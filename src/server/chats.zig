//! Chats and memberships (src/services/chats.js): create, join, leave, invite, promote, restrict.

const std = @import("std");
const A = @import("app.zig");
const v = @import("validate.zig");
const rt = @import("realtime.zig");
const ser = @import("serialize.zig");
const msgs = @import("messages.zig");
const store = @import("store.zig");
const keys = @import("keys.zig");
const access = @import("access.zig");
const events = @import("events.zig");
const teams = @import("teams.zig");
const moderation = @import("moderation.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;
const Limits = A.Limits;
const eq = access.eq;

fn col() *A.Cols {
    return &A.app.col;
}

fn idv(x: A.ObjectId) Val {
    return .{ .id = x };
}

/// Whether chats in this scope are end-to-end encrypted by default.
pub fn e2eeFor(r: *Rq, user: Val) !bool {
    if (!user.get("appId").truthy()) return true;
    const app_doc = try col().apps.findOne(r.a, .{ ._id = user.get("appId") }, .{ .projection = .{ .@"settings.e2ee" = 1 } });
    return if (app_doc) |d| eq(d.path("settings.e2ee"), "on") else false;
}

/// A chat for one user, with the extras the chat list needs.
pub fn chatFor(r: *Rq, chat_in: Val, user_id: Val, membership_: ?Val) !Val {
    const a = r.a;
    var chat = chat_in;
    const membership = membership_ orelse (try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = user_id }, .{})) orelse Val.null;
    var peer: Val = .null;
    if (eq(chat.get("type"), "private") or eq(chat.get("type"), "bot")) {
        const other = try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = .{ .@"$ne" = user_id } }, .{ .projection = .{ .userId = 1 } });
        if (other) |o| if (try col().users.findOne(a, .{ ._id = o.get("userId") }, .{})) |pu| {
            const contact = try col().contacts.findOne(a, .{ .userId = pu.get("_id"), .contactId = user_id }, .{ .projection = .{ ._id = 1 } });
            const mine = try col().contacts.findOne(a, .{ .userId = user_id, .contactId = pu.get("_id") }, .{ .projection = .{ .name = 1 } });
            peer = try ser.user(a, pu, user_id, .{ .is_contact = contact != null });
            if (mine) |m| if (m.get("name").truthy()) try peer.set("contactName", m.get("name"));
        };
    }
    const call = try col().calls.findOne(a, .{ .chatId = chat.get("_id"), .status = .{ .@"$in" = .{ "ringing", "active" } } }, .{ .projection = .{ .video = 1, .participants = 1, .status = 1, .group = 1 } });
    var team: Val = .null;
    var visitor: Val = .null;
    if (chat.get("teamId").truthy()) {
        const extras = try teams.extrasFor(r, &.{chat}, user_id);
        if (extras.len > 0) {
            team = extras[0].team;
            visitor = extras[0].visitor;
        }
    }
    if (chat.path("lastMessage.contentInApp").truthy()) {
        var copy = [_]Val{try val.clone(a, chat)};
        try msgs.fillLastMessages(r, &copy);
        chat = copy[0];
    }
    var active_call: Val = .null;
    if (call) |c| if (c.get("group").truthy()) {
        var n: usize = 0;
        for (c.get("participants").items()) |p| if (!p.get("leftAt").truthy()) {
            n += 1;
        };
        active_call = try val.from(a, .{ .id = try r.str(c.get("_id")), .video = c.get("video"), .count = n });
    };
    return ser.chat(a, chat, membership, user_id, .{
        .peer = peer,
        .team = team,
        .visitor = visitor,
        .last_message = if (chat.get("lastMessage").truthy()) try ser.message(a, chat.get("lastMessage"), user_id, chat) else .null,
        .active_call = active_call,
    });
}

/// Tells a user's open tabs about a chat (new, changed, or joined).
pub fn pushChat(r: *Rq, chat: Val, user_id: Val, event: []const u8) !void {
    _ = rt.toUser(r.a, user_id, event, try chatFor(r, chat, user_id, null));
}

fn memberDoc(r: *Rq, chat: Val, user_id: Val, role: []const u8, extra: ?Val) !Val {
    const a = r.a;
    const now = A.now();
    const seq = chat.get("seq").asInt() orelse 0;
    const doc = try val.from(a, .{ .chatId = chat.get("_id"), .userId = user_id, .chatType = chat.get("type"), .role = role, .status = "active", .joinedAt = now, .joinedSeq = seq, .lastReadSeq = seq, .unread = 0, .mentions = 0, .lastActivityAt = now });
    if (extra) |x| for (x.keys(), x.vals()) |kv_k, kv_v| try doc.set(kv_k, kv_v);
    return doc;
}

// ---- Creating chats --------------------------------------------------------------------------

