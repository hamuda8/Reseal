//! Teams (src/services/teams.js): a store, a department, or any group of people who answer
//! customers as one. A team's conversations are support chats with the team attached: one
//! visitor talks to the team, every team member answers as an admin. Visitors see the team's name
//! and photo, never the staff; staff see the visitor. The roster flows to every conversation.

const std = @import("std");
const A = @import("app.zig");
const v = @import("validate.zig");
const rt = @import("realtime.zig");
const ser = @import("serialize.zig");
const chats = @import("chats.zig");
const keys = @import("keys.zig");
const access = @import("access.zig");
const events = @import("events.zig");
const moderation = @import("moderation.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;
const eq = access.eq;

const MAX_MEMBERS = 200;

fn col() *A.Cols {
    return &A.app.col;
}

fn httpsUrl(s: []const u8) bool {
    return s.len >= 8 and std.ascii.eqlIgnoreCase(s[0..8], "https://");
}

/// What clients need to show a team as a chat counterpart.
pub fn publicTeam(r: *Rq, team: ?Val) !Val {
    const t = team orelse return .null;
    return val.from(r.a, .{ .id = try r.str(t.get("_id")), .externalId = t.get("externalId"), .name = t.get("name"), .avatarUrl = if (t.get("avatarUrl").truthy()) t.get("avatarUrl") else Val.null, .about = if (t.get("about").truthy()) t.get("about") else Val.string(""), .color = try ser.colorOf(r.a, t.get("_id")) });
}

/// The developer API view, with the roster as the app's own ids.
pub fn describeTeam(r: *Rq, team: Val) !Val {
    const a = r.a;
    const users = if (team.get("memberIds").len() > 0) try col().users.find(a, .{ ._id = .{ .@"$in" = team.get("memberIds") } }, .{ .projection = .{ .externalId = 1, .displayName = 1 } }) else val.none[0..];
    const n = try col().chats.count(a, .{ .teamId = team.get("_id"), .deletedAt = .{ .@"$exists" = false } }, .{});
    var members = try Val.array(a);
    for (users) |u| try members.push(try val.from(a, .{ .id = try r.str(u.get("_id")), .externalId = u.get("externalId"), .name = u.get("displayName") }));
    return val.from(a, .{
        .id = try r.str(team.get("_id")),
        .externalId = team.get("externalId"),
        .name = team.get("name"),
        .avatarUrl = if (team.get("avatarUrl").truthy()) team.get("avatarUrl") else Val.null,
        .about = if (team.get("about").truthy()) team.get("about") else Val.string(""),
        .metadata = if (team.get("metadata").truthy()) team.get("metadata") else Val.null,
        .members = members,
        .chats = n,
        .createdAt = team.get("createdAt"),
        .updatedAt = team.get("updatedAt"),
    });
}

/// A team by the app's own id, or by Reseal id as "id:<oid>".
pub fn teamRef(r: *Rq, app_doc: Val, ref: Val) !Val {
    const a = r.a;
    const s = if (ref.isNullish()) "" else try r.str(ref);
    const q = try val.from(a, .{ .appId = app_doc.get("_id") });
    if (std.mem.startsWith(u8, s, "id:")) {
        const id = v.oidStr(s[3..]) orelse return r.fail(404, "Team not found", "team_not_found");
        try q.set("_id", id);
    } else try q.set("externalId", s);
    return (try col().teams.findOne(a, q, .{})) orelse r.fail(404, try r.fmt("Team \"{s}\" not found. Create it with POST /api/v1/teams first.", .{s}), "team_not_found");
}

fn appUsers(r: *Rq, app_doc: Val, refs: Val, name: []const u8) ![]Val {
    const a = r.a;
    try r.ensure(refs == .arr and refs.len() <= MAX_MEMBERS, try r.fmt("{s} must be a list of up to {d} externalIds", .{ name, MAX_MEMBERS }), 400, null);
    var wanted = try Val.array(a);
    for (refs.items()) |x| {
        const id = try v.reqStr(r, x, name, .{ .min = 1, .max = 128 });
        var dup = false;
        for (wanted.items()) |y| if (std.mem.eql(u8, y.str, id)) {
            dup = true;
        };
        if (!dup) try wanted.push(Val{ .str = id });
    }
    const users = if (wanted.len() > 0) try col().users.find(a, .{ .appId = app_doc.get("_id"), .externalId = .{ .@"$in" = wanted }, .deletedAt = .{ .@"$exists" = false } }, .{}) else val.none[0..];
    for (wanted.items()) |id| {
        var found = false;
        for (users) |u| if (eq(u.get("externalId"), id.str)) {
            found = true;
        };
        if (!found) return r.fail(404, try r.fmt("User \"{s}\" not found. Create it with POST /api/v1/users first.", .{id.str}), "user_not_found");
    }
    return users;
}

fn cleanFields(r: *Rq, body: Val, partial: bool) !Val {
    const a = r.a;
    const set = try Val.object(a);
    if (!partial or body.get("name") != .undef) try set.set("name", try v.reqStr(r, body.get("name"), "name", .{ .min = 1, .max = 80 }));
    if (body.get("avatarUrl") != .undef) try set.set("avatarUrl", if (body.get("avatarUrl").truthy()) Val{ .str = try v.reqStr(r, body.get("avatarUrl"), "avatarUrl", .{ .max = 2048, .pattern = httpsUrl }) } else Val.null);
    if (body.get("about") != .undef) try set.set("about", try v.reqStr(r, body.get("about"), "about", .{ .max = 300 }));
    if (body.get("metadata") != .undef) try set.set("metadata", (try v.meta(r, body.get("metadata"))) orelse .undef);
    return set;
}

fn ids(r: *Rq, users: []const Val) !Val {
    var out = try Val.array(r.a);
    for (users) |u| try out.push(u.get("_id"));
    return out;
}

/// Creates a team, or updates the one with this externalId.
pub fn upsertTeam(r: *Rq, app_doc: Val, body: Val) !Val {
    const a = r.a;
    const ext_v = if (body.get("externalId").isNullish()) body.get("id") else body.get("externalId");
    const external_id = try v.reqStr(r, ext_v, "externalId", .{ .min = 1, .max = 128 });
    const existing = try col().teams.findOne(a, .{ .appId = app_doc.get("_id"), .externalId = external_id }, .{});
    const set = try cleanFields(r, body, existing != null);
    // Content checks (Wufour Moderation): visitors see the team's name and description.
    if (set.get("name") != .undef or set.get("about") != .undef) _ = try moderation.check(r, null, try val.from(a, .{ .type = "team", .id = external_id, .field = "upsert" }), try val.from(a, .{ .name = set.get("name"), .about = set.get("about") }), null);
    const members = if (body.get("members") != .undef) try appUsers(r, app_doc, body.get("members"), "members") else null;
    const now = A.now();
    if (existing) |ex| {
        const s2 = try val.clone(a, set);
        try s2.set("updatedAt", now);
        if (members) |m| try s2.set("memberIds", try ids(r, m));
        const team = (try col().teams.findOneAndUpdate(a, .{ ._id = ex.get("_id") }, .{ .@"$set" = s2 }, .{ .returnDocument = .after })) orelse ex;
        try afterChange(r, team, ex, if (members) |m| try ids(r, m) else null, set);
        return team;
    }
    const doc = try val.from(a, .{ .appId = app_doc.get("_id"), .externalId = external_id });
    for (set.keys(), set.vals()) |kv_k, kv_v| try doc.set(kv_k, kv_v);
    try doc.set("avatarUrl", if (set.get("avatarUrl").isNullish()) Val.null else set.get("avatarUrl"));
    try doc.set("about", if (set.get("about").isNullish()) Val.string("") else set.get("about"));
    try doc.set("memberIds", if (members) |m| try ids(r, m) else try Val.array(a));
    try doc.set("createdAt", now);
    try doc.set("updatedAt", now);
    _ = col().teams.insertOne(a, doc) catch |e| {
        if (e == error.DuplicateKey) return upsertTeam(r, app_doc, body); // two requests raced
        return e;
    };
    return doc;
}

pub fn updateTeam(r: *Rq, app_doc: Val, team: Val, body: Val) !Val {
    const a = r.a;
    const set = try cleanFields(r, body, true);
    const members = if (body.get("members") != .undef) try appUsers(r, app_doc, body.get("members"), "members") else null;
    const s2 = try val.clone(a, set);
    try s2.set("updatedAt", A.now());
    if (members) |m| try s2.set("memberIds", try ids(r, m));
    const fresh = (try col().teams.findOneAndUpdate(a, .{ ._id = team.get("_id") }, .{ .@"$set" = s2 }, .{ .returnDocument = .after })) orelse team;
    try afterChange(r, fresh, team, if (members) |m| try ids(r, m) else null, set);
    return fresh;
}

pub fn addTeamMembers(r: *Rq, app_doc: Val, team: Val, refs: Val) !struct { team: Val, added: Val } {
    const a = r.a;
    const users = try appUsers(r, app_doc, refs, "members");
    var added: std.ArrayList(Val) = .empty;
    for (users) |u| {
        var have = false;
        for (team.get("memberIds").items()) |x| if (val.same(x, u.get("_id"))) {
            have = true;
        };
        if (!have) try added.append(a, u);
    }
    try r.ensure(team.get("memberIds").len() + added.items.len <= MAX_MEMBERS, try r.fmt("A team can have up to {d} members", .{MAX_MEMBERS}), 400, null);
    var ext = try Val.array(a);
    if (added.items.len == 0) return .{ .team = team, .added = ext };
    const added_ids = try ids(r, added.items);
    const fresh = (try col().teams.findOneAndUpdate(a, .{ ._id = team.get("_id") }, .{ .@"$addToSet" = .{ .memberIds = .{ .@"$each" = added_ids } }, .@"$set" = .{ .updatedAt = A.now() } }, .{ .returnDocument = .after })) orelse team;
    try syncChats(r, fresh, added_ids.items(), &.{});
    for (added.items) |u| try ext.push(u.get("externalId"));
    return .{ .team = fresh, .added = ext };
}

pub fn removeTeamMember(r: *Rq, team: Val, user: Val) !Val {
    const a = r.a;
    var have = false;
    for (team.get("memberIds").items()) |x| if (val.same(x, user.get("_id"))) {
        have = true;
    };
    if (!have) return team;
    const fresh = (try col().teams.findOneAndUpdate(a, .{ ._id = team.get("_id") }, .{ .@"$pull" = .{ .memberIds = user.get("_id") }, .@"$set" = .{ .updatedAt = A.now() } }, .{ .returnDocument = .after })) orelse team;
    try syncChats(r, fresh, &.{}, &.{user.get("_id")});
    return fresh;
}

/// Deletes a team and the conversations people had with it.
pub fn deleteTeam(r: *Rq, team: Val) !void {
    const a = r.a;
    const list = try col().chats.find(a, .{ .teamId = team.get("_id"), .deletedAt = .{ .@"$exists" = false } }, .{});
    for (list) |chat| try chats.deleteChat(r, chat, try val.from(a, .{ .role = "owner", .status = "active" }), try val.from(a, .{ ._id = team.get("_id") }));
    _ = try col().teams.deleteOne(a, .{ ._id = team.get("_id") });
}

/// After a change: the roster flows to the team's chats, and a new name or photo shows up.
fn afterChange(r: *Rq, team: Val, before: Val, members: ?Val, set: Val) !void {
    const a = r.a;
    if (members) |m| {
        var added: std.ArrayList(Val) = .empty;
        var removed: std.ArrayList(Val) = .empty;
        for (m.items()) |id| if (!containsSame(before.get("memberIds"), id)) try added.append(a, id);
        for (before.get("memberIds").items()) |id| if (!containsSame(m, id)) try removed.append(a, id);
        try syncChats(r, team, added.items, removed.items);
    }
    const name_changed = set.get("name") != .undef and !Val.eql(set.get("name"), before.get("name"));
    const avatar_changed = set.get("avatarUrl") != .undef and !Val.eql(set.get("avatarUrl"), if (before.get("avatarUrl").truthy()) before.get("avatarUrl") else Val.null);
    const about_changed = set.get("about") != .undef and !Val.eql(set.get("about"), if (before.get("about").truthy()) before.get("about") else Val.string(""));
    if (name_changed or avatar_changed or about_changed) {
        if (set.get("name") != .undef) _ = try col().chats.updateMany(a, .{ .teamId = team.get("_id") }, .{ .@"$set" = .{ .title = team.get("name") } }, .{});
        const list = try col().chats.find(a, .{ .teamId = team.get("_id"), .deletedAt = .{ .@"$exists" = false } }, .{});
        var changes = try Val.array(a);
        for (set.keys()) |kv_k| try changes.push(Val{ .str = kv_k });
        for (list) |chat| {
            for (rt.onlineMemberVals(a, chat.get("_id"))) |uid| try chats.pushChat(r, chat, .{ .id = v.oid(uid).? }, "chat.update");
            try events.emit(a, .chat_updated, try val.from(a, .{ .chat = chat, .by = Val.null, .changes = changes }));
        }
    }
}

fn containsSame(list: Val, x: Val) bool {
    for (list.items()) |e| if (val.same(e, x)) return true;
    return false;
}

/// Adds new staff to (and removes former staff from) every chat the team has.
fn syncChats(r: *Rq, team: Val, added: []const Val, removed: []const Val) !void {
    const a = r.a;
    if (added.len == 0 and removed.len == 0) return;
    const list = try col().chats.find(a, .{ .teamId = team.get("_id"), .deletedAt = .{ .@"$exists" = false } }, .{});
    if (list.len == 0) return;
    const newcomers = if (added.len > 0) try col().users.find(a, .{ ._id = .{ .@"$in" = added }, .deletedAt = .{ .@"$exists" = false } }, .{}) else val.none[0..];
    for (list) |chat| {
        var changed = false;
        for (newcomers) |u| {
            if (chat.get("encrypted").truthy() and !eq(u.get("kind"), "bot") and !u.path("keys.enc").truthy()) _ = try keys.provisionKeys(r, u);
            if (try chats.activate(r, chat, u.get("_id"), "admin", try val.from(a, .{ .rights = try access.defaultAdminRights(a), .team = true }), .null)) changed = true;
        }
        for (removed) |id| {
            if (val.same(id, chat.get("visitorId"))) continue;
            if (try chats.deactivate(r, chat, id, "left", .null)) changed = true;
        }
        if (!changed) continue;
        const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;
        for (newcomers) |u| try chats.pushChat(r, fresh, u.get("_id"), "chat.new");
        rt.toChat(a, chat.get("_id"), "chat.members", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .memberCount = fresh.get("memberCount") }), null);
    }
}

