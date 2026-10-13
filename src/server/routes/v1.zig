//! Reseal Platform REST API, server to server (src/routes/v1.js). Authenticated with the app's
//! secret key: `Authorization: Bearer rsl_sk_…`. Users and chats can be addressed by Reseal id or
//! by the app's own id ("ext:<externalId>").

const std = @import("std");
const A = @import("../app.zig");
const web = @import("../web.zig");
const v = @import("../validate.zig");
const ser = @import("../serialize.zig");
const apps = @import("../apps.zig");
const chats = @import("../chats.zig");
const msgs = @import("../messages.zig");
const store = @import("../store.zig");
const teams = @import("../teams.zig");
const rt = @import("../realtime.zig");
const auth = @import("../auth.zig");
const access = @import("../access.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;
const Req = web.Req;

fn col() *A.Cols {
    return &A.app.col;
}

fn done(res: anyerror!void) anyerror!bool {
    try res;
    return true;
}

fn sn(r: *Rq, x: Val) !Val {
    return r.sn(x);
}

/// Every /api/v1 request: the secret key, the app's budget, then the routes; 404 otherwise.
pub fn handle(q: *Req) !void {
    try apps.requireAppSecret(q);
    // One budget per app (whatever server the calls come from), per minute.
    const max = apps.apiRateLimitFor(q.app_);
    if (max > 0) {
        try q.setHeader("ratelimit-limit", try q.r.fmt("{d}", .{max}));
        if (!A.allow(try q.r.fmt("v1:{s}", .{try q.r.str(q.app_.get("_id"))}), @floatFromInt(max), 60_000)) {
            try q.setHeader("retry-after", "1");
            return q.r.fail(429, try q.r.fmt("Too many requests: this app may make {d} API calls a minute", .{max}), "rate_limited");
        }
    }
    if (try routes(q)) return;
    return q.jsonStatus(404, .{ .@"error" = .{ .message = "Unknown API endpoint", .code = "not_found" } });
}

fn routes(q: *Req) !bool {
    if (q.is(.GET, "/api/v1/app")) return done(getApp(q));
    if (q.is(.PATCH, "/api/v1/app")) return done(patchApp(q));
    if (q.is(.POST, "/api/v1/users")) return done(createUser(q));
    if (q.is(.POST, "/api/v1/users/bulk")) return done(bulkUsers(q));
    if (q.is(.GET, "/api/v1/users/:ref")) return done(getUser(q));
    if (q.is(.PATCH, "/api/v1/users/:ref")) return done(patchUser(q));
    if (q.is(.DELETE, "/api/v1/users/:ref")) return done(deleteUser(q));
    if (q.is(.POST, "/api/v1/users/:ref/tokens")) return done(tokens(q));
    if (q.is(.POST, "/api/v1/users/:ref/sessions/revoke")) return done(revoke(q));
    if (q.is(.GET, "/api/v1/users/:ref/chats")) return done(userChats(q));
    if (q.is(.GET, "/api/v1/users/:ref/unread")) return done(userUnread(q));
    if (q.is(.GET, "/api/v1/teams")) return done(listTeams(q));
    if (q.is(.POST, "/api/v1/teams")) return done(createTeam(q));
    if (q.is(.GET, "/api/v1/teams/:ref")) return done(getTeam(q));
    if (q.is(.PATCH, "/api/v1/teams/:ref")) return done(patchTeam(q));
    if (q.is(.DELETE, "/api/v1/teams/:ref")) return done(deleteTeam(q));
    if (q.is(.POST, "/api/v1/teams/:ref/members")) return done(addTeamMembers(q));
    if (q.is(.DELETE, "/api/v1/teams/:ref/members/:userRef")) return done(removeTeamMember(q));
    if (q.is(.GET, "/api/v1/teams/:ref/chats")) return done(teamChats(q));
    if (q.is(.GET, "/api/v1/teams/:ref/unread")) return done(teamUnread(q));
    if (q.is(.POST, "/api/v1/chats")) return done(createChat(q));
    if (q.is(.GET, "/api/v1/chats/:ref")) return done(getChat(q));
    if (q.is(.PATCH, "/api/v1/chats/:ref")) return done(patchChat(q));
    if (q.is(.DELETE, "/api/v1/chats/:ref")) return done(deleteChat(q));
    if (q.is(.POST, "/api/v1/chats/:ref/members")) return done(addChatMembers(q));
    if (q.is(.DELETE, "/api/v1/chats/:ref/members/:userRef")) return done(removeChatMember(q));
    if (q.is(.GET, "/api/v1/chats/:ref/messages")) return done(listMessages(q));
    if (q.is(.POST, "/api/v1/chats/:ref/messages")) return done(postMessage(q));
    if (q.is(.DELETE, "/api/v1/chats/:ref/messages/:id")) return done(deleteMessage(q));
    return false;
}

fn chatRef(r: *Rq, app_doc: Val, ref: []const u8) !Val {
    const a = r.a;
    const f = try val.from(a, .{ .appId = app_doc.get("_id") });
    if (std.mem.startsWith(u8, ref, "ext:")) {
        try f.set(a, "externalId", ref[4..]);
    } else {
        const id = v.oidStr(ref) orelse return r.fail(404, "Chat not found", "chat_not_found");
        try f.set(a, "_id", id);
    }
    try f.set(a, "deletedAt", .{ .@"$exists" = false });
    return (try col().chats.findOne(a, f, .{})) orelse r.fail(404, "Chat not found", "chat_not_found");
}

fn userRef(r: *Rq, app_doc: Val, ref: []const u8) !Val {
    const a = r.a;
    const f = try Val.object(a);
    if (std.mem.startsWith(u8, ref, "id:")) try f.put(a, "_id", if (v.oidStr(ref[3..])) |x| Val{ .id = x } else Val.null) else try f.set(a, "externalId", ref);
    try f.put(a, "appId", app_doc.get("_id"));
    try f.set(a, "deletedAt", .{ .@"$exists" = false });
    return (try col().users.findOne(a, f, .{})) orelse r.fail(404, try r.fmt("User \"{s}\" not found. Create it with POST /api/v1/users first.", .{ref}), "user_not_found");
}

fn refStr(r: *Rq, x: Val) ![]const u8 {
    return r.str(x);
}

/// The app's own "system" sender for notices posted through the API.
fn systemUser(r: *Rq, app_doc: Val) !Val {
    const a = r.a;
    if (try col().users.findOne(a, .{ .appId = app_doc.get("_id"), .externalId = "__system__" }, .{})) |u| return u;
    const now = A.now();
    const name = try r.str(app_doc.get("name"));
    const doc = try val.from(a, .{
        .kind = "bot",
        .appId = app_doc.get("_id"),
        .externalId = "__system__",
        .displayName = name,
        .displayNameLower = try std.ascii.allocLowerString(a, name),
        .privacy = try auth.defaultPrivacy(a),
        .settings = try Val.object(a),
        .botInfo = .{ .description = "System messages", .system = true },
        .createdAt = now,
        .lastSeenAt = now,
    });
    _ = col().users.insertOne(a, doc) catch {
        return (try col().users.findOne(a, .{ .appId = app_doc.get("_id"), .externalId = "__system__" }, .{})) orelse error.SystemUser;
    };
    return doc;
}

fn teamInfo(r: *Rq, c: Val, out: Val) !void {
    if (!c.get("teamId").truthy()) return;
    const a = r.a;
    try out.set(a, "team", .{ .id = try sn(r, c.get("teamId")), .externalId = if (c.get("teamExternalId").truthy()) c.get("teamExternalId") else Val.null });
    try out.set(a, "visitor", .{ .id = try sn(r, c.get("visitorId")), .externalId = if (c.get("visitorExternalId").truthy()) c.get("visitorExternalId") else Val.null });
}

fn chatOut(r: *Rq, chat: Val) !Val {
    const a = r.a;
    const members = try col().members.find(a, .{ .chatId = chat.get("_id"), .status = "active" }, .{ .projection = .{ .userId = 1, .role = 1, .unread = 1, .lastReadSeq = 1 }, .limit = 1000 });
    var ids: std.ArrayList(Val) = .empty;
    for (members) |m| try ids.append(a, m.get("userId"));
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = ids.items } }, .{ .projection = .{ .externalId = 1, .displayName = 1 } });
    const out = try val.from(a, .{
        .id = try sn(r, chat.get("_id")),
        .type = chat.get("type"),
        .externalId = if (chat.get("externalId").truthy()) chat.get("externalId") else Val.null,
        .title = if (chat.get("title").truthy()) chat.get("title") else Val.null,
        .about = if (chat.get("about").truthy()) chat.get("about") else Val.s(""),
        .encrypted = chat.get("encrypted").truthy(),
        .metadata = if (chat.get("metadata").truthy()) chat.get("metadata") else Val.null,
        .memberCount = chat.get("memberCount"),
        .createdAt = chat.get("createdAt"),
        .lastMessageAt = chat.get("lastMessageAt"),
        .lastSeq = chat.get("seq").asInt() orelse 0,
    });
    try teamInfo(r, chat, out);
    var list = try Val.array(a);
    for (members) |m| {
        var u: Val = .null;
        for (users) |x| if (val.same(x.get("_id"), m.get("userId"))) {
            u = x;
        };
        try list.push(a, try val.from(a, .{
            .id = try sn(r, m.get("userId")),
            .externalId = if (u.get("externalId").truthy()) u.get("externalId") else Val.null,
            .name = u.get("displayName"),
            .role = m.get("role"),
            .unread = m.get("unread").asInt() orelse 0,
            .lastReadSeq = m.get("lastReadSeq").asInt() orelse 0,
        }));
    }
    try out.put(a, "members", list);
    return out;
}