pub fn openPrivate(r: *Rq, user: Val, other_id: Val) !Val {
    const a = r.a;
    const other = (try col().users.findOne(a, .{ ._id = other_id, .deletedAt = .{ .@"$exists" = false } }, .{})) orelse return r.fail(404, "User not found", "user_not_found");
    try r.ensure(access.sameScope(user, other), "User not found", 404, "user_not_found");
    if (val.same(other.get("_id"), user.get("_id"))) {
        return (try col().chats.findOne(a, .{ .pairKey = try r.fmt("saved:{s}", .{try r.str(user.get("_id"))}) }, .{})) orelse .null;
    }
    const is_bot = eq(other.get("kind"), "bot");
    const pk = try access.pairKey(a, user.get("_id"), other.get("_id"));
    const key = if (is_bot) try r.fmt("bot:{s}", .{pk}) else pk;
    if (try col().chats.findOne(a, .{ .pairKey = key }, .{})) |existing| {
        // Re-activate the caller's membership if they had deleted the chat.
        _ = try col().members.updateOne(a, .{ .chatId = existing.get("_id"), .userId = user.get("_id") }, .{ .@"$set" = .{ .status = "active" }, .@"$unset" = .{ .hiddenAt = "" } }, .{});
        rt.joinedChat(user.get("_id"), existing.get("_id"), existing.get("type"));
        return existing;
    }
    if (is_bot) {
        const bot = try col().bots.findOne(a, .{ ._id = other.get("_id") }, .{ .projection = .{ .public = 1, .ownerId = 1, .appId = 1 } });
        const ok = if (bot) |b| b.get("public").truthy() or val.same(b.get("ownerId"), user.get("_id")) or (b.get("appId").truthy() and val.same(b.get("appId"), user.get("appId"))) else false;
        try r.ensure(ok, "This bot is private", 403, "bot_private");
    }
    const encrypted = !is_bot and try e2eeFor(r, user);
    // People who never opened Reseal get keys now, so they can be messaged right away.
    if (encrypted and !other.path("keys.enc").truthy()) _ = try keys.provisionKeys(r, other);
    const now = A.now();
    const chat = try val.from(a, .{
        .type = if (is_bot) "bot" else "private",
        .appId = if (user.get("appId").truthy()) user.get("appId") else Val.null,
        .encrypted = encrypted,
        .pairKey = key,
        .createdBy = user.get("_id"),
        .createdAt = now,
        .seq = 0,
        .keyEpoch = 0,
        .memberCount = 2,
        .lastMessageAt = now,
    });
    if (is_bot) try chat.set("botId", other.get("_id"));
    _ = col().chats.insertOne(a, chat) catch |e| {
        if (e == error.DuplicateKey) return (try col().chats.findOne(a, .{ .pairKey = key }, .{})) orelse .null;
        return e;
    };
    _ = try col().members.insertMany(a, &.{ try memberDoc(r, chat, user.get("_id"), "member", null), try memberDoc(r, chat, other.get("_id"), "member", null) });
    rt.joinedChat(user.get("_id"), chat.get("_id"), chat.get("type"));
    rt.joinedChat(other.get("_id"), chat.get("_id"), chat.get("type"));
    try events.emit(a, .chat_created, try val.from(a, .{ .chat = chat, .creator = user, .memberIds = .{ user.get("_id"), other.get("_id") } }));
    if (is_bot) try events.emit(a, .bot_chat_started, try val.from(a, .{ .chat = chat, .user = user, .botUserId = other.get("_id") }));
    return chat;
}

/// People to add to a group, honouring their "who can add me" privacy.
fn filterInvitees(r: *Rq, actor: Val, ids: []const Val) !struct { allowed: []Val, skipped: Val } {
    const a = r.a;
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = ids }, .deletedAt = .{ .@"$exists" = false } }, .{});
    var allowed: std.ArrayList(Val) = .empty;
    var skipped = try Val.array(a);
    for (users) |u| {
        if (val.same(u.get("_id"), actor.get("_id")) or !access.sameScope(actor, u)) continue;
        if (eq(u.get("kind"), "bot")) {
            try allowed.append(a, u);
            continue;
        }
        if (try access.isBlocked(r, u.get("_id"), actor.get("_id")) or !(try access.allowedByPrivacy(r, u, actor.get("_id"), "groups"))) {
            try skipped.push(try r.sn(u.get("_id")));
            continue;
        }
        try allowed.append(a, u);
    }
    return .{ .allowed = allowed.items, .skipped = skipped };
}

pub fn createGroup(r: *Rq, user: Val, body: Val) !struct { chat: Val, skipped: Val } {
    const a = r.a;
    const type_ = try v.reqOneOf(r, if (body.get("type").truthy()) body.get("type") else Val.string("group"), "type", &.{ "group", "channel" });
    const title = try v.reqStr(r, body.get("title"), "title", .{ .min = 1, .max = 128 });
    const about = (try v.str(r, body.get("about"), "about", .{ .max = 1000, .optional = true })) orelse "";
    // Content checks (Wufour Moderation): titles and descriptions are readable even in encrypted groups.
    _ = try moderation.check(r, user, try val.from(a, .{ .type = "group", .field = "create" }), try val.from(a, .{ .title = title, .about = about }), null);
    const member_ids = try msgs.idList(a, try v.reqIds(r, if (body.get("members").truthy()) body.get("members") else try Val.array(a), "members", 200));
    const default_e2ee = try e2eeFor(r, user);
    // Channels are broadcasts and are never end-to-end encrypted.
    var encrypted = if (std.mem.eql(u8, type_, "group")) (if (body.get("encrypted") == .undef) default_e2ee else try v.reqBool(r, body.get("encrypted"), "encrypted")) else false;
    if (user.get("appId").truthy() and !default_e2ee) encrypted = false;
    const inv = try filterInvitees(r, user, member_ids.items());
    if (encrypted) for (inv.allowed) |u| if (!eq(u.get("kind"), "bot") and !u.path("keys.enc").truthy()) {
        _ = try keys.provisionKeys(r, u);
    };
    if (encrypted) try r.ensure(inv.allowed.len + 1 <= Limits.encrypted_group_members, try r.fmt("Encrypted groups can have up to {d} members", .{Limits.encrypted_group_members}), 400, null);

    const now = A.now();
    const chat = try val.from(a, .{
        .type = type_,
        .appId = if (user.get("appId").truthy()) user.get("appId") else Val.null,
        .encrypted = encrypted,
        .title = title,
        .about = about,
        .createdBy = user.get("_id"),
        .createdAt = now,
        .seq = 0,
        .keyEpoch = 0,
        .memberCount = 1 + inv.allowed.len,
        .lastMessageAt = now,
        .historyVisible = true,
        .pinned = try Val.array(a),
    });
    if (std.mem.eql(u8, type_, "group")) try chat.set("permissions", try access.defaultGroupPermissions(a));
    if (body.get("avatar").truthy()) try chat.set("avatar", try ownAvatar(r, user, body.get("avatar")));
    if (body.get("metadata").truthy()) try chat.set("metadata", (try v.meta(r, body.get("metadata"))) orelse .undef);
    _ = try col().chats.insertOne(a, chat);
    if (body.get("username").truthy()) _ = try setChatUsername(r, chat, body.get("username"));

    var members: std.ArrayList(Val) = .empty;
    try members.append(a, try memberDoc(r, chat, user.get("_id"), "owner", null));
    for (inv.allowed) |u| try members.append(a, try memberDoc(r, chat, u.get("_id"), if (std.mem.eql(u8, type_, "channel")) "subscriber" else "member", try val.from(a, .{ .invitedBy = user.get("_id") })));
    _ = try col().members.insertMany(a, members.items);
    for (members.items) |m| rt.joinedChat(m.get("userId"), chat.get("_id"), chat.get("type"));

    _ = try msgs.serviceMessage(r, chat, user.get("_id"), if (std.mem.eql(u8, type_, "channel")) "channel_created" else "group_created", try val.from(a, .{ .title = title }), false);
    const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;
    for (members.items) |m| try pushChat(r, fresh, m.get("userId"), "chat.new");
    var ids = try Val.array(a);
    for (members.items) |m| try ids.push(m.get("userId"));
    try events.emit(a, .chat_created, try val.from(a, .{ .chat = fresh, .creator = user, .memberIds = ids }));
    return .{ .chat = fresh, .skipped = inv.skipped };
}

