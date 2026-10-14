//! Sending messages: a local copy shows at once (pending), files upload first, then the message
//! is encrypted (encrypted chats) and posted, in order per chat. Port of the sending part of
//! Reseal-js data/messages.js (send, edit, buildBody, toPayload, tagsOf).

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");
const media = @import("media.zig");
const crypto = @import("crypto.zig");
const markdown = @import("markdown.zig");

const State = app.State;
const Id = app.Id;
const gpa = app.gpa;
const t = zui.i18n.t;
const tmp = app.tmp;

pub const Out = struct {
    local: u32,
    chat: Id,
    client_id: Id,
    reply_to: Id = .{},
    /// Files still uploading (media.Upload ids); the message waits for them.
    uploads: std.ArrayList(u32) = .empty,
    /// Uploaded files, as payload JSON objects.
    media_json: std.ArrayList([]u8) = .empty,
    attempt: u8 = 0,
    failed: bool = false,
    /// Forwarded: {"fromUserId","fromName","date"} (owned).
    fwd_json: ?[]u8 = null,
    /// More of the message, as JSON fields (",\"k\":v..."), owned: for the encrypted payload, for
    /// the body of a readable chat, and for the body in both cases.
    payload_extra: ?[]u8 = null,
    plain_extra: ?[]u8 = null,
    enc_body_extra: ?[]u8 = null,
    body_extra: ?[]u8 = null,
    /// Scheduled (or sent when the other person is online): it leaves the list once accepted.
    later: bool = false,
};

pub const Poll = struct {
    question: []const u8,
    options: []const []const u8,
    multiple: bool = false,
    quiz: bool = false,
    anonymous: bool = true,
    correct: ?usize = null,
    explanation: []const u8 = "",
};

/// What the composer sends (messages.js send's draft).
pub const Draft = struct {
    text: []const u8 = "",
    entities: []const markdown.Entity = &.{},
    reply_to: Id = .{},
    mentions: []const []const u8 = &.{},
    poll: ?Poll = null,
    location: ?struct { lat: f64, lng: f64, accuracy: f64 = 0, title: []const u8 = "" } = null,
    sticker: ?[]const u8 = null,
    /// A link preview ({url,title,description,siteName,image}) as JSON.
    preview_json: ?[]const u8 = null,
    /// A reply to a glimpse: {id, thumb, at} (encrypted payload only, as messages.js).
    story_json: ?[]const u8 = null,
    silent: bool = false,
    /// Milliseconds since 1970, or 0.
    scheduled_at: i64 = 0,
    when_online: bool = false,
    /// Seconds, or 0.
    ttl: i64 = 0,
};

pub const Outbox = struct {
    items: std.ArrayList(Out) = .empty,
    next_local: u32 = 1,
    posting: std.StringHashMapUnmanaged(void) = .empty,
};

fn find(s: *State, local: u32) ?*Out {
    for (s.out.items.items) |*o| if (o.local == local) return o;
    return null;
}

fn removeOut(s: *State, local: u32) void {
    for (s.out.items.items, 0..) |o, i| if (o.local == local) {
        var x = s.out.items.orderedRemove(i);
        for (x.media_json.items) |m| gpa.free(m);
        if (x.fwd_json) |f| gpa.free(f);
        inline for (.{ "payload_extra", "plain_extra", "enc_body_extra", "body_extra" }) |name| if (@field(x, name)) |f| gpa.free(f);
        x.media_json.deinit(gpa);
        x.uploads.deinit(gpa);
        return;
    };
}

fn newClientId() Id {
    const b = sys.randomBytes(8);
    const hex = std.fmt.bytesToHex(b, .lower);
    return Id.of(std.fmt.allocPrint(tmp(), "{x}-{s}", .{ @as(u64, @intCast(@max(0, sys.now()))), hex }) catch &hex);
}

/// Shows the message at once and queues it. `text` may be empty when files go with it.
pub fn queue(s: *State, chat_id: []const u8, text: []const u8, reply_to: Id) ?u32 {
    return queueDraft(s, chat_id, .{ .text = text, .reply_to = reply_to });
}

