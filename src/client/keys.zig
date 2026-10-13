//! The key manager: this device's identity, chat keys, rotation, sharing keys with members who
//! need them, and decrypting messages. Port of Reseal-js data/e2ee.js.
//!
//! The identity's private keys live in zui.keys (the web: non-extractable WebCrypto keys in
//! IndexedDB, as the web app kept them; the phones: their keystores), imported once from the
//! bundle the backups carry and never read again. Only the public keys stay in zui.storage. So
//! signing and unwrapping are asynchronous: a body that needs signatures carries placeholders
//! ("zui-sig-<n>") and leaves once they are in (`apiSigned`, `wsSendSigned`). Chat keys stay in
//! memory and are fetched again (wrapped for this account) from the server after a restart.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const crypto = @import("crypto.zig");
const send = @import("send.zig");
const sync = @import("sync.zig");

const State = app.State;
const Id = app.Id;
const gpa = app.gpa;
const t = zui.i18n.t;
const tmp = app.tmp;

pub const Request = struct { chat: Id, user: Id, epoch: i64 };

/// This device's identity: its public keys (the private ones are in zui.keys).
pub const Mine = struct { enc_public: [65]u8, sig_public: [65]u8 };

/// A request body waiting for its signatures.
const Job = struct { body: []u8, then: union(enum) { api: struct { method: zui.Method, path: []u8, op: app.Op }, ws: []u8 } };

pub const Keys = struct {
    identity: ?Mine = null,
    /// Signatures that arrived (request id -> base64), until their bodies leave.
    sigs: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    jobs: std.ArrayList(Job) = .empty,
    /// Unwrap requests in flight: request id -> chat and epoch; and per chat, how many.
    unwraps: std.AutoHashMapUnmanaged(u32, struct { chat: Id, epoch: i64 }) = .empty,
    unwrapping: std.StringHashMapUnmanaged(u32) = .empty,
    /// "chatId:epoch" -> raw AES key.
    chat_keys: std.StringHashMapUnmanaged([32]u8) = .empty,
    loading: std.StringHashMapUnmanaged(void) = .empty,
    rotating: std.StringHashMapUnmanaged(void) = .empty,
    /// A chat's keys answer waiting for the wrappers' public keys.
    pending_wraps: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Users to look up (batched at the end of an update), and those already asked.
    wanted: std.StringHashMapUnmanaged(void) = .empty,
    asked: std.StringHashMapUnmanaged(void) = .empty,
    lookup_inflight: bool = false,
    /// Key requests from other members (keys.needed), waiting to be answered.
    queue: std.ArrayList(Request) = .empty,
    waiting: std.ArrayList(Request) = .empty,
    batches: std.AutoHashMapUnmanaged(u32, std.ArrayList(Request)) = .empty,
    next_batch: u32 = 1,
    fulfill_scheduled: bool = false,
    /// Decrypted payloads by "messageId:editedAt".
    decrypted: std.StringHashMapUnmanaged(Decrypted) = .empty,
};

pub const Decrypted = struct { payload: []u8, verified: ?bool };

fn myId(s: *const State) []const u8 {
    return s.store.myId();
}

fn ck(a: std.mem.Allocator, chat: []const u8, epoch: i64) []u8 {
    return std.fmt.allocPrint(a, "{s}:{d}", .{ chat, epoch }) catch "";
}

pub fn keyFor(s: *const State, chat: []const u8, epoch: i64) ?[32]u8 {
    return s.keys.chat_keys.get(ck(tmp(), chat, epoch));
}

fn remember(s: *State, chat: []const u8, epoch: i64, raw: [32]u8) void {
    const k = ck(gpa, chat, epoch);
    const gop = s.keys.chat_keys.getOrPut(gpa, k) catch return;
    if (gop.found_existing) gpa.free(k);
    gop.value_ptr.* = raw;
}

fn storageKey(s: *const State) []const u8 {
    return std.fmt.allocPrint(tmp(), "identity:{s}", .{myId(s)}) catch "identity";
}

fn publicKey(s: *const State) []const u8 {
    return std.fmt.allocPrint(tmp(), "identity-public:{s}", .{myId(s)}) catch "identity-public";
}

/// The name of a private key in zui.keys ("enc" or "sig").
fn keyName(s: *const State, comptime which: []const u8) []const u8 {
    return std.fmt.allocPrint(tmp(), "reseal:{s}:" ++ which, .{myId(s)}) catch "reseal:" ++ which;
}

fn onKeyMsg(r: zui.keys.Result) app.Msg {
    return .{ .key = r };
}

/// The private keys go into zui.keys (never to be read again); the public ones are kept.
fn storeIdentity(s: *State, id: crypto.Identity) void {
    const a = tmp();
    var enc = crypto.pkcs8Encode(id.enc_secret, id.enc_public);
    var sig = crypto.pkcs8Encode(id.sig_secret, id.sig_public);
    defer std.crypto.secureZero(u8, &enc);
    defer std.crypto.secureZero(u8, &sig);
    _ = app.fx.key(.{ .op = .import, .name = keyName(s, "enc"), .kind = .ecdh, .data = &enc }, onKeyMsg);
    _ = app.fx.key(.{ .op = .import, .name = keyName(s, "sig"), .kind = .ecdsa, .data = &sig }, onKeyMsg);
    s.keys.identity = .{ .enc_public = id.enc_public, .sig_public = id.sig_public };
    const b = identityB64(s.keys.identity.?);
    zui.storage.set(publicKey(s), std.fmt.allocPrint(a, "{s} {s}", .{ b.enc, b.sig }) catch return, .{});
    // The bundle earlier versions kept in secure storage.
    zui.storage.remove(storageKey(s), .{ .secure = true });
}

/// The account's keys changed: remember them on the profile, forget chat keys made for old ones.
fn adopt(s: *State, enc: []const u8, sig: []const u8, mode: []const u8) void {
    if (s.store.me) |me| {
        const a = tmp();
        const v = j.parse(a, std.fmt.allocPrint(a, "{{\"keys\":{{\"enc\":\"{s}\",\"sig\":\"{s}\"}},\"hasKeys\":true,\"keyBackup\":true,\"keyMode\":\"{s}\"}}", .{ enc, sig, mode }) catch return) orelse return;
        me.merge(v) catch {};
        _ = s.store.putUser(me.v) catch null;
    }
    clearChatKeys(s);
    retryAll(s);
}

