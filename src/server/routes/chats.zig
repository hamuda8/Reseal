//! Chats and their messages (src/routes/chats.js). Every route needs a signed-in user.

const std = @import("std");
const A = @import("../app.zig");
const web = @import("../web.zig");
const v = @import("../validate.zig");
const ser = @import("../serialize.zig");
const store = @import("../store.zig");
const rt = @import("../realtime.zig");
const keys = @import("../keys.zig");
const chats = @import("../chats.zig");
const msgs = @import("../messages.zig");
const access = @import("../access.zig");
const apps = @import("../apps.zig");
const calls = @import("../calls.zig");
const teams = @import("../teams.zig");
const ai = @import("../ai.zig");
const auth = @import("../auth.zig");
const wufour = @import("../wufour.zig");
const events = @import("../events.zig");
const account = @import("account.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;
const Req = web.Req;
const Limits = A.Limits;
const eq = access.eq;

fn col() *A.Cols {
    return &A.app.col;
}

fn idv(x: A.ObjectId) Val {
    return .{ .id = x };
}

fn done(res: anyerror!void) anyerror!bool {
    try res;
    return true;
}

pub fn handle(q: *Req) !bool {
    if (q.is(.GET, "/api/chats")) return done(list(q));
    if (q.is(.GET, "/api/chats/:chatId")) return done(getOne(q));
    if (q.is(.GET, "/api/chats/by-username/:username")) return done(byUsername(q));
    if (q.is(.POST, "/api/chats/private")) return done(openPrivate(q));
    if (q.is(.POST, "/api/chats")) return done(create(q));
    if (q.is(.POST, "/api/chats/saved")) return done(createSaved(q));
    if (q.is(.POST, "/api/chats/read-all")) return done(readAll(q));
    if (q.is(.PATCH, "/api/chats/:chatId")) return done(patch(q));
    if (q.is(.POST, "/api/chats/:chatId/state")) return done(state(q));
    if (q.is(.GET, "/api/chats/:chatId/members")) return done(members(q));
    if (q.is(.POST, "/api/chats/:chatId/members")) return done(addMembers(q));
    if (q.is(.DELETE, "/api/chats/:chatId/members/:userId")) return done(removeMember(q));
    if (q.is(.POST, "/api/chats/:chatId/members/:userId/unban")) return done(unban(q));
    if (q.is(.POST, "/api/chats/:chatId/members/:userId/admin")) return done(setAdmin(q));
    if (q.is(.POST, "/api/chats/:chatId/members/:userId/owner")) return done(owner(q));
    if (q.is(.POST, "/api/chats/:chatId/requests/:userId")) return done(decide(q));
    if (q.is(.POST, "/api/chats/:chatId/join")) return done(join(q));
    if (q.is(.POST, "/api/chats/:chatId/leave")) return done(leave(q));
    if (q.is(.DELETE, "/api/chats/:chatId")) return done(delete(q));
    if (q.is(.POST, "/api/chats/:chatId/clear")) return done(clear(q));
    if (q.is(.POST, "/api/chats/:chatId/handoff")) return done(handoff(q));
    if (q.is(.GET, "/api/chats/:chatId/invites")) return done(invites(q));
    if (q.is(.POST, "/api/chats/:chatId/invites")) return done(createInvite(q));
    if (q.is(.DELETE, "/api/chats/:chatId/invites/:code")) return done(revokeInvite(q));
    if (q.is(.GET, "/api/invites/:code")) return done(previewInvite(q));
    if (q.is(.POST, "/api/invites/:code/join")) return done(joinInvite(q));
    if (q.is(.GET, "/api/chats/:chatId/keys")) return done(getKeys(q));
    if (q.is(.GET, "/api/chats/:chatId/key-members")) return done(keyMembers(q));
    if (q.is(.POST, "/api/chats/:chatId/keys")) return done(postKeys(q));
    if (q.is(.GET, "/api/chats/:chatId/messages")) return done(messages(q));
    if (q.is(.GET, "/api/chats/:chatId/messages/scheduled")) return done(scheduled(q));
    if (q.is(.POST, "/api/chats/:chatId/messages/scheduled/:id/send")) return done(sendScheduled(q));
    if (q.is(.GET, "/api/chats/:chatId/messages/:id")) return done(oneMessage(q));
    if (q.is(.POST, "/api/chats/:chatId/messages")) return done(send(q));
    if (q.is(.PATCH, "/api/chats/:chatId/messages/:id")) return done(edit(q));
    if (q.is(.POST, "/api/chats/:chatId/messages/delete")) return done(deleteMessages(q));
    if (q.is(.POST, "/api/chats/:chatId/messages/:id/react")) return done(react(q));
    if (q.is(.GET, "/api/chats/:chatId/messages/:id/reactions")) return done(reactions(q));
    if (q.is(.POST, "/api/chats/:chatId/messages/:id/vote")) return done(vote(q));
    if (q.is(.POST, "/api/chats/:chatId/messages/:id/close-poll")) return done(closePoll(q));
    if (q.is(.GET, "/api/chats/:chatId/messages/:id/voters")) return done(voters(q));
    if (q.is(.GET, "/api/chats/:chatId/messages/:id/readers")) return done(readers(q));
    if (q.is(.POST, "/api/chats/:chatId/messages/:id/pin")) return done(pin(q));
    if (q.is(.POST, "/api/chats/:chatId/unpin-all")) return done(unpinAll(q));
    if (q.is(.POST, "/api/chats/:chatId/messages/:id/stop")) return done(stop(q));
    if (q.is(.POST, "/api/chats/:chatId/messages/:id/regenerate")) return done(regenerate(q));
    if (q.is(.POST, "/api/chats/:chatId/messages/:id/button")) return done(button(q));
    if (q.is(.POST, "/api/chats/:chatId/read")) return done(read(q));
    if (q.is(.POST, "/api/chats/:chatId/views")) return done(views(q));
    if (q.is(.GET, "/api/chats/:chatId/media-counts")) return done(mediaCounts(q));
    return false;
}

fn member(q: *Req) !access.ChatMember {
    return access.requireMember(&q.r, q.pv("chatId"), q.user());
}

fn sameApp(r: *Rq, x: Val, y: Val) !bool {
    return std.mem.eql(u8, try val.str(r.a, if (x.truthy()) x else Val.s("")), try val.str(r.a, if (y.truthy()) y else Val.s("")));
}

/// Members, or anyone in the same scope for public groups and channels (read-only preview).
fn reader(q: *Req) !access.ChatMember {
    const r = &q.r;
    if (member(q)) |cm| return cm else |e| {
        if (e != error.Http or r.err == null or !std.mem.eql(u8, r.err.?.code, "not_member")) return e;
        const saved = r.err;
        const chat = try access.getChat(r, q.pv("chatId"));
        if (!chat.get("usernameLower").truthy() or chat.get("encrypted").truthy() or !(try sameApp(r, chat.get("appId"), q.user().get("appId")))) {
            r.err = saved;
            return e;
        }
        const banned = try col().members.findOne(r.a, .{ .chatId = chat.get("_id"), .userId = q.user().get("_id"), .status = "banned" }, .{});
        if (banned != null) {
            r.err = saved;
            return e;
        }
        return .{ .chat = chat, .member = try val.from(r.a, .{ .userId = q.user().get("_id"), .clearedSeq = 0, .joinedSeq = 0, .preview = true }) };
    }
}

// ---- Chat list --------------------------------------------------------------------------------

fn list(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const me = q.user().get("_id");
    const memberships = try col().members.find(a, .{ .userId = me, .status = "active" }, .{});
    var ids: std.ArrayList(Val) = .empty;
    for (memberships) |m| try ids.append(a, m.get("chatId"));
    const rows = try col().chats.find(a, .{ ._id = .{ .@"$in" = ids.items }, .deletedAt = .{ .@"$exists" = false } }, .{});
    const memberOf = struct {
        fn f(ms: []const Val, chat_id: Val) Val {
            for (ms) |m| if (val.same(m.get("chatId"), chat_id)) return m;
            return .null;
        }
    }.f;
    var visible: std.ArrayList(Val) = .empty;
    for (rows) |c| {
        const m = memberOf(memberships, c.get("_id"));
        // Chats "deleted for me" stay hidden until something new arrives.
        const hidden = m.get("hiddenAt").truthy() and (c.path("lastMessage.seq").asNum() orelse 0) <= (m.get("clearedSeq").asNum() orelse 0);
        if (!hidden) try visible.append(a, c);
    }
    // Peers of private and bot chats, in one query.
    var pair_ids: std.ArrayList(Val) = .empty;
    for (visible.items) |c| if (eq(c.get("type"), "private") or eq(c.get("type"), "bot")) try pair_ids.append(a, c.get("_id"));
    const peer_rows = if (pair_ids.items.len > 0) try col().members.find(a, .{ .chatId = .{ .@"$in" = pair_ids.items }, .userId = .{ .@"$ne" = me } }, .{ .projection = .{ .chatId = 1, .userId = 1 } }) else val.none[0..];
    var peer_ids: std.ArrayList(Val) = .empty;
    for (peer_rows) |p| try peer_ids.append(a, p.get("userId"));
    const peer_users = if (peer_rows.len > 0) try col().users.find(a, .{ ._id = .{ .@"$in" = peer_ids.items } }, .{}) else val.none[0..];
    const serialized = try account.usersFor(r, q.user(), peer_users, false);
    const extras = try teams.extrasFor(r, visible.items, me);
    try msgs.fillLastMessages(r, visible.items);

    var out: std.ArrayList(Val) = .empty;
    for (visible.items) |c| {
        const m = memberOf(memberships, c.get("_id"));
        var peer: Val = .null;
        for (peer_rows) |p| if (val.same(p.get("chatId"), c.get("_id"))) {
            for (serialized.items()) |u| if (val.same(u.get("id"), p.get("userId"))) {
                peer = u;
            };
        };
        const call = try calls.liveCallIn(a, c.get("_id"));
        const ex = teams.extrasOf(extras, c.get("_id"));
        const lm = c.get("lastMessage");
        const show = lm.truthy() and (lm.get("seq").asNum() orelse 0) > (m.get("clearedSeq").asNum() orelse 0);
        try out.append(a, try ser.chat(a, c, m, me, .{
            .peer = peer,
            .team = if (ex) |e| e.team else .null,
            .visitor = if (ex) |e| e.visitor else .null,
            .last_message = if (show) try ser.message(a, lm, me, c) else .null,
            .active_call = if (call) |cl| (if (cl.get("group").truthy()) cl else Val.null) else Val.null,
        }));
    }
    std.mem.sort(Val, out.items, {}, struct {
        fn lt(_: void, x: Val, y: Val) bool {
            return dateOf(x.get("lastMessageAt")) > dateOf(y.get("lastMessageAt"));
        }
        fn dateOf(d: Val) i64 {
            return switch (d) {
                .date => |ms| ms,
                else => 0,
            };
        }
    }.lt);
    return q.json(.{ .chats = out.items, .serverTime = A.nowMs() });
}

fn getOne(q: *Req) !void {
    const r = &q.r;
    const chat = try access.getChat(r, q.pv("chatId"));
    const m = try col().members.findOne(r.a, .{ .chatId = chat.get("_id"), .userId = q.user().get("_id") }, .{});
    if (m) |mm| if (eq(mm.get("status"), "active")) return q.json(.{ .chat = try chats.chatFor(r, chat, q.user().get("_id"), mm) });
    // Public chats can be previewed before joining.
    try r.ensure(chat.get("usernameLower").truthy() and try sameApp(r, chat.get("appId"), q.user().get("appId")), "Chat not found", 404, "chat_not_found");
    const out = try ser.chat(r.a, chat, .null, q.user().get("_id"), .{});
    try out.set(r.a, "preview", true);
    try out.set(r.a, "requested", m != null and eq(m.?.get("status"), "requested"));
    return q.json(.{ .chat = out });
}

fn byUsername(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    var lower = try std.ascii.allocLowerString(a, q.param("username"));
    if (lower.len > 0 and lower[0] == '@') lower = lower[1..];
    const me = q.user();
    if (try col().chats.findOne(a, .{ .usernameLower = lower, .appId = if (me.get("appId").truthy()) me.get("appId") else Val.null, .deletedAt = .{ .@"$exists" = false } }, .{})) |chat| {
        const m = try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = me.get("_id"), .status = "active" }, .{});
        if (m) |mm| return q.json(.{ .chat = try chats.chatFor(r, chat, me.get("_id"), mm) });
        const out = try ser.chat(a, chat, .null, me.get("_id"), .{});
        try out.set(a, "preview", true);
        return q.json(.{ .chat = out });
    }
    const key = if (me.get("appId").truthy()) try r.fmt("{s}:{s}", .{ try r.str(me.get("appId")), lower }) else lower;
    const user = (try col().users.findOne(a, .{ .usernameLower = key, .deletedAt = .{ .@"$exists" = false } }, .{})) orelse return r.fail(404, "Nobody has that username", "not_found");
    return q.json(.{ .user = (try account.usersFor(r, me, &.{user}, false)).items()[0] });
}

