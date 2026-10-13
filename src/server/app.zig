//! Shared state of the Reseal server and the helpers every module uses: configuration from the
//! same environment variables as Reseal-js (src/config.js), the collections, request-scoped
//! errors (HttpError), server-side secrets and the in-memory rate limits.

const std = @import("std");
const Io = std.Io;
const mongo = @import("mongo");
const env_mod = @import("env");
pub const val = @import("lib/val.zig");
pub const db = @import("lib/db.zig");
pub const Val = val.Val;
pub const ObjectId = val.ObjectId;
pub const Allocator = std.mem.Allocator;

pub const Limits = struct {
    pub const text_length = 8192;
    pub const caption_length = 2048;
    pub const group_members = 200000;
    pub const encrypted_group_members = 1000;
    pub const pinned_chats = 10;
    pub const folders = 20;
    pub const saved_chats = 50;
    pub const stories = 30;
    pub const pinned_stories = 100;
    pub const story_viewers = 2000;
    pub const story_hours = 24;
    pub const poll_options = 12;
    pub const edit_window_ms: i64 = 48 * 3600 * 1000;
    pub const upload_chunk_bytes = 1024 * 1024;
};

pub const Config = struct {
    port: u16,
    public_url: []const u8,
    trust_proxy: bool,
    public_app: bool,
    /// Lowercased Wufour usernames or ids.
    early_access_users: []const []const u8,
    mongo_uri: []const u8,
    db_name: []const u8,
    auth_host: []const u8,
    wufour_internal_key: []const u8,
    maps_url: []const u8,
    moderation_host: []const u8,
    moderation_key: []const u8,
    /// Derived from MASTER_KEY with HKDF, one key per purpose (as config.js).
    enc_key: [32]u8,
    sign_key: [32]u8,
    stun_urls: []const []const u8,
    turn_urls: []const []const u8,
    turn_secret: []const u8,
    max_upload_bytes: i64,
    openrouter_key: []const u8,
    openrouter_url: []const u8,
    vapid_public: []const u8,
    vapid_private: []const u8,
    vapid_subject: []const u8,
    api_rate_limit: i64,
    /// Static files of the web app (Reseal-js's `public` until the new client replaces it).
    public_dir: []const u8,
    allow_private_fetch: bool,
    log_requests: bool,
    listen: []const u8,

    pub fn load(a: Allocator, io: Io, e: *const env_mod.Env) !Config {
        const port = e.int(u16, "PORT", 8000);
        const public_url = std.mem.trimEnd(u8, e.str("PUBLIC_URL", try std.fmt.allocPrint(a, "http://localhost:{d}", .{port})), "/");
        var early: std.ArrayList([]const u8) = .empty;
        for (try list(a, e.get("EARLY_ACCESS_USERS"), &.{})) |u| try early.append(a, try @import("validate.zig").jsLower(a, u));
        const keys = try masterKey(a, io, e);
        const max_mb = std.fmt.parseInt(i64, e.str("MAX_UPLOAD_MB", "2048"), 10) catch 2048;
        const rate: i64 = if (e.get("API_RATE_LIMIT")) |v| (if (std.fmt.parseInt(i64, std.mem.trim(u8, v, " "), 10)) |x| (if (x >= 0) x else 600) else |_| 600) else 600;
        return .{
            .port = port,
            .public_url = public_url,
            .trust_proxy = std.mem.eql(u8, e.str("TRUST_PROXY", ""), "true"),
            .public_app = !std.mem.eql(u8, e.str("PUBLIC_APP", ""), "false"),
            .early_access_users = early.items,
            .mongo_uri = e.str("MONGO_URI", "mongodb://127.0.0.1:27017"),
            .db_name = e.str("DB_NAME", "Reseal"),
            .auth_host = std.mem.trimEnd(u8, e.str("AUTH_HOST", "http://localhost:4000"), "/"),
            .wufour_internal_key = e.str("WUFOUR_INTERNAL_KEY", ""),
            .maps_url = std.mem.trimEnd(u8, e.str("MAPS_URL", "http://localhost:5005"), "/"),
            .moderation_host = std.mem.trimEnd(u8, e.str("MODERATION_HOST", ""), "/"),
            .moderation_key = e.str("MODERATION_API_KEY", ""),
            .enc_key = keys.enc,
            .sign_key = keys.sign,
            .stun_urls = try list(a, e.get("STUN_URLS"), &.{"stun:stun.l.google.com:19302"}),
            .turn_urls = try list(a, e.get("TURN_URLS"), &.{}),
            .turn_secret = e.str("TURN_SECRET", ""),
            .max_upload_bytes = (if (max_mb > 0) max_mb else 2048) * 1024 * 1024,
            .openrouter_key = e.str("OPENROUTER_API_KEY", ""),
            .openrouter_url = std.mem.trimEnd(u8, e.str("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1"), "/"),
            .vapid_public = e.str("VAPID_PUBLIC_KEY", ""),
            .vapid_private = e.str("VAPID_PRIVATE_KEY", ""),
            .vapid_subject = e.str("VAPID_SUBJECT", "mailto:admin@example.com"),
            .api_rate_limit = rate,
            .public_dir = e.str("RESEAL_PUBLIC_DIR", "../Reseal-js/public"),
            .allow_private_fetch = std.mem.eql(u8, e.str("ALLOW_PRIVATE_FETCH", ""), "true"),
            .log_requests = !std.mem.eql(u8, e.str("LOG_REQUESTS", ""), "false"),
            .listen = e.str("LISTEN", "0.0.0.0"),
        };
    }
};