/// An extra Saved chat: a private notes space for one topic.
pub fn createSaved(r: *Rq, user: Val, body: Val) !Val {
    const a = r.a;
    const title = try v.reqStr(r, body.get("title"), "title", .{ .min = 1, .max = 64 });
    const about = (try v.str(r, body.get("about"), "about", .{ .max = 300, .optional = true })) orelse "";
    const count = try col().members.count(a, .{ .userId = user.get("_id"), .chatType = "saved", .status = "active" }, .{});
    // The default Saved chat does not count toward the limit.
    try r.ensure(count <= Limits.saved_chats, try r.fmt("You can have up to {d} saved chats", .{Limits.saved_chats}), 400, null);
    const now = A.now();
    const chat = try val.from(a, .{
        .type = "saved",
        .appId = if (user.get("appId").truthy()) user.get("appId") else Val.null,
        .encrypted = try e2eeFor(r, user),
        .title = title,
        .about = about,
        .createdBy = user.get("_id"),
        .createdAt = now,
        .seq = 0,
        .keyEpoch = 0,
        .memberCount = 1,
        .lastMessageAt = now,
        .pinned = try Val.array(a),
    });
    _ = try col().chats.insertOne(a, chat);
    _ = try col().members.insertOne(a, try memberDoc(r, chat, user.get("_id"), "owner", null));
    rt.joinedChat(user.get("_id"), chat.get("_id"), chat.get("type"));
    try pushChat(r, chat, user.get("_id"), "chat.new");
    return chat;
}

/// A support conversation for an app visitor, staffed by the app's agents.
pub fn openSupport(r: *Rq, user: Val, app_doc: Val) !Val {
    const a = r.a;
    const key = try r.fmt("support:{s}", .{try r.str(user.get("_id"))});
    if (try col().chats.findOne(a, .{ .pairKey = key }, .{})) |existing| return existing;
    var agent_ids: std.ArrayList(Val) = .empty;
    for (app_doc.path("settings.widget.agentIds").items()) |x| if (v.oid(x)) |o| try agent_ids.append(a, idv(o));
    const bot_raw = app_doc.path("settings.widget.botId");
    const bot_id: ?Val = if (bot_raw.truthy()) (if (v.oid(.{ .str = try r.str(bot_raw) })) |o| idv(o) else null) else null;
    const now = A.now();
    const support_title = app_doc.path("settings.widget.supportTitle");
    const chat = try val.from(a, .{
        .type = "support",
        .appId = app_doc.get("_id"),
        .encrypted = false,
        .pairKey = key,
        .title = if (support_title.truthy()) support_title else Val{ .str = try r.fmt("{s} Support", .{try r.str(app_doc.get("name"))}) },
        .about = "",
        .createdBy = user.get("_id"),
        .createdAt = now,
        .seq = 0,
        .keyEpoch = 0,
        .lastMessageAt = now,
        .visitorId = user.get("_id"),
    });
    if (bot_id) |b| try chat.set("botId", b);
    var staff_ids: std.ArrayList(Val) = .empty;
    try staff_ids.appendSlice(a, agent_ids.items);
    if (bot_id) |b| try staff_ids.append(a, b);
    const staff = try col().users.find(a, .{ ._id = .{ .@"$in" = staff_ids.items } }, .{ .projection = .{ ._id = 1 } });
    try chat.set("memberCount", 1 + staff.len);
    _ = col().chats.insertOne(a, chat) catch |e| {
        if (e == error.DuplicateKey) return (try col().chats.findOne(a, .{ .pairKey = key }, .{})) orelse .null;
        return e;
    };
    var members: std.ArrayList(Val) = .empty;
    try members.append(a, try memberDoc(r, chat, user.get("_id"), "member", null));
    for (staff) |u| try members.append(a, try memberDoc(r, chat, u.get("_id"), "admin", try val.from(a, .{ .rights = try access.defaultAdminRights(a) })));
    _ = try col().members.insertMany(a, members.items);
    for (members.items) |m| rt.joinedChat(m.get("userId"), chat.get("_id"), chat.get("type"));
    for (members.items) |m| if (!val.same(m.get("userId"), user.get("_id"))) try pushChat(r, chat, m.get("userId"), "chat.new");
    var ids = try Val.array(a);
    for (members.items) |m| try ids.push(m.get("userId"));
    try events.emit(a, .chat_created, try val.from(a, .{ .chat = chat, .creator = user, .memberIds = ids }));
    return chat;
}