// ---- Creating chats ----------------------------------------------------------------------------

fn openPrivate(q: *Req) !void {
    const r = &q.r;
    var user_id = q.b("userId");
    if (!user_id.truthy() and q.b("wufourId").truthy()) {
        // Someone with a Wufour account who has not opened Reseal yet: their profile is made now.
        try r.ensure(!q.user().get("appId").truthy(), "User not found", 404, "user_not_found");
        const wu = (try wufour.findById(r, try v.reqStr(r, q.b("wufourId"), "wufourId", .{ .max = 64 }))) orelse return r.fail(404, "That Wufour account was not found", "user_not_found");
        user_id = (try auth.upsertWufourUser(r, try val.from(r.a, .{ .userId = wu.get("id"), .username = wu.get("username") }))).get("_id");
    }
    const chat = try chats.openPrivate(r, q.user(), idv(try v.reqId(r, user_id, "userId")));
    return q.json(.{ .chat = try chats.chatFor(r, chat, q.user().get("_id"), null) });
}

fn create(q: *Req) !void {
    const r = &q.r;
    try account.rateLimit(q, "create-chat", 30, 3600_000);
    const t = if (q.b("type").truthy()) q.b("type") else Val.s("group");
    const is_channel = eq(t, "channel");
    try apps.assertFeature(r, q.user(), if (is_channel) "channels" else "groups", try r.fmt("Creating {s}s is turned off in this app", .{try r.str(t)}));
    const res = try chats.createGroup(r, q.user(), try q.bodyObj());
    return q.json(.{ .chat = try chats.chatFor(r, res.chat, q.user().get("_id"), null), .skipped = res.skipped });
}