fn jsonArrayOfStrings(a: std.mem.Allocator, items: []const []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '[') catch return "[]";
    for (items, 0..) |it, i| out.print(a, "{s}{s}", .{ if (i == 0) "" else ",", j.quote(a, it) catch "\"\"" }) catch {};
    out.append(a, ']') catch {};
    return out.items;
}

pub fn queueDraft(s: *State, chat_id: []const u8, d: Draft) ?u32 {
    const text = d.text;
    const reply_to = d.reply_to;
    const tl = s.store.timeline(chat_id) catch return null;
    const local = s.out.next_local;
    s.out.next_local += 1;
    const cid = newClientId();
    const a = tmp();
    const raw = std.fmt.allocPrint(a, "{{\"id\":null,\"clientId\":\"{s}\",\"chatId\":\"{s}\",\"senderId\":\"{s}\",\"authorId\":\"{s}\",\"kind\":\"message\",\"seq\":null{s}{s}{s}}}", .{
        cid.str(),                                                            chat_id, s.store.myId(), s.store.myId(),
        if (reply_to.isSet()) ",\"replyTo\":{\"id\":\"" else "",            if (reply_to.isSet()) reply_to.str() else "",
        if (reply_to.isSet()) "\"}" else "",
    }) catch return null;
    const v = j.parse(a, raw) orelse return null;
    const m = data.newMessage(v) catch return null;
    m.state = .sending;
    m.local_id = local;
    m.at = sys.now();
    m.decrypt = .ok;
    m.verified = true;
    var content: j.ObjectMap = .empty;
    content.put(m.o.alloc(), "text", data.string(m.o.alloc().dupe(u8, text) catch "")) catch {};
    content.put(m.o.alloc(), "media", .{ .array = std.json.Array.init(m.o.alloc()) }) catch {};
    // The parts the payload, the body and the pending copy share.
    var pay: std.ArrayList(u8) = .empty;
    var plain: std.ArrayList(u8) = .empty;
    var encb: std.ArrayList(u8) = .empty;
    var both: std.ArrayList(u8) = .empty;
    if (d.entities.len > 0) {
        const ej = markdown.entitiesJson(a, d.entities) catch "[]";
        pay.print(a, ",\"ent\":{s}", .{ej}) catch {};
        plain.print(a, ",\"entities\":{s}", .{ej}) catch {};
        if (j.parse(m.o.alloc(), ej)) |ev| content.put(m.o.alloc(), "entities", ev) catch {};
    }
    if (d.poll) |p| {
        const opts = jsonArrayOfStrings(a, p.options);
        const q = j.quote(a, p.question) catch "\"\"";
        pay.print(a, ",\"poll\":{{\"q\":{s},\"o\":{s}", .{ q, opts }) catch {};
        if (p.quiz) {
            pay.print(a, ",\"correct\":{d}", .{p.correct orelse 0}) catch {};
            if (p.explanation.len > 0) pay.print(a, ",\"expl\":{s}", .{j.quote(a, p.explanation) catch "\"\""}) catch {};
        }
        pay.append(a, '}') catch {};
        encb.print(a, ",\"poll\":{{\"optionCount\":{d},\"multiple\":{},\"quiz\":{},\"anonymous\":{}}}", .{ p.options.len, p.multiple and !p.quiz, p.quiz, p.anonymous }) catch {};
        plain.print(a, ",\"poll\":{{\"question\":{s},\"options\":{s},\"multiple\":{},\"quiz\":{},\"anonymous\":{}", .{ q, opts, p.multiple and !p.quiz, p.quiz, p.anonymous }) catch {};
        if (p.quiz) {
            plain.print(a, ",\"correct\":{d}", .{p.correct orelse 0}) catch {};
            if (p.explanation.len > 0) plain.print(a, ",\"explanation\":{s}", .{j.quote(a, p.explanation) catch "\"\""}) catch {};
        }
        plain.append(a, '}') catch {};
        const shown = std.fmt.allocPrint(a, "{{\"question\":{s},\"options\":{s}}}", .{ q, opts }) catch "{}";
        if (j.parse(m.o.alloc(), shown)) |pv| content.put(m.o.alloc(), "poll", pv) catch {};
        const meta = std.fmt.allocPrint(a, "{{\"optionCount\":{d},\"multiple\":{},\"quiz\":{},\"anonymous\":{},\"total\":0}}", .{ p.options.len, p.multiple and !p.quiz, p.quiz, p.anonymous }) catch "{}";
        if (j.parse(a, meta)) |mv| m.o.set("poll", mv) catch {};
    }
    if (d.location) |l| {
        const lj = std.fmt.allocPrint(a, "{{\"lat\":{d},\"lng\":{d},\"accuracy\":{d},\"title\":{s}}}", .{ l.lat, l.lng, l.accuracy, j.quote(a, l.title) catch "\"\"" }) catch "{}";
        pay.print(a, ",\"loc\":{s}", .{lj}) catch {};
        plain.print(a, ",\"location\":{s}", .{lj}) catch {};
        if (j.parse(m.o.alloc(), lj)) |lv| content.put(m.o.alloc(), "location", lv) catch {};
    }
    if (d.sticker) |e| {
        const sj = std.fmt.allocPrint(a, "{{\"emoji\":{s}}}", .{j.quote(a, e) catch "\"\""}) catch "{}";
        pay.print(a, ",\"sticker\":{s}", .{sj}) catch {};
        plain.print(a, ",\"sticker\":{s}", .{sj}) catch {};
        if (j.parse(m.o.alloc(), sj)) |sv| content.put(m.o.alloc(), "sticker", sv) catch {};
    }
    if (d.preview_json) |pj| {
        pay.print(a, ",\"preview\":{s}", .{pj}) catch {};
        plain.print(a, ",\"preview\":{s}", .{pj}) catch {};
        if (j.parse(m.o.alloc(), pj)) |pv| content.put(m.o.alloc(), "preview", pv) catch {};
    }
    if (d.story_json) |sj| {
        pay.print(a, ",\"story\":{s}", .{sj}) catch {};
        if (j.parse(m.o.alloc(), sj)) |sv| content.put(m.o.alloc(), "story", sv) catch {};
    }
    if (d.mentions.len > 0) both.print(a, ",\"mentions\":{s}", .{jsonArrayOfStrings(a, d.mentions)}) catch {};
    if (d.silent) both.appendSlice(a, ",\"silent\":true") catch {};
    if (d.scheduled_at > 0) both.print(a, ",\"scheduledAt\":{d}", .{d.scheduled_at}) catch {};
    if (d.when_online) both.appendSlice(a, ",\"whenOnline\":true") catch {};
    if (d.ttl > 0) {
        both.print(a, ",\"ttl\":{d}", .{d.ttl}) catch {};
        m.o.set("ttl", data.int(d.ttl)) catch {};
    }
    m.content = .{ .object = content };
    const later = d.scheduled_at > 0 or d.when_online;
    if (later) m.state = .scheduled;
    tl.pending.append(gpa, m) catch {
        m.destroy();
        return null;
    };
    const own = struct {
        fn f(x: []const u8) ?[]u8 {
            return if (x.len == 0) null else gpa.dupe(u8, x) catch null;
        }
    }.f;
    s.out.items.append(gpa, .{
        .local = local,
        .chat = Id.of(chat_id),
        .client_id = cid,
        .reply_to = reply_to,
        .payload_extra = own(pay.items),
        .plain_extra = own(plain.items),
        .enc_body_extra = own(encb.items),
        .body_extra = own(both.items),
        .later = later,
    }) catch return null;
    return local;
}

