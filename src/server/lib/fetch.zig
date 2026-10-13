//! Outgoing HTTP requests (webhooks, app storage, Wufour, OpenRouter, push services, link
//! previews) with a time limit, and the SSRF guard of src/util/net.js. std.http.Client has no
//! timeouts, so each request runs as its own task and the caller stops waiting at the deadline;
//! the task finishes (and frees itself) whenever the other side answers or gives up.

const std = @import("std");
const Io = std.Io;
const A = @import("../app.zig");
const Allocator = std.mem.Allocator;

pub const Response = struct {
    status: u16,
    content_type: []const u8,
    location: ?[]const u8,
    body: []const u8,
};

pub const Options = struct {
    method: std.http.Method = .GET,
    headers: []const std.http.Header = &.{},
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    timeout_ms: i64 = 10_000,
    max_bytes: usize = 16 << 20,
    /// Follow up to 3 redirects (GET only).
    follow: bool = false,
};

const Job = struct {
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(u8) = .init(2),
    done: Io.Event = .unset,
    url: []const u8,
    opts: Options,
    result: anyerror!Response = error.Pending,

    fn release(j: *Job) void {
        if (j.refs.fetchSub(1, .acq_rel) == 1) {
            j.arena.deinit();
            A.app.gpa.destroy(j);
        }
    }
};

/// Sends a request and reads the whole answer into `a`. Errors when the other side cannot be
/// reached, or does not answer within `timeout_ms` (error.Timeout).
pub fn fetch(a: Allocator, url: []const u8, opts: Options) !Response {
    const gpa = A.app.gpa;
    const job = try gpa.create(Job);
    job.* = .{ .arena = .init(gpa), .url = undefined, .opts = opts };
    {
        const ja = job.arena.allocator();
        job.url = ja.dupe(u8, url) catch |e| {
            job.arena.deinit();
            gpa.destroy(job);
            return e;
        };
        var hs = try ja.alloc(std.http.Header, opts.headers.len);
        for (opts.headers, 0..) |h, i| hs[i] = .{ .name = try ja.dupe(u8, h.name), .value = try ja.dupe(u8, h.value) };
        job.opts.headers = hs;
        if (opts.body) |b| job.opts.body = try ja.dupe(u8, b);
        if (opts.content_type) |c| job.opts.content_type = try ja.dupe(u8, c);
        if (opts.user_agent) |c| job.opts.user_agent = try ja.dupe(u8, c);
    }
    A.app.bg.concurrent(A.app.io, run, .{job}) catch {
        run(job);
    };
    defer job.release();
    const deadline: Io.Timeout = .{ .deadline = .fromNow(A.app.io, .{ .raw = .fromMilliseconds(opts.timeout_ms), .clock = .awake }) };
    while (!job.done.isSet()) {
        job.done.waitTimeout(A.app.io, deadline) catch |e| switch (e) {
            error.Timeout => {
                if (job.done.isSet()) break;
                const left = deadline.toDurationFromNow(A.app.io) orelse break;
                if (left.raw.toMilliseconds() <= 0) return error.Timeout;
            },
            error.Canceled => return error.Canceled,
        };
    }
    const res = try job.result;
    return .{
        .status = res.status,
        .content_type = try a.dupe(u8, res.content_type),
        .location = if (res.location) |l| try a.dupe(u8, l) else null,
        .body = try a.dupe(u8, res.body),
    };
}

fn run(job: *Job) void {
    defer job.release();
    job.result = attempt(job.arena.allocator(), job.url, job.opts) catch |e| switch (e) {
        error.OutOfMemory, error.ResponseTooLarge, error.InvalidUrl => e,
        // A pooled connection the other side closed while idle fails at once: try a new one.
        else => attempt(job.arena.allocator(), job.url, job.opts),
    };
    job.done.set(A.app.io);
}

