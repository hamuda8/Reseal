//! Reseal end-to-end encryption: a byte-exact port of the web client's crypto.js (Reseal-js
//! public/js/crypto.js) on std.crypto only. Messages, chat-key wraps, backups and files made by
//! either side open on the other (see the tests, whose vectors come from crypto.js itself, and
//! tools/e2ee-verify.mjs for the other direction).
//!
//! Identity: two P-256 key pairs per account, `enc` (ECDH, receives chat keys) and `sig` (ECDSA
//! P-256/SHA-256, signs messages, wraps and call offers). Public keys travel as base64 of the
//! uncompressed SEC1 point (WebCrypto "raw"), private keys as base64 PKCS#8 (WebCrypto "pkcs8"),
//! signatures as base64 of r||s (WebCrypto's IEEE P1363 form).
//!
//! Chat keys: AES-256-GCM, wrapped per member with ECIES (ephemeral ECDH, HKDF-SHA256 with the
//! ephemeral public key as salt, AES-GCM), signed by the wrapper.
//! Messages: JSON padded to 128-byte blocks (ISO 7816-4), a key per message (HKDF of the chat key,
//! random salt), AES-GCM with a binding AAD, signed by the sender.
//! Files: a fresh AES-256-GCM key per file, chunk by chunk, each chunk with its own IV.
//!
//! Every function that needs randomness takes a `std.Random` (the app passes its CSPRNG).

const std = @import("std");
const crypto = std.crypto;
const P256 = crypto.ecc.P256;
const Ecdsa = crypto.sign.ecdsa.EcdsaP256Sha256;
const Aes = crypto.aead.aes_gcm.Aes256Gcm;
const Hkdf = crypto.kdf.hkdf.HkdfSha256;
const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = crypto.hash.sha2.Sha256;
const Allocator = std.mem.Allocator;

pub const pbkdf2_iterations: u32 = 600_000;

pub const Error = error{ BadKey, BadData, Decrypt, BadSignature, OutOfMemory, WrongPasscode, WrongRecoveryKey, BadRecoveryKey };

// ---------------------------------------------------------------------------------------------
// Base64 (standard with padding out; standard or URL-safe, with or without padding, in)