fn createSaved(q: *Req) !void {
    try account.rateLimit(q, "create-saved", 30, 3600_000);
    const chat = try chats.createSaved(&q.r, q.user(), try q.bodyObj());
    return q.json(.{ .chat = try chats.chatFor(&q.r, chat, q.user().get("_id"), null) });
}

fn readAll(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    try account.rateLimit(q, "read-all", 30, 60_000);
    const ids = try msgs.idList(a, try v.reqIds(r, q.b("chatIds"), "chatIds", 500));
    const rows = try col().members.find(a, .{ .chatId = .{ .@"$in" = ids }, .userId = q.user().get("_id"), .status = "active" }, .{});
    var cids: std.ArrayList(Val) = .empty;
    for (rows) |m| try cids.append(a, m.get("chatId"));
    const chats_ = try col().chats.find(a, .{ ._id = .{ .@"$in" = cids.items }, .deletedAt = .{ .@"$exists" = false } }, .{});
    var n: usize = 0;
    for (rows) |m| {
        var chat: ?Val = null;
        for (chats_) |c| if (val.same(c.get("_id"), m.get("chatId"))) {
            chat = c;
        };
        const c = chat orelse continue;
        if (!m.get("unread").truthy() and !m.get("markedUnread").truthy() and !m.get("mentions").truthy()) continue;
        _ = try msgs.markRead(r, c, m, q.user(), c.get("seq").asInt() orelse 0);
        n += 1;
    }
    return q.json(.{ .read = n });
}

// ---- Chat settings and membership ---------------------------------------------------------------

