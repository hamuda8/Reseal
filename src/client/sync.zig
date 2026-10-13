//! Keeping local state in step with the server: the chat list, message timelines, realtime
//! events from /ws (port of Reseal-js data/sync.js), typing indicators, read receipts and
//! notifications.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");
const send = @import("send.zig");
const calls = @import("calls.zig");
const fmt = @import("fmt.zig");
const text = @import("text.zig");

const State = app.State;
const Id = app.Id;
const gpa = app.gpa;
const t = zui.i18n.t;
const tmp = app.tmp;

/// Something the screen shows changed (zui redraws after every update; kept for clarity).
pub fn changed(_: *State) void {}

// ---------------------------------------------------------------------------------------------
// Chat list

pub fn onChats(s: *State, r: zui.Response) void {
    if (!r.ok()) {
        if (r.status == 401) return app.signedOut(s);
        return app.toastError(s, app.apiError(r).message);
    }
    const v = j.parse(tmp(), r.body) orelse return;
    var seen = std.StringHashMap(void).init(tmp());
    for (j.arr(v, "chats")) |raw| {
        const c = s.store.putChat(raw) catch continue;
        seen.put(c.id(), {}) catch {};
        if (c.last) |m| keys.hydrate(s, c.id(), m);
    }
    var drop: std.ArrayList([]const u8) = .empty;
    var it = s.store.chats.keyIterator();
    while (it.next()) |k| if (!seen.contains(k.*)) drop.append(tmp(), tmp().dupe(u8, k.*) catch continue) catch {};
    for (drop.items) |id| s.store.removeChat(id);
    s.store.chats_loaded = true;
    // An embedded widget may open a chat right away.
    if (s.mode == .embed) @import("views.zig").embedAfterChats(s);
    if (s.pending_open.isSet()) {
        const id = s.pending_open;
        s.pending_open = .{};
        @import("views.zig").openChat(s, id.str());
    }
    if (s.pending_username.isSet()) {
        const name = s.pending_username;
        s.pending_username = .{};
        app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/by-username/{s}", .{j.urlEncode(tmp(), name.str()) catch return}) catch return, null, .open_username);
    }
    if (s.open_chat.isSet()) {
        if (s.store.chat(s.open_chat.str()) == null) s.open_chat = .{};
    }
}

pub fn ensureChat(s: *State, id: []const u8) void {
    if (s.store.chat(id) != null) return;
    app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/{s}", .{id}) catch return, null, .{ .chat_ensure = Id.of(id) });
}

// ---------------------------------------------------------------------------------------------
// Timelines

pub fn loadMessages(s: *State, chat: []const u8, mode: app.LoadMode, seq: i64) void {
    const tl = s.store.timeline(chat) catch return;
    if (tl.loading) return;
    tl.loading = true;
    const a = tmp();
    const q = switch (mode) {
        .latest => std.fmt.allocPrint(a, "limit={d}", .{data.page}),
        .older => std.fmt.allocPrint(a, "limit={d}&before={d}", .{ data.page, seq }),
        .newer, .catch_up => std.fmt.allocPrint(a, "limit={d}&after={d}", .{ data.page, seq }),
        .around => std.fmt.allocPrint(a, "limit={d}&around={d}", .{ data.page, seq }),
    } catch return;
    app.api(s, .GET, std.fmt.allocPrint(a, "/chats/{s}/messages?{s}", .{ chat, q }) catch return, null, .{ .messages = .{ .chat = Id.of(chat), .mode = mode, .seq = seq } });
}

/// A chat was opened: load its messages (or catch up on what is new).
pub fn openTimeline(s: *State, chat: []const u8) void {
    const tl = s.store.timeline(chat) catch return;
    if (!tl.loaded) return loadMessages(s, chat, .latest, 0);
    if (!tl.has_newer) if (tl.lastSeq()) |last| loadMessages(s, chat, .catch_up, last);
}

