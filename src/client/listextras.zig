//! More of the chat list (Reseal-js chatlist.js): "Mark all as read" on a filter chip (long
//! press or right click), and Undo on the "Chat archived" toast.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const data = @import("data.zig");
const icons = @import("icons.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");
const vlist = @import("view_list.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const t = zui.i18n.t;
const tmp = app.tmp;

pub const ListExtras = struct {
    /// The chip whose menu is open.
    chip: app.Filter = .all,
    /// The chat the toast's Undo unarchives.
    undo_archive: Id = .{},
    undo_toast: u32 = 0,
    /// The chat the toast's Open opens (a reminder).
    open_chat: Id = .{},
    open_toast: u32 = 0,
    /// The toast that offers notifications (web).
    push_toast: u32 = 0,
};

pub const Act = union(enum) {
    chip_menu: app.Filter,
    mark_all_read,
    undo_archive,
    open_toast_chat,
    push_allow,
};

pub fn chipMsg(f: app.Filter) Msg {
    return .{ .list_extras = .{ .chip_menu = f } };
}

pub fn act(s: *State, a: Act) void {
    switch (a) {
        .chip_menu => |f| {
            s.listx.chip = f;
            s.modal = .{ .menu = .{ .kind = .chip } };
        },
        .mark_all_read => {
            s.modal = null;
            markAllRead(s, s.listx.chip);
        },
        .push_allow => {
            s.listx.push_toast = 0;
            s.toast.text.clear();
            app.post("{\"t\":\"push-allow\"}");
        },
        .open_toast_chat => {
            const chat = s.listx.open_chat;
            s.listx.open_chat = .{};
            s.toast.text.clear();
            if (chat.isSet()) views.openChat(s, chat.str());
        },
        .undo_archive => {
            const chat = s.listx.undo_archive;
            s.listx.undo_archive = .{};
            s.toast.text.clear();
            if (chat.isSet()) views.onUi(s, .{ .chat_action = .{ .what = .unarchive, .chat = chat } });
        },
    }
}

/// After archiving: the toast offers Undo.
pub fn archived(s: *State, chat: Id) void {
    app.toast(s, t("Chat archived"));
    s.listx.undo_archive = chat;
    s.listx.undo_toast = s.toast.id;
}

/// A toast with Open (a reminder that came due).
pub fn toastOpen(s: *State, text: []const u8, chat: Id) void {
    app.toast(s, text);
    s.listx.open_chat = chat;
    s.listx.open_toast = s.toast.id;
}

/// The web asks once whether to turn notifications on (main.js push prompt).
pub fn toastPush(s: *State) void {
    app.toast(s, t("Turn on notifications to know when messages arrive."));
    s.listx.push_toast = s.toast.id;
}

/// The toast's action, when it has one.
pub fn toastAction(s: *const State) ?struct { label: []const u8, msg: Msg } {
    if (s.listx.undo_archive.isSet() and s.listx.undo_toast == s.toast.id) return .{ .label = t("Undo"), .msg = .{ .list_extras = .undo_archive } };
    if (s.listx.open_chat.isSet() and s.listx.open_toast == s.toast.id) return .{ .label = t("Open"), .msg = .{ .list_extras = .open_toast_chat } };
    if (s.listx.push_toast != 0 and s.listx.push_toast == s.toast.id) return .{ .label = t("Turn on"), .msg = .{ .list_extras = .push_allow } };
    return null;
}

fn markAllRead(s: *State, f: app.Filter) void {
    var ids: std.ArrayList(u8) = .empty;
    const a = tmp();
    var n: usize = 0;
    var it = s.store.chats.valueIterator();
    while (it.next()) |cp| {
        const c = cp.*;
        if (c.is("saved")) continue;
        // A filter chip shows chats outside the archive; a folder may include archived ones.
        if (f == .folder) {
            if (!vlist.matchesFilter(s, c, f)) continue;
        } else if (c.archived() or !vlist.matchesFilter(s, c, f)) continue;
        if (!(c.unread() > 0 or c.meBool("markedUnread") or c.meInt("mentions") > 0)) continue;
        ids.print(a, "{s}\"{s}\"", .{ if (n > 0) "," else "", c.id() }) catch return;
        n += 1;
        c.setMe("markedUnread", data.boolean(false));
        c.setMe("unread", data.int(0));
        c.setMe("mentions", data.int(0));
        c.setMe("lastReadSeq", data.int(@max(c.meInt("lastReadSeq"), c.seq())));
    }
    if (n == 0) return app.toast(s, t("You are all caught up."));
    app.api(s, .POST, "/chats/read-all", std.fmt.allocPrint(a, "{{\"chatIds\":[{s}]}}", .{ids.items}) catch return, .ignore);
}

pub fn chipSheet(cx: Cx) void {
    views.sheet(cx, null);
    views.menuItem(cx, icons.checks, t("Mark all as read"), .{ .list_extras = .mark_all_read }, false);
    views.endSheet(cx);
}