// ---- App ----------------------------------------------------------------------------------

fn getApp(q: *Req) !void {
    return q.json(.{ .app = try apps.publicAppConfig(&q.r, q.app_) });
}

/// The app's own settings; a backend can pin what it depends on, e.g. { settings: { e2ee: 'off' } }.
fn patchApp(q: *Req) !void {
    const r = &q.r;
    try r.ensure(q.b("settings") != .undef, "Send { settings: { … } }", 400, null);
    _ = try apps.updateApp(r, q.app_, try val.from(r.a, .{ .settings = q.b("settings") }));
    return q.json(.{ .app = try apps.publicAppConfig(r, (try col().apps.findOne(r.a, .{ ._id = q.app_.get("_id") }, .{})) orelse q.app_) });
}

// ---- Users -------------------------------------------------------------------------------------

fn createUser(q: *Req) !void {
    return q.json(.{ .user = try apps.describeAppUser(&q.r, try apps.upsertAppUser(&q.r, q.app_, try q.bodyObj())) });
}

fn bulkUsers(q: *Req) !void {
    const r = &q.r;
    const list = q.b("users");
    try r.ensure(list == .arr and list.len() <= 100, "users must be a list of up to 100", 400, null);
    var out = try Val.array(r.a);
    for (list.items()) |u| try out.push(r.a, try apps.describeAppUser(r, try apps.upsertAppUser(r, q.app_, u)));
    return q.json(.{ .users = out });
}

