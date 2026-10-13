//! The composer's extras (Reseal-js ui/composer.js): markdown formatting into entities, @mentions,
//! link previews, send options (silent, scheduled or a reminder in Saved, when online,
//! disappearing), polls and quizzes, location, emoji and emoji stickers, and the list of
//! scheduled messages.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");
const send = @import("send.zig");
const sync = @import("sync.zig");
const markdown = @import("markdown.zig");
const emoji = @import("emoji_data.zig");
const fmt = @import("fmt.zig");

const State = app.State;
const Id = app.Id;
const gpa = app.gpa;
const t = zui.i18n.t;
const tmp = app.tmp;

pub const Sheet = enum { attach, options, schedule, ttl, poll, emoji, sticker, scheduled };

pub const PollFlag = enum { anonymous, multiple, quiz };

pub const Act = union(enum) {
    open: Sheet,
    silent,
    when_online,
    /// Index into `schedule_presets`.
    schedule_in: u8,
    schedule_custom,
    pick_date,
    pick_time,
    set_date: Id,
    set_time: Id,
    ttl: u32,
    poll_toggle: PollFlag,
    poll_correct: u8,
    poll_more,
    poll_less,
    poll_send,
    emoji_tab: u8,
    /// Category (or 255 for search results / recent) and index.
    emoji: struct { cat: u8, i: u16 },
    sticker: u8,
    location,
    mention: Id,
    dismiss_preview,
    preview_due: u32,
    pick_media,
    take_photo,
    pick_file,
    scheduled_send: Id,
    scheduled_delete: Id,
};

pub const Compose = struct {
    poll_anonymous: bool = true,
    poll_multiple: bool = false,
    poll_quiz: bool = false,
    poll_correct: u8 = 0,
    poll_options: u8 = 2,
    emoji_tab: u8 = 0,
    preview: ?*data.Obj = null,
    preview_dismissed: app.Text = .{},
    preview_seq: u32 = 0,
    locating: bool = false,
    scheduled: ?*data.Obj = null,
    /// Recently used emoji (newest first), kept on the device.
    recent: std.ArrayList([]u8) = .empty,
};

pub const poll_fields = [_]app.Field{ .poll_o0, .poll_o1, .poll_o2, .poll_o3, .poll_o4, .poll_o5, .poll_o6, .poll_o7, .poll_o8, .poll_o9, .poll_o10, .poll_o11 };

/// Schedule presets: minutes from now, or a time of day (negative: -hh*60-mm, today or tomorrow).
pub const schedule_presets = [_]struct { label: []const u8, minutes: i64 }{
    .{ .label = "In 1 hour", .minutes = 60 },
    .{ .label = "In 3 hours", .minutes = 180 },
    .{ .label = "Tonight at 21:00", .minutes = -(21 * 60) },
    .{ .label = "Tomorrow at 09:00", .minutes = -(9 * 60) - 24 * 60 },
    .{ .label = "In a week", .minutes = 7 * 24 * 60 },
};

pub const ttl_presets = [_]struct { seconds: u32, label: []const u8 }{
    .{ .seconds = 30, .label = "30 s" },
    .{ .seconds = 300, .label = "5 min" },
    .{ .seconds = 3600, .label = "1 h" },
    .{ .seconds = 86400, .label = "1 d" },
    .{ .seconds = 604800, .label = "1 w" },
};

fn onDate(d: []const u8) app.Msg {
    return .{ .compose = .{ .set_date = Id.of(d) } };
}

fn onTime(tm: []const u8) app.Msg {
    return .{ .compose = .{ .set_time = Id.of(tm) } };
}

/// The custom schedule time as its date and time parts ("YYYY-MM-DD", "HH:MM").
pub fn scheduleParts(s: *const State) struct { date: []const u8, time: []const u8 } {
    const v = s.fields.get(.schedule_at).get();
    if (v.len < 16) return .{ .date = "", .time = "" };
    return .{ .date = v[0..10], .time = v[11..16] };
}

fn setPart(s: *State, date: bool, part: []const u8) void {
    const cur = scheduleParts(s);
    const d = if (date) part else cur.date;
    const tm = if (date) cur.time else part;
    s.fields.getPtr(.schedule_at).set(std.fmt.allocPrint(tmp(), "{s} {s}", .{ d, tm }) catch return);
}

fn onPicked(f: zui.File) app.Msg {
    return .{ .picked = f };
}

fn onLocated(l: zui.Location) app.Msg {
    return .{ .located = l };
}

