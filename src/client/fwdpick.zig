//! The chat picker of Reseal-js (pickers.js chatPicker): forwarding to several chats at once
//! ("Forward to…", search, chips, Send) and "Save to…" when there are several saved chats.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const data = @import("data.zig");
const icons = @import("icons.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");
const vlist = @import("view_list.zig");
const fmt = @import("fmt.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const Color = zui.Color;
const t = zui.i18n.t;
const tmp = app.tmp;
const key = kit.key;

pub const Pick = struct {
    chosen: std.ArrayList(Id) = .empty,
    /// "Save to…": one saved chat, chosen with a tap.
    save: bool = false,
    /// The message (or none for the selection).
    msg: Id = .{},
};

pub const Act = union(enum) {
    toggle: Id,
    send,
    remove: Id,
};

fn msgOf(a: Act) Msg {
    return .{ .fwd_pick = a };
}

/// Opens the picker for a message (`msg` set) or the selection.
pub fn open(s: *State, msg_id: Id, save: bool) void {
    s.fwd.chosen.clearRetainingCapacity();
    s.fwd.save = save;
    s.fwd.msg = msg_id;
    s.fields.getPtr(.forward_search).clear();
    s.modal = .{ .forward = msg_id };
}

fn has(s: *const State, id: []const u8) bool {
    for (s.fwd.chosen.items) |x| if (x.eql(id)) return true;
    return false;
}

pub fn act(s: *State, a: Act) void {
    switch (a) {
        .toggle => |id| {
            if (s.fwd.save) {
                s.fwd.chosen.clearRetainingCapacity();
                s.fwd.chosen.append(app.gpa, id) catch return;
                return send(s);
            }
            for (s.fwd.chosen.items, 0..) |x, i| if (x.eql(id.str())) {
                _ = s.fwd.chosen.orderedRemove(i);
                return;
            };
            s.fwd.chosen.append(app.gpa, id) catch {};
        },
        .remove => |id| for (s.fwd.chosen.items, 0..) |x, i| if (x.eql(id.str())) {
            _ = s.fwd.chosen.orderedRemove(i);
            return;
        },
        .send => send(s),
    }
}

fn send(s: *State) void {
    if (s.fwd.chosen.items.len == 0) return;
    s.modal = null;
    for (s.fwd.chosen.items) |to| views.forwardMessages(s, to.str(), s.fwd.msg);
    if (!s.fwd.msg.isSet()) views.endSelection(s);
    const n = s.fwd.chosen.items.len;
    const first = s.store.chat(s.fwd.chosen.items[0].str());
    const name = if (first) |c| s.store.title(c) else "";
    if (s.fwd.save) {
        app.toast(s, if (first != null and first.?.o.b("primary")) t("Saved to Saved Messages") else fmt.tf("Saved to {name}", .{ .name = name }));
    } else app.toast(s, if (n == 1) fmt.tf("Forwarded to {name}", .{ .name = name }) else fmt.tn(tmp(), @intCast(n), "Forwarded to {n} chats", "Forwarded to {n} chats"));
    s.fwd.chosen.clearRetainingCapacity();
}

/// Under each chat (pickers.js): notes, presence, or what kind of chat it is.
fn subtitle(s: *const State, c: *const data.Chat) []const u8 {
    if (c.is("saved")) return if (c.o.s("about")) |x| (if (x.len > 0) x else t("Your notes")) else t("Your notes");
    if (c.is("private")) return if (s.store.peer(c)) |p| @import("text.zig").presenceText(p.get("presence")) else "";
    if (c.is("channel")) return t("channel");
    if (c.is("bot")) return t("bot");
    return t("group");
}

fn allowed(s: *const State, c: *const data.Chat) bool {
    if (c.o.b("preview")) return false;
    if (s.fwd.save) return c.is("saved") and !s.open_chat.eql(c.id());
    return @import("view_chat.zig").can(c, "sendMessages");
}

pub fn sheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, if (s.fwd.save) t("Save to…") else t("Forward to…"));
    ui.begin(.{ .padding = .xy(8, 4), .direction = .row }, .{});
    kit.searchBox(cx, .forward_search, t("Search"));
    ui.end();
    // The chosen chats, as chips.
    if (s.fwd.chosen.items.len > 0) {
        ui.begin(.{ .direction = .row, .wrap = true, .gap = 6, .padding = .xy(10, 4) }, .{});
        for (s.fwd.chosen.items) |id| if (s.store.chat(id.str())) |c| {
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .start = 3, .end = 6, .top = 3, .bottom = 3 }, .radius = 16, .background = cx.c.surface_2, .pressed_opacity = 0.8 }, .{ .on_press = msgOf(.{ .remove = id }), .key = key(.{ "fwchip", id.str() }) });
            vlist.chatAvatar(cx, c, 24);
            ui.text(s.store.title(c), .{ .font_size = 13.5, .color = cx.c.text, .max_lines = 1 });
            ui.icon(icons.close, 14, cx.c.text_2, .{}, 0);
            ui.end();
        };
        ui.end();
    }
    const q = std.mem.trim(u8, s.fields.get(.forward_search).get(), " ");
    var shown: usize = 0;
    for ([_]bool{ false, true }) |archived| for (s.store.sorted(cx.a(), archived)) |c| {
        if (!allowed(s, c)) continue;
        if (q.len > 0 and std.ascii.findIgnoreCase(s.store.title(c), q) == null) continue;
        shown += 1;
        if (s.fwd.save) {
            vlist.chatItem(cx, c, msgOf(.{ .toggle = Id.of(c.id()) }));
            continue;
        }
        const on = has(s, c.id());
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 52, .padding = .xy(12, 4), .radius = 12, .pressed_background = cx.c.active }, .{ .on_press = msgOf(.{ .toggle = Id.of(c.id()) }), .key = key(.{ "fwd", c.id() }) });
        vlist.chatAvatar(cx, c, 40);
        ui.begin(.{ .grow = 1, .width = .fill }, .{});
        ui.text(s.store.title(c), .{ .font_size = 15, .weight = 550, .color = cx.c.text, .max_lines = 1 });
        ui.text(subtitle(s, c), .{ .font_size = 13, .color = cx.c.text_2, .max_lines = 1 });
        ui.end();
        ui.begin(.{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 11, .border_width = if (on) 0 else 1.5, .border_color = cx.c.border_strong, .background = if (on) cx.c.brand else null, .align_items = .center, .justify = .center }, .{});
        if (on) ui.icon(icons.check, 14, Color.white, .{}, 0);
        ui.end();
        ui.end();
    };
    if (shown == 0) {
        ui.begin(.{ .padding = .xy(12, 16) }, .{});
        ui.text(t("No chats found"), .{ .font_size = 14, .color = cx.c.text_3 });
        ui.end();
    }
    if (!s.fwd.save) {
        ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .top = 8, .bottom = 8, .start = 8, .end = 8 } }, .{});
        kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
        kit.button(cx, t("Send"), msgOf(.send), .{ .icon = icons.forward, .disabled = s.fwd.chosen.items.len == 0 });
        ui.end();
    }
    views.endSheet(cx);
}
