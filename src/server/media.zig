//! File storage in MongoDB, one document per 1 MiB chunk (src/services/media.js).
//!
//! Files in end-to-end encrypted chats are encrypted on the device chunk by chunk (AES-GCM), so
//! the server stores opaque bytes and never learns the file name or type. Chunked uploads give
//! progress bars, retries of single chunks, and parallel uploads.

const std = @import("std");
const A = @import("app.zig");
const web = @import("web.zig");
const stories = @import("stories.zig");
const moderation = @import("moderation.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

pub const CHUNK: i64 = A.Limits.upload_chunk_bytes;
const GCM_TAG = 16;

fn col() *A.Cols {
    return &A.app.col;
}

/// Types the browser may render inline from our origin. Anything else downloads as a file, so an
/// uploaded HTML or SVG file can never run script on Reseal's origin.
fn inlineSafe(mime: []const u8) bool {
    const ok = [_][]const u8{
        "image/png",   "image/jpeg", "image/gif",  "image/webp",      "image/avif",
        "video/mp4",   "video/webm", "video/ogg",  "video/quicktime", "audio/mpeg",
        "audio/mp4",   "audio/ogg",  "audio/webm", "audio/wav",       "audio/aac",
        "audio/x-m4a", "audio/flac",
    };
    for (ok) |x| if (std.mem.eql(u8, x, mime)) return true;
    return false;
}

fn mimeOk(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    if (slash == 0 or slash == s.len - 1) return false;
    if (std.mem.indexOfScalarPos(u8, s, slash + 1, '/') != null) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '.' or c == '+' or c == '-' or c == '/')) return false;
    return true;
}

pub fn createUpload(r: *Rq, user: Val, body: Val) !Val {
    const a = r.a;
    const size_f = @import("validate.zig").toNumber(body.get("size"));
    try r.ensure(std.math.isFinite(size_f) and @floor(size_f) == size_f and size_f > 0, "size must be a positive whole number", 400, null);
    const max = A.app.config.max_upload_bytes;
    try r.ensure(size_f <= @as(f64, @floatFromInt(max)), try r.fmt("Files can be up to {d} MB", .{@as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(max)) / 1048576)))}), 413, "too_large");
    const size: i64 = @intFromFloat(size_f);
    const encrypted = body.get("encrypted").isTrue();
    const chunks = @divFloor(size + CHUNK - 1, CHUNK);
    const mime: []const u8 = if (encrypted) "application/octet-stream" else try std.ascii.allocLowerString(a, @import("validate.zig").sliceUtf16(if (body.get("mime").truthy()) try r.str(body.get("mime")) else "application/octet-stream", 120));
    try r.ensure(mimeOk(mime), "mime type is invalid", 400, null);
    const purpose_v = body.get("purpose").asStr() orelse "";
    var purpose: []const u8 = "message";
    for ([_][]const u8{ "message", "avatar", "bot", "story" }) |p| if (std.mem.eql(u8, p, purpose_v)) {
        purpose = p;
    };
    const doc = try val.from(a, .{
        .ownerId = user.get("_id"),
        .size = size,
        .storedSize = if (encrypted) size + chunks * GCM_TAG else size,
        .chunks = chunks,
        .chunkSize = CHUNK,
        .encrypted = encrypted,
        .mime = mime,
        .name = if (encrypted or !body.get("name").truthy()) Val.null else Val{ .str = @import("validate.zig").sliceUtf16(try r.str(body.get("name")), 255) },
        .purpose = purpose,
        .status = "uploading",
        .received = try Val.array(a),
        .chatIds = try Val.array(a),
        .public = false,
        .createdAt = A.now(),
    });
    const id = try col().media.insertOne(a, doc);
    return val.from(a, .{ .id = try r.str(id), .chunkSize = CHUNK, .chunks = chunks, .encrypted = encrypted });
}

