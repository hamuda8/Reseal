//! File uploads and downloads, plus small utility endpoints (src/routes/media.js).

const std = @import("std");
const A = @import("../app.zig");
const web = @import("../web.zig");
const v = @import("../validate.zig");
const auth = @import("../auth.zig");
const media = @import("../media.zig");
const calls = @import("../calls.zig");
const ai = @import("../ai.zig");
const push = @import("../push.zig");
const preview = @import("../preview.zig");
const fetch = @import("../lib/fetch.zig");
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

/// The /api routes of this file (each one says whether it needs a user).
pub fn handleApi(q: *Req) !bool {
    if (q.is(.POST, "/api/media")) return done(createUpload(q));
    if (q.is(.PUT, "/api/media/:id/chunks/:n")) return done(putChunk(q));
    if (q.is(.POST, "/api/media/:id/complete")) return done(complete(q));
    if (q.is(.GET, "/api/media/:id")) return done(getMedia(q));
    if (q.is(.GET, "/api/media/:id/content")) return done(content(q));
    if (q.is(.GET, "/api/media/:id/chunks/:n")) return done(getChunk(q));
    if (q.is(.GET, "/api/config")) return done(config(q));
    if (q.is(.GET, "/api/calls/ice")) return done(ice(q));
    if (q.is(.GET, "/api/calls")) return done(callHistory(q));
    if (q.is(.GET, "/api/ai/models")) return done(models(q));
    if (q.is(.GET, "/api/link-preview")) return done(linkPreview(q));
    if (q.is(.GET, "/api/link-preview/image")) return done(previewImage(q));
    return false;
}

fn createUpload(q: *Req) !void {
    try auth.requireUser(q);
    try account.rateLimit(q, "upload", 120, 3600_000);
    return q.json(try media.createUpload(&q.r, q.user(), try q.bodyObj()));
}

fn putChunk(q: *Req) !void {
    try auth.requireUser(q);
    const r = &q.r;
    // express.raw: any content type, the body as bytes.
    if (!q.hasBody()) return r.fail(400, "Send the chunk as the raw request body", null);
    const data = if (q.body_read and q.raw != null) q.raw.? else try q.rawBody(@intCast(media.CHUNK + 1024));
    const id = try v.reqId(r, q.pv("id"), "id");
    try media.putChunk(r, q.user(), .{ .id = id }, v.toNumber(q.pv("n")), data);
    return q.json(.{ .ok = true });
}

fn complete(q: *Req) !void {
    try auth.requireUser(q);
    const done_ = try media.completeUpload(&q.r, q.user(), .{ .id = try v.reqId(&q.r, q.pv("id"), "id") }, try q.bodyObj());
    return q.json(.{ .media = try media.describe(&q.r, done_) });
}

fn readable(q: *Req) !Val {
    const r = &q.r;
    const doc = try col().media.findOne(r.a, .{ ._id = try v.reqId(r, q.pv("id"), "id") }, .{});
    try r.ensure(try media.canRead(r, q.user(), doc), "File not found", 404, null);
    return doc.?;
}

fn getMedia(q: *Req) !void {
    try auth.requireUser(q);
    return q.json(.{ .media = try media.describe(&q.r, try readable(q)) });
}

fn content(q: *Req) !void {
    try auth.requireUser(q);
    const doc = try readable(q);
    return media.stream(q, doc, if (q.query("download")) |d| std.mem.eql(u8, d, "1") else false);
}

/// One stored chunk (encrypted files are decrypted chunk by chunk on the device).
fn getChunk(q: *Req) !void {
    try auth.requireUser(q);
    const r = &q.r;
    const doc = try readable(q);
    const n = try v.reqInt(r, q.pv("n"), "n", .{ .min = 0, .max = @floatFromInt((doc.get("chunks").asInt() orelse 0) - 1) });
    const data = (try media.readChunk(r, doc, n)) orelse return r.fail(404, "Chunk not found", null);
    try q.setHeader("cache-control", "private, max-age=31536000, immutable");
    try q.setHeader("x-content-type-options", "nosniff");
    return q.send(200, "application/octet-stream", data);
}

/// GET /m/:id?e=…&s=…: signed file links (and public avatars without a signature).
pub fn signedFile(q: *Req) !void {
    const r = &q.r;
    const id = try v.reqId(r, q.pv("id"), "id");
    const doc = try col().media.findOne(r.a, .{ ._id = id }, .{});
    var allowed = false;
    if (doc) |d| {
        allowed = std.mem.eql(u8, d.get("status").asStr() orelse "", "ready") and (d.get("public").truthy() or try media.checkSignature(r, &id.toHex(), q.query("e"), q.query("s")));
        if (!allowed) {
            // Fall back to the session cookie (the Reseal app itself).
            const t = auth.tokenFromRequest(q);
            if (t.token) |tok| if (tok.len > 0) if (auth.resolveToken(r, tok) catch null) |au| {
                allowed = try media.canRead(r, au.user, d);
            };
        }
    }
    if (!allowed) return q.send(404, "text/plain; charset=utf-8", "Not found");
    if (q.header("if-none-match")) |inm| if (std.mem.eql(u8, inm, try r.fmt("\"{s}\"", .{&id.toHex()}))) return q.end(304);
    return media.stream(q, doc.?, if (q.query("download")) |d| std.mem.eql(u8, d, "1") else false);
}

