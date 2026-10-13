//! The key manager: this device's identity, chat keys, rotation, sharing keys with members who
//! need them, and decrypting messages. Port of Reseal-js data/e2ee.js.
//!
//! The identity's private keys live in zui.storage with .secure (Android Keystore, iOS
//! Keychain; localStorage on the web, where the web app kept them in IndexedDB) as the same
//! bundle JSON the backups carry. Chat keys stay in memory and are fetched again (wrapped for
//! this account) from the server after a restart.

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

pub const Keys = struct {
    identity: ?crypto.Identity = null,
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

fn storeIdentity(s: *State, id: crypto.Identity) void {
    s.keys.identity = id;
    const bundle = crypto.bundleJson(tmp(), id) catch return;
    zui.storage.set(storageKey(s), bundle, .{ .secure = true });
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
    if (myId(s).len > 0) zui.storage.remove(storageKey(s), .{ .secure = true });
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
    if (zui.storage.get(tmp(), storageKey(s), .{ .secure = true })) |stored| {
        if (crypto.identityFromBundle(tmp(), stored)) |id| {
            const pub_b64 = crypto.toB64(tmp(), &id.enc_public) catch "";
            const sig_b64 = crypto.toB64(tmp(), &id.sig_public) catch "";
            if (enc != null and std.mem.eql(u8, enc.?, pub_b64) and std.mem.eql(u8, me.s("keys.sig") orelse "", sig_b64)) {
                s.keys.identity = id;
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

fn identityB64(id: crypto.Identity) struct { enc: []const u8, sig: []const u8 } {
    return .{ .enc = crypto.toB64(tmp(), &id.enc_public) catch "", .sig = crypto.toB64(tmp(), &id.sig_public) catch "" };
}

/// Answers for the key manager's requests; false when the op is not one of them.
pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const a = tmp();
    const v = j.parse(a, r.body);
    switch (op) {
        .keys_setup_auto => |x| {
            defer gpa.destroy(x.id);
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
    const id = s.keys.identity orelse return;
    const v = j.parse(a, body) orelse return;
    var missing = false;
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
        const raw = crypto.unwrapChatKey(a, wrap, chat, epoch, myId(s), id.enc_secret, sig) catch {
            zui.log("Could not unwrap key {s}#{d}", .{ chat, epoch });
            continue;
        };
        remember(s, chat, epoch, raw);
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
    const id = s.keys.identity orelse return endRotation(s, chat);
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
        const w = crypto.wrapChatKey(a, sys.random(), raw, chat, epoch, uid, enc, id.sig_secret) catch continue;
        wraps.print(a, "{s}{s}", .{ if (n == 0) "" else ",", wrapJson(a, w) }) catch {};
        n += 1;
    }
    wraps.appendSlice(a, "]}") catch {};
    app.api(s, .POST, std.fmt.allocPrint(a, "/chats/{s}/keys", .{chat}) catch return, wraps.items, .{ .keys_post_rotate = .{ .chat = Id.of(chat), .epoch = epoch, .raw = raw } });
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
    const id = s.keys.identity orelse return;
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
            const w = crypto.wrapChatKey(a, sys.random(), raw, q.chat.str(), q.epoch, o.user.str(), e, id.sig_secret) catch continue;
            body.print(a, "{s}{s}", .{ if (n == 0) "" else ",", wrapJson(a, w) }) catch {};
            n += 1;
        }
        body.appendSlice(a, "]}") catch {};
        if (n > 0) app.api(s, .POST, std.fmt.allocPrint(a, "/chats/{s}/keys", .{q.chat.str()}) catch continue, body.items, .keys_post_share);
    }
}

// ---------------------------------------------------------------------------------------------
// Decrypting messages (messages.js hydrate)

fn cacheKey(m: *const data.Message) []const u8 {
    return std.fmt.allocPrint(tmp(), "{s}:{s}", .{ m.id(), m.o.s("editedAt") orelse "" }) catch "";
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
pub fn encrypt(s: *State, chat: *data.Chat, payload_json: []const u8) ?[]const u8 {
    const id = s.keys.identity orelse return null;
    const epoch = chat.keyEpoch();
    const key = keyFor(s, chat.id(), epoch) orelse return null;
    const a = tmp();
    const env = crypto.encryptMessage(a, sys.random(), key, payload_json, chat.id(), epoch, myId(s), id.sig_secret) catch return null;
    return crypto.envelopeJson(a, env) catch null;
}

pub fn signText(s: *const State, text: []const u8) ?[]const u8 {
    const id = s.keys.identity orelse return null;
    return crypto.sign(tmp(), id.sig_secret, text) catch null;
}

pub fn verifyFrom(s: *const State, user_id: []const u8, signature: []const u8, text: []const u8) bool {
    const sig = senderSig(s, user_id) orelse return false;
    return crypto.verify(tmp(), sig, signature, text);
}

pub fn myPublic(s: *const State) ?struct { enc: []const u8, sig: []const u8 } {
    const id = s.keys.identity orelse return null;
    const b = identityB64(id);
    return .{ .enc = b.enc, .sig = b.sig };
}