fn clearChatKeys(s: *State) void {
    var it = s.keys.chat_keys.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    s.keys.chat_keys.clearRetainingCapacity();
    var di = s.keys.decrypted.iterator();
    while (di.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.payload);
    }
    s.keys.decrypted.clearRetainingCapacity();
    var ci = s.store.chats.valueIterator();
    while (ci.next()) |c| c.*.keys_fetched = false;
}

/// Sign out: forget this device's keys.
pub fn forgetDevice(s: *State) void {
    if (myId(s).len > 0) {
        zui.storage.remove(storageKey(s), .{ .secure = true });
        zui.storage.remove(publicKey(s), .{});
        _ = app.fx.key(.{ .op = .delete, .name = keyName(s, "enc") }, onKeyMsg);
        _ = app.fx.key(.{ .op = .delete, .name = keyName(s, "sig") }, onKeyMsg);
    }
    s.keys.identity = null;
    clearChatKeys(s);
}

pub fn hasIdentity(s: *const State) bool {
    return s.keys.identity != null;
}

// ---------------------------------------------------------------------------------------------
// Making sure this device can encrypt (ensureKeys)

pub fn ensureKeys(s: *State) void {
    const me = s.store.me orelse return;
    const enc = me.s("keys.enc");
    if (zui.storage.get(tmp(), publicKey(s), .{})) |stored| {
        const space = std.mem.indexOfScalar(u8, stored, ' ') orelse stored.len;
        const enc_b64 = stored[0..space];
        const sig_b64 = if (space < stored.len) stored[space + 1 ..] else "";
        if (enc != null and std.mem.eql(u8, enc.?, enc_b64) and std.mem.eql(u8, me.s("keys.sig") orelse "", sig_b64)) {
            const e = crypto.fromB64(tmp(), enc_b64) catch "";
            const g = crypto.fromB64(tmp(), sig_b64) catch "";
            if (e.len == 65 and g.len == 65) {
                s.keys.identity = .{ .enc_public = e[0..65].*, .sig_public = g[0..65].* };
                return app.keysReady(s);
            }
        }
        // Keys were reset elsewhere.
        zui.storage.remove(publicKey(s), .{});
    }
    // Earlier versions kept the private keys as a bundle in secure storage: move them.
    if (zui.storage.get(tmp(), storageKey(s), .{ .secure = true })) |stored| {
        if (crypto.identityFromBundle(tmp(), stored)) |id| {
            const pub_b64 = crypto.toB64(tmp(), &id.enc_public) catch "";
            const sig_b64 = crypto.toB64(tmp(), &id.sig_public) catch "";
            if (enc != null and std.mem.eql(u8, enc.?, pub_b64) and std.mem.eql(u8, me.s("keys.sig") orelse "", sig_b64)) {
                storeIdentity(s, id);
                return app.keysReady(s);
            }
        } else |_| {}
        // Keys were reset elsewhere.
        zui.storage.remove(storageKey(s), .{ .secure = true });
    }
    if (s.mode == .embed) {
        const app_e2ee = if (s.embed.app) |a| a.b("e2ee") else false;
        if (!app_e2ee) return app.keysReady(s);
        const pass = if (s.embed.options) |o| o.s("e2eePassphrase") else null;
        if (pass) |p| {
            s.fields.getPtr(.passcode).set(p);
            if (!me.b("hasKeys")) return setupAdvanced(s, p, false);
            app.api(s, .GET, "/keys/backup", null, .keys_backup_unlock);
            return;
        }
    }
    if (!me.b("hasKeys")) return setupAutomatic(s, false);
    if (std.mem.eql(u8, me.s("keyMode") orelse "", "standard") or s.mode == .embed) {
        app.api(s, .POST, "/keys/restore", "{}", .keys_restore);
        return;
    }
    s.phase = .locked;
}

/// Create keys whose backup the server can restore on new devices.
pub fn setupAutomatic(s: *State, reset: bool) void {
    if (!sys.canRandom()) return app.toastError(s, t("Something went wrong. Try again."));
    const a = tmp();
    const fresh = crypto.generateIdentity(sys.random());
    const esc = crypto.escrowBackup(a, sys.random(), fresh) catch return;
    const body = std.fmt.allocPrint(a, "{{\"enc\":\"{s}\",\"sig\":\"{s}\",\"mode\":\"standard\",\"backup\":{{\"escrow\":{s}}},\"escrowKey\":\"{s}\",\"reset\":{}}}", .{ fresh.encPublicB64(a) catch return, fresh.sigPublicB64(a) catch return, esc.box, esc.key, reset }) catch return;
    const id = gpa.create(crypto.Identity) catch return;
    id.* = fresh;
    app.api(s, .PUT, "/keys", body, .{ .keys_setup_auto = .{ .id = id } });
}

/// Advanced protection from the start (a widget with e2eePassphrase, or provisioned keys).
fn setupAdvanced(s: *State, passcode: []const u8, reset: bool) void {
    const a = tmp();
    const fresh = crypto.generateIdentity(sys.random());
    const pass_box = crypto.passcodeBackup(a, sys.random(), fresh, passcode, crypto.pbkdf2_iterations) catch return;
    const rec = crypto.recoveryBackup(a, sys.random(), fresh) catch return;
    const body = std.fmt.allocPrint(a, "{{\"enc\":\"{s}\",\"sig\":\"{s}\",\"backup\":{{\"passcode\":{s},\"recovery\":{s}}},\"mode\":\"advanced\",\"reset\":{}}}", .{ fresh.encPublicB64(a) catch return, fresh.sigPublicB64(a) catch return, pass_box, rec.box, reset }) catch return;
    s.recovery_shown.set(rec.key);
    const id = gpa.create(crypto.Identity) catch return;
    id.* = fresh;
    app.api(s, .PUT, "/keys", body, .{ .keys_setup_auto = .{ .id = id } });
}

/// The unlock screen (advanced protection on a new device): passcode or recovery key.
pub fn unlockSubmit(s: *State) void {
    if (s.fields.get(.passcode).get().len == 0) return;
    s.busy = true;
    s.unlock_error.clear();
    app.api(s, .GET, "/keys/backup", null, .keys_backup_unlock);
}