fn ownAvatar(r: *Rq, user: Val, media_id: Val) !Val {
    const a = r.a;
    const id = idv(try v.reqId(r, media_id, "avatar"));
    const media = try col().media.findOne(a, .{ ._id = id, .ownerId = user.get("_id"), .status = "ready" }, .{});
    try r.ensure(media != null and std.mem.startsWith(u8, media.?.get("mime").asStr() orelse "", "image/"), "Avatar must be an image you uploaded", 400, null);
    _ = try col().media.updateOne(a, .{ ._id = id }, .{ .@"$set" = .{ .public = true } }, .{});
    return id;
}

pub fn setChatUsername(r: *Rq, chat: Val, username: Val) !Val {
    const a = r.a;
    if (username == .null or (username == .str and username.str.len == 0)) {
        _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$unset" = .{ .username = "", .usernameLower = "" } }, .{});
        return .null;
    }
    const name = try v.reqStr(r, username, "username", .{ .pattern = v.isUsername });
    try r.ensure(!chat.get("encrypted").truthy(), "Encrypted groups cannot be public. Create an unencrypted group to give it a public link.", 400, null);
    const lower = try v.jsLower(a, name);
    const taken = try col().users.findOne(a, .{ .usernameLower = lower }, .{ .projection = .{ ._id = 1 } });
    try r.ensure(taken == null, "That username is taken", 409, "username_taken");
    _ = col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = .{ .username = name, .usernameLower = lower } }, .{}) catch |e| {
        if (e == error.DuplicateKey) return r.fail(409, "That username is taken", "username_taken");
        return e;
    };
    return .{ .str = name };
}

// ---- Membership changes ----------------------------------------------------------------------

pub fn activate(r: *Rq, chat: Val, user_id: Val, role: []const u8, extra: ?Val, actor_id: Val) !bool {
    const a = r.a;
    const existing = try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = user_id }, .{});
    if (existing) |e| if (eq(e.get("status"), "active")) return false;
    const doc = try memberDoc(r, chat, user_id, role, extra);
    if (existing) |e| {
        const rest = try val.clone(a, doc);
        rest.del("chatId");
        rest.del("userId");
        try rest.set("clearedSeq", e.get("clearedSeq").asInt() orelse 0);
        _ = try col().members.updateOne(a, .{ ._id = e.get("_id") }, .{ .@"$set" = rest, .@"$unset" = .{ .leftAt = "", .bannedUntil = "" } }, .{});
    } else _ = try col().members.insertOne(a, doc);
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$inc" = .{ .memberCount = 1 } }, .{});
    rt.joinedChat(user_id, chat.get("_id"), chat.get("type"));
    if (chat.get("encrypted").truthy()) try keys.requestKeys(r, chat, &.{user_id}, !(chat.get("historyVisible") == .bool and !chat.get("historyVisible").bool));
    try events.emit(a, .member_joined, try val.from(a, .{ .chat = chat, .userId = user_id, .actorId = actor_id }));
    return true;
}

pub fn addMembers(r: *Rq, chat: Val, member: Val, actor: Val, user_ids: []const Val) !Val {
    const a = r.a;
    const t = chat.get("type").asStr() orelse "";
    try r.ensure(std.mem.eql(u8, t, "group") or std.mem.eql(u8, t, "channel") or std.mem.eql(u8, t, "support"), "You cannot add people to this chat", 400, null);
    try r.ensure(access.can(chat, member, "addMembers") or access.can(chat, member, "inviteUsers"), "You cannot add members here", 403, "no_permission");
    const inv = try filterInvitees(r, actor, user_ids);
    const count = chat.get("memberCount").asInt() orelse 0;
    if (chat.get("encrypted").truthy()) for (inv.allowed) |u| if (!eq(u.get("kind"), "bot") and !u.path("keys.enc").truthy()) {
        _ = try keys.provisionKeys(r, u);
    };
    if (chat.get("encrypted").truthy()) try r.ensure(count + @as(i64, @intCast(inv.allowed.len)) <= Limits.encrypted_group_members, try r.fmt("Encrypted groups can have up to {d} members", .{Limits.encrypted_group_members}), 400, null);
    if (std.mem.eql(u8, t, "group")) try r.ensure(count + @as(i64, @intCast(inv.allowed.len)) <= Limits.group_members, try r.fmt("Groups can have up to {d} members", .{Limits.group_members}), 400, null);
    var added: std.ArrayList(Val) = .empty;
    for (inv.allowed) |u| {
        const banned = try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = u.get("_id"), .status = "banned" }, .{});
        if (banned != null and !access.can(chat, member, "banUsers")) {
            try inv.skipped.push(try r.sn(u.get("_id")));
            continue;
        }
        if (try activate(r, chat, u.get("_id"), if (std.mem.eql(u8, t, "channel")) "subscriber" else "member", try val.from(a, .{ .invitedBy = actor.get("_id") }), actor.get("_id"))) try added.append(a, u.get("_id"));
    }
    var added_s = try Val.array(a);
    for (added.items) |x| try added_s.push(try r.sn(x));
    if (added.items.len > 0) {
        _ = try msgs.serviceMessage(r, chat, actor.get("_id"), "members_added", try val.from(a, .{ .targetIds = added.items }), false);
        const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;
        for (added.items) |id| try pushChat(r, fresh, id, "chat.new");
        rt.toChat(a, chat.get("_id"), "chat.members", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .memberCount = fresh.get("memberCount") }), null);
    }
    return val.from(a, .{ .added = added_s, .skipped = inv.skipped });
}

