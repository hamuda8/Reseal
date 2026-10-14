//! Keyboard (Reseal-js main.js, shell.js, composer.js, viewer.js): Esc closes what is on top
//! (a sheet, the viewer, a reply or edit, the selection, the info panel, a pane, the chat),
//! Alt+Up/Down open the previous/next chat, Up in an empty composer edits my last message,
//! Left/Right move through the viewer. zui hands the app these keys only (no letters, so no
//! Ctrl+Shift+F).

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const data = @import("data.zig");

const State = app.State;
const Id = app.Id;
const Msg = app.Msg;

/// What the last update left on screen: keys are decided before an update runs, from this.
const Snapshot = struct {
    modal: bool = false,
    viewer: bool = false,
    reply_or_edit: bool = false,
    selecting: bool = false,
    info: bool = false,
    panes: bool = false,
    chat: bool = false,
    composer_empty: bool = true,
    ready: bool = false,
};

var snap: Snapshot = .{};

/// After each update.
pub fn remember(s: *const State) void {
    snap = .{
        .modal = s.modal != null,
        .viewer = s.viewer != null,
        .reply_or_edit = s.reply_to.isSet() or s.editing.isSet(),
        .selecting = s.selecting,
        .info = s.info.isSet() or s.user_info.isSet(),
        .panes = s.panes.items.len > 0,
        .chat = s.open_chat.isSet(),
        .composer_empty = s.fields.get(.composer).get().len == 0,
        .ready = s.phase == .ready,
    };
}

pub const Act = union(enum) {
    chat_step: i8,
    edit_last,
};

pub fn keyEvent(e: zui.KeyEvent) ?Msg {
    if (!snap.ready) return null;
    switch (e.key) {
        .escape => {
            if (snap.modal) return .close_modal;
            if (snap.viewer) return .close_viewer;
            if (snap.reply_or_edit) return .cancel_reply;
            if (snap.selecting) return .select_cancel;
            if (snap.info) return .close_info;
            if (snap.panes) return .pop_pane;
            if (snap.chat and !e.in_input) return .close_chat;
            return null;
        },
        .up, .down => {
            if (e.alt) return .{ .keys = .{ .chat_step = if (e.key == .up) -1 else 1 } };
            if (e.key == .up and e.in_input and !e.shift and !e.ctrl and snap.chat and snap.composer_empty and !snap.modal and !snap.reply_or_edit) return .{ .keys = .edit_last };
            return null;
        },
        .left, .right => {
            if (!snap.viewer or e.in_input) return null;
            const forward = (e.key == .right) != zui.i18n.isRtl();
            return .{ .viewer_x = .{ .go = if (forward) 1 else -1 } };
        },
        else => return null,
    }
}

pub fn act(s: *State, a: Act) void {
    switch (a) {
        .chat_step => |d| step(s, d),
        .edit_last => editLast(s),
    }
}

/// The previous/next chat of the list on screen (wrapping; the first or last when none is open).
fn step(s: *State, d: i8) void {
    const archived = false;
    const list = s.store.sorted(app.tmp(), archived);
    var shown: std.ArrayList(*data.Chat) = .empty;
    for (list) |c| {
        const saved_section = s.section == .saved;
        if (c.is("saved") != saved_section) continue;
        if (c.o.b("preview")) continue;
        shown.append(app.tmp(), c) catch return;
    }
    const items = shown.items;
    if (items.len == 0) return;
    var at: ?usize = null;
    for (items, 0..) |c, i| if (s.open_chat.eql(c.id())) {
        at = i;
    };
    const n: i64 = @intCast(items.len);
    const next: usize = if (at) |i| @intCast(@mod(@as(i64, @intCast(i)) + d, n)) else if (d > 0) 0 else items.len - 1;
    @import("views.zig").openChat(s, items[next].id());
}

/// My last text message in the open chat (within 48 hours; any age in Saved) goes into the
/// composer to edit.
fn editLast(s: *State) void {
    const c = s.store.chat(s.open_chat.str()) orelse return;
    const tl = s.store.existingTimeline(c.id()) orelse return;
    var i = tl.items.items.len;
    while (i > 0) {
        i -= 1;
        const m = tl.items.items[i];
        if (m.isService() or m.deleted() or !s.store.isMe(m.authorId())) continue;
        if (m.text().len == 0 or m.decrypt != .ok) return;
        if (!c.is("saved") and @import("sys.zig").now() - m.at > 48 * 3600 * 1000) return;
        @import("views.zig").onUi(s, .{ .message_action = .{ .what = .edit, .msg = Id.of(m.id()) } });
        return;
    }
}