pub fn toB64(a: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

/// Like crypto.js fromB64: accepts "-" and "_" and missing padding.
pub fn fromB64(a: Allocator, s: []const u8) Error![]u8 {
    var clean = try a.alloc(u8, s.len + 3);
    var n: usize = 0;
    for (s) |c| {
        clean[n] = switch (c) {
            '-' => '+',
            '_' => '/',
            '=' => continue,
            ' ', '\n', '\r', '\t' => continue,
            else => c,
        };
        n += 1;
    }
    while (n % 4 != 0) : (n += 1) clean[n] = '=';
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(clean[0..n]) catch return error.BadData;
    const out = try a.alloc(u8, size);
    dec.decode(out, clean[0..n]) catch return error.BadData;
    return out;
}

fn fromB64Fixed(comptime N: usize, a: Allocator, s: []const u8) Error![N]u8 {
    const b = try fromB64(a, s);
    if (b.len != N) return error.BadData;
    return b[0..N].*;
}

pub fn random(rng: std.Random, comptime n: usize) [n]u8 {
    var b: [n]u8 = undefined;
    rng.bytes(&b);
    return b;
}

// ---------------------------------------------------------------------------------------------
// Padding

fn pad(a: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const len = ((bytes.len + 1 + 127) / 128) * 128;
    const out = try a.alloc(u8, len);
    @memset(out, 0);
    @memcpy(out[0..bytes.len], bytes);
    out[bytes.len] = 0x80;
    return out;
}

fn unpad(bytes: []const u8) Error![]const u8 {
    var i = bytes.len;
    while (i > 0 and bytes[i - 1] == 0) i -= 1;
    if (i == 0 or bytes[i - 1] != 0x80) return error.BadData;
    return bytes[0 .. i - 1];
}

// ---------------------------------------------------------------------------------------------
// AES-GCM as WebCrypto does it: ciphertext || 16-byte tag

pub fn seal(a: Allocator, key: [32]u8, iv: [12]u8, ad: []const u8, plain: []const u8) Allocator.Error![]u8 {
    const out = try a.alloc(u8, plain.len + Aes.tag_length);
    Aes.encrypt(out[0..plain.len], out[plain.len..][0..Aes.tag_length], plain, ad, iv, key);
    return out;
}

pub fn open(a: Allocator, key: [32]u8, iv: [12]u8, ad: []const u8, sealed: []const u8) Error![]u8 {
    if (sealed.len < Aes.tag_length) return error.Decrypt;
    const n = sealed.len - Aes.tag_length;
    const out = try a.alloc(u8, n);
    Aes.decrypt(out, sealed[0..n], sealed[n..][0..Aes.tag_length].*, ad, iv, key) catch return error.Decrypt;
    return out;
}

fn hkdf(ikm: []const u8, salt: []const u8, info: []const u8) [32]u8 {
    const prk = Hkdf.extract(salt, ikm);
    var out: [32]u8 = undefined;
    Hkdf.expand(&out, info, prk);
    return out;
}

// ---------------------------------------------------------------------------------------------
// Identity keys

pub const Identity = struct {
    enc_secret: [32]u8,
    sig_secret: [32]u8,
    enc_public: [65]u8,
    sig_public: [65]u8,

    pub fn encPublicB64(id: Identity, a: Allocator) ![]u8 {
        return toB64(a, &id.enc_public);
    }
    pub fn sigPublicB64(id: Identity, a: Allocator) ![]u8 {
        return toB64(a, &id.sig_public);
    }
};

fn randomScalar(rng: std.Random) [32]u8 {
    while (true) {
        const s = random(rng, 32);
        P256.scalar.rejectNonCanonical(s, .big) catch continue;
        if (std.mem.allEqual(u8, &s, 0)) continue;
        return s;
    }
}

fn publicOf(secret: [32]u8) Error![65]u8 {
    const p = P256.basePoint.mul(secret, .big) catch return error.BadKey;
    return p.toUncompressedSec1();
}

pub fn generateIdentity(rng: std.Random) Identity {
    const e = randomScalar(rng);
    const s = randomScalar(rng);
    return .{ .enc_secret = e, .sig_secret = s, .enc_public = publicOf(e) catch unreachable, .sig_public = publicOf(s) catch unreachable };
}

// PKCS#8 for a P-256 key, as WebCrypto exports it (Chrome, Node, Firefox):
// SEQUENCE { INTEGER 0, SEQUENCE { OID ecPublicKey, OID prime256v1 },
//            OCTET STRING { SEQUENCE { INTEGER 1, OCTET STRING d, [1] { BIT STRING point } } } }
const pkcs8_head = [_]u8{ 0x30, 0x81, 0x87, 0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x04, 0x6d, 0x30, 0x6b, 0x02, 0x01, 0x01, 0x04, 0x20 };
const pkcs8_mid = [_]u8{ 0xa1, 0x44, 0x03, 0x42, 0x00 };

pub fn pkcs8Encode(secret: [32]u8, public: [65]u8) [138]u8 {
    var out: [138]u8 = undefined;
    @memcpy(out[0..36], &pkcs8_head);
    @memcpy(out[36..68], &secret);
    @memcpy(out[68..73], &pkcs8_mid);
    @memcpy(out[73..138], &public);
    return out;
}

/// The private scalar of a PKCS#8 P-256 key (with or without the optional parameters and
/// public key fields).
pub fn pkcs8Decode(der: []const u8) Error![32]u8 {
    var r: Der = .{ .b = der };
    var outer = try r.enter(0x30);
    _ = try outer.next(0x02); // version
    _ = try outer.next(0x30); // algorithm (checked loosely: the curve is in the key's length)
    const inner_bytes = try outer.next(0x04);
    var ir: Der = .{ .b = inner_bytes };
    var ec = try ir.enter(0x30);
    _ = try ec.next(0x02); // version 1
    const d = try ec.next(0x04);
    if (d.len > 32) return error.BadKey;
    var s: [32]u8 = @splat(0);
    @memcpy(s[32 - d.len ..], d);
    P256.scalar.rejectNonCanonical(s, .big) catch return error.BadKey;
    return s;
}

const Der = struct {
    b: []const u8,
    i: usize = 0,

    fn next(r: *Der, tag: u8) Error![]const u8 {
        if (r.i + 2 > r.b.len or r.b[r.i] != tag) return error.BadKey;
        r.i += 1;
        var len: usize = r.b[r.i];
        r.i += 1;
        if (len & 0x80 != 0) {
            const n = len & 0x7f;
            if (n == 0 or n > 2 or r.i + n > r.b.len) return error.BadKey;
            len = 0;
            for (0..n) |_| {
                len = (len << 8) | r.b[r.i];
                r.i += 1;
            }
        }
        if (r.i + len > r.b.len) return error.BadKey;
        defer r.i += len;
        return r.b[r.i .. r.i + len];
    }

    fn enter(r: *Der, tag: u8) Error!Der {
        return .{ .b = try r.next(tag) };
    }
};

/// The private keys as crypto.js's backups carry them: {"enc","sig","encPublic","sigPublic"}.
pub fn bundleJson(a: Allocator, id: Identity) Allocator.Error![]u8 {
    const enc = try toB64(a, &pkcs8Encode(id.enc_secret, id.enc_public));
    const sig = try toB64(a, &pkcs8Encode(id.sig_secret, id.sig_public));
    return std.fmt.allocPrint(a, "{{\"enc\":\"{s}\",\"sig\":\"{s}\",\"encPublic\":\"{s}\",\"sigPublic\":\"{s}\"}}", .{ enc, sig, try toB64(a, &id.enc_public), try toB64(a, &id.sig_public) });
}

pub const Bundle = struct { enc: []const u8, sig: []const u8, encPublic: []const u8 = "", sigPublic: []const u8 = "" };

pub fn identityFromBundle(a: Allocator, json: []const u8) Error!Identity {
    const b = std.json.parseFromSliceLeaky(Bundle, a, json, .{ .ignore_unknown_fields = true }) catch return error.BadData;
    const e = try pkcs8Decode(try fromB64(a, b.enc));
    const s = try pkcs8Decode(try fromB64(a, b.sig));
    return .{ .enc_secret = e, .sig_secret = s, .enc_public = try publicOf(e), .sig_public = try publicOf(s) };
}

// ---------------------------------------------------------------------------------------------
// Backups: passcode (PBKDF2), recovery key (HKDF), escrow (a random key kept by the server)

const backup_aad = "reseal/backup/v1";
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// A key box: {"v":1,"kdf":...,"iter":...,"salt":...,"iv":...,"ct":...}.
pub const Box = struct {
    v: i64 = 1,
    kdf: []const u8 = "",
    iter: u32 = pbkdf2_iterations,
    salt: []const u8 = "",
    iv: []const u8,
    ct: []const u8,
};

fn sealBundle(a: Allocator, rng: std.Random, key: [32]u8, bundle: []const u8) Allocator.Error!struct { iv: []u8, ct: []u8 } {
    const iv = random(rng, 12);
    return .{ .iv = try toB64(a, &iv), .ct = try toB64(a, try seal(a, key, iv, backup_aad, bundle)) };
}

fn openBundle(a: Allocator, key: [32]u8, box: Box) Error!Identity {
    const plain = try open(a, key, try fromB64Fixed(12, a, box.iv), backup_aad, try fromB64(a, box.ct));
    return identityFromBundle(a, plain);
}

/// NFKC as far as passcodes need it: full-width ASCII and the ideographic space become ASCII.
/// (crypto.js normalizes with String.normalize('NFKC'); other compatibility characters are kept
/// as they are, which only matters for passcodes that contain them.)
fn nfkcLite(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = (std.unicode.Utf8View.init(s) catch return a.dupe(u8, s)).iterator();
    while (it.nextCodepoint()) |cp| {
        const c: u21 = if (cp >= 0xFF01 and cp <= 0xFF5E) cp - 0xFF01 + 0x21 else if (cp == 0x3000) ' ' else cp;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &buf) catch continue;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.items;
}

fn passcodeKey(a: Allocator, passcode: []const u8, salt: []const u8, iterations: u32) Error![32]u8 {
    var key: [32]u8 = undefined;
    crypto.pwhash.pbkdf2(&key, try nfkcLite(a, passcode), salt, iterations, HmacSha256) catch return error.BadData;
    return key;
}

fn recoveryKeyFromBytes(raw: []const u8, salt: []const u8) [32]u8 {
    return hkdf(raw, salt, "reseal/recovery/v1");
}

pub fn formatRecovery(a: Allocator, raw: [30]u8) Allocator.Error![]u8 {
    var chars: [48]u8 = undefined;
    var acc: u32 = 0;
    var bits: u5 = 0;
    var n: usize = 0;
    for (raw) |b| {
        acc = (acc << 8) | b;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            chars[n] = crockford[(acc >> bits) & 31];
            n += 1;
        }
        acc &= (@as(u32, 1) << bits) - 1;
    }
    var out: std.ArrayList(u8) = .empty;
    for (chars, 0..) |c, i| {
        if (i > 0 and i % 4 == 0) try out.append(a, '-');
        try out.append(a, c);
    }
    return out.items;
}