pub fn join(r: *Rq, chat: Val, user: Val, via: []const u8, invite: ?Val) !Val {
    const a = r.a;
    try r.ensure(access.sameScope(user, chat), "Chat not found", 404, "chat_not_found");
    const existing = try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = user.get("_id") }, .{});
    if (existing) |e| if (eq(e.get("status"), "active")) return val.from(a, .{ .joined = false, .chat = chat });
    try r.ensure(!(existing != null and eq(existing.?.get("status"), "banned")), "You were banned from this chat", 403, "banned");
    const count = chat.get("memberCount").asInt() orelse 0;
    if (chat.get("encrypted").truthy()) try r.ensure(count < Limits.encrypted_group_members, "This group is full", 400, null);
    if (eq(chat.get("type"), "group")) try r.ensure(count < Limits.group_members, "This group is full", 400, null);
    const needs_approval = (chat.get("joinApproval").truthy() and std.mem.eql(u8, via, "username")) or (if (invite) |i| i.get("requestApproval").truthy() else false);
    if (needs_approval) {
        _ = try col().members.updateOne(a, .{ .chatId = chat.get("_id"), .userId = user.get("_id") }, .{
            .@"$set" = .{ .chatType = chat.get("type"), .status = "requested", .requestedAt = A.now(), .role = "member", .inviteCode = if (invite) |i| i.get("code") else Val.null },
        }, .{ .upsert = true });
        const admins = try col().members.find(a, .{ .chatId = chat.get("_id"), .status = "active", .role = .{ .@"$in" = .{ "owner", "admin" } } }, .{ .projection = .{ .userId = 1 } });
        var ids: std.ArrayList(Val) = .empty;
        for (admins) |x| try ids.append(a, x.get("userId"));
        rt.toUsers(a, ids.items, "chat.join_request", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .userId = try r.str(user.get("_id")) }));
        return val.from(a, .{ .joined = false, .requested = true, .chat = chat });
    }
    _ = try activate(r, chat, user.get("_id"), if (eq(chat.get("type"), "channel")) "subscriber" else "member", try val.from(a, .{ .via = via }), user.get("_id"));
    if (!eq(chat.get("type"), "channel")) _ = try msgs.serviceMessage(r, chat, user.get("_id"), "joined", try val.from(a, .{ .via = via }), false);
    if (invite) |i| _ = try col().invites.updateOne(a, .{ ._id = i.get("_id") }, .{ .@"$inc" = .{ .uses = 1 } }, .{});
    const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;
    try pushChat(r, fresh, user.get("_id"), "chat.new");
    rt.toChat(a, chat.get("_id"), "chat.members", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .memberCount = fresh.get("memberCount") }), null);
    return val.from(a, .{ .joined = true, .chat = fresh });
}

pub fn decideJoinRequest(r: *Rq, chat: Val, member: Val, actor: Val, user_id: Val, approve: bool) !Val {
    const a = r.a;
    try r.ensure(access.can(chat, member, "inviteUsers"), "You cannot approve members", 403, "no_permission");
    const req = (try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = user_id, .status = "requested" }, .{})) orelse return r.fail(404, "Request not found", null);
    if (!approve) {
        _ = try col().members.deleteOne(a, .{ ._id = req.get("_id") });
        _ = rt.toUser(a, user_id, "chat.join_declined", try val.from(a, .{ .chatId = try r.str(chat.get("_id")) }));
        return val.from(a, .{ .approved = false });
    }
    _ = try col().members.updateOne(a, .{ ._id = req.get("_id") }, .{ .@"$set" = .{ .status = "left" } }, .{});
    _ = try activate(r, chat, user_id, if (eq(chat.get("type"), "channel")) "subscriber" else "member", try val.from(a, .{ .invitedBy = actor.get("_id") }), actor.get("_id"));
    if (!eq(chat.get("type"), "channel")) _ = try msgs.serviceMessage(r, chat, user_id, "joined", try val.from(a, .{ .approvedBy = actor.get("_id") }), false);
    const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;
    try pushChat(r, fresh, user_id, "chat.new");
    return val.from(a, .{ .approved = true });
}

pub fn deactivate(r: *Rq, chat: Val, user_id: Val, status: []const u8, actor_id: Val) !bool {
    const a = r.a;
    const res = try col().members.updateOne(a, .{ .chatId = chat.get("_id"), .userId = user_id, .status = "active" }, .{
        .@"$set" = .{ .status = status, .leftAt = A.now(), .role = "member" },
        .@"$unset" = .{ .rights = "", .title = "", .pinnedAt = "" },
    }, .{});
    if (res.modified == 0) return false;
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$inc" = .{ .memberCount = -1 } }, .{});
    rt.leftChat(user_id, chat.get("_id"));
    _ = rt.toUser(a, user_id, "chat.removed", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .status = status }));
    if (chat.get("encrypted").truthy()) try keys.markRotation(r, chat, "member_removed");
    try events.emit(a, .member_left, try val.from(a, .{ .chat = chat, .userId = user_id, .status = status, .actorId = actor_id }));
    return true;
}

pub fn removeMember(r: *Rq, chat: Val, member: Val, actor: Val, target_id: Val, ban: bool) !void {
    const a = r.a;
    const t = chat.get("type").asStr() orelse "";
    try r.ensure(std.mem.eql(u8, t, "group") or std.mem.eql(u8, t, "channel") or std.mem.eql(u8, t, "support"), "You cannot remove people from this chat", 400, null);
    try access.assertCan(r, chat, member, "banUsers", "You cannot remove members here");
    const target = (try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = target_id }, .{})) orelse return r.fail(404, "That person is not in this chat", null);
    try r.ensure(!eq(target.get("role"), "owner"), "The owner cannot be removed", 403, null);
    if (eq(target.get("role"), "admin")) try r.ensure(eq(member.get("role"), "owner") or val.same(target.get("promotedBy"), actor.get("_id")), "Only the owner can remove this admin", 403, null);
    if (eq(target.get("status"), "active")) {
        _ = try deactivate(r, chat, target_id, if (ban) "banned" else "kicked", actor.get("_id"));
        if (!std.mem.eql(u8, t, "channel")) _ = try msgs.serviceMessage(r, chat, actor.get("_id"), "member_removed", try val.from(a, .{ .targetIds = .{target_id} }), false);
    } else if (ban) {
        _ = try col().members.updateOne(a, .{ ._id = target.get("_id") }, .{ .@"$set" = .{ .status = "banned" } }, .{});
    }
    const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;
    rt.toChat(a, chat.get("_id"), "chat.members", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .memberCount = fresh.get("memberCount") }), null);
}

