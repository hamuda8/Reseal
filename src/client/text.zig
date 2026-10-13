//! Human-readable text for messages: list previews, notifications, service notices, typing and
//! presence. Port of Reseal-js ui/text.js and format.js presenceText.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const fmt = @import("fmt.zig");

const State = app.State;
const t = zui.i18n.t;
const tmp = app.tmp;

fn nameOf(s: *const State, id: []const u8) []const u8 {
    return if (s.store.isMe(id)) t("You") else s.store.displayName(id);
}

fn mediaLabel(kind: []const u8) []const u8 {
    const map = .{ .{ "photo", "Photo" }, .{ "video", "Video" }, .{ "file", "File" }, .{ "voice", "Voice message" }, .{ "round", "Video message" }, .{ "audio", "Audio" }, .{ "sticker", "Sticker" } };
    inline for (map) |kv| if (std.mem.eql(u8, kind, kv[0])) return t(kv[1]);
    if (std.mem.eql(u8, kind, "gif")) return "GIF";
    return t("Media");
}

fn mediaEmoji(kind: []const u8) []const u8 {
    const map = .{ .{ "photo", "🖼" }, .{ "video", "📹" }, .{ "file", "📎" }, .{ "voice", "🎤" }, .{ "round", "📹" }, .{ "audio", "🎵" }, .{ "gif", "🎞" } };
    inline for (map) |kv| if (std.mem.eql(u8, kind, kv[0])) return kv[1];
    return "";
}

/// One line describing a message (chat list, notifications, reply quotes).
pub fn summary(s: *const State, m: *const data.Message, with_emoji: bool) []const u8 {
    const a = tmp();
    if (m.deleted()) return t("Deleted message");
    if (m.isService()) return serviceText(s, m);
    switch (m.decrypt) {
        .pending => return t("Decrypting…"),
        .nokey => return std.fmt.allocPrint(a, "🔒 {s}", .{t("Waiting for encryption key")}) catch "",
        .failed => return std.fmt.allocPrint(a, "⚠️ {s}", .{t("Message could not be decrypted")}) catch "",
        .ok => {},
    }
    const c = m.content orelse return "";
    if (j.obj(c, "sticker")) |st| return std.fmt.allocPrint(a, "{s} {s}", .{ j.strOr(st, "emoji", ""), t("Sticker") }) catch "";
    if (j.obj(c, "poll")) |p| return std.fmt.allocPrint(a, "📊 {s}", .{j.str(p, "question") orelse t("Poll")}) catch "";
    if (j.obj(c, "location")) |l| return std.fmt.allocPrint(a, "📍 {s}", .{j.str(l, "title") orelse t("Location")}) catch "";
    if (j.obj(c, "contact")) |ct| return std.fmt.allocPrint(a, "👤 {s}", .{j.strOr(ct, "name", "")}) catch "";
    const media = j.arr(c, "media");
    const txt = j.strOr(c, "text", "");
    if (media.len > 0) {
        const kind = j.strOr(media[0], "kind", "file");
        var same = true;
        for (media) |x| if (!std.mem.eql(u8, j.strOr(x, "kind", ""), kind)) {
            same = false;
        };
        const n: i64 = @intCast(media.len);
        const label = if (media.len > 1 and same)
            (if (std.mem.eql(u8, kind, "photo")) fmt.tn(a, n, "{n} photo", "{n} photos") else if (std.mem.eql(u8, kind, "video")) fmt.tn(a, n, "{n} video", "{n} videos") else fmt.tn(a, n, "{n} file", "{n} files"))
        else if (std.mem.eql(u8, kind, "file") and j.str(media[0], "name") != null)
            j.str(media[0], "name").?
        else
            mediaLabel(kind);
        const emoji = mediaEmoji(kind);
        const prefix = if (with_emoji and emoji.len > 0) std.fmt.allocPrint(a, "{s} ", .{emoji}) catch "" else "";
        return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, if (txt.len > 0) fmt.plain(a, txt, 100) else label }) catch "";
    }
    return fmt.plain(a, txt, 140);
}

