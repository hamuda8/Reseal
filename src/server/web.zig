//! The request layer: what Express gave Reseal-js on top of zig-core's HTTP server. Paths match
//! the way Express routes do (case-insensitive, trailing slash allowed, params decoded), bodies
//! are parsed like express.json / express.raw, and errors answer with Reseal's error shape
//! `{ error: { message, code } }`.

const std = @import("std");
const http = @import("http");
const A = @import("app.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

pub const Param = struct { name: []const u8, value: []const u8 };

pub const Auth = struct {
    user: Val,
    /// "session" (rsl_ut_ tokens) or "wufour".
    kind: []const u8,
    token: []const u8,
    session: Val = .undef,
};

pub const Req = struct {
    ctx: *http.Context,
    r: Rq,
    method: http.Method,
    path: []const u8,
    params: [8]Param = undefined,
    nparams: usize = 0,
    /// The parsed JSON body; undefined when the request had none (as req.body in Express 5).
    body: Val = .undef,
    raw: ?[]const u8 = null,
    body_read: bool = false,
    auth: ?Auth = null,
    /// The app behind a secret key (/api/v1).
    app_: Val = .undef,
    status: u16 = 200,
    start_ms: i64,

    pub fn user(q: *Req) Val {
        return if (q.auth) |au| au.user else .undef;
    }

    pub fn param(q: *const Req, name: []const u8) []const u8 {
        for (q.params[0..q.nparams]) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return "";
    }

    pub fn pv(q: *const Req, name: []const u8) Val {
        return .{ .str = q.param(name) };
    }

    /// A query parameter (first value), percent-decoded.
    pub fn query(q: *Req, name: []const u8) ?[]const u8 {
        return q.ctx.queryParam(name);
    }

    /// The query parameter as a Val (undefined when absent), like `req.query[name]`.
    pub fn qv(q: *Req, name: []const u8) Val {
        return if (q.ctx.queryParam(name)) |v| .{ .str = v } else .undef;
    }

    pub fn header(q: *const Req, name: []const u8) ?[]const u8 {
        return q.ctx.header(name);
    }

    /// `req.body?.[key]`
    pub fn b(q: *const Req, key: []const u8) Val {
        return q.body.get(key);
    }

    /// `req.body || {}`
    pub fn bodyObj(q: *Req) !Val {
        if (q.body == .undef or q.body == .null) return Val.object(q.r.a);
        return q.body;
    }

    pub fn setHeader(q: *Req, name: []const u8, value: []const u8) !void {
        try q.ctx.setHeader(name, value);
    }

    pub fn addHeader(q: *Req, name: []const u8, value: []const u8) !void {
        try q.ctx.addHeader(name, value);
    }

    /// `res.json(value)` with status 200.
    pub fn json(q: *Req, value: anytype) !void {
        return q.jsonStatus(200, value);
    }

    pub fn jsonStatus(q: *Req, status: u16, value: anytype) !void {
        const v = try val.from(q.r.a, value);
        return q.send(status, "application/json; charset=utf-8", try val.stringify(q.r.a, v));
    }

    pub fn send(q: *Req, status: u16, content_type: []const u8, data: []const u8) !void {
        q.status = status;
        try q.ctx.send(@fromBackingInt(@intCast(status)), content_type, data);
    }

    pub fn redirect(q: *Req, location: []const u8) !void {
        try q.ctx.setHeader("location", location);
        // Express's res.redirect body for non-HTML clients.
        return q.send(302, "text/plain; charset=utf-8", try std.fmt.allocPrint(q.r.a, "Found. Redirecting to {s}", .{location}));
    }

    /// `res.status(status).end()`: no body, no content type.
    pub fn end(q: *Req, status: u16) !void {
        q.status = status;
        return q.ctx.end(@fromBackingInt(@intCast(status)));
    }

    /// Path match (Express style). Sets the params on success.
    pub fn is(q: *Req, method: ?http.Method, pattern: []const u8) bool {
        if (method) |m| {
            if (m == .GET) {
                if (q.method != .GET and q.method != .HEAD) return false;
            } else if (m != q.method) return false;
        }
        return q.matches(pattern);
    }

    pub fn matches(q: *Req, pattern: []const u8) bool {
        var pi = std.mem.splitScalar(u8, std.mem.trim(u8, pattern, "/"), '/');
        var p = q.path;
        if (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
        var si = std.mem.splitScalar(u8, std.mem.trimStart(u8, p, "/"), '/');
        var n: usize = 0;
        while (pi.next()) |seg| {
            const s = si.next() orelse return false;
            if (seg.len > 0 and seg[0] == ':') {
                if (s.len == 0) return false;
                const decoded = decodeComponent(q.r.a, s) catch return false;
                if (n < q.params.len) {
                    q.params[n] = .{ .name = seg[1..], .value = decoded };
                    n += 1;
                }
            } else if (!std.ascii.eqlIgnoreCase(seg, s)) return false;
        }
        if (si.next() != null) return false;
        q.nparams = n;
        return true;
    }

    pub fn startsWith(q: *const Req, prefix: []const u8) bool {
        if (q.path.len < prefix.len) return false;
        if (!std.ascii.eqlIgnoreCase(q.path[0..prefix.len], prefix)) return false;
        return q.path.len == prefix.len or q.path[prefix.len] == '/';
    }

    /// The client address (Express req.ip, with `trust proxy` 1 behind a tunnel).
    pub fn ip(q: *Req) []const u8 {
        if (A.app.config.trust_proxy) {
            if (q.header("x-forwarded-for")) |v| {
                var it = std.mem.splitBackwardsScalar(u8, v, ',');
                if (it.next()) |last| return std.mem.trim(u8, last, " ");
            }
        }
        return http.formatIp(q.r.a, q.ctx.stream.socket.address) catch "";
    }

    pub fn secure(q: *const Req) bool {
        if (!A.app.config.trust_proxy) return false;
        const proto = q.header("x-forwarded-proto") orelse return false;
        const first = std.mem.trim(u8, proto[0 .. std.mem.indexOfScalar(u8, proto, ',') orelse proto.len], " ");
        return std.ascii.eqlIgnoreCase(first, "https");
    }

    pub fn protocol(q: *const Req) []const u8 {
        return if (q.secure()) "https" else "http";
    }

    /// The whole body, up to `limit` bytes (413 beyond it). zig-core reads bodies on any
    /// method (Express does; Reseal's clients send JSON with DELETE) and reads away or closes
    /// on an oversized one, so the client sees the 413.
    pub fn rawBody(q: *Req, limit: usize) ![]const u8 {
        if (q.raw) |x| return x;
        if (q.ctx.raw_body == null and q.ctx.body_error == null) q.ctx.max_body = limit;
        const data = q.ctx.body() catch |e| switch (e) {
            error.PayloadTooLarge => return q.r.fail(413, "That request is too large", "too_large"),
            else => return q.r.fail(400, "The request body could not be read", "bad_request"),
        };
        // Read earlier under a larger limit (a body on GET or DELETE is read before routing).
        if (data.len > limit) return q.r.fail(413, "That request is too large", "too_large");
        q.raw = data;
        return data;
    }

    pub fn hasBody(q: *const Req) bool {
        const req = q.ctx.request;
        return req.head.transfer_encoding != .none or (req.head.content_length orelse 0) > 0 or q.header("content-length") != null;
    }

    pub fn contentTypeIs(q: *const Req, comptime kind: enum { json, any }) bool {
        const ct = q.header("content-type") orelse return false;
        const mime = std.mem.trim(u8, ct[0 .. std.mem.indexOfScalar(u8, ct, ';') orelse ct.len], " ");
        return switch (kind) {
            .json => std.ascii.eqlIgnoreCase(mime, "application/json") or (std.ascii.startsWithIgnoreCase(mime, "application/") and std.ascii.endsWithIgnoreCase(mime, "+json")),
            .any => true,
        };
    }

    /// express.json({ limit: '512kb' }): parses JSON bodies only; anything else leaves req.body
    /// undefined.
    pub fn parseJsonBody(q: *Req) !void {
        if (q.body_read) return;
        q.body_read = true;
        if (!q.contentTypeIs(.json) or !q.hasBody()) return;
        const data = try q.rawBody(512 * 1024);
        const t = std.mem.trim(u8, data, " \t\r\n");
        if (t.len == 0) {
            q.body = try Val.object(q.r.a);
            return;
        }
        // Strict mode: only objects and arrays.
        if (t[0] != '{' and t[0] != '[') return q.r.fail(400, "The request body is not valid JSON", "bad_json");
        q.body = val.parseJson(q.r.a, t) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return q.r.fail(400, "The request body is not valid JSON", "bad_json"),
        };
    }

    /// A cookie as wufour-auth's parseCookies reads it (value percent-decoded).
    pub fn cookie(q: *Req, name: []const u8) ?[]const u8 {
        return q.ctx.cookie(name);
    }
};

/// decodeURIComponent (no `+` → space).
pub const decodeComponent = http.decodeComponent;

/// encodeURIComponent
pub fn encodeComponent(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.!~*'()", c) != null) try out.append(a, c) else try out.print(a, "%{X:0>2}", .{c});
    }
    return out.items;
}

