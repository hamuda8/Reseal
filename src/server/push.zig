//! Web Push notifications (src/services/push.js). Message encryption (RFC 8291) and VAPID
//! signing (RFC 8292) come from zig-core's push module.
//!
//! For end-to-end encrypted chats the push carries the encrypted envelope (when small enough);
//! the service worker decrypts it on the device with the stored chat key, so push services and
//! Reseal's server never see the text. A subscription made by the embedded widget carries openUrl:
//! the page on the host site that the notification opens.

const std = @import("std");
const corepush = @import("push");
const A = @import("app.zig");

const rt = @import("realtime.zig");
const events = @import("events.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

pub fn pushEnabled() bool {
    return A.app.config.vapid_public.len > 0 and A.app.config.vapid_private.len > 0;
}

fn col() *A.Cols {
    return &A.app.col;
}

fn vapidHeader(a: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(endpoint);
    var hbuf: [256]u8 = undefined;
    const host = try (uri.host orelse return error.BadEndpoint).toRaw(&hbuf);
    // The audience is the endpoint's origin (with a port when it has one), as `new URL().origin`.
    const default_port: u16 = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80;
    const origin = if (uri.port != null and uri.port.? != default_port) try std.fmt.allocPrint(a, "{s}://{s}:{d}", .{ uri.scheme, host, uri.port.? }) else try std.fmt.allocPrint(a, "{s}://{s}", .{ uri.scheme, host });
    const claims = try val.stringify(a, try val.from(a, .{ .aud = origin, .exp = @divFloor(A.nowMs(), 1000) + 12 * 3600, .sub = A.app.config.vapid_subject }));
    const raw = try A.lenientBase64(a, A.app.config.vapid_private);
    if (raw.len != 32) return error.BadVapidKey;
    const token = try corepush.jwt.es256(a, claims, raw[0..32].*);
    return std.fmt.allocPrint(a, "vapid t={s}, k={s}", .{ token, A.app.config.vapid_public });
}

/// Sends one push; drops the subscription when the push service says it is gone.
pub fn sendPush(r: *Rq, sub: Val, payload: Val, ttl: u32) !u16 {
    const a = r.a;
    const endpoint = sub.get("endpoint").asStr() orelse return error.BadSubscription;
    const plain = try val.stringify(a, payload);
    const body = try corepush.encrypt(a, A.app.io, .{
        .endpoint = endpoint,
        .p256dh = try toUrlSafe(a, sub.path("keys.p256dh").asStr() orelse ""),
        .auth = try toUrlSafe(a, sub.path("keys.auth").asStr() orelse ""),
    }, plain, null);
    var ttl_buf: [16]u8 = undefined;
    const res = try A.app.fetch.fetch(a, endpoint, .{
        .method = .POST,
        .body = body,
        .content_type = "application/octet-stream",
        .timeout_ms = 10_000,
        .headers = &.{
            .{ .name = "TTL", .value = try std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl}) },
            .{ .name = "Urgency", .value = "high" },
            .{ .name = "Content-Encoding", .value = "aes128gcm" },
            .{ .name = "Authorization", .value = try vapidHeader(a, endpoint) },
        },
    });
    if (res.status == 404 or res.status == 410) _ = try col().pushSubs.deleteOne(a, .{ .endpoint = endpoint });
    return res.status;
}

/// Keys may arrive base64 or base64url; zig-core wants base64url without padding.
fn toUrlSafe(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try a.alloc(u8, s.len);
    var n: usize = 0;
    for (s) |c| {
        if (c == '=') continue;
        out[n] = switch (c) {
            '+' => '-',
            '/' => '_',
            else => c,
        };
        n += 1;
    }
    return out[0..n];
}

fn pushToUsers(r: *Rq, user_ids: []const Val, payload: Val, ttl: u32) !void {
    const a = r.a;
    if (!pushEnabled() or user_ids.len == 0) return;
    const subs = try col().pushSubs.find(a, .{ .userId = .{ .@"$in" = user_ids } }, .{});
    for (subs) |sub| {
        var p = payload;
        if (sub.get("openUrl").truthy()) {
            p = try val.clone(a, payload);
            try p.set("openUrl", sub.get("openUrl"));
        }
        _ = sendPush(r, sub, p, ttl) catch {};
    }
}

