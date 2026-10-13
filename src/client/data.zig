//! Local copies of what the server sent: users, chats, message timelines. Port of Reseal-js
//! data/users.js, data/chats.js and the timeline part of data/messages.js.
//!
//! Server objects are kept as JSON values (std.json.Value) in an arena per object (`Obj`), the
//! way the web app keeps plain JS objects: partial updates merge into them (Object.assign).

const std = @import("std");
const zui = @import("zui");
const j = @import("j.zig");
const sys = @import("sys.zig");
const Value = j.Value;
const Allocator = std.mem.Allocator;

pub const gpa = zui.allocator;

// ---------------------------------------------------------------------------------------------
// Ids: Mongo ObjectIds (24 hex characters) and local ids; kept inline, no allocation.

pub const Id = struct {
    buf: [40]u8 = undefined,
    len: u8 = 0,

    pub fn of(s: []const u8) Id {
        var id: Id = .{};
        const n = @min(s.len, id.buf.len);
        @memcpy(id.buf[0..n], s[0..n]);
        id.len = @intCast(n);
        return id;
    }

    pub fn str(id: *const Id) []const u8 {
        return id.buf[0..id.len];
    }

    pub fn eql(id: Id, s: []const u8) bool {
        return std.mem.eql(u8, id.buf[0..id.len], s);
    }

    pub fn isSet(id: Id) bool {
        return id.len > 0;
    }
};

// ---------------------------------------------------------------------------------------------
// Obj: one server object with its own memory

pub const Obj = struct {
    arena: std.heap.ArenaAllocator,
    v: Value,
    merges: u32 = 0,

    pub fn create(src: Value) !*Obj {
        const o = try gpa.create(Obj);
        o.* = .{ .arena = .init(gpa), .v = j.emptyObject() };
        errdefer o.destroy();
        o.v = if (src == .object) try j.clone(o.arena.allocator(), src) else j.emptyObject();
        return o;
    }

    pub fn destroy(o: *Obj) void {
        o.arena.deinit();
        gpa.destroy(o);
    }

    pub fn alloc(o: *Obj) Allocator {
        return o.arena.allocator();
    }

    pub fn map(o: *Obj) *j.ObjectMap {
        return &o.v.object;
    }

    /// Object.assign(o, src). Every few merges the object is copied into fresh memory, so
    /// replaced values do not pile up.
    pub fn merge(o: *Obj, src: Value) !void {
        try j.assign(o.alloc(), o.map(), src);
        o.merges += 1;
        if (o.merges >= 32) try o.compact();
    }

    pub fn compact(o: *Obj) !void {
        var fresh: std.heap.ArenaAllocator = .init(gpa);
        const copy = j.clone(fresh.allocator(), o.v) catch |e| {
            fresh.deinit();
            return e;
        };
        o.arena.deinit();
        o.arena = fresh;
        o.v = copy;
        o.merges = 0;
    }

    pub fn set(o: *Obj, key: []const u8, val: Value) !void {
        try o.map().put(o.alloc(), try o.alloc().dupe(u8, key), try j.clone(o.alloc(), val));
    }

    /// Sets `key` inside the object field `parent` (created if missing), e.g. chat.me.unread.
    pub fn setIn(o: *Obj, parent: []const u8, key: []const u8, val: Value) !void {
        const a = o.alloc();
        const gop = try o.map().getOrPut(a, parent);
        if (!gop.found_existing or gop.value_ptr.* != .object) {
            gop.key_ptr.* = try a.dupe(u8, parent);
            gop.value_ptr.* = j.emptyObject();
        }
        try gop.value_ptr.object.put(a, try a.dupe(u8, key), try j.clone(a, val));
    }

    pub fn s(o: *const Obj, key: []const u8) ?[]const u8 {
        return j.str(o.v, key);
    }
    pub fn i(o: *const Obj, key: []const u8) ?i64 {
        return j.int(o.v, key);
    }
    pub fn b(o: *const Obj, key: []const u8) bool {
        return j.truthy(o.v, key);
    }
    pub fn get(o: *const Obj, key: []const u8) ?Value {
        return j.path(o.v, key);
    }
};

pub fn int(v: i64) Value {
    return .{ .integer = v };
}
pub fn boolean(v: bool) Value {
    return .{ .bool = v };
}
pub fn string(v: []const u8) Value {
    return .{ .string = v };
}
pub const null_value: Value = .null;

// ---------------------------------------------------------------------------------------------
// Messages