pub fn unban(r: *Rq, chat: Val, member: Val, target_id: Val) !void {
    try access.assertCan(r, chat, member, "banUsers", "You cannot manage bans here");
    _ = try col().members.updateOne(r.a, .{ .chatId = chat.get("_id"), .userId = target_id, .status = "banned" }, .{ .@"$set" = .{ .status = "kicked" } }, .{});
}

pub fn leave(r: *Rq, chat: Val, member: Val, user: Val) !void {
    const a = r.a;
    if (chat.get("teamId").truthy() and eq(member.get("role"), "admin")) return r.fail(400, "Team members are added and removed through the team", "team_member");
    const t = chat.get("type").asStr() orelse "";
    if (std.mem.eql(u8, t, "private") or std.mem.eql(u8, t, "bot") or std.mem.eql(u8, t, "saved") or (chat.get("teamId").truthy() and val.same(chat.get("visitorId"), user.get("_id")))) {
        // "Delete chat" for me: hide it until a new message arrives.
        _ = try col().members.updateOne(a, .{ ._id = member.get("_id") }, .{ .@"$set" = .{ .clearedSeq = chat.get("seq").asInt() orelse 0, .hiddenAt = A.now(), .unread = 0, .mentions = 0 } }, .{});
        _ = rt.toUser(a, user.get("_id"), "chat.removed", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .status = "hidden" }));
        return;
    }
    if (eq(member.get("role"), "owner")) {
        const heir = try col().members.findOne(a, .{ .chatId = chat.get("_id"), .status = "active", .userId = .{ .@"$ne" = user.get("_id") } }, .{ .sort = .{ .role = 1, .joinedAt = 1 } });
        const admin = try col().members.findOne(a, .{ .chatId = chat.get("_id"), .status = "active", .role = "admin", .userId = .{ .@"$ne" = user.get("_id") } }, .{ .sort = .{ .joinedAt = 1 } });
        const next = admin orelse heir orelse return deleteChat(r, chat, member, user);
        _ = try col().members.updateOne(a, .{ ._id = next.get("_id") }, .{ .@"$set" = .{ .role = "owner" }, .@"$unset" = .{ .rights = "" } }, .{});
        _ = rt.toUser(a, next.get("userId"), "chat.update", try chatFor(r, chat, next.get("userId"), null));
    }
    _ = try deactivate(r, chat, user.get("_id"), "left", user.get("_id"));
    if (!std.mem.eql(u8, t, "channel")) _ = try msgs.serviceMessage(r, chat, user.get("_id"), "left", try Val.object(a), false);
    const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;
    rt.toChat(a, chat.get("_id"), "chat.members", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .memberCount = fresh.get("memberCount") }), null);
}

/// Deletes a whole chat: groups and channels by their owner, private chats for both sides.
pub fn deleteChat(r: *Rq, chat: Val, member: Val, user: Val) !void {
    const a = r.a;
    const t = chat.get("type").asStr() orelse "";
    const pair = std.mem.eql(u8, t, "private") or std.mem.eql(u8, t, "bot");
    try r.ensure(pair or eq(member.get("role"), "owner"), "Only the owner can delete this chat", 403, "no_permission");
    try r.ensure(!std.mem.eql(u8, t, "saved") or !chat.get("pairKey").truthy(), "Saved Messages cannot be deleted. Clear the history instead.", 400, null);
    const members = try col().members.find(a, .{ .chatId = chat.get("_id") }, .{ .projection = .{ .userId = 1 } });
    rt.toChat(a, chat.get("_id"), "chat.removed", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .status = "deleted" }), null);
    // The chat is gone either way; an app whose storage is down still gets the chat.deleted webhook.
    store.clear(r, chat, true) catch |e| {
        r.err = null;
        std.log.err("Deleting the history of an app chat failed: {t}", .{e});
    };
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = .{ .deletedAt = A.now() }, .@"$unset" = .{ .pairKey = "", .username = "", .usernameLower = "", .externalId = "" } }, .{});
    _ = try col().messageTimers.deleteMany(a, .{ .chatId = chat.get("_id") });
    _ = try col().members.deleteMany(a, .{ .chatId = chat.get("_id") });
    _ = try col().chatKeys.deleteMany(a, .{ .chatId = chat.get("_id") });
    _ = try col().invites.deleteMany(a, .{ .chatId = chat.get("_id") });
    _ = try col().keyRequests.deleteMany(a, .{ .chatId = chat.get("_id") });
    for (members) |m| rt.leftChat(m.get("userId"), chat.get("_id"));
    try events.emit(a, .chat_deleted, try val.from(a, .{ .chat = chat, .by = user }));
}

pub fn clearHistory(r: *Rq, chat: Val, member: Val, user: Val, for_everyone: bool) !void {
    const a = r.a;
    const seq = chat.get("seq").asInt() orelse 0;
    const cid = try r.str(chat.get("_id"));
    if (for_everyone) {
        const t = chat.get("type").asStr() orelse "";
        try r.ensure(std.mem.eql(u8, t, "private") or std.mem.eql(u8, t, "saved") or std.mem.eql(u8, t, "bot") or eq(member.get("role"), "owner"), "Only the owner can clear history for everyone", 403, null);
        try store.clear(r, chat, false);
        _ = try col().messageTimers.deleteMany(a, .{ .chatId = chat.get("_id") });
        _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = .{ .lastMessage = Val.null, .pinned = try Val.array(a) } }, .{});
        _ = try col().members.updateMany(a, .{ .chatId = chat.get("_id") }, .{ .@"$set" = .{ .unread = 0, .mentions = 0, .clearedSeq = seq } }, .{});
        rt.toChat(a, chat.get("_id"), "chat.cleared", try val.from(a, .{ .chatId = cid, .upToSeq = seq }), null);
    } else {
        _ = try col().members.updateOne(a, .{ ._id = member.get("_id") }, .{ .@"$set" = .{ .clearedSeq = seq, .unread = 0, .mentions = 0 } }, .{});
        _ = rt.toUser(a, user.get("_id"), "chat.cleared", try val.from(a, .{ .chatId = cid, .upToSeq = seq }));
    }
}

