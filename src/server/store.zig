//! Where messages live (src/services/store.js).
//!
//! Reseal's own chats (appId: null) keep their messages in Reseal's database. Chats inside an
//! app that embeds Reseal belong to that app: their messages are kept in the app's own database,
//! reached through the app's storage endpoint (docs/message-storage.md). The one exception is a
//! message that has not gone out yet (scheduled, or "send when online"): it waits in Reseal and
//! moves to the app when it is sent.
//!
//! Callers use the same Mongo-style filters and update operators for both; documents that come
//! back from an app are filtered and updated here with a small matcher.

const std = @import("std");
const Io = std.Io;
const A = @import("app.zig");
const fetch = @import("lib/fetch.zig");
const webhooks = @import("webhooks.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;
const Allocator = std.mem.Allocator;

const TIMEOUT_MS = 8_000;
const PAGE = 100;

pub fn isAppChat(chat: Val) bool {
    return chat.get("appId").truthy();
}

// ---- Matching and updating documents in memory ----------------------------------------------

fn isOperatorObject(c: Val) bool {
    if (c != .obj) return false;
    for (c.keys()) |kv| if (kv.k.len > 0 and kv.k[0] == '$') return true;
    return false;
}

fn same(a: Allocator, x: Val, y: Val) bool {
    if (x.isNullish() or y.isNullish()) return x.isNullish() and y.isNullish();
    if (x == .date or y == .date) return dateMs(x) == dateMs(y);
    if (x == .id or y == .id) return val.same(x, y);
    if (x == .obj or x == .arr or y == .obj or y == .arr) {
        const sx = val.stringify(a, x) catch return false;
        const sy = val.stringify(a, y) catch return false;
        return std.mem.eql(u8, sx, sy);
    }
    return val.Val.eql(x, y);
}

fn dateMs(v: Val) ?f64 {
    return switch (v) {
        .date => |ms| @floatFromInt(ms),
        .num => |x| x,
        .str => |s| if (val.parseDate(s)) |ms| @as(f64, @floatFromInt(ms)) else null,
        else => null,
    };
}

fn eqAny(a: Allocator, v: Val, x: Val) bool {
    if (v == .arr) {
        for (v.items()) |e| if (same(a, e, x)) return true;
        return false;
    }
    return same(a, v, x);
}

fn order(x: Val, y: Val) ?f64 {
    if (x == .date or y == .date) {
        const dx = dateMs(x) orelse return null;
        const dy = dateMs(y) orelse return null;
        return dx - dy;
    }
    if (x == .num and y == .num) return x.num - y.num;
    return null;
}

fn matchCond(a: Allocator, v: Val, cond: Val) bool {
    if (!isOperatorObject(cond)) return eqAny(a, v, cond);
    for (cond.keys()) |kv| {
        const op = kv.k;
        const arg = kv.v;
        const ok = if (std.mem.eql(u8, op, "$exists"))
            (v != .undef) == arg.truthy()
        else if (std.mem.eql(u8, op, "$ne"))
            !eqAny(a, v, arg)
        else if (std.mem.eql(u8, op, "$in")) blk: {
            for (arg.items()) |x| if (eqAny(a, v, x)) break :blk true;
            break :blk false;
        } else if (std.mem.eql(u8, op, "$nin")) blk: {
            for (arg.items()) |x| if (eqAny(a, v, x)) break :blk false;
            break :blk true;
        } else if (std.mem.eql(u8, op, "$gt"))
            !v.isNullish() and (order(v, arg) orelse -1) > 0
        else if (std.mem.eql(u8, op, "$gte"))
            !v.isNullish() and (order(v, arg) orelse -1) >= 0
        else if (std.mem.eql(u8, op, "$lt"))
            !v.isNullish() and (order(v, arg) orelse 1) < 0
        else if (std.mem.eql(u8, op, "$lte"))
            !v.isNullish() and (order(v, arg) orelse 1) <= 0
        else if (std.mem.eql(u8, op, "$type")) blk: {
            const t = arg.asStr() orelse break :blk false;
            if (std.mem.eql(u8, t, "date")) break :blk v == .date;
            if (std.mem.eql(u8, t, "objectId")) break :blk v == .id;
            if (std.mem.eql(u8, t, "number")) break :blk v == .num;
            if (std.mem.eql(u8, t, "string")) break :blk v == .str;
            if (std.mem.eql(u8, t, "boolean")) break :blk v == .bool;
            if (std.mem.eql(u8, t, "object")) break :blk v == .obj or v == .arr or v == .null;
            break :blk false;
        } else false;
        if (!ok) return false;
    }
    return true;
}

pub fn matches(a: Allocator, doc: Val, filter: Val) bool {
    for (filter.keys()) |kv| if (!matchCond(a, doc.path(kv.k), kv.v)) return false;
    return true;
}

fn setPath(a: Allocator, doc: Val, p: []const u8, value: Val) !void {
    var o = doc;
    var it = std.mem.splitScalar(u8, p, '.');
    var key = it.next().?;
    while (it.next()) |next| {
        var child = o.get(key);
        if (child.isNullish()) {
            child = try Val.object(a);
            try o.put(a, key, child);
        }
        if (child != .obj) return; // cannot descend into a primitive; Mongo would refuse too
        o = child;
        key = next;
    }
    if (o == .obj) try o.put(a, key, value);
}

fn unsetPath(doc: Val, p: []const u8) void {
    const dot = std.mem.lastIndexOfScalar(u8, p, '.');
    const parent = if (dot) |d| doc.path(p[0..d]) else doc;
    parent.del(if (dot) |d| p[d + 1 ..] else p);
}

/// Applies Mongo update operators ($set, $unset, $inc, $addToSet, $pull, $push) in place.
pub fn applyUpdate(a: Allocator, doc: Val, ops: Val) !void {
    for (ops.keys()) |op| {
        for (op.v.keys()) |f| {
            const cur = doc.path(f.k);
            if (std.mem.eql(u8, op.k, "$set")) {
                try setPath(a, doc, f.k, f.v);
            } else if (std.mem.eql(u8, op.k, "$unset")) {
                unsetPath(doc, f.k);
            } else if (std.mem.eql(u8, op.k, "$inc")) {
                const base: f64 = if (cur.truthy()) (cur.asNum() orelse 0) else 0;
                try setPath(a, doc, f.k, .{ .num = base + (f.v.asNum() orelse 0) });
            } else if (std.mem.eql(u8, op.k, "$addToSet")) {
                var arr = if (cur == .arr) cur else try Val.array(a);
                var found = false;
                for (arr.items()) |x| if (same(a, x, f.v)) {
                    found = true;
                };
                if (!found) try arr.push(a, f.v);
                try setPath(a, doc, f.k, arr);
            } else if (std.mem.eql(u8, op.k, "$push")) {
                var arr = if (cur == .arr) cur else try Val.array(a);
                const each = f.v.get("$each");
                if (f.v == .obj and each == .arr) {
                    for (each.items()) |x| try arr.push(a, x);
                } else try arr.push(a, f.v);
                try setPath(a, doc, f.k, arr);
            } else if (std.mem.eql(u8, op.k, "$pull")) {
                if (cur == .arr) {
                    const by_fields = f.v == .obj;
                    var kept = try Val.array(a);
                    for (cur.items()) |x| {
                        const drop = if (by_fields) matches(a, x, f.v) else same(a, x, f.v);
                        if (!drop) try kept.push(a, x);
                    }
                    try setPath(a, doc, f.k, kept);
                }
            } else return error.UnsupportedUpdate;
        }
    }
}

// Updates to one message are applied one after another, so two reactions at once do not
// overwrite each other.
var stripes: [64]Io.Mutex = @splat(.init);

fn stripeOf(id: Val) *Io.Mutex {
    var buf: [40]u8 = undefined;
    const k = val.keyOf(id, &buf) orelse "";
    return &stripes[std.hash.Wyhash.hash(0, k) % stripes.len];
}

// ---- The app's storage endpoint ---------------------------------------------------------------

const AppEntry = struct { at: i64, url: ?[]u8, secret: ?[]u8 };
var app_lock: Io.Mutex = .init;
var app_cache: std.AutoHashMapUnmanaged([24]u8, AppEntry) = .empty;

fn freeEntry(e: AppEntry) void {
    if (e.url) |u| A.app.gpa.free(u);
    if (e.secret) |s| A.app.gpa.free(s);
}

pub fn forgetApp(app_id: Val) void {
    var buf: [40]u8 = undefined;
    const k = val.keyOf(app_id, &buf) orelse return;
    if (k.len != 24) return;
    app_lock.lockUncancelable(A.app.io);
    defer app_lock.unlock(A.app.io);
    if (app_cache.fetchRemove(k[0..24].*)) |kv| freeEntry(kv.value);
}

fn appOf(r: *Rq, app_id: Val) !struct { url: ?[]const u8, secret: ?[]const u8 } {
    var buf: [40]u8 = undefined;
    const ks = val.keyOf(app_id, &buf) orelse "";
    const io = A.app.io;
    if (ks.len == 24) {
        app_lock.lockUncancelable(io);
        defer app_lock.unlock(io);
        if (app_cache.get(ks[0..24].*)) |hit| if (A.nowMs() - hit.at < 30_000) {
            return .{ .url = if (hit.url) |u| try r.a.dupe(u8, u) else null, .secret = if (hit.secret) |s| try r.a.dupe(u8, s) else null };
        };
    }
    const app_doc = try A.app.col.apps.findOne(r.a, .{ ._id = app_id }, .{ .projection = .{ .storage = 1, .@"webhook.secretSealed" = 1 } });
    const url: ?[]const u8 = if (app_doc) |d| (d.path("storage.url").asStr()) else null;
    const secret: ?[]const u8 = if (app_doc) |d| A.unseal(r.a, d.path("webhook.secretSealed")) else null;
    if (ks.len == 24) {
        const gpa = A.app.gpa;
        app_lock.lockUncancelable(io);
        defer app_lock.unlock(io);
        const e: AppEntry = .{ .at = A.nowMs(), .url = if (url) |u| try gpa.dupe(u8, u) else null, .secret = if (secret) |s| try gpa.dupe(u8, s) else null };
        if (try app_cache.fetchPut(gpa, ks[0..24].*, e)) |old| freeEntry(old.value);
    }
    return .{ .url = url, .secret = secret };
}

/// One message as it travels to and from the app: index fields beside the opaque document.
pub fn toRecord(r: *Rq, doc: Val) !Val {
    const a = r.a;
    const ca = doc.get("createdAt");
    return val.from(a, .{
        .id = try r.sn(doc.get("_id")),
        .chatId = try r.sn(doc.get("chatId")),
        .seq = if (doc.get("seq").isNullish()) Val.null else doc.get("seq"),
        .senderId = try r.sn(doc.get("senderId")),
        .clientId = if (doc.get("clientId").truthy()) doc.get("clientId") else Val.null,
        .createdAt = if (ca == .date) Val{ .str = try val.isoDate(a, ca.date) } else Val.null,
        .message = try val.toEjson(a, doc),
    });
}

pub fn fromRecord(r: *Rq, rec: Val) !?Val {
    const m = rec.get("message");
    if (!m.truthy()) return null;
    const doc = try val.fromEjson(r.a, m);
    return if (doc.get("_id").truthy()) doc else null;
}

pub const Override = struct { url: []const u8, secret: []const u8 };

/// POSTs one signed operation to an app's storage endpoint (or to `override`, when testing a
/// new one).
pub fn callApp(r: *Rq, app_id: Val, op: []const u8, body: Val, override: ?Override) !Val {
    const a = r.a;
    var url: []const u8 = undefined;
    var secret: []const u8 = undefined;
    if (override) |o| {
        url = o.url;
        secret = o.secret;
    } else {
        const app_ = try appOf(r, app_id);
        if (app_.url == null or app_.url.?.len == 0 or app_.secret == null or app_.secret.?.len == 0) {
            return r.fail(503, "This app has not connected its message storage yet. Its developer sets it up in the developer console, under Storage.", "storage_not_configured");
        }
        url = app_.url.?;
        secret = app_.secret.?;
    }
    const full = try val.from(a, .{ .op = op, .appId = try r.sn(app_id) });
    for (body.keys()) |kv| try full.put(a, kv.k, kv.v);
    const payload = try val.stringify(a, full);
    fetch.assertPublicUrl(url) catch |e| return r.fail(502, try r.fmt("The app's message storage did not answer ({s})", .{fetch.urlErrorMessage(e)}), "storage_unavailable");
    const res = fetch.fetch(a, url, .{
        .method = .POST,
        .body = payload,
        .content_type = "application/json",
        .user_agent = "Reseal-Storage/1.0",
        .timeout_ms = TIMEOUT_MS,
        .headers = &.{
            .{ .name = "Reseal-Operation", .value = op },
            .{ .name = "Reseal-Signature", .value = try webhooks.signature(a, secret, payload) },
        },
    }) catch |e| return r.fail(502, try r.fmt("The app's message storage did not answer ({s})", .{fetch.urlErrorMessage(e)}), "storage_unavailable");
    if (res.status < 200 or res.status >= 300) return r.fail(502, try r.fmt("The app's message storage answered HTTP {d}", .{res.status}), "storage_error");
    const out = val.parseJson(a, res.body) catch return Val.object(a);
    return if (out.isNullish()) Val.object(a) else out;
}

fn remoteGet(r: *Rq, chat: Val, ids: []const Val) ![]Val {
    const a = r.a;
    if (ids.len == 0) return &.{};
    var id_list = try Val.array(a);
    for (ids) |id| try id_list.push(a, try r.sn(id));
    const res = try callApp(r, chat.get("appId"), "get", try val.from(a, .{ .chatId = try r.sn(chat.get("_id")), .ids = id_list }), null);
    var out: std.ArrayList(Val) = .empty;
    for (res.get("messages").items()) |rec| {
        const d = (try fromRecord(r, rec)) orelse continue;
        if (val.same(d.get("chatId"), chat.get("_id"))) try out.append(a, d);
    }
    return out.items;
}

fn remotePut(r: *Rq, chat: Val, docs: []const Val) !void {
    if (docs.len == 0) return;
    const a = r.a;
    var recs = try Val.array(a);
    for (docs) |d| try recs.push(a, try toRecord(r, d));
    _ = try callApp(r, chat.get("appId"), "put", try val.from(a, .{ .chatId = try r.sn(chat.get("_id")), .messages = recs }), null);
}

// ---- Operations ------------------------------------------------------------------------------

fn emptyFilter(a: Allocator) !Val {
    return Val.object(a);
}

/// One message of a chat, optionally only when it also matches `filter`.
pub fn findOne(r: *Rq, chat: Val, id: Val, filter: ?Val) !?Val {
    const a = r.a;
    if (!id.truthy()) return null;
    const f = filter orelse try emptyFilter(a);
    const pending = try A.app.col.messages.findOne(a, .{ ._id = id, .chatId = chat.get("_id") }, .{});
    if (pending != null or !isAppChat(chat)) {
        const p = pending orelse return null;
        return if (matches(a, p, f)) p else null;
    }
    const docs = try remoteGet(r, chat, &.{id});
    if (docs.len == 0) return null;
    return if (matches(a, docs[0], f)) docs[0] else null;
}

pub fn findMany(r: *Rq, chat: Val, ids: []const Val) ![]Val {
    const a = r.a;
    const pending = try A.app.col.messages.find(a, .{ ._id = .{ .@"$in" = ids }, .chatId = chat.get("_id") }, .{});
    if (!isAppChat(chat)) return pending;
    var rest: std.ArrayList(Val) = .empty;
    outer: for (ids) |id| {
        for (pending) |p| if (val.same(p.get("_id"), id)) continue :outer;
        try rest.append(a, id);
    }
    const remote = try remoteGet(r, chat, rest.items);
    var out: std.ArrayList(Val) = .empty;
    try out.appendSlice(a, pending);
    try out.appendSlice(a, remote);
    return out.items;
}

/// A message sent earlier with the same clientId (retries are idempotent).
pub fn byClientId(r: *Rq, chat: Val, sender_id: Val, client_id: []const u8) !?Val {
    const a = r.a;
    const pending = try A.app.col.messages.findOne(a, .{ .chatId = chat.get("_id"), .senderId = sender_id, .clientId = client_id }, .{});
    if (pending != null or !isAppChat(chat)) return pending;
    const res = try callApp(r, chat.get("appId"), "find", try val.from(a, .{ .chatId = try r.sn(chat.get("_id")), .senderId = try r.sn(sender_id), .clientId = client_id }), null);
    const doc = (try fromRecord(r, res.get("message"))) orelse return null;
    return if (val.same(doc.get("chatId"), chat.get("_id"))) doc else null;
}

/// Stores a new message. Messages that are not sent yet (seq: null) always wait in Reseal.
pub fn insert(r: *Rq, chat: Val, doc: Val) !void {
    try A.db.ensureId(r.a, A.app.io, doc);
    if (!isAppChat(chat) or doc.get("seq") == .null) {
        _ = try A.app.col.messages.insertOne(r.a, doc);
    } else try remotePut(r, chat, &.{doc});
}

/// Updates one message with Mongo operators; the updated document, or null.
pub fn update(r: *Rq, chat: Val, id: Val, ops: Val) !?Val {
    const a = r.a;
    const pending = try A.app.col.messages.findOneAndUpdate(a, .{ ._id = id, .chatId = chat.get("_id") }, ops, .{});
    if (pending != null or !isAppChat(chat)) return pending;
    const m = stripeOf(id);
    m.lockUncancelable(A.app.io);
    defer m.unlock(A.app.io);
    const docs = try remoteGet(r, chat, &.{id});
    if (docs.len == 0) return null;
    try applyUpdate(a, docs[0], ops);
    try remotePut(r, chat, docs[0..1]);
    return docs[0];
}

pub fn updateMany(r: *Rq, chat: Val, ids: []const Val, ops: Val) !void {
    const a = r.a;
    if (ids.len == 0) return;
    _ = try A.app.col.messages.updateMany(a, .{ ._id = .{ .@"$in" = ids }, .chatId = chat.get("_id") }, ops, .{});
    if (!isAppChat(chat)) return;
    const pending = try A.app.col.messages.find(a, .{ ._id = .{ .@"$in" = ids }, .chatId = chat.get("_id") }, .{ .projection = .{ ._id = 1 } });
    var rest: std.ArrayList(Val) = .empty;
    outer: for (ids) |id| {
        for (pending) |p| if (val.same(p.get("_id"), id)) continue :outer;
        try rest.append(a, id);
    }
    if (rest.items.len == 0) return;
    const docs = try remoteGet(r, chat, rest.items);
    for (docs) |d| try applyUpdate(a, d, ops);
    try remotePut(r, chat, docs);
}

pub const ListOpts = struct {
    filter: ?Val = null,
    after: ?i64 = null,
    before: ?i64 = null,
    asc: bool = false,
    limit: i64 = 50,
};

/// Sent messages of a chat in seq order. `after` and `before` are exclusive seq bounds.
pub fn list(r: *Rq, chat: Val, o: ListOpts) ![]Val {
    const a = r.a;
    const seq = try val.from(a, .{ .@"$ne" = Val.null });
    if (o.after) |x| try seq.set(a, "$gt", x);
    if (o.before) |x| try seq.set(a, "$lt", x);
    const q = try val.from(a, .{ .chatId = chat.get("_id") });
    if (o.filter) |f| for (f.keys()) |kv| try q.put(a, kv.k, kv.v);
    try q.put(a, "seq", seq);
    if (!isAppChat(chat)) {
        return A.app.col.messages.find(a, q, .{ .sort = .{ .seq = @as(i32, if (o.asc) 1 else -1) }, .limit = o.limit });
    }
    // The app returns pages by seq; anything it cannot filter on is filtered here, so keep
    // paging until the page is full.
    var out: std.ArrayList(Val) = .empty;
    var lo = o.after;
    var hi = o.before;
    const match_filter = try val.clone(a, if (o.filter) |f| f else try Val.object(a));
    try match_filter.put(a, "seq", seq);
    var round: usize = 0;
    while (round < 20 and out.items.len < o.limit) : (round += 1) {
        const want = @max(PAGE, o.limit - @as(i64, @intCast(out.items.len)));
        const res = try callApp(r, chat.get("appId"), "list", try val.from(a, .{
            .chatId = try r.sn(chat.get("_id")),
            .afterSeq = if (lo) |x| Val.n(x) else Val.null,
            .beforeSeq = if (hi) |x| Val.n(x) else Val.null,
            .order = if (o.asc) "asc" else "desc",
            .limit = want,
        }), null);
        var docs: std.ArrayList(Val) = .empty;
        for (res.get("messages").items()) |rec| {
            const d = (try fromRecord(r, rec)) orelse continue;
            if (val.same(d.get("chatId"), chat.get("_id")) and d.get("seq") == .num) try docs.append(a, d);
        }
        const Ctx = struct { asc: bool };
        std.mem.sort(Val, docs.items, Ctx{ .asc = o.asc }, struct {
            fn lt(c: Ctx, x: Val, y: Val) bool {
                return if (c.asc) x.get("seq").num < y.get("seq").num else x.get("seq").num > y.get("seq").num;
            }
        }.lt);
        for (docs.items) |d| if (out.items.len < o.limit and matches(a, d, match_filter)) try out.append(a, d);
        if (docs.items.len < want) break;
        const last: i64 = docs.items[docs.items.len - 1].get("seq").asInt() orelse break;
        if (o.asc) lo = last else hi = last;
    }
    return out.items;
}

/// Counts sent messages after a seq that match `filter` (unread counters).
pub fn count(r: *Rq, chat: Val, filter: Val, after: i64) !i64 {
    const a = r.a;
    const cap: i64 = 9999;
    if (!isAppChat(chat)) {
        const q = try val.from(a, .{ .chatId = chat.get("_id") });
        for (filter.keys()) |kv| try q.put(a, kv.k, kv.v);
        try q.set(a, "seq", .{ .@"$gt" = after });
        return A.app.col.messages.count(a, q, .{ .limit = cap });
    }
    if ((chat.get("seq").asInt() orelse 0) <= after) return 0;
    return @intCast((try list(r, chat, .{ .filter = filter, .after = after, .asc = true, .limit = @min(cap, 999) })).len);
}

pub fn latest(r: *Rq, chat: Val, filter: Val) !?Val {
    const docs = try list(r, chat, .{ .filter = filter, .limit = 1 });
    return if (docs.len > 0) docs[0] else null;
}

/// Removes messages for good (self-destruct timers, unsent messages).
pub fn remove(r: *Rq, chat: Val, ids: []const Val) !void {
    const a = r.a;
    if (ids.len == 0) return;
    _ = try A.app.col.messages.deleteMany(a, .{ ._id = .{ .@"$in" = ids }, .chatId = chat.get("_id") });
    if (isAppChat(chat)) {
        var list_ = try Val.array(a);
        for (ids) |id| try list_.push(a, try r.sn(id));
        _ = try callApp(r, chat.get("appId"), "delete", try val.from(a, .{ .chatId = try r.sn(chat.get("_id")), .ids = list_ }), null);
    }
}

/// Removes a chat's history. With `unsent`, also messages that have not gone out yet.
pub fn clear(r: *Rq, chat: Val, unsent: bool) !void {
    const a = r.a;
    if (isAppChat(chat)) _ = try callApp(r, chat.get("appId"), "delete", try val.from(a, .{ .chatId = try r.sn(chat.get("_id")), .ids = Val.null }), null);
    if (unsent) {
        _ = try A.app.col.messages.deleteMany(a, .{ .chatId = chat.get("_id") });
    } else {
        _ = try A.app.col.messages.deleteMany(a, .{ .chatId = chat.get("_id"), .seq = .{ .@"$ne" = Val.null } });
    }
}

/// Full-text search in an app's readable chats. Optional for apps: no answer means no results.
pub fn searchApp(r: *Rq, app_id: Val, chat_ids: []const Val, query: []const u8) ![]Val {
    const a = r.a;
    if (chat_ids.len == 0) return &.{};
    var ids = try Val.array(a);
    for (chat_ids) |c| try ids.push(a, try r.sn(c));
    const res = callApp(r, app_id, "search", try val.from(a, .{ .chatIds = ids, .query = query, .limit = 50 }), null) catch return &.{};
    var out: std.ArrayList(Val) = .empty;
    for (res.get("messages").items()) |rec| {
        const d = (fromRecord(r, rec) catch null) orelse continue;
        for (chat_ids) |c| if (val.same(c, d.get("chatId"))) {
            try out.append(a, d);
            break;
        };
    }
    r.err = null;
    return out.items;
}

test "matcher and updates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try val.parseJson(a, "{\"seq\":3,\"kind\":\"message\",\"hiddenFor\":[\"u1\"],\"reactions\":{}}");
    try std.testing.expect(matches(a, doc, try val.parseJson(a, "{\"seq\":{\"$gt\":2,\"$ne\":null},\"deletedAt\":{\"$exists\":false},\"hiddenFor\":{\"$ne\":\"u2\"}}")));
    try std.testing.expect(!matches(a, doc, try val.parseJson(a, "{\"hiddenFor\":{\"$ne\":\"u1\"}}")));
    try applyUpdate(a, doc, try val.parseJson(a, "{\"$addToSet\":{\"reactions.x\":\"u1\"},\"$inc\":{\"views\":1}}"));
    try std.testing.expectEqualStrings("{\"seq\":3,\"kind\":\"message\",\"hiddenFor\":[\"u1\"],\"reactions\":{\"x\":[\"u1\"]},\"views\":1}", try val.stringify(a, doc));
}
