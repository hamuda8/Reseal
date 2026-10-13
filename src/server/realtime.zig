//! Realtime hub (src/realtime.js): WebSocket connections on /ws, presence, typing and event
//! fan-out. The hub keeps an index of which online users belong to which chats, so sending to a
//! chat with 100k members only touches the members that are online.
//!
//! Protocol: every frame is JSON `{ t, d }`; a client message may carry `id`, and is then
//! answered with `{ t: "ack", d: { id, ok, result } }` or `{ t: "ack", d: { id, ok: false, error, code } }`.

const std = @import("std");
const Io = std.Io;
const http = @import("http");
const A = @import("app.zig");
const web = @import("web.zig");
const auth = @import("auth.zig");
const ws = @import("http").ws;
const calls = @import("calls.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

pub const Key = [24]u8;

pub fn keyOf(v: Val) ?Key {
    return switch (v) {
        .id => |x| x.toHex(),
        .str => |s| if (s.len == 24) s[0..24].* else null,
        else => null,
    };
}

fn keyVal(k: Key) Val {
    return .{ .id = A.ObjectId.parse(&k) catch return .null };
}

pub const Conn = struct {
    id: [36]u8,
    user_id: Key,
    arena: std.heap.ArenaAllocator,
    /// The user as resolved at connect time (deep copy, owned by `arena`).
    user: Val,
    app_id: ?Key,
    device: []const u8,
    visible: bool = true,
    peer: *ws.Socket,
    /// Last time a ping or pong arrived (ms); proves the peer is alive.
    last_pong: std.atomic.Value(i64) = .init(0),

    pub fn idStr(c: *const Conn) []const u8 {
        return &c.id;
    }

    /// Sends `{ t, d }`; false when the connection is gone.
    pub fn send(c: *Conn, a: std.mem.Allocator, t: []const u8, d: Val) bool {
        const text = frame(a, t, d) catch return false;
        return sendText(c.peer, text);
    }
};

/// Queues a text frame; false when the connection is closed (or was dropped for not reading).
fn sendText(s: *ws.Socket, text: []const u8) bool {
    s.sendText(text) catch return false;
    return true;
}

fn frame(a: std.mem.Allocator, t: []const u8, d: Val) ![]const u8 {
    return val.stringify(a, try val.from(a, .{ .t = t, .d = d }));
}

pub const ChatType = enum { private, group, channel, saved, bot, support, other };

pub fn chatTypeOf(v: Val) ChatType {
    const s = v.asStr() orelse return .group; // m.chatType || 'group'
    return std.meta.stringToEnum(ChatType, s) orelse .other;
}

const Set = std.AutoHashMapUnmanaged(Key, void);
const LastSeenRule = enum { everyone, contacts, nobody };

var lock: Io.Mutex = .init;
var sockets: std.AutoHashMapUnmanaged(Key, std.ArrayList(*Conn)) = .empty;
var chat_index: std.AutoHashMapUnmanaged(Key, Set) = .empty;
var user_chats: std.AutoHashMapUnmanaged(Key, std.AutoHashMapUnmanaged(Key, ChatType)) = .empty;
var contacts_of: std.AutoHashMapUnmanaged(Key, Set) = .empty;
var privacy_of: std.AutoHashMapUnmanaged(Key, LastSeenRule) = .empty;
var away: Set = .empty;

fn gpa() std.mem.Allocator {
    return A.app.gpa;
}

fn lockIt() void {
    lock.lockUncancelable(A.app.io);
}

fn unlockIt() void {
    lock.unlock(A.app.io);
}

pub fn isOnline(user_id: Val) bool {
    const k = keyOf(user_id) orelse return false;
    lockIt();
    defer unlockIt();
    return sockets.contains(k);
}

pub fn isAway(user_id: Val) bool {
    const k = keyOf(user_id) orelse return false;
    lockIt();
    defer unlockIt();
    return away.contains(k);
}

/// Sends an event to every open tab and device of a user. Returns how many got it.
pub fn toUser(a: std.mem.Allocator, user_id: Val, t: []const u8, d: Val) usize {
    return toUserExcept(a, user_id, t, d, null);
}

pub fn toUserExcept(a: std.mem.Allocator, user_id: Val, t: []const u8, d: Val, except_conn: ?[]const u8) usize {
    const k = keyOf(user_id) orelse return 0;
    const text = frame(a, t, d) catch return 0;
    lockIt();
    defer unlockIt();
    const list = sockets.get(k) orelse return 0;
    var n: usize = 0;
    for (list.items) |c| {
        if (except_conn) |e| if (std.mem.eql(u8, &c.id, e)) continue;
        if (sendText(c.peer, text)) n += 1;
    }
    return n;
}

pub fn toUsers(a: std.mem.Allocator, user_ids: []const Val, t: []const u8, d: Val) void {
    var seen: Set = .empty;
    for (user_ids) |id| {
        const k = keyOf(id) orelse continue;
        const gop = seen.getOrPut(a, k) catch continue;
        if (gop.found_existing) continue;
        _ = toUser(a, id, t, d);
    }
}

/// Online members of a chat (their user ids).
pub fn onlineMembers(a: std.mem.Allocator, chat_id: Val) []Key {
    const k = keyOf(chat_id) orelse return &.{};
    lockIt();
    defer unlockIt();
    const set = chat_index.get(k) orelse return &.{};
    const out = a.alloc(Key, set.count()) catch return &.{};
    var it = set.keyIterator();
    var i: usize = 0;
    while (it.next()) |u| : (i += 1) out[i] = u.*;
    return out;
}

pub fn onlineMemberVals(a: std.mem.Allocator, chat_id: Val) []Val {
    const keys = onlineMembers(a, chat_id);
    const out = a.alloc(Val, keys.len) catch return &.{};
    for (keys, 0..) |k, i| out[i] = .{ .str = a.dupe(u8, &k) catch "" };
    return out;
}

/// Sends an event to every online member of a chat (except `except`).
pub fn toChat(a: std.mem.Allocator, chat_id: Val, t: []const u8, d: Val, except: ?Val) void {
    const ex = if (except) |e| keyOf(e) else null;
    for (onlineMembers(a, chat_id)) |uid| {
        if (ex) |e| if (std.mem.eql(u8, &e, &uid)) continue;
        _ = toUser(a, .{ .str = &uid }, t, d);
    }
}

/// toChat with a payload tailored to each member: `f(ctx, a, userId)` returns it, or null to skip.
pub fn toChatEach(a: std.mem.Allocator, chat_id: Val, t: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), std.mem.Allocator, []const u8) anyerror!?Val) void {
    for (onlineMembers(a, chat_id)) |uid| {
        const key = a.dupe(u8, &uid) catch continue;
        const d = (f(ctx, a, key) catch continue) orelse continue;
        _ = toUser(a, .{ .str = key }, t, d);
    }
}