pub const Decrypt = enum { ok, pending, nokey, failed };
pub const SendState = enum { sent, sending, failed, scheduled };

pub const Message = struct {
    o: *Obj,
    /// Normalized content (both chat kinds): {text, entities, media, poll, location, contact,
    /// sticker, fwd, preview, buttons}; null for service and deleted messages, or until decrypted.
    content: ?Value = null,
    decrypt: Decrypt = .ok,
    /// Signature check of an encrypted message: true, false, or null (not known yet).
    verified: ?bool = null,
    state: SendState = .sent,
    /// Messages being sent: the local number and the client id the server echoes back.
    local_id: u32 = 0,
    at: i64 = 0,
    err: ?[]const u8 = null,
    /// Upload progress of a message being sent (0..1).
    progress: f32 = 0,

    pub fn destroy(m: *Message) void {
        m.o.destroy();
        gpa.destroy(m);
    }

    pub fn id(m: *const Message) []const u8 {
        return m.o.s("id") orelse "";
    }
    pub fn seq(m: *const Message) ?i64 {
        return m.o.i("seq");
    }
    pub fn kind(m: *const Message) []const u8 {
        return m.o.s("kind") orelse "message";
    }
    pub fn isService(m: *const Message) bool {
        return std.mem.eql(u8, m.kind(), "service");
    }
    pub fn deleted(m: *const Message) bool {
        return m.o.b("deleted");
    }
    pub fn senderId(m: *const Message) []const u8 {
        return m.o.s("senderId") orelse "";
    }
    /// Who wrote it (also for channel posts, where the sender is hidden).
    pub fn authorId(m: *const Message) []const u8 {
        return m.o.s("authorId") orelse m.o.s("senderId") orelse "";
    }
    pub fn text(m: *const Message) []const u8 {
        return j.str(m.content, "text") orelse "";
    }
    pub fn media(m: *const Message) []Value {
        return j.arr(m.content, "media");
    }
    pub fn enc(m: *const Message) ?Value {
        return j.obj(m.o.v, "enc");
    }
};

fn contentFromPlain(a: Allocator, raw: Value) !Value {
    var c: j.ObjectMap = .empty;
    try c.put(a, "text", string(j.strOr(raw, "text", "")));
    inline for (.{ "entities", "media", "location", "contact", "sticker", "preview", "buttons" }) |k| {
        if (j.field(raw, k)) |x| try c.put(a, k, x);
    }
    if (j.obj(raw, "poll")) |p| {
        var poll: j.ObjectMap = .empty;
        if (j.field(p, "question")) |q| try poll.put(a, "question", q);
        if (j.field(p, "options")) |q| try poll.put(a, "options", q);
        try c.put(a, "poll", .{ .object = poll });
    }
    if (j.obj(raw, "fwd")) |f| try c.put(a, "fwd", f);
    return .{ .object = c };
}

/// Content from a decrypted payload (short keys: t, ent, media, poll{q,o}, loc, contact, ...).
pub fn contentFromPayload(a: Allocator, p: Value) !Value {
    var c: j.ObjectMap = .empty;
    try c.put(a, "text", string(try a.dupe(u8, j.strOr(p, "t", ""))));
    if (j.field(p, "ent")) |x| try c.put(a, "entities", try j.clone(a, x));
    if (j.field(p, "media")) |x| try c.put(a, "media", try j.clone(a, x));
    if (j.obj(p, "poll")) |x| {
        var poll: j.ObjectMap = .empty;
        if (j.field(x, "q")) |q| try poll.put(a, "question", try j.clone(a, q));
        if (j.field(x, "o")) |q| try poll.put(a, "options", try j.clone(a, q));
        try c.put(a, "poll", .{ .object = poll });
    }
    inline for (.{ .{ "loc", "location" }, .{ "contact", "contact" }, .{ "sticker", "sticker" }, .{ "fwd", "fwd" }, .{ "preview", "preview" }, .{ "story", "story" } }) |kv| {
        if (j.field(p, kv[0])) |x| try c.put(a, kv[1], try j.clone(a, x));
    }
    return .{ .object = c };
}