fn previewOf(m: Val) Val {
    if (m.get("text").truthy()) return .{ .str = @import("validate.zig").sliceUtf16(m.get("text").str, 160) };
    if (m.get("media").len() > 0) {
        const kind = m.get("media").items()[0].get("kind").asStr() orelse "";
        const names = [_][2][]const u8{ .{ "photo", "📷 Photo" }, .{ "video", "🎬 Video" }, .{ "voice", "🎤 Voice message" }, .{ "round", "📹 Video message" }, .{ "file", "📎 File" }, .{ "audio", "🎵 Audio" }, .{ "gif", "GIF" }, .{ "sticker", "Sticker" } };
        for (names) |x| if (std.mem.eql(u8, x[0], kind)) return .{ .str = x[1] };
        return Val.string("Media");
    }
    return .undef;
}

fn previewText(a: std.mem.Allocator, m: Val) !Val {
    const p = previewOf(m);
    if (p != .undef) return p;
    if (m.get("poll").truthy()) return .{ .str = try std.fmt.allocPrint(a, "📊 {s}", .{m.path("poll.question").asStr() orelse "Poll"}) };
    if (m.get("location").truthy()) return Val.string("📍 Location");
    if (m.get("contact").truthy()) return Val.string("👤 Contact");
    if (m.get("sticker").truthy()) return .{ .str = try std.fmt.allocPrint(a, "{s} Sticker", .{m.path("sticker.emoji").asStr() orelse ""}) };
    return Val.string("New message");
}

fn eq(x: Val, s: []const u8) bool {
    return x == .str and std.mem.eql(u8, x.str, s);
}

pub fn onEvent(r: *Rq, kind: events.Kind, p: Val) !void {
    switch (kind) {
        .message_created => try onMessage(r, p.get("chat"), p.get("message"), p.get("sender")),
        .call_incoming => {
            if (!pushEnabled()) return;
            const callee = p.get("calleeId");
            if (rt.isOnline(callee) and !rt.isAway(callee)) return;
            try pushToUsers(r, &.{callee}, try val.from(r.a, .{
                .type = "call",
                .callId = p.get("callId"),
                .chatId = p.get("chatId"),
                .title = p.get("callerName"),
                .body = if (p.get("video").isTrue()) "Incoming video call" else "Incoming voice call",
            }), 45);
        },
        else => {},
    }
}

fn onMessage(r: *Rq, chat: Val, message: Val, sender: Val) !void {
    const a = r.a;
    if (!pushEnabled() or (eq(message.get("kind"), "service") and !message.path("service.notify").truthy())) return;
    if (eq(chat.get("type"), "channel") and (chat.get("memberCount").asInt() orelse 0) > 5000) return;
    const now = A.now();
    // Reminders in Saved chats go to the person who set them; everything else to the others.
    const sender_id: Val = if (sender.truthy()) sender.get("_id") else .null;
    const user_filter: Val = if (message.get("reminder").truthy() and sender.truthy()) sender_id else try val.from(a, .{ .@"$ne" = sender_id });
    const members = try col().members.find(a, .{
        .chatId = chat.get("_id"),
        .status = "active",
        .userId = user_filter,
        .@"$or" = .{ .{ .mutedUntil = Val.null }, .{ .mutedUntil = .{ .@"$exists" = false } }, .{ .mutedUntil = .{ .@"$lt" = now } } },
    }, .{ .projection = .{ .userId = 1, .locked = 1 }, .limit = 5000 });
    // People looking at Reseal right now get an in-app notification instead.
    var targets: std.ArrayList(Val) = .empty;
    for (members) |m| if (!rt.isOnline(m.get("userId")) or rt.isAway(m.get("userId"))) try targets.append(a, m.get("userId"));
    if (targets.items.len == 0) return;
    const sender_name: Val = if (sender.get("displayName").truthy()) sender.get("displayName") else Val.string("Reseal");
    const pair = eq(chat.get("type"), "private") or eq(chat.get("type"), "bot");
    const reminder = message.get("reminder").truthy();
    const title: Val = if (reminder)
        .{ .str = try std.fmt.allocPrint(a, "Reminder · {s}", .{if (chat.get("title").truthy()) chat.get("title").str else "Saved"}) }
    else if (pair) sender_name else (if (chat.get("title").truthy()) chat.get("title") else Val.string("Reseal"));
    const payload = try val.from(a, .{
        .type = "message",
        .chatId = try r.str(chat.get("_id")),
        .messageId = try r.str(message.get("_id")),
        .seq = message.get("seq"),
        .title = title,
        .sender = if (pair or reminder) Val.null else sender_name,
        .senderId = if (sender.truthy()) Val{ .str = try r.str(sender.get("_id")) } else Val.null,
        .silent = message.get("silent").truthy(),
        .encrypted = chat.get("encrypted").truthy(),
    });
    const service = eq(message.get("kind"), "service");
    if (chat.get("encrypted").truthy()) {
        const enc = message.get("enc");
        if (enc.truthy() and (enc.get("ct").asStr() orelse @as([]const u8, "")).len < 2400) try payload.set("enc", .{ .e = enc.get("e"), .s = enc.get("s"), .iv = enc.get("iv"), .ct = enc.get("ct"), .sig = enc.get("sig") });
        try payload.set("body", Val.string(if (service) "New activity" else "New message"));
    } else {
        try payload.set("body", if (service) Val.string("New activity") else try previewText(a, message));
    }
    const hide = try col().users.find(a, .{ ._id = .{ .@"$in" = targets.items }, .@"settings.notifyPreview" = false }, .{ .projection = .{ ._id = 1 } });
    var plain: std.ArrayList(Val) = .empty;
    var masked: std.ArrayList(Val) = .empty;
    var secret: std.ArrayList(Val) = .empty;
    for (targets.items) |t| {
        var locked = false;
        for (members) |m| if (val.same(m.get("userId"), t) and m.get("locked").truthy()) {
            locked = true;
        };
        var hidden = false;
        for (hide) |h| if (val.same(h.get("_id"), t)) {
            hidden = true;
        };
        if (locked) try secret.append(a, t) else if (hidden) try masked.append(a, t) else try plain.append(a, t);
    }
    try pushToUsers(r, plain.items, payload, 86400);
    if (masked.items.len > 0) {
        const m = try val.clone(a, payload);
        try m.set("body", "New message");
        try m.set("enc", .undef);
        try m.set("sender", .null);
        try pushToUsers(r, masked.items, m, 86400);
    }
    if (secret.items.len > 0) {
        // Locked chats notify without saying who wrote or what.
        const m = try val.clone(a, payload);
        try m.set("title", "Reseal");
        try m.set("body", "New message");
        try m.set("enc", .undef);
        try m.set("sender", .null);
        try m.set("locked", true);
        try pushToUsers(r, secret.items, m, 86400);
    }
}

