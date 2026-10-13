//! AI bots and the developer console (src/routes/platform.js). Every route needs a signed-in
//! user; most are for Reseal accounts only (not users inside other apps).

const std = @import("std");
const A = @import("../app.zig");
const web = @import("../web.zig");
const v = @import("../validate.zig");
const ai = @import("../ai.zig");
const apps = @import("../apps.zig");
const auth = @import("../auth.zig");
const teams = @import("../teams.zig");
const store = @import("../store.zig");
const webhooks = @import("../webhooks.zig");
const platform = @import("../platform.zig");
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

fn ownersOnly(q: *Req) !void {
    if (q.user().get("appId").truthy()) return q.r.fail(403, "This is available to Reseal accounts only", null);
}

pub fn handle(q: *Req) !bool {
    if (q.is(.GET, "/api/bots")) return done(listBots(q));
    if (q.is(.GET, "/api/bots/discover")) return done(discover(q));
    if (q.is(.POST, "/api/bots")) return done(createBot(q));
    if (q.is(.GET, "/api/bots/:id")) return done(getBot(q));
    if (q.is(.PATCH, "/api/bots/:id")) return done(patchBot(q));
    if (q.is(.DELETE, "/api/bots/:id")) return done(deleteBot(q));
    if (q.is(.GET, "/api/dev/apps")) return done(listApps(q));
    if (q.is(.POST, "/api/dev/apps")) return done(createApp(q));
    if (q.is(.GET, "/api/dev/apps/:appId")) return done(getApp(q));
    if (q.is(.PATCH, "/api/dev/apps/:appId")) return done(patchApp(q));
    if (q.is(.DELETE, "/api/dev/apps/:appId")) return done(deleteApp(q));
    if (q.is(.POST, "/api/dev/apps/:appId/rotate-secret")) return done(rotate(q));
    if (q.is(.POST, "/api/dev/apps/:appId/webhook-secret")) return done(webhookSecret(q));
    if (q.is(.POST, "/api/dev/apps/:appId/webhook-test")) return done(webhookTest(q));
    if (q.is(.POST, "/api/dev/apps/:appId/storage-test")) return done(storageTest(q));
    if (q.is(.GET, "/api/dev/apps/:appId/deliveries")) return done(deliveries(q));
    if (q.is(.POST, "/api/dev/apps/:appId/deliveries/:id/retry")) return done(retry(q));
    if (q.is(.GET, "/api/dev/apps/:appId/users")) return done(appUsers(q));
    if (q.is(.GET, "/api/dev/apps/:appId/teams")) return done(appTeams(q));
    if (q.is(.POST, "/api/dev/apps/:appId/users")) return done(addAppUser(q));
    if (q.is(.POST, "/api/dev/apps/:appId/test-token")) return done(testToken(q));
    return false;
}

// ---- Bots -------------------------------------------------------------------------------------

fn ownedBot(q: *Req) !Val {
    const r = &q.r;
    return (try col().bots.findOne(r.a, .{ ._id = try v.reqId(r, q.pv("id"), "id"), .ownerId = q.user().get("_id") }, .{})) orelse r.fail(404, "Bot not found", null);
}

fn listBots(q: *Req) !void {
    try ownersOnly(q);
    const r = &q.r;
    const a = r.a;
    const f = try val.from(a, .{ .ownerId = q.user().get("_id") });
    if (q.qv("appId").truthy()) try f.set(a, "appId", try v.reqId(r, q.qv("appId"), "appId"));
    const bots = try col().bots.find(a, f, .{ .sort = .{ .createdAt = -1 } });
    var ids: std.ArrayList(Val) = .empty;
    for (bots) |b| try ids.append(a, b.get("_id"));
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = ids.items }, .deletedAt = .{ .@"$exists" = false } }, .{});
    var out = try Val.array(a);
    for (bots) |b| for (users) |u| if (val.same(u.get("_id"), b.get("_id"))) {
        try out.push(a, try ai.describeBot(r, b, u));
        break;
    };
    return q.json(.{ .bots = out });
}