fn patch(q: *Req) !void {
    const cm = try member(q);
    const fresh = try chats.updateChat(&q.r, cm.chat, cm.member, q.user(), try q.bodyObj());
    return q.json(.{ .chat = try chats.chatFor(&q.r, fresh, q.user().get("_id"), null) });
}

/// Personal settings for a chat: mute, pin, archive, mark unread, lock, draft.
fn state(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const cm = try member(q);
    const chat = cm.chat;
    const m = cm.member;
    const b = try q.bodyObj();
    const set = try Val.object(a);
    const unset = try Val.object(a);
    if (b.get("mutedUntil") != .undef) {
        const mu = b.get("mutedUntil");
        if (mu == .null or (mu == .num and mu.num == 0)) try set.put(a, "mutedUntil", .null) else try set.put(a, "mutedUntil", .{ .date = @min(try v.reqInt(r, mu, "mutedUntil", .{ .min = 0 }), 32503680000000) });
    }
    if (b.get("pinned") != .undef) {
        if (try v.reqBool(r, b.get("pinned"), "pinned")) {
            const n = try col().members.count(a, .{ .userId = q.user().get("_id"), .status = "active", .pinnedAt = .{ .@"$ne" = Val.null }, .archived = .{ .@"$ne" = true } }, .{});
            try r.ensure(n < Limits.pinned_chats or m.get("pinnedAt").truthy(), try r.fmt("You can pin up to {d} chats", .{Limits.pinned_chats}), 400, null);
            try set.put(a, "pinnedAt", if (m.get("pinnedAt").truthy()) m.get("pinnedAt") else A.now());
        } else try set.put(a, "pinnedAt", .null);
    }
    if (b.get("archived") != .undef) {
        const arch = try v.reqBool(r, b.get("archived"), "archived");
        try set.set(a, "archived", arch);
        if (arch) try set.put(a, "pinnedAt", .null);
    }
    if (b.get("markedUnread") != .undef) try set.set(a, "markedUnread", try v.reqBool(r, b.get("markedUnread"), "markedUnread"));
    if (b.get("locked") != .undef) {
        if (try v.reqBool(r, b.get("locked"), "locked")) {
            try r.ensure(q.user().get("chatLock").truthy(), "Set a chat lock code first", 400, "no_lock_code");
            try set.set(a, "locked", true);
        } else try unset.set(a, "locked", "");
    }
    if (b.get("draft") != .undef) {
        const d = b.get("draft");
        if (d == .null) try unset.set(a, "draft", "") else {
            _ = try v.reqObj(r, d, "draft");
            // Drafts in encrypted chats arrive encrypted; the server just syncs them between devices.
            const enc_chat = chat.get("encrypted").truthy();
            const text: Val = if (enc_chat) .undef else if (try v.str(r, d.get("text"), "draft.text", .{ .max = Limits.text_length, .optional = true, .trim = false })) |t| Val{ .str = t } else .undef;
            const enc: Val = if (enc_chat and d.get("enc").truthy()) try val.from(a, .{
                .e = try v.reqInt(r, d.path("enc.e"), "e", .{ .min = 1 }),
                .iv = try v.reqB64(r, d.path("enc.iv"), "iv", 32),
                .ct = try v.reqB64(r, d.path("enc.ct"), "ct", 48 * 1024),
            }) else .undef;
            try set.set(a, "draft", .{ .text = text, .enc = enc, .replyTo = if (d.get("replyTo").truthy()) Val{ .str = try r.str(idv(try v.reqId(r, d.get("replyTo"), "replyTo"))) } else Val.null, .at = A.now() });
        }
    }
    const update = try Val.object(a);
    if (set.len() > 0) try update.put(a, "$set", set);
    if (unset.len() > 0) try update.put(a, "$unset", unset);
    if (update.len() > 0) _ = try col().members.updateOne(a, .{ ._id = m.get("_id") }, update, .{});
    const fresh = (try col().members.findOne(a, .{ ._id = m.get("_id") }, .{})) orelse m;
    const me_v = (try ser.chat(a, chat, fresh, q.user().get("_id"), .{})).get("me");
    _ = rt.toUser(a, q.user().get("_id"), "chat.state", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .me = me_v }));
    return q.json(.{ .me = me_v });
}