fn getUser(q: *Req) !void {
    return q.json(.{ .user = try apps.describeAppUser(&q.r, try userRef(&q.r, q.app_, q.param("ref"))) });
}

fn patchUser(q: *Req) !void {
    const r = &q.r;
    const user = try userRef(r, q.app_, q.param("ref"));
    const body = try val.clone(r.a, try q.bodyObj());
    try body.put(r.a, "externalId", user.get("externalId"));
    return q.json(.{ .user = try apps.describeAppUser(r, try apps.upsertAppUser(r, q.app_, body)) });
}

fn deleteUser(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const user = try userRef(r, q.app_, q.param("ref"));
    _ = try col().users.updateOne(a, .{ ._id = user.get("_id") }, .{ .@"$set" = .{ .deletedAt = A.now(), .displayName = "Deleted user" }, .@"$unset" = .{ .keys = "", .username = "", .usernameLower = "" } }, .{});
    _ = try col().sessions.deleteMany(a, .{ .userId = user.get("_id") });
    _ = try col().members.updateMany(a, .{ .userId = user.get("_id"), .status = "active" }, .{ .@"$set" = .{ .status = "left", .leftAt = A.now() } }, .{});
    return q.json(.{ .ok = true });
}

/// A short-lived token the app's frontend passes to the Reseal widget for this user.
fn tokens(q: *Req) !void {
    const r = &q.r;
    const user = try userRef(r, q.app_, q.param("ref"));
    const ttl = try v.reqInt(r, if (q.b("ttlSeconds").isNullish()) Val.n(3600) else q.b("ttlSeconds"), "ttlSeconds", .{ .min = 60, .max = 30 * 86400 });
    const t = try auth.issueUserToken(r, user, ttl, q.app_.get("_id"), "api");
    return q.json(.{ .token = t.token, .expiresAt = t.expiresAt, .user = try apps.describeAppUser(r, user) });
}