/// A server message in the one shape both chat kinds use (messages.js normalize).
pub fn newMessage(raw: Value) !*Message {
    const o = try Obj.create(raw);
    errdefer o.destroy();
    const m = try gpa.create(Message);
    m.* = .{ .o = o };
    m.at = sys.parseIso(o.s("createdAt") orelse "") orelse 0;
    if (o.get("seq") == null and o.get("scheduledAt") != null) m.state = .scheduled;
    if (o.b("deleted") or m.isService()) {
        m.decrypt = .ok;
    } else if (o.get("enc") != null) {
        m.decrypt = .pending;
    } else {
        m.content = try contentFromPlain(o.alloc(), o.v);
        m.decrypt = .ok;
    }
    return m;
}

/// A copy (the chat list keeps its own copy of the last message).
pub fn cloneMessage(m: *const Message) !*Message {
    const o = try Obj.create(m.o.v);
    errdefer o.destroy();
    const c = try gpa.create(Message);
    c.* = m.*;
    c.o = o;
    c.content = if (m.content) |x| try j.clone(o.alloc(), x) else null;
    if (m.err) |e| c.err = try o.alloc().dupe(u8, e);
    return c;
}

// ---------------------------------------------------------------------------------------------
// Timelines (one per open chat)

pub const page = 50;

pub const Timeline = struct {
    items: std.ArrayList(*Message) = .empty,
    pending: std.ArrayList(*Message) = .empty,
    has_older: bool = true,
    has_newer: bool = false,
    loaded: bool = false,
    loading: bool = false,
    floor: i64 = 0,
    /// Opened by the person (counts for "least recently used").
    used: u64 = 0,

    pub fn find(tl: *Timeline, id: []const u8) ?*Message {
        if (id.len == 0) return null;
        for (tl.items.items) |m| if (std.mem.eql(u8, m.id(), id)) return m;
        return null;
    }

    pub fn findPending(tl: *Timeline, local_id: u32) ?*Message {
        for (tl.pending.items) |m| if (m.local_id == local_id) return m;
        return null;
    }

    pub fn findClient(tl: *Timeline, client_id: []const u8) ?usize {
        for (tl.pending.items, 0..) |m, i| if (std.mem.eql(u8, m.o.s("clientId") orelse "", client_id)) return i;
        return null;
    }

    pub fn clear(tl: *Timeline) void {
        for (tl.items.items) |m| m.destroy();
        tl.items.clearRetainingCapacity();
    }

    pub fn deinit(tl: *Timeline) void {
        tl.clear();
        for (tl.pending.items) |m| m.destroy();
        tl.items.deinit(gpa);
        tl.pending.deinit(gpa);
    }

    /// Replaces everything (latest page, or the window around a message).
    pub fn reset(tl: *Timeline, list: []*Message) !void {
        tl.clear();
        try tl.items.appendSlice(gpa, list);
        tl.loaded = true;
    }

    pub fn prepend(tl: *Timeline, list: []*Message) !void {
        var fresh: std.ArrayList(*Message) = .empty;
        defer fresh.deinit(gpa);
        for (list) |m| {
            if (tl.find(m.id()) != null) m.destroy() else try fresh.append(gpa, m);
        }
        try tl.items.insertSlice(gpa, 0, fresh.items);
    }

    /// A confirmed message, in seq order; replaces an existing copy. Takes ownership.
    pub fn insert(tl: *Timeline, m: *Message) !void {
        if (tl.find(m.id())) |old| {
            for (tl.items.items, 0..) |x, i| if (x == old) {
                tl.items.items[i] = m;
                old.destroy();
                return;
            };
        }
        const sq = m.seq() orelse {
            m.destroy();
            return;
        };
        if (tl.has_newer) {
            m.destroy();
            return;
        }
        var i = tl.items.items.len;
        while (i > 0 and (tl.items.items[i - 1].seq() orelse 0) > sq) i -= 1;
        try tl.items.insert(gpa, i, m);
    }

    pub fn remove(tl: *Timeline, id: []const u8) void {
        for (tl.items.items, 0..) |m, i| if (std.mem.eql(u8, m.id(), id)) {
            _ = tl.items.orderedRemove(i);
            m.destroy();
            return;
        };
    }

    pub fn dropPending(tl: *Timeline, local_id: u32) void {
        for (tl.pending.items, 0..) |m, i| if (m.local_id == local_id) {
            _ = tl.pending.orderedRemove(i);
            m.destroy();
            return;
        };
    }

    pub fn lastSeq(tl: *const Timeline) ?i64 {
        if (tl.items.items.len == 0) return null;
        return tl.items.items[tl.items.items.len - 1].seq();
    }

    pub fn firstSeq(tl: *const Timeline) ?i64 {
        if (tl.items.items.len == 0) return null;
        return tl.items.items[0].seq();
    }
};