fn onMessages(s: *State, x: app.MessagesOp, r: zui.Response) void {
    const chat = x.chat.str();
    const tl = s.store.timeline(chat) catch return;
    tl.loading = false;
    if (!r.ok()) return app.toastError(s, app.apiError(r).message);
    const v = j.parse(tmp(), r.body) orelse return;
    tl.floor = j.intOr(v, "floor", 0);
    var list: std.ArrayList(*data.Message) = .empty;
    defer list.deinit(gpa);
    for (j.arr(v, "messages")) |raw| {
        const m = data.newMessage(raw) catch continue;
        list.append(gpa, m) catch {
            m.destroy();
            continue;
        };
        if (j.str(raw, "senderId")) |sid| keys.want(s, sid);
        keys.hydrate(s, chat, m);
    }
    const n = list.items.len;
    switch (x.mode) {
        .latest => {
            tl.reset(list.items) catch {};
            tl.has_older = n == data.page;
            tl.has_newer = false;
            list.clearRetainingCapacity();
            markOpenChatRead(s);
        },
        .around => {
            tl.reset(list.items) catch {};
            tl.has_older = true;
            const c = s.store.chat(chat);
            tl.has_newer = if (c) |cc| (tl.lastSeq() orelse 0) < cc.seq() else true;
            list.clearRetainingCapacity();
        },
        .older => {
            tl.prepend(list.items) catch {};
            tl.has_older = n == data.page;
            list.clearRetainingCapacity();
        },
        .newer, .catch_up => {
            for (list.items) |m| tl.insert(m) catch {};
            list.clearRetainingCapacity();
            if (x.mode == .newer) tl.has_newer = n == data.page;
            if (n == data.page) if (tl.lastSeq()) |last| loadMessages(s, chat, if (x.mode == .newer) .newer else .catch_up, last);
            markOpenChatRead(s);
        },
    }
}

// ---------------------------------------------------------------------------------------------
// Read receipts (debounced per chat: messages.js markRead)

pub fn markRead(s: *State, c: *data.Chat, seq: i64) void {
    if (seq <= 0) return;
    if (seq <= c.meInt("lastReadSeq") and !c.meBool("markedUnread")) return;
    c.setMe("markedUnread", data.boolean(false));
    if (seq >= (if (c.last) |m| m.seq() orelse c.seq() else c.seq())) {
        c.setMe("unread", data.int(0));
        c.setMe("mentions", data.int(0));
    }
    for (s.read_pending.items) |*p| if (p.chat.eql(c.id())) {
        p.seq = @max(p.seq, seq);
        return;
    };
    s.read_pending.append(gpa, .{ .chat = Id.of(c.id()), .seq = seq }) catch return;
    app.fx.after(350, .{ .read_flush = Id.of(c.id()) });
}

pub fn flushRead(s: *State, chat: Id) void {
    for (s.read_pending.items, 0..) |p, i| if (p.chat.eql(chat.str())) {
        _ = s.read_pending.orderedRemove(i);
        app.api(s, .POST, std.fmt.allocPrint(tmp(), "/chats/{s}/read", .{chat.str()}) catch return, std.fmt.allocPrint(tmp(), "{{\"seq\":{d}}}", .{p.seq}) catch return, .{ .read = chat });
        return;
    };
}

/// The open chat, looked at: everything in it is read (the message list always shows the newest).
pub fn markOpenChatRead(s: *State) void {
    if (!s.visible or !s.open_chat.isSet()) return;
    const c = s.store.chat(s.open_chat.str()) orelse return;
    if (c.o.b("preview")) return;
    const tl = s.store.existingTimeline(c.id()) orelse return;
    if (tl.has_newer) return;
    if (tl.lastSeq()) |last| markRead(s, c, last);
}

// ---------------------------------------------------------------------------------------------
// Typing

pub fn setTyping(s: *State, chat: []const u8, user: []const u8, action: []const u8) void {
    const c = s.store.chat(chat) orelse return;
    for (c.typing.items, 0..) |*e, i| if (e.user.eql(user)) {
        if (std.mem.eql(u8, action, "cancel")) {
            _ = c.typing.orderedRemove(i);
            return;
        }
        e.until = sys.now() + 6000;
        setAction(e, action);
        return;
    };
    if (std.mem.eql(u8, action, "cancel")) return;
    var e: data.Typing = .{ .user = Id.of(user), .until = sys.now() + 6000 };
    setAction(&e, action);
    c.typing.append(gpa, e) catch return;
    app.fx.after(6100, .typing_check);
}