/// Keeps the online index in sync when memberships change.
pub fn joinedChat(user_id: Val, chat_id: Val, chat_type: Val) void {
    const uid = keyOf(user_id) orelse return;
    const cid = keyOf(chat_id) orelse return;
    lockIt();
    defer unlockIt();
    if (!sockets.contains(uid)) return;
    if (user_chats.getPtr(uid)) |m| m.put(gpa(), cid, chatTypeOf(chat_type)) catch {};
    const gop = chat_index.getOrPut(gpa(), cid) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    gop.value_ptr.put(gpa(), uid, {}) catch {};
}

pub fn leftChat(user_id: Val, chat_id: Val) void {
    const uid = keyOf(user_id) orelse return;
    const cid = keyOf(chat_id) orelse return;
    lockIt();
    defer unlockIt();
    if (user_chats.getPtr(uid)) |m| _ = m.remove(cid);
    removeFromChat(cid, uid);
}

fn removeFromChat(cid: Key, uid: Key) void {
    if (chat_index.getPtr(cid)) |set| {
        _ = set.remove(uid);
        if (set.count() == 0) {
            set.deinit(gpa());
            _ = chat_index.remove(cid);
        }
    }
}

/// The chat ids a user is in and the chat's type (online users only).
pub fn userChatType(user_id: Key, chat_id: Key) ?ChatType {
    lockIt();
    defer unlockIt();
    const m = user_chats.get(user_id) orelse return null;
    return m.get(chat_id);
}

pub fn updateContacts(user_id: Val, contact_ids: []const Val) void {
    const uid = keyOf(user_id) orelse return;
    lockIt();
    defer unlockIt();
    if (!sockets.contains(uid)) return;
    const gop = contacts_of.getOrPut(gpa(), uid) catch return;
    if (gop.found_existing) gop.value_ptr.clearRetainingCapacity() else gop.value_ptr.* = .empty;
    for (contact_ids) |c| if (keyOf(c)) |ck| gop.value_ptr.put(gpa(), ck, {}) catch {};
}