pub fn putChunk(r: *Rq, user: Val, media_id: Val, n_f: f64, data: []const u8) !void {
    const a = r.a;
    const m = (try col().media.findOne(a, .{ ._id = media_id, .ownerId = user.get("_id") }, .{})) orelse return r.fail(404, "Upload not found", null);
    try r.ensure(std.mem.eql(u8, m.get("status").asStr() orelse "", "uploading"), "This upload is already complete", 409, null);
    const chunks = m.get("chunks").asInt() orelse 0;
    try r.ensure(std.math.isFinite(n_f) and @floor(n_f) == n_f and n_f >= 0 and n_f < @as(f64, @floatFromInt(chunks)), "Chunk number is out of range", 400, null);
    const n: i64 = @intFromFloat(n_f);
    const overhead: i64 = if (m.get("encrypted").truthy()) GCM_TAG else 0;
    const expected = if (n == chunks - 1) (m.get("size").asInt() orelse 0) - CHUNK * (chunks - 1) + overhead else CHUNK + overhead;
    try r.ensure(@as(i64, @intCast(data.len)) == expected, try r.fmt("Chunk {d} should be {d} bytes, got {d}", .{ n, expected, data.len }), 400, null);
    _ = try col().mediaChunks.updateOne(a, .{ .mediaId = media_id, .n = n }, .{ .@"$set" = .{ .mediaId = media_id, .n = n, .data = Val{ .bin = data }, .size = data.len } }, .{ .upsert = true });
    _ = try col().media.updateOne(a, .{ ._id = media_id }, .{ .@"$addToSet" = .{ .received = n } }, .{});
}

pub fn completeUpload(r: *Rq, user: Val, media_id: Val, body: Val) !Val {
    const a = r.a;
    const m = (try col().media.findOne(a, .{ ._id = media_id, .ownerId = user.get("_id") }, .{})) orelse return r.fail(404, "Upload not found", null);
    if (std.mem.eql(u8, m.get("status").asStr() orelse "", "ready")) return m;
    const count = try col().mediaChunks.count(a, .{ .mediaId = media_id }, .{});
    const chunks = m.get("chunks").asInt() orelse 0;
    try r.ensure(count == chunks, try r.fmt("Upload incomplete: {d} of {d} chunks received", .{ count, chunks }), 409, "incomplete");
    const set = try val.from(a, .{ .status = "ready", .completedAt = A.now() });
    if (body.get("sha256").asStr()) |h| if (h.len == 64 and isLowerHex(h)) try set.set("sha256", h);
    // Content checks (Wufour Moderation) on readable images before the file becomes usable.
    // Files encrypted on the device are opaque bytes and are skipped.
    if (!m.get("encrypted").truthy() and std.mem.startsWith(u8, m.get("mime").asStr() orelse "", "image/") and (m.get("size").asInt() orelse 0) <= 5 * 1024 * 1024) {
        var bytes: std.ArrayList(u8) = .empty;
        var i: i64 = 0;
        while (i < chunks) : (i += 1) if (try readChunk(r, m, i)) |c| try bytes.appendSlice(a, c);
        const purpose = m.get("purpose").asStr() orelse "message";
        const outcome = moderation.check(r, user, try val.from(a, .{ .type = "upload", .id = try r.str(media_id), .field = purpose }), try Val.object(a), &.{.{ .id = "image", .bytes = bytes.items }}) catch |e| {
            if (e == error.Http) if (r.err) |he| if (he.status == 422) {
                // Layer 1: the upload is discarded, nothing stays behind.
                _ = try col().mediaChunks.deleteMany(a, .{ .mediaId = media_id });
                _ = try col().media.deleteOne(a, .{ ._id = media_id });
            };
            return e;
        };
        try set.set("moderation", try moderation.stamp(a, outcome));
    }
    _ = try col().media.updateOne(a, .{ ._id = media_id }, .{ .@"$set" = set, .@"$unset" = .{ .received = "" } }, .{});
    const out = try val.clone(a, m);
    for (set.keys(), set.vals()) |kv_k, kv_v| try out.set(kv_k, kv_v);
    return out;
}

