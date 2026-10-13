//! Endpoints the embeddable widget uses (src/routes/embed.js).

const std = @import("std");
const A = @import("../app.zig");
const web = @import("../web.zig");
const v = @import("../validate.zig");
const auth = @import("../auth.zig");
const apps = @import("../apps.zig");
const chats = @import("../chats.zig");
const media = @import("../media.zig");
const teams = @import("../teams.zig");
const account = @import("account.zig");
const val = A.val;
const Val = A.Val;
const Req = web.Req;

fn col() *A.Cols {
    return &A.app.col;
}

fn done(res: anyerror!void) anyerror!bool {
    try res;
    return true;
}

pub fn handle(q: *Req) !bool {
    if (q.is(.GET, "/api/embed/config")) return done(config(q));
    if (q.is(.POST, "/api/embed/guest")) return done(guest(q));
    if (q.is(.POST, "/api/embed/support")) return done(support(q));
    if (q.is(.POST, "/api/embed/bot")) return done(bot(q));
    if (q.is(.POST, "/api/embed/team")) return done(team(q));
    if (q.is(.GET, "/api/embed/teams")) return done(myTeams(q));
    if (q.is(.GET, "/api/embed/resolve")) return done(resolve(q));
    return false;
}

fn config(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const app_doc = (try apps.appByPublishableKey(r, q.query("pk") orelse "")) orelse return r.fail(404, "Unknown or disabled app key", "app_not_found");
    const cfg = try apps.publicAppConfig(r, app_doc);
    const logo = cfg.path("theme.logo");
    if (logo.truthy()) try cfg.get("theme").set(a, "logoUrl", try media.signedPath(r, try r.str(logo), 30 * 86400));
    const bot_id = cfg.path("widget.botId");
    if (bot_id.truthy()) {
        const b = try col().users.findOne(a, .{ ._id = v.oid(.{ .str = try r.str(bot_id) }) }, .{ .projection = .{ .displayName = 1, .avatar = 1 } });
        try cfg.get("widget").put(a, "bot", if (b) |x| try val.from(a, .{ .id = try r.str(x.get("_id")), .name = x.get("displayName"), .avatar = if (x.get("avatar").truthy()) Val{ .str = try r.str(x.get("avatar")) } else Val.null }) else Val.null);
    }
    // The SDK on the host site reads this (public, no credentials).
    try q.setHeader("cache-control", "no-store");
    try q.setHeader("access-control-allow-origin", "*");
    return q.json(.{ .app = cfg });
}