/// Opens the conversation between a visitor and a team: one per pair, or one per externalId (an
/// order, a ticket).
pub fn openTeamChat(r: *Rq, app_doc: Val, team: Val, visitor: Val, external_id: ?[]const u8, metadata: Val, bot_id: ?Val) !struct { chat: Val, created: bool } {
    const a = r.a;
    try r.ensure(val.same(visitor.get("appId"), app_doc.get("_id")), "User not found", 404, "user_not_found");
    try r.ensure(!containsSame(team.get("memberIds"), visitor.get("_id")), "This person is on the team", 400, "team_member");
    const pair_key = try r.fmt("team:{s}:{s}", .{ try r.str(team.get("_id")), try r.str(visitor.get("_id")) });
    const existing = if (external_id) |e|
        try col().chats.findOne(a, .{ .appId = app_doc.get("_id"), .externalId = e, .deletedAt = .{ .@"$exists" = false } }, .{})
    else
        try col().chats.findOne(a, .{ .pairKey = pair_key }, .{});
    if (existing) |ex| {
        try r.ensure(val.same(ex.get("teamId"), team.get("_id")) and val.same(ex.get("visitorId"), visitor.get("_id")), "That chat id belongs to another conversation", 409, "chat_exists");
        // Re-open it for a visitor who had deleted it from their list.
        _ = try col().members.updateOne(a, .{ .chatId = ex.get("_id"), .userId = visitor.get("_id") }, .{ .@"$set" = .{ .status = "active" }, .@"$unset" = .{ .hiddenAt = "" } }, .{});
        rt.joinedChat(visitor.get("_id"), ex.get("_id"), ex.get("type"));
        return .{ .chat = ex, .created = false };
    }
    const staff = if (team.get("memberIds").len() > 0) try col().users.find(a, .{ ._id = .{ .@"$in" = team.get("memberIds") }, .deletedAt = .{ .@"$exists" = false } }, .{}) else val.none[0..];
    const bot = if (bot_id) |b| try col().users.findOne(a, .{ ._id = b, .kind = "bot" }, .{}) else null;
    const encrypted = (try chats.e2eeFor(r, visitor)) and bot == null;
    if (encrypted) {
        if (!visitor.path("keys.enc").truthy()) _ = try keys.provisionKeys(r, visitor);
        for (staff) |u| if (!u.path("keys.enc").truthy()) {
            _ = try keys.provisionKeys(r, u);
        };
    }
    const now = A.now();
    const chat = try val.from(a, .{
        .type = "support",
        .appId = app_doc.get("_id"),
        .encrypted = encrypted,
        .title = team.get("name"),
        .about = "",
        .teamId = team.get("_id"),
        .teamExternalId = team.get("externalId"),
        .visitorId = visitor.get("_id"),
        .visitorExternalId = if (visitor.get("externalId").truthy()) visitor.get("externalId") else Val.null,
        .createdBy = visitor.get("_id"),
        .createdAt = now,
        .seq = 0,
        .keyEpoch = 0,
        .lastMessageAt = now,
        .pinned = try Val.array(a),
        .memberCount = 1 + staff.len + @as(usize, if (bot != null) 1 else 0),
    });
    if (external_id) |e| try chat.set("externalId", e) else try chat.set("pairKey", pair_key);
    if (metadata.truthy()) try chat.set("metadata", (try v.meta(r, metadata)) orelse .undef);
    if (bot) |b| try chat.set("botId", b.get("_id"));
    _ = col().chats.insertOne(a, chat) catch |e| {
        if (e == error.DuplicateKey) return openTeamChat(r, app_doc, team, visitor, external_id, metadata, bot_id);
        return e;
    };
    const mk = struct {
        fn doc(rq: *Rq, c: Val, user_id: Val, role: []const u8, extra: ?Val) !Val {
            const d = try val.from(rq.a, .{ .chatId = c.get("_id"), .userId = user_id, .chatType = "support", .role = role, .status = "active", .joinedAt = c.get("createdAt"), .joinedSeq = 0, .lastReadSeq = 0, .unread = 0, .mentions = 0, .lastActivityAt = c.get("createdAt") });
            if (extra) |x| for (x.keys(), x.vals()) |kv_k, kv_v| try d.set(kv_k, kv_v);
            return d;
        }
    }.doc;
    var members: std.ArrayList(Val) = .empty;
    try members.append(a, try mk(r, chat, visitor.get("_id"), "member", null));
    for (staff) |u| try members.append(a, try mk(r, chat, u.get("_id"), "admin", try val.from(a, .{ .rights = try access.defaultAdminRights(a), .team = true })));
    if (bot) |b| try members.append(a, try mk(r, chat, b.get("_id"), "admin", try val.from(a, .{ .rights = try access.defaultAdminRights(a) })));
    _ = try col().members.insertMany(a, members.items);
    for (members.items) |m| rt.joinedChat(m.get("userId"), chat.get("_id"), chat.get("type"));
    for (members.items) |m| if (!val.same(m.get("userId"), visitor.get("_id"))) try chats.pushChat(r, chat, m.get("userId"), "chat.new");
    var mids = try Val.array(a);
    for (members.items) |m| try mids.push(m.get("userId"));
    try events.emit(a, .chat_created, try val.from(a, .{ .chat = chat, .creator = visitor, .memberIds = mids }));
    return .{ .chat = chat, .created = true };
}