pub fn parseRecovery(text: []const u8) Error![30]u8 {
    var vals: [48]u8 = undefined;
    var n: usize = 0;
    for (text) |c0| {
        var c = std.ascii.toUpper(c0);
        if (!std.ascii.isAlphanumeric(c)) continue;
        if (c == 'O') c = '0';
        if (c == 'I' or c == 'L') c = '1';
        if (n >= 48) return error.BadRecoveryKey;
        vals[n] = @intCast(std.mem.indexOfScalar(u8, crockford, c) orelse return error.BadRecoveryKey);
        n += 1;
    }
    if (n != 48) return error.BadRecoveryKey;
    var out: [30]u8 = undefined;
    var acc: u32 = 0;
    var bits: u5 = 0;
    var o: usize = 0;
    for (vals) |v| {
        acc = (acc << 5) | v;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            out[o] = @truncate(acc >> bits);
            o += 1;
            acc &= (@as(u32, 1) << bits) - 1;
        }
    }
    return out;
}

fn boxJson(a: Allocator, kdf: []const u8, iter: ?u32, salt: ?[]const u8, iv: []const u8, ct: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{{\"v\":1,\"kdf\":\"{s}\"", .{kdf});
    if (iter) |i| try out.print(a, ",\"iter\":{d}", .{i});
    if (salt) |s| try out.print(a, ",\"salt\":\"{s}\"", .{s});
    try out.print(a, ",\"iv\":\"{s}\",\"ct\":\"{s}\"}}", .{ iv, ct });
    return out.items;
}

/// The passcode box (JSON) for these keys.
pub fn passcodeBackup(a: Allocator, rng: std.Random, id: Identity, passcode: []const u8, iterations: u32) Error![]u8 {
    const salt = random(rng, 16);
    const key = try passcodeKey(a, passcode, &salt, iterations);
    const s = try sealBundle(a, rng, key, try bundleJson(a, id));
    return boxJson(a, "pbkdf2-sha256", iterations, try toB64(a, &salt), s.iv, s.ct);
}

pub const RecoveryBackup = struct { box: []u8, key: []u8 };

/// The recovery box (JSON) and the 48-character key to show once.
pub fn recoveryBackup(a: Allocator, rng: std.Random, id: Identity) Error!RecoveryBackup {
    const raw = random(rng, 30);
    const salt = random(rng, 16);
    const s = try sealBundle(a, rng, recoveryKeyFromBytes(&raw, &salt), try bundleJson(a, id));
    return .{ .box = try boxJson(a, "hkdf-sha256", null, try toB64(a, &salt), s.iv, s.ct), .key = try formatRecovery(a, raw) };
}

pub const EscrowBackup = struct { box: []u8, key: []u8 };

/// Automatic backup: the box (JSON) and its random key (base64), stored apart by the server.
pub fn escrowBackup(a: Allocator, rng: std.Random, id: Identity) Error!EscrowBackup {
    const raw = random(rng, 32);
    const s = try sealBundle(a, rng, raw, try bundleJson(a, id));
    return .{ .box = try boxJson(a, "escrow", null, null, s.iv, s.ct), .key = try toB64(a, &raw) };
}

pub fn unlockWithEscrow(a: Allocator, box: Box, escrow_key_b64: []const u8) Error!Identity {
    return openBundle(a, try fromB64Fixed(32, a, escrow_key_b64), box);
}

pub fn unlockWithPasscode(a: Allocator, box: Box, passcode: []const u8) Error!Identity {
    const key = try passcodeKey(a, passcode, try fromB64(a, box.salt), box.iter);
    return openBundle(a, key, box) catch |e| return if (e == error.Decrypt) error.WrongPasscode else e;
}

pub fn unlockWithRecovery(a: Allocator, box: Box, text: []const u8) Error!Identity {
    const raw = try parseRecovery(text);
    return openBundle(a, recoveryKeyFromBytes(&raw, try fromB64(a, box.salt)), box) catch |e| return if (e == error.Decrypt) error.WrongRecoveryKey else e;
}

pub fn parseBox(a: Allocator, json: []const u8) Error!Box {
    return std.json.parseFromSliceLeaky(Box, a, json, .{ .ignore_unknown_fields = true }) catch error.BadData;
}

// ---------------------------------------------------------------------------------------------
// Safety numbers

pub const safety_emoji = [_][]const u8{ "🐶", "🐱", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔", "🐧", "🐦", "🦉", "🐴", "🦄", "🐝", "🦋", "🐢", "🐙", "🐬", "🐳", "🌵", "🌲", "🌻", "🍀", "🍄", "🌙", "⭐", "🔥", "🌈", "❄️", "🌊", "🍎", "🍋", "🍉", "🍇", "🍓", "🥑", "🥕", "🌽", "🍕", "🍩", "🎂", "☕", "⚽", "🏀", "🎸", "🎲", "🚀", "✈️", "🚲", "⛵", "🏠", "⏰", "💡", "🔑", "🎁", "📚", "✏️", "🎈", "🔔" };

pub fn fingerprint(a: Allocator, enc_b64: []const u8, sig_b64: []const u8) Error![32]u8 {
    var h = Sha256.init(.{});
    h.update(try fromB64(a, enc_b64));
    h.update(try fromB64(a, sig_b64));
    return h.finalResult();
}

pub const Safety = struct { groups: [12][5]u8, emoji: [8][]const u8 };

pub fn safetyNumber(a: Allocator, a_enc: []const u8, a_sig: []const u8, b_enc: []const u8, b_sig: []const u8) Error!Safety {
    const fa = try fingerprint(a, a_enc, a_sig);
    const fb = try fingerprint(a, b_enc, b_sig);
    // crypto.js sorts the base64 forms as strings.
    const first_a = std.mem.lessThan(u8, try toB64(a, &fa), try toB64(a, &fb));
    var h = Sha256.init(.{});
    h.update("reseal/safety/v1");
    h.update(if (first_a) &fa else &fb);
    h.update(if (first_a) &fb else &fa);
    const d = h.finalResult();
    var out: Safety = undefined;
    for (0..12) |i| {
        const n = ((@as(u32, d[i * 2]) << 16) | (@as(u32, d[i * 2 + 1]) << 8) | d[(i * 2 + 2) % 32]) % 100000;
        _ = std.fmt.bufPrint(&out.groups[i], "{d:0>5}", .{n}) catch unreachable;
    }
    for (0..8) |i| out.emoji[i] = safety_emoji[d[24 + i] % safety_emoji.len];
    return out;
}

// ---------------------------------------------------------------------------------------------
// Signatures

pub fn sign(a: Allocator, sig_secret: [32]u8, text: []const u8) Error![]u8 {
    const kp = Ecdsa.KeyPair.fromSecretKey(Ecdsa.SecretKey.fromBytes(sig_secret) catch return error.BadKey) catch return error.BadKey;
    const s = kp.sign(text, null) catch return error.BadKey;
    return toB64(a, &s.toBytes());
}

pub fn verify(a: Allocator, sig_public_b64: []const u8, signature_b64: []const u8, text: []const u8) bool {
    const pk_bytes = fromB64(a, sig_public_b64) catch return false;
    const pk = Ecdsa.PublicKey.fromSec1(pk_bytes) catch return false;
    const sig = fromB64Fixed(64, a, signature_b64) catch return false;
    Ecdsa.Signature.fromBytes(sig).verify(text, pk) catch return false;
    return true;
}

// ---------------------------------------------------------------------------------------------
// Chat keys

fn ecdhKey(secret: [32]u8, public: []const u8, salt: []const u8, info: []const u8) Error![32]u8 {
    const p = P256.fromSec1(public) catch return error.BadKey;
    const shared = p.mul(secret, .big) catch return error.BadKey;
    const x = shared.affineCoordinates().x.toBytes(.big);
    return hkdf(&x, salt, info);
}

pub const Wrap = struct { userId: []const u8, eph: []const u8, iv: []const u8, ct: []const u8, sig: []const u8 };

pub fn wrapInfo(a: Allocator, chat_id: []const u8, epoch: i64, user_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "reseal/chatkey/v1|{s}|{d}|{s}", .{ chat_id, epoch, user_id });
}

pub fn wrapSigned(a: Allocator, chat_id: []const u8, epoch: i64, user_id: []const u8, w: Wrap) ![]u8 {
    return std.fmt.allocPrint(a, "reseal/wrap/v1|{s}|{d}|{s}|{s}|{s}|{s}", .{ chat_id, epoch, user_id, w.eph, w.iv, w.ct });
}

/// Wraps a raw chat key for one member, signed by the wrapper.
pub fn wrapChatKey(a: Allocator, rng: std.Random, raw: [32]u8, chat_id: []const u8, epoch: i64, user_id: []const u8, recipient_enc_b64: []const u8, signer: [32]u8) Error!Wrap {
    const u = try wrapChatKeyUnsigned(a, rng, raw, chat_id, epoch, user_id, recipient_enc_b64);
    var w = u.wrap;
    w.sig = try sign(a, signer, u.signed);
    return w;
}

/// A wrap without its signature, and the text to sign (by a key the app cannot read, zui.keys).
pub const UnsignedWrap = struct { wrap: Wrap, signed: []u8 };

pub fn wrapChatKeyUnsigned(a: Allocator, rng: std.Random, raw: [32]u8, chat_id: []const u8, epoch: i64, user_id: []const u8, recipient_enc_b64: []const u8) Error!UnsignedWrap {
    const eph = randomScalar(rng);
    const eph_pub = try publicOf(eph);
    const info = try wrapInfo(a, chat_id, epoch, user_id);
    const key = try ecdhKey(eph, try fromB64(a, recipient_enc_b64), &eph_pub, info);
    const iv = random(rng, 12);
    const w: Wrap = .{ .userId = user_id, .eph = try toB64(a, &eph_pub), .iv = try toB64(a, &iv), .ct = try toB64(a, try seal(a, key, iv, info, &raw)), .sig = "" };
    return .{ .wrap = w, .signed = try wrapSigned(a, chat_id, epoch, user_id, w) };
}

/// Unwraps a chat key addressed to me; a wrap whose signature does not check out is refused.
pub fn unwrapChatKey(a: Allocator, w: Wrap, chat_id: []const u8, epoch: i64, user_id: []const u8, enc_secret: [32]u8, wrapper_sig_b64: []const u8) Error![32]u8 {
    if (!verify(a, wrapper_sig_b64, w.sig, try wrapSigned(a, chat_id, epoch, user_id, w))) return error.BadSignature;
    const info = try wrapInfo(a, chat_id, epoch, user_id);
    const eph = try fromB64(a, w.eph);
    const key = try ecdhKey(enc_secret, eph, eph, info);
    const raw = try open(a, key, try fromB64Fixed(12, a, w.iv), info, try fromB64(a, w.ct));
    if (raw.len != 32) return error.BadKey;
    return raw[0..32].*;
}

// ---------------------------------------------------------------------------------------------
// Messages

/// An encrypted message: {"e":epoch,"s":salt,"iv":...,"ct":...,"sig":...}; v1 envelopes have no salt.
pub const Envelope = struct { e: i64, s: ?[]const u8 = null, iv: []const u8, ct: []const u8, sig: []const u8 = "" };

fn msgAad(a: Allocator, chat_id: []const u8, epoch: i64, sender_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "reseal/msg/v1|{s}|{d}|{s}", .{ chat_id, epoch, sender_id });
}