fn guestPattern(s: []const u8) bool {
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

/// Anonymous visitors (when the app allows guests): no backend needed, e.g. an AI help widget.
fn guest(q: *Req) !void {
    try account.rateLimit(q, "guest", 20, 3600_000);
    const r = &q.r;
    const a = r.a;
    const pk = try val.str(a, if (q.b("pk").truthy()) q.b("pk") else Val.s(""));
    const app_doc = (try apps.appByPublishableKey(r, pk)) orelse return r.fail(404, "Unknown or disabled app key", "app_not_found");
    try r.ensure(app_doc.path("settings.guests").truthy(), "This app does not allow guest chats", 403, "guests_disabled");
    const guest_id = try v.reqStr(r, q.b("guestId"), "guestId", .{ .min = 16, .max = 64, .pattern = guestPattern });
    const name = try v.str(r, q.b("name"), "name", .{ .max = 64, .optional = true });
    const body = try val.from(a, .{ .externalId = try r.fmt("guest:{s}", .{guest_id}) });
    if (name) |n| if (n.len > 0) try body.set(a, "name", n);
    const user = try apps.upsertAppUser(r, app_doc, body);
    _ = try col().users.updateOne(a, .{ ._id = user.get("_id") }, .{ .@"$set" = .{ .guest = true } }, .{});
    const t = try auth.issueUserToken(r, user, 7 * 86400, app_doc.get("_id"), "guest");
    return q.json(.{ .token = t.token, .expiresAt = t.expiresAt });
}

/// The widget's "Contact support" entry point.
fn support(q: *Req) !void {
    try auth.requireUser(q);
    const r = &q.r;
    try r.ensure(q.user().get("appId").truthy(), "Support chats exist inside apps only", 400, null);
    const app_doc = (try col().apps.findOne(r.a, .{ ._id = q.user().get("appId") }, .{})) orelse Val.null;
    const chat = try chats.openSupport(r, q.user(), app_doc);
    return q.json(.{ .chat = try chats.chatFor(r, chat, q.user().get("_id"), null) });
}

/// The widget's "Ask AI" entry point.
fn bot(q: *Req) !void {
    try auth.requireUser(q);
    const r = &q.r;
    try r.ensure(q.user().get("appId").truthy(), "Only inside apps", 400, null);
    const app_doc = try col().apps.findOne(r.a, .{ ._id = q.user().get("appId") }, .{});
    const bot_id = if (app_doc) |d| d.path("settings.widget.botId") else Val.undef;
    try r.ensure(bot_id.truthy(), "This app has no AI assistant configured", 404, null);
    const id = v.oid(.{ .str = try r.str(bot_id) }) orelse return r.fail(404, "User not found", "user_not_found");
    const chat = try chats.openPrivate(r, q.user(), .{ .id = id });
    return q.json(.{ .chat = try chats.chatFor(r, chat, q.user().get("_id"), null) });
}

/// "Message this store": the visitor opens (or continues) their conversation with a team.
fn team(q: *Req) !void {
    try auth.requireUser(q);
    try account.rateLimit(q, "team-chat", 60, 3600_000);
    const r = &q.r;
    try r.ensure(q.user().get("appId").truthy(), "Only inside apps", 400, null);
    const app_doc = (try col().apps.findOne(r.a, .{ ._id = q.user().get("appId") }, .{})) orelse Val.null;
    const t = try teams.teamRef(r, app_doc, .{ .str = try v.reqStr(r, q.b("team"), "team", .{ .min = 1, .max = 128 }) });
    const ext = try v.str(r, q.b("externalChatId"), "externalChatId", .{ .max = 128, .optional = true });
    const res = try teams.openTeamChat(r, app_doc, t, q.user(), if (ext) |e| (if (e.len > 0) e else null) else null, q.b("metadata"), null);
    return q.json(.{ .chat = try chats.chatFor(r, res.chat, q.user().get("_id"), null) });
}

/// The teams this user answers for (shown as filters on a staff dashboard).
fn myTeams(q: *Req) !void {
    try auth.requireUser(q);
    const r = &q.r;
    var out = try Val.array(r.a);
    for (try teams.teamsOf(r, q.user())) |t| try out.push(r.a, try teams.publicTeam(r, t));
    return q.json(.{ .teams = out });
}

/// The host page can open chats by its own ids: a person or a chat (externalId).
fn resolve(q: *Req) !void {
    try auth.requireUser(q);
    const r = &q.r;
    const a = r.a;
    try r.ensure(q.user().get("appId").truthy(), "Only inside apps", 400, null);
    if (q.query("user")) |u| if (u.len > 0) {
        const found = (try col().users.findOne(a, .{ .appId = q.user().get("appId"), .externalId = u, .deletedAt = .{ .@"$exists" = false } }, .{ .projection = .{ ._id = 1 } })) orelse return r.fail(404, "User not found", "user_not_found");
        return q.json(.{ .userId = try r.str(found.get("_id")) });
    };
    if (q.query("chat")) |c| if (c.len > 0) {
        const chat = try col().chats.findOne(a, .{ .appId = q.user().get("appId"), .externalId = c, .deletedAt = .{ .@"$exists" = false } }, .{ .projection = .{ ._id = 1 } });
        const m = if (chat) |x| try col().members.findOne(a, .{ .chatId = x.get("_id"), .userId = q.user().get("_id"), .status = "active" }, .{ .projection = .{ ._id = 1 } }) else null;
        try r.ensure(m != null, "Chat not found", 404, "chat_not_found");
        return q.json(.{ .chatId = try r.str(chat.?.get("_id")) });
    };
    return r.fail(400, "Pass ?user= or ?chat=", null);
}