pub fn sendText(s: *State, chat_id: []const u8, text: []const u8, reply_to: Id) void {
    _ = queue(s, chat_id, text, reply_to) orelse return;
    pump(s, chat_id);
}

/// A file finished uploading for message `local`: `item` is its payload object (JSON).
pub fn fileReady(s: *State, local: u32, upload: u32, item_json: []const u8) void {
    const o = find(s, local) orelse return;
    for (o.uploads.items, 0..) |u, i| if (u == upload) {
        _ = o.uploads.orderedRemove(i);
        break;
    };
    o.media_json.append(gpa, gpa.dupe(u8, item_json) catch return) catch {};
    // Show it in the pending copy too.
    if (s.store.existingTimeline(o.chat.str())) |tl| if (tl.findPending(local)) |m| {
        const a = m.o.alloc();
        if (j.parse(a, item_json)) |item| if (m.content) |*c| if (c.object.getPtr("media")) |arr| arr.array.append(item) catch {};
    };
    pump(s, o.chat.str());
}

pub fn fileFailed(s: *State, local: u32, message: []const u8) void {
    const o = find(s, local) orelse return;
    fail(s, o, message);
}

pub fn progress(s: *State, local: u32, p: f32) void {
    const o = find(s, local) orelse return;
    if (s.store.existingTimeline(o.chat.str())) |tl| if (tl.findPending(local)) |m| {
        m.progress = p;
    };
}