/// Text of a service notice.
pub fn serviceText(s: *const State, m: *const data.Message) []const u8 {
    const a = tmp();
    const sv = j.obj(m.o.v, "service");
    const action = j.strOr(sv, "action", "");
    const actor = if (j.str(sv, "actorId")) |id| nameOf(s, id) else "";
    var targets: std.ArrayList(u8) = .empty;
    for (j.arr(sv, "targetIds"), 0..) |x, i| {
        if (x != .string) continue;
        if (i > 0) targets.appendSlice(a, ", ") catch {};
        targets.appendSlice(a, nameOf(s, x.string)) catch {};
    }
    const title = j.strOr(sv, "title", "");
    const eq = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.f;
    if (eq(action, "group_created")) return fmt.tf("{actor} created the group “{title}”", .{ .actor = actor, .title = title });
    if (eq(action, "channel_created")) return t("Channel created");
    if (eq(action, "members_added")) return fmt.tf("{actor} added {targets}", .{ .actor = actor, .targets = targets.items });
    if (eq(action, "member_removed")) return fmt.tf("{actor} removed {targets}", .{ .actor = actor, .targets = targets.items });
    if (eq(action, "joined")) return if (j.eqlStr(sv, "via", "invite")) fmt.tf("{actor} joined the group via invite link", .{ .actor = actor }) else fmt.tf("{actor} joined the group", .{ .actor = actor });
    if (eq(action, "left")) return fmt.tf("{actor} left the group", .{ .actor = actor });
    if (eq(action, "title_changed")) return fmt.tf("{actor} changed the group name to “{title}”", .{ .actor = actor, .title = title });
    if (eq(action, "avatar_changed")) return fmt.tf("{actor} updated the group photo", .{ .actor = actor });
    if (eq(action, "avatar_removed")) return fmt.tf("{actor} removed the group photo", .{ .actor = actor });
    if (eq(action, "pinned")) return fmt.tf("{actor} pinned a message", .{ .actor = actor });
    if (eq(action, "ttl_changed")) {
        const ttl = j.intOr(sv, "ttl", 0);
        if (ttl > 0) return fmt.tf("{actor} set messages to disappear after {time}", .{ .actor = actor, .time = fmt.longDuration(a, ttl) });
        return fmt.tf("{actor} turned off disappearing messages", .{ .actor = actor });
    }
    if (eq(action, "ownership_transferred")) return fmt.tf("{actor} made {targets} the owner", .{ .actor = actor, .targets = targets.items });
    if (eq(action, "group_call_started")) return if (j.truthy(sv, "video")) fmt.tf("{actor} started a video chat", .{ .actor = actor }) else fmt.tf("{actor} started a voice chat", .{ .actor = actor });
    if (eq(action, "group_call_ended")) return fmt.tf("Voice chat ended ({duration})", .{ .duration = fmt.duration(a, j.float(sv, "duration") orelse 0) });
    if (eq(action, "keys_changed")) return fmt.tf("{actor}'s security key changed", .{ .actor = actor });
    if (eq(action, "call")) {
        const outgoing = s.store.isMe(j.strOr(sv, "actorId", ""));
        const kind = if (j.truthy(sv, "video")) t("video call") else t("call");
        const result = j.strOr(sv, "result", "");
        if (eq(result, "missed")) return if (outgoing) fmt.tf("Cancelled {kind}", .{ .kind = kind }) else fmt.tf("Missed {kind}", .{ .kind = kind });
        if (eq(result, "declined")) return fmt.tf("Declined {kind}", .{ .kind = kind });
        if (eq(result, "busy")) return t("Busy");
        const head = if (outgoing) fmt.tf("Outgoing {kind}", .{ .kind = kind }) else fmt.tf("Incoming {kind}", .{ .kind = kind });
        return std.fmt.allocPrint(a, "{s} ({s})", .{ head, fmt.duration(a, j.float(sv, "duration") orelse 0) }) catch head;
    }
    return t("Something happened");
}

