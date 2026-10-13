//! End-to-end encryption key directory (src/services/keys.js).
//!
//! Messages and files are encrypted on people's devices. The server stores each user's public
//! keys (ECDH and ECDSA P-256), a backup of their private keys (automatic: sealed with a random
//! key kept apart under MASTER_KEY; advanced protection: under a passcode only they know), and for
//! every encrypted chat and key epoch the chat key wrapped for each member. When someone needs a
//! key they do not have, the server records a key request and asks online holders to share it.

const std = @import("std");
const A = @import("app.zig");
const v = @import("validate.zig");
const rt = @import("realtime.zig");
const ec = @import("ec");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

const ROTATE_AFTER_MS: i64 = 7 * 86400_000;
const BACKUP_AAD = "reseal/backup/v1";

fn col() *A.Cols {
    return &A.app.col;
}

fn b64Len(s: []const u8) usize {
    var n: usize = 0;
    var pad: usize = 0;
    for (s) |c| {
        if (c == '=') pad += 1 else n += 1;
    }
    return n * 3 / 4;
}

fn cleanPublicKey(r: *Rq, value: Val, name: []const u8) ![]const u8 {
    const key = try v.reqB64(r, value, name, 100);
    const raw = try A.lenientBase64(r.a, key);
    try r.ensure(raw.len == 65, try r.fmt("{s} must be an uncompressed P-256 public key", .{name}), 400, null);
    return key;
}

fn cleanBackup(r: *Rq, b: Val, name: []const u8) !?Val {
    const a = r.a;
    if (!b.truthy()) return null;
    _ = try v.reqObj(r, b, name);
    const kdf = try v.reqOneOf(r, b.get("kdf"), try r.fmt("{s}.kdf", .{name}), &.{ "pbkdf2-sha256", "hkdf-sha256", "escrow" });
    const ver: Val = if (b.get("v").isNullish()) Val.number(1) else b.get("v");
    return try val.from(a, .{
        .v = try v.reqInt(r, ver, try r.fmt("{s}.v", .{name}), .{ .min = 1, .max = 9 }),
        .kdf = kdf,
        .iter = if (std.mem.eql(u8, kdf, "pbkdf2-sha256")) Val.number(try v.reqInt(r, b.get("iter"), try r.fmt("{s}.iter", .{name}), .{ .min = 200_000, .max = 10_000_000 })) else Val.undef,
        .salt = if (std.mem.eql(u8, kdf, "escrow")) Val.undef else Val{ .str = try v.reqB64(r, b.get("salt"), try r.fmt("{s}.salt", .{name}), 64) },
        .iv = try v.reqB64(r, b.get("iv"), try r.fmt("{s}.iv", .{name}), 32),
        .ct = try v.reqB64(r, b.get("ct"), try r.fmt("{s}.ct", .{name}), 4096),
    });
}

fn cleanEscrowKey(r: *Rq, value: Val) ![]const u8 {
    const key = try v.reqB64(r, value, "escrowKey", 48);
    try r.ensure((try A.lenientBase64(r.a, key)).len == 32, "escrowKey must be 32 bytes", 400, null);
    return key;
}

fn storeEscrowKey(r: *Rq, user_id: Val, key_b64: []const u8) !void {
    const a = r.a;
    _ = try col().keyEscrow.updateOne(a, .{ .userId = user_id }, .{ .@"$set" = .{ .userId = user_id, .keySealed = try A.seal(a, key_b64), .updatedAt = A.now() }, .@"$setOnInsert" = .{ .createdAt = A.now() } }, .{ .upsert = true });
}