fn revoke(q: *Req) !void {
    const user = try userRef(&q.r, q.app_, q.param("ref"));
    return q.json(.{ .revoked = try col().sessions.deleteMany(q.r.a, .{ .userId = user.get("_id") }) });
}

/// A user's chats with unread counters (for badges in the app's own UI).
fn userChats(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const user = try userRef(r, q.app_, q.param("ref"));
    const rows = try col().members.find(a, .{ .userId = user.get("_id"), .status = "active" }, .{});
    var ids: std.ArrayList(Val) = .empty;
    var total: f64 = 0;
    for (rows) |m| {
        try ids.append(a, m.get("chatId"));
        total += m.get("unread").asNum() orelse 0;
    }
    const list = try col().chats.find(a, .{ ._id = .{ .@"$in" = ids.items }, .deletedAt = .{ .@"$exists" = false } }, .{ .sort = .{ .lastMessageAt = -1 }, .limit = 200 });
    var out = try Val.array(a);
    for (list) |c| {
        var unread: f64 = 0;
        for (rows) |m| if (val.same(m.get("chatId"), c.get("_id"))) {
            unread = m.get("unread").asNum() orelse 0;
        };
        const o = try val.from(a, .{ .id = try sn(r, c.get("_id")), .type = c.get("type"), .externalId = if (c.get("externalId").truthy()) c.get("externalId") else Val.null, .title = if (c.get("title").truthy()) c.get("title") else Val.null, .metadata = if (c.get("metadata").truthy()) c.get("metadata") else Val.null });
        try teamInfo(r, c, o);
        try o.put(a, "unread", .{ .num = unread });
        try o.put(a, "lastMessageAt", c.get("lastMessageAt"));
        try out.push(a, o);
    }
    return q.json(.{ .chats = out, .unreadTotal = total });
}

/// Just the count, for badges a host page shows on every load.
fn userUnread(q: *Req) !void {
    const r = &q.r;
    const user = try userRef(r, q.app_, q.param("ref"));
    const rows = try col().members.aggregate(r.a, .{
        .{ .@"$match" = .{ .userId = user.get("_id"), .status = "active", .unread = .{ .@"$gt" = 0 } } },
        .{ .@"$group" = .{ ._id = Val.null, .total = .{ .@"$sum" = "$unread" } } },
    });
    return q.json(.{ .unreadTotal = if (rows.len > 0) (rows[0].get("total").asNum() orelse 0) else 0 });
}

// ---- Teams --------------------------------------------------------------------------------------

fn listTeams(q: *Req) !void {
    const r = &q.r;
    const limit = try v.reqInt(r, if (q.qv("limit") != .undef) q.qv("limit") else Val.n(100), "limit", .{ .min = 1, .max = 500 });
    const rows = try col().teams.find(r.a, .{ .appId = q.app_.get("_id") }, .{ .sort = .{ .createdAt = -1 }, .limit = limit });
    var out = try Val.array(r.a);
    for (rows) |t| try out.push(r.a, try teams.describeTeam(r, t));
    return q.json(.{ .teams = out });
}

fn createTeam(q: *Req) !void {
    const t = try teams.upsertTeam(&q.r, q.app_, try q.bodyObj());
    return q.json(.{ .team = try teams.describeTeam(&q.r, t) });
}

fn teamOf(q: *Req) !Val {
    return teams.teamRef(&q.r, q.app_, q.pv("ref"));
}

fn getTeam(q: *Req) !void {
    return q.json(.{ .team = try teams.describeTeam(&q.r, try teamOf(q)) });
}

fn patchTeam(q: *Req) !void {
    const t = try teamOf(q);
    return q.json(.{ .team = try teams.describeTeam(&q.r, try teams.updateTeam(&q.r, q.app_, t, try q.bodyObj())) });
}

fn deleteTeam(q: *Req) !void {
    try teams.deleteTeam(&q.r, try teamOf(q));
    return q.json(.{ .ok = true });
}

