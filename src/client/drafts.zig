//! Drafts (Reseal-js ui/drafts.js): what was typed in a chat stays when you leave it, kept on
//! this device at once and on the server 1.5 s after typing stops, so other devices have it too
//! (encrypted with the chat key in end-to-end encrypted chats). The newer of the local and the
//! server copy wins when a chat opens. The chat list shows "Draft: …" for chats with one.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");
const crypto = @import("crypto.zig");

const State = app.State;
const Id = app.Id;
const tmp = app.tmp;
const gpa = app.gpa;

pub const Drafts = struct {
    /// Chat id -> the draft's text, for the chat list.
    texts: std.StringHashMapUnmanaged([]u8) = .empty,
    seq: u32 = 0,
};

fn storageKey(chat: []const u8) []const u8 {
    return std.fmt.allocPrint(tmp(), "draft:{s}", .{chat}) catch "draft:";
}

fn setText(s: *State, chat: []const u8, text: []const u8) void {
    const d = &s.drafts;
    if (text.len == 0) {
        if (d.texts.fetchRemove(chat)) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value);
        }
        return;
    }
    const v = gpa.dupe(u8, text) catch return;
    if (d.texts.getPtr(chat)) |old| {
        gpa.free(old.*);
        old.* = v;
    } else d.texts.put(gpa, gpa.dupe(u8, chat) catch return gpa.free(v), v) catch gpa.free(v);
}

/// The draft text to show in the chat list (not for the open chat).
pub fn preview(s: *const State, chat: []const u8) ?[]const u8 {
    if (s.open_chat.eql(chat)) return null;
    return s.drafts.texts.get(chat);
}

/// The composer changed: keep it here now, on the server a moment later.
pub fn typed(s: *State) void {
    if (!s.open_chat.isSet() or s.editing.isSet()) return;
    const chat = s.open_chat.str();
    const text = s.fields.get(.composer).get();
    saveLocal(s, chat, text);
    s.drafts.seq +%= 1;
    app.fx.after(1500, .{ .draft_due = .{ .chat = s.open_chat, .seq = s.drafts.seq } });
}

fn saveLocal(s: *State, chat: []const u8, text: []const u8) void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        zui.storage.remove(storageKey(chat), .{});
        setText(s, chat, "");
        return;
    }
    const a = tmp();
    const v = std.fmt.allocPrint(a, "{{\"text\":{s},\"replyTo\":{s},\"at\":{d}}}", .{ j.quote(a, text) catch return, if (s.reply_to.isSet()) (std.fmt.allocPrint(a, "\"{s}\"", .{s.reply_to.str()}) catch "null") else "null", sys.now() }) catch return;
    zui.storage.set(storageKey(chat), v, .{});
    setText(s, chat, text);
}

/// 1.5 s after typing stopped: the server copy.
pub fn due(s: *State, chat: Id, seq: u32) void {
    if (seq != s.drafts.seq) return;
    const local = zui.storage.get(tmp(), storageKey(chat.str()), .{});
    const v = if (local) |l| j.parse(tmp(), l) else null;
    send(s, chat.str(), j.strOr(v, "text", ""), j.str(v, "replyTo"));
}

fn send(s: *State, chat_id: []const u8, text: []const u8, reply_to: ?[]const u8) void {
    const c = s.store.chat(chat_id) orelse return;
    const a = tmp();
    const path = std.fmt.allocPrint(a, "/chats/{s}/state", .{chat_id}) catch return;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        if (c.me()) |me| if (j.field(me, "draft")) |dv| if (dv != .null) app.api(s, .POST, path, "{\"draft\":null}", .{ .draft_saved = Id.of(chat_id) });
        return;
    }
    const rt = if (reply_to) |r| std.fmt.allocPrint(a, "\"{s}\"", .{r}) catch "null" else "null";
    var body: []const u8 = undefined;
    if (c.encrypted()) {
        const epoch = c.keyEpoch();
        const key = keys.keyFor(s, chat_id, epoch) orelse return;
        const env = crypto.encryptDraft(a, sys.random(), key, epoch, std.fmt.allocPrint(a, "{{\"text\":{s}}}", .{j.quote(a, text) catch return}) catch return, chat_id) catch return;
        body = std.fmt.allocPrint(a, "{{\"draft\":{{\"enc\":{s},\"replyTo\":{s}}}}}", .{ crypto.envelopeJson(a, env) catch return, rt }) catch return;
    } else {
        body = std.fmt.allocPrint(a, "{{\"draft\":{{\"text\":{s},\"replyTo\":{s}}}}}", .{ j.quote(a, text) catch return, rt }) catch return;
    }
    app.api(s, .POST, path, body, .{ .draft_saved = Id.of(chat_id) });
}