fn members(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const cm = try member(q);
    const chat = cm.chat;
    const filter = try v.reqOneOf(r, if (q.qv("filter").truthy()) q.qv("filter") else Val.s("all"), "filter", &.{ "all", "admins", "banned", "requests" });
    const f = try val.from(a, .{ .chatId = chat.get("_id") });
    if (std.mem.eql(u8, filter, "all")) try f.set(a, "status", "active");
    if (std.mem.eql(u8, filter, "admins")) {
        try f.set(a, "status", "active");
        try f.set(a, "role", .{ .@"$in" = .{ "owner", "admin" } });
    }
    if (std.mem.eql(u8, filter, "banned")) try f.set(a, "status", "banned");
    if (std.mem.eql(u8, filter, "requests")) try f.set(a, "status", "requested");
    if (eq(chat.get("type"), "channel") and std.mem.eql(u8, filter, "all")) {
        const role = cm.member.get("role");
        try r.ensure(eq(role, "owner") or eq(role, "admin"), "Only admins can see subscribers", 403, null);
    }
    const limit = @min(try v.reqInt(r, if (q.qv("limit") != .undef) q.qv("limit") else Val.n(200), "limit", .{ .min = 1, .max = 500 }), 500);
    const offset = try v.reqInt(r, if (q.qv("offset") != .undef) q.qv("offset") else Val.n(0), "offset", .{ .min = 0 });
    const rows = try col().members.find(a, f, .{ .sort = .{ .role = 1, .joinedAt = 1 }, .skip = offset, .limit = limit });
    var uids: std.ArrayList(Val) = .empty;
    for (rows) |m| try uids.append(a, m.get("userId"));
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = uids.items } }, .{});
    const serialized = try account.usersFor(r, q.user(), users, false);
    const userOf = struct {
        fn find(list_: Val, id: Val) Val {
            for (list_.items()) |u| if (val.same(u.get("id"), id)) return u;
            return .null;
        }
    }.find;
    const Ctx = struct { users: Val };
    const order = struct {
        fn rank(role: Val) i32 {
            if (eq(role, "owner")) return 0;
            if (eq(role, "admin")) return 1;
            return 2;
        }
        fn online(c: Ctx, m: Val) i32 {
            const u = userOf(c.users, m.get("userId"));
            return if (eq(u.path("presence.status"), "online")) 1 else 0;
        }
        fn lt(c: Ctx, x: Val, y: Val) bool {
            const d = rank(x.get("role")) - rank(y.get("role"));
            if (d != 0) return d < 0;
            return online(c, y) - online(c, x) < 0;
        }
    };
    std.mem.sort(Val, rows, Ctx{ .users = serialized }, order.lt);
    var out = try Val.array(a);
    const needle = if (q.query("q")) |t| (if (t.len > 0) try std.ascii.allocLowerString(a, t) else null) else null;
    for (rows) |m| {
        const u = userOf(serialized, m.get("userId"));
        if (needle) |n| {
            const dn = try std.ascii.allocLowerString(a, u.get("displayName").asStr() orelse "");
            const un = try std.ascii.allocLowerString(a, u.get("username").asStr() orelse "");
            if (std.mem.indexOf(u8, dn, n) == null and std.mem.indexOf(u8, un, n) == null) continue;
        }
        const o = try ser.member(a, m);
        try o.put(a, "user", u);
        try out.push(a, o);
    }
    return q.json(.{ .members = out, .total = try col().members.count(a, f, .{}), .online = rt.onlineMembers(a, chat.get("_id")).len });
}

fn addMembers(q: *Req) !void {
    const cm = try member(q);
    const ids = try msgs.idList(q.r.a, try v.reqIds(&q.r, q.b("userIds"), "userIds", 200));
    return q.json(try chats.addMembers(&q.r, cm.chat, cm.member, q.user(), ids.items()));
}

fn removeMember(q: *Req) !void {
    const cm = try member(q);
    const ban = (if (q.query("ban")) |b| std.mem.eql(u8, b, "true") else false) or q.b("ban").isTrue();
    try chats.removeMember(&q.r, cm.chat, cm.member, q.user(), idv(try v.reqId(&q.r, q.pv("userId"), "userId")), ban);
    return q.json(.{ .ok = true });
}

fn unban(q: *Req) !void {
    const cm = try member(q);
    try chats.unban(&q.r, cm.chat, cm.member, idv(try v.reqId(&q.r, q.pv("userId"), "userId")));
    return q.json(.{ .ok = true });
}

fn setAdmin(q: *Req) !void {
    const cm = try member(q);
    try chats.setAdmin(&q.r, cm.chat, cm.member, q.user(), idv(try v.reqId(&q.r, q.pv("userId"), "userId")), try q.bodyObj());
    return q.json(.{ .ok = true });
}

fn owner(q: *Req) !void {
    const cm = try member(q);
    try chats.transferOwnership(&q.r, cm.chat, cm.member, q.user(), idv(try v.reqId(&q.r, q.pv("userId"), "userId")));
    return q.json(.{ .ok = true });
}

fn decide(q: *Req) !void {
    const cm = try member(q);
    return q.json(try chats.decideJoinRequest(&q.r, cm.chat, cm.member, q.user(), idv(try v.reqId(&q.r, q.pv("userId"), "userId")), q.b("approve").isTrue()));
}

fn joinResult(q: *Req, result: Val) !void {
    const out = try val.clone(q.r.a, result);
    try out.put(q.r.a, "chat", try chats.chatFor(&q.r, result.get("chat"), q.user().get("_id"), null));
    return q.json(out);
}

fn join(q: *Req) !void {
    const r = &q.r;
    const chat = try access.getChat(r, q.pv("chatId"));
    try r.ensure(chat.get("usernameLower").truthy(), "This chat is private. Ask for an invite link.", 403, "private_chat");
    return joinResult(q, try chats.join(r, chat, q.user(), "username", null));
}

fn leave(q: *Req) !void {
    const cm = try member(q);
    try chats.leave(&q.r, cm.chat, cm.member, q.user());
    return q.json(.{ .ok = true });
}

fn delete(q: *Req) !void {
    const cm = try member(q);
    try chats.deleteChat(&q.r, cm.chat, cm.member, q.user());
    return q.json(.{ .ok = true });
}

fn clear(q: *Req) !void {
    const cm = try member(q);
    try chats.clearHistory(&q.r, cm.chat, cm.member, q.user(), q.b("forEveryone").isTrue());
    return q.json(.{ .ok = true });
}

fn handoff(q: *Req) !void {
    const cm = try member(q);
    try ai.requestHuman(&q.r, cm.chat, q.user());
    return q.json(.{ .ok = true });
}

// ---- Invite links -----------------------------------------------------------------------------

fn isAdmin(m: Val) bool {
    return eq(m.get("role"), "owner") or eq(m.get("role"), "admin");
}