/// Public bots anyone can start a chat with (the "bot store").
fn discover(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const bots = try col().bots.find(a, .{ .public = true, .appId = if (q.user().get("appId").truthy()) q.user().get("appId") else Val.null }, .{ .sort = .{ .@"stats.replies" = -1 }, .limit = 50 });
    var ids: std.ArrayList(Val) = .empty;
    for (bots) |b| try ids.append(a, b.get("_id"));
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = ids.items }, .deletedAt = .{ .@"$exists" = false } }, .{});
    var out = try Val.array(a);
    for (bots) |b| for (users) |u| if (val.same(u.get("_id"), b.get("_id"))) {
        const d = try ai.describeBot(r, b, u);
        try out.push(a, try val.from(a, .{ .id = d.get("id"), .name = d.get("name"), .username = d.get("username"), .avatar = d.get("avatar"), .description = d.get("description"), .model = d.get("model"), .starters = d.get("starters") }));
        break;
    };
    return q.json(.{ .bots = out });
}

fn createBot(q: *Req) !void {
    try ownersOnly(q);
    try account.rateLimit(q, "create-bot", 20, 3600_000);
    const r = &q.r;
    var app_id: Val = .null;
    if (q.b("appId").truthy()) app_id = (try apps.ownedApp(r, q.user(), q.b("appId"))).get("_id");
    return q.json(.{ .bot = try ai.createBot(r, q.user(), try q.bodyObj(), app_id) });
}

fn getBot(q: *Req) !void {
    try ownersOnly(q);
    const bot = try ownedBot(q);
    return q.json(.{ .bot = try ai.describeBot(&q.r, bot, (try col().users.findOne(q.r.a, .{ ._id = bot.get("_id") }, .{})) orelse Val.null) });
}

fn patchBot(q: *Req) !void {
    try ownersOnly(q);
    return q.json(.{ .bot = try ai.updateBot(&q.r, try ownedBot(q), try q.bodyObj()) });
}

fn deleteBot(q: *Req) !void {
    try ownersOnly(q);
    try ai.deleteBot(&q.r, try ownedBot(q));
    return q.json(.{ .ok = true });
}

// ---- Developer console: apps ------------------------------------------------------------------

fn listApps(q: *Req) !void {
    try ownersOnly(q);
    const a = q.r.a;
    const rows = try col().apps.find(a, .{ .ownerId = q.user().get("_id"), .deletedAt = .{ .@"$exists" = false } }, .{ .sort = .{ .createdAt = -1 } });
    var out = try Val.array(a);
    for (rows) |x| try out.push(a, try apps.describeApp(&q.r, x, null));
    return q.json(.{ .apps = out });
}

fn createApp(q: *Req) !void {
    try ownersOnly(q);
    try account.rateLimit(q, "create-app", 20, 3600_000);
    const r = &q.r;
    const s = platform.get();
    if (!s.dev_console) return r.fail(403, "Creating embed apps is paused for now", null);
    const n = try col().apps.count(r.a, .{ .ownerId = q.user().get("_id"), .deletedAt = .{ .@"$exists" = false } }, .{});
    try r.ensure(n < s.max_apps_per_owner, try r.fmt("You can have up to {d} apps", .{s.max_apps_per_owner}), 400, null);
    return q.json(.{ .app = try apps.createApp(r, q.user(), try q.bodyObj()) });
}

fn owned(q: *Req) !Val {
    try ownersOnly(q);
    return apps.ownedApp(&q.r, q.user(), q.pv("appId"));
}