fn msgSigned(a: Allocator, chat_id: []const u8, sender_id: []const u8, env: Envelope) ![]u8 {
    if (env.s) |salt| return std.fmt.allocPrint(a, "reseal/msgsig/v2|{s}|{d}|{s}|{s}|{s}|{s}", .{ chat_id, env.e, sender_id, salt, env.iv, env.ct });
    return std.fmt.allocPrint(a, "reseal/msgsig/v1|{s}|{d}|{s}|{s}|{s}", .{ chat_id, env.e, sender_id, env.iv, env.ct });
}

/// The key for one message: HKDF(chat key, salt, "reseal/mk/v1|chat|epoch|sender").
pub fn messageKey(a: Allocator, chat_key: [32]u8, chat_id: []const u8, epoch: i64, sender_id: []const u8, salt: []const u8) Allocator.Error![32]u8 {
    return hkdf(&chat_key, salt, try std.fmt.allocPrint(a, "reseal/mk/v1|{s}|{d}|{s}", .{ chat_id, epoch, sender_id }));
}

/// Encrypts and signs a payload (JSON text).
pub fn encryptMessage(a: Allocator, rng: std.Random, chat_key: [32]u8, payload_json: []const u8, chat_id: []const u8, epoch: i64, sender_id: []const u8, signer: [32]u8) Error!Envelope {
    const u = try encryptMessageUnsigned(a, rng, chat_key, payload_json, chat_id, epoch, sender_id);
    var env = u.env;
    env.sig = try sign(a, signer, u.signed);
    return env;
}