fn setAction(e: *data.Typing, action: []const u8) void {
    const n = @min(action.len, e.action.len);
    @memcpy(e.action[0..n], action[0..n]);
    e.action_len = @intCast(n);
}

pub fn stopTyping(s: *State, chat: []const u8, user: []const u8) void {
    const c = s.store.chat(chat) orelse return;
    for (c.typing.items, 0..) |e, i| if (e.user.eql(user)) {
        _ = c.typing.orderedRemove(i);
        return;
    };
}

pub fn expireTyping(s: *State) void {
    const now = sys.now();
    var it = s.store.chats.valueIterator();
    while (it.next()) |cp| {
        const c = cp.*;
        var i: usize = 0;
        while (i < c.typing.items.len) {
            if (c.typing.items[i].until <= now) _ = c.typing.orderedRemove(i) else i += 1;
        }
    }
}

/// The person is typing in the composer: tell the chat (at most every 3.5 s).
pub fn typing(s: *State) void {
    if (!s.open_chat.isSet() or s.editing.isSet()) return;
    const now = sys.now();
    if (now - s.last_typing_sent < 3500) return;
    if (s.fields.get(.composer).get().len == 0) return;
    s.last_typing_sent = now;
    app.wsSend(s, "typing", std.fmt.allocPrint(tmp(), "{{\"chatId\":\"{s}\",\"action\":\"typing\"}}", .{s.open_chat.str()}) catch return);
}

pub fn cancelTyping(s: *State) void {
    if (s.last_typing_sent == 0 or !s.open_chat.isSet()) return;
    s.last_typing_sent = 0;
    app.wsSend(s, "typing", std.fmt.allocPrint(tmp(), "{{\"chatId\":\"{s}\",\"action\":\"cancel\"}}", .{s.open_chat.str()}) catch return);
}

// ---------------------------------------------------------------------------------------------
// The connection came (back)

pub fn onConnected(s: *State, reconnect: bool) void {
    keys.fulfillPending(s);
    if (!reconnect) return;
    // Catch up on everything that happened while we were offline.
    app.api(s, .GET, "/chats", null, .chats);
    var it = s.store.timelines.iterator();
    while (it.next()) |e| {
        const tl = e.value_ptr.*;
        if (!tl.loaded or tl.has_newer) continue;
        if (tl.lastSeq()) |last| loadMessages(s, e.key_ptr.*, .catch_up, last);
    }
}

// ---------------------------------------------------------------------------------------------
// Realtime events