/// A JSON array, or a comma-separated list (config.js `list`).
fn list(a: Allocator, value: ?[]const u8, fallback: []const []const u8) ![]const []const u8 {
    const v = value orelse return fallback;
    if (v.len == 0) return fallback;
    if (val.parseJson(a, v)) |parsed| {
        if (parsed != .arr) return fallback;
        var out: std.ArrayList([]const u8) = .empty;
        for (parsed.items()) |x| try out.append(a, try val.str(a, x));
        return out.items;
    } else |_| {}
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t\r\n");
        if (t.len > 0) try out.append(a, t);
    }
    return out.items;
}

fn masterKey(a: Allocator, io: Io, e: *const env_mod.Env) !struct { enc: [32]u8, sign: [32]u8 } {
    const raw = e.str("MASTER_KEY", "");
    var key: []const u8 = "";
    if (raw.len == 64 and isHex(raw)) {
        const b = try a.alloc(u8, 32);
        _ = try std.fmt.hexToBytes(b, raw);
        key = b;
    } else if (raw.len > 0) key = try lenientBase64(a, raw);
    if (key.len < 32) {
        if (std.mem.eql(u8, e.str("NODE_ENV", ""), "production")) return error.MasterKeyRequired;
        std.log.warn("MASTER_KEY missing or short: using an ephemeral key. Stored AI keys and app tokens will not survive a restart.", .{});
        const b = try a.alloc(u8, 32);
        io.random(b);
        key = b;
    }
    return .{ .enc = derive(key, "reseal:encryption"), .sign = derive(key, "reseal:signing") };
}

fn derive(key: []const u8, label: []const u8) [32]u8 {
    const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
    const prk = Hkdf.extract("", key);
    var out: [32]u8 = undefined;
    Hkdf.expand(&out, label, prk);
    return out;
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// Node's Buffer.from(x, 'base64'): accepts both alphabets, ignores padding and stray characters.
pub fn lenientBase64(a: Allocator, s: []const u8) ![]u8 {
    var bits: u32 = 0;
    var nbits: u5 = 0;
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        const v: u32 = switch (c) {
            'A'...'Z' => c - 'A',
            'a'...'z' => c - 'a' + 26,
            '0'...'9' => c - '0' + 52,
            '+', '-' => 62,
            '/', '_' => 63,
            '=' => break,
            else => continue,
        };
        bits = (bits << 6) | v;
        nbits += 6;
        if (nbits >= 8) {
            nbits -= 8;
            try out.append(a, @truncate(bits >> nbits));
            bits &= (@as(u32, 1) << nbits) - 1;
        }
    }
    return out.items;
}

pub const Cols = struct {
    users: db.Coll,
    sessions: db.Coll,
    chats: db.Coll,
    members: db.Coll,
    messages: db.Coll,
    chatKeys: db.Coll,
    media: db.Coll,
    mediaChunks: db.Coll,
    contacts: db.Coll,
    blocks: db.Coll,
    calls: db.Coll,
    invites: db.Coll,
    folders: db.Coll,
    apps: db.Coll,
    bots: db.Coll,
    pushSubs: db.Coll,
    webhookDeliveries: db.Coll,
    keyRequests: db.Coll,
    keyEscrow: db.Coll,
    stories: db.Coll,
    teams: db.Coll,
    messageTimers: db.Coll,
    settings: db.Coll,
};