fn getApp(q: *Req) !void {
    const app_doc = try owned(q);
    const a = q.r.a;
    const id = app_doc.get("_id");
    return q.json(.{ .app = try apps.describeApp(&q.r, app_doc, null), .stats = .{
        .users = try col().users.count(a, .{ .appId = id, .kind = "app", .deletedAt = .{ .@"$exists" = false } }, .{}),
        .chats = try col().chats.count(a, .{ .appId = id, .deletedAt = .{ .@"$exists" = false } }, .{}),
        .webhooksDelivered = try col().webhookDeliveries.count(a, .{ .appId = id, .status = "delivered" }, .{}),
        .webhooksFailed = try col().webhookDeliveries.count(a, .{ .appId = id, .status = "failed" }, .{}),
    } });
}

fn patchApp(q: *Req) !void {
    const app_doc = try owned(q);
    return q.json(.{ .app = try apps.updateApp(&q.r, app_doc, try q.bodyObj()) });
}

fn deleteApp(q: *Req) !void {
    const app_doc = try owned(q);
    try q.r.ensure(val.same(q.b("confirm"), app_doc.get("name")) and q.b("confirm") == .str, "Type the app name to confirm", 400, null);
    try apps.deleteApp(&q.r, app_doc);
    return q.json(.{ .ok = true });
}

fn rotate(q: *Req) !void {
    const app_doc = try owned(q);
    return q.json(.{ .secretKey = try apps.rotateSecret(&q.r, app_doc) });
}

fn webhookSecret(q: *Req) !void {
    const app_doc = try owned(q);
    return q.json(.{ .secret = try apps.revealWebhookSecret(&q.r, app_doc, q.b("rotate").isTrue()) });
}

fn webhookTest(q: *Req) !void {
    try ownersOnly(q);
    try account.rateLimit(q, "webhook-test", 20, 60_000);
    const app_doc = try owned(q);
    const r = &q.r;
    const a = r.a;
    const url = app_doc.path("webhook.url").asStr() orelse "";
    try r.ensure(url.len > 0, "Set a webhook URL first", 400, null);
    const now = A.nowMs();
    const res = try webhooks.deliver(r, url, A.unseal(a, app_doc.path("webhook.secretSealed")), try val.from(a, .{
        .id = try r.fmt("test_{d}", .{now}),
        .type = "ping",
        .createdAt = try val.isoDate(a, now),
        .appId = try r.str(app_doc.get("_id")),
        .data = .{ .message = "Hello from Reseal 👋" },
    }));
    const out = try val.from(a, .{ .ok = res.ok, .status = res.status });
    if (res.@"error") |e| try out.set(a, "error", e);
    return q.json(out);
}

/// Checks the storage endpoint before chats depend on it: a signed "ping" must answer { "ok": true }.
fn storageTest(q: *Req) !void {
    try ownersOnly(q);
    try account.rateLimit(q, "storage-test", 20, 60_000);
    const app_doc = try owned(q);
    const r = &q.r;
    const url = app_doc.path("storage.url").asStr() orelse "";
    try r.ensure(url.len > 0, "Set a storage URL first", 400, null);
    const secret = try apps.revealWebhookSecret(r, app_doc, false);
    const answer = store.callApp(r, app_doc.get("_id"), "ping", try Val.object(r.a), .{ .url = url, .secret = secret }) catch |e| {
        const msg = if (e == error.Http) (if (r.err) |he| he.message else "fetch failed") else @errorName(e);
        r.err = null;
        return q.json(.{ .ok = false, .@"error" = msg });
    };
    if (answer.get("ok").isTrue()) return q.json(.{ .ok = true });
    return q.json(.{ .ok = false, .@"error" = "The endpoint answered, but not with { \"ok\": true }" });
}

fn deliveries(q: *Req) !void {
    const app_doc = try owned(q);
    const r = &q.r;
    const a = r.a;
    const rows = try col().webhookDeliveries.find(a, .{ .appId = app_doc.get("_id") }, .{ .sort = .{ .createdAt = -1 }, .limit = 100 });
    var out = try Val.array(a);
    for (rows) |d| try out.push(a, try val.from(a, .{
        .id = try r.str(d.get("_id")),
        .event = d.get("event"),
        .status = d.get("status"),
        .attempts = d.get("attempts"),
        .lastStatus = if (d.get("lastStatus").isNullish()) Val.null else d.get("lastStatus"),
        .lastError = if (d.get("lastError").truthy()) d.get("lastError") else Val.null,
        .createdAt = d.get("createdAt"),
        .deliveredAt = if (d.get("deliveredAt").truthy()) d.get("deliveredAt") else Val.null,
        .nextAttemptAt = d.get("nextAttemptAt"),
        .payload = d.get("payload"),
    }));
    return q.json(.{ .deliveries = out });
}