fn invites(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const cm = try member(q);
    try r.ensure(access.can(cm.chat, cm.member, "inviteUsers") or access.can(cm.chat, cm.member, "addMembers"), "You cannot see invite links here", 403, null);
    const f = try val.from(a, .{ .chatId = cm.chat.get("_id"), .revoked = false });
    if (!isAdmin(cm.member)) try f.put(a, "createdBy", q.user().get("_id"));
    const rows = try col().invites.find(a, f, .{ .sort = .{ .createdAt = -1 }, .limit = 100 });
    var out = try Val.array(a);
    for (rows) |i| try out.push(a, try chats.serializeInvite(r, i));
    return q.json(.{ .invites = out });
}

fn createInvite(q: *Req) !void {
    const cm = try member(q);
    const inv = try chats.createInvite(&q.r, cm.chat, cm.member, q.user(), try q.bodyObj());
    return q.json(.{ .invite = try chats.serializeInvite(&q.r, inv) });
}

fn revokeInvite(q: *Req) !void {
    const a = q.r.a;
    const cm = try member(q);
    const f = try val.from(a, .{ .chatId = cm.chat.get("_id"), .code = q.param("code") });
    if (!isAdmin(cm.member)) try f.put(a, "createdBy", q.user().get("_id"));
    _ = try col().invites.updateOne(a, f, .{ .@"$set" = .{ .revoked = true } }, .{});
    return q.json(.{ .ok = true });
}

fn previewInvite(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const inv = try chats.findInvite(r, q.pv("code"));
    const chat = try access.getChat(r, inv.get("chatId"));
    try r.ensure(try sameApp(r, chat.get("appId"), q.user().get("appId")), "This invite link is invalid", 404, null);
    const m = try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = q.user().get("_id") }, .{});
    const out = try ser.chat(a, chat, .null, q.user().get("_id"), .{});
    try out.set(a, "preview", true);
    return q.json(.{ .chat = out, .member = m != null and eq(m.?.get("status"), "active"), .requestApproval = inv.get("requestApproval") });
}

fn joinInvite(q: *Req) !void {
    const r = &q.r;
    const inv = try chats.findInvite(r, q.pv("code"));
    const chat = try access.getChat(r, inv.get("chatId"));
    return joinResult(q, try chats.join(r, chat, q.user(), "invite", inv));
}

// ---- Encryption keys for a chat ---------------------------------------------------------------

fn getKeys(q: *Req) !void {
    const cm = try member(q);
    return q.json(.{ .epoch = cm.chat.get("keyEpoch").asInt() orelse 0, .rotationNeeded = cm.chat.get("rotationNeeded").truthy(), .keys = try keys.myChatKeys(&q.r, cm.chat, q.user()) });
}

fn keyMembers(q: *Req) !void {
    const a = q.r.a;
    const cm = try member(q);
    // Everyone a new chat key must be wrapped for, with their public keys.
    const rows = try col().members.find(a, .{ .chatId = cm.chat.get("_id"), .status = "active" }, .{ .projection = .{ .userId = 1 }, .limit = Limits.encrypted_group_members + 10 });
    var ids: std.ArrayList(Val) = .empty;
    for (rows) |m| try ids.append(a, m.get("userId"));
    return q.json(.{ .members = try keys.publicKeys(&q.r, ids.items) });
}

fn postKeys(q: *Req) !void {
    try account.rateLimit(q, "chat-keys", 120, 60_000);
    const cm = try member(q);
    return q.json(try keys.storeChatKeys(&q.r, cm.chat, cm.member, q.user(), try q.bodyObj()));
}

// ---- Messages ---------------------------------------------------------------------------------

fn numQ(q: *Req, k: []const u8) !?i64 {
    const x = q.qv(k);
    if (x == .undef) return null;
    return try v.reqInt(&q.r, x, k, .{ .min = 0 });
}

fn messages(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const cm = try reader(q);
    const tag: ?[]const u8 = if (q.qv("tag").truthy()) try v.reqOneOf(r, q.qv("tag"), "tag", &.{ "photo", "video", "file", "voice", "round", "audio", "gif", "link", "poll", "music" }) else null;
    const lim = try numQ(q, "limit");
    const docs = try msgs.history(r, cm.chat, cm.member, .{ .before = try numQ(q, "before"), .after = try numQ(q, "after"), .around = try numQ(q, "around"), .limit = if (lim) |l| (if (l != 0) l else 50) else 50, .tag = tag });
    var out = try Val.array(a);
    for (docs) |d| try out.push(a, try ser.message(a, d, q.user().get("_id"), cm.chat));
    return q.json(.{ .messages = out, .floor = msgs.visibleFrom(cm.chat, cm.member) });
}

fn scheduled(q: *Req) !void {
    const a = q.r.a;
    const cm = try member(q);
    const docs = try col().messages.find(a, .{ .chatId = cm.chat.get("_id"), .senderId = q.user().get("_id"), .scheduledAt = .{ .@"$type" = "date" } }, .{ .sort = .{ .scheduledAt = 1 }, .limit = 100 });
    var out = try Val.array(a);
    for (docs) |d| try out.push(a, try ser.message(a, d, q.user().get("_id"), cm.chat));
    return q.json(.{ .messages = out });
}

fn sendScheduled(q: *Req) !void {
    const cm = try member(q);
    try msgs.publishScheduledNow(&q.r, cm.chat, q.user(), idv(try v.reqId(&q.r, q.pv("id"), "id")));
    return q.json(.{ .ok = true });
}