fn ruleOf(privacy: Val) LastSeenRule {
    const r = privacy.get("lastSeen").asStr() orelse return .everyone;
    return std.meta.stringToEnum(LastSeenRule, r) orelse .nobody;
}

pub fn updatePrivacy(a: std.mem.Allocator, user_id: Val, privacy: Val) void {
    if (keyOf(user_id)) |uid| {
        lockIt();
        defer unlockIt();
        if (sockets.contains(uid)) privacy_of.put(gpa(), uid, ruleOf(privacy)) catch {};
    }
    broadcastPresence(a, user_id, null);
}

/// Whether `viewer_id` may see the online status / last seen of `user_id`.
pub fn canSeePresence(user_id: Val, viewer_id: Val, privacy: Val, viewer_is_contact: bool) bool {
    if (val.same(user_id, viewer_id)) return true;
    return switch (ruleOf(privacy)) {
        .everyone => true,
        .contacts => viewer_is_contact,
        .nobody => false,
    };
}

/// Presence as a viewer is allowed to see it.
pub fn presenceFor(a: std.mem.Allocator, user: Val, viewer_id: Val, viewer_is_contact: bool) !Val {
    const kind = user.get("kind");
    if (kind == .str and std.mem.eql(u8, kind.str, "bot")) return val.from(a, .{ .status = "bot" });
    const uid = user.get("_id");
    if (!canSeePresence(uid, viewer_id, user.get("privacy"), viewer_is_contact)) {
        // Hide the exact time but give a rough idea.
        const last = user.get("lastSeenAt");
        const ago = A.nowMs() - (if (last == .date) last.date else 0);
        const status: []const u8 = if (ago < 3 * 86400_000) "recently" else if (ago < 7 * 86400_000) "within_week" else if (ago < 30 * 86400_000) "within_month" else "long_ago";
        return val.from(a, .{ .status = status });
    }
    if (isOnline(uid) and !isAway(uid)) return val.from(a, .{ .status = "online" });
    const last = user.get("lastSeenAt");
    return val.from(a, .{ .status = "offline", .lastSeenAt = if (last.truthy()) last else Val.null });
}

/// Tells the people who care (private-chat and group partners) that someone's presence changed.
fn broadcastPresence(a: std.mem.Allocator, user_id: Val, last_seen: ?i64) void {
    const uid = keyOf(user_id) orelse return;
    const Target = struct { viewer: Key, visible: bool };
    var targets: std.ArrayList(Target) = .empty;
    var online = false;
    {
        lockIt();
        defer unlockIt();
        online = sockets.contains(uid) and !away.contains(uid);
        const rule = privacy_of.get(uid) orelse .everyone;
        var audience: Set = .empty;
        if (user_chats.get(uid)) |chats| {
            var it = chats.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* != .private and e.value_ptr.* != .group) continue;
                const members = chat_index.get(e.key_ptr.*) orelse continue;
                var mi = members.keyIterator();
                while (mi.next()) |other| if (!std.mem.eql(u8, other, &uid)) audience.put(a, other.*, {}) catch {};
            }
        }
        var ai = audience.keyIterator();
        while (ai.next()) |viewer| {
            const is_contact = if (contacts_of.get(uid)) |cs| cs.contains(viewer.*) else false;
            const visible = switch (rule) {
                .everyone => true,
                .contacts => is_contact,
                .nobody => false,
            };
            targets.append(a, .{ .viewer = viewer.*, .visible = visible }) catch {};
        }
    }
    const uid_s = a.dupe(u8, &uid) catch return;
    for (targets.items) |t| {
        const d = if (t.visible)
            val.from(a, .{ .userId = uid_s, .status = if (online) "online" else "offline", .lastSeenAt = if (online) Val.null else Val{ .date = last_seen orelse A.nowMs() } }) catch continue
        else
            val.from(a, .{ .userId = uid_s, .status = "recently" }) catch continue;
        _ = toUser(a, .{ .str = &t.viewer }, "presence", d);
    }
}

