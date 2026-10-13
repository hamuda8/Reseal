//! Wufour directory, server to server (src/services/wufour.js), so people can message any Wufour
//! account, even one that has never opened Reseal. Uses Wufour's INTERNAL_API_KEY.

const std = @import("std");
const Io = std.Io;
const A = @import("app.zig");
const fetch = @import("lib/fetch.zig");
const auth = @import("auth.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

pub fn directoryEnabled() bool {
    return A.app.config.wufour_internal_key.len > 0;
}

fn call(r: *Rq, path: []const u8, body: Val) ?Val {
    if (!directoryEnabled()) return null;
    const a = r.a;
    const url = std.fmt.allocPrint(a, "{s}/api{s}", .{ auth.backendHost(a) catch return null, path }) catch return null;
    const res = fetch.fetch(a, url, .{
        .method = .POST,
        .body = val.stringify(a, body) catch return null,
        .content_type = "application/json",
        .timeout_ms = 5000,
        .headers = &.{.{ .name = "X-Internal-Key", .value = A.app.config.wufour_internal_key }},
    }) catch return null;
    if (res.status < 200 or res.status >= 300) return null;
    return val.parseJson(a, res.body) catch null;
}

// The search bar asks on every pause in typing: recent answers are kept 30 s, at most 300.
const Hit = struct { at: i64, json: []u8 };
var lock: Io.Mutex = .init;
var cache: std.StringArrayHashMapUnmanaged(Hit) = .empty;

/// Accounts whose username starts with the query, or whose email is exactly the query.
pub fn lookup(r: *Rq, query: []const u8) ![]Val {
    const a = r.a;
    const gpa = A.app.gpa;
    const key = try @import("validate.zig").jsLower(a, query);
    {
        lock.lockUncancelable(A.app.io);
        defer lock.unlock(A.app.io);
        if (cache.get(key)) |h| if (A.nowMs() - h.at < 30_000) return (try val.parseJson(a, h.json)).items();
    }
    const res = call(r, "/internal/users/lookup", try val.from(a, .{ .query = query })) orelse return &.{};
    const users = res.get("users");
    lock.lockUncancelable(A.app.io);
    defer lock.unlock(A.app.io);
    if (cache.fetchOrderedRemove(key)) |old| {
        gpa.free(old.key);
        gpa.free(old.value.json);
    }
    const k = try gpa.dupe(u8, key);
    const j = try gpa.dupe(u8, try val.stringify(a, if (users == .arr) users else try Val.array(a)));
    try cache.put(gpa, k, .{ .at = A.nowMs(), .json = j });
    while (cache.count() > 300) {
        const first = cache.keys()[0];
        const h = cache.values()[0];
        cache.orderedRemoveAt(0);
        gpa.free(first);
        gpa.free(h.json);
    }
    return users.items();
}

/// Confirms a Wufour account exists: { id, username }, or null.
pub fn findById(r: *Rq, id: []const u8) !?Val {
    const a = r.a;
    const res = call(r, "/internal/users/bulk", try val.from(a, .{ .ids = .{id} })) orelse return null;
    if (res != .arr or res.len() == 0) return null;
    const u = res.items()[0];
    if (u.isNullish()) return null;
    return try val.from(a, .{ .id = try val.str(a, u.get("_id")), .username = u.get("username") });
}