/// An envelope without its signature, and the text to sign.
pub const UnsignedEnvelope = struct { env: Envelope, signed: []u8 };

pub fn encryptMessageUnsigned(a: Allocator, rng: std.Random, chat_key: [32]u8, payload_json: []const u8, chat_id: []const u8, epoch: i64, sender_id: []const u8) Error!UnsignedEnvelope {
    const salt = random(rng, 16);
    const key = try messageKey(a, chat_key, chat_id, epoch, sender_id, &salt);
    const iv = random(rng, 12);
    const ct = try seal(a, key, iv, try msgAad(a, chat_id, epoch, sender_id), try pad(a, payload_json));
    const env: Envelope = .{ .e = epoch, .s = try toB64(a, &salt), .iv = try toB64(a, &iv), .ct = try toB64(a, ct) };
    return .{ .env = env, .signed = try msgSigned(a, chat_id, sender_id, env) };
}

pub fn envelopeJson(a: Allocator, env: Envelope) Allocator.Error![]u8 {
    if (env.s) |s| return std.fmt.allocPrint(a, "{{\"e\":{d},\"s\":\"{s}\",\"iv\":\"{s}\",\"ct\":\"{s}\",\"sig\":\"{s}\"}}", .{ env.e, s, env.iv, env.ct, env.sig });
    return std.fmt.allocPrint(a, "{{\"e\":{d},\"iv\":\"{s}\",\"ct\":\"{s}\",\"sig\":\"{s}\"}}", .{ env.e, env.iv, env.ct, env.sig });
}