pub fn onEvent(s: *State, typ: []const u8, d: j.Value) void {
    const eq = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    const chat_id = j.strOr(d, "chatId", "");
    if (eq(typ, "message")) return onMessage(s, d);
    if (eq(typ, "message.edit")) return onEdit(s, d);
    if (eq(typ, "message.stream")) return onStream(s, d);
    if (eq(typ, "message.delete")) return onDelete(s, d);
    if (eq(typ, "message.reactions")) return patchMessage(s, chat_id, j.strOr(d, "id", ""), "reactions", j.field(d, "reactions"));
    if (eq(typ, "message.poll")) return patchMessage(s, chat_id, j.strOr(d, "id", ""), "poll", j.field(d, "poll"));
    if (eq(typ, "chat.new") or eq(typ, "chat.update")) {
        const c = s.store.putChat(d) catch return;
        if (c.last) |m| keys.hydrate(s, c.id(), m);
        return;
    }
    if (eq(typ, "chat.state")) {
        if (s.store.chat(chat_id)) |c| if (j.field(d, "me")) |me| c.o.set("me", me) catch {};
        return;
    }
    if (eq(typ, "chat.removed")) {
        s.store.removeChat(chat_id);
        if (s.open_chat.eql(chat_id)) s.open_chat = .{};
        return;
    }
    if (eq(typ, "chat.read")) {
        const c = s.store.chat(chat_id) orelse return;
        c.setMe("lastReadSeq", data.int(@max(c.meInt("lastReadSeq"), j.intOr(d, "lastReadSeq", 0))));
        c.setMe("unread", data.int(j.intOr(d, "unread", 0)));
        if (j.int(d, "mentions")) |m| c.setMe("mentions", data.int(m));
        c.setMe("markedUnread", data.boolean(false));
        return;
    }
    if (eq(typ, "chat.unread")) {
        if (s.store.chat(chat_id)) |c| c.setMe("unread", data.int(j.intOr(d, "unread", 0)));
        return;
    }
    if (eq(typ, "read")) {
        const c = s.store.chat(chat_id) orelse return;
        const seq = j.intOr(d, "seq", 0);
        if (seq > (c.o.i("readSeq") orelse 0)) c.o.set("readSeq", data.int(seq)) catch {};
        return;
    }
    if (eq(typ, "chat.pins")) {
        if (s.store.chat(chat_id)) |c| c.o.set("pinned", j.field(d, "pinned") orelse .null) catch {};
        return;
    }
    if (eq(typ, "chat.members")) {
        if (s.store.chat(chat_id)) |c| c.o.set("memberCount", data.int(j.intOr(d, "memberCount", 0))) catch {};
        if (s.members_chat.eql(chat_id)) @import("views.zig").loadMembers(s, chat_id);
        return;
    }
    if (eq(typ, "chat.cleared")) {
        if (s.store.chat(chat_id)) |c| {
            c.setMe("clearedSeq", data.int(j.intOr(d, "upToSeq", 0)));
            c.setMe("unread", data.int(0));
            if (c.last) |m| m.destroy();
            c.last = null;
        }
        if (s.store.existingTimeline(chat_id)) |tl| {
            tl.clear();
            tl.loaded = false;
            if (s.open_chat.eql(chat_id)) loadMessages(s, chat_id, .latest, 0);
        }
        return;
    }
    if (eq(typ, "typing")) return setTyping(s, chat_id, j.strOr(d, "userId", ""), j.strOr(d, "action", "typing"));
    if (eq(typ, "presence")) {
        const u = s.store.user(j.strOr(d, "userId", "")) orelse return;
        const p = std.fmt.allocPrint(tmp(), "{{\"presence\":{{\"status\":{s},\"lastSeenAt\":{s}}}}}", .{
            j.stringify(tmp(), j.field(d, "status") orelse .null) catch "null",
            j.stringify(tmp(), j.field(d, "lastSeenAt") orelse .null) catch "null",
        }) catch return;
        u.merge(j.parse(tmp(), p) orelse return) catch {};
        return;
    }
    if (eq(typ, "user.update")) {
        _ = s.store.putUser(d) catch null;
        return;
    }
    if (eq(typ, "me.update")) return app.setMe(s, d);
    if (eq(typ, "blocks.update")) {
        if (s.store.user(j.strOr(d, "userId", ""))) |u| u.set("blocked", data.boolean(j.truthy(d, "blocked"))) catch {};
        return;
    }
    if (eq(typ, "folders.update")) {
        app.api(s, .GET, "/folders", null, .folders);
        return;
    }
    if (eq(typ, "keys.needed")) return keys.onKeysNeeded(s, d);
    if (eq(typ, "keys.available")) return keys.keysArrived(s, chat_id);
    if (eq(typ, "keys.epoch")) {
        if (s.store.chat(chat_id)) |c| {
            const epoch = j.intOr(d, "epoch", 0);
            if (epoch > c.keyEpoch()) {
                c.o.set("keyEpoch", data.int(epoch)) catch {};
                c.o.set("rotationNeeded", data.boolean(false)) catch {};
            }
        }
        return keys.keysArrived(s, chat_id);
    }
    if (eq(typ, "keys.rotate")) {
        if (s.store.chat(chat_id)) |c| c.o.set("rotationNeeded", data.boolean(true)) catch {};
        return;
    }
    if (eq(typ, "keys.changed")) {
        const uid = j.strOr(d, "userId", "");
        _ = s.keys.asked.remove(uid);
        app.api(s, .GET, std.fmt.allocPrint(tmp(), "/users/{s}", .{uid}) catch return, null, .{ .user_refresh = Id.of(uid) });
        return;
    }
    if (eq(typ, "security.restore")) return app.toast(s, fmt.tf("Reseal was opened on a new device: {device}", .{ .device = text.deviceName(j.strOr(d, "device", "")) }));
    if (std.mem.startsWith(u8, typ, "call.")) return calls.onEvent(s, typ, d);
}