/// Express's default 404 page for anything nothing handled.
pub fn cannot(q: *Req) !void {
    const body = try std.fmt.allocPrint(q.r.a, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Error</title>\n</head>\n<body>\n<pre>Cannot {s} {s}</pre>\n</body>\n</html>\n", .{ @tagName(q.method), try htmlEscape(q.r.a, q.path) });
    try q.setHeader("content-security-policy", "default-src 'none'");
    return q.send(404, "text/html; charset=utf-8", body);
}

pub fn htmlEscape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&#39;"),
        else => try out.append(a, c),
    };
    return out.items;
}

/// Answers a failed request: HttpErrors with their status, anything else as a 500.
pub fn sendError(q: *Req, err: anyerror) !void {
    if (q.ctx.responded) return;
    var status: u16 = 500;
    var message: []const u8 = "Something went wrong on our side. Please try again.";
    var code: []const u8 = "error";
    var extra: ?Val = null;
    if (err == error.Http) {
        if (q.r.err) |e| {
            status = e.status;
            message = if (status >= 500) "Something went wrong on our side. Please try again." else e.message;
            code = e.code;
            extra = e.extra;
        }
    } else {
        std.log.err("{s} {s}: {t}", .{ @tagName(q.method), q.path, err });
    }
    const body = try Val.object(q.r.a);
    try body.set("message", message);
    try body.set("code", code);
    if (extra) |x| for (x.keys(), x.vals()) |kv_k, kv_v| try body.set(kv_k, kv_v);
    return q.jsonStatus(status, .{ .@"error" = body });
}