pub const App = struct {
    io: Io,
    gpa: Allocator,
    config: Config,
    mongo: *mongo.Client,
    col: Cols,
    client: std.http.Client,
    /// Background tasks (event subscribers, timers, AI replies).
    bg: Io.Group = .init,
    started_ms: i64,
};

/// The one instance; set in main before serving.
pub var app: *App = undefined;

pub fn nowMs() i64 {
    return Io.Timestamp.now(app.io, .real).toMilliseconds();
}

pub fn now() Val {
    return .{ .date = nowMs() };
}

/// Runs `function` as its own task (detached); inline when no task can be started.
pub fn spawn(function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
    app.bg.concurrent(app.io, function, args) catch {
        @call(.auto, function, args);
    };
}

pub fn sleepMs(ms: i64) void {
    app.io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

// ---------------------------------------------------------------------------------------------
// Request scope and HttpError
// ---------------------------------------------------------------------------------------------

pub const Err = struct {
    status: u16,
    message: []const u8,
    code: []const u8,
    /// Extra fields for the error body (moderation warnings).
    extra: ?Val = null,
};

/// What a service call needs: an arena for everything it allocates, and the place an HttpError
/// is recorded before `error.Http` unwinds to the route (JS throws an object; Zig cannot).
pub const Rq = struct {
    a: Allocator,
    err: ?Err = null,

    pub fn fail(r: *Rq, status: u16, message: []const u8, code: ?[]const u8) error{Http} {
        r.err = .{ .status = status, .message = message, .code = code orelse defaultCode(status) };
        return error.Http;
    }

    pub fn failf(r: *Rq, status: u16, code: ?[]const u8, comptime f: []const u8, args: anytype) error{ Http, OutOfMemory } {
        return r.fail(status, try std.fmt.allocPrint(r.a, f, args), code);
    }

    /// `ensure(condition, message, status, code)`
    pub fn ensure(r: *Rq, ok: bool, message: []const u8, status: u16, code: ?[]const u8) error{Http}!void {
        if (!ok) return r.fail(status, message, code);
    }

    pub fn fmt(r: *Rq, comptime f: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(r.a, f, args);
    }

    /// `{ ...x }` helpers shortened.
    pub fn obj(r: *Rq, x: anytype) !Val {
        return val.from(r.a, x);
    }

    pub fn str(r: *Rq, v: Val) ![]const u8 {
        return val.str(r.a, v);
    }

    /// String(x) or null for nullish (serialize.js `s`).
    pub fn sn(r: *Rq, v: Val) !Val {
        return val.sOrNull(r.a, v);
    }
};

pub fn defaultCode(status: u16) []const u8 {
    return switch (status) {
        400 => "bad_request",
        401 => "unauthorized",
        403 => "forbidden",
        404 => "not_found",
        409 => "conflict",
        413 => "too_large",
        429 => "rate_limited",
        else => "error",
    };
}

// ---------------------------------------------------------------------------------------------
// Secrets (src/util/secrets.js)
// ---------------------------------------------------------------------------------------------

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const b64url = std.base64.url_safe_no_pad;

/// Encrypts a short secret for storage: "v1.<iv>.<ciphertext+tag>" (base64url).
pub fn seal(a: Allocator, plaintext: ?[]const u8) !Val {
    const p = plaintext orelse return .null;
    if (p.len == 0) return .null;
    var iv: [12]u8 = undefined;
    app.io.random(&iv);
    const buf = try a.alloc(u8, p.len + 16);
    var tag: [16]u8 = undefined;
    Aes256Gcm.encrypt(buf[0..p.len], &tag, p, "", iv, app.config.enc_key);
    @memcpy(buf[p.len..], &tag);
    var iv_b: [16]u8 = undefined;
    const data_b = try a.alloc(u8, b64url.Encoder.calcSize(buf.len));
    return .{ .str = try std.fmt.allocPrint(a, "v1.{s}.{s}", .{ b64url.Encoder.encode(&iv_b, &iv), b64url.Encoder.encode(data_b, buf) }) };
}

pub fn unseal(a: Allocator, sealed: Val) ?[]const u8 {
    const s = sealed.asStr() orelse return null;
    var it = std.mem.splitScalar(u8, s, '.');
    const v = it.next() orelse return null;
    if (!std.mem.eql(u8, v, "v1")) return null;
    const iv_b = lenientBase64(a, it.next() orelse return null) catch return null;
    const data = lenientBase64(a, it.next() orelse return null) catch return null;
    if (iv_b.len != 12 or data.len < 16) return null;
    const out = a.alloc(u8, data.len - 16) catch return null;
    Aes256Gcm.decrypt(out, data[0 .. data.len - 16], data[data.len - 16 ..][0..16].*, "", iv_b[0..12].*, app.config.enc_key) catch return null;
    return out;
}

pub fn sha256Hex(a: Allocator, value: []const u8) ![]const u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

/// A random token with a readable prefix, e.g. rsl_sk_…
pub fn randomToken(a: Allocator, prefix: []const u8, comptime bytes: usize) ![]const u8 {
    var raw: [bytes]u8 = undefined;
    app.io.random(&raw);
    var enc: [b64url.Encoder.calcSize(bytes)]u8 = undefined;
    return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, b64url.Encoder.encode(&enc, &raw) });
}