fn fail(s: *State, o: *Out, message: []const u8) void {
    o.failed = true;
    if (s.store.existingTimeline(o.chat.str())) |tl| if (tl.findPending(o.local)) |m| {
        m.state = .failed;
        m.err = m.o.alloc().dupe(u8, message) catch null;
    };
}

/// The chat's key could not be made ready: the waiting messages fail (they can be retried).
pub fn keyProblem(s: *State, chat: []const u8, message: []const u8) void {
    for (s.out.items.items) |*o| if (o.chat.eql(chat) and !o.failed and o.uploads.items.len == 0) fail(s, o, message);
}

pub fn retry(s: *State, local: u32) void {
    const o = find(s, local) orelse return;
    o.failed = false;
    o.attempt = 0;
    if (s.store.existingTimeline(o.chat.str())) |tl| if (tl.findPending(local)) |m| {
        m.state = .sending;
        m.err = null;
    };
    pump(s, o.chat.str());
}

pub fn cancel(s: *State, local: u32) void {
    const o = find(s, local) orelse return;
    const chat = o.chat;
    media.cancelUploads(s, local);
    if (s.store.existingTimeline(chat.str())) |tl| tl.dropPending(local);
    removeOut(s, local);
}

const TAGS = [_][2][]const u8{ .{ "photo", "photo" }, .{ "video", "video" }, .{ "file", "file" }, .{ "voice", "voice" }, .{ "round", "round" }, .{ "audio", "audio" }, .{ "gif", "gif" }, .{ "sticker", "sticker" } };