/// Unread messages across all of the team's conversations (read by any staff member counts as
/// read by the team), in one aggregation.
pub fn teamUnreadTotal(r: *Rq, team: Val) !i64 {
    const a = r.a;
    const rows = try col().chats.aggregate(a, .{
        .{ .@"$match" = .{ .teamId = team.get("_id"), .deletedAt = .{ .@"$exists" = false } } },
        .{ .@"$project" = .{ ._id = 1 } },
        .{ .@"$lookup" = .{
            .from = "members",
            .let = .{ .chat = "$_id" },
            .pipeline = .{
                .{ .@"$match" = .{ .@"$expr" = .{ .@"$eq" = .{ "$chatId", "$$chat" } }, .status = "active", .role = "admin" } },
                .{ .@"$group" = .{ ._id = Val.null, .unread = .{ .@"$min" = .{ .@"$ifNull" = .{ "$unread", 0 } } } } },
            },
            .as = "staff",
        } },
        .{ .@"$group" = .{ ._id = Val.null, .total = .{ .@"$sum" = .{ .@"$ifNull" = .{ .{ .@"$arrayElemAt" = .{ "$staff.unread", 0 } }, 0 } } } } },
    });
    if (rows.len == 0) return 0;
    return rows[0].get("total").asInt() orelse 0;
}

