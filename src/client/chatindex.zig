//! Searching an encrypted chat's whole history (Reseal-js data/index.js): the server cannot read
//! it, so "Search everything" walks the history page by page, decrypts it here and keeps the
//! texts for this session (in memory only: nothing decrypted is written to the device).

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");

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

/// Index entries of the open chat (none for another chat).
pub fn entries(s: *const State) []const Entry {
    if (!s.chat_index.chat.eql(s.open_chat.str())) return &.{};
    return s.chat_index.entries.items;
}

pub fn status(s: *const State) struct { running: bool, complete: bool, count: usize } {
    const mine = s.chat_index.chat.eql(s.open_chat.str());
    return .{ .running = mine and s.chat_index.running, .complete = mine and s.chat_index.complete, .count = if (mine) s.chat_index.entries.items.len else 0 };
}