/// After keys change: drop old chat keys, ask members to re-share, tell chat partners.
fn afterKeysChanged(r: *Rq, user: Val, first: bool, changed: bool, version: i64) !void {
    const a = r.a;
    if (!first and !changed) return;
    if (changed) _ = try col().chatKeys.deleteMany(a, .{ .userId = user.get("_id") });
    const memberships = try col().members.find(a, .{ .userId = user.get("_id"), .status = "active" }, .{ .projection = .{ .chatId = 1 } });
    var ids: std.ArrayList(Val) = .empty;
    for (memberships) |m| try ids.append(a, m.get("chatId"));
    const chats = try col().chats.find(a, .{ ._id = .{ .@"$in" = ids.items }, .encrypted = true, .deletedAt = .{ .@"$exists" = false } }, .{});
    for (chats) |chat| try requestKeys(r, chat, &.{user.get("_id")}, true);
    if (changed) {
        var cids: std.ArrayList(Val) = .empty;
        for (chats) |c| try cids.append(a, c.get("_id"));
        const peers = try col().members.find(a, .{ .chatId = .{ .@"$in" = cids.items }, .status = "active", .userId = .{ .@"$ne" = user.get("_id") } }, .{ .projection = .{ .userId = 1 } });
        var pids: std.ArrayList(Val) = .empty;
        for (peers) |p| try pids.append(a, p.get("userId"));
        rt.toUsers(a, pids.items, "keys.changed", try val.from(a, .{ .userId = try r.str(user.get("_id")), .version = version }));
    }
}

/// Publishes (or replaces) a user's public keys with their backup.
pub fn publishUserKeys(r: *Rq, user: Val, body: Val) !Val {
    const a = r.a;
    const enc = try cleanPublicKey(r, body.get("enc"), "enc");
    const sig = try cleanPublicKey(r, body.get("sig"), "sig");
    const mode: []const u8 = if (access_eq(body.get("mode"), "advanced")) "advanced" else "standard";
    const standard = std.mem.eql(u8, mode, "standard");
    const backup = try Val.object(a);
    if (standard) if (try cleanBackup(r, body.path("backup.escrow"), "backup.escrow")) |x| try backup.set("escrow", x);
    if (try cleanBackup(r, body.path("backup.passcode"), "backup.passcode")) |x| try backup.set("passcode", x);
    if (try cleanBackup(r, body.path("backup.recovery"), "backup.recovery")) |x| try backup.set("recovery", x);
    if (standard) try r.ensure(backup.get("escrow").truthy() and body.get("escrowKey").truthy(), "A key backup is required", 400, null) else try r.ensure(backup.get("passcode").truthy(), "A passcode backup is required for advanced protection", 400, null);

    const old = user.get("keys");
    const changed = old.get("enc").truthy() and (!access_eq(old.get("enc"), enc) or !access_eq(old.get("sig"), sig));
    // Server-provisioned keys (for someone who had not opened Reseal yet) may be replaced freely.
    if (old.get("enc").truthy() and changed and !body.get("reset").isTrue() and !old.get("provisioned").truthy()) {
        return r.fail(409, "This account already has encryption keys. Restore them instead, or reset them.", "keys_exist");
    }
    const old_version = old.get("version").asInt() orelse 1;
    const keys = try val.from(a, .{ .enc = enc, .sig = sig, .mode = mode, .version = if (changed) old_version + 1 else (if (old.get("version").truthy()) old_version else 1), .updatedAt = A.now(), .backup = backup });
    _ = try col().users.updateOne(a, .{ ._id = user.get("_id") }, .{ .@"$set" = .{ .keys = keys } }, .{});
    if (standard) try storeEscrowKey(r, user.get("_id"), try cleanEscrowKey(r, body.get("escrowKey"))) else _ = try col().keyEscrow.deleteOne(a, .{ .userId = user.get("_id") });
    try user.set("keys", keys);
    try afterKeysChanged(r, user, !old.get("enc").truthy(), changed, keys.get("version").asInt() orelse 1);
    return keys;
}

fn access_eq(x: Val, s: []const u8) bool {
    return x == .str and std.mem.eql(u8, x.str, s);
}