/// The next message of this chat, if it can go now.
pub fn pump(s: *State, chat_id: []const u8) void {
    if (s.out.posting.contains(chat_id)) return;
    const o = for (s.out.items.items) |*o| {
        if (o.chat.eql(chat_id) and !o.failed) break o;
    } else return;
    if (o.uploads.items.len > 0) return;
    const c = s.store.chat(chat_id) orelse return;
    const tl = s.store.timeline(chat_id) catch return;
    const m = tl.findPending(o.local) orelse return removeOut(s, o.local);
    const a = tmp();
    const text = m.text();

    var media_arr: std.ArrayList(u8) = .empty;
    media_arr.append(a, '[') catch return;
    for (o.media_json.items, 0..) |mj, i| media_arr.print(a, "{s}{s}", .{ if (i == 0) "" else ",", mj }) catch {};
    media_arr.append(a, ']') catch return;

    var body: std.ArrayList(u8) = .empty;
    body.print(a, "{{\"clientId\":\"{s}\"", .{o.client_id.str()}) catch return;
    if (o.reply_to.isSet()) body.print(a, ",\"replyTo\":\"{s}\"", .{o.reply_to.str()}) catch {};

    if (c.encrypted()) {
        if (s.keys.identity == null) return fail(s, o, t("Unlock encryption first"));
        if (c.keyEpoch() == 0 or c.o.b("rotationNeeded")) return keys.rotate(s, chat_id);
        if (keys.keyFor(s, chat_id, c.keyEpoch()) == null) {
            if (keys.isRotating(s, chat_id) or s.keys.loading.contains(chat_id)) return;
            // Not shared with us yet: fetch, and if it is still missing start a new epoch.
            if (!c.keys_fetched) return keys.fetchChatKeys(s, chat_id, false);
            return keys.rotate(s, chat_id);
        }
        // The payload (short keys keep messages small).
        var payload: std.ArrayList(u8) = .empty;
        payload.appendSlice(a, "{\"v\":1") catch return;
        if (text.len > 0) payload.print(a, ",\"t\":{s}", .{j.quote(a, text) catch return}) catch return;
        if (o.media_json.items.len > 0) payload.print(a, ",\"media\":{s}", .{media_arr.items}) catch return;
        if (o.fwd_json) |f| payload.print(a, ",\"fwd\":{s}", .{f}) catch return;
        if (o.payload_extra) |x| payload.appendSlice(a, x) catch return;
        payload.append(a, '}') catch return;
        const env = keys.encrypt(s, c, payload.items) orelse return fail(s, o, t("Could not encrypt the message"));
        const tags = tagsOf(a, text, o.media_json.items);
        const more = extraTags(a, o);
        body.print(a, ",\"enc\":{s},\"tags\":[{s}{s}]", .{ env, tags, if (tags.len == 0 and more.len > 0) more[1..] else more }) catch return;
        if (o.media_json.items.len > 0) {
            body.appendSlice(a, ",\"mediaIds\":[") catch return;
            for (o.media_json.items, 0..) |mj, i| body.print(a, "{s}\"{s}\"", .{ if (i == 0) "" else ",", j.strOr(j.parse(a, mj), "id", "") }) catch {};
            body.append(a, ']') catch return;
        }
        if (o.enc_body_extra) |x| body.appendSlice(a, x) catch return;
    } else {
        if (o.plain_extra) |x| body.appendSlice(a, x) catch return;
        if (text.len > 0) body.print(a, ",\"text\":{s}", .{j.quote(a, text) catch return}) catch return;
        if (o.fwd_json) |f| {
            // A copy forwarded from an encrypted chat: the label is informational (date in ms).
            const fv = j.parse(a, f);
            const date = @import("sys.zig").parseIso(j.strOr(fv, "date", "")) orelse 0;
            body.print(a, ",\"forwarded\":{{\"fromName\":{s},\"fromUserId\":{s},\"date\":{d}}}", .{ j.stringify(a, j.field(fv, "fromName") orelse .null) catch "null", j.stringify(a, j.field(fv, "fromUserId") orelse .null) catch "null", date }) catch return;
        }
        if (o.media_json.items.len > 0) {
            // Plain chats: the files without their (absent) keys.
            body.appendSlice(a, ",\"media\":[") catch return;
            for (o.media_json.items, 0..) |mj, i| {
                var v = j.parse(a, mj) orelse continue;
                _ = v.object.orderedRemove("key");
                _ = v.object.orderedRemove("iv");
                body.print(a, "{s}{s}", .{ if (i == 0) "" else ",", j.stringify(a, v) catch "{}" }) catch {};
            }
            body.append(a, ']') catch return;
        }
    }
    if (o.body_extra) |x| body.appendSlice(a, x) catch return;
    body.append(a, '}') catch return;
    s.out.posting.put(gpa, gpa.dupe(u8, chat_id) catch return, {}) catch return;
    keys.apiSigned(s, .POST, std.fmt.allocPrint(a, "/chats/{s}/messages", .{chat_id}) catch return, body.items, .{ .send_message = .{ .chat = Id.of(chat_id), .local = o.local } });
}

fn tagsOf(a: std.mem.Allocator, text: []const u8, media_json: []const []u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var seen: [TAGS.len + 1]bool = @splat(false);
    for (media_json) |mj| {
        const kind = j.strOr(j.parse(a, mj), "kind", "");
        for (TAGS, 0..) |tg, i| if (std.mem.eql(u8, tg[0], kind) and !seen[i]) {
            seen[i] = true;
            out.print(a, "{s}\"{s}\"", .{ if (out.items.len == 0) "" else ",", tg[1] }) catch {};
        };
    }
    if (std.mem.indexOf(u8, text, "http://") != null or std.mem.indexOf(u8, text, "https://") != null)
        out.print(a, "{s}\"link\"", .{if (out.items.len == 0) "" else ","}) catch {};
    return out.items;
}

fn extraTags(a: std.mem.Allocator, o: *const Out) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const p = o.payload_extra orelse return "";
    if (std.mem.indexOf(u8, p, "\"poll\":") != null) out.appendSlice(a, ",\"poll\"") catch {};
    if (std.mem.indexOf(u8, p, "\"loc\":") != null) out.appendSlice(a, ",\"location\"") catch {};
    if (std.mem.indexOf(u8, p, "\"sticker\":") != null) out.appendSlice(a, ",\"sticker\"") catch {};
    if (std.mem.indexOf(u8, p, "\"preview\":") != null) out.appendSlice(a, ",\"link\"") catch {};
    return out.items;
}

