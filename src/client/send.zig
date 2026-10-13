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
    m.content = .{ .object = content };
    tl.pending.append(gpa, m) catch {
        m.destroy();
        return null;
    };
    s.out.items.append(gpa, .{ .local = local, .chat = Id.of(chat_id), .client_id = cid, .reply_to = reply_to }) catch return null;
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
        payload.append(a, '}') catch return;
        const env = keys.encrypt(s, c, payload.items) orelse return fail(s, o, t("Could not encrypt the message"));
        body.print(a, ",\"enc\":{s},\"tags\":[{s}]", .{ env, tagsOf(a, text, o.media_json.items) }) catch return;
        if (o.media_json.items.len > 0) {
            body.appendSlice(a, ",\"mediaIds\":[") catch return;
            for (o.media_json.items, 0..) |mj, i| body.print(a, "{s}\"{s}\"", .{ if (i == 0) "" else ",", j.strOr(j.parse(a, mj), "id", "") }) catch {};
            body.append(a, ']') catch return;
        }
    } else {
        if (text.len > 0) body.print(a, ",\"text\":{s}", .{j.quote(a, text) catch return}) catch return;
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
    body.append(a, '}') catch return;
    s.out.posting.put(gpa, gpa.dupe(u8, chat_id) catch return, {}) catch return;
    app.api(s, .POST, std.fmt.allocPrint(a, "/chats/{s}/messages", .{chat_id}) catch return, body.items, .{ .send_message = .{ .chat = Id.of(chat_id), .local = o.local } });
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
                const m = data.newMessage(raw) catch return true;
                if (tl.findPending(x.local)) |local| {
                    if (local.content) |c| m.content = j.clone(m.o.alloc(), c) catch null;
                }
                m.decrypt = .ok;
                m.verified = true;
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
            if (m.enc() != null) {
                // Our own edit: we know the words.
                var content = j.clone(m.o.alloc(), old.content orelse j.emptyObject()) catch return true;
                content.object.put(m.o.alloc(), "text", data.string(m.o.alloc().dupe(u8, s.fields.get(.composer).get()) catch "")) catch {};
                m.content = content;
                m.decrypt = .ok;
                m.verified = true;
            }
            tl.insert(m) catch {};
        },
        else => return false,
    }
    return true;
}

/// Edit my message: re-encrypted with the current key in encrypted chats.
pub fn edit(s: *State, chat_id: []const u8, msg_id: []const u8, text: []const u8) void {
    const c = s.store.chat(chat_id) orelse return;
    const a = tmp();
    var body: []const u8 = "";
    if (c.encrypted()) {
        const tl = s.store.existingTimeline(chat_id) orelse return;
        const m = tl.find(msg_id) orelse return;
        var payload: std.ArrayList(u8) = .empty;
        payload.print(a, "{{\"v\":1,\"t\":{s}", .{j.quote(a, text) catch return}) catch return;
        const media_items = m.media();
        if (media_items.len > 0) payload.print(a, ",\"media\":{s}", .{j.stringify(a, media_items) catch "[]"}) catch {};
        payload.append(a, '}') catch return;
        const env = keys.encrypt(s, c, payload.items) orelse return app.toastError(s, t("Waiting for a member to share this chat's encryption key"));
        body = std.fmt.allocPrint(a, "{{\"enc\":{s},\"tags\":[]}}", .{env}) catch return;
    } else {
        body = std.fmt.allocPrint(a, "{{\"text\":{s}}}", .{j.quote(a, text) catch return}) catch return;
    }
    app.api(s, .PATCH, std.fmt.allocPrint(a, "/chats/{s}/messages/{s}", .{ chat_id, msg_id }) catch return, body, .{ .edit_message = .{ .chat = Id.of(chat_id), .msg = Id.of(msg_id) } });
}

/// A file the web shell read (Attach): {"t":"file","name","type","size","data":base64,
/// "thumb"?,"w"?,"h"?}. It goes out in its own message in the open chat.
pub fn onPickedFile(s: *State, v: j.Value) void {
    if (!s.open_chat.isSet()) return;
    const chat = s.open_chat;
    const c = s.store.chat(chat.str()) orelse return;
    const bytes = crypto.fromB64(gpa, j.strOr(v, "data", "")) catch return app.toastError(s, t("Could not read that file"));
    const local = queue(s, chat.str(), "", s.reply_to) orelse {
        gpa.free(bytes);
        return;
    };
    s.reply_to = .{};
    const o = find(s, local) orelse return;
    const up = media.startUpload(s, local, bytes, .{
        .name = j.strOr(v, "name", "file"),
        .mime = j.strOr(v, "type", "application/octet-stream"),
        .thumb = j.str(v, "thumb"),
        .w = j.int(v, "w"),
        .h = j.int(v, "h"),
        .duration = j.float(v, "duration"),
        .encrypted = c.encrypted(),
    }) orelse return;
    o.uploads.append(gpa, up) catch {};
}