fn addTeamMembers(q: *Req) !void {
    const t = try teamOf(q);
    const res = try teams.addTeamMembers(&q.r, q.app_, t, q.b("members"));
    return q.json(.{ .team = try teams.describeTeam(&q.r, res.team), .added = res.added });
}

fn removeTeamMember(q: *Req) !void {
    const t = try teamOf(q);
    const user = try userRef(&q.r, q.app_, q.param("userRef"));
    return q.json(.{ .team = try teams.describeTeam(&q.r, try teams.removeTeamMember(&q.r, t, user)) });
}

/// The team's conversations with the team's unread counts.
fn teamChats(q: *Req) !void {
    const t = try teamOf(q);
    const lim = v.toNumber(q.qv("limit"));
    const list = try teams.teamChats(&q.r, t, if (std.math.isFinite(lim) and lim != 0) @intFromFloat(@trunc(lim)) else 100, q.query("before"));
    var total: f64 = 0;
    for (list.items()) |c| total += c.get("unread").asNum() orelse 0;
    return q.json(.{ .chats = list, .unreadTotal = total });
}

fn teamUnread(q: *Req) !void {
    return q.json(.{ .unreadTotal = try teams.teamUnreadTotal(&q.r, try teamOf(q)) });
}

// ---- Chats ----------------------------------------------------------------------------------

fn createChat(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const app_doc = q.app_;
    const b = try q.bodyObj();
    const type_ = try v.reqOneOf(r, if (b.get("type").truthy()) b.get("type") else Val.s("group"), "type", &.{ "private", "group", "channel", "support", "team" });
    const external_id = try v.str(r, b.get("externalId"), "externalId", .{ .max = 128, .optional = true });
    const ext: ?[]const u8 = if (external_id) |e| (if (e.len > 0) e else null) else null;
    if (std.mem.eql(u8, type_, "team")) {
        // A customer's conversation with a store (or any team).
        const t = try teams.teamRef(r, app_doc, .{ .str = try v.reqStr(r, b.get("team"), "team", .{ .min = 1, .max = 128 }) });
        try r.ensure(b.get("members") == .arr and b.get("members").len() == 1, "A team chat has exactly one visitor in members", 400, null);
        const visitor = try userRef(r, app_doc, try refStr(r, b.get("members").items()[0]));
        const bot_raw = app_doc.path("settings.widget.botId");
        const bot_id: ?Val = if (b.get("bot").isTrue() and bot_raw.truthy()) (if (v.oid(.{ .str = try r.str(bot_raw) })) |x| Val{ .id = x } else null) else null;
        const res = try teams.openTeamChat(r, app_doc, t, visitor, ext, b.get("metadata"), bot_id);
        return q.json(.{ .chat = try chatOut(r, res.chat), .created = res.created });
    }
    if (ext) |e| if (try col().chats.findOne(a, .{ .appId = app_doc.get("_id"), .externalId = e, .deletedAt = .{ .@"$exists" = false } }, .{})) |existing| {
        return q.json(.{ .chat = try chatOut(r, existing), .created = false });
    };
    try r.ensure(b.get("members") == .arr and b.get("members").len() >= 1 and b.get("members").len() <= 200, "members must list 1 to 200 externalIds", 400, null);
    var members: std.ArrayList(Val) = .empty;
    for (b.get("members").items()) |ref| try members.append(a, try userRef(r, app_doc, try refStr(r, ref)));
    var chat: Val = undefined;
    if (std.mem.eql(u8, type_, "private")) {
        try r.ensure(members.items.len == 2, "A private chat has exactly two members", 400, null);
        chat = try chats.openPrivate(r, members.items[0], members.items[1].get("_id"));
    } else if (std.mem.eql(u8, type_, "support")) {
        chat = try chats.openSupport(r, members.items[0], app_doc);
    } else {
        const owner = if (b.get("owner").truthy()) try userRef(r, app_doc, try refStr(r, b.get("owner"))) else members.items[0];
        var others = try Val.array(a);
        for (members.items) |m| if (!val.same(m.get("_id"), owner.get("_id"))) try others.push(a, .{ .str = try r.str(m.get("_id")) });
        const body = try val.from(a, .{ .type = type_, .title = if (b.get("title").truthy()) b.get("title") else Val.s("Chat"), .about = b.get("about"), .members = others, .metadata = b.get("metadata") });
        if (b.get("encrypted") != .undef) try body.set(a, "encrypted", try v.reqBool(r, b.get("encrypted"), "encrypted"));
        chat = (try chats.createGroup(r, owner, body)).chat;
    }
    const set = try Val.object(a);
    if (ext) |e| try set.set(a, "externalId", e);
    if (b.get("metadata") != .undef) try set.put(a, "metadata", (try v.meta(r, b.get("metadata"))) orelse .undef);
    if (b.get("title").truthy() and !std.mem.eql(u8, type_, "group") and !std.mem.eql(u8, type_, "channel")) try set.set(a, "title", try v.reqStr(r, b.get("title"), "title", .{ .max = 128 }));
    if (set.len() > 0) _ = col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = set }, .{}) catch |e| {
        if (e == error.DuplicateKey) {
            const existing = (try col().chats.findOne(a, .{ .appId = app_doc.get("_id"), .externalId = ext orelse "" }, .{})) orelse return e;
            return q.json(.{ .chat = try chatOut(r, existing), .created = false });
        }
        return e;
    };
    return q.json(.{ .chat = try chatOut(r, (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat), .created = true });
}

