//! Searching an encrypted chat's whole history (Reseal-js data/index.js): the server cannot read
//! it, so "Search everything" walks the history page by page, decrypts it here and keeps the
//! texts on this device, encrypted (AES-GCM) with a key kept in secure storage, one record per
//! chat; logging out forgets them.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");
const crypto = @import("crypto.zig");
const sys = @import("sys.zig");

const State = app.State;
const Id = app.Id;
const tmp = app.tmp;
const gpa = app.gpa;

const page = 100;
/// Between pages, as Reseal-js paces its walk.
const pace_ms = 300;

pub const Entry = struct {
    id: Id,
    seq: i64,
    at: i64,
    sender: Id,
    text: []u8,
};

pub const Index = struct {
    chat: Id = .{},
    entries: std.ArrayList(Entry) = .empty,
    /// The next page is the one before this sequence number.
    before: i64 = 0,
    running: bool = false,
    complete: bool = false,
    seq: u32 = 0,

    fn reset(x: *Index) void {
        for (x.entries.items) |e| gpa.free(e.text);
        x.entries.clearRetainingCapacity();
        x.running = false;
        x.complete = false;
        x.before = 0;
        x.seq +%= 1;
    }
};

pub const Act = union(enum) {
    start,
    next: u32,
};

/// What a message is found by: its text, file names, poll question, place, contact.
fn textOf(a: std.mem.Allocator, m: *const data.Message) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const c = m.content orelse return "";
    const add = struct {
        fn f(al: std.mem.Allocator, o: *std.ArrayList(u8), x: ?[]const u8) void {
            const v = x orelse return;
            if (v.len == 0) return;
            if (o.items.len > 0) o.append(al, ' ') catch {};
            o.appendSlice(al, v) catch {};
        }
    }.f;
    add(a, &out, j.str(c, "text"));
    for (j.arr(c, "media")) |it| add(a, &out, j.str(it, "name"));
    add(a, &out, j.str(c, "poll.question"));
    add(a, &out, j.str(c, "location.title"));
    add(a, &out, j.str(c, "contact.name"));
    return out.items[0..@min(out.items.len, 4000)];
}

pub fn act(s: *State, a: Act) void {
    const x = &s.chat_index;
    switch (a) {
        .start => {
            const chat = s.open_chat;
            if (!chat.isSet()) return;
            if (!x.chat.eql(chat.str())) {
                x.reset();
                x.chat = chat;
                load(s);
            }
            if (x.running or x.complete) return;
            if (x.before == 0) {
                // From the oldest message loaded (newer ones are searched where they are).
                const c = s.store.chat(chat.str()) orelse return;
                x.before = c.seq() + 1;
                if (s.store.existingTimeline(chat.str())) |tl| if (tl.items.items.len > 0) {
                    x.before = tl.items.items[0].seq() orelse x.before;
                };
            }
            x.running = true;
            fetch(s);
        },
        .next => |seq| if (seq == x.seq and x.running) fetch(s),
    }
}

fn fetch(s: *State) void {
    const x = &s.chat_index;
    if (x.before <= 1) {
        x.running = false;
        x.complete = true;
        return;
    }
    app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/{s}/messages?limit={d}&before={d}", .{ x.chat.str(), page, x.before }) catch return, null, .{ .chat_index = x.seq });
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const seq = switch (op) {
        .chat_index => |q| q,
        else => return false,
    };
    const x = &s.chat_index;
    if (seq != x.seq) return true;
    if (!r.ok()) {
        x.running = false;
        return true;
    }
    const v = j.parse(tmp(), r.body);
    const list = j.arr(v, "messages");
    var oldest = x.before;
    for (list) |raw| {
        const m = data.newMessage(raw) catch continue;
        defer m.destroy();
        const sq = m.seq() orelse continue;
        oldest = @min(oldest, sq);
        if (m.isService() or m.deleted()) continue;
        keys.hydrate(s, x.chat.str(), m);
        if (m.decrypt != .ok) continue;
        const text = textOf(tmp(), m);
        if (text.len == 0) continue;
        x.entries.append(gpa, .{
            .id = Id.of(m.id()),
            .seq = sq,
            .at = m.at,
            .sender = Id.of(m.senderId()),
            .text = gpa.dupe(u8, text) catch continue,
        }) catch {};
    }
    defer save(s);
    const floor = j.intOr(v, "floor", 0);
    if (list.len < page or oldest <= @max(1, floor + 1) or oldest >= x.before) {
        x.running = false;
        x.complete = true;
        x.before = oldest;
        return true;
    }
    x.before = oldest;
    app.fx.after(pace_ms, .{ .chat_index = .{ .next = x.seq } });
    return true;
}

// ---------------------------------------------------------------------------------------------
// On the device, encrypted

const max_bytes = 3 * 1024 * 1024;

fn recordKey(s: *const State, chat: []const u8) []const u8 {
    return std.fmt.allocPrint(tmp(), "idx:{s}:{s}", .{ s.store.myId(), chat }) catch "";
}