/// Switches protection without changing keys.
pub fn setProtection(r: *Rq, user: Val, body: Val) !void {
    const a = r.a;
    try r.ensure(user.path("keys.enc").truthy(), "Set up encryption first", 400, "no_keys");
    if (access_eq(body.get("mode"), "advanced")) {
        const passcode = (try cleanBackup(r, body.get("passcode"), "passcode")) orelse return r.fail(400, "A passcode backup is required", null);
        const b = try val.from(a, .{ .passcode = passcode });
        if (try cleanBackup(r, body.get("recovery"), "recovery")) |rec| try b.set("recovery", rec);
        _ = try col().users.updateOne(a, .{ ._id = user.get("_id") }, .{ .@"$set" = .{ .@"keys.mode" = "advanced", .@"keys.backup" = b } }, .{});
        _ = try col().keyEscrow.deleteOne(a, .{ .userId = user.get("_id") });
    } else {
        const escrow = try cleanBackup(r, body.get("escrow"), "escrow");
        try r.ensure(escrow != null and body.get("escrowKey").truthy(), "A key backup is required", 400, null);
        _ = try col().users.updateOne(a, .{ ._id = user.get("_id") }, .{ .@"$set" = .{ .@"keys.mode" = "standard", .@"keys.backup" = .{ .escrow = escrow.? } } }, .{});
        try storeEscrowKey(r, user.get("_id"), try cleanEscrowKey(r, body.get("escrowKey")));
    }
}

/// Replaces only the passcode backups (advanced protection).
pub fn updateBackup(r: *Rq, user: Val, body: Val) !void {
    const a = r.a;
    try r.ensure(user.path("keys.enc").truthy(), "Set up encryption first", 400, "no_keys");
    const set = try Val.object(a);
    if (body.get("passcode") != .undef) try set.set("keys.backup.passcode", (try cleanBackup(r, body.get("passcode"), "passcode")) orelse .undef);
    if (body.get("recovery") != .undef) try set.set("keys.backup.recovery", (try cleanBackup(r, body.get("recovery"), "recovery")) orelse .undef);
    try r.ensure(set.len() > 0, "Nothing to update", 400, null);
    _ = try col().users.updateOne(a, .{ ._id = user.get("_id") }, .{ .@"$set" = set }, .{});
}

/// Automatic mode: hands the backup and its key to the signed-in account (a new device).
pub fn restoreEscrow(r: *Rq, user: Val, device: []const u8) !Val {
    const a = r.a;
    const k = user.get("keys");
    try r.ensure(k.get("enc").truthy(), "No encryption keys yet", 404, "no_keys");
    try r.ensure(!access_eq(k.get("mode"), "advanced") and k.path("backup.escrow").truthy(), "This account uses advanced protection. Unlock it with your passcode.", 409, "advanced");
    const row = try col().keyEscrow.findOne(a, .{ .userId = user.get("_id") }, .{});
    const key = if (row) |x| A.unseal(a, x.get("keySealed")) else null;
    try r.ensure(key != null, "The key backup is unavailable", 404, "no_escrow");
    const dev = v.sliceUtf16(device, 200);
    _ = try col().keyEscrow.updateOne(a, .{ ._id = row.?.get("_id") }, .{ .@"$set" = .{ .lastRestoredAt = A.now(), .lastDevice = dev }, .@"$inc" = .{ .restores = 1 } }, .{});
    // Tell the account's other open devices, so an unexpected sign-in is noticed.
    _ = rt.toUser(a, user.get("_id"), "security.restore", try val.from(a, .{ .device = dev, .at = A.now() }));
    return val.from(a, .{ .enc = k.get("enc"), .sig = k.get("sig"), .version = if (k.get("version").truthy()) k.get("version") else Val.number(1), .provisioned = k.get("provisioned").truthy(), .escrow = k.path("backup.escrow"), .escrowKey = key.? });
}

