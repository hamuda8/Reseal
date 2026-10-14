//! More from a chat's menu (Reseal-js chatview.js header menu): selecting messages, the
//! scheduled messages (reminders in Saved), auto-delete for new messages, and asking a support
//! bot for a person.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const icons = @import("icons.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const t = zui.i18n.t;
const tmp = app.tmp;

pub const ttls = [_]struct { secs: u32, label: []const u8 }{
    .{ .secs = 0, .label = "Off" },
    .{ .secs = 86400, .label = "1 day" },
    .{ .secs = 604800, .label = "1 week" },
    .{ .secs = 2592000, .label = "1 month" },
    .{ .secs = 3600, .label = "1 hour" },
    .{ .secs = 300, .label = "5 minutes" },
};

pub fn ttlLabel(secs: i64) []const u8 {
    for (ttls) |x| if (x.secs == secs) return t(x.label);
    return std.fmt.allocPrint(tmp(), "{d}s", .{secs}) catch "";
}

pub const Act = union(enum) {
    select: Id,
    scheduled: Id,
    ttl_menu: Id,
    set_ttl: struct { chat: Id, secs: u32 },
    handoff: Id,
};

fn openIt(s: *State, chat: Id) void {
    if (!s.open_chat.eql(chat.str())) views.openChat(s, chat.str());
}

pub fn act(s: *State, a: Act) void {
    switch (a) {
        .select => |chat| {
            s.modal = null;
            openIt(s, chat);
            s.selecting = true;
            s.selected.clearRetainingCapacity();
        },
        .scheduled => |chat| {
            openIt(s, chat);
            app.compose.act(s, .{ .open = .scheduled });
        },
        .ttl_menu => |chat| s.modal = .{ .menu = .{ .kind = .ttl, .target = chat } },
        .set_ttl => |x| {
            s.modal = null;
            app.api(s, .PATCH, std.fmt.allocPrint(tmp(), "/chats/{s}", .{x.chat.str()}) catch return, std.fmt.allocPrint(tmp(), "{{\"ttl\":{d}}}", .{x.secs}) catch return, .{ .chat_patch = x.chat });
        },
        .handoff => |chat| {
            s.modal = null;
            app.api(s, .POST, std.fmt.allocPrint(tmp(), "/chats/{s}/handoff", .{chat.str()}) catch return, "{}", .handoff);
        },
    }
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    switch (op) {
        .handoff => if (r.ok()) app.toast(s, t("We let the team know. Someone will reply here soon.")) else app.toastError(s, app.apiError(r).message),
        else => return false,
    }
    return true;
}

fn msg(a: Act) Msg {
    return .{ .chat_more = a };
}

/// The items this module adds to a chat's menu.
pub fn menuItems(cx: Cx, c: *const data.Chat) void {
    const s = cx.s;
    const id = Id.of(c.id());
    const pair = c.is("private") or c.is("bot") or c.is("saved");
    const admin = std.mem.eql(u8, c.role(), "owner") or std.mem.eql(u8, c.role(), "admin");
    if (s.mode == .app) views.menuItem(cx, icons.selectCircle, if (c.is("saved")) t("Select notes") else t("Select messages"), msg(.{ .select = id }), false);
    views.menuItem(cx, icons.calendar, if (c.is("saved")) t("Reminders") else t("Scheduled messages"), msg(.{ .scheduled = id }), false);
    if ((pair and !c.is("bot")) or admin) {
        const ttl = c.o.i("ttl") orelse 0;
        views.menuItem(cx, icons.timer, if (ttl > 0) @import("fmt.zig").tf("Auto-delete: {time}", .{ .time = ttlLabel(ttl) }) else t("Auto-delete messages"), msg(.{ .ttl_menu = id }), false);
    }
    if (c.is("support") and !c.o.b("preview") and !std.mem.eql(u8, c.role(), "admin") and c.o.s("botId") != null)
        views.menuItem(cx, icons.user, t("Talk to a person"), msg(.{ .handoff = id }), false);
}

pub fn ttlSheet(cx: Cx, chat: Id) void {
    const c = cx.s.store.chat(chat.str()) orelse return;
    const cur = c.o.i("ttl") orelse 0;
    views.sheet(cx, t("Auto-delete messages"));
    for (ttls) |x| {
        cx.ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 44, .padding = .xy(12, 6), .radius = 12, .pressed_background = cx.c.hover }, .{ .on_press = msg(.{ .set_ttl = .{ .chat = chat, .secs = x.secs } }), .key = kit.key(.{ "ttl", x.secs }) });
        cx.ui.icon(icons.timer, 19, cx.c.text_2, .{}, 0);
        cx.ui.text(t(x.label), .{ .font_size = 14.5, .weight = 550, .color = cx.c.text, .grow = 1, .width = .fill });
        if (cur == x.secs) cx.ui.icon(icons.check, 18, cx.c.accent, .{}, 0);
        cx.ui.end();
    }
    views.endSheet(cx);
}