fn loadIndexes(r: *Rq, conn: *Conn) !void {
    const a = r.a;
    const uid = conn.user_id;
    {
        lockIt();
        defer unlockIt();
        if (user_chats.contains(uid)) return;
    }
    const user_oid = conn.user.get("_id");
    const memberships = try A.app.col.members.find(a, .{ .userId = user_oid, .status = "active" }, .{ .projection = .{ .chatId = 1, .chatType = 1 } });
    const contacts = try A.app.col.contacts.find(a, .{ .userId = user_oid }, .{ .projection = .{ .contactId = 1 } });
    lockIt();
    defer unlockIt();
    if (user_chats.contains(uid)) return;
    var chats: std.AutoHashMapUnmanaged(Key, ChatType) = .empty;
    for (memberships) |m| {
        const cid = keyOf(m.get("chatId")) orelse continue;
        chats.put(gpa(), cid, chatTypeOf(m.get("chatType"))) catch {};
        const gop = chat_index.getOrPut(gpa(), cid) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.put(gpa(), uid, {}) catch {};
    }
    user_chats.put(gpa(), uid, chats) catch {};
    var cs: Set = .empty;
    for (contacts) |c| if (keyOf(c.get("contactId"))) |ck| cs.put(gpa(), ck, {}) catch {};
    if (contacts_of.fetchRemove(uid)) |old| {
        var o = old.value;
        o.deinit(gpa());
    }
    contacts_of.put(gpa(), uid, cs) catch {};
    privacy_of.put(gpa(), uid, ruleOf(conn.user.get("privacy"))) catch {};
}

fn unloadIndexesLocked(uid: Key) void {
    if (user_chats.fetchRemove(uid)) |kv| {
        var m = kv.value;
        var it = m.keyIterator();
        while (it.next()) |cid| removeFromChat(cid.*, uid);
        m.deinit(gpa());
    }
    if (contacts_of.fetchRemove(uid)) |kv| {
        var s = kv.value;
        s.deinit(gpa());
    }
    _ = privacy_of.remove(uid);
}

fn register(r: *Rq, conn: *Conn) !void {
    const uid = conn.user_id;
    var first = false;
    {
        lockIt();
        defer unlockIt();
        const gop = try sockets.getOrPut(gpa(), uid);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            first = true;
        }
        try gop.value_ptr.append(gpa(), conn);
    }
    try loadIndexes(r, conn);
    refreshAway(r.a, uid, conn.user.get("_id"));
    if (first) broadcastPresence(r.a, conn.user.get("_id"), null);
}

fn unregister(r: *Rq, conn: *Conn) void {
    const uid = conn.user_id;
    var last = false;
    {
        lockIt();
        defer unlockIt();
        const list = sockets.getPtr(uid) orelse return;
        for (list.items, 0..) |c, i| if (c == conn) {
            _ = list.swapRemove(i);
            break;
        };
        last = list.items.len == 0;
    }
    calls.onDisconnect(r, conn);
    if (!last) {
        refreshAway(r.a, uid, conn.user.get("_id"));
        return;
    }
    {
        lockIt();
        defer unlockIt();
        // Another tab may have connected meanwhile.
        if (sockets.getPtr(uid)) |list| if (list.items.len == 0) {
            list.deinit(gpa());
            _ = sockets.remove(uid);
        };
        _ = away.remove(uid);
    }
    const now = A.nowMs();
    _ = A.app.col.users.updateOne(r.a, .{ ._id = conn.user.get("_id") }, .{ .@"$set" = .{ .lastSeenAt = Val{ .date = now } } }, .{}) catch {};
    broadcastPresence(r.a, conn.user.get("_id"), now);
    lockIt();
    defer unlockIt();
    if (!sockets.contains(uid)) unloadIndexesLocked(uid);
}

fn refreshAway(a: std.mem.Allocator, uid: Key, user_oid: Val) void {
    var changed = false;
    var now_away = false;
    {
        lockIt();
        defer unlockIt();
        const was = away.contains(uid);
        if (sockets.get(uid)) |list| {
            if (list.items.len > 0) {
                now_away = true;
                for (list.items) |c| if (c.visible) {
                    now_away = false;
                };
            }
        }
        if (now_away) away.put(gpa(), uid, {}) catch {} else _ = away.remove(uid);
        changed = was != now_away;
    }
    if (!changed) return;
    if (now_away) _ = A.app.col.users.updateOne(a, .{ ._id = user_oid }, .{ .@"$set" = .{ .lastSeenAt = A.now() } }, .{}) catch {};
    broadcastPresence(a, user_oid, null);
}

// ---- Connections -----------------------------------------------------------------------------