pub const Decrypted = struct { payload: []const u8, verified: bool };

/// Decrypts a message. `verified` is false when the signature does not match the sender's key
/// (or no key is known).
pub fn decryptMessage(a: Allocator, chat_key: [32]u8, env: Envelope, chat_id: []const u8, sender_id: []const u8, sender_sig_b64: ?[]const u8) Error!Decrypted {
    const key = if (env.s) |s| try messageKey(a, chat_key, chat_id, env.e, sender_id, try fromB64(a, s)) else chat_key;
    const plain = try open(a, key, try fromB64Fixed(12, a, env.iv), try msgAad(a, chat_id, env.e, sender_id), try fromB64(a, env.ct));
    const payload = try unpad(plain);
    const verified = if (sender_sig_b64) |sig| verify(a, sig, env.sig, try msgSigned(a, chat_id, sender_id, env)) else false;
    return .{ .payload = payload, .verified = verified };
}

fn draftAad(a: Allocator, chat_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "reseal/draft/v1|{s}", .{chat_id});
}

/// A draft (only my own devices read it; not signed).
pub fn encryptDraft(a: Allocator, rng: std.Random, chat_key: [32]u8, epoch: i64, payload_json: []const u8, chat_id: []const u8) Error!Envelope {
    const iv = random(rng, 12);
    const ct = try seal(a, chat_key, iv, try draftAad(a, chat_id), try pad(a, payload_json));
    return .{ .e = epoch, .iv = try toB64(a, &iv), .ct = try toB64(a, ct) };
}

pub fn decryptDraft(a: Allocator, chat_key: [32]u8, env: Envelope, chat_id: []const u8) Error![]const u8 {
    const plain = try open(a, chat_key, try fromB64Fixed(12, a, env.iv), try draftAad(a, chat_id), try fromB64(a, env.ct));
    return unpad(plain);
}

// ---------------------------------------------------------------------------------------------
// Files

pub const FileKey = struct { key: [32]u8, iv: [12]u8 };

pub fn newFileKey(rng: std.Random) FileKey {
    return .{ .key = random(rng, 32), .iv = random(rng, 12) };
}

fn chunkIv(base: [12]u8, index: u32) [12]u8 {
    var iv = base;
    const v = std.mem.readInt(u32, iv[8..12], .big) ^ index;
    std.mem.writeInt(u32, iv[8..12], v, .big);
    return iv;
}

fn chunkAad(buf: []u8, index: u32, last: bool) []const u8 {
    return std.fmt.bufPrint(buf, "reseal/file/v1|{d}|{d}", .{ index, @intFromBool(last) }) catch unreachable;
}

pub fn encryptChunk(a: Allocator, fk: FileKey, index: u32, last: bool, data: []const u8) Allocator.Error![]u8 {
    var buf: [48]u8 = undefined;
    return seal(a, fk.key, chunkIv(fk.iv, index), chunkAad(&buf, index, last), data);
}

pub fn decryptChunk(a: Allocator, fk: FileKey, index: u32, last: bool, data: []const u8) Error![]u8 {
    var buf: [48]u8 = undefined;
    return open(a, fk.key, chunkIv(fk.iv, index), chunkAad(&buf, index, last), data);
}

pub fn fileKeyFromB64(a: Allocator, key_b64: []const u8, iv_b64: []const u8) Error!FileKey {
    return .{ .key = try fromB64Fixed(32, a, key_b64), .iv = try fromB64Fixed(12, a, iv_b64) };
}