fn httpOpenUrl(s: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, s, "https://")) s[8..] else if (std.mem.startsWith(u8, s, "http://")) s[7..] else return false;
    if (rest.len < 1 or rest.len > 480) return false;
    for (rest) |c| if (std.ascii.isWhitespace(c)) return false;
    return true;
}

pub fn subscribe(r: *Rq, user: Val, body: Val) !void {
    const a = r.a;
    const endpoint = try r.str(if (body.get("endpoint").truthy()) body.get("endpoint") else Val.string(""));
    const p256dh = try r.str(if (body.path("keys.p256dh").truthy()) body.path("keys.p256dh") else Val.string(""));
    const auth = try r.str(if (body.path("keys.auth").truthy()) body.path("keys.auth") else Val.string(""));
    const local_ok = A.app.config.allow_private_fetch and (std.mem.startsWith(u8, endpoint, "http://localhost:") or std.mem.startsWith(u8, endpoint, "http://localhost/") or std.mem.startsWith(u8, endpoint, "http://127.0.0.1:") or std.mem.startsWith(u8, endpoint, "http://127.0.0.1/"));
    if ((!std.mem.startsWith(u8, endpoint, "https://") and !local_ok) or endpoint.len > 1000 or p256dh.len == 0 or auth.len == 0) return r.fail(400, "Invalid push subscription", null);
    const set = try val.from(a, .{ .userId = user.get("_id"), .endpoint = endpoint, .keys = .{ .p256dh = p256dh, .auth = auth }, .updatedAt = A.now() });
    const unset = try Val.object(a);
    // Widgets say which page of the host site a notification opens; the Reseal app opens itself.
    if (body.get("openUrl").truthy()) {
        const open = try r.str(body.get("openUrl"));
        if (!httpOpenUrl(open)) return r.fail(400, "openUrl must be an http(s) address", null);
        try set.set("openUrl", open);
    } else try unset.set("openUrl", "");
    const update = try val.from(a, .{ .@"$set" = set, .@"$setOnInsert" = .{ .createdAt = A.now() } });
    if (unset.len() > 0) try update.set("$unset", unset);
    _ = try col().pushSubs.updateOne(a, .{ .endpoint = endpoint }, update, .{ .upsert = true });
}

pub fn unsubscribe(r: *Rq, user: Val, endpoint: Val) !void {
    _ = try col().pushSubs.deleteOne(r.a, .{ .endpoint = try r.str(if (endpoint.truthy()) endpoint else Val.string("")), .userId = user.get("_id") });
}