fn boxOf(v: ?j.Value, key: []const u8) ?crypto.Box {
    // Read field by field: the server's boxes may carry nulls or extra fields.
    const b = j.obj(v, key) orelse return null;
    return .{
        .v = j.intOr(b, "v", 1),
        .kdf = j.strOr(b, "kdf", ""),
        .iter = @intCast(std.math.clamp(j.intOr(b, "iter", crypto.pbkdf2_iterations), 1, 10_000_000)),
        .salt = j.strOr(b, "salt", ""),
        .iv = j.str(b, "iv") orelse return null,
        .ct = j.str(b, "ct") orelse return null,
    };
}

fn identityB64(id: anytype) struct { enc: []const u8, sig: []const u8 } {
    return .{ .enc = crypto.toB64(tmp(), &id.enc_public) catch "", .sig = crypto.toB64(tmp(), &id.sig_public) catch "" };
}

/// Answers for the key manager's requests; false when the op is not one of them.
pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const a = tmp();
    const v = j.parse(a, r.body);
    switch (op) {
        .keys_setup_auto => |x| {
            defer {
                std.crypto.secureZero(u8, std.mem.asBytes(x.id));
                gpa.destroy(x.id);
            }
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
                if (s.phase != .ready) s.phase = .locked;
                return true;
            }
            storeIdentity(s, x.id.*);
            const b = identityB64(x.id.*);
            const advanced = s.recovery_shown.get().len > 0;
            adopt(s, b.enc, b.sig, if (advanced) "advanced" else "standard");
            if (advanced and s.mode == .app) s.modal = .{ .recovery_key = .{} } else s.recovery_shown.clear();
            app.keysReady(s);
        },
        .keys_restore => {
            if (!r.ok()) {
                zui.log("key restore failed: {d} {s}", .{ r.status, r.body[0..@min(r.body.len, 200)] });
                s.phase = .locked;
                return true;
            }
            const box = boxOf(v, "escrow") orelse {
                zui.log("key restore: no backup in the answer", .{});
                s.phase = .locked;
                return true;
            };
            const id = crypto.unlockWithEscrow(a, box, j.strOr(v, "escrowKey", "")) catch |e| {
                zui.log("key restore: backup did not open: {s}", .{@errorName(e)});
                if (s.mode == .embed) {
                    setupAutomatic(s, true);
                    return true;
                }
                s.phase = .locked;
                return true;
            };
            const b = identityB64(id);
            if (!std.mem.eql(u8, b.enc, j.strOr(v, "enc", ""))) {
                zui.log("key restore: the backup holds other keys ({s} vs {s})", .{ b.enc, j.strOr(v, "enc", "") });
                s.phase = .locked;
                return true;
            }
            storeIdentity(s, id);
            adopt(s, b.enc, b.sig, "standard");
            app.keysReady(s);
            fulfillPending(s);
        },
        .keys_backup_unlock => {
            s.busy = false;
            const pass = s.fields.get(.passcode).get();
            if (!r.ok()) {
                s.unlock_error.set(app.apiError(r).message);
                return true;
            }
            const res = if (s.unlock_recovery)
                if (boxOf(j.field(v, "backup"), "recovery")) |box| crypto.unlockWithRecovery(a, box, pass) else error.BadData
            else if (boxOf(j.field(v, "backup"), "passcode")) |box| crypto.unlockWithPasscode(a, box, pass) else error.BadData;
            const id = res catch |e| {
                if (s.mode == .embed) {
                    // A widget whose passphrase changed: start over with it (embed.js does too).
                    setupAdvanced(s, pass, true);
                    return true;
                }
                s.unlock_error.set(switch (e) {
                    error.WrongPasscode => t("That passcode is not right. Try again."),
                    error.WrongRecoveryKey, error.BadRecoveryKey => t("That recovery key is not right."),
                    else => t("Something went wrong. Try again."),
                });
                return true;
            };
            const b = identityB64(id);
            if (!std.mem.eql(u8, b.enc, j.strOr(v, "enc", ""))) {
                s.unlock_error.set(t("This backup does not match your current keys"));
                return true;
            }
            s.fields.getPtr(.passcode).clear();
            storeIdentity(s, id);
            adopt(s, b.enc, b.sig, "advanced");
            app.keysReady(s);
            fulfillPending(s);
        },
        .keys_enable_advanced => {
            s.busy = false;
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            const pass = s.fields.get(.passcode).get();
            // Keys the server created (before this person ever opened Reseal) are replaced.
            if (j.truthy(v, "provisioned")) {
                setupAdvanced(s, pass, true);
                s.modal = null;
                return true;
            }
            const box = boxOf(v, "escrow") orelse return true;
            const id = crypto.unlockWithEscrow(a, box, j.strOr(v, "escrowKey", "")) catch {
                app.toastError(s, t("The key backup could not be opened"));
                return true;
            };
            const pass_box = crypto.passcodeBackup(a, sys.random(), id, pass, crypto.pbkdf2_iterations) catch return true;
            const rec = crypto.recoveryBackup(a, sys.random(), id) catch return true;
            s.recovery_shown.set(rec.key);
            app.api(s, .PUT, "/keys/protection", std.fmt.allocPrint(a, "{{\"mode\":\"advanced\",\"passcode\":{s},\"recovery\":{s}}}", .{ pass_box, rec.box }) catch return true, .keys_protection);
        },
        .keys_protection => {
            s.busy = false;
            if (!r.ok()) {
                s.recovery_shown.clear();
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            const mode = j.strOr(v, "mode", "standard");
            if (s.store.me) |me| me.set("keyMode", data.string(mode)) catch {};
            clearPassFields(s);
            if (std.mem.eql(u8, mode, "advanced")) {
                s.modal = .{ .recovery_key = .{} };
            } else {
                s.modal = null;
                app.toast(s, t("Automatic key backup is on"));
            }
        },
        .keys_backup_for => |what| {
            s.busy = false;
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            const current = s.fields.get(.passcode).get();
            const box = boxOf(j.field(v, "backup"), "passcode") orelse return true;
            const id = crypto.unlockWithPasscode(a, box, current) catch |e| {
                app.toastError(s, if (e == error.WrongPasscode) t("That passcode is not right. Try again.") else t("Something went wrong. Try again."));
                return true;
            };
            switch (what) {
                .disable => {
                    const esc = crypto.escrowBackup(a, sys.random(), id) catch return true;
                    app.api(s, .PUT, "/keys/protection", std.fmt.allocPrint(a, "{{\"mode\":\"standard\",\"escrow\":{s},\"escrowKey\":\"{s}\"}}", .{ esc.box, esc.key }) catch return true, .keys_protection);
                },
                .change => {
                    const next = s.fields.get(.passcode_2).get();
                    const pass_box = crypto.passcodeBackup(a, sys.random(), id, next, crypto.pbkdf2_iterations) catch return true;
                    app.api(s, .PUT, "/keys/backup", std.fmt.allocPrint(a, "{{\"passcode\":{s}}}", .{pass_box}) catch return true, .keys_backup_put);
                },
                .recovery => {
                    const rec = crypto.recoveryBackup(a, sys.random(), id) catch return true;
                    s.recovery_shown.set(rec.key);
                    app.api(s, .PUT, "/keys/backup", std.fmt.allocPrint(a, "{{\"recovery\":{s}}}", .{rec.box}) catch return true, .keys_backup_put);
                },
            }
        },
        .keys_backup_put => {
            s.busy = false;
            if (!r.ok()) {
                s.recovery_shown.clear();
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            clearPassFields(s);
            if (s.recovery_shown.get().len > 0) {
                s.modal = .{ .recovery_key = .{} };
            } else {
                s.modal = null;
                app.toast(s, t("Passcode changed"));
            }
        },
        .keys_requests => if (r.ok()) {
            for (j.arr(v, "requests")) |q| enqueue(s, j.strOr(q, "chatId", ""), j.strOr(q, "userId", ""), j.intOr(q, "epoch", 0));
            scheduleFulfill(s);
        },
        .keys_lookup_fulfill => |x| onFulfillLookup(s, x.batch, r, v),
        .keys_post_share => {},
        .chat_keys => |chat| onChatKeys(s, chat.str(), r),
        .key_members => |x| onKeyMembers(s, x.chat.str(), x.epoch, r, v),
        .keys_post_rotate => |x| onRotated(s, x.chat.str(), x.epoch, x.raw, r),
        .chat_refresh_conflict => |chat| {
            _ = s.keys.rotating.remove(chat.str());
            if (r.ok()) if (j.obj(v, "chat")) |c| {
                _ = s.store.putChat(c) catch null;
            };
            fetchChatKeys(s, chat.str(), true);
        },
        .users_lookup => {
            s.keys.lookup_inflight = false;
            if (r.ok()) for (j.arr(v, "users")) |u| {
                _ = s.store.putUser(u) catch null;
            };
            usersArrived(s);
        },
        else => return false,
    }
    return true;
}