pub fn sha256Hex(data: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

// ---------------------------------------------------------------------------------------------
// Tests: vectors from crypto.js (tools/e2ee-vectors.mjs)

const testing = std.testing;
const vectors_json = @embedFile("testdata/e2ee_vectors.json");

const Vectors = struct {
    chatId: []const u8,
    aliceId: []const u8,
    bobId: []const u8,
    alice: Bundle,
    bob: Bundle,
    chatKey: []const u8,
    wrap: struct { userId: []const u8, eph: []const u8, iv: []const u8, ct: []const u8, sig: []const u8, epoch: i64 },
    messages: []const struct { payload: std.json.Value, env: Envelope },
    draft: struct { env: Envelope, payload: std.json.Value },
    passcode: []const u8,
    passcodeBox: Box,
    recovery: struct { box: Box, key: []const u8 },
    escrow: struct { box: Box, key: []const u8 },
    safety: struct { groups: []const []const u8, emoji: []const []const u8 },
    fingerprint: []const u8,
    file: struct { key: []const u8, iv: []const u8, chunks: []const []const u8, plain: []const u8, sha256: []const u8 },
    b64: struct { bytes: []const u8, urlsafe: []const u8, urlsafeBytes: []const u8 },
};

fn loadVectors(a: Allocator) !Vectors {
    return std.json.parseFromSliceLeaky(Vectors, a, vectors_json, .{ .ignore_unknown_fields = true });
}

fn testRng() std.Random {
    const S = struct {
        var drbg: std.Random.ChaCha = undefined;
        var ready = false;
    };
    if (!S.ready) {
        S.drbg = std.Random.ChaCha.init(@splat(7));
        S.ready = true;
    }
    return S.drbg.random();
}

fn jsonEql(a: Allocator, expected: std.json.Value, got_text: []const u8) !void {
    const got = try std.json.parseFromSliceLeaky(std.json.Value, a, got_text, .{});
    const e = try std.json.Stringify.valueAlloc(a, expected, .{});
    const g = try std.json.Stringify.valueAlloc(a, got, .{});
    try testing.expectEqualStrings(e, g);
}

test "base64 like crypto.js" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try loadVectors(a);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 250, 251, 252, 253, 254, 255 }, try fromB64(a, v.b64.bytes));
    try testing.expectEqualStrings(v.b64.bytes, try toB64(a, &.{ 0, 1, 2, 250, 251, 252, 253, 254, 255 }));
    try testing.expectEqualSlices(u8, v.b64.urlsafeBytes, try fromB64(a, v.b64.urlsafe));
}

test "identities from crypto.js bundles; PKCS#8 round trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try loadVectors(a);
    const alice = try identityFromBundle(a, try std.json.Stringify.valueAlloc(a, v.alice, .{}));
    try testing.expectEqualStrings(v.alice.encPublic, try alice.encPublicB64(a));
    try testing.expectEqualStrings(v.alice.sigPublic, try alice.sigPublicB64(a));
    // The same PKCS#8 bytes WebCrypto exports.
    try testing.expectEqualStrings(v.alice.enc, try toB64(a, &pkcs8Encode(alice.enc_secret, alice.enc_public)));
    try testing.expectEqualStrings(v.alice.sig, try toB64(a, &pkcs8Encode(alice.sig_secret, alice.sig_public)));
}

test "unwrap a chat key and decrypt messages from crypto.js" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try loadVectors(a);
    const bob = try identityFromBundle(a, try std.json.Stringify.valueAlloc(a, v.bob, .{}));
    const w: Wrap = .{ .userId = v.wrap.userId, .eph = v.wrap.eph, .iv = v.wrap.iv, .ct = v.wrap.ct, .sig = v.wrap.sig };
    const raw = try unwrapChatKey(a, w, v.chatId, v.wrap.epoch, v.bobId, bob.enc_secret, v.alice.sigPublic);
    try testing.expectEqualStrings(v.chatKey, try toB64(a, &raw));
    // A wrap checked against the wrong signer is refused.
    try testing.expectError(error.BadSignature, unwrapChatKey(a, w, v.chatId, v.wrap.epoch, v.bobId, bob.enc_secret, v.bob.sigPublic));

    for (v.messages) |m| {
        const d = try decryptMessage(a, raw, m.env, v.chatId, v.aliceId, v.alice.sigPublic);
        try testing.expect(d.verified);
        try jsonEql(a, m.payload, d.payload);
        // Someone else's key does not verify; another sender id does not decrypt.
        try testing.expect(!(try decryptMessage(a, raw, m.env, v.chatId, v.aliceId, v.bob.sigPublic)).verified);
        try testing.expectError(error.Decrypt, decryptMessage(a, raw, m.env, v.chatId, v.bobId, null));
    }
    try jsonEql(a, v.draft.payload, try decryptDraft(a, raw, v.draft.env, v.chatId));
}

test "open crypto.js backups: passcode, recovery key, escrow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try loadVectors(a);
    const p = try unlockWithPasscode(a, v.passcodeBox, v.passcode);
    try testing.expectEqualStrings(v.alice.encPublic, try p.encPublicB64(a));
    try testing.expectError(error.WrongPasscode, unlockWithPasscode(a, v.passcodeBox, "wrong"));
    const r = try unlockWithRecovery(a, v.recovery.box, v.recovery.key);
    try testing.expectEqualStrings(v.alice.sigPublic, try r.sigPublicB64(a));
    // Lower case, no dashes, O for 0 still parse.
    const loose = try std.ascii.allocLowerString(a, v.recovery.key);
    _ = try unlockWithRecovery(a, v.recovery.box, loose);
    const e = try unlockWithEscrow(a, v.escrow.box, v.escrow.key);
    try testing.expectEqualStrings(v.alice.encPublic, try e.encPublicB64(a));
    try testing.expectEqualSlices(u8, &(try parseRecovery(v.recovery.key)), &(try parseRecovery(try formatRecovery(a, try parseRecovery(v.recovery.key)))));
}

