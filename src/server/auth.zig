//! Authentication (src/auth.js and the wufour-auth library it used).
//!
//! Two kinds of people use Reseal:
//!  1. Reseal accounts, signed in with Wufour. The browser carries the Wufour token in the
//!     wufour_token cookie; the native apps send it as `Authorization: Bearer <token>`. Either
//!     way it is checked with Wufour (/api/auth/verify) and the answer cached briefly.
//!  2. Users of apps that embed Reseal: the app's backend asks Reseal for a user token (rsl_ut_…)
//!     that the widget sends as a Bearer token.

const std = @import("std");
const Io = std.Io;
const A = @import("app.zig");
const web = @import("web.zig");
const fetch = @import("lib/fetch.zig");
const v = @import("validate.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;
const Req = web.Req;

pub fn defaultPrivacy(a: std.mem.Allocator) !Val {
    return val.from(a, .{ .lastSeen = "everyone", .avatar = "everyone", .calls = "everyone", .groups = "everyone", .forwards = "everyone", .readReceipts = true });
}

// ---- Wufour token checks, cached ----------------------------------------------------------

const VERIFY_CACHE_MS = 60_000;

const CacheEntry = struct {
    until: i64,
    /// The verified user as JSON (owned by gpa), or null for a refused token.
    user_json: ?[]const u8,
};

var cache_lock: Io.Mutex = .init;
var cache: std.StringHashMapUnmanaged(CacheEntry) = .empty;
var cache_swept: i64 = 0;

/// Wufour's backend address: wufour-auth calls 127.0.0.1 instead of localhost.
pub fn backendHost(a: std.mem.Allocator) ![]const u8 {
    return std.mem.replaceOwned(u8, a, A.app.config.auth_host, "localhost", "127.0.0.1");
}

/// POST /api/auth/verify; the Wufour user, or null when the token is not valid (or Wufour
/// cannot be reached).
pub fn wufourVerifyUncached(a: std.mem.Allocator, token: []const u8) ?Val {
    const body = val.stringify(a, val.from(a, .{ .token = token }) catch return null) catch return null;
    const url = std.fmt.allocPrint(a, "{s}/api/auth/verify", .{backendHost(a) catch return null}) catch return null;
    const res = fetch.fetch(a, url, .{ .method = .POST, .body = body, .content_type = "application/json", .timeout_ms = 15_000 }) catch return null;
    const data = val.parseJson(a, res.body) catch return null;
    if (!data.get("success").truthy()) return null;
    const u = data.get("user");
    return if (u.isNullish()) null else u;
}

fn verifyWufourToken(a: std.mem.Allocator, token: []const u8) ?Val {
    const key = A.sha256Hex(a, token) catch return null;
    const io = A.app.io;
    {
        cache_lock.lockUncancelable(io);
        defer cache_lock.unlock(io);
        if (cache.get(key)) |hit| if (hit.until > A.nowMs()) {
            const j = hit.user_json orelse return null;
            return val.parseJson(a, j) catch null;
        };
    }
    const user = wufourVerifyUncached(a, token);
    const gpa = A.app.gpa;
    cache_lock.lockUncancelable(io);
    defer cache_lock.unlock(io);
    const t = A.nowMs();
    if (t - cache_swept > 120_000) {
        cache_swept = t;
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(gpa);
        var it = cache.iterator();
        while (it.next()) |e| if (e.value_ptr.until < t) stale.append(gpa, e.key_ptr.*) catch {};
        for (stale.items) |k| if (cache.fetchRemove(k)) |kv| {
            if (kv.value.user_json) |j| gpa.free(j);
            gpa.free(kv.key);
        };
    }
    // Failures are remembered for a shorter time than successes.
    const json: ?[]const u8 = if (user) |u| (gpa.dupe(u8, val.stringify(a, u) catch return user) catch return user) else null;
    const gop = cache.getOrPut(gpa, key) catch return user;
    if (gop.found_existing) {
        if (gop.value_ptr.user_json) |j| gpa.free(j);
    } else {
        gop.key_ptr.* = gpa.dupe(u8, key) catch {
            _ = cache.remove(key);
            if (json) |j| gpa.free(j);
            return user;
        };
    }
    gop.value_ptr.* = .{ .until = t + (if (user != null) @as(i64, VERIFY_CACHE_MS) else 5_000), .user_json = json };
    return user;
}

pub fn forgetToken(a: std.mem.Allocator, token: ?[]const u8) void {
    const t = token orelse return;
    const key = A.sha256Hex(a, t) catch return;
    cache_lock.lockUncancelable(A.app.io);
    defer cache_lock.unlock(A.app.io);
    if (cache.fetchRemove(key)) |kv| {
        if (kv.value.user_json) |j| A.app.gpa.free(j);
        A.app.gpa.free(kv.key);
    }
}

// ---- Profiles -----------------------------------------------------------------------------

/// Find or create the Reseal profile for a verified Wufour user.
pub fn upsertWufourUser(r: *Rq, wu: Val) !Val {
    const a = r.a;
    const col = &A.app.col;
    const wufour_id = try val.str(a, wu.get("userId"));
    const now = A.now();
    if (try col.users.findOne(a, .{ .wufourId = wufour_id }, .{})) |existing| {
        const role = wu.get("role");
        if (role != .undef) {
            const is_admin = role == .str and std.mem.eql(u8, role.str, "admin");
            if (is_admin != existing.get("isAdmin").truthy()) {
                _ = try col.users.updateOne(a, .{ ._id = existing.get("_id") }, .{ .@"$set" = .{ .isAdmin = is_admin } }, .{});
                try existing.put(a, "isAdmin", .{ .bool = is_admin });
            }
        }
        return existing;
    }
    const uname = wu.get("username");
    const display = v.sliceUtf16(if (uname.truthy()) try val.str(a, uname) else "New user", 64);
    const doc = try val.from(a, .{
        .kind = "wufour",
        .appId = Val.null,
        .wufourId = wufour_id,
        .displayName = display,
        .displayNameLower = try std.ascii.allocLowerString(a, display),
        .bio = "",
        .avatar = Val.null,
        .privacy = try defaultPrivacy(a),
        .settings = try Val.object(a),
        .isAdmin = wu.get("role") == .str and std.mem.eql(u8, wu.get("role").str, "admin"),
        .createdAt = now,
        .lastSeenAt = now,
    });
    // Offer the Wufour username as the Reseal @username when it is valid and free.
    if (uname.asStr()) |un| if (v.isUsername(un)) {
        const lower = try std.ascii.allocLowerString(a, un);
        if (try col.users.findOne(a, .{ .usernameLower = lower }, .{ .projection = .{ ._id = 1 } }) == null) {
            try doc.set(a, "username", un);
            try doc.set(a, "usernameLower", lower);
        }
    };
    _ = col.users.insertOne(a, doc) catch |e| switch (e) {
        error.DuplicateKey => {
            // Two requests raced; the other one created the profile.
            if (try col.users.findOne(a, .{ .wufourId = wufour_id }, .{})) |again| return again;
            // The username was taken in the meantime: create without it.
            doc.del("username");
            doc.del("usernameLower");
            doc.del("_id");
            _ = try col.users.insertOne(a, doc);
            try createSavedMessages(r, doc.get("_id"));
            return doc;
        },
        else => return e,
    };
    try createSavedMessages(r, doc.get("_id"));
    return doc;
}

/// Every user gets a private "Saved Messages" chat.
pub fn createSavedMessages(r: *Rq, user_id: Val) !void {
    const a = r.a;
    const col = &A.app.col;
    const now = A.now();
    const chat = try val.from(a, .{
        .type = "saved",
        .appId = Val.null,
        .encrypted = true,
        .title = "Saved Messages",
        .pairKey = try std.fmt.allocPrint(a, "saved:{s}", .{try val.str(a, user_id)}),
        .createdBy = user_id,
        .createdAt = now,
        .seq = 0,
        .keyEpoch = 0,
        .memberCount = 1,
        .lastMessageAt = now,
    });
    _ = col.chats.insertOne(a, chat) catch |e| switch (e) {
        error.DuplicateKey => return,
        else => return e,
    };
    _ = try col.members.insertOne(a, try val.from(a, .{
        .chatId = chat.get("_id"),
        .userId = user_id,
        .chatType = "saved",
        .role = "owner",
        .status = "active",
        .joinedAt = now,
        .lastReadSeq = 0,
        .unread = 0,
        .lastActivityAt = now,
        .joinedSeq = 0,
    }));
}

/// Issue a Reseal user token (for app users and guests).
pub fn issueUserToken(r: *Rq, user: Val, ttl_seconds: i64, app_id: Val, label: []const u8) !struct { token: []const u8, expiresAt: Val } {
    const a = r.a;
    const token = try A.randomToken(a, "rsl_ut_", 32);
    const now = A.nowMs();
    _ = try A.app.col.sessions.insertOne(a, try val.from(a, .{
        .tokenHash = try A.sha256Hex(a, token),
        .userId = user.get("_id"),
        .appId = app_id,
        .label = label,
        .createdAt = Val{ .date = now },
        .expiresAt = Val{ .date = now + ttl_seconds * 1000 },
    }));
    return .{ .token = token, .expiresAt = .{ .date = now + ttl_seconds * 1000 } };
}

/// A bearer or cookie token as { user, kind, token }; null when it is not valid.
pub fn resolveToken(r: *Rq, token_: ?[]const u8) !?web.Auth {
    const a = r.a;
    const token = token_ orelse return null;
    if (token.len == 0 or token.len > 4096) return null;
    const col = &A.app.col;
    if (std.mem.startsWith(u8, token, "rsl_ut_")) {
        const session = (try col.sessions.findOne(a, .{ .tokenHash = try A.sha256Hex(a, token) }, .{})) orelse return null;
        const exp = session.get("expiresAt");
        if (exp == .date and exp.date < A.nowMs()) return null;
        const user = (try col.users.findOne(a, .{ ._id = session.get("userId"), .deletedAt = .{ .@"$exists" = false } }, .{})) orelse return null;
        if (user.get("appId").truthy()) {
            const app_doc = (try col.apps.findOne(a, .{ ._id = user.get("appId") }, .{ .projection = .{ .disabled = 1 } })) orelse return null;
            if (app_doc.get("disabled").truthy()) return null;
        }
        return .{ .user = user, .kind = "session", .token = token, .session = session };
    }
    const wu = verifyWufourToken(a, token) orelse return null;
    const user = try upsertWufourUser(r, wu);
    if (user.get("deletedAt").truthy()) return null;
    return .{ .user = user, .kind = "wufour", .token = token };
}

pub const Via = enum { bearer, cookie, none };

pub fn tokenFromRequest(q: *Req) struct { token: ?[]const u8, via: Via } {
    const h = q.header("authorization") orelse "";
    if (std.mem.startsWith(u8, h, "Bearer ")) return .{ .token = std.mem.trim(u8, h[7..], " \t"), .via = .bearer };
    const t = q.cookie("wufour_token") orelse q.cookie("auth_token");
    return if (t) |x| .{ .token = x, .via = .cookie } else .{ .token = null, .via = .none };
}

/// requireUser: a signed-in user, or 401. Cookie-authenticated writes must carry
/// X-Reseal-Client so other sites cannot forge them (CSRF).
pub fn requireUser(q: *Req) !void {
    if (q.auth != null) return;
    const t = tokenFromRequest(q);
    if (t.via == .cookie and q.method != .GET and q.method != .HEAD and q.method != .OPTIONS and q.header("x-reseal-client") == null) {
        return q.r.fail(403, "Missing X-Reseal-Client header", "csrf");
    }
    q.auth = (try resolveToken(&q.r, t.token)) orelse return q.r.fail(401, "Please sign in", "unauthorized");
}

/// Only relative paths as the post-sign-in destination (no open redirects).
pub fn safeNext(value: ?[]const u8) []const u8 {
    const x = value orelse return "/";
    if (std.mem.startsWith(u8, x, "/") and !std.mem.startsWith(u8, x, "//") and !std.mem.startsWith(u8, x, "/\\")) return x;
    return "/";
}

// ---- The sign-in round trip with Wufour (wufour-auth's routes) ----------------------------

fn clearAuthCookies(q: *Req) !void {
    for ([_][]const u8{ "auth_token", "wufour_token", "wufour_session" }) |name| {
        try q.addHeader("set-cookie", try std.fmt.allocPrint(q.r.a, "{s}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax", .{name}));
    }
}

fn redirectToLogin(q: *Req) !void {
    const a = q.r.a;
    const original = if (q.ctx.query.len > 0) try std.fmt.allocPrint(a, "{s}?{s}", .{ q.path, q.ctx.query }) else q.path;
    const back = try std.fmt.allocPrint(a, "{s}://{s}/auth/callback?next={s}", .{ q.protocol(), q.header("host") orelse "localhost", try web.encodeComponent(a, original) });
    const sso = try std.fmt.allocPrint(a, "{s}/auth?returnTo={s}", .{ A.app.config.auth_host, try web.encodeComponent(a, back) });
    return q.redirect(sso);
}

/// GET /login: to Wufour when there is no valid cookie, else to `next`.
pub fn login(q: *Req) !void {
    const token = q.cookie("wufour_token") orelse q.cookie("auth_token") orelse return redirectToLogin(q);
    if (wufourVerifyUncached(q.r.a, token) == null) {
        try clearAuthCookies(q);
        return redirectToLogin(q);
    }
    return q.redirect(safeNext(q.query("next")));
}

fn expires(a: std.mem.Allocator, ms: i64) ![]const u8 {
    // Express writes cookie expiry as an HTTP date.
    const days = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        days[@intCast(ed.day % 7)], md.day_index + 1, months[md.month.numeric() - 1], yd.year,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

/// GET /auth/callback?token=…&next=…: Wufour sends the browser back here.
pub fn callback(q: *Req) !void {
    const a = q.r.a;
    const token = q.query("token") orelse return q.redirect("/");
    const destination = safeNext(q.query("next"));
    const user = wufourVerifyUncached(a, token) orelse {
        try clearAuthCookies(q);
        return q.redirect("/?auth=failed");
    };
    _ = upsertWufourUser(&q.r, user) catch |e| std.log.err("Custom Auth Hook Failed: {t}", .{e});
    const enc = try web.encodeComponent(a, token);
    const exp = try expires(a, A.nowMs() + 86400_000);
    for ([_][]const u8{ "auth_token", "wufour_token" }) |name| {
        try q.addHeader("set-cookie", try std.fmt.allocPrint(a, "{s}={s}; Max-Age=86400; Path=/; Expires={s}; HttpOnly; SameSite=Lax", .{ name, enc, exp }));
    }
    return q.redirect(destination);
}

/// ALL /logout
pub fn logout(q: *Req) !void {
    const a = q.r.a;
    const t = tokenFromRequest(q);
    forgetToken(a, t.token);
    const token = q.cookie("auth_token") orelse q.cookie("wufour_token");
    if (token) |tok| A.spawn(tellWufourLogout, .{ A.app.gpa.dupe(u8, tok) catch return });
    try clearAuthCookies(q);
    const xhr = if (q.header("x-requested-with")) |x| std.ascii.eqlIgnoreCase(x, "xmlhttprequest") else false;
    const accept = q.header("accept") orelse "";
    if (xhr or std.mem.indexOf(u8, accept, "json") != null) return q.json(.{ .ok = true });
    return q.redirect("/");
}

fn tellWufourLogout(token: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(A.app.gpa);
    defer arena.deinit();
    defer A.app.gpa.free(token);
    const a = arena.allocator();
    const body = val.stringify(a, val.from(a, .{ .token = token }) catch return) catch return;
    const url = std.fmt.allocPrint(a, "{s}/api/auth/logout", .{backendHost(a) catch return}) catch return;
    _ = fetch.fetch(a, url, .{ .method = .POST, .body = body, .content_type = "application/json" }) catch |e| std.log.warn("Logout API Warning: {t}", .{e});
}