/// Creates keys on the server for someone who has not opened Reseal yet, so people can message
/// them right away. Their device restores the keys on first sign-in (automatic mode).
pub fn provisionKeys(r: *Rq, user: Val) !Val {
    const a = r.a;
    if (user.path("keys.enc").truthy()) return user.get("keys");
    const enc_pair = ec.generate(A.app.io);
    const sig_pair = ec.generate(A.app.io);
    const b64 = std.base64.standard.Encoder;
    const enc_priv = try ec.pkcs8(a, enc_pair);
    const sig_priv = try ec.pkcs8(a, sig_pair);
    const bundle = try val.from(a, .{
        .enc = try b64e(a, enc_priv),
        .sig = try b64e(a, sig_priv),
        .encPublic = try b64e(a, &enc_pair.public),
        .sigPublic = try b64e(a, &sig_pair.public),
    });
    _ = b64;
    // Same box format the browser uses (AES-256-GCM, tag appended, fixed AAD).
    var escrow_key: [32]u8 = undefined;
    A.app.io.random(&escrow_key);
    var iv: [12]u8 = undefined;
    A.app.io.random(&iv);
    const plain = try val.stringify(a, bundle);
    const ct = try a.alloc(u8, plain.len + 16);
    var tag: [16]u8 = undefined;
    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(ct[0..plain.len], &tag, plain, BACKUP_AAD, iv, escrow_key);
    @memcpy(ct[plain.len..], &tag);
    const keys = try val.from(a, .{
        .enc = bundle.get("encPublic"),
        .sig = bundle.get("sigPublic"),
        .mode = "standard",
        .version = 1,
        .provisioned = true,
        .updatedAt = A.now(),
        .backup = .{ .escrow = .{ .v = 1, .kdf = "escrow", .iv = try b64e(a, &iv), .ct = try b64e(a, ct) } },
    });
    const res = try col().users.updateOne(a, .{ ._id = user.get("_id"), .@"keys.enc" = .{ .@"$exists" = false } }, .{ .@"$set" = .{ .keys = keys } }, .{});
    if (res.modified == 0) {
        const fresh = try col().users.findOne(a, .{ ._id = user.get("_id") }, .{});
        return if (fresh) |f| f.get("keys") else .undef;
    }
    try storeEscrowKey(r, user.get("_id"), try b64e(a, &escrow_key));
    try user.set("keys", keys);
    return keys;
}

fn b64e(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    return std.base64.standard.Encoder.encode(out, bytes);
}

/// Marks that an encrypted chat should get a fresh key (someone left, or the key is old).
pub fn markRotation(r: *Rq, chat: Val, reason: []const u8) !void {
    const a = r.a;
    if (!chat.get("encrypted").truthy() or !chat.get("keyEpoch").truthy()) return;
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = .{ .rotationNeeded = true, .rotationReason = reason } }, .{});
    rt.toChat(a, chat.get("_id"), "keys.rotate", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .reason = reason }), null);
}

/// Records that users need keys, and asks online holders to provide them.
pub fn requestKeys(r: *Rq, chat: Val, user_ids: []const Val, all_epochs: bool) !void {
    const a = r.a;
    const epoch_now = chat.get("keyEpoch").asInt() orelse 0;
    if (!chat.get("encrypted").truthy() or epoch_now == 0) return; // the first sender creates epoch 1 for everyone
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = user_ids }, .@"keys.enc" = .{ .@"$exists" = true } }, .{ .projection = .{ ._id = 1 } });
    if (users.len == 0) return;
    const now = A.now();
    var created = try Val.array(a);
    for (users) |u| {
        const have = try col().chatKeys.find(a, .{ .chatId = chat.get("_id"), .userId = u.get("_id") }, .{ .projection = .{ .epoch = 1 } });
        var epoch: i64 = if (all_epochs) 1 else epoch_now;
        while (epoch <= epoch_now) : (epoch += 1) {
            var has = false;
            for (have) |h| if ((h.get("epoch").asInt() orelse -1) == epoch) {
                has = true;
            };
            if (has) continue;
            _ = try col().keyRequests.updateOne(a, .{ .chatId = chat.get("_id"), .userId = u.get("_id"), .epoch = epoch }, .{ .@"$setOnInsert" = .{ .createdAt = now } }, .{ .upsert = true });
            try created.push(try val.from(a, .{ .userId = try r.str(u.get("_id")), .epoch = epoch }));
        }
    }
    if (created.len() > 0) try notifyHolders(r, chat, created);
}