fn retry(q: *Req) !void {
    const app_doc = try owned(q);
    const r = &q.r;
    _ = try col().webhookDeliveries.updateOne(r.a, .{ ._id = try v.reqId(r, q.pv("id"), "id"), .appId = app_doc.get("_id") }, .{ .@"$set" = .{ .status = "pending", .nextAttemptAt = A.now() } }, .{});
    webhooks.kick();
    return q.json(.{ .ok = true });
}

fn appUsers(q: *Req) !void {
    const app_doc = try owned(q);
    const r = &q.r;
    const a = r.a;
    const f = try val.from(a, .{ .appId = app_doc.get("_id"), .kind = "app", .deletedAt = .{ .@"$exists" = false } });
    if (q.qv("role").truthy()) try f.set(a, "role", try v.reqOneOf(r, q.qv("role"), "role", &.{ "user", "agent" }));
    if (q.query("q")) |text| if (text.len > 0) try f.set(a, "displayNameLower", .{ .@"$regex" = try account.escapeRe(a, try std.ascii.allocLowerString(a, text)) });
    const rows = try col().users.find(a, f, .{ .sort = .{ .createdAt = -1 }, .limit = 100 });
    var out = try Val.array(a);
    for (rows) |u| try out.push(a, try apps.describeAppUser(r, u));
    return q.json(.{ .users = out, .total = try col().users.count(a, f, .{}) });
}

fn appTeams(q: *Req) !void {
    const app_doc = try owned(q);
    const r = &q.r;
    const rows = try col().teams.find(r.a, .{ .appId = app_doc.get("_id") }, .{ .sort = .{ .createdAt = -1 }, .limit = 100 });
    var out = try Val.array(r.a);
    for (rows) |t| try out.push(r.a, try teams.describeTeam(r, t));
    return q.json(.{ .teams = out, .total = try col().teams.count(r.a, .{ .appId = app_doc.get("_id") }, .{}) });
}

fn addAppUser(q: *Req) !void {
    const app_doc = try owned(q);
    const user = try apps.upsertAppUser(&q.r, app_doc, try q.bodyObj());
    return q.json(.{ .user = try apps.describeAppUser(&q.r, user) });
}

/// A token for trying the widget in the console's live preview, without writing a backend.
fn testToken(q: *Req) !void {
    try ownersOnly(q);
    try account.rateLimit(q, "test-token", 60, 3600_000);
    const app_doc = try owned(q);
    const r = &q.r;
    const a = r.a;
    const ext = if (q.b("externalId").truthy()) q.b("externalId") else Val{ .str = try r.fmt("console-tester-{s}", .{try r.str(q.user().get("_id"))}) };
    const name = if (q.b("name").truthy()) q.b("name") else Val{ .str = try r.fmt("{s} (test)", .{try r.str(q.user().get("displayName"))}) };
    const user = try apps.upsertAppUser(r, app_doc, try val.from(a, .{
        .externalId = try v.reqStr(r, ext, "externalId", .{ .max = 128 }),
        .name = try v.reqStr(r, name, "name", .{ .max = 64 }),
        .role = if (std.mem.eql(u8, q.b("role").asStr() orelse "", "agent")) "agent" else "user",
    }));
    const t = try auth.issueUserToken(r, user, 3600, app_doc.get("_id"), "console");
    return q.json(.{ .token = t.token, .expiresAt = t.expiresAt, .user = try apps.describeAppUser(r, user) });
}