// ---------------------------------------------------------------------------------------------
// Chats

pub const Typing = struct { user: Id, action: [24]u8 = undefined, action_len: u8 = 0, until: i64 };

pub const Chat = struct {
    o: *Obj,
    last: ?*Message = null,
    typing: std.ArrayList(Typing) = .empty,
    /// Keys for this chat were fetched (no need to ask again for a missing epoch until new ones arrive).
    keys_fetched: bool = false,

    pub fn destroy(c: *Chat) void {
        if (c.last) |m| m.destroy();
        c.typing.deinit(gpa);
        c.o.destroy();
        gpa.destroy(c);
    }

    pub fn id(c: *const Chat) []const u8 {
        return c.o.s("id") orelse "";
    }
    pub fn typ(c: *const Chat) []const u8 {
        return c.o.s("type") orelse "private";
    }
    pub fn is(c: *const Chat, t: []const u8) bool {
        return std.mem.eql(u8, c.typ(), t);
    }
    pub fn encrypted(c: *const Chat) bool {
        return c.o.b("encrypted");
    }
    pub fn me(c: *const Chat) ?Value {
        return j.obj(c.o.v, "me");
    }
    pub fn meInt(c: *const Chat, key: []const u8) i64 {
        return j.intOr(c.me(), key, 0);
    }
    pub fn meBool(c: *const Chat, key: []const u8) bool {
        return j.truthy(c.me(), key);
    }
    pub fn setMe(c: *Chat, key: []const u8, v: Value) void {
        c.o.setIn("me", key, v) catch {};
    }
    pub fn archived(c: *const Chat) bool {
        return c.meBool("archived");
    }
    pub fn keyEpoch(c: *const Chat) i64 {
        return c.o.i("keyEpoch") orelse 0;
    }
    pub fn seq(c: *const Chat) i64 {
        return c.o.i("seq") orelse 0;
    }
    pub fn peerId(c: *const Chat) ?[]const u8 {
        return j.str(c.o.v, "peer.id");
    }
    /// Last activity (last message, or a newer draft), for sorting.
    pub fn activity(c: *const Chat) i64 {
        const msg_at = if (c.last) |m| m.at else sys.parseIso(c.o.s("lastMessageAt") orelse c.o.s("createdAt") orelse "") orelse 0;
        const draft_at = sys.parseIso(j.str(c.me(), "draft.at") orelse "") orelse 0;
        return @max(msg_at, draft_at);
    }
    pub fn pinnedAt(c: *const Chat) i64 {
        return sys.parseIso(j.str(c.me(), "pinnedAt") orelse "") orelse 0;
    }
    pub fn mutedUntil(c: *const Chat) i64 {
        const v = j.field(c.me(), "mutedUntil") orelse return 0;
        return switch (v) {
            .string => |s| sys.parseIso(s) orelse 0,
            .integer => |n| n,
            .float => |f| @intFromFloat(f),
            else => 0,
        };
    }
    pub fn isMuted(c: *const Chat) bool {
        return c.mutedUntil() > sys.now();
    }
    pub fn unread(c: *const Chat) i64 {
        return c.meInt("unread");
    }
    pub fn role(c: *const Chat) []const u8 {
        return j.str(c.me(), "role") orelse "member";
    }
    pub fn isTeamChat(c: *const Chat) bool {
        return c.is("support") and c.o.get("team") != null;
    }
};