fn config(q: *Req) !void {
    const a = q.r.a;
    const cfg = &A.app.config;
    const L = A.Limits;
    return q.json(.{
        .publicUrl = cfg.public_url,
        .authHost = cfg.auth_host,
        .mapsUrl = cfg.maps_url,
        .limits = .{
            .textLength = L.text_length,         .captionLength = L.caption_length,       .groupMembers = L.group_members,
            .encryptedGroupMembers = L.encrypted_group_members, .pinnedChats = L.pinned_chats, .folders = L.folders,
            .savedChats = L.saved_chats,         .stories = L.stories,                    .pinnedStories = L.pinned_stories,
            .storyViewers = L.story_viewers,     .storyHours = L.story_hours,             .pollOptions = L.poll_options,
            .editWindowMs = L.edit_window_ms,    .uploadChunkBytes = L.upload_chunk_bytes, .maxUploadBytes = cfg.max_upload_bytes,
        },
        .push = if (push.pushEnabled()) try val.from(a, .{ .vapidPublicKey = cfg.vapid_public }) else Val.null,
        .ai = .{ .platformKey = cfg.openrouter_key.len > 0 },
        .version = "1.0.0",
    });
}

fn ice(q: *Req) !void {
    try auth.requireUser(q);
    return q.json(.{ .iceServers = try calls.iceServers(q.r.a, try q.r.str(q.user().get("_id"))) });
}

fn callHistory(q: *Req) !void {
    try auth.requireUser(q);
    const lim = v.toNumber(q.qv("limit"));
    const limit: i64 = if (std.math.isFinite(lim) and lim != 0) v.clampInt(lim) else 50;
    return q.json(.{ .calls = try calls.history(&q.r, q.user(), q.query("before"), limit) });
}

fn models(q: *Req) !void {
    try auth.requireUser(q);
    return q.json(.{ .models = try ai.listModels(&q.r) });
}

fn linkPreview(q: *Req) !void {
    try auth.requireUser(q);
    try account.rateLimit(q, "preview", 60, 60_000);
    const r = &q.r;
    const url = try v.reqStr(r, q.qv("url"), "url", .{ .max = 2048, .pattern = httpUrl });
    const p = try preview.linkPreview(r, url);
    if (p.get("image").truthy()) {
        // Images load through Reseal so the linked site never sees the reader's address.
        const img = p.get("image").str;
        const sig = try A.hmacHex(r.a, &A.app.config.sign_key, try r.fmt("img:{s}", .{img}));
        try p.set(r.a, "imageProxy", try r.fmt("/api/link-preview/image?u={s}&s={s}", .{ try web.encodeComponent(r.a, img), sig[0..24] }));
    }
    return q.json(.{ .preview = p });
}

fn httpUrl(s: []const u8) bool {
    return (s.len >= 7 and std.ascii.eqlIgnoreCase(s[0..7], "http://")) or (s.len >= 8 and std.ascii.eqlIgnoreCase(s[0..8], "https://"));
}

fn previewImage(q: *Req) !void {
    const r = &q.r;
    const u = q.query("u") orelse "";
    const s = q.query("s") orelse "";
    const want = try A.hmacHex(r.a, &A.app.config.sign_key, try r.fmt("img:{s}", .{u}));
    if (u.len == 0 or !A.safeEqual(want[0..24], s)) return q.end(404);
    fetch.assertPublicUrl(u) catch return q.end(404);
    const res = fetch.fetch(r.a, u, .{ .timeout_ms = 8000, .follow = true, .user_agent = "ResealBot/1.0", .max_bytes = 3 * 1024 * 1024 }) catch |e| {
        if (e == error.ResponseTooLarge) return q.end(413);
        return q.end(404);
    };
    const ct = res.content_type;
    const ok_type = for ([_][]const u8{ "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif" }) |t| {
        if (std.mem.startsWith(u8, ct, t)) break true;
    } else false;
    if (res.status < 200 or res.status >= 300 or !ok_type) return q.end(404);
    try q.setHeader("cache-control", "public, max-age=86400");
    try q.setHeader("x-content-type-options", "nosniff");
    try q.setHeader("content-security-policy", "default-src 'none'");
    return q.send(200, ct, res.body);
}