/// This device's index key (made once, kept in secure storage).
fn indexKey(s: *const State) ?[32]u8 {
    const name = std.fmt.allocPrint(tmp(), "idxkey:{s}", .{s.store.myId()}) catch return null;
    if (zui.storage.get(tmp(), name, .{ .secure = true })) |b64| {
        const raw = crypto.fromB64(tmp(), b64) catch return null;
        if (raw.len == 32) return raw[0..32].*;
    }
    const k = sys.randomBytes(32);
    zui.storage.set(name, crypto.toB64(tmp(), &k) catch return null, .{ .secure = true });
    return k;
}

/// The chats with a record (to forget them all at log out).
fn listKey(s: *const State) []const u8 {
    return std.fmt.allocPrint(tmp(), "idx:{s}", .{s.store.myId()}) catch "";
}

fn save(s: *State) void {
    const x = &s.chat_index;
    if (!x.chat.isSet() or s.store.myId().len == 0) return;
    const key = indexKey(s) orelse return;
    const a = tmp();
    var out: std.ArrayList(u8) = .empty;
    out.print(a, "{{\"before\":{d},\"complete\":{},\"e\":[", .{ x.before, x.complete }) catch return;
    for (x.entries.items, 0..) |e, i| {
        if (out.items.len > max_bytes) break;
        out.print(a, "{s}[\"{s}\",{d},{d},\"{s}\",{s}]", .{ if (i > 0) "," else "", e.id.str(), e.seq, e.at, e.sender.str(), j.quote(a, e.text) catch "\"\"" }) catch return;
    }
    out.appendSlice(a, "]}") catch return;
    const iv = sys.randomBytes(12);
    const sealed = crypto.seal(a, key, iv, x.chat.str(), out.items) catch return;
    const rec = std.fmt.allocPrint(a, "{s}.{s}", .{ crypto.toB64(a, &iv) catch return, crypto.toB64(a, sealed) catch return }) catch return;
    zui.storage.set(recordKey(s, x.chat.str()), rec, .{});
    // Remember the chat for log out.
    const list = zui.storage.get(a, listKey(s), .{}) orelse "";
    if (std.mem.indexOf(u8, list, x.chat.str()) == null)
        zui.storage.set(listKey(s), std.fmt.allocPrint(a, "{s}{s}{s}", .{ list, if (list.len > 0) "," else "", x.chat.str() }) catch return, .{});
}

fn load(s: *State) void {
    const x = &s.chat_index;
    const a = tmp();
    const rec = zui.storage.get(a, recordKey(s, x.chat.str()), .{}) orelse return;
    const dot = std.mem.indexOfScalar(u8, rec, '.') orelse return;
    const key = indexKey(s) orelse return;
    const iv = crypto.fromB64(a, rec[0..dot]) catch return;
    if (iv.len != 12) return;
    const sealed = crypto.fromB64(a, rec[dot + 1 ..]) catch return;
    const plain = crypto.open(a, key, iv[0..12].*, x.chat.str(), sealed) catch return;
    const v = j.parse(a, plain) orelse return;
    x.before = j.intOr(v, "before", 0);
    x.complete = j.truthy(v, "complete");
    for (j.arr(v, "e")) |e| {
        if (e != .array or e.array.items.len < 5) continue;
        const it = e.array.items;
        if (it[0] != .string or it[3] != .string or it[4] != .string) continue;
        x.entries.append(gpa, .{
            .id = Id.of(it[0].string),
            .seq = if (it[1] == .integer) it[1].integer else 0,
            .at = if (it[2] == .integer) it[2].integer else 0,
            .sender = Id.of(it[3].string),
            .text = gpa.dupe(u8, it[4].string) catch continue,
        }) catch {};
    }
}

/// The open chat's saved index, if it is not in memory yet (the search sheet opened).
pub fn ensureLoaded(s: *State) void {
    const x = &s.chat_index;
    if (x.chat.eql(s.open_chat.str()) or !s.open_chat.isSet()) return;
    x.reset();
    x.chat = s.open_chat;
    load(s);
}

/// Log out: every saved index and its key go.
pub fn forgetAll(s: *State) void {
    const a = tmp();
    if (s.store.myId().len == 0) return;
    const list = zui.storage.get(a, listKey(s), .{}) orelse "";
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |chat| if (chat.len > 0) zui.storage.remove(recordKey(s, chat), .{});
    zui.storage.remove(listKey(s), .{});
    zui.storage.remove(std.fmt.allocPrint(a, "idxkey:{s}", .{s.store.myId()}) catch return, .{ .secure = true });
    s.chat_index.reset();
    s.chat_index.chat = .{};
}

/// Index entries of the open chat (none for another chat).
pub fn entries(s: *const State) []const Entry {
    if (!s.chat_index.chat.eql(s.open_chat.str())) return &.{};
    return s.chat_index.entries.items;
}

pub fn status(s: *const State) struct { running: bool, complete: bool, count: usize } {
    const mine = s.chat_index.chat.eql(s.open_chat.str());
    return .{ .running = mine and s.chat_index.running, .complete = mine and s.chat_index.complete, .count = if (mine) s.chat_index.entries.items.len else 0 };
}
