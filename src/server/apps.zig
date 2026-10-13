//! Developer platform (src/services/apps.js): apps that embed Reseal chat in their own products.
//! Each app has a publishable key (safe in web pages), a secret key for its backend (shown once,
//! stored hashed), its own user directory, settings, webhooks and a storage endpoint.

const std = @import("std");
const Io = std.Io;
const A = @import("app.zig");
const v = @import("validate.zig");
const auth = @import("auth.zig");
const webhooks = @import("webhooks.zig");
const store = @import("store.zig");
const moderation = @import("moderation.zig");
const web = @import("web.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

pub const FEATURES = [_][]const u8{
    "groups",       "channels", "calls",     "video",        "voiceMessages", "videoMessages", "files",      "photos",   "reactions",
    "polls",        "stickers", "replies",   "forwarding",   "editing",       "deleting",      "pinning",    "search",   "typing",
    "readReceipts", "presence", "scheduled", "selfDestruct", "location",      "contacts",      "userSearch", "profiles", "stories",
    "export",
};

fn col() *A.Cols {
    return &A.app.col;
}

fn featureDefault(f: []const u8) bool {
    for ([_][]const u8{ "channels", "userSearch", "location", "contacts", "stories" }) |x| if (std.mem.eql(u8, x, f)) return false;
    return true;
}

pub fn defaultSettings(a: std.mem.Allocator) !Val {
    const features = try Val.object(a);
    for (FEATURES) |f| try features.set(a, f, featureDefault(f));
    return val.from(a, .{
        .e2ee = "off",
        .guests = false,
        .features = features,
        .theme = .{ .mode = "auto", .primary = "#6c5cff", .accent = "#4f8cff", .radius = 14, .font = "system", .density = "comfortable", .bubbleStyle = "rounded", .wallpaper = "pattern", .title = "", .subtitle = "", .logo = Val.null },
        .widget = .{
            .mode = "bubble",
            .position = "right",
            .offsetX = 24,
            .offsetY = 24,
            .launcherIcon = "chat",
            .launcherLabel = "",
            .defaultView = "chats",
            .botId = Val.null,
            .agentIds = .{},
            .supportTitle = "",
            .welcome = "",
            .placeholder = "",
            .width = 400,
            .height = 640,
            .showBranding = true,
            .locale = "auto",
        },
    });
}

const FONTS = [_][]const u8{ "system", "inter", "roboto", "serif", "mono", "rounded", "arabic" };

fn wallpaperPattern(s: []const u8) bool {
    if (std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "pattern") or std.mem.eql(u8, s, "gradient")) return true;
    return v.isHexColor(s);
}

fn httpUrlNoSpace(s: []const u8) bool {
    const lower_ok = (s.len >= 8 and std.ascii.eqlIgnoreCase(s[0..8], "https://")) or (s.len >= 7 and std.ascii.eqlIgnoreCase(s[0..7], "http://"));
    if (!lower_ok) return false;
    const rest = if (std.ascii.eqlIgnoreCase(s[0..5], "https")) s[8..] else s[7..];
    if (rest.len == 0) return false;
    for (rest) |c| if (std.ascii.isWhitespace(c)) return false;
    return true;
}

fn httpsUrl(s: []const u8) bool {
    return s.len >= 8 and std.ascii.eqlIgnoreCase(s[0..8], "https://");
}