/// Sends to one connection by id. False when it is gone.
pub fn sendToConn(a: std.mem.Allocator, conn_id: []const u8, t: []const u8, d: Val) bool {
    const text = frame(a, t, d) catch return false;
    lockIt();
    defer unlockIt();
    var it = sockets.valueIterator();
    while (it.next()) |list| for (list.items) |c| if (std.mem.eql(u8, &c.id, conn_id)) return sendText(c.peer, text);
    return false;
}

/// The connection ids of a user's open tabs.
pub fn connectionsOf(a: std.mem.Allocator, user_id: Val) [][]const u8 {
    const k = keyOf(user_id) orelse return &.{};
    lockIt();
    defer unlockIt();
    const list = sockets.get(k) orelse return &.{};
    const out = a.alloc([]const u8, list.items.len) catch return &.{};
    for (list.items, 0..) |c, i| out[i] = a.dupe(u8, &c.id) catch "";
    return out;
}

pub fn stats() struct { users: usize, connections: usize, chats: usize } {
    lockIt();
    defer unlockIt();
    var n: usize = 0;
    var it = sockets.valueIterator();
    while (it.next()) |l| n += l.items.len;
    return .{ .users = sockets.count(), .connections = n, .chats = chat_index.count() };
}

/// Every 25 s: ping each connection and drop those silent for 2.5 pings.
pub fn pingLoop() void {
    while (true) {
        A.app.io.sleep(.fromSeconds(25), .awake) catch return;
        const t = A.nowMs();
        lockIt();
        var it = sockets.valueIterator();
        while (it.next()) |list| for (list.items) |c| {
            if (t - c.last_pong.load(.acquire) > 62_500) c.peer.terminate() else c.peer.send(.ping, "") catch {};
        };
        unlockIt();
    }
}

// ---- Upgrade and the message loop --------------------------------------------------------