/// The draft to restore when a chat opens: the newer of this device's and the server's.
pub fn restore(s: *State, chat_id: []const u8) void {
    const c = s.store.chat(chat_id) orelse return;
    const a = tmp();
    const local = if (zui.storage.get(a, storageKey(chat_id), .{})) |l| j.parse(a, l) else null;
    const local_at = j.intOr(local, "at", 0);
    var text: []const u8 = j.strOr(local, "text", "");
    var reply: ?[]const u8 = j.str(local, "replyTo");
    if (c.me()) |me| if (j.obj(me, "draft")) |dv| {
        const server_at = sys.parseIso(j.strOr(dv, "at", "")) orelse 0;
        if (local == null or server_at > local_at) {
            if (serverText(s, c, dv)) |t| {
                text = t;
                reply = j.str(dv, "replyTo");
            }
        }
    };
    if (text.len == 0) return;
    s.fields.getPtr(.composer).set(text);
    if (reply) |r| if (r.len > 0) {
        s.reply_to = Id.of(r);
    };
    setText(s, chat_id, text);
}

fn serverText(s: *State, c: *const data.Chat, dv: j.Value) ?[]const u8 {
    if (j.obj(dv, "enc")) |ev| {
        const a = tmp();
        const env = std.json.parseFromValueLeaky(crypto.Envelope, a, ev, .{ .ignore_unknown_fields = true }) catch return null;
        const key = keys.keyFor(s, c.id(), env.e) orelse return null;
        const plain = crypto.decryptDraft(a, key, env, c.id()) catch return null;
        return j.strOr(j.parse(a, plain), "text", "");
    }
    return j.str(dv, "text");
}

/// The chat list's previews for drafts made on other devices (when their keys are here).
pub fn refresh(s: *State) void {
    var it = s.store.chats.valueIterator();
    while (it.next()) |cp| {
        const c = cp.*;
        if (s.drafts.texts.contains(c.id())) continue;
        const a = tmp();
        if (zui.storage.get(a, storageKey(c.id()), .{})) |l| {
            setText(s, c.id(), j.strOr(j.parse(a, l), "text", ""));
            continue;
        }
        const me = c.me() orelse continue;
        const dv = j.obj(me, "draft") orelse continue;
        if (serverText(s, c, dv)) |t| setText(s, c.id(), t);
    }
}

/// Sent: no draft any more.
pub fn clear(s: *State, chat_id: []const u8) void {
    zui.storage.remove(storageKey(chat_id), .{});
    setText(s, chat_id, "");
    s.drafts.seq +%= 1;
    if (s.store.chat(chat_id)) |c| if (c.me()) |me| if (j.field(me, "draft")) |dv| if (dv != .null) {
        app.api(s, .POST, std.fmt.allocPrint(tmp(), "/chats/{s}/state", .{chat_id}) catch return, "{\"draft\":null}", .{ .draft_saved = Id.of(chat_id) });
    };
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    switch (op) {
        .draft_saved => |chat| if (r.ok()) {
            if (j.obj(j.parse(tmp(), r.body), "me")) |me| if (s.store.chat(chat.str())) |c| c.o.set("me", j.clone(c.o.alloc(), me) catch return true) catch {};
        },
        else => return false,
    }
    return true;
}