pub fn mergeSettings(r: *Rq, current: Val, body: Val) !Val {
    const a = r.a;
    const defaults = try defaultSettings(a);
    const out = try val.deepClone(a, if (current.truthy()) current else defaults);
    for (defaults.keys()) |kv| if (out.get(kv.k) == .undef) try out.put(a, kv.k, try val.deepClone(a, kv.v));
    // Settings saved partially (older versions, scripts) still get every default underneath.
    for ([_][]const u8{ "theme", "widget" }) |group| {
        if (out.get(group) != .obj) try out.put(a, group, try Val.object(a));
        for (defaults.get(group).keys()) |kv| if (out.get(group).get(kv.k) == .undef) try out.get(group).put(a, kv.k, try val.deepClone(a, kv.v));
    }
    if (out.get("features") != .obj) try out.put(a, "features", try Val.object(a));
    for (FEATURES) |f| if (out.get("features").get(f) == .undef) try out.get("features").set(a, f, featureDefault(f));
    if (body.get("e2ee") != .undef) try out.set(a, "e2ee", try v.reqOneOf(r, body.get("e2ee"), "e2ee", &.{ "on", "off" }));
    if (body.get("guests") != .undef) try out.set(a, "guests", try v.reqBool(r, body.get("guests"), "guests"));
    if (body.get("features") != .undef) {
        _ = try v.reqObj(r, body.get("features"), "features");
        for (FEATURES) |f| if (body.get("features").get(f) == .bool) try out.get("features").put(a, f, body.get("features").get(f));
    }
    if (body.get("theme") != .undef) {
        const t = try v.reqObj(r, body.get("theme"), "theme");
        const th = out.get("theme");
        if (t.get("mode") != .undef) try th.set(a, "mode", try v.reqOneOf(r, t.get("mode"), "theme.mode", &.{ "auto", "light", "dark" }));
        if (t.get("primary") != .undef) try th.set(a, "primary", try v.reqStr(r, t.get("primary"), "theme.primary", .{ .pattern = v.isHexColor }));
        if (t.get("accent") != .undef) try th.set(a, "accent", try v.reqStr(r, t.get("accent"), "theme.accent", .{ .pattern = v.isHexColor }));
        if (t.get("radius") != .undef) try th.set(a, "radius", try v.reqInt(r, t.get("radius"), "theme.radius", .{ .min = 0, .max = 28 }));
        if (t.get("font") != .undef) try th.set(a, "font", try v.reqOneOf(r, t.get("font"), "theme.font", &FONTS));
        if (t.get("density") != .undef) try th.set(a, "density", try v.reqOneOf(r, t.get("density"), "theme.density", &.{ "comfortable", "compact" }));
        if (t.get("bubbleStyle") != .undef) try th.set(a, "bubbleStyle", try v.reqOneOf(r, t.get("bubbleStyle"), "theme.bubbleStyle", &.{ "rounded", "square", "minimal" }));
        if (t.get("wallpaper") != .undef) try th.set(a, "wallpaper", try v.reqStr(r, t.get("wallpaper"), "theme.wallpaper", .{ .max = 16, .pattern = wallpaperPattern }));
        if (t.get("title") != .undef) try th.set(a, "title", try v.reqStr(r, t.get("title"), "theme.title", .{ .max = 60 }));
        if (t.get("subtitle") != .undef) try th.set(a, "subtitle", try v.reqStr(r, t.get("subtitle"), "theme.subtitle", .{ .max = 120 }));
        if (t.get("logo") != .undef) try th.put(a, "logo", if (t.get("logo").truthy()) Val{ .str = try r.str(.{ .id = try v.reqId(r, t.get("logo"), "theme.logo") }) } else Val.null);
    }
    if (body.get("widget") != .undef) {
        const w = try v.reqObj(r, body.get("widget"), "widget");
        const wd = out.get("widget");
        if (w.get("mode") != .undef) try wd.set(a, "mode", try v.reqOneOf(r, w.get("mode"), "widget.mode", &.{ "bubble", "inline", "fullscreen" }));
        if (w.get("position") != .undef) try wd.set(a, "position", try v.reqOneOf(r, w.get("position"), "widget.position", &.{ "right", "left" }));
        if (w.get("offsetX") != .undef) try wd.set(a, "offsetX", try v.reqInt(r, w.get("offsetX"), "widget.offsetX", .{ .min = 0, .max = 400 }));
        if (w.get("offsetY") != .undef) try wd.set(a, "offsetY", try v.reqInt(r, w.get("offsetY"), "widget.offsetY", .{ .min = 0, .max = 400 }));
        if (w.get("launcherIcon") != .undef) try wd.set(a, "launcherIcon", try v.reqOneOf(r, w.get("launcherIcon"), "widget.launcherIcon", &.{ "chat", "bot", "help", "support" }));
        if (w.get("launcherLabel") != .undef) try wd.set(a, "launcherLabel", try v.reqStr(r, w.get("launcherLabel"), "widget.launcherLabel", .{ .max = 40 }));
        if (w.get("defaultView") != .undef) try wd.set(a, "defaultView", try v.reqOneOf(r, w.get("defaultView"), "widget.defaultView", &.{ "chats", "support", "bot" }));
        if (w.get("botId") != .undef) try wd.put(a, "botId", if (w.get("botId").truthy()) Val{ .str = try r.str(.{ .id = try v.reqId(r, w.get("botId"), "widget.botId") }) } else Val.null);
        if (w.get("agentIds") != .undef) {
            var ids = try Val.array(a);
            for (try v.reqIds(r, w.get("agentIds"), "widget.agentIds", 50)) |x| try ids.push(a, .{ .str = try r.str(.{ .id = x }) });
            try wd.put(a, "agentIds", ids);
        }
        if (w.get("supportTitle") != .undef) try wd.set(a, "supportTitle", try v.reqStr(r, w.get("supportTitle"), "widget.supportTitle", .{ .max = 60 }));
        if (w.get("welcome") != .undef) try wd.set(a, "welcome", try v.reqStr(r, w.get("welcome"), "widget.welcome", .{ .max = 500 }));
        if (w.get("placeholder") != .undef) try wd.set(a, "placeholder", try v.reqStr(r, w.get("placeholder"), "widget.placeholder", .{ .max = 80 }));
        if (w.get("width") != .undef) try wd.set(a, "width", try v.reqInt(r, w.get("width"), "widget.width", .{ .min = 300, .max = 1200 }));
        if (w.get("height") != .undef) try wd.set(a, "height", try v.reqInt(r, w.get("height"), "widget.height", .{ .min = 360, .max = 1200 }));
        if (w.get("showBranding") != .undef) try wd.set(a, "showBranding", try v.reqBool(r, w.get("showBranding"), "widget.showBranding"));
        if (w.get("locale") != .undef) try wd.set(a, "locale", try v.reqOneOf(r, w.get("locale"), "widget.locale", &.{ "auto", "en", "ar" }));
    }
    return out;
}

