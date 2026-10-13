//! Voice and video calls (src/services/calls.js).
//!
//! Media flows browser to browser over WebRTC (DTLS-SRTP), so the server never sees it; it only
//! relays signalling (offers, answers, ICE candidates) between connections. Group calls are a
//! full mesh of up to ten people. Live call state is in memory, as in Reseal-js.

const std = @import("std");
const Io = std.Io;
const A = @import("app.zig");
const rt = @import("realtime.zig");
const msgs = @import("messages.zig");
const access = @import("access.zig");
const events = @import("events.zig");
const v = @import("validate.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;
const Key = rt.Key;

const RING_MS = 45_000;
const MAX_GROUP = 10;

const Media = struct { audio: bool, video: bool, screen: bool };
const Participant = struct { conn_id: [36]u8, user_id: Key, media: Media };

const Call = struct {
    id: A.ObjectId,
    id_hex: [24]u8,
    chat_id: A.ObjectId,
    group: bool,
    video: bool,
    initiator_id: Key,
    ringing: bool,
    participants: std.ArrayList(Participant) = .empty,
    invited: std.ArrayList(Key) = .empty,
    started_at: ?i64 = null,
    ended: bool = false,
    /// Bumped whenever a timer is replaced, so an older timer does nothing.
    timer_gen: u32 = 0,
    refs: u32 = 1,

    fn find(c: *Call, conn_id: []const u8) ?*Participant {
        for (c.participants.items) |*p| if (std.mem.eql(u8, &p.conn_id, conn_id)) return p;
        return null;
    }

    fn invitedHas(c: *Call, user: Key) bool {
        for (c.invited.items) |k| if (std.mem.eql(u8, &k, &user)) return true;
        return false;
    }
};

var lock: Io.Mutex = .init;
var live: std.AutoArrayHashMapUnmanaged(Key, *Call) = .empty;

fn gpa() std.mem.Allocator {
    return A.app.gpa;
}

fn lockIt() void {
    lock.lockUncancelable(A.app.io);
}

fn unlockIt() void {
    lock.unlock(A.app.io);
}

/// A live call by id, held until `release`.
fn acquire(id: Val) ?*Call {
    const k = rt.keyOf(id) orelse return null;
    lockIt();
    defer unlockIt();
    const c = live.get(k) orelse return null;
    c.refs += 1;
    return c;
}

fn release(c: *Call) void {
    lockIt();
    defer unlockIt();
    c.refs -= 1;
    if (c.refs == 0) {
        c.participants.deinit(gpa());
        c.invited.deinit(gpa());
        gpa().destroy(c);
    }
}

/// STUN plus short-lived TURN credentials (coturn "use-auth-secret").
pub fn iceServers(a: std.mem.Allocator, user_id: []const u8) !Val {
    const cfg = &A.app.config;
    var servers = try Val.array(a);
    if (cfg.stun_urls.len > 0) try servers.push(try val.from(a, .{ .urls = cfg.stun_urls }));
    if (cfg.turn_urls.len > 0 and cfg.turn_secret.len > 0) {
        const username = try std.fmt.allocPrint(a, "{d}:{s}", .{ @divFloor(A.nowMs(), 1000) + 12 * 3600, user_id });
        var mac: [20]u8 = undefined;
        std.crypto.auth.hmac.HmacSha1.create(&mac, username, cfg.turn_secret);
        var enc: [28]u8 = undefined;
        try servers.push(try val.from(a, .{ .urls = cfg.turn_urls, .username = username, .credential = try a.dupe(u8, std.base64.standard.Encoder.encode(&enc, &mac)) }));
    }
    return servers;
}

fn mediaVal(a: std.mem.Allocator, m: Media) !Val {
    return val.from(a, .{ .audio = m.audio, .video = m.video, .screen = m.screen });
}

/// Snapshot of the participants (call lock held by the caller).
fn participantList(a: std.mem.Allocator, c: *Call, except: ?[]const u8) !Val {
    var out = try Val.array(a);
    for (c.participants.items) |p| {
        if (except) |e| if (std.mem.eql(u8, &p.conn_id, e)) continue;
        try out.push(try val.from(a, .{ .connId = try a.dupe(u8, &p.conn_id), .userId = try a.dupe(u8, &p.user_id), .media = try mediaVal(a, p.media) }));
    }
    return out;
}

fn connIds(a: std.mem.Allocator, c: *Call, except: ?[]const u8) [][36]u8 {
    lockIt();
    defer unlockIt();
    var out: std.ArrayList([36]u8) = .empty;
    for (c.participants.items) |p| {
        if (except) |e| if (std.mem.eql(u8, &p.conn_id, e)) continue;
        out.append(a, p.conn_id) catch {};
    }
    return out.items;
}

fn toParticipants(a: std.mem.Allocator, c: *Call, t: []const u8, d: Val, except: ?[]const u8) void {
    for (connIds(a, c, except)) |*cid| _ = rt.sendToConn(a, cid, t, d);
}

fn loadMember(r: *Rq, chat_id: Val, user_id: []const u8) !struct { chat: Val, member: Val } {
    const a = r.a;
    const cid = v.oid(.{ .str = try val.toStr(a, chat_id) });
    const chat = (if (cid) |x| try A.app.col.chats.findOne(a, .{ ._id = x, .deletedAt = .{ .@"$exists" = false } }, .{}) else null) orelse return r.fail(404, "Chat not found", null);
    const member = (try A.app.col.members.findOne(a, .{ .chatId = chat.get("_id"), .userId = v.oidStr(user_id), .status = "active" }, .{})) orelse return r.fail(404, "Chat not found", null);
    return .{ .chat = chat, .member = member };
}

fn features(r: *Rq, user: Val) !?Val {
    if (!user.get("appId").truthy()) return null;
    return A.app.col.apps.findOne(r.a, .{ ._id = user.get("appId") }, .{ .projection = .{ .@"settings.features" = 1 } });
}

fn finish(r: *Rq, c: *Call, status: []const u8, reason: []const u8) !void {
    const a = r.a;
    var duration: i64 = 0;
    const ended_at = A.nowMs();
    var invited: []Key = &.{};
    var conns: [][36]u8 = &.{};
    {
        lockIt();
        defer unlockIt();
        if (c.ended) return;
        c.ended = true;
        c.timer_gen += 1;
        if (live.fetchSwapRemove(c.id_hex)) |kv| {
            // The map's reference.
            kv.value.refs -= 1;
        }
        if (c.started_at) |s| duration = @intFromFloat(@round(@as(f64, @floatFromInt(ended_at - s)) / 1000));
        invited = try a.dupe(Key, c.invited.items);
        var list: std.ArrayList([36]u8) = .empty;
        for (c.participants.items) |p| try list.append(a, p.conn_id);
        conns = list.items;
    }
    const col = &A.app.col;
    _ = try col.calls.updateOne(a, .{ ._id = c.id }, .{ .@"$set" = .{ .status = status, .endedAt = Val{ .date = ended_at }, .duration = duration, .reason = reason } }, .{});
    _ = col.calls.updateMany(a, .{ ._id = c.id, .@"participants.leftAt" = Val.null }, .{ .@"$set" = .{ .@"participants.$[p].leftAt" = Val{ .date = ended_at } } }, .{ .arrayFilters = .{.{ .@"p.leftAt" = Val.null }} }) catch {};
    const id_s = try a.dupe(u8, &c.id_hex);
    const chat_s = try a.dupe(u8, &c.chat_id.toHex());
    const payload = try val.from(a, .{ .callId = id_s, .chatId = chat_s, .status = status, .reason = reason, .duration = duration });
    for (conns) |*cid| _ = rt.sendToConn(a, cid, "call.ended", payload);
    for (invited) |*k| _ = rt.toUser(a, .{ .str = k }, "call.ended", payload);
    if (c.group) rt.toChat(a, .{ .id = c.chat_id }, "call.group", try val.from(a, .{ .chatId = chat_s, .callId = id_s, .ended = true }), null);

    if (try col.chats.findOne(a, .{ ._id = c.chat_id }, .{})) |chat| {
        const initiator: Val = .{ .id = A.ObjectId.parse(&c.initiator_id) catch c.id };
        if (c.group) {
            _ = try msgs.serviceMessage(r, chat, initiator, "group_call_ended", try val.from(a, .{ .duration = duration, .video = c.video }), false);
        } else {
            _ = try msgs.serviceMessage(r, chat, initiator, "call", try val.from(a, .{ .result = status, .duration = duration, .video = c.video, .callId = c.id }), std.mem.eql(u8, status, "missed"));
        }
    }
    try events.emit(a, .call_ended, try val.from(a, .{ .call = .{ .id = c.id, .chatId = c.chat_id, .video = c.video, .status = status, .duration = duration } }));
}

fn timerTask(id_hex: [24]u8, gen: u32, ms: i64, kind: enum { ring, empty }) void {
    A.sleepMs(ms);
    var arena = std.heap.ArenaAllocator.init(gpa());
    defer arena.deinit();
    var r: Rq = .{ .a = arena.allocator() };
    const c = acquire(.{ .str = &id_hex }) orelse return;
    defer release(c);
    var due = false;
    {
        lockIt();
        defer unlockIt();
        due = c.timer_gen == gen and !c.ended and switch (kind) {
            .ring => c.ringing,
            .empty => c.participants.items.len == 0,
        };
    }
    if (!due) return;
    switch (kind) {
        .ring => finish(&r, c, "missed", "no_answer") catch {},
        .empty => finish(&r, c, "ended", "empty") catch {},
    }
}

fn startTimer(c: *Call, ms: i64, kind: anytype) void {
    var gen: u32 = 0;
    {
        lockIt();
        defer unlockIt();
        c.timer_gen += 1;
        gen = c.timer_gen;
    }
    A.spawn(timerTask, .{ c.id_hex, gen, ms, kind });
}

// ---- Client messages over the WebSocket -----------------------------------------------------

pub fn handle(r: *Rq, conn: *rt.Conn, t: []const u8, d: Val) !Val {
    if (std.mem.eql(u8, t, "call.start")) return start(r, conn, d);
    if (std.mem.eql(u8, t, "call.accept")) return accept(r, conn, d);
    if (std.mem.eql(u8, t, "call.decline")) return decline(r, conn, d);
    if (std.mem.eql(u8, t, "call.join")) return join(r, conn, d);
    if (std.mem.eql(u8, t, "call.hangup")) return hangup(r, conn, d);
    if (std.mem.eql(u8, t, "call.end_for_all")) return endForAll(r, conn, d);
    if (std.mem.eql(u8, t, "call.signal")) return signal(r, conn, d);
    if (std.mem.eql(u8, t, "call.media")) return media(r, conn, d);
    if (std.mem.eql(u8, t, "call.reaction")) return reaction(r, conn, d);
    return error.NoHandler;
}

fn inAnyCall(conn_id: []const u8, except: ?*Call) bool {
    lockIt();
    defer unlockIt();
    for (live.values()) |c| {
        if (except != null and c == except.?) continue;
        if (c.find(conn_id) != null) return true;
    }
    return false;
}

fn start(r: *Rq, conn: *rt.Conn, d: Val) !Val {
    const a = r.a;
    const col = &A.app.col;
    const video = d.get("video").isTrue();
    const uid = conn.user_id;
    const lm = try loadMember(r, d.get("chatId"), &uid);
    const chat = lm.chat;
    if (try features(r, conn.user)) |app_doc| {
        const f = app_doc.path("settings.features");
        if (f.get("calls") == .bool and !f.get("calls").bool) return r.fail(403, "Calls are turned off in this app", "calls_disabled");
        if (video and f.get("video") == .bool and !f.get("video").bool) return r.fail(403, "Video calls are turned off in this app", "video_disabled");
    }
    if (inAnyCall(conn.idStr(), null)) return r.fail(409, "You are already in a call", "in_call");

    const ctype = chat.get("type").asStr() orelse "";
    const chat_key = rt.keyOf(chat.get("_id")).?;
    if (std.mem.eql(u8, ctype, "group") or std.mem.eql(u8, ctype, "support") or std.mem.eql(u8, ctype, "channel")) {
        {
            lockIt();
            defer unlockIt();
            for (live.values()) |c| if (std.mem.eql(u8, &c.chat_id.toHex(), &chat_key)) {
                return val.from(a, .{ .callId = try a.dupe(u8, &c.id_hex), .join = true, .iceServers = try iceServers(a, &uid) });
            };
        }
        if (std.mem.eql(u8, ctype, "channel")) {
            const m = try col.members.findOne(a, .{ .chatId = chat.get("_id"), .userId = conn.user.get("_id") }, .{});
            const role = if (m) |x| x.get("role").asStr() orelse "" else "";
            if (!(std.mem.eql(u8, role, "owner") or std.mem.eql(u8, role, "admin"))) return r.fail(403, "Only admins can start a live stream", null);
        }
        const now = A.now();
        const doc = try val.from(a, .{ .chatId = chat.get("_id"), .group = true, .video = video, .initiatorId = conn.user.get("_id"), .status = "active", .participants = try Val.array(a), .invited = try Val.array(a), .createdAt = now, .startedAt = now });
        const inserted = try col.calls.insertOne(a, doc);
        const c = try gpa().create(Call);
        c.* = .{ .id = inserted.id, .id_hex = inserted.id.toHex(), .chat_id = chat.get("_id").id, .group = true, .video = video, .initiator_id = uid, .ringing = false, .started_at = now.date, .refs = 2 };
        defer release(c);
        {
            lockIt();
            defer unlockIt();
            try live.put(gpa(), c.id_hex, c);
        }
        _ = try msgs.serviceMessage(r, chat, conn.user.get("_id"), "group_call_started", try val.from(a, .{ .video = video, .callId = inserted }), true);
        const id_s = try a.dupe(u8, &c.id_hex);
        rt.toChat(a, chat.get("_id"), "call.group", try val.from(a, .{ .chatId = &chat_key, .callId = id_s, .video = video, .count = 0, .startedBy = &uid }), null);
        return val.from(a, .{ .callId = id_s, .join = true, .iceServers = try iceServers(a, &uid) });
    }

    if (!std.mem.eql(u8, ctype, "private")) return r.fail(400, "You cannot call this chat", null);
    const peer_member = try col.members.findOne(a, .{ .chatId = chat.get("_id"), .userId = .{ .@"$ne" = conn.user.get("_id") } }, .{});
    const peer = (if (peer_member) |pm| try col.users.findOne(a, .{ ._id = pm.get("userId") }, .{}) else null) orelse return r.fail(404, "This user is unavailable", null);
    if (peer.get("deletedAt").truthy()) return r.fail(404, "This user is unavailable", null);
    if (try access.isBlocked(r, peer.get("_id"), conn.user.get("_id")) or !(try access.allowedByPrivacy(r, peer, conn.user.get("_id"), "calls"))) {
        return r.fail(403, try r.fmt("{s} does not accept calls from you", .{try val.toStr(a, peer.get("displayName"))}), "calls_forbidden");
    }
    const peer_key = rt.keyOf(peer.get("_id")).?;
    var busy = false;
    {
        lockIt();
        defer unlockIt();
        for (live.values()) |c| {
            if (c.ended) continue;
            if (c.invitedHas(peer_key)) busy = true;
            for (c.participants.items) |p| if (std.mem.eql(u8, &p.user_id, &peer_key)) {
                busy = true;
            };
        }
    }
    const now = A.now();
    const doc = try val.from(a, .{
        .chatId = chat.get("_id"),
        .group = false,
        .video = video,
        .initiatorId = conn.user.get("_id"),
        .status = if (busy) "busy" else "ringing",
        .participants = .{.{ .userId = conn.user.get("_id"), .joinedAt = now, .leftAt = Val.null }},
        .invited = .{peer.get("_id")},
        .createdAt = now,
    });
    const inserted = try col.calls.insertOne(a, doc);
    if (busy) {
        _ = try msgs.serviceMessage(r, chat, conn.user.get("_id"), "call", try val.from(a, .{ .result = "busy", .duration = 0, .video = video, .callId = inserted }), true);
        return val.from(a, .{ .callId = try val.toStr(a, inserted), .busy = true });
    }
    const c = try gpa().create(Call);
    c.* = .{ .id = inserted.id, .id_hex = inserted.id.toHex(), .chat_id = chat.get("_id").id, .group = false, .video = video, .initiator_id = uid, .ringing = true, .refs = 2 };
    defer release(c);
    try c.participants.append(gpa(), .{ .conn_id = conn.id, .user_id = uid, .media = .{ .audio = true, .video = video, .screen = false } });
    try c.invited.append(gpa(), peer_key);
    {
        lockIt();
        defer unlockIt();
        try live.put(gpa(), c.id_hex, c);
    }
    startTimer(c, RING_MS, .ring);
    const id_s = try a.dupe(u8, &c.id_hex);
    const av = conn.user.get("avatar");
    const caller = try val.from(a, .{ .id = &uid, .displayName = conn.user.get("displayName"), .avatar = if (av.truthy()) Val{ .str = try val.toStr(a, av) } else Val.null });
    const delivered = rt.toUser(a, peer.get("_id"), "call.incoming", try val.from(a, .{ .callId = id_s, .chatId = &chat_key, .from = caller, .video = video, .callerConnId = conn.idStr() }));
    try events.emit(a, .call_incoming, try val.from(a, .{ .callId = id_s, .chatId = &chat_key, .video = video, .callerName = conn.user.get("displayName"), .calleeId = peer.get("_id") }));
    return val.from(a, .{ .callId = id_s, .iceServers = try iceServers(a, &uid), .ringing = delivered > 0 });
}

fn accept(r: *Rq, conn: *rt.Conn, d: Val) !Val {
    const a = r.a;
    const c = acquire(.{ .str = try val.toStr(a, d.get("callId")) }) orelse return r.fail(410, "This call has ended", "call_ended");
    defer release(c);
    const uid = conn.user_id;
    const media_ = Media{ .audio = true, .video = d.get("video").isTrue(), .screen = false };
    var peers: Val = undefined;
    {
        lockIt();
        defer unlockIt();
        if (c.ended) return r.fail(410, "This call has ended", "call_ended");
        if (c.group) return r.fail(400, "Use call.join for group calls", null);
        if (!c.invitedHas(uid)) return r.fail(403, "This call is not for you", null);
        if (!c.ringing) return r.fail(409, "This call was answered on another device", "call_taken");
        c.ringing = false;
        c.started_at = A.nowMs();
        c.timer_gen += 1;
        try c.participants.append(gpa(), .{ .conn_id = conn.id, .user_id = uid, .media = media_ });
        peers = try participantList(a, c, conn.idStr());
    }
    const started: Val = .{ .date = c.started_at.? };
    _ = try A.app.col.calls.updateOne(a, .{ ._id = c.id }, .{ .@"$set" = .{ .status = "active", .startedAt = started } }, .{});
    _ = try A.app.col.calls.updateOne(a, .{ ._id = c.id }, .{ .@"$push" = .{ .participants = .{ .userId = conn.user.get("_id"), .joinedAt = started, .leftAt = Val.null } } }, .{});
    const id_s = try a.dupe(u8, &c.id_hex);
    for (rt.connectionsOf(a, .{ .str = &uid })) |cid| if (!std.mem.eql(u8, cid, conn.idStr())) {
        _ = rt.sendToConn(a, cid, "call.taken", try val.from(a, .{ .callId = id_s }));
    };
    toParticipants(a, c, "call.accepted", try val.from(a, .{ .callId = id_s, .connId = conn.idStr(), .userId = &uid, .media = try mediaVal(a, media_) }), conn.idStr());
    try events.emit(a, .call_started, try val.from(a, .{ .call = .{ .id = c.id, .chatId = c.chat_id, .video = c.video } }));
    return val.from(a, .{ .callId = id_s, .iceServers = try iceServers(a, &uid), .peers = peers });
}

fn decline(r: *Rq, conn: *rt.Conn, d: Val) !Val {
    const c = acquire(.{ .str = try val.toStr(r.a, d.get("callId")) }) orelse return .undef;
    defer release(c);
    {
        lockIt();
        defer unlockIt();
        if (c.ended or c.group) return .undef;
    }
    if (!c.invitedHas(conn.user_id)) return r.fail(403, "This call is not for you", null);
    if (!c.ringing) return .undef;
    const busy = d.get("busy").truthy();
    try finish(r, c, if (busy) "busy" else "declined", if (busy) "busy" else "declined");
    return .undef;
}

fn join(r: *Rq, conn: *rt.Conn, d: Val) !Val {
    const a = r.a;
    const c = acquire(.{ .str = try val.toStr(a, d.get("callId")) }) orelse return r.fail(410, "This call has ended", "call_ended");
    defer release(c);
    if (c.ended or !c.group) return r.fail(410, "This call has ended", "call_ended");
    const uid = conn.user_id;
    _ = try loadMember(r, .{ .id = c.chat_id }, &uid);
    if (c.participants.items.len >= MAX_GROUP) return r.fail(409, try r.fmt("Group calls are limited to {d} people", .{MAX_GROUP}), "call_full");
    if (inAnyCall(conn.idStr(), c)) return r.fail(409, "Leave your other call first", "in_call");
    const media_ = Media{ .audio = !(d.get("audio") == .bool and !d.get("audio").bool), .video = d.get("video").isTrue(), .screen = false };
    var peers: Val = undefined;
    var count: usize = 0;
    {
        lockIt();
        defer unlockIt();
        peers = try participantList(a, c, null);
        try c.participants.append(gpa(), .{ .conn_id = conn.id, .user_id = uid, .media = media_ });
        c.timer_gen += 1;
        count = c.participants.items.len;
    }
    _ = try A.app.col.calls.updateOne(a, .{ ._id = c.id }, .{ .@"$push" = .{ .participants = .{ .userId = conn.user.get("_id"), .joinedAt = A.now(), .leftAt = Val.null } } }, .{});
    const id_s = try a.dupe(u8, &c.id_hex);
    toParticipants(a, c, "call.participant_joined", try val.from(a, .{ .callId = id_s, .connId = conn.idStr(), .userId = &uid, .media = try mediaVal(a, media_) }), conn.idStr());
    rt.toChat(a, .{ .id = c.chat_id }, "call.group", try val.from(a, .{ .chatId = try a.dupe(u8, &c.chat_id.toHex()), .callId = id_s, .video = c.video, .count = count }), null);
    return val.from(a, .{ .callId = id_s, .iceServers = try iceServers(a, &uid), .peers = peers, .video = c.video });
}

fn leave(r: *Rq, conn: *rt.Conn, c: *Call, reason: []const u8) !void {
    const a = r.a;
    var was_in = false;
    var ringing = false;
    var left: usize = 0;
    {
        lockIt();
        defer unlockIt();
        for (c.participants.items, 0..) |p, i| if (std.mem.eql(u8, &p.conn_id, conn.idStr())) {
            _ = c.participants.orderedRemove(i);
            was_in = true;
            break;
        };
        ringing = c.ringing;
        left = c.participants.items.len;
    }
    if (!was_in) {
        // A ringing caller can cancel; an invitee hanging up while ringing is a decline.
        if (!c.group and ringing and c.invitedHas(conn.user_id)) return finish(r, c, "declined", "declined");
        return;
    }
    if (!c.group) return finish(r, c, if (ringing) "missed" else "ended", if (ringing) "cancelled" else reason);
    _ = A.app.col.calls.updateOne(a, .{ ._id = c.id }, .{ .@"$set" = .{ .@"participants.$[p].leftAt" = A.now() } }, .{ .arrayFilters = .{.{ .@"p.userId" = conn.user.get("_id"), .@"p.leftAt" = Val.null }} }) catch {};
    const id_s = try a.dupe(u8, &c.id_hex);
    toParticipants(a, c, "call.participant_left", try val.from(a, .{ .callId = id_s, .connId = conn.idStr(), .userId = &conn.user_id }), null);
    // Give people a moment to rejoin before closing an empty group call.
    if (left == 0) startTimer(c, 30_000, .empty);
    rt.toChat(a, .{ .id = c.chat_id }, "call.group", try val.from(a, .{ .chatId = try a.dupe(u8, &c.chat_id.toHex()), .callId = id_s, .video = c.video, .count = left }), null);
}

fn hangup(r: *Rq, conn: *rt.Conn, d: Val) !Val {
    const c = acquire(.{ .str = try val.toStr(r.a, d.get("callId")) }) orelse return .undef;
    defer release(c);
    if (c.ended) return .undef;
    try leave(r, conn, c, "hangup");
    return .undef;
}

fn endForAll(r: *Rq, conn: *rt.Conn, d: Val) !Val {
    const a = r.a;
    const c = acquire(.{ .str = try val.toStr(a, d.get("callId")) }) orelse return .undef;
    defer release(c);
    if (c.ended or !c.group) return .undef;
    const m = try A.app.col.members.findOne(a, .{ .chatId = c.chat_id, .userId = conn.user.get("_id") }, .{});
    const role = if (m) |x| x.get("role").asStr() orelse "" else "";
    const ok = std.mem.eql(u8, role, "owner") or (std.mem.eql(u8, role, "admin") and !(m.?.path("rights.manageCalls") == .bool and !m.?.path("rights.manageCalls").bool));
    if (!ok) return r.fail(403, "Only admins can end the call for everyone", null);
    try finish(r, c, "ended", "ended_by_admin");
    return .undef;
}

/// Relays WebRTC signalling between two connections in the same call.
fn signal(r: *Rq, conn: *rt.Conn, d: Val) !Val {
    const a = r.a;
    const c = acquire(.{ .str = try val.toStr(a, d.get("callId")) }) orelse return .undef;
    defer release(c);
    const to = try val.toStr(a, if (d.get("to").truthy()) d.get("to") else Val.string(""));
    var target: ?[36]u8 = null;
    {
        lockIt();
        defer unlockIt();
        if (c.ended) return .undef;
        if (c.find(conn.idStr()) == null) return .undef;
        if (c.find(to)) |p| target = p.conn_id;
    }
    const t = target orelse return .undef;
    const data = d.get("data");
    if (data != .obj and data != .arr) return .undef;
    if ((try val.stringify(a, data)).len > 64 * 1024) return .undef;
    _ = rt.sendToConn(a, &t, "call.signal", try val.from(a, .{ .callId = try a.dupe(u8, &c.id_hex), .from = conn.idStr(), .fromUser = &conn.user_id, .data = data }));
    return .undef;
}

fn media(r: *Rq, conn: *rt.Conn, d: Val) !Val {
    const a = r.a;
    const c = acquire(.{ .str = try val.toStr(a, d.get("callId")) }) orelse return .undef;
    defer release(c);
    const m = Media{ .audio = !(d.get("audio") == .bool and !d.get("audio").bool), .video = d.get("video").isTrue(), .screen = d.get("screen").isTrue() };
    {
        lockIt();
        defer unlockIt();
        const p = c.find(conn.idStr()) orelse return .undef;
        p.media = m;
    }
    toParticipants(a, c, "call.media", try val.from(a, .{ .callId = try a.dupe(u8, &c.id_hex), .connId = conn.idStr(), .userId = &conn.user_id, .media = try mediaVal(a, m) }), conn.idStr());
    return .undef;
}

/// In-call extras: raise hand, emoji reactions.
fn reaction(r: *Rq, conn: *rt.Conn, d: Val) !Val {
    const a = r.a;
    const c = acquire(.{ .str = try val.toStr(a, d.get("callId")) }) orelse return .undef;
    defer release(c);
    {
        lockIt();
        defer unlockIt();
        if (c.find(conn.idStr()) == null) return .undef;
    }
    const emoji = if (d.get("emoji").asStr()) |e| v.sliceUtf16(e, 8) else "";
    if (emoji.len == 0) return .undef;
    toParticipants(a, c, "call.reaction", try val.from(a, .{ .callId = try a.dupe(u8, &c.id_hex), .connId = conn.idStr(), .userId = &conn.user_id, .emoji = emoji, .hand = d.get("hand").isTrue() }), null);
    return .undef;
}

/// A closed connection leaves every call it was in.
pub fn onDisconnect(r: *Rq, conn: *rt.Conn) void {
    var mine: std.ArrayList(*Call) = .empty;
    {
        lockIt();
        defer unlockIt();
        for (live.values()) |c| if (c.find(conn.idStr()) != null) {
            c.refs += 1;
            mine.append(r.a, c) catch {
                c.refs -= 1;
            };
        };
    }
    for (mine.items) |c| {
        leave(r, conn, c, "disconnected") catch {};
        release(c);
    }
}

/// Calls the user is in or was invited to, newest first.
pub fn history(r: *Rq, user: Val, before: ?[]const u8, limit_: i64) !Val {
    const a = r.a;
    const q = try val.from(a, .{ .@"$or" = .{ .{ .@"participants.userId" = user.get("_id") }, .{ .invited = user.get("_id") } } });
    if (before) |b| if (b.len > 0) {
        const ms = val.parseDate(b) orelse (std.fmt.parseInt(i64, b, 10) catch null);
        if (ms) |m| try q.set("createdAt", .{ .@"$lt" = Val{ .date = m } }) else try q.set("createdAt", .{ .@"$lt" = Val.null });
    };
    const rows = try A.app.col.calls.find(a, q, .{ .sort = .{ .createdAt = -1 }, .limit = @min(limit_, 100) });
    var out = try Val.array(a);
    for (rows) |c| try out.push(try val.from(a, .{
        .id = try r.str(c.get("_id")),
        .chatId = try r.str(c.get("chatId")),
        .group = c.get("group"),
        .video = c.get("video"),
        .status = c.get("status"),
        .outgoing = val.same(c.get("initiatorId"), user.get("_id")),
        .initiatorId = try r.str(c.get("initiatorId")),
        .createdAt = c.get("createdAt"),
        .startedAt = if (c.get("startedAt").truthy()) c.get("startedAt") else Val.null,
        .duration = if (c.get("duration").truthy()) c.get("duration") else Val.number(0),
    }));
    return out;
}

/// Snapshot of the live call in a chat, if any.
pub fn liveCallIn(a: std.mem.Allocator, chat_id: Val) !?Val {
    const k = rt.keyOf(chat_id) orelse return null;
    lockIt();
    defer unlockIt();
    for (live.values()) |c| if (!c.ended and std.mem.eql(u8, &c.chat_id.toHex(), &k)) {
        return try val.from(a, .{ .id = try a.dupe(u8, &c.id_hex), .group = c.group, .video = c.video, .count = c.participants.items.len });
    };
    return null;
}

/// When the server restarts, calls that were live can no longer continue.
pub fn closeStaleCalls(a: std.mem.Allocator) !void {
    _ = try A.app.col.calls.updateMany(a, .{ .status = .{ .@"$in" = .{ "ringing", "active" } } }, .{ .@"$set" = .{ .status = "ended", .reason = "server_restart", .endedAt = A.now() } }, .{});
}