fn reject(ctx: *http.Context, status: u16, message: []const u8) !void {
    ctx.responded = true;
    ctx.close_connection = true;
    try ctx.request.respond(message, .{ .status = @fromBackingInt(@intCast(status)), .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
}

/// Takes WebSocket upgrades (any path; only /ws is accepted, as Node's 'upgrade' handler did).
pub fn upgrade(q: *web.Req) !void {
    const ctx = q.ctx;
    if (!std.mem.eql(u8, q.path, "/ws")) return reject(ctx, 404, "Not Found");
    // Only pages served by Reseal itself may open a socket (stops cross-site hijacking).
    if (q.header("origin")) |origin| {
        const host = q.header("host") orelse "";
        const uri = std.Uri.parse(origin) catch return reject(ctx, 403, "Forbidden origin");
        var buf: [300]u8 = undefined;
        const h = (uri.host orelse return reject(ctx, 403, "Forbidden origin")).percent_encoded;
        const origin_host = if (uri.port) |p| (std.fmt.bufPrint(&buf, "{s}:{d}", .{ h, p }) catch "") else h;
        if (!std.mem.eql(u8, origin_host, host)) return reject(ctx, 403, "Forbidden origin");
    }
    // The cookie (the Reseal web app), ?token= (the widget, native apps) or a Bearer header.
    var token = q.query("token");
    if (token == null or token.?.len == 0) token = auth.tokenFromRequest(q).token;
    const resolved = (auth.resolveToken(&q.r, token) catch null) orelse return reject(ctx, 401, "Unauthorized");

    const gpa_ = A.app.gpa;
    var peer = ctx.webSocket() catch return reject(ctx, 400, "Bad Request");
    // As Reseal-js's ws: messages up to 512 KiB (call signalling), sends queued for the
    // connection's writer task, a client that stops reading dropped at 16 MiB.
    peer.max_payload = 512 * 1024;
    peer.queued = true;

    const conn = try gpa_.create(Conn);
    defer gpa_.destroy(conn);
    conn.* = .{ .id = undefined, .user_id = keyOf(resolved.user.get("_id")) orelse return, .arena = .init(gpa_), .user = undefined, .app_id = null, .device = "", .peer = &peer };
    conn.last_pong.store(A.nowMs(), .release);
    defer conn.arena.deinit();
    _ = A.randomUuid(&conn.id);
    const ca = conn.arena.allocator();
    conn.user = try val.deepClone(ca, resolved.user);
    conn.device = try ca.dupe(u8, @import("validate.zig").sliceUtf16(q.header("user-agent") orelse "", 200));
    conn.app_id = keyOf(resolved.user.get("appId"));

    var writer: Io.Group = .init;
    try writer.concurrent(A.app.io, ws.Socket.writerLoop, .{&peer});
    defer {
        peer.close(1000);
        writer.await(A.app.io) catch {};
        peer.deinit();
    }

    var msg_arena = std.heap.ArenaAllocator.init(gpa_);
    defer msg_arena.deinit();
    {
        var r: Rq = .{ .a = msg_arena.allocator() };
        try register(&r, conn);
    }
    defer {
        _ = msg_arena.reset(.retain_capacity);
        var r: Rq = .{ .a = msg_arena.allocator() };
        unregister(&r, conn);
    }
    {
        const a = msg_arena.allocator();
        _ = conn.send(a, "ready", try val.from(a, .{ .connId = conn.idStr(), .userId = &conn.user_id, .serverTime = A.nowMs() }));
    }

    while (true) {
        const m = peer.read() catch break;
        if (m.op == .ping or m.op == .pong) conn.last_pong.store(A.nowMs(), .release);
        _ = msg_arena.reset(.retain_capacity);
        if (m.op != .text) continue;
        var r: Rq = .{ .a = msg_arena.allocator() };
        handleMessage(&r, conn, m.data);
    }
}

const ACTIONS = [_][]const u8{ "typing", "recording_voice", "recording_video", "uploading_photo", "uploading_video", "uploading_file", "choosing_sticker", "cancel" };

fn handleMessage(r: *Rq, conn: *Conn, raw: []const u8) void {
    const a = r.a;
    const rate_key = std.fmt.allocPrint(a, "ws:{s}", .{&conn.user_id}) catch return;
    if (!A.allow(rate_key, 120, 10_000)) {
        _ = conn.send(a, "error", val.from(a, .{ .message = "Too many messages" }) catch return);
        return;
    }
    const msg = val.parseJson(a, raw) catch return;
    const t = msg.get("t").asStr() orelse return;
    if (t.len > 0 and t[0] == '$') return;
    var d = msg.get("d");
    if (!d.truthy()) d = Val.object(a) catch return;
    const id = msg.get("id");
    const result = dispatch(r, conn, t, d) catch |e| {
        if (e == error.NoHandler) return;
        if (id == .undef) return;
        var message: []const u8 = @errorName(e);
        var code: []const u8 = "error";
        if (e == error.Http) if (r.err) |he| {
            message = he.message;
            code = he.code;
        };
        _ = conn.send(a, "ack", val.from(a, .{ .id = id, .ok = false, .@"error" = message, .code = code }) catch return);
        return;
    };
    if (id == .undef) return;
    _ = conn.send(a, "ack", val.from(a, .{ .id = id, .ok = true, .result = if (result == .undef) Val.null else result }) catch return);
}

fn dispatch(r: *Rq, conn: *Conn, t: []const u8, d: Val) !Val {
    if (std.mem.eql(u8, t, "presence")) {
        {
            lockIt();
            defer unlockIt();
            conn.visible = !(d.get("visible") == .bool and !d.get("visible").bool);
        }
        refreshAway(r.a, conn.user_id, conn.user.get("_id"));
        return .undef;
    }
    if (std.mem.eql(u8, t, "typing")) {
        try typing(r, conn, d);
        return .undef;
    }
    if (std.mem.startsWith(u8, t, "call.")) return calls.handle(r, conn, t, d);
    return error.NoHandler;
}

/// Typing indicators: "typing", "recording voice", "uploading photo", ...
fn typing(r: *Rq, conn: *Conn, d: Val) !void {
    const a = r.a;
    const chat_s = try val.toStr(a, if (d.get("chatId").truthy()) d.get("chatId") else Val.string(""));
    const action_v = d.get("action").asStr();
    var action: []const u8 = "typing";
    if (action_v) |x| for (ACTIONS) |known| if (std.mem.eql(u8, known, x)) {
        action = known;
    };
    if (chat_s.len != 24) return;
    const ctype = userChatType(conn.user_id, chat_s[0..24].*) orelse return;
    if (ctype == .channel) return;
    if (!A.allow(try std.fmt.allocPrint(a, "typing:{s}", .{&conn.user_id}), 20, 10_000)) return;
    const topic = d.get("topicId");
    toChat(a, .{ .str = chat_s }, "typing", try val.from(a, .{ .chatId = chat_s, .userId = &conn.user_id, .action = action, .topicId = if (topic.truthy()) topic else Val.null }), .{ .str = &conn.user_id });
}