fn notifyHolders(r: *Rq, chat: Val, requests: Val) !void {
    const a = r.a;
    const online = rt.onlineMemberVals(a, chat.get("_id"));
    if (online.len == 0) return;
    var epochs = try Val.array(a);
    for (requests.items()) |q| {
        var dup = false;
        for (epochs.items()) |e| if (e.num == q.get("epoch").num) {
            dup = true;
        };
        if (!dup) try epochs.push(q.get("epoch"));
    }
    var online_ids: std.ArrayList(Val) = .empty;
    for (online) |o| if (v.oid(o)) |x| try online_ids.append(a, .{ .id = x });
    const holders = try col().chatKeys.find(a, .{ .chatId = chat.get("_id"), .epoch = .{ .@"$in" = epochs }, .userId = .{ .@"$in" = online_ids.items } }, .{ .projection = .{ .userId = 1, .epoch = 1 } });
    // In the order holders were found, like the Map in keys.js.
    var seen: std.ArrayList([]const u8) = .empty;
    for (holders) |h| {
        const uid = try r.str(h.get("userId"));
        var dup = false;
        for (seen.items) |x| if (std.mem.eql(u8, x, uid)) {
            dup = true;
        };
        if (dup) continue;
        try seen.append(a, uid);
        var relevant = try Val.array(a);
        for (requests.items()) |q| {
            if (std.mem.eql(u8, q.get("userId").str, uid)) continue;
            var holds = false;
            for (holders) |h2| if (std.mem.eql(u8, try r.str(h2.get("userId")), uid) and (h2.get("epoch").asNum() orelse -1) == q.get("epoch").num) {
                holds = true;
            };
            if (holds) try relevant.push(q);
        }
        if (relevant.len() > 0) _ = rt.toUser(a, .{ .str = uid }, "keys.needed", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .requests = relevant }));
    }
}

/// Wrapped chat keys the caller can unwrap.
pub fn myChatKeys(r: *Rq, chat: Val, user: Val) !Val {
    const a = r.a;
    const rows = try col().chatKeys.find(a, .{ .chatId = chat.get("_id"), .userId = user.get("_id") }, .{ .sort = .{ .epoch = 1 } });
    var out = try Val.array(a);
    for (rows) |x| try out.push(try val.from(a, .{ .epoch = x.get("epoch"), .eph = x.get("eph"), .iv = x.get("iv"), .ct = x.get("ct"), .sig = x.get("sig"), .by = try r.str(x.get("by")), .byVersion = if (x.get("byVersion").truthy()) x.get("byVersion") else Val.number(1), .createdAt = x.get("createdAt") }));
    return out;
}

pub fn cleanWrap(r: *Rq, w: Val, i: usize) !Val {
    _ = try v.reqObj(r, w, try r.fmt("keys[{d}]", .{i}));
    return val.from(r.a, .{
        .userId = Val{ .id = try v.reqId(r, w.get("userId"), "userId") },
        .eph = try cleanPublicKey(r, w.get("eph"), "eph"),
        .iv = try v.reqB64(r, w.get("iv"), "iv", 32),
        .ct = try v.reqB64(r, w.get("ct"), "ct", 128),
        .sig = try v.reqB64(r, w.get("sig"), "sig", 160),
    });
}