fn attempt(a: Allocator, url: []const u8, opts: Options) !Response {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var req = try A.app.client.request(opts.method, uri, .{
        .extra_headers = opts.headers,
        .redirect_behavior = if (opts.follow) @fromBackingInt(@intCast(3)) else .unhandled,
        .keep_alive = true,
        .headers = .{
            .accept_encoding = .omit,
            .user_agent = if (opts.user_agent) |u| .{ .override = u } else .default,
            .content_type = if (opts.content_type) |c| .{ .override = c } else .default,
        },
    });
    defer req.deinit();
    if (opts.body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
        var w = try req.sendBodyUnflushed(&.{});
        try w.writer.writeAll(b);
        try w.end();
        try req.connection.?.flush();
    } else try req.sendBodiless();
    var redirect_buf: [2048]u8 = undefined;
    var res = try req.receiveHead(if (opts.follow) &redirect_buf else &.{});
    const status: u16 = @backingInt(res.head.status);
    const content_type = try a.dupe(u8, res.head.content_type orelse "");
    var location: ?[]const u8 = null;
    var it = res.head.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "location")) {
        location = try a.dupe(u8, h.value);
    };
    var transfer: [64]u8 = undefined;
    const body = res.reader(&transfer).allocRemaining(a, .limited(opts.max_bytes)) catch |e| switch (e) {
        error.StreamTooLong => return error.ResponseTooLarge,
        else => return e,
    };
    return .{ .status = status, .content_type = content_type, .location = location, .body = body };
}

// ---------------------------------------------------------------------------------------------
// SSRF guard (src/util/net.js)
// ---------------------------------------------------------------------------------------------

fn isPrivate(addr: Io.net.IpAddress) bool {
    switch (addr) {
        .ip4 => |x| return private4(x.bytes),
        .ip6 => |x| {
            const b = x.bytes;
            // ::ffff:a.b.c.d
            if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff) return private4(b[12..16].*);
            if (std.mem.allEqual(u8, b[0..15], 0) and (b[15] == 1 or b[15] == 0)) return true;
            if (b[0] == 0xfc or b[0] == 0xfd) return true;
            if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return true;
            return false;
        },
    }
}

fn private4(b: [4]u8) bool {
    return b[0] == 10 or b[0] == 127 or b[0] == 0 or (b[0] == 169 and b[1] == 254) or (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or
        (b[0] == 192 and b[1] == 168) or (b[0] == 100 and b[1] >= 64 and b[1] <= 127) or b[0] >= 224;
}

pub const UrlError = error{ InvalidUrl, NotHttp, Unreachable };

/// Refuses URLs that are not http(s), and (unless ALLOW_PRIVATE_FETCH=true) any whose host
/// resolves to a loopback, private or link-local address.
pub fn assertPublicUrl(url: []const u8) UrlError!void {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.NotHttp;
    const host_c = uri.host orelse return error.InvalidUrl;
    if (A.app.config.allow_private_fetch) return;
    var hbuf: [256]u8 = undefined;
    const host_raw = host_c.toRaw(&hbuf) catch return error.InvalidUrl;
    const host = std.mem.trim(u8, host_raw, "[]");
    if (Io.net.IpAddress.parse(host, 0)) |ip| {
        if (isPrivate(ip)) return error.Unreachable;
        return;
    } else |_| {}
    const name = Io.net.HostName.init(host) catch return error.InvalidUrl;
    var buf: [16]Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&buf);
    name.lookup(A.app.io, &queue, .{ .port = 80 }) catch return error.Unreachable;
    var any = false;
    while (queue.getOne(A.app.io)) |r| switch (r) {
        .address => |ad| {
            any = true;
            if (isPrivate(ad)) return error.Unreachable;
        },
        .canonical_name => {},
    } else |_| {}
    if (!any) return error.Unreachable;
}

/// The message Reseal-js's assertPublicUrl throws, for error texts that include it.
pub fn urlErrorMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.InvalidUrl => "Invalid URL",
        error.NotHttp => "Only http and https URLs are allowed",
        error.Unreachable => "That address is not reachable from Reseal",
        error.Timeout => "The operation was aborted due to timeout",
        else => "fetch failed",
    };
}