fn endPosting(s: *State, chat: []const u8) void {
    if (s.out.posting.fetchRemove(chat)) |kv| gpa.free(kv.key);
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    switch (op) {
        .send_message => |x| {
            const chat = x.chat.str();
            endPosting(s, chat);
            const o = find(s, x.local) orelse return true;
            if (!r.ok()) {
                const e = app.apiError(r);
                if (o.attempt == 0 and (std.mem.eql(u8, e.code, "stale_epoch") or std.mem.eql(u8, e.code, "no_epoch"))) {
                    o.attempt += 1;
                    app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/{s}", .{chat}) catch return true, null, .{ .chat_refresh = x.chat });
                    return true;
                }
                fail(s, o, e.message);
                pump(s, chat);
                return true;
            }
            const v = j.parse(tmp(), r.body);
            const tl = s.store.timeline(chat) catch return true;
            if (j.obj(v, "message")) |raw| {
                // The socket may have delivered it first (and replaced the pending copy).
                if (tl.findPending(x.local) == null and tl.find(j.strOr(raw, "id", "")) != null) {
                    removeOut(s, x.local);
                    pump(s, chat);
                    return true;
                }
                const m = data.newMessage(raw) catch return true;
                if (tl.findPending(x.local)) |local| {
                    if (local.content) |c| m.content = j.clone(m.o.alloc(), c) catch null;
                }
                if (m.content != null) {
                    m.decrypt = .ok;
                    m.verified = true;
                } else @import("keys.zig").hydrate(s, chat, m);
                if (m.seq() != null) {
                    if (s.store.chat(chat)) |c| {
                        if (c.last == null or (m.seq() orelse 0) >= (c.last.?.seq() orelse 0)) {
                            if (data.cloneMessage(m)) |copy| {
                                if (c.last) |old| old.destroy();
                                c.last = copy;
                            } else |_| {}
                        }
                        c.setMe("unread", data.int(0));
                        c.setMe("draft", .null);
                        c.setMe("lastReadSeq", data.int(@max(c.meInt("lastReadSeq"), m.seq() orelse 0)));
                    }
                    tl.dropPending(x.local);
                    tl.insert(m) catch {};
                } else {
                    // Scheduled: it leaves the list until it is sent.
                    tl.dropPending(x.local);
                    m.destroy();
                    s.scheduled_count += 1;
                }
            } else tl.dropPending(x.local);
            removeOut(s, x.local);
            pump(s, chat);
        },
        .edit_message => |x| {
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            const v = j.parse(tmp(), r.body);
            const raw = j.obj(v, "message") orelse return true;
            const tl = s.store.existingTimeline(x.chat.str()) orelse return true;
            const old = tl.find(x.msg.str()) orelse return true;
            const m = data.newMessage(raw) catch return true;
            _ = old;
            if (m.enc() != null) keys.hydrate(s, x.chat.str(), m);
            tl.insert(m) catch {};
        },
        else => return false,
    }
    return true;
}

/// Edit my message: re-encrypted with the current key in encrypted chats.
pub fn edit(s: *State, chat_id: []const u8, msg_id: []const u8, text: []const u8, entities: []const markdown.Entity) void {
    const c = s.store.chat(chat_id) orelse return;
    const a = tmp();
    const ej: ?[]const u8 = if (entities.len > 0) (markdown.entitiesJson(a, entities) catch null) else null;
    var body: []const u8 = "";
    if (c.encrypted()) {
        const tl = s.store.existingTimeline(chat_id) orelse return;
        const m = tl.find(msg_id) orelse return;
        var payload: std.ArrayList(u8) = .empty;
        payload.print(a, "{{\"v\":1,\"t\":{s}", .{j.quote(a, text) catch return}) catch return;
        const media_items = m.media();
        if (media_items.len > 0) payload.print(a, ",\"media\":{s}", .{j.stringify(a, media_items) catch "[]"}) catch {};
        if (ej) |e| payload.print(a, ",\"ent\":{s}", .{e}) catch {};
        payload.append(a, '}') catch return;
        const env = keys.encrypt(s, c, payload.items) orelse return app.toastError(s, t("Waiting for a member to share this chat's encryption key"));
        body = std.fmt.allocPrint(a, "{{\"enc\":{s},\"tags\":[]}}", .{env}) catch return;
    } else {
        body = std.fmt.allocPrint(a, "{{\"text\":{s},\"entities\":{s}}}", .{ j.quote(a, text) catch return, ej orelse "[]" }) catch return;
    }
    keys.apiSigned(s, .PATCH, std.fmt.allocPrint(a, "/chats/{s}/messages/{s}", .{ chat_id, msg_id }) catch return, body, .{ .edit_message = .{ .chat = Id.of(chat_id), .msg = Id.of(msg_id) } });
}