/// The team's conversations, newest first, with how much the team has not read yet.
pub fn teamChats(r: *Rq, team: Val, limit_: i64, before: ?[]const u8) !Val {
    const a = r.a;
    const q = try val.from(a, .{ .teamId = team.get("_id"), .deletedAt = .{ .@"$exists" = false } });
    if (before) |b| if (b.len > 0) try q.set("lastMessageAt", .{ .@"$lt" = if (val.parseDate(b)) |ms| Val{ .date = ms } else Val.null });
    const list = try col().chats.find(a, q, .{ .sort = .{ .lastMessageAt = -1 }, .limit = @min(@max(limit_, 1), 200) });
    var out = try Val.array(a);
    if (list.len == 0) return out;
    var chat_ids: std.ArrayList(Val) = .empty;
    var visitor_ids: std.ArrayList(Val) = .empty;
    for (list) |c| {
        try chat_ids.append(a, c.get("_id"));
        if (c.get("visitorId").truthy()) try visitor_ids.append(a, c.get("visitorId"));
    }
    const staff = try col().members.find(a, .{ .chatId = .{ .@"$in" = chat_ids.items }, .status = "active", .role = "admin" }, .{ .projection = .{ .chatId = 1, .unread = 1, .userId = 1 } });
    const visitors = try col().users.find(a, .{ ._id = .{ .@"$in" = visitor_ids.items } }, .{ .projection = .{ .externalId = 1, .displayName = 1, .avatarUrl = 1 } });
    for (list) |c| {
        // Read by any team member counts as read by the team.
        var unread: ?i64 = null;
        for (staff) |m| if (val.same(m.get("chatId"), c.get("_id"))) {
            const u = m.get("unread").asInt() orelse 0;
            unread = if (unread) |x| @min(x, u) else u;
        };
        var vis: Val = .null;
        for (visitors) |u| if (val.same(u.get("_id"), c.get("visitorId"))) {
            vis = try val.from(a, .{ .id = try r.str(u.get("_id")), .externalId = if (u.get("externalId").truthy()) u.get("externalId") else Val.null, .name = u.get("displayName"), .avatarUrl = if (u.get("avatarUrl").truthy()) u.get("avatarUrl") else Val.null });
        };
        try out.push(try val.from(a, .{
            .id = try r.str(c.get("_id")),
            .externalId = if (c.get("externalId").truthy()) c.get("externalId") else Val.null,
            .encrypted = c.get("encrypted").truthy(),
            .metadata = if (c.get("metadata").truthy()) c.get("metadata") else Val.null,
            .visitor = vis,
            .unread = unread orelse 0,
            .lastMessageAt = c.get("lastMessageAt"),
            .lastSeq = c.get("seq").asInt() orelse 0,
            .createdAt = c.get("createdAt"),
        }));
    }
    return out;
}