/// Stores wrapped chat keys. With rotate this starts the next epoch; otherwise it shares an
/// existing epoch's key with members who lack it.
pub fn storeChatKeys(r: *Rq, chat: Val, member: Val, user: Val, body: Val) !Val {
    const a = r.a;
    try r.ensure(chat.get("encrypted").truthy(), "This chat is not end-to-end encrypted", 400, null);
    try r.ensure(user.path("keys.enc").truthy(), "Set up encryption first", 400, "no_keys");
    const epoch = try v.reqInt(r, body.get("epoch"), "epoch", .{ .min = 1 });
    const list = body.get("keys");
    try r.ensure(list == .arr and list.len() >= 1 and list.len() <= 1000, "keys must be a list of 1 to 1000 items", 400, null);
    var wraps: std.ArrayList(Val) = .empty;
    for (list.items(), 0..) |w, i| try wraps.append(a, try cleanWrap(r, w, i));
    for (wraps.items, 0..) |w, i| for (wraps.items[0..i]) |w2| if (val.same(w.get("userId"), w2.get("userId"))) return r.fail(400, "Each member may appear once", null);

    var wids: std.ArrayList(Val) = .empty;
    for (wraps.items) |w| try wids.append(a, w.get("userId"));
    const active = try col().members.find(a, .{ .chatId = chat.get("_id"), .userId = .{ .@"$in" = wids.items }, .status = "active" }, .{ .projection = .{ .userId = 1 } });
    var valid: std.ArrayList(Val) = .empty;
    for (wraps.items) |w| for (active) |m| if (val.same(m.get("userId"), w.get("userId"))) {
        try valid.append(a, w);
        break;
    };
    const now = A.now();
    const cur_epoch = chat.get("keyEpoch").asInt() orelse 0;
    const rotate = body.get("rotate").truthy();

    if (rotate) {
        try r.ensure(epoch == cur_epoch + 1, "Another device changed the key first. Refresh and try again", 409, "epoch_conflict");
        var self = false;
        for (valid.items) |w| if (val.same(w.get("userId"), user.get("_id"))) {
            self = true;
        };
        try r.ensure(self, "Include a key for yourself", 400, null);
        const ka = chat.get("keyEpochAt");
        const old = ka == .date and A.nowMs() - ka.date > ROTATE_AFTER_MS;
        // A member who never received the current key may also start a new epoch.
        const lacks = cur_epoch != 0 and (try col().chatKeys.findOne(a, .{ .chatId = chat.get("_id"), .epoch = cur_epoch, .userId = user.get("_id") }, .{ .projection = .{ ._id = 1 } })) == null;
        const role = member.get("role").asStr() orelse "";
        const t = chat.get("type").asStr() orelse "";
        const may = cur_epoch == 0 or chat.get("rotationNeeded").truthy() or old or lacks or std.mem.eql(u8, role, "owner") or std.mem.eql(u8, role, "admin") or std.mem.eql(u8, t, "private") or std.mem.eql(u8, t, "saved");
        try r.ensure(may, "Only admins can change the key right now", 403, "no_permission");
        const res = try col().chats.updateOne(a, .{ ._id = chat.get("_id"), .keyEpoch = cur_epoch }, .{ .@"$set" = .{ .keyEpoch = epoch, .keyEpochAt = now, .rotationNeeded = false }, .@"$unset" = .{ .rotationReason = "" } }, .{});
        try r.ensure(res.modified == 1, "Another device changed the key first. Refresh and try again", 409, "epoch_conflict");
    } else {
        try r.ensure(epoch <= cur_epoch, "Unknown key epoch", 400, "bad_epoch");
        const mine = try col().chatKeys.findOne(a, .{ .chatId = chat.get("_id"), .epoch = epoch, .userId = user.get("_id") }, .{ .projection = .{ ._id = 1 } });
        try r.ensure(mine != null, "You do not hold this key", 403, "no_key");
    }

    var stored: i64 = 0;
    const by_version = user.path("keys.version").asInt() orelse 1;
    for (valid.items) |w| {
        const doc = try val.from(a, .{ .chatId = chat.get("_id"), .epoch = epoch, .userId = w.get("userId"), .eph = w.get("eph"), .iv = w.get("iv"), .ct = w.get("ct"), .sig = w.get("sig"), .by = user.get("_id"), .byVersion = by_version, .createdAt = now });
        // Unordered: a key that is already there does not stop the others.
        if (col().chatKeys.insertOne(a, doc)) |_| {
            stored += 1;
        } else |e| if (e != error.DuplicateKey) return e;
    }
    var vids: std.ArrayList(Val) = .empty;
    for (valid.items) |w| try vids.append(a, w.get("userId"));
    _ = try col().keyRequests.deleteMany(a, .{ .chatId = chat.get("_id"), .epoch = epoch, .userId = .{ .@"$in" = vids.items } });
    const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{})) orelse chat;

    if (rotate) {
        rt.toChat(a, chat.get("_id"), "keys.epoch", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .epoch = epoch, .by = try r.str(user.get("_id")) }), null);
        // Members who have keys but were not included still need this epoch.
        const everyone = try col().members.find(a, .{ .chatId = chat.get("_id"), .status = "active" }, .{ .projection = .{ .userId = 1 } });
        var missing: std.ArrayList(Val) = .empty;
        for (everyone) |m| {
            var inc = false;
            for (valid.items) |w| if (val.same(w.get("userId"), m.get("userId"))) {
                inc = true;
            };
            if (!inc) try missing.append(a, m.get("userId"));
        }
        if (missing.items.len > 0) try requestKeys(r, fresh, missing.items, false);
    } else {
        rt.toUsers(a, vids.items, "keys.available", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .epoch = epoch }));
    }
    return val.from(a, .{ .epoch = fresh.get("keyEpoch"), .stored = stored });
}