pub fn randomCode(a: Allocator, length: usize) ![]const u8 {
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
    const out = try a.alloc(u8, length);
    var n: usize = 0;
    while (n < length) {
        var bytes: [64]u8 = undefined;
        app.io.random(&bytes);
        for (bytes) |byte| {
            // Rejection sampling keeps every character equally likely.
            if (byte < 256 - (256 % alphabet.len) and n < length) {
                out[n] = alphabet[byte % alphabet.len];
                n += 1;
            }
        }
    }
    return out;
}

pub fn hmacHex(a: Allocator, key: []const u8, data: []const u8) ![]const u8 {
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, data, key);
    return a.dupe(u8, &std.fmt.bytesToHex(mac, .lower));
}

pub fn safeEqual(x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return false;
    var diff: u8 = 0;
    for (x, y) |p, q| diff |= p ^ q;
    return diff == 0;
}

/// Last four characters of a secret, for display.
pub fn hint(a: Allocator, secret: ?[]const u8) !Val {
    const s = secret orelse return .null;
    if (s.len == 0) return .null;
    return .{ .str = try std.fmt.allocPrint(a, "…{s}", .{s[s.len - @min(4, s.len) ..]}) };
}

pub fn randomUuid(buf: *[36]u8) []const u8 {
    var b: [16]u8 = undefined;
    app.io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = std.fmt.bytesToHex(b, .lower);
    _ = std.fmt.bufPrint(buf, "{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] }) catch unreachable;
    return buf;
}

pub fn newId() ObjectId {
    return ObjectId.generate(app.io);
}

// ---------------------------------------------------------------------------------------------
// Rate limits (src/util/ratelimit.js): token buckets in memory
// ---------------------------------------------------------------------------------------------

const Bucket = struct { tokens: f64, at: i64 };
var buckets_lock: Io.Mutex = .init;
var buckets: std.StringHashMapUnmanaged(Bucket) = .empty;
var buckets_swept: i64 = 0;

/// Allow `max` actions per `window_ms` for a key; short bursts are fine, floods are not.
pub fn allow(key: []const u8, max: f64, window_ms: f64) bool {
    buckets_lock.lockUncancelable(app.io);
    defer buckets_lock.unlock(app.io);
    const t = nowMs();
    if (t - buckets_swept > 600_000) {
        buckets_swept = t;
        sweepBuckets(t - 3600_000);
    }
    const gop = buckets.getOrPut(app.gpa, key) catch return true;
    if (!gop.found_existing) {
        gop.key_ptr.* = app.gpa.dupe(u8, key) catch {
            _ = buckets.remove(key);
            return true;
        };
        gop.value_ptr.* = .{ .tokens = max, .at = t };
    }
    const b = gop.value_ptr;
    b.tokens = @min(max, b.tokens + @as(f64, @floatFromInt(t - b.at)) * (max / window_ms));
    b.at = t;
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
}

fn sweepBuckets(cutoff: i64) void {
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(app.gpa);
    var it = buckets.iterator();
    while (it.next()) |e| if (e.value_ptr.at < cutoff) stale.append(app.gpa, e.key_ptr.*) catch {};
    for (stale.items) |k| {
        _ = buckets.remove(k);
        app.gpa.free(k);
    }
}

pub fn limit(r: *Rq, key: []const u8, max: f64, window_ms: f64, message: ?[]const u8) !void {
    if (!allow(key, max, window_ms)) return r.fail(429, message orelse "Slow down a little and try again", "rate_limited");
}

test "lenient base64 and hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("hello", try lenientBase64(a, "aGVsbG8="));
    try std.testing.expectEqualStrings("hello", try lenientBase64(a, "aGVsbG8"));
    try std.testing.expectEqualStrings("…cdef", (try hint(a, "abcdef")).str);
}