fn oneMessage(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const cm = try reader(q);
    const doc = try store.findOne(r, cm.chat, idv(try v.reqId(r, q.pv("id"), "id")), try val.from(a, .{ .hiddenFor = .{ .@"$ne" = q.user().get("_id") } }));
    const ok = if (doc) |d| (if (d.get("seq") == .null) val.same(d.get("senderId"), q.user().get("_id")) else (d.get("seq").asNum() orelse 0) > @as(f64, @floatFromInt(msgs.visibleFrom(cm.chat, cm.member)))) else false;
    try r.ensure(ok, "Message not found", 404, null);
    return q.json(.{ .message = try ser.message(a, doc.?, q.user().get("_id"), cm.chat) });
}

fn featureChecks(r: *Rq, user: Val, input: Val) !void {
    if (!user.get("appId").truthy()) return;
    var kinds: std.ArrayList([]const u8) = .empty;
    for (input.get("media").items()) |m| if (m.get("kind").asStr()) |k| try kinds.append(r.a, k);
    for (input.get("tags").items()) |t| if (t.asStr()) |k| try kinds.append(r.a, k);
    const has = struct {
        fn f(list_: []const []const u8, x: []const u8) bool {
            for (list_) |y| if (std.mem.eql(u8, x, y)) return true;
            return false;
        }
    }.f;
    const k = kinds.items;
    if (has(k, "photo") or has(k, "gif")) try apps.assertFeature(r, user, "photos", "Sending photos is turned off in this app");
    if (has(k, "video") or has(k, "file") or has(k, "audio")) try apps.assertFeature(r, user, "files", "Sending files is turned off in this app");
    if (has(k, "voice")) try apps.assertFeature(r, user, "voiceMessages", "Voice messages are turned off in this app");
    if (has(k, "round")) try apps.assertFeature(r, user, "videoMessages", "Video messages are turned off in this app");
    if (input.get("poll").truthy()) try apps.assertFeature(r, user, "polls", "Polls are turned off in this app");
    if (input.get("sticker").truthy() or has(k, "sticker")) try apps.assertFeature(r, user, "stickers", "Stickers are turned off in this app");
    if (input.get("location").truthy() or has(k, "location")) try apps.assertFeature(r, user, "location", "Sharing locations is turned off in this app");
    if (input.get("contact").truthy() or has(k, "contact")) try apps.assertFeature(r, user, "contacts", "Sharing contacts is turned off in this app");
    if (input.get("replyTo").truthy()) try apps.assertFeature(r, user, "replies", "Replies are turned off in this app");
    if (input.get("fwd").truthy() or input.get("forwarded").truthy()) try apps.assertFeature(r, user, "forwarding", "Forwarding is turned off in this app");
    if (input.get("scheduledAt").truthy() or input.get("whenOnline").truthy()) try apps.assertFeature(r, user, "scheduled", "Scheduled messages are turned off in this app");
    if (input.get("ttl").truthy()) try apps.assertFeature(r, user, "selfDestruct", "Self-destructing messages are turned off in this app");
}

fn send(q: *Req) !void {
    try account.rateLimit(q, "send", 60, 10_000);
    const cm = try member(q);
    const body = try q.bodyObj();
    try featureChecks(&q.r, q.user(), body);
    const doc = try msgs.sendMessage(&q.r, cm.chat, q.user(), body, .{ .member = cm.member });
    return q.json(.{ .message = try ser.message(q.r.a, doc, q.user().get("_id"), cm.chat) });
}

fn edit(q: *Req) !void {
    const r = &q.r;
    const cm = try member(q);
    try apps.assertFeature(r, q.user(), "editing", "Editing is turned off in this app");
    const doc = try msgs.editMessage(r, cm.chat, cm.member, q.user(), idv(try v.reqId(r, q.pv("id"), "id")), try q.bodyObj());
    return q.json(.{ .message = try ser.message(r.a, doc, q.user().get("_id"), cm.chat) });
}

fn deleteMessages(q: *Req) !void {
    const r = &q.r;
    const cm = try member(q);
    try apps.assertFeature(r, q.user(), "deleting", "Deleting messages is turned off in this app");
    const ids = try msgs.idList(r.a, try v.reqIds(r, q.b("ids"), "ids", 100));
    return q.json(try msgs.deleteMessages(r, cm.chat, cm.member, q.user(), ids.items(), q.b("forEveryone").isTrue()));
}

fn react(q: *Req) !void {
    const r = &q.r;
    try account.rateLimit(q, "react", 60, 10_000);
    const cm = try member(q);
    try apps.assertFeature(r, q.user(), "reactions", "Reactions are turned off in this app");
    const on = !(q.b("on") == .bool and !q.b("on").bool);
    return q.json(.{ .reactions = try msgs.react(r, cm.chat, q.user(), idv(try v.reqId(r, q.pv("id"), "id")), q.b("emoji"), on) });
}

fn reactions(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const cm = try member(q);
    try r.ensure(!eq(cm.chat.get("type"), "channel"), "Reactions in channels are anonymous", 403, null);
    const doc = (try store.findOne(r, cm.chat, idv(try v.reqId(r, q.pv("id"), "id")), null)) orelse return r.fail(404, "Message not found", null);
    var uids: std.ArrayList(Val) = .empty;
    for (doc.get("reactions").keys()) |kv| for (kv.v.items()) |u| try uids.append(a, u);
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = uids.items } }, .{});
    const serialized = try account.usersFor(r, q.user(), users, false);
    var out = try Val.array(a);
    for (doc.get("reactions").keys()) |kv| for (kv.v.items()) |u| {
        for (serialized.items()) |s| if (val.same(s.get("id"), u)) {
            try out.push(a, try val.from(a, .{ .emoji = kv.k, .user = s }));
            break;
        };
    };
    return q.json(.{ .reactions = out });
}