fn isLowerHex(s: []const u8) bool {
    for (s) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// Can this user read this file? Public files (avatars) are readable by anyone with the link.
pub fn canRead(r: *Rq, user: ?Val, m_: ?Val) !bool {
    const m = m_ orelse return false;
    if (!std.mem.eql(u8, m.get("status").asStr() orelse "", "ready")) return false;
    if (m.get("public").truthy()) return true;
    const u = user orelse return false;
    if (val.same(m.get("ownerId"), u.get("_id"))) return true;
    if (std.mem.eql(u8, m.get("purpose").asStr() orelse "", "story")) return stories.canReadStoryMedia(r, u, m);
    if (m.get("chatIds").len() == 0) return false;
    return (try col().members.findOne(r.a, .{ .chatId = .{ .@"$in" = m.get("chatIds") }, .userId = u.get("_id"), .status = "active" }, .{ .projection = .{ ._id = 1 } })) != null;
}

/// A short-lived signed link, so <img>/<video> tags load files without an auth header.
pub fn signedPath(r: *Rq, media_id: []const u8, ttl_seconds: i64) ![]const u8 {
    const exp = @divFloor(A.nowMs(), 1000) + ttl_seconds;
    const sig = try A.hmacHex(r.a, &A.app.config.sign_key, try r.fmt("media:{s}:{d}", .{ media_id, exp }));
    return r.fmt("/m/{s}?e={d}&s={s}", .{ media_id, exp, sig[0..32] });
}

pub fn checkSignature(r: *Rq, media_id: []const u8, exp: ?[]const u8, sig: ?[]const u8) !bool {
    const e = exp orelse return false;
    const s = sig orelse return false;
    if (e.len == 0 or s.len == 0) return false;
    const e_num = std.fmt.parseFloat(f64, e) catch return false;
    if (e_num < @as(f64, @floatFromInt(A.nowMs())) / 1000) return false;
    const expected = try A.hmacHex(r.a, &A.app.config.sign_key, try r.fmt("media:{s}:{s}", .{ media_id, e }));
    return A.safeEqual(expected[0..32], s);
}

pub fn readChunk(r: *Rq, m: Val, n: i64) !?[]const u8 {
    const c = (try col().mediaChunks.findOne(r.a, .{ .mediaId = m.get("_id"), .n = n }, .{})) orelse return null;
    return if (c.get("data") == .bin) c.get("data").bin else null;
}

/// Streams a file (or a byte range of it) as the response.
pub fn stream(q: *web.Req, m: Val, download: bool) !void {
    const r = &q.r;
    const a = r.a;
    const total: u64 = @intCast(@max(0, m.get("storedSize").asInt() orelse 0));
    var start: u64 = 0;
    var len: u64 = total;
    var status: u16 = 200;
    switch (q.ctx.range(total)) {
        .full => {},
        .unsatisfiable => {
            q.status = 416;
            return q.ctx.unsatisfiable(total);
        },
        .partial => |p| {
            status = 206;
            start = p.start;
            len = try q.ctx.partial(p.start, p.last, total);
        },
    }
    const mime = m.get("mime").asStr() orelse "application/octet-stream";
    const inline_ = !download and !m.get("encrypted").truthy() and inlineSafe(mime);
    const id = try r.str(m.get("_id"));
    try q.setHeader("content-type", if (inline_) mime else "application/octet-stream");
    try q.setHeader("accept-ranges", "bytes");
    try q.setHeader("cache-control", if (m.get("public").truthy()) "public, max-age=31536000, immutable" else "private, max-age=86400");
    try q.setHeader("x-content-type-options", "nosniff");
    try q.setHeader("content-security-policy", "default-src 'none'; sandbox");
    try q.setHeader("cross-origin-resource-policy", "same-site");
    try q.setHeader("etag", try r.fmt("\"{s}\"", .{id}));
    if (!inline_) {
        const name = if (m.get("name").truthy()) try r.str(m.get("name")) else try r.fmt("file-{s}", .{id});
        try q.setHeader("content-disposition", try r.fmt("attachment; filename=\"{s}\"", .{try safeName(a, name)}));
    }
    q.status = status;
    var buf: [16 * 1024]u8 = undefined;
    // HEAD gets the headers only; a missing or short chunk ends the connection rather than
    // promise bytes that never come.
    var body = try q.ctx.startBody(&buf, @fromBackingInt(@intCast(status)), null, len);
    if (len == 0 or q.method == .HEAD) return body.finish();
    const end_ = start + len - 1;
    // Each stored chunk is chunkSize bytes, plus a 16-byte tag when encrypted.
    const stride: u64 = @intCast((m.get("chunkSize").asInt() orelse CHUNK) + @as(i64, if (m.get("encrypted").truthy()) GCM_TAG else 0));
    const first = start / stride;
    const last = end_ / stride;
    var n = first;
    var chunk_arena = std.heap.ArenaAllocator.init(A.app.gpa);
    defer chunk_arena.deinit();
    while (n <= last) : (n += 1) {
        _ = chunk_arena.reset(.retain_capacity);
        var cr: Rq = .{ .a = chunk_arena.allocator() };
        const data = (try readChunk(&cr, m, @intCast(n))) orelse break;
        const from: usize = if (n == first) @intCast(start - n * stride) else 0;
        const to: usize = if (n == last) @intCast(end_ - n * stride + 1) else data.len;
        const lo = @min(from, data.len);
        const hi = @max(lo, @min(to, data.len));
        try body.write(data[lo..hi]);
    }
    try body.finish();
}

/// name.replace(/[^\w.\- ]+/g, '_')
fn safeName(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_bad = false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == ' ';
        if (ok) {
            try out.append(a, c);
            in_bad = false;
        } else if (!in_bad) {
            try out.append(a, '_');
            in_bad = true;
        }
    }
    return out.items;
}