fn getChat(q: *Req) !void {
    return q.json(.{ .chat = try chatOut(&q.r, try chatRef(&q.r, q.app_, q.param("ref"))) });
}

fn patchChat(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const chat = try chatRef(r, q.app_, q.param("ref"));
    const set = try Val.object(a);
    if (q.b("title") != .undef) try set.set(a, "title", try v.reqStr(r, q.b("title"), "title", .{ .min = 1, .max = 128 }));
    if (q.b("about") != .undef) try set.set(a, "about", try v.reqStr(r, q.b("about"), "about", .{ .max = 1000 }));
    if (q.b("metadata") != .undef) try set.put(a, "metadata", (try v.meta(r, q.b("metadata"))) orelse .undef);
    if (set.len() > 0) _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = set }, .{});
    const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;
    for (rt.onlineMemberVals(a, chat.get("_id"))) |uid| try chats.pushChat(r, fresh, .{ .id = v.oid(uid).? }, "chat.update");
    return q.json(.{ .chat = try chatOut(r, fresh) });
}

fn deleteChat(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const chat = try chatRef(r, q.app_, q.param("ref"));
    const owner = try col().members.findOne(a, .{ .chatId = chat.get("_id"), .status = "active" }, .{ .sort = .{ .role = 1 } });
    const m = try val.clone(a, owner orelse try Val.object(a));
    try m.set(a, "role", "owner");
    try chats.deleteChat(r, chat, m, try val.from(a, .{ ._id = if (owner) |o| o.get("userId") else Val.undef }));
    return q.json(.{ .ok = true });
}

fn addChatMembers(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const chat = try chatRef(r, q.app_, q.param("ref"));
    const list = q.b("members");
    try r.ensure(list == .arr and list.len() <= 200, "members must be a list of up to 200", 400, null);
    var users: std.ArrayList(Val) = .empty;
    for (list.items()) |ref| try users.append(a, try userRef(r, q.app_, try refStr(r, ref)));
    const owner = (try col().members.findOne(a, .{ .chatId = chat.get("_id"), .status = "active", .role = "owner" }, .{})) orelse (try col().members.findOne(a, .{ .chatId = chat.get("_id"), .status = "active" }, .{})) orelse return r.fail(400, "The chat has no members to act for", null);
    const actor = (try col().users.findOne(a, .{ ._id = owner.get("userId") }, .{})) orelse Val.null;
    const m = try val.clone(a, owner);
    try m.set(a, "role", "owner");
    var ids: std.ArrayList(Val) = .empty;
    for (users.items) |u| try ids.append(a, u.get("_id"));
    const result = try chats.addMembers(r, chat, m, actor, ids.items);
    if (eq(q.b("role"), "admin")) for (users.items) |u| {
        _ = try col().members.updateOne(a, .{ .chatId = chat.get("_id"), .userId = u.get("_id") }, .{ .@"$set" = .{ .role = "admin", .rights = .{ .changeInfo = false, .postMessages = true, .editMessages = false, .deleteMessages = true, .banUsers = false, .inviteUsers = true, .pinMessages = true, .manageCalls = true, .addAdmins = false } } }, .{});
    };
    return q.json(result);
}

fn eq(x: Val, s: []const u8) bool {
    return x == .str and std.mem.eql(u8, x.str, s);
}

