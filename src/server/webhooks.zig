//! Webhooks for apps that integrate Reseal (src/services/webhooks.js). Every event is stored,
//! then delivered by a background worker with retries. Requests carry
//! "Reseal-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256 of `${t}.${body}`>" made with the app's
//! webhook secret, so receivers can verify they came from Reseal.

const std = @import("std");
const Io = std.Io;
const A = @import("app.zig");
const fetch = @import("lib/fetch.zig");
const ser = @import("serialize.zig");
const events = @import("events.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

const BACKOFF_MS = [_]i64{ 60_000, 5 * 60_000, 30 * 60_000, 2 * 3600_000, 6 * 3600_000, 12 * 3600_000 };

pub const WEBHOOK_EVENTS = [_][]const u8{
    "message.created", "message.edited", "message.deleted", "message.reaction",
    "chat.created",    "chat.updated",   "chat.deleted",    "member.joined",
    "member.left",     "call.started",   "call.ended",      "support.handoff",
    "button.pressed",
};

fn col() *A.Cols {
    return &A.app.col;
}

/// Kept for parity with Reseal-js's cache; apps are read fresh on each event here.
pub fn forgetApp(_: Val) void {}

fn externalIds(r: *Rq, user_ids: []const Val) ![]Val {
    var ids: std.ArrayList(Val) = .empty;
    for (user_ids) |x| if (x.truthy()) try ids.append(r.a, x);
    if (ids.items.len == 0) return &.{};
    return col().users.find(r.a, .{ ._id = .{ .@"$in" = ids.items } }, .{ .projection = .{ .externalId = 1, .kind = 1 } });
}

fn extOf(users: []const Val, id: Val) Val {
    for (users) |u| if (val.same(u.get("_id"), id)) return if (u.get("externalId").truthy()) u.get("externalId") else Val.null;
    return .undef;
}

fn chatPayload(r: *Rq, chat: Val) !Val {
    const a = r.a;
    const out = try val.from(a, .{
        .id = try r.sn(chat.get("_id")),
        .type = chat.get("type"),
        .externalId = if (chat.get("externalId").truthy()) chat.get("externalId") else Val.null,
        .title = if (chat.get("title").truthy()) chat.get("title") else Val.null,
        .encrypted = chat.get("encrypted").truthy(),
        .metadata = if (chat.get("metadata").truthy()) chat.get("metadata") else Val.null,
    });
    if (chat.get("teamId").truthy()) {
        try out.set(a, "team", .{ .id = try r.sn(chat.get("teamId")), .externalId = if (chat.get("teamExternalId").truthy()) chat.get("teamExternalId") else Val.null });
        try out.set(a, "visitor", .{ .id = try r.sn(chat.get("visitorId")), .externalId = if (chat.get("visitorExternalId").truthy()) chat.get("visitorExternalId") else Val.null });
    }
    return out;
}

fn messagePayload(r: *Rq, chat: Val, message: Val) !Val {
    const a = r.a;
    const ext = try externalIds(r, &.{message.get("senderId")});
    const out = try ser.message(a, message, .null, chat);
    out.del("enc"); // never forward ciphertext; it is useless to the receiver
    const e = extOf(ext, message.get("senderId"));
    try out.put(a, "sender", if (message.get("senderId").truthy()) try val.from(a, .{ .id = try r.sn(message.get("senderId")), .externalId = if (e.truthy()) e else Val.null }) else Val.null);
    if (chat.get("encrypted").truthy()) try out.set(a, "encrypted", true);
    return out;
}

pub fn enqueue(r: *Rq, app_id: Val, event: []const u8, data: Val) !void {
    const a = r.a;
    const app_doc = (try col().apps.findOne(a, .{ ._id = app_id }, .{ .projection = .{ .webhook = 1, .disabled = 1 } })) orelse return;
    const wh = app_doc.get("webhook");
    if (app_doc.get("disabled").truthy() or !wh.get("enabled").truthy() or !wh.get("url").truthy()) return;
    if (wh.get("events").len() > 0) {
        var on = false;
        for (wh.get("events").items()) |e| if (e == .str and std.mem.eql(u8, e.str, event)) {
            on = true;
        };
        if (!on) return;
    }
    const now = A.nowMs();
    const doc = try val.from(a, .{
        .appId = app_id,
        .event = event,
        .status = "pending",
        .attempts = 0,
        .nextAttemptAt = Val{ .date = now },
        .createdAt = Val{ .date = now },
        .payload = .{ .type = event, .createdAt = try val.isoDate(a, now), .appId = try r.sn(app_id), .data = data },
    });
    const id = try col().webhookDeliveries.insertOne(a, doc);
    _ = try col().webhookDeliveries.updateOne(a, .{ ._id = id }, .{ .@"$set" = .{ .@"payload.id" = try r.str(id) } }, .{});
    kick();
}

// ---- Event subscriptions --------------------------------------------------------------------

pub fn onEvent(r: *Rq, kind: events.Kind, p: Val) !void {
    const a = r.a;
    const chat = p.get("chat");
    switch (kind) {
        .call_started, .call_ended => {
            const call = p.get("call");
            const c = (try col().chats.findOne(a, .{ ._id = call.get("chatId") }, .{})) orelse return;
            if (!c.get("appId").truthy()) return;
            if (kind == .call_started) {
                try enqueue(r, c.get("appId"), "call.started", try val.from(a, .{ .chat = try chatPayload(r, c), .callId = try r.sn(call.get("id")), .video = call.get("video") }));
            } else {
                try enqueue(r, c.get("appId"), "call.ended", try val.from(a, .{ .chat = try chatPayload(r, c), .callId = try r.sn(call.get("id")), .video = call.get("video"), .status = call.get("status"), .duration = call.get("duration") }));
            }
            return;
        },
        else => {},
    }
    if (!chat.get("appId").truthy()) return;
    const app_id = chat.get("appId");
    switch (kind) {
        .message_created => try enqueue(r, app_id, "message.created", try val.from(a, .{ .chat = try chatPayload(r, chat), .message = try messagePayload(r, chat, p.get("message")) })),
        .message_edited => try enqueue(r, app_id, "message.edited", try val.from(a, .{ .chat = try chatPayload(r, chat), .message = try messagePayload(r, chat, p.get("message")) })),
        .message_deleted => {
            var ids = try Val.array(a);
            for (p.get("ids").items()) |x| try ids.push(a, try r.sn(x));
            try enqueue(r, app_id, "message.deleted", try val.from(a, .{ .chat = try chatPayload(r, chat), .messageIds = ids }));
        },
        .message_reaction => {
            const u = p.get("user");
            try enqueue(r, app_id, "message.reaction", try val.from(a, .{ .chat = try chatPayload(r, chat), .messageId = try r.sn(p.path("message._id")), .userId = try r.sn(u.get("_id")), .externalId = if (u.get("externalId").truthy()) u.get("externalId") else Val.null, .emoji = p.get("emoji"), .added = p.get("on") }));
        },
        .chat_created => {
            const ids = p.get("memberIds").items();
            const ext = try externalIds(r, ids);
            var members = try Val.array(a);
            for (ids) |id| try members.push(a, try val.from(a, .{ .id = try r.sn(id), .externalId = extOf(ext, id) }));
            try enqueue(r, app_id, "chat.created", try val.from(a, .{ .chat = try chatPayload(r, chat), .members = members }));
        },
        .chat_updated => try enqueue(r, app_id, "chat.updated", try val.from(a, .{ .chat = try chatPayload(r, chat), .changes = p.get("changes") })),
        .chat_deleted => try enqueue(r, app_id, "chat.deleted", try val.from(a, .{ .chat = try chatPayload(r, chat) })),
        .member_joined, .member_left => {
            const uid = p.get("userId");
            const ext = try externalIds(r, &.{uid});
            const user = try val.from(a, .{ .id = try r.sn(uid), .externalId = extOf(ext, uid) });
            if (kind == .member_joined) {
                try enqueue(r, app_id, "member.joined", try val.from(a, .{ .chat = try chatPayload(r, chat), .user = user }));
            } else {
                try enqueue(r, app_id, "member.left", try val.from(a, .{ .chat = try chatPayload(r, chat), .user = user, .reason = p.get("status") }));
            }
        },
        .button_pressed => {
            const u = p.get("user");
            try enqueue(r, app_id, "button.pressed", try val.from(a, .{ .chat = try chatPayload(r, chat), .messageId = try r.sn(p.get("messageId")), .user = .{ .id = try r.sn(u.get("_id")), .externalId = if (u.get("externalId").truthy()) u.get("externalId") else Val.null }, .data = p.get("data") }));
        },
        .support_handoff => {
            const u = p.get("user");
            try enqueue(r, app_id, "support.handoff", try val.from(a, .{ .chat = try chatPayload(r, chat), .visitor = .{ .id = try r.sn(u.get("_id")), .externalId = if (u.get("externalId").truthy()) u.get("externalId") else Val.null } }));
        },
        else => {},
    }
}

// ---- Delivery ---------------------------------------------------------------------------------

/// The Reseal-Signature header for a request body. Webhooks and storage calls are signed alike.
pub fn signature(a: std.mem.Allocator, secret: []const u8, body: []const u8) ![]const u8 {
    const t = @divFloor(A.nowMs(), 1000);
    const data = try std.fmt.allocPrint(a, "{d}.{s}", .{ t, body });
    return std.fmt.allocPrint(a, "t={d},v1={s}", .{ t, try A.hmacHex(a, secret, data) });
}

pub const Delivery = struct { ok: bool, status: u16, @"error": ?[]const u8 = null };

/// Sends one delivery now.
pub fn deliver(r: *Rq, url: []const u8, secret: ?[]const u8, payload: Val) !Delivery {
    const a = r.a;
    const body = try val.stringify(a, payload);
    fetch.assertPublicUrl(url) catch |e| return .{ .ok = false, .status = 0, .@"error" = fetch.urlErrorMessage(e) };
    const res = fetch.fetch(a, url, .{
        .method = .POST,
        .body = body,
        .content_type = "application/json",
        .user_agent = "Reseal-Webhooks/1.0",
        .headers = &.{
            .{ .name = "Reseal-Event", .value = payload.get("type").asStr() orelse "" },
            .{ .name = "Reseal-Delivery", .value = payload.get("id").asStr() orelse "" },
            .{ .name = "Reseal-Signature", .value = try signature(a, secret orelse "", body) },
        },
    }) catch |e| return .{ .ok = false, .status = 0, .@"error" = fetch.urlErrorMessage(e) };
    return .{ .ok = res.status >= 200 and res.status < 300, .status = res.status };
}

var wake: Io.Event = .unset;

pub fn kick() void {
    wake.set(A.app.io);
}

// Message content belongs in the app's own database, not in Reseal's delivery log: once a
// delivery is final (delivered, or out of retries), only the message id is kept.
fn redact(r: *Rq, job: Val, set: Val) !void {
    const m = job.path("payload.data.message");
    if (m.truthy()) try set.put(r.a, "payload.data.message", try val.from(r.a, .{ .id = m.get("id"), .redacted = true }));
}

fn work(r: *Rq) !void {
    const a = r.a;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const job = (try col().webhookDeliveries.findOneAndUpdate(a, .{ .status = "pending", .nextAttemptAt = .{ .@"$lte" = A.now() } }, .{ .@"$set" = .{ .status = "sending", .lockedAt = A.now() } }, .{ .sort = .{ .nextAttemptAt = 1 } })) orelse return;
        const app_doc = try col().apps.findOne(a, .{ ._id = job.get("appId") }, .{ .projection = .{ .webhook = 1 } });
        const url = if (app_doc) |d| d.path("webhook.url").asStr() orelse "" else "";
        if (url.len == 0) {
            _ = try col().webhookDeliveries.updateOne(a, .{ ._id = job.get("_id") }, .{ .@"$set" = .{ .status = "cancelled" } }, .{});
            continue;
        }
        const result = try deliver(r, url, A.unseal(a, app_doc.?.path("webhook.secretSealed")), job.get("payload"));
        const attempts = (job.get("attempts").asInt() orelse 0) + 1;
        if (result.ok) {
            const set = try val.from(a, .{ .status = "delivered", .attempts = attempts, .deliveredAt = A.now(), .lastStatus = result.status });
            try redact(r, job, set);
            _ = try col().webhookDeliveries.updateOne(a, .{ ._id = job.get("_id") }, .{ .@"$set" = set }, .{});
        } else {
            const delay: ?i64 = if (attempts - 1 < BACKOFF_MS.len) BACKOFF_MS[@intCast(attempts - 1)] else null;
            const set = try val.from(a, .{
                .status = if (delay != null) "pending" else "failed",
                .attempts = attempts,
                .lastStatus = result.status,
                .lastError = if (result.@"error") |e| Val{ .str = e } else Val.null,
                .nextAttemptAt = Val{ .date = A.nowMs() + (delay orelse 0) },
            });
            if (delay == null) try redact(r, job, set);
            _ = try col().webhookDeliveries.updateOne(a, .{ ._id = job.get("_id") }, .{ .@"$set" = set }, .{});
        }
    }
}

/// The delivery worker: recovers deliveries left "sending" by a crash, then delivers whenever
/// kicked, and every 15 s for retries.
pub fn workerLoop() void {
    {
        var arena = std.heap.ArenaAllocator.init(A.app.gpa);
        defer arena.deinit();
        _ = col().webhookDeliveries.updateMany(arena.allocator(), .{ .status = "sending", .lockedAt = .{ .@"$lt" = Val{ .date = A.nowMs() - 60_000 } } }, .{ .@"$set" = .{ .status = "pending" } }, .{}) catch {};
    }
    while (true) {
        wake.waitTimeout(A.app.io, .{ .duration = .{ .raw = .fromSeconds(15), .clock = .awake } }) catch |e| switch (e) {
            error.Canceled => return,
            error.Timeout => {},
        };
        wake.reset();
        var arena = std.heap.ArenaAllocator.init(A.app.gpa);
        defer arena.deinit();
        var r: Rq = .{ .a = arena.allocator() };
        work(&r) catch |e| std.log.err("Webhook worker: {t}", .{e});
    }
}