pub const Store = struct {
    me: ?*Obj = null,
    config: ?*Obj = null,
    users: std.StringHashMapUnmanaged(*Obj) = .empty,
    chats: std.StringHashMapUnmanaged(*Chat) = .empty,
    timelines: std.StringHashMapUnmanaged(*Timeline) = .empty,
    folders: ?*Obj = null,
    chats_loaded: bool = false,
    use_counter: u64 = 0,

    pub fn myId(st: *const Store) []const u8 {
        return if (st.me) |m| m.s("id") orelse "" else "";
    }

    pub fn isMe(st: *const Store, id: []const u8) bool {
        return id.len > 0 and std.mem.eql(u8, st.myId(), id);
    }

    // --- users ---

    pub fn user(st: *const Store, id: []const u8) ?*Obj {
        return st.users.get(id);
    }

    pub fn putUser(st: *Store, raw: Value) !?*Obj {
        const id = j.str(raw, "id") orelse return null;
        if (st.users.get(id)) |u| {
            try u.merge(raw);
            return u;
        }
        const u = try Obj.create(raw);
        errdefer u.destroy();
        try st.users.put(gpa, try gpa.dupe(u8, id), u);
        return u;
    }

    pub fn displayName(st: *const Store, id: []const u8) []const u8 {
        const u = st.user(id) orelse return "…";
        return userName(st, u);
    }

    pub fn userName(st: *const Store, u: *const Obj) []const u8 {
        if (st.isMe(u.s("id") orelse "")) return u.s("displayName") orelse "";
        return u.s("contactName") orelse u.s("displayName") orelse zui.i18n.t("Deleted account");
    }

    // --- chats ---

    pub fn chat(st: *const Store, id: []const u8) ?*Chat {
        return st.chats.get(id);
    }

    /// Adds or merges a chat from the server (chats.js prepare). Returns it.
    pub fn putChat(st: *Store, raw: Value) !*Chat {
        const id = j.str(raw, "id") orelse return error.BadChat;
        if (j.obj(raw, "peer")) |p| _ = try st.putUser(p);
        if (j.obj(raw, "visitor")) |p| _ = try st.putUser(p);
        const c = if (st.chats.get(id)) |c| blk: {
            try c.o.merge(raw);
            break :blk c;
        } else blk: {
            const o = try Obj.create(raw);
            errdefer o.destroy();
            const c = try gpa.create(Chat);
            c.* = .{ .o = o };
            try st.chats.put(gpa, try gpa.dupe(u8, id), c);
            break :blk c;
        };
        if (j.field(raw, "lastMessage")) |lm| {
            if (c.last) |old| old.destroy();
            c.last = if (lm == .object) try newMessage(lm) else null;
        } else if (raw == .object and raw.object.contains("lastMessage")) {
            if (c.last) |old| old.destroy();
            c.last = null;
        }
        return c;
    }

    pub fn removeChat(st: *Store, id: []const u8) void {
        if (st.chats.fetchRemove(id)) |kv| {
            gpa.free(kv.key);
            kv.value.destroy();
        }
        if (st.timelines.fetchRemove(id)) |kv| {
            gpa.free(kv.key);
            kv.value.deinit();
            gpa.destroy(kv.value);
        }
    }

    pub fn title(st: *const Store, c: *const Chat) []const u8 {
        const t = zui.i18n.t;
        if (c.is("saved")) return if (c.o.b("primary") or c.o.s("title") == null) t("Saved") else c.o.s("title").?;
        if ((c.is("private") or c.is("bot"))) {
            if (c.peerId()) |pid| {
                if (st.user(pid)) |u| return st.userName(u);
                return j.str(c.o.v, "peer.displayName") orelse "…";
            }
        }
        if (c.isTeamChat()) {
            if (st.isTeamStaff(c)) {
                const vid = j.str(c.o.v, "visitor.id") orelse "";
                return st.displayName(vid);
            }
            return j.str(c.o.v, "team.name") orelse "";
        }
        return c.o.s("title") orelse t("Chat");
    }

    /// Am I answering for the team in this chat (rather than being the customer)?
    pub fn isTeamStaff(st: *const Store, c: *const Chat) bool {
        if (!c.isTeamChat()) return false;
        const vid = j.str(c.o.v, "visitor.id") orelse return false;
        return std.mem.eql(u8, c.role(), "admin") and !st.isMe(vid);
    }

    pub fn showsSenderNames(st: *const Store, c: *const Chat) bool {
        return c.is("group") or (c.is("support") and !st.isTeamStaff(c));
    }

    pub fn peer(st: *const Store, c: *const Chat) ?*Obj {
        return st.user(c.peerId() orelse return null);
    }

    /// The chat list order: pinned first (in pin order), then by last activity.
    pub fn sorted(st: *const Store, a: Allocator, archived: bool) []*Chat {
        var list: std.ArrayList(*Chat) = .empty;
        var it = st.chats.valueIterator();
        while (it.next()) |c| if (c.*.archived() == archived) list.append(a, c.*) catch break;
        std.mem.sort(*Chat, list.items, {}, struct {
            fn lt(_: void, x: *Chat, y: *Chat) bool {
                const px = x.pinnedAt();
                const py = y.pinnedAt();
                if (px != 0 or py != 0) {
                    if (px != 0 and py != 0) return px < py;
                    return px != 0;
                }
                const ax = x.activity();
                const ay = y.activity();
                if (ax != ay) return ax > ay;
                return std.mem.order(u8, x.id(), y.id()) == .lt;
            }
        }.lt);
        return list.items;
    }

    pub fn savedChat(st: *const Store) ?*Chat {
        var first: ?*Chat = null;
        var it = st.chats.valueIterator();
        while (it.next()) |c| {
            if (!c.*.is("saved")) continue;
            if (c.*.o.b("primary")) return c.*;
            if (first == null) first = c.*;
        }
        return first;
    }

    pub const Totals = struct { unread: i64 = 0, chats_unread: i64 = 0, archived_unread: i64 = 0, saved_unread: i64 = 0 };

    pub fn totals(st: *const Store) Totals {
        var out: Totals = .{};
        var it = st.chats.valueIterator();
        while (it.next()) |cp| {
            const c = cp.*;
            const n = c.unread() + @as(i64, @intFromBool(c.meBool("markedUnread")));
            if (n == 0) continue;
            if (c.is("saved")) {
                out.saved_unread += n;
                continue;
            }
            if (c.archived()) {
                if (!c.isMuted()) out.archived_unread += n;
                continue;
            }
            if (!c.isMuted()) {
                out.unread += n;
                out.chats_unread += 1;
            }
        }
        return out;
    }

    // --- timelines ---

    pub fn timeline(st: *Store, chat_id: []const u8) !*Timeline {
        st.use_counter += 1;
        if (st.timelines.get(chat_id)) |tl| {
            tl.used = st.use_counter;
            return tl;
        }
        // Keep memory bounded: forget the least recently used timeline beyond 25.
        if (st.timelines.count() >= 25) {
            var oldest: ?[]const u8 = null;
            var oldest_used: u64 = std.math.maxInt(u64);
            var it = st.timelines.iterator();
            while (it.next()) |e| if (e.value_ptr.*.used < oldest_used and e.value_ptr.*.pending.items.len == 0) {
                oldest_used = e.value_ptr.*.used;
                oldest = e.key_ptr.*;
            };
            if (oldest) |k| if (st.timelines.fetchRemove(k)) |kv| {
                gpa.free(kv.key);
                kv.value.deinit();
                gpa.destroy(kv.value);
            };
        }
        const tl = try gpa.create(Timeline);
        tl.* = .{ .used = st.use_counter };
        try st.timelines.put(gpa, try gpa.dupe(u8, chat_id), tl);
        return tl;
    }

    pub fn existingTimeline(st: *const Store, chat_id: []const u8) ?*Timeline {
        return st.timelines.get(chat_id);
    }

    pub fn reset(st: *Store) void {
        if (st.me) |m| m.destroy();
        if (st.config) |m| m.destroy();
        if (st.folders) |m| m.destroy();
        var ui = st.users.iterator();
        while (ui.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.destroy();
        }
        st.users.deinit(gpa);
        var ci = st.chats.iterator();
        while (ci.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.destroy();
        }
        st.chats.deinit(gpa);
        var ti = st.timelines.iterator();
        while (ti.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.deinit();
            gpa.destroy(e.value_ptr.*);
        }
        st.timelines.deinit(gpa);
        st.* = .{};
    }
};

test "chats merge and sort" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: Store = .{};
    defer st.reset();
    _ = try st.putChat(j.parse(a, "{\"id\":\"c1\",\"type\":\"group\",\"title\":\"A\",\"lastMessageAt\":\"2026-01-01T00:00:00Z\",\"me\":{\"unread\":2}}").?);
    _ = try st.putChat(j.parse(a, "{\"id\":\"c2\",\"type\":\"private\",\"peer\":{\"id\":\"u2\",\"displayName\":\"Bob\"},\"lastMessage\":{\"id\":\"m1\",\"seq\":1,\"text\":\"hi\",\"createdAt\":\"2026-02-01T00:00:00Z\"}}").?);
    const list = st.sorted(a, false);
    try std.testing.expectEqualStrings("c2", list[0].id());
    try std.testing.expectEqualStrings("Bob", st.title(list[0]));
    try std.testing.expectEqualStrings("hi", list[0].last.?.text());
    _ = try st.putChat(j.parse(a, "{\"id\":\"c1\",\"title\":\"B\"}").?);
    try std.testing.expectEqualStrings("B", st.title(st.chat("c1").?));
    try std.testing.expectEqual(@as(i64, 2), st.totals().unread);
}