fn clearPassFields(s: *State) void {
    s.fields.getPtr(.passcode).clear();
    s.fields.getPtr(.passcode_2).clear();
    s.fields.getPtr(.passcode_3).clear();
}

/// Settings → Advanced protection and its forms (the modal decides which).
pub fn advancedSubmit(s: *State) void {
    const p1 = s.fields.get(.passcode).get();
    const p2 = s.fields.get(.passcode_2).get();
    const p3 = s.fields.get(.passcode_3).get();
    const modal = s.modal orelse return;
    switch (modal) {
        .enable_advanced => {
            if (p1.len < 8) return app.toastError(s, t("Use at least 8 characters."));
            if (!std.mem.eql(u8, p1, p2)) return app.toastError(s, t("The passcodes do not match."));
            s.busy = true;
            app.api(s, .POST, "/keys/restore", "{}", .keys_enable_advanced);
        },
        .disable_advanced => {
            if (p1.len == 0) return app.toastError(s, t("Enter your passcode"));
            s.busy = true;
            app.api(s, .GET, "/keys/backup", null, .{ .keys_backup_for = .disable });
        },
        .change_passcode => {
            if (p2.len < 8) return app.toastError(s, t("Use at least 8 characters."));
            if (!std.mem.eql(u8, p2, p3)) return app.toastError(s, t("The passcodes do not match."));
            s.busy = true;
            app.api(s, .GET, "/keys/backup", null, .{ .keys_backup_for = .change });
        },
        .new_recovery => {
            if (p1.len == 0) return app.toastError(s, t("Enter your passcode"));
            s.busy = true;
            app.api(s, .GET, "/keys/backup", null, .{ .keys_backup_for = .recovery });
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------------------------
// Users we need (wrappers' and senders' public keys), looked up in batches

pub fn want(s: *State, user_id: []const u8) void {
    if (user_id.len == 0) return;
    // Known with keys: nothing to ask. (Known without keys: ask once, they may have set them up.)
    if (s.store.user(user_id)) |u| if (u.get("keys") != null) return;
    if (s.keys.asked.contains(user_id) or s.keys.wanted.contains(user_id)) return;
    s.keys.wanted.put(gpa, gpa.dupe(u8, user_id) catch return, {}) catch {};
}

pub fn flushLookups(s: *State) void {
    if (s.keys.lookup_inflight or s.keys.wanted.count() == 0 or s.phase != .ready) return;
    const a = tmp();
    var ids: std.ArrayList(u8) = .empty;
    ids.appendSlice(a, "{\"ids\":[") catch return;
    var it = s.keys.wanted.keyIterator();
    var first = true;
    while (it.next()) |k| {
        ids.print(a, "{s}\"{s}\"", .{ if (first) "" else ",", k.* }) catch {};
        first = false;
        s.keys.asked.put(gpa, k.*, {}) catch gpa.free(k.*);
    }
    ids.appendSlice(a, "]}") catch {};
    s.keys.wanted.clearRetainingCapacity();
    s.keys.lookup_inflight = true;
    app.api(s, .POST, "/users/lookup", ids.items, .users_lookup);
}

fn usersArrived(s: *State) void {
    // Wraps that waited for their wrapper's key.
    var chats: std.ArrayList([]const u8) = .empty;
    var it = s.keys.pending_wraps.keyIterator();
    while (it.next()) |k| chats.append(tmp(), tmp().dupe(u8, k.*) catch continue) catch {};
    for (chats.items) |c| {
        const kv = s.keys.pending_wraps.fetchRemove(c) orelse continue;
        defer {
            gpa.free(kv.key);
            gpa.free(kv.value);
        }
        processWraps(s, c, kv.value, false);
    }
    // Signatures that could not be checked yet.
    retryAll(s);
    sync.changed(s);
}

pub fn senderSig(s: *const State, user_id: []const u8) ?[]const u8 {
    if (s.store.isMe(user_id)) if (s.keys.identity) |id| return crypto.toB64(tmp(), &id.sig_public) catch null;
    const u = s.store.user(user_id) orelse return null;
    return u.s("keys.sig");
}

// ---------------------------------------------------------------------------------------------
// Chat keys

pub fn fetchChatKeys(s: *State, chat: []const u8, force: bool) void {
    if (s.keys.identity == null) return;
    if (s.keys.loading.contains(chat)) return;
    if (!force) if (s.store.chat(chat)) |c| if (c.keys_fetched) return;
    s.keys.loading.put(gpa, gpa.dupe(u8, chat) catch return, {}) catch return;
    app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/{s}/keys", .{chat}) catch return, null, .{ .chat_keys = Id.of(chat) });
}

fn onChatKeys(s: *State, chat: []const u8, r: zui.Response) void {
    if (s.keys.loading.fetchRemove(chat)) |kv| gpa.free(kv.key);
    if (!r.ok()) {
        send.keyProblem(s, chat, app.apiError(r).message);
        return;
    }
    processWraps(s, chat, r.body, true);
}

/// Unwraps every key of a chat addressed to me; wraps from unknown people wait for a lookup.
fn processWraps(s: *State, chat: []const u8, body: []const u8, can_wait: bool) void {
    const a = tmp();
    if (s.keys.identity == null) return;
    const v = j.parse(a, body) orelse return;
    var missing = false;
    var started: u32 = 0;
    for (j.arr(v, "keys")) |w| {
        const epoch = j.intOr(w, "epoch", 0);
        if (keyFor(s, chat, epoch) != null) continue;
        const by = j.strOr(w, "by", "");
        const sig = senderSig(s, by) orelse {
            if (can_wait and !s.keys.asked.contains(by)) {
                want(s, by);
                missing = true;
            }
            continue;
        };
        const wrap: crypto.Wrap = .{ .userId = myId(s), .eph = j.strOr(w, "eph", ""), .iv = j.strOr(w, "iv", ""), .ct = j.strOr(w, "ct", ""), .sig = j.strOr(w, "sig", "") };
        if (unwrap(s, wrap, chat, epoch, sig)) started += 1 else zui.log("Could not unwrap key {s}#{d}", .{ chat, epoch });
    }
    if (started > 0) {
        // The keys arrive as messages: the chat stays "loading" until the last one.
        const gop = s.keys.unwrapping.getOrPut(gpa, gpa.dupe(u8, chat) catch return) catch return;
        if (gop.found_existing) gpa.free(gop.key_ptr.*) else gop.value_ptr.* = 0;
        gop.key_ptr.* = gop.key_ptr.*;
        gop.value_ptr.* += started;
        if (!s.keys.loading.contains(chat)) s.keys.loading.put(gpa, gpa.dupe(u8, chat) catch return, {}) catch {};
        _ = app.fx.key(.{ .op = .delete, .name = "reseal:unwrap" }, onKeyMsg);
        if (!missing) return;
    }
    if (missing) {
        const k = gpa.dupe(u8, chat) catch return;
        const gop = s.keys.pending_wraps.getOrPut(gpa, k) catch return;
        if (gop.found_existing) {
            gpa.free(k);
            gpa.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = gpa.dupe(u8, body) catch "";
        return;
    }
    keysLoaded(s, chat);
}

/// A chat's keys are in: messages decrypt, waiting requests are answered, the outbox moves.
fn keysLoaded(s: *State, chat: []const u8) void {
    if (s.store.chat(chat)) |c| c.keys_fetched = true;
    retryChat(s, chat);
    // Key requests that waited for this chat's keys.
    var i: usize = 0;
    while (i < s.keys.waiting.items.len) {
        if (s.keys.waiting.items[i].chat.eql(chat)) {
            s.keys.queue.append(gpa, s.keys.waiting.orderedRemove(i)) catch {};
        } else i += 1;
    }
    if (s.keys.queue.items.len > 0) scheduleFulfill(s);
    send.pump(s, chat);
}

/// New keys are available for a chat (keys.available / keys.epoch).
pub fn keysArrived(s: *State, chat: []const u8) void {
    if (s.store.chat(chat)) |c| c.keys_fetched = false;
    fetchChatKeys(s, chat, true);
}

/// Start a new epoch: a fresh key wrapped for every member with keys.
pub fn rotate(s: *State, chat: []const u8) void {
    if (s.keys.rotating.contains(chat)) return;
    const c = s.store.chat(chat) orelse return;
    s.keys.rotating.put(gpa, gpa.dupe(u8, chat) catch return, {}) catch return;
    app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/{s}/key-members", .{chat}) catch return, null, .{ .key_members = .{ .chat = Id.of(chat), .epoch = c.keyEpoch() + 1 } });
}

pub fn isRotating(s: *const State, chat: []const u8) bool {
    return s.keys.rotating.contains(chat);
}

fn endRotation(s: *State, chat: []const u8) void {
    if (s.keys.rotating.fetchRemove(chat)) |kv| gpa.free(kv.key);
}

fn onKeyMembers(s: *State, chat: []const u8, epoch: i64, r: zui.Response, v: ?j.Value) void {
    const a = tmp();
    if (s.keys.identity == null) return endRotation(s, chat);
    if (!r.ok()) {
        endRotation(s, chat);
        return send.keyProblem(s, chat, app.apiError(r).message);
    }
    const raw = sys.randomBytes(32);
    var wraps: std.ArrayList(u8) = .empty;
    wraps.print(a, "{{\"epoch\":{d},\"rotate\":true,\"keys\":[", .{epoch}) catch return;
    var n: usize = 0;
    for (j.arr(v, "members")) |m| {
        const enc = j.str(m, "enc") orelse continue;
        const uid = j.strOr(m, "userId", "");
        if (!s.store.isMe(uid)) {
            const u = std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"keys\":{{\"enc\":\"{s}\",\"sig\":\"{s}\",\"version\":{d}}}}}", .{ uid, enc, j.strOr(m, "sig", ""), j.intOr(m, "version", 1) }) catch continue;
            if (j.parse(a, u)) |uv| _ = s.store.putUser(uv) catch null;
        }
        const w = wrapSigned(s, raw, chat, epoch, uid, enc) orelse continue;
        wraps.print(a, "{s}{s}", .{ if (n == 0) "" else ",", wrapJson(a, w) }) catch {};
        n += 1;
    }
    wraps.appendSlice(a, "]}") catch {};
    apiSigned(s, .POST, std.fmt.allocPrint(a, "/chats/{s}/keys", .{chat}) catch return, wraps.items, .{ .keys_post_rotate = .{ .chat = Id.of(chat), .epoch = epoch, .raw = raw } });
}

fn wrapJson(a: std.mem.Allocator, w: crypto.Wrap) []const u8 {
    return std.fmt.allocPrint(a, "{{\"userId\":\"{s}\",\"eph\":\"{s}\",\"iv\":\"{s}\",\"ct\":\"{s}\",\"sig\":\"{s}\"}}", .{ w.userId, w.eph, w.iv, w.ct, w.sig }) catch "";
}

fn onRotated(s: *State, chat: []const u8, epoch: i64, raw: [32]u8, r: zui.Response) void {
    if (!r.ok()) {
        const e = app.apiError(r);
        if (std.mem.eql(u8, e.code, "epoch_conflict")) {
            // Someone else rotated first: adopt their epoch.
            app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/{s}", .{chat}) catch return, null, .{ .chat_refresh_conflict = Id.of(chat) });
            return;
        }
        endRotation(s, chat);
        return send.keyProblem(s, chat, e.message);
    }
    endRotation(s, chat);
    remember(s, chat, epoch, raw);
    if (s.store.chat(chat)) |c| {
        c.o.set("keyEpoch", data.int(epoch)) catch {};
        c.o.set("rotationNeeded", data.boolean(false)) catch {};
    }
    send.pump(s, chat);
}

// ---------------------------------------------------------------------------------------------
// Sharing keys with members who need them (keys.needed)

fn enqueue(s: *State, chat: []const u8, user: []const u8, epoch: i64) void {
    if (chat.len == 0 or user.len == 0) return;
    s.keys.queue.append(gpa, .{ .chat = Id.of(chat), .user = Id.of(user), .epoch = epoch }) catch {};
}

pub fn onKeysNeeded(s: *State, d: j.Value) void {
    const chat = j.strOr(d, "chatId", "");
    for (j.arr(d, "requests")) |q| enqueue(s, chat, j.strOr(q, "userId", ""), j.intOr(q, "epoch", 0));
    scheduleFulfill(s);
}

fn scheduleFulfill(s: *State) void {
    if (s.keys.fulfill_scheduled or s.keys.identity == null) return;
    s.keys.fulfill_scheduled = true;
    // A short random delay so several online members do not all answer at once.
    app.fx.after(200 + sys.random().uintLessThan(u32, 1200), .fulfill_due);
}

pub fn fulfillPending(s: *State) void {
    if (s.keys.identity == null) return;
    app.api(s, .GET, "/keys/requests", null, .keys_requests);
}

pub fn fulfillDue(s: *State) void {
    s.keys.fulfill_scheduled = false;
    if (s.keys.queue.items.len == 0) return;
    const a = tmp();
    var ready: std.ArrayList(Request) = .empty;
    for (s.keys.queue.items) |q| {
        if (keyFor(s, q.chat.str(), q.epoch) == null) {
            // This device has not loaded that chat's keys yet: load them, then answer.
            const c = s.store.chat(q.chat.str());
            if (c == null or !c.?.keys_fetched) {
                s.keys.waiting.append(gpa, q) catch {};
                fetchChatKeys(s, q.chat.str(), false);
            }
            continue;
        }
        ready.append(gpa, q) catch {};
    }
    s.keys.queue.clearRetainingCapacity();
    if (ready.items.len == 0) return ready.deinit(gpa);
    var ids: std.ArrayList(u8) = .empty;
    ids.appendSlice(a, "{\"userIds\":[") catch return;
    for (ready.items, 0..) |q, i| ids.print(a, "{s}\"{s}\"", .{ if (i == 0) "" else ",", q.user.str() }) catch {};
    ids.appendSlice(a, "]}") catch {};
    const batch = s.keys.next_batch;
    s.keys.next_batch += 1;
    s.keys.batches.put(gpa, batch, ready) catch return;
    app.api(s, .POST, "/keys/lookup", ids.items, .{ .keys_lookup_fulfill = .{ .batch = batch } });
}

fn onFulfillLookup(s: *State, batch: u32, r: zui.Response, v: ?j.Value) void {
    var list = (s.keys.batches.fetchRemove(batch) orelse return).value;
    defer list.deinit(gpa);
    if (!r.ok()) return;
    if (s.keys.identity == null) return;
    const a = tmp();
    // Group by chat and epoch.
    var done = std.StringHashMap(void).init(a);
    for (list.items, 0..) |q, qi| {
        const group = ck(a, q.chat.str(), q.epoch);
        if (done.contains(group)) continue;
        done.put(group, {}) catch {};
        const raw = keyFor(s, q.chat.str(), q.epoch) orelse continue;
        var body: std.ArrayList(u8) = .empty;
        body.print(a, "{{\"epoch\":{d},\"keys\":[", .{q.epoch}) catch continue;
        var n: usize = 0;
        for (list.items[qi..]) |o| {
            if (!o.chat.eql(q.chat.str()) or o.epoch != q.epoch) continue;
            const enc = for (j.arr(v, "keys")) |k| {
                if (j.eqlStr(k, "userId", o.user.str())) break j.str(k, "enc");
            } else null;
            const e = enc orelse continue;
            const w = wrapSigned(s, raw, q.chat.str(), q.epoch, o.user.str(), e) orelse continue;
            body.print(a, "{s}{s}", .{ if (n == 0) "" else ",", wrapJson(a, w) }) catch {};
            n += 1;
        }
        body.appendSlice(a, "]}") catch {};
        if (n > 0) apiSigned(s, .POST, std.fmt.allocPrint(a, "/chats/{s}/keys", .{q.chat.str()}) catch continue, body.items, .keys_post_share);
    }
}

// ---------------------------------------------------------------------------------------------
// Decrypting messages (messages.js hydrate)

fn cacheKey(m: *const data.Message) []const u8 {
    // The ciphertext names the message (summaries in the chat list may come without an id).
    const ct = j.str(m.enc(), "ct") orelse return "";
    return std.fmt.allocPrint(tmp(), "{s}:{s}", .{ ct[0..@min(ct.len, 48)], j.str(m.enc(), "sig") orelse "" }) catch "";
}

/// Decrypts a message if it needs it. Never fails: problems are recorded on the message.
pub fn hydrate(s: *State, chat: []const u8, m: *data.Message) void {
    if (m.decrypt == .ok and (m.content != null or m.enc() == null or m.deleted())) {
        if (m.verified == null and m.enc() != null and m.content != null) reverify(s, chat, m);
        return;
    }
    const env_v = m.enc() orelse return;
    const a = tmp();
    if (s.keys.decrypted.get(cacheKey(m))) |d| {
        if (setPayload(m, d.payload)) {
            m.verified = d.verified;
            m.decrypt = .ok;
            if (d.verified == null) reverify(s, chat, m);
            return;
        }
    }
    if (s.keys.identity == null) {
        m.decrypt = .nokey;
        return;
    }
    const env = std.json.parseFromValueLeaky(crypto.Envelope, a, env_v, .{ .ignore_unknown_fields = true }) catch {
        m.decrypt = .failed;
        return;
    };
    const key = keyFor(s, chat, env.e) orelse {
        m.decrypt = .nokey;
        fetchChatKeys(s, chat, false);
        return;
    };
    const author = m.authorId();
    const sig = senderSig(s, author);
    if (sig == null) want(s, author);
    const d = crypto.decryptMessage(a, key, env, chat, author, sig) catch {
        m.decrypt = .failed;
        return;
    };
    if (!setPayload(m, d.payload)) {
        m.decrypt = .failed;
        return;
    }
    m.decrypt = .ok;
    m.verified = if (sig == null) null else d.verified;
    // Remember (bounded).
    if (s.keys.decrypted.count() > 5000) clearDecrypted(s);
    const k = gpa.dupe(u8, cacheKey(m)) catch return;
    const p = gpa.dupe(u8, d.payload) catch {
        gpa.free(k);
        return;
    };
    const gop = s.keys.decrypted.getOrPut(gpa, k) catch return;
    if (gop.found_existing) {
        gpa.free(k);
        gpa.free(gop.value_ptr.payload);
    }
    gop.value_ptr.* = .{ .payload = p, .verified = m.verified };
}

fn clearDecrypted(s: *State) void {
    var di = s.keys.decrypted.iterator();
    while (di.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.payload);
    }
    s.keys.decrypted.clearRetainingCapacity();
}

fn setPayload(m: *data.Message, payload: []const u8) bool {
    const a = m.o.alloc();
    const p = j.parse(a, payload) orelse return false;
    m.content = data.contentFromPayload(a, p) catch return false;
    return true;
}

/// The signature of a message decrypted before its sender's keys were known.
fn reverify(s: *State, chat: []const u8, m: *data.Message) void {
    const sig = senderSig(s, m.authorId()) orelse {
        want(s, m.authorId());
        return;
    };
    const a = tmp();
    const env = std.json.parseFromValueLeaky(crypto.Envelope, a, m.enc() orelse return, .{ .ignore_unknown_fields = true }) catch return;
    const key = keyFor(s, chat, env.e) orelse return;
    const d = crypto.decryptMessage(a, key, env, chat, m.authorId(), sig) catch return;
    m.verified = d.verified;
    if (s.keys.decrypted.getPtr(cacheKey(m))) |c| c.verified = d.verified;
}

/// Messages of a chat waiting for a key or a signature check: try again.
pub fn retryChat(s: *State, chat: []const u8) void {
    if (s.store.existingTimeline(chat)) |tl| for (tl.items.items) |m| {
        if (m.decrypt == .nokey or m.decrypt == .failed or m.decrypt == .pending or m.verified == null) {
            if (m.decrypt != .ok) m.decrypt = .pending;
            hydrate(s, chat, m);
        }
    };
    if (s.store.chat(chat)) |c| if (c.last) |m| if (m.decrypt != .ok or m.verified == null) {
        if (m.decrypt != .ok) m.decrypt = .pending;
        hydrate(s, chat, m);
    };
}

pub fn retryAll(s: *State) void {
    var it = s.store.chats.keyIterator();
    var list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |k| list.append(tmp(), k.*) catch {};
    for (list.items) |c| retryChat(s, c);
}

// ---------------------------------------------------------------------------------------------
// Encrypting, signing

pub const Encrypted = struct { env_json: []const u8 };

/// The envelope for a payload in this chat, or null when the key is not ready (the caller
/// waits: `pump` runs again when it is).
/// Its signature is a placeholder: send the body with `apiSigned`.
pub fn encrypt(s: *State, chat: *data.Chat, payload_json: []const u8) ?[]const u8 {
    if (s.keys.identity == null) return null;
    const epoch = chat.keyEpoch();
    const key = keyFor(s, chat.id(), epoch) orelse return null;
    const a = tmp();
    const u = crypto.encryptMessageUnsigned(a, sys.random(), key, payload_json, chat.id(), epoch, myId(s)) catch return null;
    var env = u.env;
    env.sig = signLater(s, u.signed) orelse return null;
    return crypto.envelopeJson(a, env) catch null;
}

/// A placeholder for the signature of `text` (send the body with `apiSigned` or
/// `wsSendSigned`).
pub fn signText(s: *State, text: []const u8) ?[]const u8 {
    return signLater(s, text);
}

pub fn verifyFrom(s: *const State, user_id: []const u8, signature: []const u8, text: []const u8) bool {
    const sig = senderSig(s, user_id) orelse return false;
    return crypto.verify(tmp(), sig, signature, text);
}

pub fn myPublic(s: *const State) ?struct { enc: []const u8, sig: []const u8 } {
    const b = identityB64(s.keys.identity orelse return null);
    return .{ .enc = b.enc, .sig = b.sig };
}

// ---------------------------------------------------------------------------------------------
// Signing and unwrapping with keys the app cannot read (zui.keys)

fn signLater(s: *State, text: []const u8) ?[]const u8 {
    if (s.keys.identity == null) return null;
    const id = app.fx.key(.{ .op = .sign, .name = keyName(s, "sig"), .data = text }, onKeyMsg);
    return std.fmt.allocPrint(tmp(), "zui-sig-{d}", .{id}) catch null;
}

fn wrapSigned(s: *State, raw: [32]u8, chat: []const u8, epoch: i64, user: []const u8, enc: []const u8) ?crypto.Wrap {
    const u = crypto.wrapChatKeyUnsigned(tmp(), sys.random(), raw, chat, epoch, user, enc) catch return null;
    var w = u.wrap;
    w.sig = signLater(s, u.signed) orelse return null;
    return w;
}

/// Sends a request whose body may wait for signatures.
pub fn apiSigned(s: *State, method: zui.Method, path: []const u8, body: []const u8, op: app.Op) void {
    if (std.mem.indexOf(u8, body, "zui-sig-") == null) return app.api(s, method, path, body, op);
    const b = gpa.dupe(u8, body) catch return;
    const p = gpa.dupe(u8, path) catch return gpa.free(b);
    s.keys.jobs.append(gpa, .{ .body = b, .then = .{ .api = .{ .method = method, .path = p, .op = op } } }) catch return;
    fillJobs(s);
}

pub fn wsSendSigned(s: *State, typ: []const u8, d: []const u8) void {
    if (std.mem.indexOf(u8, d, "zui-sig-") == null) return app.wsSend(s, typ, d);
    const b = gpa.dupe(u8, d) catch return;
    s.keys.jobs.append(gpa, .{ .body = b, .then = .{ .ws = gpa.dupe(u8, typ) catch return gpa.free(b) } }) catch return;
    fillJobs(s);
}

/// Puts the signatures that arrived into the waiting bodies, and sends those that are complete.
fn fillJobs(s: *State) void {
    var i: usize = 0;
    while (i < s.keys.jobs.items.len) {
        const job = &s.keys.jobs.items[i];
        var out: std.ArrayList(u8) = .empty;
        var rest: []const u8 = job.body;
        var waiting = false;
        while (std.mem.indexOf(u8, rest, "zui-sig-")) |at| {
            out.appendSlice(gpa, rest[0..at]) catch return;
            var end = at + "zui-sig-".len;
            while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
            const rid = std.fmt.parseInt(u32, rest[at + "zui-sig-".len .. end], 10) catch 0;
            if (s.keys.sigs.get(rid)) |sig| out.appendSlice(gpa, sig) catch return else {
                out.appendSlice(gpa, rest[at..end]) catch return;
                waiting = true;
            }
            rest = rest[end..];
        }
        out.appendSlice(gpa, rest) catch return;
        gpa.free(job.body);
        job.body = out.toOwnedSlice(gpa) catch return;
        if (waiting) {
            i += 1;
            continue;
        }
        const done = s.keys.jobs.orderedRemove(i);
        defer gpa.free(done.body);
        switch (done.then) {
            .api => |x| {
                defer gpa.free(x.path);
                app.api(s, x.method, x.path, done.body, x.op);
            },
            .ws => |typ| {
                defer gpa.free(typ);
                app.wsSend(s, typ, done.body);
            },
        }
    }
    // Signatures no body waits for any more.
    if (s.keys.jobs.items.len == 0) {
        var it = s.keys.sigs.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        s.keys.sigs.clearRetainingCapacity();
    }
}

/// Starts unwrapping a chat key: ECDH of my key with the wrap's ephemeral one, HKDF into a key
/// zui keeps (crypto.zig's ecdhKey, byte for byte), then AES-GCM opens the wrap.
fn unwrap(s: *State, w: crypto.Wrap, chat: []const u8, epoch: i64, wrapper_sig: []const u8) bool {
    const a = tmp();
    const text = crypto.wrapSigned(a, chat, epoch, myId(s), w) catch return false;
    if (!crypto.verify(a, wrapper_sig, w.sig, text)) return false;
    const info = crypto.wrapInfo(a, chat, epoch, myId(s)) catch return false;
    const eph = crypto.fromB64(a, w.eph) catch return false;
    const iv = crypto.fromB64(a, w.iv) catch return false;
    const ct = crypto.fromB64(a, w.ct) catch return false;
    _ = app.fx.key(.{ .op = .ecdh, .name = keyName(s, "enc"), .peer = eph, .salt = eph, .info = info, .into = "reseal:unwrap" }, onKeyMsg);
    const rid = app.fx.key(.{ .op = .decrypt, .name = "reseal:unwrap", .iv = iv, .aad = info, .data = ct }, onKeyMsg);
    s.keys.unwraps.put(gpa, rid, .{ .chat = Id.of(chat), .epoch = epoch }) catch return false;
    return true;
}

/// An answer from zui.keys: a signature, or an unwrapped chat key.
pub fn onKey(s: *State, r: zui.keys.Result) void {
    if (s.keys.unwraps.fetchRemove(r.id)) |kv| {
        const chat = kv.value.chat.str();
        if (r.ok() and r.data.len == 32) remember(s, chat, kv.value.epoch, r.data[0..32].*) else zui.log("Could not unwrap key {s}#{d}", .{ chat, kv.value.epoch });
        const left = s.keys.unwrapping.getPtr(chat) orelse return;
        left.* -|= 1;
        if (left.* > 0) return;
        if (s.keys.unwrapping.fetchRemove(chat)) |e| gpa.free(e.key);
        if (s.keys.loading.fetchRemove(chat)) |e| gpa.free(e.key);
        return keysLoaded(s, chat);
    }
    if (r.ok() and r.data.len == 64) {
        const sig = crypto.toB64(gpa, r.data) catch return;
        s.keys.sigs.put(gpa, r.id, sig) catch return gpa.free(sig);
        return fillJobs(s);
    }
    if (r.status != .ok) {
        zui.log("zui.keys request {d}: {t}", .{ r.id, r.status });
        // A body waiting for a signature that will not come is dropped.
        var b: [24]u8 = undefined;
        const mark = std.fmt.bufPrint(&b, "zui-sig-{d}", .{r.id}) catch return;
        var i: usize = 0;
        while (i < s.keys.jobs.items.len) {
            if (std.mem.indexOf(u8, s.keys.jobs.items[i].body, mark) == null) {
                i += 1;
                continue;
            }
            const job = s.keys.jobs.orderedRemove(i);
            gpa.free(job.body);
            switch (job.then) {
                .api => |x| gpa.free(x.path),
                .ws => |x| gpa.free(x),
            }
        }
    }
}