// ---- Settings, admins, invites ---------------------------------------------------------------

pub fn updateChat(r: *Rq, chat: Val, member: Val, user: Val, body: Val) !Val {
    const a = r.a;
    const set = try Val.object(a);
    var notices: std.ArrayList(struct { action: []const u8, extra: Val }) = .empty;
    const info_msg = "You cannot change this chat's info";
    const is_saved = eq(chat.get("type"), "saved");
    if (body.get("title") != .undef) {
        try access.assertCan(r, chat, member, "changeInfo", info_msg);
        const title = try v.reqStr(r, body.get("title"), "title", .{ .min = 1, .max = 128 });
        try set.set("title", title);
        if (!access.eq(chat.get("title"), title) and !is_saved) try notices.append(a, .{ .action = "title_changed", .extra = try val.from(a, .{ .title = title }) });
    }
    if (body.get("about") != .undef) {
        try access.assertCan(r, chat, member, "changeInfo", info_msg);
        try set.set("about", try v.reqStr(r, body.get("about"), "about", .{ .max = if (is_saved) 300 else 1000 }));
    }
    if (set.get("title") != .undef or set.get("about") != .undef) {
        // Content checks (Wufour Moderation)
        _ = try moderation.check(r, user, try val.from(a, .{ .type = "group", .id = try r.str(chat.get("_id")), .field = "update" }), try val.from(a, .{ .title = set.get("title"), .about = set.get("about") }), null);
    }
    if (body.get("avatar") != .undef) {
        try access.assertCan(r, chat, member, "changeInfo", info_msg);
        const avatar = if (body.get("avatar").truthy()) try ownAvatar(r, user, body.get("avatar")) else Val.null;
        try set.set("avatar", avatar);
        try notices.append(a, .{ .action = if (avatar.truthy()) "avatar_changed" else "avatar_removed", .extra = try Val.object(a) });
    }
    if (body.get("username") != .undef) {
        try r.ensure(eq(member.get("role"), "owner"), "Only the owner can change the public link", 403, null);
        _ = try setChatUsername(r, chat, body.get("username"));
    }
    const admin = eq(member.get("role"), "owner") or eq(member.get("role"), "admin");
    const admin_only = struct {
        fn check(rq: *Rq, ok: bool) !void {
            try rq.ensure(ok, "Only admins can change this", 403, "no_permission");
        }
    }.check;
    if (body.get("permissions") != .undef) {
        try admin_only(r, admin);
        _ = try v.reqObj(r, body.get("permissions"), "permissions");
        const perms = try access.defaultGroupPermissions(a);
        for (chat.get("permissions").keys(), chat.get("permissions").vals()) |kv_k, kv_v| try perms.set(kv_k, kv_v);
        for (access.MEMBER_PERMISSIONS) |k| if (body.path("permissions").get(k) == .bool) try perms.set(k, body.path("permissions").get(k));
        try set.set("permissions", perms);
    }
    if (body.get("slowMode") != .undef) {
        try admin_only(r, admin);
        try set.set("slowMode", try v.oneOfNum(r, body.get("slowMode"), "slowMode", &.{ 0, 10, 30, 60, 300, 900, 3600 }));
    }
    if (body.get("ttl") != .undef) {
        if (!eq(chat.get("type"), "private") and !is_saved) try admin_only(r, admin);
        const ttl = try v.oneOfNum(r, body.get("ttl"), "ttl", &.{ 0, 30, 300, 3600, 86400, 604800, 2592000 });
        try set.set("ttl", ttl);
        if (ttl != (chat.get("ttl").asInt() orelse 0)) try notices.append(a, .{ .action = "ttl_changed", .extra = try val.from(a, .{ .ttl = ttl }) });
    }
    inline for (.{ "historyVisible", "signMessages", "joinApproval", "protectedContent" }) |k| {
        if (body.get(k) != .undef) {
            try admin_only(r, admin);
            try set.set(k, try v.reqBool(r, body.get(k), k));
        }
    }
    if (body.get("reactions") != .undef) {
        try admin_only(r, admin);
        const list = body.get("reactions");
        try r.ensure(list == .null or (list == .arr and list.len() <= 100), "reactions must be null or a list", 400, null);
        if (list == .null) try set.set("reactions", .null) else {
            var out = try Val.array(a);
            for (list.items()) |e| try out.push(Val{ .str = try v.reqStr(r, e, "reaction", .{ .min = 1, .max = 16 }) });
            try set.set("reactions", out);
        }
    }
    if (body.get("metadata") != .undef) {
        try admin_only(r, admin);
        try set.set("metadata", (try v.meta(r, body.get("metadata"))) orelse .undef);
    }
    if (set.len() > 0) _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = set }, .{});
    const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;
    for (notices.items) |n| _ = try msgs.serviceMessage(r, fresh, user.get("_id"), n.action, n.extra, false);
    for (rt.onlineMemberVals(a, chat.get("_id"))) |uid| try pushChat(r, fresh, idv(v.oid(uid).?), "chat.update");
    var changes = try Val.array(a);
    for (set.keys()) |kv_k| try changes.push(Val{ .str = kv_k });
    try events.emit(a, .chat_updated, try val.from(a, .{ .chat = fresh, .by = user, .changes = changes }));
    return fresh;
}