fn patchMessage(s: *State, chat: []const u8, id: []const u8, key: []const u8, v: ?j.Value) void {
    const tl = s.store.existingTimeline(chat) orelse return;
    const m = tl.find(id) orelse return;
    m.o.set(key, v orelse .null) catch {};
}

fn onMessage(s: *State, raw: j.Value) void {
    const chat_id = j.strOr(raw, "chatId", "");
    const c = s.store.chat(chat_id) orelse {
        // A chat we do not know yet: load it (its counters include this message).
        ensureChat(s, chat_id);
        return;
    };
    const m = data.newMessage(raw) catch return;
    if (m.senderId().len > 0) keys.want(s, m.senderId());
    keys.hydrate(s, chat_id, m);
    const mine = s.store.isMe(m.authorId());

    // Chat list: last message, unread counter.
    const last_seq = if (c.last) |l| l.seq() orelse 0 else 0;
    if (c.last == null or (m.seq() orelse 0) >= last_seq) {
        if (data.cloneMessage(m)) |copy| {
            if (c.last) |old| old.destroy();
            c.last = copy;
        } else |_| {}
        c.o.set("lastMessageAt", j.field(raw, "createdAt") orelse .null) catch {};
        c.o.set("seq", data.int(@max(c.seq(), m.seq() orelse 0))) catch {};
    }
    const open_visible = s.open_chat.eql(chat_id) and s.visible;
    const service_notify = !m.isService() or j.truthy(raw, "service.notify");
    if (!mine and c.me() != null and service_notify) {
        if (!open_visible) {
            c.setMe("unread", data.int(c.unread() + 1));
            if (mentionsMe(s, raw)) c.setMe("mentions", data.int(c.meInt("mentions") + 1));
        }
        if (c.archived() and !c.isMuted()) c.setMe("archived", data.boolean(false));
    }
    if (mine and c.me() != null) {
        c.setMe("unread", data.int(0));
        c.setMe("lastReadSeq", data.int(@max(c.meInt("lastReadSeq"), m.seq() orelse 0)));
        c.setMe("draft", .null);
    }
    if (m.senderId().len > 0) stopTyping(s, chat_id, m.senderId());

    if (!mine and !j.truthy(raw, "silent") and service_notify) notify(s, c, m, open_visible);

    if (s.store.existingTimeline(chat_id)) |tl| {
        // Our own message sent from this device: replace the pending copy.
        if (j.str(raw, "clientId")) |cid| if (tl.findClient(cid)) |i| {
            const local = tl.pending.orderedRemove(i);
            if (m.content == null and local.content != null) {
                m.content = j.clone(m.o.alloc(), local.content.?) catch null;
                m.decrypt = .ok;
                m.verified = true;
            }
            local.destroy();
        };
        if (tl.loaded) tl.insert(m) catch m.destroy() else m.destroy();
        if (open_visible) markOpenChatRead(s);
    } else m.destroy();
}

fn mentionsMe(s: *const State, raw: j.Value) bool {
    for (j.arr(raw, "mentions")) |x| if (x == .string and s.store.isMe(x.string)) return true;
    return false;
}

fn onEdit(s: *State, raw: j.Value) void {
    const chat_id = j.strOr(raw, "chatId", "");
    const id = j.strOr(raw, "id", "");
    if (s.store.existingTimeline(chat_id)) |tl| if (tl.find(id) != null) {
        const m = data.newMessage(raw) catch return;
        keys.hydrate(s, chat_id, m);
        tl.insert(m) catch {};
    };
    if (s.store.chat(chat_id)) |c| if (c.last) |l| if (std.mem.eql(u8, l.id(), id)) {
        const m = data.newMessage(raw) catch return;
        keys.hydrate(s, chat_id, m);
        l.destroy();
        c.last = m;
    };
}

fn onStream(s: *State, d: j.Value) void {
    const tl = s.store.existingTimeline(j.strOr(d, "chatId", "")) orelse return;
    const m = tl.find(j.strOr(d, "id", "")) orelse return;
    const a = m.o.alloc();
    const old = m.text();
    const joined = std.fmt.allocPrint(a, "{s}{s}", .{ old, j.strOr(d, "delta", "") }) catch return;
    if (m.content == null) m.content = j.emptyObject();
    m.content.?.object.put(a, "text", data.string(joined)) catch {};
    m.o.set("streaming", data.boolean(true)) catch {};
}

