//! Reseal server: Reseal-js (server.js) on zig-core. Same endpoints, answers, WebSocket protocol,
//! database documents and environment variables, so it can replace the Node server without any
//! other app (Control, Taazur, Wufour, Moderation) noticing.
//!
//! Configuration: environment variables, else RESEAL_ENV_FILE or the first of `.env.local`,
//! `.env.production`, `.env` (see app.Config).

const std = @import("std");
const http = @import("http");
const mongo = @import("mongo");
const env_mod = @import("env");
const A = @import("app.zig");
const web = @import("web.zig");
const auth = @import("auth.zig");
const rt = @import("realtime.zig");
const msgs = @import("messages.zig");
const media = @import("media.zig");
const webhooks = @import("webhooks.zig");
const calls = @import("calls.zig");
const apps = @import("apps.zig");
const platform = @import("platform.zig");
const r_account = @import("routes/account.zig");
const r_chats = @import("routes/chats.zig");
const r_media = @import("routes/media.zig");
const r_platform = @import("routes/platform.zig");
const r_embed = @import("routes/embed.zig");
const r_v1 = @import("routes/v1.zig");
const r_stories = @import("routes/stories.zig");
const r_internal = @import("routes/internal.zig");
const val = A.val;
const Val = A.Val;
const Req = web.Req;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const env = try env_mod.Env.loadApp(arena, io, init.environ_map, "reseal");
    const config = try A.Config.load(arena, io, &env);
    // FCM and APNs for the phone apps (off unless their environment variables are set).
    @import("push.zig").initNative(gpa, io, &env);

    const client = try mongo.Client.init(io, gpa, config.mongo_uri);
    defer client.deinit();
    var state: A.App = .{
        .io = io,
        .gpa = gpa,
        .config = config,
        .mongo = client,
        .col = undefined,
        .fetch = .init(io, gpa),
        .wufour = undefined,
        .started_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    };
    defer state.fetch.deinit();
    state.fetch.allow_private = config.allow_private_fetch;
    state.wufour = .{ .fetch = &state.fetch, .host = config.auth_host, .ttl_ms = 60_000, .refused_ttl_ms = 5_000 };
    defer state.wufour.deinit();
    inline for (comptime std.meta.fieldNames(A.Cols)) |name| {
        @field(state.col, name) = .{ .client = client, .db = config.db_name, .name = name };
    }
    A.app = &state;

    _ = client.command(arena, "admin", .{ .ping = 1 }) catch |err| {
        std.log.err("MongoDB connection failed: {t} {s}", .{ err, client.lastError() });
        return err;
    };
    ensureIndexes(arena);
    try calls.closeStaleCalls(arena);

    var router: http.Router = .init(gpa);
    defer router.deinit();
    router.fallback = handle;

    defer state.bg.cancel(io);
    try state.bg.concurrent(io, msgs.jobsLoop, .{});
    try state.bg.concurrent(io, media.sweeperLoop, .{});
    try state.bg.concurrent(io, webhooks.workerLoop, .{});
    try state.bg.concurrent(io, rt.pingLoop, .{});

    std.log.info("Reseal is running at {s} (port {d})", .{ config.public_url, config.port });
    std.log.info("   Wufour Auth: {s}   Database: {s}", .{ config.auth_host, config.db_name });
    try http.serve(io, gpa, .{
        .address = try .parse(config.listen, config.port),
        .router = &router,
        // Chunk uploads are 1 MiB plus the encryption tag; JSON bodies are limited to 512 KiB
        // per request in web.zig.
        .max_body = 2 * 1024 * 1024,
        .trust_proxy = config.trust_proxy,
    });
}

// ---- Indexes (src/db.js) ---------------------------------------------------------------------