pub fn describe(r: *Rq, m: Val) !Val {
    const id = try r.str(m.get("_id"));
    return val.from(r.a, .{
        .id = id,
        .size = m.get("size"),
        .storedSize = m.get("storedSize"),
        .chunks = m.get("chunks"),
        .chunkSize = m.get("chunkSize"),
        .encrypted = m.get("encrypted"),
        .mime = m.get("mime"),
        .name = m.get("name"),
        .status = m.get("status"),
        .public = m.get("public").truthy(),
        .url = try signedPath(r, id, 6 * 3600),
    });
}

/// Removes abandoned uploads and files nobody references: once a minute after start, then hourly.
pub fn sweeperLoop() void {
    A.app.io.sleep(.fromSeconds(60), .awake) catch return;
    while (true) {
        sweep();
        A.app.io.sleep(.fromSeconds(3600), .awake) catch return;
    }
}

fn sweep() void {
    var arena = std.heap.ArenaAllocator.init(A.app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const t = A.nowMs();
    const stale = col().media.find(a, .{
        .@"$or" = .{
            .{ .status = "uploading", .createdAt = .{ .@"$lt" = Val{ .date = t - 24 * 3600_000 } } },
            .{ .status = "ready", .public = false, .chatIds = .{ .@"$size" = 0 }, .purpose = "message", .createdAt = .{ .@"$lt" = Val{ .date = t - 48 * 3600_000 } } },
            // A story file whose story was never posted (posted ones go with their story).
            .{ .purpose = "story", .storyId = .{ .@"$exists" = false }, .createdAt = .{ .@"$lt" = Val{ .date = t - 48 * 3600_000 } } },
        },
    }, .{ .projection = .{ ._id = 1 }, .limit = 200 }) catch |e| {
        std.log.err("Media sweep failed: {t}", .{e});
        return;
    };
    if (stale.len == 0) return;
    var ids: std.ArrayList(Val) = .empty;
    for (stale) |m| ids.append(a, m.get("_id")) catch return;
    _ = col().mediaChunks.deleteMany(a, .{ .mediaId = .{ .@"$in" = ids.items } }) catch {};
    _ = col().media.deleteMany(a, .{ ._id = .{ .@"$in" = ids.items } }) catch {};
}