fn vote(q: *Req) !void {
    const r = &q.r;
    const cm = try member(q);
    const poll = try msgs.vote(r, cm.chat, q.user(), idv(try v.reqId(r, q.pv("id"), "id")), q.b("options"));
    return q.json(.{ .poll = try ser.poll(r.a, poll, .{ .str = try r.str(q.user().get("_id")) }) });
}

fn closePoll(q: *Req) !void {
    const r = &q.r;
    const cm = try member(q);
    const poll = try msgs.closePoll(r, cm.chat, cm.member, q.user(), idv(try v.reqId(r, q.pv("id"), "id")));
    return q.json(.{ .poll = try ser.poll(r.a, poll, .{ .str = try r.str(q.user().get("_id")) }) });
}

fn voters(q: *Req) !void {
    const cm = try member(q);
    return q.json(.{ .voters = try msgs.pollVoters(&q.r, cm.chat, idv(try v.reqId(&q.r, q.pv("id"), "id"))) });
}

fn readers(q: *Req) !void {
    const cm = try member(q);
    return q.json(.{ .userIds = try msgs.readers(&q.r, cm.chat, q.user(), idv(try v.reqId(&q.r, q.pv("id"), "id"))) });
}

fn pin(q: *Req) !void {
    const r = &q.r;
    const cm = try member(q);
    try apps.assertFeature(r, q.user(), "pinning", "Pinning is turned off in this app");
    return q.json(.{ .pinned = try msgs.pin(r, cm.chat, cm.member, q.user(), idv(try v.reqId(r, q.pv("id"), "id")), q.b("silent").isTrue(), q.b("unpin").isTrue()) });
}

fn unpinAll(q: *Req) !void {
    const cm = try member(q);
    try msgs.unpinAll(&q.r, cm.chat, cm.member);
    return q.json(.{ .ok = true });
}

fn stop(q: *Req) !void {
    const cm = try member(q);
    return q.json(.{ .stopped = ai.stop(idv(try v.reqId(&q.r, q.pv("id"), "id")), cm.chat.get("_id")) });
}

fn regenerate(q: *Req) !void {
    const cm = try member(q);
    try ai.regenerate(&q.r, cm.chat, idv(try v.reqId(&q.r, q.pv("id"), "id")), q.user());
    return q.json(.{ .ok = true });
}

/// Inline keyboard buttons on bot and app messages: tells the app (webhook) and the chat.
fn button(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const cm = try member(q);
    const doc = try store.findOne(r, cm.chat, idv(try v.reqId(r, q.pv("id"), "id")), null);
    const data = try v.reqStr(r, q.b("data"), "data", .{ .min = 1, .max = 128 });
    var found = false;
    if (doc) |d| for (d.get("buttons").items()) |row| for (row.items()) |b| if (eq(b.get("data"), data)) {
        found = true;
    };
    try r.ensure(found, "Button not found", 404, null);
    try events.emit(a, .button_pressed, try val.from(a, .{ .chat = cm.chat, .messageId = doc.?.get("_id"), .user = q.user(), .data = data }));
    rt.toChat(a, cm.chat.get("_id"), "message.button", try val.from(a, .{ .chatId = try r.str(cm.chat.get("_id")), .id = try r.str(doc.?.get("_id")), .userId = try r.str(q.user().get("_id")), .data = data }), null);
    return q.json(.{ .ok = true });
}

fn read(q: *Req) !void {
    const cm = try member(q);
    return q.json(try msgs.markRead(&q.r, cm.chat, cm.member, q.user(), try v.reqInt(&q.r, q.b("seq"), "seq", .{ .min = 0 })));
}

fn views(q: *Req) !void {
    const cm = try member(q);
    try msgs.addViews(&q.r, cm.chat, cm.member, try v.reqInt(&q.r, q.b("seq"), "seq", .{ .min = 0 }));
    return q.json(.{ .ok = true });
}

/// Shared media counts for the chat info panel.
fn mediaCounts(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const cm = try member(q);
    const floor = msgs.visibleFrom(cm.chat, cm.member);
    const tags = .{ "photo", "video", "file", "voice", "round", "audio", "link", "gif" };
    const filter = try val.from(a, .{ .deletedAt = .{ .@"$exists" = false }, .hiddenFor = .{ .@"$ne" = q.user().get("_id") }, .tags = .{ .@"$in" = tags } });
    const counts = try Val.object(a);
    if (store.isAppChat(cm.chat)) {
        // Counted over the newest thousand messages the app keeps.
        for (try store.list(r, cm.chat, .{ .filter = filter, .after = floor, .limit = 1000 })) |d| for (d.get("tags").items()) |t| {
            const k = t.asStr() orelse continue;
            try counts.set(a, k, (counts.get(k).asNum() orelse 0) + 1);
        };
        return q.json(.{ .counts = counts });
    }
    const match = try val.from(a, .{ .chatId = cm.chat.get("_id"), .seq = .{ .@"$gt" = floor } });
    for (filter.keys()) |kv| try match.put(a, kv.k, kv.v);
    const rows = try col().messages.aggregate(a, .{ .{ .@"$match" = match }, .{ .@"$unwind" = "$tags" }, .{ .@"$group" = .{ ._id = "$tags", .count = .{ .@"$sum" = 1 } } } });
    for (rows) |x| try counts.put(a, try r.str(x.get("_id")), x.get("count"));
    return q.json(.{ .counts = counts });
}