fn ensureIndexes(arena: std.mem.Allocator) void {
    const S = struct { c: []const u8, keys: []const u8, opts: []const u8 = "{}" };
    const P = struct {
        fn partial(comptime field: []const u8, comptime t: []const u8) []const u8 {
            return "{\"unique\":true,\"partialFilterExpression\":{\"" ++ field ++ "\":{\"$type\":\"" ++ t ++ "\"}}}";
        }
    };
    const specs = [_]S{
        .{ .c = "users", .keys = "{\"wufourId\":1}", .opts = P.partial("wufourId", "string") },
        .{ .c = "users", .keys = "{\"appId\":1,\"externalId\":1}", .opts = P.partial("externalId", "string") },
        .{ .c = "users", .keys = "{\"usernameLower\":1}", .opts = P.partial("usernameLower", "string") },
        .{ .c = "users", .keys = "{\"appId\":1,\"displayNameLower\":1}" },
        .{ .c = "sessions", .keys = "{\"tokenHash\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "sessions", .keys = "{\"expiresAt\":1}", .opts = "{\"expireAfterSeconds\":0}" },
        .{ .c = "chats", .keys = "{\"usernameLower\":1}", .opts = P.partial("usernameLower", "string") },
        .{ .c = "chats", .keys = "{\"pairKey\":1}", .opts = P.partial("pairKey", "string") },
        .{ .c = "chats", .keys = "{\"appId\":1,\"externalId\":1}", .opts = P.partial("externalId", "string") },
        .{ .c = "chats", .keys = "{\"teamId\":1,\"lastMessageAt\":-1}", .opts = "{\"partialFilterExpression\":{\"teamId\":{\"$type\":\"objectId\"}}}" },
        .{ .c = "teams", .keys = "{\"appId\":1,\"externalId\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "teams", .keys = "{\"appId\":1,\"memberIds\":1}" },
        .{ .c = "members", .keys = "{\"chatId\":1,\"userId\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "members", .keys = "{\"userId\":1,\"status\":1,\"lastActivityAt\":-1}" },
        .{ .c = "members", .keys = "{\"chatId\":1,\"status\":1,\"role\":1}" },
        .{ .c = "messages", .keys = "{\"chatId\":1,\"seq\":-1}" },
        .{ .c = "messages", .keys = "{\"chatId\":1,\"senderId\":1,\"clientId\":1}", .opts = P.partial("clientId", "string") },
        .{ .c = "messages", .keys = "{\"scheduledAt\":1}", .opts = "{\"partialFilterExpression\":{\"scheduledAt\":{\"$type\":\"date\"}}}" },
        .{ .c = "messages", .keys = "{\"expiresAt\":1}", .opts = "{\"partialFilterExpression\":{\"expiresAt\":{\"$type\":\"date\"}}}" },
        .{ .c = "messages", .keys = "{\"waitFor\":1}", .opts = "{\"partialFilterExpression\":{\"waitFor\":{\"$type\":\"objectId\"}}}" },
        .{ .c = "messages", .keys = "{\"chatId\":1,\"kind\":1,\"seq\":-1}" },
        .{ .c = "messages", .keys = "{\"search\":\"text\"}", .opts = "{\"default_language\":\"none\",\"name\":\"message_search\"}" },
        .{ .c = "messageTimers", .keys = "{\"expiresAt\":1}" },
        .{ .c = "messageTimers", .keys = "{\"chatId\":1}" },
        .{ .c = "stories", .keys = "{\"viewerIds\":1,\"expiresAt\":1}" },
        .{ .c = "stories", .keys = "{\"userId\":1,\"expiresAt\":1}" },
        .{ .c = "stories", .keys = "{\"userId\":1,\"pinned\":1,\"_id\":-1}" },
        .{ .c = "chatKeys", .keys = "{\"chatId\":1,\"epoch\":1,\"userId\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "chatKeys", .keys = "{\"userId\":1,\"chatId\":1}" },
        .{ .c = "keyRequests", .keys = "{\"chatId\":1,\"userId\":1,\"epoch\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "keyRequests", .keys = "{\"createdAt\":1}", .opts = "{\"expireAfterSeconds\":2592000}" },
        .{ .c = "contacts", .keys = "{\"userId\":1,\"contactId\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "blocks", .keys = "{\"userId\":1,\"blockedId\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "blocks", .keys = "{\"blockedId\":1}" },
        .{ .c = "calls", .keys = "{\"chatId\":1,\"startedAt\":-1}" },
        .{ .c = "calls", .keys = "{\"participants.userId\":1,\"startedAt\":-1}" },
        .{ .c = "invites", .keys = "{\"code\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "invites", .keys = "{\"chatId\":1}" },
        .{ .c = "folders", .keys = "{\"userId\":1,\"order\":1}" },
        .{ .c = "apps", .keys = "{\"ownerId\":1}" },
        .{ .c = "apps", .keys = "{\"publishableKey\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "apps", .keys = "{\"secretKeyHash\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "bots", .keys = "{\"ownerId\":1}" },
        .{ .c = "bots", .keys = "{\"appId\":1}" },
        .{ .c = "pushSubs", .keys = "{\"endpoint\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "pushSubs", .keys = "{\"userId\":1}" },
        .{ .c = "webhookDeliveries", .keys = "{\"status\":1,\"nextAttemptAt\":1}" },
        .{ .c = "webhookDeliveries", .keys = "{\"appId\":1,\"createdAt\":-1}" },
        .{ .c = "webhookDeliveries", .keys = "{\"createdAt\":1}", .opts = "{\"expireAfterSeconds\":1209600}" },
        .{ .c = "media", .keys = "{\"ownerId\":1,\"createdAt\":-1}" },
        .{ .c = "keyEscrow", .keys = "{\"userId\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "mediaChunks", .keys = "{\"mediaId\":1,\"n\":1}", .opts = "{\"unique\":true}" },
        .{ .c = "media", .keys = "{\"status\":1,\"createdAt\":1}" },
    };
    for (specs) |s| {
        const keys = val.parseJson(arena, s.keys) catch unreachable;
        const opts = val.parseJson(arena, s.opts) catch unreachable;
        const coll: A.db.Coll = .{ .client = A.app.mongo, .db = A.app.config.db_name, .name = s.c };
        coll.createIndex(arena, keys, opts) catch |e| std.log.warn("Index {s} {s}: {t} {s}", .{ s.c, s.keys, e, A.app.mongo.lastError() });
    }
}

// ---- Requests ------------------------------------------------------------------------------

const CSP_BASE = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; media-src 'self' blob: data:; font-src 'self' data:; connect-src 'self' {s} ws: wss:; worker-src 'self' blob:; manifest-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'";

fn csp(q: *Req, frame_ancestors: []const u8) ![]const u8 {
    return cspFor(q, frame_ancestors, "");
}

/// The policy for a page: the zui web app compiles WebAssembly and starts from small inline
/// scripts, which are allowed by their SHA-256 (Reseal-js's pages have none, so they are unchanged).
fn cspFor(q: *Req, frame_ancestors: []const u8, html: []const u8) ![]const u8 {
    const pub_url = A.app.config.public_url;
    // config.publicUrl.replace(/^http/, 'ws')
    const ws_origin = if (std.mem.startsWith(u8, pub_url, "http")) try q.r.fmt("ws{s}", .{pub_url[4..]}) else pub_url;
    var scripts: std.ArrayList(u8) = .empty;
    try scripts.appendSlice(q.r.a, "'self' 'wasm-unsafe-eval'");
    var rest = html;
    while (std.mem.indexOf(u8, rest, "<script")) |open| {
        const tag_end = std.mem.indexOfScalarPos(u8, rest, open, '>') orelse break;
        const close = std.mem.indexOfPos(u8, rest, tag_end, "</script>") orelse break;
        if (std.mem.indexOf(u8, rest[open..tag_end], " src=") == null) {
            // Browsers hash the script as parsed, where CRLF and lone CR are LF (a page checked
            // out on Windows has CRLF).
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            const body = rest[tag_end + 1 .. close];
            var i: usize = 0;
            while (i < body.len) : (i += 1) {
                if (body[i] != '\r') {
                    h.update(body[i .. i + 1]);
                    continue;
                }
                h.update("\n");
                if (i + 1 < body.len and body[i + 1] == '\n') i += 1;
            }
            var digest: [32]u8 = undefined;
            h.final(&digest);
            var b64: [44]u8 = undefined;
            try scripts.print(q.r.a, " 'sha256-{s}'", .{std.base64.standard.Encoder.encode(&b64, &digest)});
        }
        rest = rest[close + 9 ..];
    }
    const base = try std.mem.replaceOwned(u8, q.r.a, CSP_BASE, "script-src 'self'", try q.r.fmt("script-src {s}", .{scripts.items}));
    const with_ws = try std.mem.replaceOwned(u8, q.r.a, base, "{s}", ws_origin);
    // Wufour: the app logos in the account menu (zui.account).
    const with_wufour = try std.mem.replaceOwned(u8, q.r.a, with_ws, "img-src 'self'", try q.r.fmt("img-src 'self' {s}", .{std.mem.trimEnd(u8, A.app.config.auth_host, "/")}));
    return q.r.fmt("{s}; frame-ancestors {s}", .{ with_wufour, frame_ancestors });
}

fn handle(ctx: *http.Context) anyerror!void {
    const path = ctx.path;
    var q: Req = .{
        .ctx = ctx,
        .r = .{ .a = ctx.arena },
        .method = ctx.method,
        .path = path,
        .start_ms = A.nowMs(),
    };
    try q.setHeader("x-content-type-options", "nosniff");
    try q.setHeader("referrer-policy", "strict-origin-when-cross-origin");
    try q.setHeader("cross-origin-opener-policy", "same-origin-allow-popups");
    try q.setHeader("permissions-policy", "camera=(self), microphone=(self), display-capture=(self), geolocation=(self), fullscreen=(self)");
    if (q.secure()) try q.setHeader("strict-transport-security", "max-age=31536000; includeSubDomains");

    if (ctx.wantsWebSocket()) return rt.upgrade(&q);

    dispatch(&q) catch |err| try web.sendError(&q, err);
    if (!ctx.responded) try web.cannot(&q);
    logRequest(&q);
}

fn logRequest(q: *Req) void {
    if (!A.app.config.log_requests) return;
    // Chunk uploads are noisy.
    if (q.method == .PUT and std.mem.startsWith(u8, q.path, "/api/media")) return;
    std.log.info("{s} {s} {d} {d}ms", .{ @tagName(q.method), q.path, q.status, A.nowMs() - q.start_ms });
}

fn dispatch(q: *Req) !void {
    // The sign-in round trip with Wufour.
    if (q.is(.GET, "/login")) return auth.login(q);
    if (q.is(.GET, "/auth/callback")) return auth.callback(q);
    if (q.is(null, "/logout")) return auth.logout(q);

    if (q.startsWith("/api/v1")) {
        try q.parseJsonBody();
        return r_v1.handle(q);
    }
    if (q.startsWith("/api")) {
        try q.parseJsonBody();
        if (q.is(.GET, "/api/health")) {
            const s = rt.stats();
            return q.json(.{ .ok = true, .realtime = .{ .users = s.users, .connections = s.connections, .chats = s.chats } });
        }
        // Routers with public endpoints first; the others need a signed-in user for everything.
        if (try r_internal.handle(q)) return;
        if (try r_embed.handle(q)) return;
        if (try r_media.handleApi(q)) return;
        if (q.startsWith("/api/stories")) {
            try auth.requireUser(q);
            if (try r_stories.handle(q)) return;
        }
        try auth.requireUser(q);
        if (try r_account.handle(q)) return;
        if (try r_chats.handle(q)) return;
        if (try r_platform.handle(q)) return;
        return q.jsonStatus(404, .{ .@"error" = .{ .message = "Unknown API endpoint", .code = "not_found" } });
    }
    if (q.is(.GET, "/m/:id")) return r_media.signedFile(q);

    // Pages. The widget may be framed only by the origins its app allows.
    if (q.is(.GET, "/embed")) {
        const app_doc = try apps.appByPublishableKey(&q.r, q.query("pk") orelse "");
        var ancestors: []const u8 = "'self'";
        if (app_doc) |d| if (d.get("allowedOrigins").len() > 0) {
            var parts: std.ArrayList([]const u8) = .empty;
            try parts.append(q.r.a, "'self'");
            for (d.get("allowedOrigins").items()) |o| try parts.append(q.r.a, try q.r.str(o));
            ancestors = try std.mem.join(q.r.a, " ", parts.items);
        };
        return page(q, "embed.html", ancestors);
    }
    if (q.is(.GET, "/developers")) return page(q, "developers.html", "'none'");
    // The small window the widget opens to ask for notification permission. It reads what it
    // needs from window.opener (the widget's frame inside another site); with the site-wide COOP
    // the browser would cut that link, so this one page opts out.
    if (q.is(.GET, "/push")) {
        try q.setHeader("cross-origin-opener-policy", "unsafe-none");
        return page(q, "push.html", "'none'");
    }
    if (q.is(.GET, "/sw.js")) {
        try q.setHeader("service-worker-allowed", "/");
        try q.setHeader("cache-control", "no-cache");
        const data = readPublic(q, "sw.js") catch return web.cannot(q);
        return q.send(200, "text/javascript", data);
    }
    if (q.is(.GET, "/index.html") or q.is(.GET, "/coming-soon.html")) return appPage(q);
    if (q.method == .GET or q.method == .HEAD) {
        if (try staticFile(q)) return;
        // Everything else is the single-page app (/, /c/<chat>, /join/<code>, /@username, …).
        // Paths that look like files are never the app page: missing assets get a real 404.
        if (spaPath(q.path)) return appPage(q);
    }
    return web.cannot(q);
}

/// /^\/(?!api\/|m\/|ws$)(?!.*\.[a-z0-9]{1,8}$).*/i
fn spaPath(p: []const u8) bool {
    if (p.len == 0 or p[0] != '/') return false;
    const rest = p[1..];
    if (std.ascii.startsWithIgnoreCase(rest, "api/") or std.ascii.startsWithIgnoreCase(rest, "m/") or std.ascii.eqlIgnoreCase(rest, "ws")) return false;
    if (std.mem.lastIndexOfScalar(u8, p, '.')) |dot| {
        const ext = p[dot + 1 ..];
        if (ext.len >= 1 and ext.len <= 8) {
            var ok = true;
            for (ext) |c| if (!std.ascii.isAlphanumeric(c)) {
                ok = false;
            };
            if (ok) return false;
        }
    }
    return true;
}

fn readPublic(q: *Req, rel: []const u8) ![]const u8 {
    const full = try std.fs.path.join(q.r.a, &.{ A.app.config.public_dir, rel });
    return std.Io.Dir.cwd().readFileAlloc(A.app.io, full, q.r.a, .limited(64 * 1024 * 1024));
}

fn page(q: *Req, file: []const u8, frame_ancestors: []const u8) !void {
    const data = readPublic(q, file) catch return web.cannot(q);
    try q.setHeader("content-security-policy", try cspFor(q, frame_ancestors, data));
    try q.setHeader("cache-control", "no-cache");
    if (std.mem.eql(u8, frame_ancestors, "'none'")) try q.setHeader("x-frame-options", "DENY");
    return q.send(200, "text/html; charset=utf-8", data);
}

/// Before the public launch the app is only for admins and early-access users; everyone else
/// sees "Coming soon". Embedded chat is not affected.
fn appPage(q: *Req) !void {
    if (platform.get().public_app) return page(q, "index.html", "'none'");
    const t = auth.tokenFromRequest(q);
    const au = if (t.via == .cookie) (auth.resolveToken(&q.r, t.token) catch null) else null;
    const ok = try platform.canOpenApp(q.r.a, if (au) |x| x.user else null);
    return page(q, if (ok) "index.html" else "coming-soon.html", "'none'");
}

fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const extra = [_]struct { []const u8, []const u8 }{
        .{ ".mp3", "audio/mpeg" },  .{ ".ogg", "audio/ogg" },       .{ ".wav", "audio/wav" }, .{ ".mp4", "video/mp4" },
        .{ ".webm", "video/webm" }, .{ ".woff", "font/woff" },      .{ ".ttf", "font/ttf" },  .{ ".map", "application/json" },
        .{ ".avif", "image/avif" }, .{ ".pdf", "application/pdf" },
    };
    for (extra) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
    return http.contentType(path);
}

/// express.static(public, { index: false }): files only; scripts and styles revalidate.
fn staticFile(q: *Req) !bool {
    const a = q.r.a;
    const rel_raw = web.decodeComponent(a, q.path) catch return false;
    var parts = std.mem.splitAny(u8, rel_raw, "/\\");
    while (parts.next()) |p| if (std.mem.eql(u8, p, "..") or std.mem.indexOfScalar(u8, p, 0) != null) return false;
    const rel = std.mem.trimStart(u8, rel_raw, "/");
    if (rel.len == 0) return false;
    const full = try std.fs.path.join(a, &.{ A.app.config.public_dir, rel });
    const dir = std.Io.Dir.cwd();
    const stat = dir.statFile(A.app.io, full, .{}) catch return false;
    if (stat.kind == .directory) {
        if (std.mem.endsWith(u8, q.path, "/")) return false;
        // serve-static sends directories to their trailing-slash form.
        try q.setHeader("location", try q.r.fmt("{s}/", .{q.path}));
        try q.setHeader("content-security-policy", "default-src 'none'");
        try q.send(301, "text/html; charset=utf-8", try q.r.fmt("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Redirecting</title>\n</head>\n<body>\n<pre>Redirecting to {s}/</pre>\n</body>\n</html>\n", .{try web.htmlEscape(a, q.path)}));
        return true;
    }
    if (stat.kind != .file) return false;
    const etag = try q.r.fmt("W/\"{x}-{x}\"", .{ stat.size, @divFloor(stat.mtime.toNanoseconds(), std.time.ns_per_ms) });
    const revalidate = for ([_][]const u8{ ".js", ".css", ".html", ".json", ".webmanifest" }) |e| {
        if (std.mem.endsWith(u8, rel, e)) break true;
    } else false;
    // Font files carry their version in the name, so they may be kept for a year.
    const font = std.mem.endsWith(u8, rel, ".woff2");
    try q.setHeader("cache-control", if (revalidate) "no-cache" else if (font) "public, max-age=31536000, immutable" else "public, max-age=86400");
    if (std.mem.endsWith(u8, rel, ".html")) try q.setHeader("content-security-policy", try csp(q, "'none'"));
    try q.setHeader("etag", etag);
    try q.setHeader("accept-ranges", "bytes");
    if (q.header("if-none-match")) |inm| if (std.mem.eql(u8, inm, etag)) {
        try q.end(304);
        return true;
    };
    const data = dir.readFileAlloc(A.app.io, full, a, .limited(256 * 1024 * 1024)) catch return false;
    try q.send(200, contentType(rel), data);
    return true;
}

test {
    _ = val;
    _ = @import("validate.zig");
    _ = @import("store.zig");
    _ = A;
}