pub const Extras = struct { chat_id: Val, team: Val, visitor: Val };

/// Team and visitor details for support chats, batched for a list.
pub fn extrasFor(r: *Rq, list: []const Val, viewer_id: Val) ![]Extras {
    const a = r.a;
    var with_team: std.ArrayList(Val) = .empty;
    for (list) |c| if (c.get("teamId").truthy()) try with_team.append(a, c);
    if (with_team.items.len == 0) return &.{};
    var team_ids: std.ArrayList(Val) = .empty;
    var visitor_ids: std.ArrayList(Val) = .empty;
    for (with_team.items) |c| {
        try team_ids.append(a, c.get("teamId"));
        if (c.get("visitorId").truthy()) try visitor_ids.append(a, c.get("visitorId"));
    }
    const ts = try col().teams.find(a, .{ ._id = .{ .@"$in" = team_ids.items } }, .{});
    const vs = try col().users.find(a, .{ ._id = .{ .@"$in" = visitor_ids.items } }, .{});
    var out: std.ArrayList(Extras) = .empty;
    for (with_team.items) |c| {
        var team: ?Val = null;
        for (ts) |t| if (val.same(t.get("_id"), c.get("teamId"))) {
            team = t;
        };
        var visitor: Val = .null;
        for (vs) |u| if (val.same(u.get("_id"), c.get("visitorId"))) {
            visitor = u;
        };
        const team_v = if (team != null) try publicTeam(r, team) else try val.from(a, .{ .id = try r.str(c.get("teamId")), .externalId = if (c.get("teamExternalId").truthy()) c.get("teamExternalId") else Val.null, .name = c.get("title"), .avatarUrl = Val.null, .about = "", .color = try ser.colorOf(a, c.get("teamId")) });
        try out.append(a, .{ .chat_id = c.get("_id"), .team = team_v, .visitor = try ser.user(a, visitor, viewer_id, .{}) });
    }
    return out.items;
}

pub fn extrasOf(extras: []const Extras, chat_id: Val) ?Extras {
    for (extras) |e| if (val.same(e.chat_id, chat_id)) return e;
    return null;
}

/// The teams this user answers for.
pub fn teamsOf(r: *Rq, user: Val) ![]Val {
    if (!user.get("appId").truthy()) return &.{};
    return col().teams.find(r.a, .{ .appId = user.get("appId"), .memberIds = user.get("_id") }, .{});
}