/// Outstanding key requests the caller could fulfil.
pub fn pendingRequests(r: *Rq, user: Val) !Val {
    const a = r.a;
    var out = try Val.array(a);
    const mine = try col().chatKeys.find(a, .{ .userId = user.get("_id") }, .{ .projection = .{ .chatId = 1, .epoch = 1 } });
    if (mine.len == 0) return out;
    var chat_ids: std.ArrayList(Val) = .empty;
    for (mine) |k| {
        var dup = false;
        for (chat_ids.items) |c| if (val.same(c, k.get("chatId"))) {
            dup = true;
        };
        if (!dup) try chat_ids.append(a, k.get("chatId"));
    }
    const requests = try col().keyRequests.find(a, .{ .chatId = .{ .@"$in" = chat_ids.items }, .userId = .{ .@"$ne" = user.get("_id") } }, .{ .limit = 500 });
    for (requests) |q| {
        var has = false;
        for (mine) |k| if (val.same(k.get("chatId"), q.get("chatId")) and (k.get("epoch").asNum() orelse -1) == (q.get("epoch").asNum() orelse -2)) {
            has = true;
        };
        if (has) try out.push(try val.from(a, .{ .chatId = try r.str(q.get("chatId")), .userId = try r.str(q.get("userId")), .epoch = q.get("epoch") }));
    }
    return out;
}

/// Public keys for a set of users.
pub fn publicKeys(r: *Rq, user_ids: []const Val) !Val {
    const a = r.a;
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = user_ids } }, .{ .projection = .{ .keys = 1 } });
    var out = try Val.array(a);
    for (users) |u| {
        const k = u.get("keys");
        try out.push(try val.from(a, .{
            .userId = try r.str(u.get("_id")),
            .enc = if (k.get("enc").truthy()) k.get("enc") else Val.null,
            .sig = if (k.get("sig").truthy()) k.get("sig") else Val.null,
            .version = if (k.get("version").truthy()) k.get("version") else Val.null,
        }));
    }
    return out;
}