/// A file the web shell read (Attach): {"t":"file","name","type","size","data":base64,
/// "thumb"?,"w"?,"h"?}. It goes out in its own message in the open chat.
pub fn onPickedFile(s: *State, v: j.Value) void {
    if (!s.open_chat.isSet()) return;
    const bytes = crypto.fromB64(gpa, j.strOr(v, "data", "")) catch return app.toastError(s, t("Could not read that file"));
    attach(s, bytes, .{
        .name = j.strOr(v, "name", "file"),
        .mime = j.strOr(v, "type", "application/octet-stream"),
        .thumb = j.str(v, "thumb"),
        .w = j.int(v, "w"),
        .h = j.int(v, "h"),
        .duration = j.float(v, "duration"),
        .encrypted = false,
    });
}

/// A photo or file zui's picker gave (phones): its bytes are only valid now, so copied.
pub fn onPicked(s: *State, f: zui.File) void {
    if (!s.open_chat.isSet()) return;
    const bytes = gpa.dupe(u8, f.data) catch return app.toastError(s, t("Could not read that file"));
    attach(s, bytes, .{
        .name = if (f.name.len > 0) f.name else "photo.jpg",
        .mime = if (f.mime.len > 0) f.mime else "application/octet-stream",
        .w = if (f.width > 0) @as(i64, f.width) else null,
        .h = if (f.height > 0) @as(i64, f.height) else null,
        .encrypted = false,
    });
}

/// Sends `bytes` (owned) as a new message's attachment in the open chat.
/// A voice message or round video (voice.zig): its bytes (owned) as a new message.
pub fn attachRecording(s: *State, bytes: []u8, meta: media.Meta) void {
    attach(s, bytes, meta);
}

fn attach(s: *State, bytes: []u8, meta_in: media.Meta) void {
    const chat = s.open_chat;
    const c = s.store.chat(chat.str()) orelse {
        gpa.free(bytes);
        return;
    };
    var meta = meta_in;
    meta.encrypted = c.encrypted();
    const local = queue(s, chat.str(), "", s.reply_to) orelse {
        gpa.free(bytes);
        return;
    };
    s.reply_to = .{};
    const o = find(s, local) orelse return;
    const up = media.startUpload(s, local, bytes, meta) orelse return;
    o.uploads.append(gpa, up) catch {};
}

/// Forwards a message's content into another chat (re-encrypted there when needed).
pub fn forward(s: *State, to_chat: []const u8, text: []const u8, media_items: []j.Value, fwd_json: []const u8) void {
    const local = queue(s, to_chat, text, .{}) orelse return;
    const o = find(s, local) orelse return;
    o.fwd_json = gpa.dupe(u8, fwd_json) catch null;
    const a = tmp();
    for (media_items) |it| {
        const mj = j.stringify(a, it) catch continue;
        o.media_json.append(gpa, gpa.dupe(u8, mj) catch continue) catch {};
    }
    if (s.store.existingTimeline(to_chat)) |tl| if (tl.findPending(local)) |m| {
        const ma = m.o.alloc();
        if (m.content) |*c| {
            if (c.object.getPtr("media")) |arr| for (media_items) |it| arr.array.append(j.clone(ma, it) catch continue) catch {};
            if (j.parse(ma, fwd_json)) |fv| c.object.put(ma, "fwd", fv) catch {};
        }
    };
    pump(s, to_chat);
}