fn onDelete(s: *State, d: j.Value) void {
    if (j.truthy(d, "scheduled")) return;
    const chat_id = j.strOr(d, "chatId", "");
    const tl = s.store.existingTimeline(chat_id);
    var last_gone = false;
    const c = s.store.chat(chat_id);
    for (j.arr(d, "ids")) |x| {
        if (x != .string) continue;
        if (tl) |l| l.remove(x.string);
        if (c) |cc| if (cc.last) |m| if (std.mem.eql(u8, m.id(), x.string)) {
            last_gone = true;
        };
    }
    if (last_gone) app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/{s}", .{chat_id}) catch return, null, .{ .chat_refresh = Id.of(chat_id) });
}

// ---------------------------------------------------------------------------------------------
// Notifications (sync.js notify): the device's notification when the chat is not on screen.

var notify_ids: u32 = 100;

fn notify(s: *State, c: *data.Chat, m: *data.Message, open_visible: bool) void {
    const muted = c.isMuted() and !mentionsMe(s, m.o.v);
    if (muted or open_visible or !s.prefs.notifications) return;
    if (s.mode == .embed) {
        const a = tmp();
        app.post(std.fmt.allocPrint(a, "{{\"type\":\"reseal:message\",\"chatId\":\"{s}\",\"title\":{s},\"body\":{s}}}", .{ c.id(), j.quote(a, s.store.title(c)) catch "\"\"", j.quote(a, previewBody(s, c, m)) catch "\"\"" }) catch return);
    }
    // While the page is in front of the person, the list's badge says enough (as on the web).
    if (zui.platform == .web and s.visible) return;
    const a = tmp();
    var title = s.store.title(c);
    var body = previewBody(s, c, m);
    // Locked chats say only that something arrived; without previews, no text either.
    if (c.meBool("locked")) {
        title = "Reseal";
        body = t("New message");
    } else if (!s.prefs.previews) body = t("New message");
    app.fx.notify(.{ .id = notifyId(c.id()), .title = title, .body = body });
    _ = a;
}

fn notifyId(chat: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(7, chat) | 0x100000);
}

fn previewBody(s: *State, c: *data.Chat, m: *data.Message) []const u8 {
    const a = tmp();
    const is_pair = c.is("private") or c.is("bot");
    const summary = text.summary(s, m, true);
    if (!is_pair and m.senderId().len > 0) return std.fmt.allocPrint(a, "{s}: {s}", .{ s.store.displayName(m.senderId()), summary }) catch summary;
    return summary;
}

pub fn cancelNotification(chat: []const u8) void {
    app.fx.cancelNotify(notifyId(chat));
}

// ---------------------------------------------------------------------------------------------
// Answers

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const v = j.parse(tmp(), r.body);
    switch (op) {
        .messages => |x| onMessages(s, x, r),
        .chat_ensure, .chat_refresh => |id| {
            if (!r.ok()) return true;
            const raw = j.obj(v, "chat") orelse return true;
            if (j.truthy(raw, "preview") and s.store.chat(id.str()) == null) {
                // A public group or channel seen before joining: open it as a preview.
                const c = s.store.putChat(raw) catch return true;
                _ = c;
                return true;
            }
            const c = s.store.putChat(raw) catch return true;
            if (c.last) |m| keys.hydrate(s, c.id(), m);
            if (s.open_chat.eql(id.str())) openTimeline(s, id.str());
            send.pump(s, id.str());
        },
        .read => |chat| if (r.ok()) {
            if (s.store.chat(chat.str())) |c| {
                if (j.int(v, "lastReadSeq")) |x| c.setMe("lastReadSeq", data.int(x));
                if (j.int(v, "unread")) |x| c.setMe("unread", data.int(x));
            }
        },
        .user_refresh => if (r.ok()) {
            if (j.obj(v, "user")) |u| _ = s.store.putUser(u) catch null;
            keys.retryAll(s);
        },
        .state_set => |chat| {
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            if (s.store.chat(chat.str())) |c| if (j.field(v, "me")) |me| c.o.set("me", me) catch {};
        },
        else => return false,
    }
    return true;
}