pub fn act(s: *State, a: Act) void {
    const c = &s.compose;
    switch (a) {
        .open => |sheet| {
            if (sheet == .poll) {
                c.poll_options = 2;
                c.poll_correct = 0;
                c.poll_quiz = false;
                c.poll_multiple = false;
                c.poll_anonymous = true;
                s.fields.getPtr(.poll_question).clear();
                s.fields.getPtr(.poll_explanation).clear();
                for (poll_fields) |f| s.fields.getPtr(f).clear();
            }
            if (sheet == .schedule) s.fields.getPtr(.schedule_at).set(defaultCustomTime());
            if (sheet == .scheduled) loadScheduled(s);
            if (sheet == .emoji or sheet == .sticker) loadRecent(s);
            s.modal = .{ .compose = sheet };
        },
        .silent => sendNow(s, .{ .silent = true }),
        .when_online => {
            sendNow(s, .{ .when_online = true });
            if (s.store.chat(s.open_chat.str())) |ch| if (s.store.peer(ch)) |p| app.toast(s, fmt.tf("Will be sent when {name} comes online", .{ .name = fmt.firstName(s.store.userName(p)) }));
        },
        .schedule_in => |i| {
            if (i >= schedule_presets.len) return;
            const at = presetTime(schedule_presets[i].minutes);
            scheduleAt(s, at);
        },
        .pick_date => {
            const p = scheduleParts(s);
            const today = sys.local(sys.now());
            app.fx.pickDate(.{ .value = p.date, .min = std.fmt.allocPrint(tmp(), "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(today.year)), today.month, today.day }) catch "" }, onDate);
        },
        .pick_time => app.fx.pickTime(.{ .value = scheduleParts(s).time }, onTime),
        .set_date => |d| setPart(s, true, d.str()),
        .set_time => |tm| setPart(s, false, tm.str()),
        .schedule_custom => {
            const at = parseLocal(s.fields.get(.schedule_at).trimmed()) orelse return app.toastError(s, t("Pick a time in the future."));
            scheduleAt(s, at);
        },
        .ttl => |secs| sendNow(s, .{ .ttl = secs }),
        .poll_toggle => |f| switch (f) {
            .anonymous => c.poll_anonymous = !c.poll_anonymous,
            .multiple => c.poll_multiple = !c.poll_multiple,
            .quiz => c.poll_quiz = !c.poll_quiz,
        },
        .poll_correct => |i| c.poll_correct = i,
        .poll_more => c.poll_options = @min(c.poll_options + 1, poll_fields.len),
        .poll_less => if (c.poll_options > 2) {
            c.poll_options -= 1;
            s.fields.getPtr(poll_fields[c.poll_options]).clear();
        },
        .poll_send => sendPoll(s),
        .emoji_tab => |i| c.emoji_tab = i,
        .emoji => |e| {
            const ch = emojiAt(s, e.cat, e.i) orelse return;
            remember(s, ch);
            const field = s.fields.getPtr(.composer);
            const text = std.fmt.allocPrint(tmp(), "{s}{s}", .{ field.get(), ch }) catch return;
            field.set(text);
        },
        .sticker => |i| {
            if (i >= emoji.stickers.len) return;
            s.modal = null;
            draft(s, .{ .sticker = emoji.stickers[i], .reply_to = s.reply_to });
            s.reply_to = .{};
        },
        .location => {
            s.modal = null;
            c.locating = true;
            app.toast(s, t("Getting your location…"));
            app.fx.watchLocation(onLocated);
        },
        .mention => |uid| pickMention(s, uid.str()),
        .dismiss_preview => if (c.preview) |p| {
            c.preview_dismissed.set(p.s("url") orelse "");
            p.destroy();
            c.preview = null;
        },
        .preview_due => |seq| if (seq == c.preview_seq) fetchPreview(s),
        // The web shell's picker also makes a tiny preview for the receivers' placeholders.
        .pick_media => {
            s.modal = null;
            if (zui.platform == .web) app.post("{\"t\":\"pick\",\"accept\":\"image/*,video/*\"}") else app.fx.pickPhoto(.{ .max_size = 2560, .quality = 85 }, onPicked);
        },
        .take_photo => {
            s.modal = null;
            app.fx.pickPhoto(.{ .camera = true, .max_size = 2560, .quality = 85 }, onPicked);
        },
        .pick_file => {
            s.modal = null;
            if (zui.platform == .web) app.post("{\"t\":\"pick\"}") else app.fx.pickFile(.{}, onPicked);
        },
        .scheduled_send => |id| app.api(s, .POST, std.fmt.allocPrint(tmp(), "/chats/{s}/messages/scheduled/{s}/send", .{ s.open_chat.str(), id.str() }) catch return, "{}", .scheduled_changed),
        .scheduled_delete => |id| app.api(s, .POST, std.fmt.allocPrint(tmp(), "/chats/{s}/messages/delete", .{s.open_chat.str()}) catch return, std.fmt.allocPrint(tmp(), "{{\"ids\":[\"{s}\"],\"forEveryone\":true}}", .{id.str()}) catch return, .scheduled_changed),
    }
}

/// A position for "Location" arrived (or not): send it once.
pub fn onLocation(s: *State, l: zui.Location) void {
    if (!s.compose.locating) return;
    s.compose.locating = false;
    app.fx.watchLocation(null);
    switch (l) {
        .fix => |f| draft(s, .{ .location = .{ .lat = f.lat, .lng = f.lng, .accuracy = f.accuracy, .title = t("My location") } }),
        .denied => app.toastError(s, t("Location permission was denied.")),
        .unavailable => app.toastError(s, t("Could not get your location.")),
    }
}

// ---------------------------------------------------------------------------------------------
// Sending what is in the composer

pub const Options = struct { silent: bool = false, scheduled_at: i64 = 0, when_online: bool = false, ttl: i64 = 0 };

/// The composer's text as a message (or as the edit of one).
pub fn sendNow(s: *State, o: Options) void {
    s.modal = null;
    if (!s.open_chat.isSet()) return;
    const raw = std.mem.trimEnd(u8, s.fields.get(.composer).get(), " \t\r\n");
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return;
    const a = tmp();
    const p = markdown.parse(a, raw) catch return;
    if (std.mem.trim(u8, p.text, " \t\r\n").len == 0) return;
    if (p.text.len > 8192 * 4) return app.toastError(s, t("This message is too long."));
    const chat = s.open_chat.str();
    if (s.editing.isSet()) {
        send.edit(s, chat, s.editing.str(), p.text, p.entities);
        s.editing = .{};
    } else {
        var preview_json: ?[]const u8 = null;
        if (s.compose.preview) |pv| preview_json = previewJson(a, pv);
        draft(s, .{
            .text = p.text,
            .entities = p.entities,
            .reply_to = s.reply_to,
            .mentions = mentionIds(s, a, raw),
            .preview_json = preview_json,
            .silent = o.silent,
            .scheduled_at = o.scheduled_at,
            .when_online = o.when_online,
            .ttl = o.ttl,
        });
        s.first_unread = 0;
        if (o.scheduled_at > 0) {
            const reminder = if (s.store.chat(chat)) |ch| ch.is("saved") else false;
            app.toast(s, if (reminder) t("Reminder set") else t("Message scheduled"));
        }
    }
    s.reply_to = .{};
    sync.cancelTyping(s);
    s.fields.getPtr(.composer).clear();
    if (s.compose.preview) |pv| pv.destroy();
    s.compose.preview = null;
    s.compose.preview_dismissed.clear();
}

fn draft(s: *State, d: send.Draft) void {
    if (!s.open_chat.isSet()) return;
    const chat = s.open_chat.str();
    _ = send.queueDraft(s, chat, d) orelse return;
    send.pump(s, chat);
}

fn previewJson(a: std.mem.Allocator, p: *const data.Obj) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '{') catch return "{}";
    var first = true;
    inline for (.{ "url", "title", "description", "siteName", "image" }) |k| {
        if (p.s(k)) |v| {
            out.print(a, "{s}\"{s}\":{s}", .{ if (first) "" else ",", k, j.quote(a, v) catch "\"\"" }) catch {};
            first = false;
        }
    }
    out.append(a, '}') catch {};
    return out.items;
}

/// Ids of the people @mentioned (by username) among the chat's members.
fn mentionIds(s: *State, a: std.mem.Allocator, raw: []const u8) []const []const u8 {
    const names = markdown.usernames(a, raw) catch return &.{};
    if (names.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    const members = if (s.members) |m| j.arr(m.v, "members") else &.{};
    for (names) |n| {
        for (members) |mb| {
            const u = j.obj(mb, "user") orelse continue;
            if (std.ascii.eqlIgnoreCase(j.strOr(u, "username", ""), n)) {
                out.append(a, j.strOr(u, "id", "")) catch {};
                break;
            }
        }
    }
    return out.items;
}

fn scheduleAt(s: *State, at: i64) void {
    if (at < sys.now() + 10_000) return app.toastError(s, t("Pick a time in the future."));
    sendNow(s, .{ .scheduled_at = at });
}

fn presetTime(minutes: i64) i64 {
    const now = sys.now();
    if (minutes > 0) return now + minutes * 60_000;
    // A time of day: today, or tomorrow when it has passed (or when asked for tomorrow).
    var m = -minutes;
    var days: i64 = 0;
    if (m >= 24 * 60) {
        days = 1;
        m -= 24 * 60;
    }
    const tz = @as(i64, sys.tzOffsetMin(now)) * 60_000;
    const local_midnight = @divFloor(now + tz, 86_400_000) * 86_400_000 - tz;
    var at = local_midnight + (days * 24 * 60 + m) * 60_000;
    if (at <= now) at += 86_400_000;
    return at;
}

fn defaultCustomTime() []const u8 {
    const c = sys.local(sys.now() + 3_600_000);
    return std.fmt.allocPrint(tmp(), "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ @as(u32, @intCast(c.year)), c.month, c.day, c.hour, c.minute }) catch "";
}

/// "2026-10-12 21:30" (local time) to ms.
pub fn parseLocal(s: []const u8) ?i64 {
    if (s.len < 16) return null;
    const num = struct {
        fn f(x: []const u8) ?u32 {
            return std.fmt.parseInt(u32, x, 10) catch null;
        }
    }.f;
    const y = num(s[0..4]) orelse return null;
    const mo = num(s[5..7]) orelse return null;
    const d = num(s[8..10]) orelse return null;
    const h = num(s[11..13]) orelse return null;
    const mi = num(s[14..16]) orelse return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59) return null;
    const local_ms = (sys.daysFromCivil(@intCast(y), mo, d) * 86400 + @as(i64, h) * 3600 + @as(i64, mi) * 60) * 1000;
    return local_ms - @as(i64, sys.tzOffsetMin(local_ms)) * 60_000;
}

fn sendPoll(s: *State) void {
    const c = &s.compose;
    const a = tmp();
    const q = s.fields.get(.poll_question).trimmed();
    if (q.len == 0) return app.toastError(s, t("Ask a question"));
    var opts: std.ArrayList([]const u8) = .empty;
    var correct: ?usize = null;
    for (poll_fields[0..c.poll_options], 0..) |f, i| {
        const v = s.fields.get(f).trimmed();
        if (v.len == 0) continue;
        if (c.poll_quiz and i == c.poll_correct) correct = opts.items.len;
        opts.append(a, a.dupe(u8, v) catch continue) catch {};
    }
    if (opts.items.len < 2) return app.toastError(s, t("Add at least two options."));
    s.modal = null;
    draft(s, .{ .poll = .{
        .question = a.dupe(u8, q) catch return,
        .options = opts.items,
        .multiple = c.poll_multiple and !c.poll_quiz,
        .quiz = c.poll_quiz,
        .anonymous = c.poll_anonymous,
        .correct = if (c.poll_quiz) correct orelse 0 else null,
        .explanation = if (c.poll_quiz) (a.dupe(u8, s.fields.get(.poll_explanation).trimmed()) catch "") else "",
    } });
}

// ---------------------------------------------------------------------------------------------
// @mentions

/// The "@word" being typed at the end of the composer, if any.
pub fn mentionQuery(s: *const State) ?[]const u8 {
    const text = s.fields.get(.composer).get();
    const at = std.mem.lastIndexOfScalar(u8, text, '@') orelse return null;
    if (at > 0 and !std.ascii.isWhitespace(text[at - 1])) return null;
    const q = text[at + 1 ..];
    if (q.len > 32) return null;
    for (q) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return null;
    return q;
}

fn pickMention(s: *State, uid: []const u8) void {
    const field = s.fields.getPtr(.composer);
    const text = field.get();
    const at = std.mem.lastIndexOfScalar(u8, text, '@') orelse return;
    const u = s.store.user(uid) orelse return;
    const name = if (u.s("username")) |un| std.fmt.allocPrint(tmp(), "@{s} ", .{un}) catch return else std.fmt.allocPrint(tmp(), "{s} ", .{s.store.userName(u)}) catch return;
    const next = std.fmt.allocPrint(tmp(), "{s}{s}", .{ text[0..at], name }) catch return;
    field.set(next);
    app.fx.focus(zui.key("composer"));
}

// ---------------------------------------------------------------------------------------------
// Link previews

/// The composer changed: look for a link a little later.
pub fn typed(s: *State) void {
    if (!s.prefs.link_previews or s.editing.isSet()) return;
    s.compose.preview_seq += 1;
    app.fx.after(600, .{ .compose = .{ .preview_due = s.compose.preview_seq } });
}

fn fetchPreview(s: *State) void {
    const c = &s.compose;
    const url = markdown.firstUrl(s.fields.get(.composer).get()) orelse {
        if (c.preview) |p| p.destroy();
        c.preview = null;
        return;
    };
    if (std.mem.eql(u8, url, c.preview_dismissed.get())) return;
    if (c.preview) |p| if (std.mem.eql(u8, p.s("url") orelse "", url)) return;
    app.api(s, .GET, std.fmt.allocPrint(tmp(), "/link-preview?url={s}", .{j.urlEncode(tmp(), url) catch return}) catch return, null, .{ .link_preview = c.preview_seq });
}

// ---------------------------------------------------------------------------------------------
// Emoji

fn emojiAt(s: *const State, cat: u8, i: u16) ?[]const u8 {
    if (cat == 255) {
        if (i < s.compose.recent.items.len) return s.compose.recent.items[i];
        return null;
    }
    if (cat == 254) {
        if (i < emoji.keywords.len) return emoji.keywords[i].emoji;
        return null;
    }
    if (cat >= emoji.categories.len) return null;
    const list = emoji.categories[cat].list;
    return if (i < list.len) list[i] else null;
}

fn loadRecent(s: *State) void {
    if (s.compose.recent.items.len > 0) return;
    const raw = zui.storage.get(tmp(), "recentEmoji", .{}) orelse "";
    const v = j.parse(tmp(), raw);
    if (v) |val| if (val == .array) for (val.array.items) |x| {
        if (x == .string) s.compose.recent.append(gpa, gpa.dupe(u8, x.string) catch continue) catch {};
    };
    if (s.compose.recent.items.len == 0) for ([_][]const u8{ "👍", "❤️", "😂", "🔥", "🙏", "😍", "🎉", "😊" }) |e| {
        s.compose.recent.append(gpa, gpa.dupe(u8, e) catch continue) catch {};
    };
}

fn remember(s: *State, e: []const u8) void {
    const r = &s.compose.recent;
    for (r.items, 0..) |x, i| if (std.mem.eql(u8, x, e)) {
        gpa.free(r.orderedRemove(i));
        break;
    };
    r.insert(gpa, 0, gpa.dupe(u8, e) catch return) catch return;
    while (r.items.len > 32) gpa.free(r.pop().?);
    zui.storage.set("recentEmoji", j.stringify(tmp(), r.items) catch return, .{});
}

/// Emoji whose search words start with `q`.
pub fn search(a: std.mem.Allocator, q: []const u8) []const u16 {
    var out: std.ArrayList(u16) = .empty;
    if (q.len == 0) return out.items;
    for (emoji.keywords, 0..) |k, i| {
        var it = std.mem.tokenizeScalar(u8, k.words, ' ');
        while (it.next()) |w| if (std.ascii.startsWithIgnoreCase(w, q)) {
            out.append(a, @intCast(i)) catch {};
            break;
        };
        if (out.items.len >= 60) break;
    }
    return out.items;
}

// ---------------------------------------------------------------------------------------------
// Scheduled messages

pub fn loadScheduled(s: *State) void {
    if (!s.open_chat.isSet()) return;
    app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/{s}/messages/scheduled", .{s.open_chat.str()}) catch return, null, .scheduled_list);
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const v = j.parse(tmp(), r.body);
    switch (op) {
        .link_preview => |seq| {
            if (seq != s.compose.preview_seq or !r.ok()) return true;
            const p = j.obj(v, "preview") orelse return true;
            if (s.compose.preview) |old| old.destroy();
            s.compose.preview = data.Obj.create(p) catch null;
        },
        .scheduled_list => {
            if (!r.ok()) return true;
            // Encrypted ones: their words decrypted here for the list ("text").
            for (j.arr(v, "messages")) |*m| if (j.obj(m.*, "enc") != null and m.* == .object) {
                m.object.put(tmp(), "text", .{ .string = scheduledText(s, m.*) }) catch {};
            };
            if (s.compose.scheduled) |old| old.destroy();
            s.compose.scheduled = data.Obj.create(v orelse return true) catch null;
        },
        .scheduled_changed => {
            if (!r.ok()) app.toastError(s, app.apiError(r).message);
            loadScheduled(s);
        },
        else => return false,
    }
    return true;
}

/// The words of a scheduled message (decrypted when needed).
pub fn scheduledText(s: *State, raw: j.Value) []const u8 {
    const m = data.newMessage(raw) catch return "";
    defer m.destroy();
    keys.hydrate(s, s.open_chat.str(), m);
    return tmp().dupe(u8, @import("text.zig").summary(s, m, true)) catch "";
}