pub fn setAdmin(r: *Rq, chat: Val, member: Val, actor: Val, target_id: Val, body: Val) !void {
    const a = r.a;
    try r.ensure(eq(chat.get("type"), "group") or eq(chat.get("type"), "channel"), "Admins exist only in groups and channels", 400, null);
    try access.assertCan(r, chat, member, "addAdmins", "You cannot manage admins here");
    const target = (try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = target_id, .status = "active" }, .{})) orelse return r.fail(404, "That person is not a member", null);
    try r.ensure(!eq(target.get("role"), "owner"), "The owner is already in charge", 400, null);
    const demote = body.get("demote").truthy();
    if (demote) {
        try r.ensure(eq(member.get("role"), "owner") or val.same(target.get("promotedBy"), actor.get("_id")), "Only the owner can demote this admin", 403, null);
        _ = try col().members.updateOne(a, .{ ._id = target.get("_id") }, .{ .@"$set" = .{ .role = if (eq(chat.get("type"), "channel")) "subscriber" else "member" }, .@"$unset" = .{ .rights = "", .title = "", .promotedBy = "" } }, .{});
    } else {
        const rights = try Val.object(a);
        const defaults = try access.defaultAdminRights(a);
        const given = body.get("rights");
        for (access.ADMIN_RIGHTS) |k| {
            var x = if (given.get(k) == .bool) given.get(k) else defaults.get(k);
            // An admin can only hand out rights they have themselves.
            if (!eq(member.get("role"), "owner") and !member.path("rights").get(k).truthy()) x = Val.False;
            try rights.set(k, x);
        }
        const title = try v.str(r, body.get("title"), "title", .{ .max = 16, .optional = true });
        const set = try val.from(a, .{ .role = "admin", .rights = rights, .promotedBy = actor.get("_id") });
        if (title) |t| try set.set("title", t);
        _ = try col().members.updateOne(a, .{ ._id = target.get("_id") }, .{ .@"$set" = set }, .{});
    }
    const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;
    try pushChat(r, fresh, target_id, "chat.update");
    rt.toChat(a, chat.get("_id"), "chat.admins", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .userId = try r.str(target_id), .demoted = demote }), null);
}

pub fn transferOwnership(r: *Rq, chat: Val, member: Val, actor: Val, target_id: Val) !void {
    const a = r.a;
    try r.ensure(eq(member.get("role"), "owner"), "Only the owner can transfer ownership", 403, null);
    const target = try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = target_id, .status = "active" }, .{});
    try r.ensure(target != null and !eq(target.?.get("role"), "subscriber"), "Promote this person to admin first", 400, null);
    _ = try col().members.updateOne(a, .{ ._id = target.?.get("_id") }, .{ .@"$set" = .{ .role = "owner" }, .@"$unset" = .{ .rights = "" } }, .{});
    const rights = try access.defaultAdminRights(a);
    try rights.set("addAdmins", true);
    _ = try col().members.updateOne(a, .{ ._id = member.get("_id") }, .{ .@"$set" = .{ .role = "admin", .rights = rights } }, .{});
    const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;
    try pushChat(r, fresh, target_id, "chat.update");
    try pushChat(r, fresh, actor.get("_id"), "chat.update");
    _ = try msgs.serviceMessage(r, fresh, actor.get("_id"), "ownership_transferred", try val.from(a, .{ .targetIds = .{target_id} }), false);
}

pub fn createInvite(r: *Rq, chat: Val, member: Val, user: Val, body: Val) !Val {
    const a = r.a;
    try r.ensure(eq(chat.get("type"), "group") or eq(chat.get("type"), "channel"), "Invite links exist only for groups and channels", 400, null);
    try r.ensure(access.can(chat, member, "inviteUsers") or access.can(chat, member, "addMembers"), "You cannot create invite links here", 403, "no_permission");
    const name = try v.str(r, body.get("name"), "name", .{ .max = 32, .optional = true });
    const invite = try val.from(a, .{
        .code = try A.randomCode(a, 12),
        .chatId = chat.get("_id"),
        .createdBy = user.get("_id"),
        .createdAt = A.now(),
        .name = if (name) |n| (if (n.len > 0) Val{ .str = n } else Val.null) else Val.null,
        .expiresAt = if (body.get("expiresAt").truthy()) Val{ .date = try v.reqInt(r, body.get("expiresAt"), "expiresAt", .{ .min = @floatFromInt(A.nowMs()) }) } else Val.null,
        .usageLimit = if (try v.int(r, body.get("usageLimit"), "usageLimit", .{ .min = 1, .max = 100000, .optional = true })) |x| Val.number(x) else Val.null,
        .requestApproval = body.get("requestApproval").isTrue(),
        .uses = 0,
        .revoked = false,
    });
    _ = try col().invites.insertOne(a, invite);
    return invite;
}

pub fn findInvite(r: *Rq, code: Val) !Val {
    const a = r.a;
    const c = try v.reqStr(r, code, "code", .{ .max = 40 });
    const invite = (try col().invites.findOne(a, .{ .code = c }, .{})) orelse return r.fail(404, "This invite link is invalid or was revoked", "invite_invalid");
    try r.ensure(!invite.get("revoked").truthy(), "This invite link is invalid or was revoked", 404, "invite_invalid");
    const exp = invite.get("expiresAt");
    try r.ensure(!exp.truthy() or (exp == .date and exp.date > A.nowMs()), "This invite link has expired", 410, "invite_expired");
    const lim = invite.get("usageLimit");
    try r.ensure(!lim.truthy() or (invite.get("uses").asNum() orelse 0) < (lim.asNum() orelse 0), "This invite link has reached its limit", 410, "invite_full");
    return invite;
}

pub fn serializeInvite(r: *Rq, inv: Val) !Val {
    return val.from(r.a, .{
        .code = inv.get("code"),
        .link = try r.fmt("{s}/join/{s}", .{ A.app.config.public_url, try r.str(inv.get("code")) }),
        .name = inv.get("name"),
        .createdBy = try r.str(inv.get("createdBy")),
        .createdAt = inv.get("createdAt"),
        .expiresAt = inv.get("expiresAt"),
        .usageLimit = inv.get("usageLimit"),
        .uses = inv.get("uses"),
        .requestApproval = inv.get("requestApproval"),
        .revoked = inv.get("revoked"),
    });
}