fn verb(action: []const u8) []const u8 {
    const map = .{
        .{ "typing", "typing" },                      .{ "recording_voice", "recording a voice message" }, .{ "recording_video", "recording a video" },
        .{ "uploading_photo", "sending a photo" },    .{ "uploading_video", "sending a video" },           .{ "uploading_file", "sending a file" },
        .{ "choosing_sticker", "choosing a sticker" },
    };
    inline for (map) |kv| if (std.mem.eql(u8, action, kv[0])) return t(kv[1]);
    return t("typing");
}

/// "typing…", "Sara typing…", "Sara and Omar are typing…", or "" when nobody is.
pub fn typingText(s: *const State, c: *const data.Chat) []const u8 {
    const a = tmp();
    const now = sys.now();
    var who: [3]*const data.Typing = undefined;
    var n: usize = 0;
    for (c.typing.items) |*e| {
        if (e.until <= now or s.store.isMe(e.user.str())) continue;
        if (n < 3) who[n] = e;
        n += 1;
    }
    if (n == 0) return "";
    const action = who[0].action[0..who[0].action_len];
    if (!s.store.showsSenderNames(c)) return std.fmt.allocPrint(a, "{s}…", .{verb(action)}) catch "";
    const first = fmt.firstName(s.store.displayName(who[0].user.str()));
    if (n == 1) return std.fmt.allocPrint(a, "{s} {s}…", .{ first, verb(action) }) catch "";
    if (n == 2) return fmt.tf("{a} and {b} are typing…", .{ .a = first, .b = fmt.firstName(s.store.displayName(who[1].user.str())) });
    return fmt.tn(a, @intCast(n), "{n} person is typing…", "{n} people are typing…");
}

/// "online", "last seen 5 minutes ago", ...
pub fn presenceText(presence: ?j.Value) []const u8 {
    const a = tmp();
    const p = presence orelse return "";
    const status = j.strOr(p, "status", "");
    const eq = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.f;
    if (eq(status, "online")) return t("online");
    if (eq(status, "bot")) return t("bot");
    if (eq(status, "recently")) return t("last seen recently");
    if (eq(status, "within_week")) return t("last seen within a week");
    if (eq(status, "within_month")) return t("last seen within a month");
    if (eq(status, "long_ago")) return t("last seen a long time ago");
    if (eq(status, "offline")) {
        const at = sys.parseIso(j.strOr(p, "lastSeenAt", "")) orelse return t("last seen recently");
        const now = sys.now();
        const ago = now - at;
        if (ago < 60_000) return t("last seen just now");
        if (ago < 3_600_000) return fmt.tn(a, @divTrunc(ago, 60_000), "last seen {n} minute ago", "last seen {n} minutes ago");
        if (fmt.sameDay(at, now)) return fmt.tf("last seen at {time}", .{ .time = fmt.time(a, at) });
        if (fmt.sameDay(at, now - 86_400_000)) return fmt.tf("last seen yesterday at {time}", .{ .time = fmt.time(a, at) });
        return fmt.tf("last seen {date}", .{ .date = fmt.shortDate(a, at) });
    }
    return "";
}

/// "Chrome on Windows" from a user agent (security.restore).
pub fn deviceName(ua: []const u8) []const u8 {
    const has = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.indexOf(u8, x, y) != null;
        }
    }.f;
    const browser = if (has(ua, "Edg/")) "Edge" else if (has(ua, "OPR/")) "Opera" else if (has(ua, "Chrome/")) "Chrome" else if (has(ua, "Firefox/")) "Firefox" else if (has(ua, "Safari/")) "Safari" else t("a browser");
    const os = if (has(ua, "Windows")) "Windows" else if (has(ua, "Android")) "Android" else if (has(ua, "iPhone") or has(ua, "iPad")) "iOS" else if (has(ua, "Mac OS")) "macOS" else if (has(ua, "Linux")) "Linux" else "";
    if (os.len == 0) return browser;
    return fmt.tf("{browser} on {os}", .{ .browser = browser, .os = os });
}
