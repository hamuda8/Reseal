//! Content checks through Wufour Moderation (src/services/moderation.js and the shared
//! moderation-client.js), for what the server can read: messages and uploads in chats that are
//! not end-to-end encrypted, and profile content. Encrypted chats are never checked.
//!
//!   layer 1  nothing is saved; the request fails with 422 moderation_blocked and the warning
//!   layer 2  saved with moderation.layer = 2
//!   layer 3  saved as usual
//!
//! When Moderation cannot answer, the request fails closed with 503 moderation_unavailable. When
//! MODERATION_HOST / MODERATION_API_KEY are not set, checks are off.

const std = @import("std");
const A = @import("app.zig");

const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

const UNAVAILABLE = "Content checks are unavailable right now. Please try again in a moment.";

pub fn enabled() bool {
    return A.app.config.moderation_host.len > 0 and A.app.config.moderation_key.len > 0;
}

pub fn stamp(a: std.mem.Allocator, outcome: Val) !Val {
    return val.from(a, .{ .layer = outcome.get("layer"), .reasons = if (outcome.get("reasons").truthy()) outcome.get("reasons") else try Val.array(a), .checkedAt = A.now() });
}

/// The Wufour account behind a Reseal user: Wufour accounts carry wufourId, an app's users
/// (Taazur) carry the Wufour id as externalId.
fn subjectOf(r: *Rq, user: ?Val) !Val {
    const u = user orelse return .null;
    if (u.isNullish()) return .null;
    const id = if (u.get("wufourId").truthy()) u.get("wufourId") else if (u.get("externalId").truthy()) u.get("externalId") else Val{ .str = try r.str(u.get("_id")) };
    const name = if (u.get("displayName").truthy()) u.get("displayName") else if (u.get("username").truthy()) u.get("username") else Val.null;
    return val.from(r.a, .{ .userId = id, .name = name });
}

/// Checks texts ({ field: value }) and images ([{ id, bytes }]). Returns { layer, reasons,
/// warning } for layers 2 and 3; fails with 422 for layer 1 and 503 when Moderation is down.
pub fn check(r: *Rq, user: ?Val, context: Val, texts: Val, images: ?[]const struct { id: []const u8, bytes: []const u8 }) !Val {
    const a = r.a;
    var items = try Val.array(a);
    for (texts.keys(), texts.vals()) |kv_k, kv_v| {
        const t = kv_v.asStr() orelse continue;
        if (@import("validate.zig").jsTrim(t).len == 0) continue;
        try items.push(try val.from(a, .{ .id = kv_k, .kind = "text", .text = t, .field = kv_k }));
    }
    if (images) |list| for (list) |img| {
        const enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(img.bytes.len));
        _ = std.base64.standard.Encoder.encode(enc, img.bytes);
        try items.push(try val.from(a, .{ .id = img.id, .kind = "image", .data = enc, .field = img.id }));
    };
    const allow = try val.from(a, .{ .layer = 3, .reasons = try Val.array(a), .warning = Val.null, .skipped = true });
    if (items.len() == 0 or !enabled()) return allow;

    const host = try std.mem.replaceOwned(u8, a, A.app.config.moderation_host, "://localhost", "://127.0.0.1");
    const body = try val.stringify(a, try val.from(a, .{ .app = "reseal", .subject = try subjectOf(r, user), .context = context, .items = items }));
    const res = A.app.fetch.fetch(a, try r.fmt("{s}/api/v1/check", .{host}), .{
        .method = .POST,
        .body = body,
        .content_type = "application/json",
        .headers = &.{.{ .name = "x-moderation-key", .value = A.app.config.moderation_key }},
        .timeout_ms = 25_000,
    }) catch return r.fail(503, UNAVAILABLE, "moderation_unavailable");
    const json = val.parseJson(a, res.body) catch Val.null;
    const ok = res.status >= 200 and res.status < 300 and json.get("success").truthy();
    if (!ok) {
        if (res.status == 400 or res.status == 413) {
            return r.fail(400, json.get("message").asStr() orelse "The content could not be checked", json.get("code").asStr() orelse "invalid_content");
        }
        return r.fail(503, UNAVAILABLE, "moderation_unavailable");
    }
    const layer = json.get("layer").asInt() orelse 3;
    if (layer == 1) {
        const w = json.get("warning");
        return r.fail(422, w.get("en").asStr() orelse "This content is not allowed on Reseal", "moderation_blocked");
    }
    var reasons = try Val.array(a);
    for (json.get("items").items()) |it| {
        if ((it.get("layer").asInt() orelse 3) >= 3) continue;
        for (it.get("reasons").items()) |reason| {
            var dup = false;
            for (reasons.items()) |x| if (val.same(x, reason)) {
                dup = true;
            };
            if (!dup) try reasons.push(reason);
        }
    }
    return val.from(a, .{ .layer = layer, .reasons = reasons, .warning = json.get("warning"), .result = json });
}