test "safety number, fingerprint and files match crypto.js" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try loadVectors(a);
    const s = try safetyNumber(a, v.alice.encPublic, v.alice.sigPublic, v.bob.encPublic, v.bob.sigPublic);
    const s2 = try safetyNumber(a, v.bob.encPublic, v.bob.sigPublic, v.alice.encPublic, v.alice.sigPublic);
    for (0..12) |i| {
        try testing.expectEqualStrings(v.safety.groups[i], &s.groups[i]);
        try testing.expectEqualStrings(v.safety.groups[i], &s2.groups[i]);
    }
    for (0..8) |i| try testing.expectEqualStrings(v.safety.emoji[i], s.emoji[i]);
    const fp = try fingerprint(a, v.alice.encPublic, v.alice.sigPublic);
    try testing.expectEqualStrings(v.fingerprint, &std.fmt.bytesToHex(fp, .lower));

    const fk = try fileKeyFromB64(a, v.file.key, v.file.iv);
    var plain: std.ArrayList(u8) = .empty;
    for (v.file.chunks, 0..) |c, i| try plain.appendSlice(a, try decryptChunk(a, fk, @intCast(i), i == v.file.chunks.len - 1, try fromB64(a, c)));
    try testing.expectEqualStrings(v.file.plain, plain.items);
    try testing.expectEqualStrings(v.file.sha256, &sha256Hex(plain.items));
    // The chunk index and the "last" flag are bound.
    try testing.expectError(error.Decrypt, decryptChunk(a, fk, 0, true, try fromB64(a, v.file.chunks[0])));
}

test "round trip of everything made here" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rng = testRng();
    const alice = generateIdentity(rng);
    const bob = generateIdentity(rng);
    const raw = random(rng, 32);
    const w = try wrapChatKey(a, rng, raw, "c1", 2, "bob", try bob.encPublicB64(a), alice.sig_secret);
    try testing.expectEqualSlices(u8, &raw, &(try unwrapChatKey(a, w, "c1", 2, "bob", bob.enc_secret, try alice.sigPublicB64(a))));
    const env = try encryptMessage(a, rng, raw, "{\"v\":1,\"t\":\"hi\"}", "c1", 2, "alice", alice.sig_secret);
    const d = try decryptMessage(a, raw, env, "c1", "alice", try alice.sigPublicB64(a));
    try testing.expect(d.verified);
    try testing.expectEqualStrings("{\"v\":1,\"t\":\"hi\"}", d.payload);
    const esc = try escrowBackup(a, rng, alice);
    const back = try unlockWithEscrow(a, try parseBox(a, esc.box), esc.key);
    try testing.expectEqualSlices(u8, &alice.enc_secret, &back.enc_secret);
}

// Prints what this code makes, for tools/e2ee-verify.mjs (crypto.js must open it):
//   zig test src/client/crypto.zig --test-filter "emit vectors"
test "emit vectors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rng = testRng();
    const v = try loadVectors(a);
    // Zig's own identity for Alice (a new one), and Bob from crypto.js receives.
    const zalice = generateIdentity(rng);
    const raw = random(rng, 32);
    const w = try wrapChatKey(a, rng, raw, v.chatId, 5, v.bobId, v.bob.encPublic, zalice.sig_secret);
    const env = try encryptMessage(a, rng, raw, "{\"v\":1,\"t\":\"from Zig ✓ مرحبا\"}", v.chatId, 5, v.aliceId, zalice.sig_secret);
    const draft = try encryptDraft(a, rng, raw, 5, "{\"t\":\"zig draft\"}", v.chatId);
    const pass = try passcodeBackup(a, rng, zalice, "pass ＷＯＲＤ 9", 1500);
    const rec = try recoveryBackup(a, rng, zalice);
    const esc = try escrowBackup(a, rng, zalice);
    const fk = newFileKey(rng);
    const c0 = try encryptChunk(a, fk, 0, false, "zig file, ");
    const c1 = try encryptChunk(a, fk, 1, true, "part two");
    const sn = try safetyNumber(a, try zalice.encPublicB64(a), try zalice.sigPublicB64(a), v.bob.encPublic, v.bob.sigPublic);
    var groups: std.ArrayList(u8) = .empty;
    for (sn.groups, 0..) |g, i| try groups.print(a, "{s}\"{s}\"", .{ if (i == 0) "" else ",", &g });
    std.debug.print("ZIG_VECTORS {{\"alice\":{s},\"chatKey\":\"{s}\",\"epoch\":5,\"wrap\":{{\"userId\":\"{s}\",\"eph\":\"{s}\",\"iv\":\"{s}\",\"ct\":\"{s}\",\"sig\":\"{s}\"}},\"env\":{s},\"draft\":{s},\"passcode\":\"pass ＷＯＲＤ 9\",\"passcodeAscii\":\"pass WORD 9\",\"passcodeBox\":{s},\"recovery\":{{\"box\":{s},\"key\":\"{s}\"}},\"escrow\":{{\"box\":{s},\"key\":\"{s}\"}},\"file\":{{\"key\":\"{s}\",\"iv\":\"{s}\",\"chunks\":[\"{s}\",\"{s}\"]}},\"safety\":[{s}]}}\n", .{
        try bundleJson(a, zalice),                try toB64(a, &raw),       w.userId, w.eph, w.iv, w.ct, w.sig,
        try envelopeJson(a, env),                 try envelopeJson(a, draft), pass,     rec.box, rec.key, esc.box, esc.key,
        try toB64(a, &fk.key),                    try toB64(a, &fk.iv),     try toB64(a, c0), try toB64(a, c1), groups.items,
    });
}