fn removeChatMember(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const chat = try chatRef(r, q.app_, q.param("ref"));
    const user = try userRef(r, q.app_, q.param("userRef"));
    const owner = try col().members.findOne(a, .{ .chatId = chat.get("_id"), .status = "active", .role = "owner" }, .{});
    if (owner != null and val.same(owner.?.get("userId"), user.get("_id"))) {
        try chats.leave(r, chat, owner.?, user);
    } else {
        const actor = if (owner) |o| (try col().users.findOne(a, .{ ._id = o.get("userId") }, .{})) orelse Val.null else user;
        const m = try val.clone(a, owner orelse try Val.object(a));
        try m.set(a, "role", "owner");
        try m.set(a, "status", "active");
        try chats.removeMember(r, chat, m, actor, user.get("_id"), if (q.query("ban")) |x| std.mem.eql(u8, x, "true") else false);
    }
    return q.json(.{ .ok = true });
}

fn listMessages(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const chat = try chatRef(r, q.app_, q.param("ref"));
    const limit = try v.reqInt(r, if (q.qv("limit") != .undef) q.qv("limit") else Val.n(50), "limit", .{ .min = 1, .max = 100 });
    const has_after = q.qv("after").truthy();
    const docs = try store.list(r, chat, .{
        .after = if (has_after) try v.reqInt(r, q.qv("after"), "after", .{ .min = 0 }) else null,
        .before = if (q.qv("before").truthy() and !has_after) try v.reqInt(r, q.qv("before"), "before", .{ .min = 1 }) else null,
        .asc = has_after,
        .limit = limit,
    });
    if (!has_after) std.mem.reverse(Val, docs);
    var sids: std.ArrayList(Val) = .empty;
    for (docs) |d| if (d.get("senderId").truthy()) try sids.append(a, d.get("senderId"));
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = sids.items } }, .{ .projection = .{ .externalId = 1 } });
    var out = try Val.array(a);
    for (docs) |d| {
        const m = try ser.message(a, d, .null, chat);
        m.del("enc");
        if (d.get("senderId").truthy()) {
            var ext: Val = .null;
            for (users) |u| if (val.same(u.get("_id"), d.get("senderId")) and u.get("externalId").truthy()) {
                ext = u.get("externalId");
            };
            try m.set(a, "sender", .{ .id = try sn(r, d.get("senderId")), .externalId = ext });
        } else try m.put(a, "sender", .null);
        try out.push(a, m);
    }
    return q.json(.{ .encrypted = chat.get("encrypted").truthy(), .messages = out });
}

/// Sends a message as a user, a bot, or (with no "from") the app itself. Unencrypted chats only.
fn postMessage(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const chat = try chatRef(r, q.app_, q.param("ref"));
    try r.ensure(!chat.get("encrypted").truthy(), "This chat is end-to-end encrypted, so only its members' devices can write to it", 409, "encrypted");
    const b = try q.bodyObj();
    if (b.get("from").truthy()) {
        const sender = try userRef(r, q.app_, try refStr(r, b.get("from")));
        const doc = try msgs.sendMessage(r, chat, sender, b, .{ .origin = .api });
        return q.json(.{ .message = try ser.message(a, doc, .null, chat) });
    }
    const sender = try systemUser(r, q.app_);
    const content = try msgs.cleanContent(r, chat, b, .api);
    for ([_][]const u8{ "replyToId", "fwdFrom", "fwdChat", "fwdCopy" }) |k| content.del(k);
    try content.set(a, "system", true);
    const doc = try msgs.publishRaw(r, chat, sender, content, false);
    return q.json(.{ .message = try ser.message(a, doc, .null, chat) });
}

fn deleteMessage(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const chat = try chatRef(r, q.app_, q.param("ref"));
    const msg = (try store.findOne(r, chat, .{ .id = try v.reqId(r, q.pv("id"), "id") }, null)) orelse return r.fail(404, "Message not found", null);
    const actor = (try col().users.findOne(a, .{ ._id = msg.get("senderId") }, .{})) orelse try systemUser(r, q.app_);
    _ = try msgs.deleteMessages(r, chat, try val.from(a, .{ .role = "owner", .status = "active", .rights = .{ .deleteMessages = true } }), actor, &.{msg.get("_id")}, true);
    return q.json(.{ .ok = true });
}