fn cleanOrigins(r: *Rq, list: Val) !Val {
    const a = r.a;
    try r.ensure(list == .arr and list.len() <= 50, "allowedOrigins must be a list of up to 50 origins", 400, null);
    var out = try Val.array(a);
    for (list.items(), 0..) |o, i| {
        const s = try v.reqStr(r, o, try r.fmt("allowedOrigins[{d}]", .{i}), .{ .min = 1, .max = 200 });
        const uri = std.Uri.parse(s) catch return r.fail(400, try r.fmt("\"{s}\" is not a valid origin, e.g. https://shop.example.com", .{s}), "invalid_input");
        try r.ensure(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https"), "Origins must use http or https", 400, null);
        const host = uri.host orelse return r.fail(400, try r.fmt("\"{s}\" is not a valid origin, e.g. https://shop.example.com", .{s}), "invalid_input");
        var hbuf: [256]u8 = undefined;
        const h = try v.jsLower(a, host.toRaw(&hbuf) catch "");
        const scheme = try v.jsLower(a, uri.scheme);
        const default_port: u16 = if (std.mem.eql(u8, scheme, "https")) 443 else 80;
        const origin = if (uri.port != null and uri.port.? != default_port) try r.fmt("{s}://{s}:{d}", .{ scheme, h, uri.port.? }) else try r.fmt("{s}://{s}", .{ scheme, h });
        var dup = false;
        for (out.items()) |x| if (std.mem.eql(u8, x.str, origin)) {
            dup = true;
        };
        if (!dup) try out.push(a, .{ .str = origin });
    }
    return out;
}

pub fn describeApp(r: *Rq, app_doc: Val, secret_key: ?[]const u8) !Val {
    const a = r.a;
    const wh = app_doc.get("webhook");
    var events_v = wh.get("events");
    if (events_v.len() == 0) {
        events_v = try Val.array(a);
        for (webhooks.WEBHOOK_EVENTS) |e| try events_v.push(a, .{ .str = e });
    }
    const out = try val.from(a, .{
        .id = try r.str(app_doc.get("_id")),
        .name = app_doc.get("name"),
        .description = if (app_doc.get("description").truthy()) app_doc.get("description") else Val.s(""),
        .publishableKey = app_doc.get("publishableKey"),
        .secretKeyHint = app_doc.get("secretKeyHint"),
    });
    if (secret_key) |k| try out.set(a, "secretKey", k);
    try out.put(a, "allowedOrigins", if (app_doc.get("allowedOrigins").truthy()) app_doc.get("allowedOrigins") else try Val.array(a));
    try out.put(a, "settings", try mergeSettings(r, app_doc.get("settings"), try Val.object(a)));
    try out.set(a, "webhook", .{ .url = if (wh.get("url").truthy()) wh.get("url") else Val.s(""), .enabled = wh.get("enabled").truthy(), .events = events_v, .secretHint = if (wh.get("secretHint").truthy()) wh.get("secretHint") else Val.null });
    try out.set(a, "storage", .{ .url = if (app_doc.path("storage.url").truthy()) app_doc.path("storage.url") else Val.s(""), .connected = app_doc.path("storage.url").truthy() });
    try out.set(a, "disabled", app_doc.get("disabled").truthy());
    try out.put(a, "createdAt", app_doc.get("createdAt"));
    return out;
}

/// What the embedded widget needs to know (safe to show publicly).
pub fn publicAppConfig(r: *Rq, app_doc: Val) !Val {
    const a = r.a;
    const settings = try mergeSettings(r, app_doc.get("settings"), try Val.object(a));
    const widget = try val.clone(a, settings.get("widget"));
    try widget.put(a, "agentIds", .undef);
    return val.from(a, .{
        .id = try r.str(app_doc.get("_id")),
        .name = app_doc.get("name"),
        .e2ee = access_eq(settings.get("e2ee"), "on"),
        .guests = settings.get("guests"),
        .features = settings.get("features"),
        .theme = settings.get("theme"),
        .widget = widget,
        // Whether "Message the team" leads anywhere: agents or an assistant are set up.
        .support = settings.path("widget.agentIds").len() > 0 or settings.path("widget.botId").truthy(),
        .allowedOrigins = if (app_doc.get("allowedOrigins").truthy()) app_doc.get("allowedOrigins") else try Val.array(a),
    });
}

fn access_eq(x: Val, s: []const u8) bool {
    return x == .str and std.mem.eql(u8, x.str, s);
}

pub fn createApp(r: *Rq, owner: Val, body: Val) !Val {
    const a = r.a;
    const name = try v.reqStr(r, body.get("name"), "name", .{ .min = 1, .max = 80 });
    const secret = try A.randomToken(a, "rsl_sk_", 32);
    const app_doc = try val.from(a, .{
        .ownerId = owner.get("_id"),
        .name = name,
        .description = (try v.str(r, body.get("description"), "description", .{ .max = 500, .optional = true })) orelse "",
        .publishableKey = try A.randomToken(a, "rsl_pk_", 18),
        .secretKeyHash = try A.sha256Hex(a, secret),
        .secretKeyHint = try A.hint(a, secret),
        .allowedOrigins = if (body.get("allowedOrigins").truthy()) try cleanOrigins(r, body.get("allowedOrigins")) else try Val.array(a),
        .settings = try mergeSettings(r, .null, if (body.get("settings").truthy()) body.get("settings") else try Val.object(a)),
        .webhook = .{ .url = "", .enabled = false, .events = .{}, .secretSealed = Val.null, .secretHint = Val.null },
        .storage = .{ .url = "" },
        .createdAt = A.now(),
    });
    _ = try col().apps.insertOne(a, app_doc);
    return describeApp(r, app_doc, secret);
}

pub fn updateApp(r: *Rq, app_doc: Val, body: Val) !Val {
    const a = r.a;
    const set = try Val.object(a);
    if (body.get("name") != .undef) try set.set(a, "name", try v.reqStr(r, body.get("name"), "name", .{ .min = 1, .max = 80 }));
    if (body.get("description") != .undef) try set.set(a, "description", try v.reqStr(r, body.get("description"), "description", .{ .max = 500 }));
    if (body.get("allowedOrigins") != .undef) try set.put(a, "allowedOrigins", try cleanOrigins(r, body.get("allowedOrigins")));
    if (body.get("settings") != .undef) try set.put(a, "settings", try mergeSettings(r, app_doc.get("settings"), try v.reqObj(r, body.get("settings"), "settings")));
    if (body.get("disabled") != .undef) try set.set(a, "disabled", try v.reqBool(r, body.get("disabled"), "disabled"));
    const logo = set.path("settings.theme.logo");
    if (logo.truthy()) {
        const m = try col().media.findOne(a, .{ ._id = v.oid(logo), .ownerId = app_doc.get("ownerId"), .status = "ready" }, .{});
        try r.ensure(m != null and std.mem.startsWith(u8, m.?.get("mime").asStr() orelse "", "image/"), "The logo must be an image you uploaded", 400, null);
        _ = try col().media.updateOne(a, .{ ._id = m.?.get("_id") }, .{ .@"$set" = .{ .public = true } }, .{});
    }
    const bot_id = set.path("settings.widget.botId");
    if (bot_id.truthy()) {
        const bot = try col().bots.findOne(a, .{ ._id = v.oid(bot_id) }, .{});
        try r.ensure(bot != null and (val.same(bot.?.get("appId"), app_doc.get("_id")) or val.same(bot.?.get("ownerId"), app_doc.get("ownerId"))), "Pick one of this app's bots", 400, null);
        if (!bot.?.get("appId").truthy()) _ = try col().bots.updateOne(a, .{ ._id = bot.?.get("_id") }, .{ .@"$set" = .{ .appId = app_doc.get("_id") } }, .{});
        _ = try col().users.updateOne(a, .{ ._id = bot.?.get("_id"), .appId = Val.null }, .{ .@"$set" = .{ .appId = app_doc.get("_id") } }, .{});
    }
    const agents = set.path("settings.widget.agentIds");
    if (agents.len() > 0) {
        var ids: std.ArrayList(Val) = .empty;
        for (agents.items()) |x| try ids.append(a, if (v.oid(x)) |o| Val{ .id = o } else Val.null);
        const n = try col().users.count(a, .{ ._id = .{ .@"$in" = ids.items }, .appId = app_doc.get("_id") }, .{});
        try r.ensure(n == agents.len(), "Agents must be users of this app", 400, null);
    }
    if (body.get("webhook") != .undef) {
        const w = try v.reqObj(r, body.get("webhook"), "webhook");
        if (w.get("url") != .undef) try set.set(a, "webhook.url", if (w.get("url").truthy()) try v.reqStr(r, w.get("url"), "webhook.url", .{ .max = 500, .pattern = httpUrlNoSpace }) else "");
        if (w.get("enabled") != .undef) try set.set(a, "webhook.enabled", try v.reqBool(r, w.get("enabled"), "webhook.enabled"));
        if (w.get("events") != .undef) {
            try r.ensure(w.get("events") == .arr, "webhook.events must be a list", 400, null);
            var list = try Val.array(a);
            for (w.get("events").items()) |e| {
                const x = try v.reqOneOf(r, e, "event", &webhooks.WEBHOOK_EVENTS);
                var dup = false;
                for (list.items()) |y| if (std.mem.eql(u8, y.str, x)) {
                    dup = true;
                };
                if (!dup) try list.push(a, .{ .str = x });
            }
            try set.put(a, "webhook.events", list);
        }
    }
    if (body.get("storage") != .undef) {
        const st = try v.reqObj(r, body.get("storage"), "storage");
        if (st.get("url") != .undef) try set.set(a, "storage.url", if (st.get("url").truthy()) try v.reqStr(r, st.get("url"), "storage.url", .{ .max = 500, .pattern = httpUrlNoSpace }) else "");
    }
    // Webhooks and storage calls are signed with the same secret.
    if ((body.get("webhook") != .undef or body.get("storage") != .undef) and !app_doc.path("webhook.secretSealed").truthy()) {
        const secret = try A.randomToken(a, "whsec_", 24);
        try set.put(a, "webhook.secretSealed", try A.seal(a, secret));
        try set.put(a, "webhook.secretHint", try A.hint(a, secret));
    }
    if (set.len() > 0) _ = try col().apps.updateOne(a, .{ ._id = app_doc.get("_id") }, .{ .@"$set" = set }, .{});
    webhooks.forgetApp(app_doc.get("_id"));
    store.forgetApp(app_doc.get("_id"));
    forgetFeatures(app_doc.get("_id"));
    return describeApp(r, (try col().apps.findOne(a, .{ ._id = app_doc.get("_id") }, .{})) orelse app_doc, null);
}

pub fn rotateSecret(r: *Rq, app_doc: Val) ![]const u8 {
    const a = r.a;
    const secret = try A.randomToken(a, "rsl_sk_", 32);
    _ = try col().apps.updateOne(a, .{ ._id = app_doc.get("_id") }, .{ .@"$set" = .{ .secretKeyHash = try A.sha256Hex(a, secret), .secretKeyHint = try A.hint(a, secret) } }, .{});
    return secret;
}

pub fn revealWebhookSecret(r: *Rq, app_doc: Val, rotate: bool) ![]const u8 {
    const a = r.a;
    var secret = A.unseal(a, app_doc.path("webhook.secretSealed"));
    if (secret == null or rotate) {
        const s = try A.randomToken(a, "whsec_", 24);
        _ = try col().apps.updateOne(a, .{ ._id = app_doc.get("_id") }, .{ .@"$set" = .{ .@"webhook.secretSealed" = try A.seal(a, s), .@"webhook.secretHint" = try A.hint(a, s) } }, .{});
        webhooks.forgetApp(app_doc.get("_id"));
        store.forgetApp(app_doc.get("_id"));
        secret = s;
    }
    return secret.?;
}

pub fn ownedApp(r: *Rq, user: Val, app_id: Val) !Val {
    const id = try v.reqId(r, app_id, "appId");
    return (try col().apps.findOne(r.a, .{ ._id = id, .ownerId = user.get("_id"), .deletedAt = .{ .@"$exists" = false } }, .{})) orelse r.fail(404, "App not found", "app_not_found");
}

pub fn deleteApp(r: *Rq, app_doc: Val) !void {
    const a = r.a;
    const id = try r.str(app_doc.get("_id"));
    _ = try col().apps.updateOne(a, .{ ._id = app_doc.get("_id") }, .{ .@"$set" = .{ .deletedAt = A.now(), .disabled = true, .publishableKey = try r.fmt("deleted_{s}", .{id}), .secretKeyHash = try r.fmt("deleted_{s}", .{id}) } }, .{});
    _ = try col().sessions.deleteMany(a, .{ .appId = app_doc.get("_id") });
}

/// requireAppSecret: `Authorization: Bearer rsl_sk_…` (or X-Reseal-Key).
pub fn requireAppSecret(q: *web.Req) !void {
    const r = &q.r;
    const header = q.header("authorization") orelse "";
    const key = if (std.mem.startsWith(u8, header, "Bearer ")) std.mem.trim(u8, header[7..], " \t") else (q.header("x-reseal-key") orelse "");
    if (!std.mem.startsWith(u8, key, "rsl_sk_")) return r.fail(401, "Send your secret key as \"Authorization: Bearer rsl_sk_…\"", "unauthorized");
    const app_doc = (try col().apps.findOne(r.a, .{ .secretKeyHash = try A.sha256Hex(r.a, key), .deletedAt = .{ .@"$exists" = false } }, .{})) orelse return r.fail(401, "Invalid secret key", "unauthorized");
    if (app_doc.get("disabled").truthy()) return r.fail(403, "This app is disabled", "app_disabled");
    q.app_ = app_doc;
}

/// REST API calls per minute this app may make (0 = no limit).
pub fn apiRateLimitFor(app_doc: Val) i64 {
    if (app_doc.get("apiRateLimit").asInt()) |own| if (own >= 0) return own;
    return A.app.config.api_rate_limit;
}

pub fn appByPublishableKey(r: *Rq, pk: []const u8) !?Val {
    if (!std.mem.startsWith(u8, pk, "rsl_pk_")) return null;
    return col().apps.findOne(r.a, .{ .publishableKey = pk, .deletedAt = .{ .@"$exists" = false }, .disabled = .{ .@"$ne" = true } }, .{});
}

// ---- App users -------------------------------------------------------------------------------

pub fn upsertAppUser(r: *Rq, app_doc: Val, body: Val) !Val {
    const a = r.a;
    const ext_v = if (body.get("externalId").isNullish()) body.get("id") else body.get("externalId");
    const external_id = try v.reqStr(r, ext_v, "externalId", .{ .min = 1, .max = 128 });
    const set = try val.from(a, .{ .updatedAt = A.now() });
    if (body.get("name") != .undef) {
        const name = try v.reqStr(r, body.get("name"), "name", .{ .min = 1, .max = 64 });
        try set.set(a, "displayName", name);
        try set.set(a, "displayNameLower", try v.jsLower(a, name));
    }
    if (body.get("avatarUrl") != .undef) try set.put(a, "avatarUrl", if (body.get("avatarUrl").truthy()) Val{ .str = try v.reqStr(r, body.get("avatarUrl"), "avatarUrl", .{ .max = 2048, .pattern = httpsUrl }) } else Val.null);
    if (body.get("bio") != .undef) try set.set(a, "bio", try v.reqStr(r, body.get("bio"), "bio", .{ .max = 300 }));
    // Content checks (Wufour Moderation): names and bios are visible to other people in the app.
    if (set.get("displayName") != .undef or set.get("bio") != .undef) {
        _ = try moderation.check(r, try val.from(a, .{ .externalId = external_id, .displayName = set.get("displayName") }), try val.from(a, .{ .type = "profile", .id = external_id, .field = "app-user" }), try val.from(a, .{ .name = set.get("displayName"), .bio = set.get("bio") }), null);
    }
    if (body.get("role") != .undef) try set.set(a, "role", try v.reqOneOf(r, body.get("role"), "role", &.{ "user", "agent" }));
    if (body.get("metadata") != .undef) try set.put(a, "metadata", (try v.meta(r, body.get("metadata"))) orelse .undef);
    if (body.get("username") != .undef and body.get("username").truthy()) {
        const un = try v.reqStr(r, body.get("username"), "username", .{ .pattern = v.isUsername });
        try set.set(a, "username", un);
        // Usernames are unique per app.
        try set.set(a, "usernameLower", try r.fmt("{s}:{s}", .{ try r.str(app_doc.get("_id")), try v.jsLower(a, un) }));
    }
    const now = A.now();
    const on_insert = try val.from(a, .{ .kind = "app", .appId = app_doc.get("_id"), .externalId = external_id, .privacy = try auth.defaultPrivacy(a), .settings = try Val.object(a), .createdAt = now, .lastSeenAt = now });
    if (set.get("displayName") == .undef) {
        try on_insert.set(a, "displayName", if (std.mem.startsWith(u8, external_id, "guest:")) "Guest" else external_id);
        try on_insert.set(a, "displayNameLower", try v.jsLower(a, external_id));
    }
    const user = col().users.findOneAndUpdate(a, .{ .appId = app_doc.get("_id"), .externalId = external_id }, .{ .@"$set" = set, .@"$setOnInsert" = on_insert, .@"$unset" = .{ .deletedAt = "" } }, .{ .upsert = true }) catch |e| {
        if (e == error.DuplicateKey) return r.fail(409, "That username is taken in this app", "username_taken");
        return e;
    };
    return user orelse error.UpsertReturnedNothing;
}

pub fn findAppUser(r: *Rq, app_doc: Val, external_id: []const u8) !Val {
    return (try col().users.findOne(r.a, .{ .appId = app_doc.get("_id"), .externalId = external_id, .deletedAt = .{ .@"$exists" = false } }, .{})) orelse r.fail(404, "User not found", "user_not_found");
}

pub fn describeAppUser(r: *Rq, u: Val) !Val {
    return val.from(r.a, .{
        .id = try r.str(u.get("_id")),
        .externalId = u.get("externalId"),
        .name = u.get("displayName"),
        .username = if (u.get("username").truthy()) u.get("username") else Val.null,
        .avatarUrl = if (u.get("avatarUrl").truthy()) u.get("avatarUrl") else Val.null,
        .bio = if (u.get("bio").truthy()) u.get("bio") else Val.s(""),
        .role = if (u.get("role").truthy()) u.get("role") else Val.s("user"),
        .metadata = if (u.get("metadata").truthy()) u.get("metadata") else Val.null,
        .hasKeys = u.path("keys.enc").truthy(),
        .createdAt = u.get("createdAt"),
        .lastSeenAt = u.get("lastSeenAt"),
    });
}

// Feature switches per app, cached 30 s.
const FeatureEntry = struct { at: i64, off: std.StringHashMapUnmanaged(void) };
var feature_lock: Io.Mutex = .init;
var feature_cache: std.AutoHashMapUnmanaged([24]u8, FeatureEntry) = .empty;

/// Fails when an app has turned a feature off. Reseal accounts have every feature.
pub fn assertFeature(r: *Rq, user: Val, feature: []const u8, message: []const u8) !void {
    if (!user.get("appId").truthy()) return;
    const key = (try r.str(user.get("appId")));
    if (key.len != 24) return;
    const k = key[0..24].*;
    const io = A.app.io;
    const gpa = A.app.gpa;
    {
        feature_lock.lockUncancelable(io);
        defer feature_lock.unlock(io);
        if (feature_cache.get(k)) |e| if (A.nowMs() - e.at <= 30_000) {
            if (e.off.contains(feature)) return r.fail(403, message, "feature_disabled");
            return;
        };
    }
    const app_doc = try col().apps.findOne(r.a, .{ ._id = user.get("appId") }, .{ .projection = .{ .settings = 1 } });
    const features = (try mergeSettings(r, if (app_doc) |d| d.get("settings") else .null, try Val.object(r.a))).get("features");
    var off: std.StringHashMapUnmanaged(void) = .empty;
    for (FEATURES) |f| if (features.get(f) == .bool and !features.get(f).bool) off.put(gpa, f, {}) catch {};
    const disabled = off.contains(feature);
    {
        feature_lock.lockUncancelable(io);
        defer feature_lock.unlock(io);
        if (feature_cache.fetchRemove(k)) |old| {
            var o = old.value.off;
            o.deinit(gpa);
        }
        feature_cache.put(gpa, k, .{ .at = A.nowMs(), .off = off }) catch {
            off.deinit(gpa);
        };
    }
    if (disabled) return r.fail(403, message, "feature_disabled");
}

pub fn forgetFeatures(app_id: Val) void {
    var buf: [40]u8 = undefined;
    const k = val.keyOf(app_id, &buf) orelse return;
    if (k.len != 24) return;
    feature_lock.lockUncancelable(A.app.io);
    defer feature_lock.unlock(A.app.io);
    if (feature_cache.fetchRemove(k[0..24].*)) |old| {
        var o = old.value.off;
        o.deinit(A.app.gpa);
    }
}
