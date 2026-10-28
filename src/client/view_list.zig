//! The app's frame (Reseal-js ui/shell.js: navigation rail, sidebar panes, main area, info
//! panel; a tab bar on phones) and the lists in the sidebar: chats (ui/chatlist.js) with
//! filters and search, archive, Saved, contacts and call history.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const fmt = @import("fmt.zig");
const text = @import("text.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");
const vchat = @import("view_chat.zig");
const vset = @import("view_settings.zig");
const media = @import("media.zig");

const Cx = kit.Cx;
const Msg = app.Msg;
const Id = app.Id;
const Color = zui.Color;
const t = zui.i18n.t;
const key = kit.key;

// ---------------------------------------------------------------------------------------------
// Shell

pub fn shell(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const embed = s.mode == .embed;
    if (cx.phone) {
        if (s.open_chat.isSet()) {
            vchat.chatView(cx);
            if (s.info.isSet() or s.user_info.isSet()) {
                ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 }, .background = cx.c.surface }, .{});
                vchat.infoPanel(cx);
                ui.end();
            }
            return;
        }
        ui.begin(.{ .width = .fill, .height = .fill, .background = cx.c.surface }, .{});
        ui.begin(.{ .grow = 1, .height = .fill, .width = .fill }, .{});
        sidebar(cx);
        ui.end();
        if (!embed and s.panes.items.len == 0) tabbar(cx);
        ui.end();
        return;
    }
    const pad = theme.gap;
    ui.begin(.{ .direction = .row, .width = .fill, .height = .fill, .gap = theme.gap, .padding = .{ .top = if (embed) 0 else pad, .bottom = if (embed) 0 else pad, .end = if (embed) 0 else pad, .start = 0 } }, .{});
    if (!embed) rail(cx);
    const side_w: f32 = if (cx.w <= 980) theme.sidebar_w_narrow else theme.sidebar_w;
    panel(cx, .{ .width = .{ .px = side_w }, .height = .fill }, embed);
    sidebar(cx);
    cx.ui.end();
    panel(cx, .{ .grow = 1, .width = .fill, .height = .fill }, embed);
    if (s.open_chat.isSet()) vchat.chatView(cx) else emptyMain(cx);
    cx.ui.end();
    if (s.info.isSet() or s.user_info.isSet()) {
        if (cx.w > 1240) {
            panel(cx, .{ .width = .{ .px = theme.info_w }, .height = .fill }, embed);
            vchat.infoPanel(cx);
            cx.ui.end();
        }
    }
    ui.end();
    if ((s.info.isSet() or s.user_info.isSet()) and cx.w <= 1240) {
        ui.begin(.{ .position = .absolute, .inset = .{ .top = pad, .bottom = pad, .end = pad }, .width = .{ .px = theme.info_w }, .background = cx.c.surface, .radius = theme.r_panel, .clip = true, .border_width = 1, .border_color = cx.c.border }, .{});
        vchat.infoPanel(cx);
        ui.end();
    }
}

fn panel(cx: Cx, st: zui.Style, flat: bool) void {
    var style = st;
    style.background = cx.c.surface;
    style.radius = if (flat) 0 else theme.r_panel;
    style.clip = true;
    if (!flat) {
        style.border_width = 1;
        style.border_color = cx.c.border;
    }
    cx.ui.begin(style, .{});
}

const NavItem = struct { sec: app.Section, icon: zui.Icon, label: []const u8 };
const nav_items = [_]NavItem{
    .{ .sec = .chats, .icon = icons.chats, .label = "Chats" },
    .{ .sec = .calls, .icon = icons.phone, .label = "Calls" },
    .{ .sec = .saved, .icon = icons.bookmark, .label = "Saved" },
    .{ .sec = .contacts, .icon = icons.contacts, .label = "Contacts" },
    .{ .sec = .ai, .icon = icons.sparkles, .label = "AI" },
    .{ .sec = .settings, .icon = icons.settings, .label = "Settings" },
};

fn rail(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const c = cx.c;
    const totals = s.store.totals();
    ui.begin(.{ .width = .{ .px = theme.rail_w }, .height = .fill, .align_items = .center, .gap = 6, .padding = .{ .top = 6, .bottom = 4 } }, .{});
    ui.begin(.{ .padding = .{ .top = 6, .bottom = 14 } }, .{});
    views.logo(cx, 44);
    ui.end();
    for (nav_items) |n| {
        if (n.sec == .settings) {
            ui.begin(.{ .grow = 1, .height = .fill }, .{});
            ui.end();
        }
        const active = s.section == n.sec;
        ui.begin(.{ .width = .{ .px = 52 }, .height = .{ .px = 52 }, .radius = 17, .background = if (active) c.surface else null, .align_items = .center, .justify = .center, .pressed_opacity = 0.8 }, .{ .on_press = .{ .nav = n.sec }, .key = key(.{ "rail", @intFromEnum(n.sec) }) });
        ui.icon(n.icon, 24, if (active) c.accent else c.text_2, .{}, 0);
        const count = switch (n.sec) {
            .chats => totals.unread,
            .saved => totals.saved_unread,
            else => 0,
        };
        if (count > 0) {
            ui.begin(.{ .position = .absolute, .inset = .{ .top = 4, .end = 2 } }, .{});
            kit.badge(cx, if (count > 99) "99+" else fmt.number(cx.a(), count), false);
            ui.end();
        }
        ui.end();
    }
    if (s.store.me != null) {
        ui.begin(.{ .padding = .{ .top = 6 } }, .{});
        accountPicture(cx, 42);
        ui.end();
    }
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// The Wufour account menu (zui.account): the profile picture opens it, the same menu as in every
// Wufour app. Reseal's own items: My profile, Settings (app.accountAction maps them by index).

fn onAccount(a: zui.account.Action) Msg {
    return .{ .account = a };
}

/// The person's photo in Reseal, for the menu's picture.
fn myPhoto(cx: Cx) []const u8 {
    const me = cx.s.store.me orelse return "";
    if (me.s("avatar")) |id| if (id.len > 0) return media.mediaUrl(cx.a(), id);
    return "";
}

pub fn accountOptions(cx: Cx) zui.account.Options(Msg) {
    var items: []const zui.account.Item = &.{};
    if (cx.a().alloc(zui.account.Item, 2)) |list| {
        list[0] = .{ .label = t("My profile"), .icon = zui.account.icons.user };
        list[1] = .{ .label = t("Settings"), .icon = zui.account.icons.settings, .current = cx.s.section == .settings };
        items = list;
    } else |_| {}
    return .{
        .msg = onAccount,
        .ar = cx.s.lang == .ar,
        .app = "reseal",
        .photo = myPhoto(cx),
        .items = items,
        // Desktop: beside the rail, upwards from its picture; phones: under the header.
        .anchor = if (cx.phone) .{ .top = cx.ui.env.safe.top + 64, .end = 12 } else .{ .bottom = 12, .start = theme.rail_w + 8 },
    };
}

/// Reseal's own picture of the person (their photo or initials), opening the account menu.
fn accountPicture(cx: Cx, size: f32) void {
    const me = cx.s.store.me orelse return;
    const open = cx.s.account.open;
    cx.ui.begin(.{ .padding = .all(2), .radius = size * 0.34 + 4, .border_width = 2, .border_color = if (open) cx.c.accent else Color.transparent, .pressed_opacity = 0.85, .transition = .{ .duration_ms = 200 } }, .{ .on_press = .{ .account = .toggle }, .label = t("Wufour account"), .key = key(.{"me-av-btn"}) });
    kit.avatar(cx, .{ .name = me.s("displayName") orelse "", .color = me.i("color") orelse 0, .image = me.s("avatar"), .size = size }, key(.{"me-av"}));
    cx.ui.end();
}

fn tabbar(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const c = cx.c;
    const totals = s.store.totals();
    kit.divider(cx);
    ui.begin(.{ .direction = .row, .justify = .space_between, .padding = .{ .top = 6, .bottom = 6, .start = 6, .end = 6 }, .background = c.surface }, .{});
    for (nav_items) |n| {
        if (n.sec == .contacts) continue;
        const active = s.section == n.sec;
        const col = if (active) c.accent else c.text_3;
        ui.begin(.{ .grow = 1, .width = .fill, .align_items = .center, .gap = 2, .padding = .xy(0, 6), .radius = 12 }, .{ .on_press = .{ .nav = n.sec }, .key = key(.{ "tab", @intFromEnum(n.sec) }) });
        ui.icon(n.icon, 24, col, .{}, 0);
        ui.text(t(n.label), .{ .font_size = 12, .weight = 500, .color = col, .text_align = .center });
        const count = if (n.sec == .chats) totals.unread else if (n.sec == .saved) totals.saved_unread else 0;
        if (count > 0) {
            ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .start = 0, .end = 0 }, .align_items = .center }, .{});
            ui.begin(.{ .padding = .{ .start = 30 } }, .{});
            kit.badge(cx, if (count > 99) "99+" else fmt.number(cx.a(), count), false);
            ui.end();
            ui.end();
        }
        ui.end();
    }
    ui.end();
}

fn sidebar(cx: Cx) void {
    const s = cx.s;
    if (s.panes.items.len > 0) {
        const p = s.panes.items[s.panes.items.len - 1];
        switch (p) {
            .archive => archivePane(cx),
            else => vset.pane(cx, p),
        }
        return;
    }
    if (s.mode == .embed) return chatsPane(cx);
    switch (s.section) {
        .chats => chatsPane(cx),
        .calls => callsPane(cx),
        .saved => savedPane(cx),
        .contacts => contactsPane(cx),
        .ai => @import("bots.zig").rootPane(cx),
        .settings => vset.settingsRoot(cx),
    }
}

/// A pane's header: back button (or not), title, actions.
pub fn paneHeader(cx: Cx, title: []const u8, back: bool, large: bool) void {
    const ui = cx.ui;
    if (large) {
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .top = 20, .bottom = 10, .start = 20, .end = 14 } }, .{});
        ui.text(title, .{ .font_size = 27, .weight = 700, .color = cx.c.text, .grow = 1, .width = .fill, .max_lines = 1 });
        return;
    }
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6, .height = .{ .px = theme.header_h }, .padding = .xy(14, 0) }, .{});
    if (back) kit.iconButton(cx, icons.back, .pop_pane, .{ .rtl = icons.back_rtl });
    ui.text(title, .{ .font_size = 20, .weight = 700, .color = cx.c.text, .grow = 1, .width = .fill, .max_lines = 1 });
}

pub fn endHeader(cx: Cx) void {
    cx.ui.end();
}

fn emptyMain(cx: Cx) void {
    const ui = cx.ui;
    const c = cx.c;
    const s = cx.s;
    const embed = s.mode == .embed;
    ui.begin(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 8, .padding = .all(24) }, .{});
    ui.begin(.{ .padding = .{ .bottom = 10 } }, .{});
    views.logo(cx, 96);
    ui.end();
    const title = if (embed) (if (s.embed.app) |a| a.s("theme.title") orelse a.s("name") orelse t("Chats") else t("Chats")) else t("Reseal");
    ui.text(title, .{ .font_size = 30, .weight = 700, .color = c.text, .text_align = .center });
    ui.text(if (embed) t("Pick a conversation to read and reply.") else t("Pick a conversation, or start something new. Your chats are encrypted on your devices."), .{ .font_size = 16, .color = c.text_2, .text_align = .center, .max_width = 380, .line_height = 1.5 });
    if (!embed) {
        ui.begin(.{ .direction = .row, .gap = 10, .padding = .{ .top = 18 } }, .{});
        quickAction(cx, icons.compose, t("New chat"), .{ .push_pane = .{ .picker = .new_message } }, c.brand);
        quickAction(cx, icons.users, t("New group"), .{ .push_pane = .{ .picker = .new_group } }, c.v);
        quickAction(cx, icons.bookmark, t("Saved"), .{ .nav = .saved }, c.p);
        quickAction(cx, icons.sparkles, t("Ask AI"), .{ .nav = .ai }, c.o);
        ui.end();
    }
    ui.begin(.{ .direction = .row, .gap = 7, .align_items = .center, .padding = .{ .top = 22 } }, .{});
    ui.icon(icons.lock, 14, c.text_3, .{}, 0);
    ui.text(t("Encrypted on your devices"), .{ .font_size = 13, .color = c.text_3 });
    ui.end();
    ui.end();
}

fn quickAction(cx: Cx, ic: zui.Icon, label: []const u8, msg: Msg, col: Color) void {
    const ui = cx.ui;
    ui.begin(.{ .width = .{ .px = 150 }, .gap = 10, .padding = .all(16), .radius = 20, .background = cx.c.surface_2, .pressed_background = cx.c.surface_3 }, .{ .on_press = msg });
    ui.begin(.{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .radius = 13, .background = col, .align_items = .center, .justify = .center }, .{});
    ui.icon(ic, 22, cx.c.onOf(col), .{}, 0);
    ui.end();
    ui.text(label, .{ .font_size = 14, .weight = 500, .color = cx.c.text });
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// Chat list items

pub fn chatAvatar(cx: Cx, c: *const data.Chat, size: f32) void {
    const s = cx.s;
    const k = key(.{ "cav", c.id() });
    if (c.is("saved")) {
        if (c.o.b("primary")) return kit.avatar(cx, .{ .saved = true, .size = size }, k);
        return kit.avatar(cx, .{ .name = c.o.s("title") orelse "", .color = c.o.i("color") orelse 0, .size = size }, k);
    }
    if (c.isTeamChat()) {
        if (s.store.isTeamStaff(c)) {
            const u = s.store.user(j.strOr(c.o.v, "visitor.id", ""));
            return kit.avatar(cx, .{ .name = if (u) |x| s.store.userName(x) else "?", .color = if (u) |x| x.i("color") orelse 0 else 0, .image = if (u) |x| x.s("avatar") else null, .image_url = if (u) |x| x.s("avatarUrl") else null, .size = size }, k);
        }
        return kit.avatar(cx, .{ .name = j.strOr(c.o.v, "team.name", ""), .color = j.int(c.o.v, "team.color") orelse c.o.i("color") orelse 0, .image_url = j.str(c.o.v, "team.avatarUrl"), .size = size, .square = true }, k);
    }
    if (c.is("private") or c.is("bot")) {
        const p = s.store.peer(c);
        const name = if (p) |x| s.store.userName(x) else j.strOr(c.o.v, "peer.displayName", "?");
        return kit.avatar(cx, .{
            .name = name,
            .color = if (p) |x| x.i("color") orelse 0 else c.o.i("color") orelse 0,
            .image = if (p) |x| x.s("avatar") else null,
            .image_url = if (p) |x| x.s("avatarUrl") else null,
            .size = size,
            .icon = if (p != null and p.?.b("deleted")) icons.user else null,
            .online = if (c.is("private")) (if (p) |x| std.mem.eql(u8, x.s("presence.status") orelse "", "online") else false) else null,
        }, k);
    }
    kit.avatar(cx, .{ .name = c.o.s("title") orelse "", .color = c.o.i("color") orelse 0, .image = c.o.s("avatar"), .size = size }, k);
}

fn titleIcon(c: *const data.Chat) ?zui.Icon {
    if (c.is("channel")) return icons.megaphone;
    if (c.isTeamChat()) return null;
    if (c.is("group") or c.is("support")) return icons.users;
    if (c.is("bot")) return icons.bot;
    return null;
}

fn previewOf(cx: Cx, c: *const data.Chat) struct { prefix: ?[]const u8 = null, body: []const u8, color: Color, draft: bool = false } {
    const s = cx.s;
    const a = cx.a();
    if (c.meBool("locked")) return .{ .body = t("Locked chat"), .color = cx.c.text_2 };
    const typing_now = text.typingText(s, c);
    if (typing_now.len > 0) return .{ .body = typing_now, .color = cx.c.accent };
    if (@import("drafts.zig").preview(s, c.id()) orelse (if (!s.open_chat.eql(c.id())) j.str(c.me(), "draft.text") else null)) |d| if (d.len > 0) return .{ .prefix = std.fmt.allocPrint(a, "{s}: ", .{t("Draft")}) catch "", .body = fmt.plain(a, d, 80), .color = cx.c.text_2, .draft = true };
    const m = c.last orelse return .{ .body = if (c.is("saved")) (if (c.o.s("about")) |ab| (if (ab.len > 0) ab else t("Save messages, files and notes here")) else t("Save messages, files and notes here")) else "", .color = cx.c.text_2 };
    var prefix: ?[]const u8 = null;
    if (!m.isService() and m.senderId().len > 0) {
        if (s.store.isMe(m.authorId()) and !c.is("saved") and !c.is("channel")) {
            prefix = std.fmt.allocPrint(a, "{s}: ", .{t("You")}) catch null;
        } else if (s.store.showsSenderNames(c)) prefix = std.fmt.allocPrint(a, "{s}: ", .{fmt.firstName(s.store.displayName(m.senderId()))}) catch null;
    }
    return .{ .prefix = prefix, .body = text.summary(s, m, true), .color = cx.c.text_2 };
}

pub fn chatItem(cx: Cx, c: *const data.Chat, msg: Msg) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    const a = cx.a();
    const unread = c.unread();
    const muted = c.isMuted();
    const active = s.open_chat.eql(c.id());
    const m = c.last;
    const at: i64 = if (m) |x| x.at else sys.parseIso(j.str(c.me(), "draft.at") orelse c.o.s("lastMessageAt") orelse "") orelse 0;
    // A long press or right click opens the chat's menu (Reseal-js chatlist contextmenu).
    const menu_msg: ?Msg = if (s.mode == .app) Msg{ .menu = .{ .menu = .{ .kind = .chat_row, .target = Id.of(c.id()) } } } else null;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 13, .height = .{ .px = 70 }, .padding = .xy(10, 0), .radius = 18, .background = if (active) col.accent_soft else null, .pressed_background = col.active, .hover_background = if (active) null else col.hover, .transition = .{ .duration_ms = 220 } }, .{ .on_press = msg, .on_long_press = menu_msg, .on_context = menu_msg, .key = key(.{ "chat", c.id() }) });
    chatAvatar(cx, c, 50);
    ui.begin(.{ .grow = 1, .width = .fill, .gap = 3 }, .{});
    // Title row
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6 }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 5, .grow = 1, .width = .fill }, .{});
    if (titleIcon(c)) |ic| ui.icon(ic, 15, col.text_3, .{}, 0);
    ui.text(s.store.title(c), .{ .font_size = 16, .weight = 500, .color = col.text, .max_lines = 1 });
    if (s.store.isTeamStaff(c)) {
        ui.begin(.{ .padding = .xy(7, 1), .radius = 999, .background = col.surface_3 }, .{});
        ui.text(j.strOr(c.o.v, "team.name", ""), .{ .font_size = 12, .weight = 500, .color = col.text_3, .max_lines = 1 });
        ui.end();
    }
    if (c.meBool("locked")) ui.icon(icons.lock, 14, col.text_3, .{}, 0);
    if (muted) ui.icon(icons.bellOff, 14, col.text_3, .{}, 0);
    ui.end();
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 3 }, .{});
    if (m) |x| if (s.store.isMe(x.authorId()) and !x.isService() and !c.is("saved") and !c.is("channel")) {
        if (x.state == .sending) {
            ui.icon(icons.clock, 16, col.accent, .{}, 0);
        } else if ((c.o.i("readSeq") orelse 0) >= (x.seq() orelse 0)) ui.icon(icons.checks, 16, col.accent, .{}, 0) else ui.icon(icons.check, 16, col.accent, .{}, 0);
    };
    if (at > 0) ui.text(fmt.shortDate(a, at), .{ .font_size = 12, .color = col.text_3 });
    ui.end();
    ui.end();
    // Preview row
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6 }, .{});
    const p = previewOf(cx, c);
    ui.begin(.{ .direction = .row, .grow = 1, .width = .fill }, .{});
    const line = if (p.prefix) |pre| std.fmt.allocPrint(a, "{s}{s}", .{ pre, p.body }) catch p.body else p.body;
    ui.text(line, .{ .font_size = 14, .color = if (p.draft) col.danger else p.color, .max_lines = 1 });
    ui.end();
    if (c.meInt("mentions") > 0) kit.badge(cx, "@", false);
    if (unread > 0 or c.meBool("markedUnread")) {
        kit.badge(cx, if (unread > 999) "999+" else if (unread > 0) fmt.number(a, unread) else "", muted);
    } else if (c.pinnedAt() != 0) ui.icon(icons.pin, 16, col.text_3, .{}, 0);
    ui.end();
    ui.end();
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// Chats pane

pub fn matchesFilter(s: *const app.State, c: *const data.Chat, f: app.Filter) bool {
    return switch (f) {
        .all => true,
        .unread => c.unread() > 0 or c.meBool("markedUnread"),
        .people => c.is("private"),
        .groups => c.is("group") or c.is("support"),
        .channels => c.is("channel"),
        .ai => c.is("bot"),
        .folder => |id| matchesFolder(s, c, id.str()),
    };
}

fn folderById(s: *const app.State, id: []const u8) ?j.Value {
    const f = s.store.folders orelse return null;
    for (j.arr(f.v, "folders")) |x| if (j.eqlStr(x, "id", id)) return x;
    return null;
}

fn has(list: []j.Value, id: []const u8) bool {
    for (list) |x| if (x == .string and std.mem.eql(u8, x.string, id)) return true;
    return false;
}

fn matchesFolder(s: *const app.State, c: *const data.Chat, id: []const u8) bool {
    const f = folderById(s, id) orelse return false;
    if (has(j.arr(f, "excludeChatIds"), c.id())) return false;
    if (j.truthy(f, "excludeArchived") and c.archived()) return false;
    if (j.truthy(f, "excludeMuted") and c.isMuted()) return false;
    if (j.truthy(f, "excludeRead") and c.unread() == 0 and !c.meBool("markedUnread")) return false;
    if (has(j.arr(f, "chatIds"), c.id())) return true;
    const peer = s.store.peer(c);
    for (j.arr(f, "include")) |x| {
        if (x != .string) continue;
        const ty = x.string;
        if (std.mem.eql(u8, ty, "groups") and (c.is("group") or c.is("support"))) return true;
        if (std.mem.eql(u8, ty, "channels") and c.is("channel")) return true;
        if (std.mem.eql(u8, ty, "bots") and c.is("bot")) return true;
        const contact = if (peer) |p| p.b("inContacts") or p.b("isContact") else false;
        if (std.mem.eql(u8, ty, "contacts") and c.is("private") and contact) return true;
        if (std.mem.eql(u8, ty, "noncontacts") and c.is("private") and !contact) return true;
    }
    return false;
}

/// The widget's host may show only one team's conversations.
fn embedFilter(s: *const app.State, c: *const data.Chat) bool {
    if (s.mode != .embed) return true;
    const opts = if (s.embed.options) |o| o.v else return true;
    const team = j.field(opts, "filter.team") orelse return true;
    const want = switch (team) {
        .string => |x| x,
        .integer => |n| std.fmt.allocPrint(app.tmp(), "{d}", .{n}) catch "",
        else => return true,
    };
    return std.mem.eql(u8, j.strOr(c.o.v, "team.externalId", ""), want);
}

pub fn visibleChats(cx: Cx, archived: bool) []*data.Chat {
    const s = cx.s;
    var out: std.ArrayList(*data.Chat) = .empty;
    const base = s.store.sorted(cx.a(), archived);
    for (base) |c| {
        if (c.is("saved")) continue;
        if (!embedFilter(s, c)) continue;
        if (!archived and !matchesFilter(s, c, s.filter)) continue;
        out.append(cx.a(), c) catch {};
    }
    return out.items;
}

fn chip(cx: Cx, label: []const u8, n: i64, active: bool, msg: Msg) void {
    const ui = cx.ui;
    const c = cx.c;
    // Long press or right click: "Mark all as read" for the chats it shows.
    const menu: ?Msg = if (msg == .filter) @import("listextras.zig").chipMsg(msg.filter) else null;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6, .height = .{ .px = 32 }, .padding = .xy(13, 0), .radius = 11, .background = if (active) c.text else c.surface_2 }, .{ .on_press = msg, .on_long_press = menu, .on_context = menu, .key = key(.{ "chip", label }) });
    ui.text(label, .{ .font_size = 13, .weight = 500, .color = if (active) c.surface else c.text_2, .max_lines = 1 });
    if (n > 0) {
        ui.begin(.{ .min_width = 18, .height = .{ .px = 18 }, .padding = .xy(5, 0), .radius = 6, .background = if (active) c.surface else c.accent, .align_items = .center, .justify = .center }, .{});
        ui.text(fmt.number(cx.a(), n), .{ .font_size = 12, .weight = 700, .color = if (active) c.text else c.on_accent, .line_height = 1.2 });
        ui.end();
    }
    ui.end();
}

fn filterChips(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    var any_groups = false;
    var any_channels = false;
    var any_ai = false;
    var counts: [6]i64 = @splat(0);
    var it = s.store.chats.valueIterator();
    while (it.next()) |cp| {
        const c = cp.*;
        if (c.is("saved") or c.archived()) continue;
        if (c.is("group") or c.is("support")) any_groups = true;
        if (c.is("channel")) any_channels = true;
        if (c.is("bot")) any_ai = true;
        const has_unread = (c.unread() > 0 or c.meBool("markedUnread")) and !c.isMuted();
        if (!has_unread) continue;
        counts[1] += 1;
        if (c.is("private")) counts[2] += 1;
        if (c.is("group") or c.is("support")) counts[3] += 1;
        if (c.is("channel")) counts[4] += 1;
        if (c.is("bot")) counts[5] += 1;
    }
    ui.beginScroll(.{ .direction = .row, .gap = 6, .padding = .{ .start = 14, .end = 14, .top = 2, .bottom = 10 }, .height = .{ .px = 44 } }, key(.{"chips"}));
    chip(cx, t("All"), 0, s.filter == .all, .{ .filter = .all });
    chip(cx, t("Unread"), counts[1], s.filter == .unread, .{ .filter = .unread });
    chip(cx, t("People"), counts[2], s.filter == .people, .{ .filter = .people });
    if (any_groups) chip(cx, t("Groups"), counts[3], s.filter == .groups, .{ .filter = .groups });
    if (any_channels) chip(cx, t("Channels"), counts[4], s.filter == .channels, .{ .filter = .channels });
    if (any_ai) chip(cx, t("AI"), counts[5], s.filter == .ai, .{ .filter = .ai });
    if (s.store.folders) |f| for (j.arr(f.v, "folders")) |x| {
        const id = j.strOr(x, "id", "");
        // The folder's name only: the app's chrome shows no emoji.
        const label = j.strOr(x, "name", "");
        const active = s.filter == .folder and s.filter.folder.eql(id);
        chip(cx, label, 0, active, .{ .filter = .{ .folder = Id.of(id) } });
    };
    if (s.mode == .app) {
        ui.begin(.{ .width = .{ .px = 32 }, .height = .{ .px = 32 }, .radius = 11, .background = cx.c.surface_2, .align_items = .center, .justify = .center }, .{ .on_press = .{ .push_pane = .folders }, .key = key(.{"chip-folders"}) });
        ui.icon(icons.plus, 16, cx.c.text_2, .{}, 0);
        ui.end();
    }
    ui.end();
}

fn embedHeader(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const appv = if (s.embed.app) |a| a.v else null;
    const title = j.str(appv, "theme.title") orelse j.strOr(appv, "name", "Chat");
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .padding = .{ .top = 14, .bottom = 6, .start = 16, .end = 10 } }, .{});
    if (j.str(appv, "theme.logoUrl")) |logo_url| {
        ui.begin(.{ .width = .{ .px = 32 }, .height = .{ .px = 32 }, .radius = 9, .clip = true }, .{});
        ui.image(logo_url, .{ .width = .{ .px = 32 }, .height = .{ .px = 32 } }, key(.{"elogo"}));
        ui.end();
    } else kit.avatar(cx, .{ .name = title, .color = 2, .size = 32, .square = true }, key(.{"elogo"}));
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    ui.text(title, .{ .font_size = 16, .weight = 700, .color = cx.c.text, .max_lines = 1 });
    if (j.str(appv, "theme.subtitle")) |sub| ui.text(sub, .{ .font_size = 13, .color = cx.c.text_2, .max_lines = 1 });
    ui.end();
    const mode = if (s.embed.options) |o| o.s("mode") orelse j.strOr(appv, "widget.mode", "bubble") else j.strOr(appv, "widget.mode", "bubble");
    if (!std.mem.eql(u8, mode, "inline")) kit.iconButton(cx, icons.close, .{ .chat_action = .{ .what = .search, .chat = Id.of("__close") } }, .{});
    ui.end();
    // Entries: the assistant, the team.
    const filtered = if (s.embed.options) |o| o.get("filter.team") != null else false;
    if (filtered) return;
    if (j.str(appv, "widget.welcome")) |w| {
        ui.begin(.{ .padding = .xy(18, 6), .gap = 2 }, .{});
        ui.text(t("Hi there"), .{ .font_size = 17, .weight = 700, .color = cx.c.text });
        ui.text(w, .{ .font_size = 14, .color = cx.c.text_2, .line_height = 1.5 });
        ui.end();
    }
    if (j.obj(appv, "widget.bot")) |bot| entry(cx, j.strOr(bot, "name", t("Assistant")), t("Get an instant answer from our AI assistant"), icons.sparkles, .{ .embed_open = .bot });
    if (j.truthy(appv, "support")) entry(cx, t("Message the team"), t("We will reply right here"), icons.chat, .{ .embed_open = .support });
}

fn entry(cx: Cx, title: []const u8, sub: []const u8, ic: zui.Icon, msg: Msg) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .padding = .xy(14, 10), .radius = 12, .pressed_background = cx.c.active }, .{ .on_press = msg, .key = key(.{ "entry", title }) });
    kit.avatar(cx, .{ .icon = ic, .color = 4, .size = 44 }, 0);
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    ui.text(title, .{ .font_size = 16, .weight = 700, .color = cx.c.text });
    ui.text(sub, .{ .font_size = 14, .color = cx.c.text_2 });
    ui.end();
    ui.icon(if (cx.s.lang == .ar) icons.chevronRight_rtl else icons.chevronRight, 20, cx.c.text_3, .{}, 0);
    ui.end();
}

fn chatsPane(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    if (s.mode == .embed) {
        embedHeader(cx);
    } else if (!s.searching) {
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .top = 20, .bottom = 10, .start = 20, .end = 14 } }, .{});
        ui.text(t("Chats"), .{ .font_size = 27, .weight = 700, .color = cx.c.text, .grow = 1, .width = .fill });
        kit.iconButton(cx, icons.compose, .{ .menu = .{ .menu = .{ .kind = .compose } } }, .{ .soft = true });
        // Phones have no rail: the picture (the account menu) ends the header.
        if (cx.phone) accountPicture(cx, 38);
        ui.end();
    }
    // Keyed, so the input (and its focus) survives the header going away when searching starts.
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .start = 14, .end = 14, .bottom = 10, .top = if (s.searching) 14 else 0 } }, .{ .key = zui.key("search-row") });
    if (s.searching) kit.iconButton(cx, icons.back, .{ .toggle_search = false }, .{ .rtl = icons.back_rtl });
    kit.searchBox(cx, .search, t("Search people and chats"));
    ui.end();
    if (s.searching) {
        searchResults(cx);
    } else {
        @import("stories.zig").strip(cx);
        if (s.mode != .embed) filterChips(cx);
        chatList(cx);
    }
    ui.end();
}

fn chatList(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 10, .end = 10, .top = 2, .bottom = 96 } }, key(.{"chatlist"}));
    if (!s.store.chats_loaded) {
        kit.spinner(cx);
    } else {
        const list = visibleChats(cx, false);
        // Archived row
        if (s.filter == .all and s.mode != .embed) {
            const arch = s.store.sorted(cx.a(), true);
            var n: i64 = 0;
            for (arch) |c| if (!c.is("saved")) {
                n += 1;
            };
            if (n > 0) {
                ui.begin(.{ .direction = .row, .align_items = .center, .gap = 13, .height = .{ .px = 52 }, .padding = .xy(10, 0), .radius = 18, .pressed_background = cx.c.active }, .{ .on_press = .open_archive, .key = key(.{"archrow"}) });
                ui.begin(.{ .padding = .xy(7, 0) }, .{});
                ui.begin(.{ .width = .{ .px = 36 }, .height = .{ .px = 36 }, .radius = 12, .background = cx.c.surface_3, .align_items = .center, .justify = .center }, .{});
                ui.icon(icons.archive, 18, cx.c.text_2, .{}, 0);
                ui.end();
                ui.end();
                ui.text(std.fmt.allocPrint(cx.a(), "{s} · {s}", .{ t("Archived"), fmt.number(cx.a(), n) }) catch "", .{ .font_size = 14, .weight = 500, .color = cx.c.text, .grow = 1, .width = .fill });
                const au = s.store.totals().archived_unread;
                if (au > 0) kit.badge(cx, fmt.number(cx.a(), au), true);
                ui.end();
            }
        }
        for (list) |c| chatItem(cx, c, .{ .open_chat = Id.of(c.id()) });
        if (list.len == 0) {
            if (s.filter == .all) {
                kit.emptyState(cx, icons.chats, t("No chats yet"), t("Search for anyone with a Wufour account, or tap the pencil to start."));
            } else kit.emptyState(cx, icons.chats, t("Nothing here"), if (s.filter == .unread) t("You are all caught up.") else null);
        }
    }
    ui.end();
}

fn groupTitle(cx: Cx, title: []const u8) void {
    cx.ui.begin(.{ .padding = .{ .top = 14, .bottom = 6, .start = 12, .end = 12 } }, .{});
    var buf: [128]u8 = undefined;
    const up = std.ascii.upperString(buf[0..@min(title.len, buf.len)], title[0..@min(title.len, buf.len)]);
    cx.ui.text(cx.a().dupe(u8, up) catch title, .{ .font_size = 12, .weight = 700, .color = cx.c.text_3 });
    cx.ui.end();
}

/// A person or chat from the server's search, as a list row.
fn personRow(cx: Cx, name: []const u8, sub: []const u8, color: i64, image: ?[]const u8, msg: Msg, k: u64, tag: ?[]const u8) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 13, .height = .{ .px = 70 }, .padding = .xy(10, 0), .radius = 18, .pressed_background = cx.c.active }, .{ .on_press = msg, .key = k });
    kit.avatar(cx, .{ .name = name, .color = color, .image = image, .size = 50 }, 0);
    ui.begin(.{ .grow = 1, .width = .fill, .gap = 3 }, .{});
    ui.text(name, .{ .font_size = 16, .weight = 500, .color = cx.c.text, .max_lines = 1 });
    if (sub.len > 0) ui.text(sub, .{ .font_size = 14, .color = cx.c.text_2, .max_lines = 1 });
    ui.end();
    if (tag) |tg| {
        ui.begin(.{ .padding = .xy(8, 2), .radius = 7, .background = cx.c.accent_soft }, .{});
        ui.text(tg, .{ .font_size = 12, .weight = 700, .color = cx.c.accent });
        ui.end();
    }
    ui.end();
}

fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn searchResults(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const a = cx.a();
    const q = std.mem.trim(u8, s.fields.get(.search).get(), " ");
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 10, .end = 10, .top = 4, .bottom = 24 } }, key(.{"search"}));
    if (q.len == 0) {
        // Recent people as quick picks, then the chats.
        const all = s.store.sorted(a, false);
        var people: usize = 0;
        for (all) |c| {
            if (c.is("private") or c.is("bot")) people += 1;
        }
        if (people > 0) groupTitle(cx, t("Recent"));
        if (people > 0) ui.beginScroll(.{ .direction = .row, .gap = 4, .padding = .{ .start = 4, .end = 4, .bottom = 10 }, .height = .{ .px = 100 } }, key(.{"recent"}));
        var n: usize = 0;
        for (all) |c| {
            if (!(c.is("private") or c.is("bot"))) continue;
            if (n == 10) break;
            n += 1;
            ui.begin(.{ .width = .{ .px = 74 }, .align_items = .center, .gap = 6, .padding = .xy(0, 8), .radius = 12, .pressed_background = cx.c.hover }, .{ .on_press = .{ .open_chat = Id.of(c.id()) }, .key = key(.{ "recent", c.id() }) });
            chatAvatar(cx, c, 52);
            ui.text(fmt.firstName(s.store.title(c)), .{ .font_size = 12, .color = cx.c.text, .max_lines = 1, .max_width = 66 });
            ui.end();
        }
        if (people > 0) ui.end();
        groupTitle(cx, t("Chats"));
        for (all[0..@min(all.len, 30)]) |c| chatItem(cx, c, .{ .open_chat = Id.of(c.id()) });
        ui.end();
        return;
    }
    var any = false;
    // My chats whose name matches.
    var local_peers = std.StringHashMap(void).init(a);
    var known = std.StringHashMap(void).init(a);
    var first = true;
    var it = s.store.chats.valueIterator();
    var count: usize = 0;
    while (it.next()) |cp| {
        const c = cp.*;
        const uname = if (s.store.peer(c)) |p| p.s("username") orelse "" else "";
        const q2 = if (q[0] == '@') q[1..] else q;
        if (!contains(s.store.title(c), q) and !contains(uname, q2)) continue;
        if (count >= 20) break;
        count += 1;
        if (first) groupTitle(cx, t("Chats"));
        first = false;
        any = true;
        known.put(c.id(), {}) catch {};
        if (c.peerId()) |pid| local_peers.put(pid, {}) catch {};
        chatItem(cx, c, .{ .open_chat = Id.of(c.id()) });
    }
    if (s.search) |res| {
        var title_done = false;
        for (j.arr(res.v, "users")) |u| {
            const id = j.strOr(u, "id", "");
            if (local_peers.contains(id)) continue;
            if (!title_done) groupTitle(cx, t("Global search"));
            title_done = true;
            any = true;
            const uname = j.str(u, "username");
            personRow(cx, j.strOr(u, "displayName", ""), if (uname) |x| std.fmt.allocPrint(a, "@{s}", .{x}) catch "" else if (j.truthy(u, "isBot")) t("bot") else "", j.intOr(u, "color", 0), j.str(u, "avatar"), .{ .start_global = Id.of(id) }, key(.{ "gu", id }), null);
        }
        for (j.arr(res.v, "chats")) |ch| {
            const id = j.strOr(ch, "id", "");
            if (known.contains(id)) continue;
            if (!title_done) groupTitle(cx, t("Global search"));
            title_done = true;
            any = true;
            const members = fmt.tn(a, j.intOr(ch, "memberCount", 0), "{n} member", "{n} members");
            const sub = if (j.str(ch, "username")) |un| std.fmt.allocPrint(a, "@{s} · {s}", .{ un, members }) catch members else members;
            personRow(cx, j.strOr(ch, "title", ""), sub, j.intOr(ch, "color", 0), j.str(ch, "avatar"), .{ .open_chat = Id.of(id) }, key(.{ "gc", id }), null);
        }
        const wuf = j.arr(res.v, "wufour");
        if (wuf.len > 0) groupTitle(cx, t("On Wufour"));
        for (wuf) |w| {
            any = true;
            personRow(cx, j.strOr(w, "displayName", ""), t("Hasn't opened Reseal yet. They'll see your messages when they do."), 5, null, .{ .open_wufour = Id.of(j.strOr(w, "wufourId", "")) }, key(.{ "wf", j.strOr(w, "wufourId", "") }), t("Message"));
        }
    }
    // Messages: the server's (readable chats) and the decrypted ones loaded on this device.
    var hits_title = false;
    if (s.msg_search) |res| for (j.arr(res.v, "messages")) |m| {
        const c = s.store.chat(j.strOr(m, "chatId", "")) orelse continue;
        if (c.meBool("locked")) continue;
        if (!hits_title) groupTitle(cx, t("Messages"));
        hits_title = true;
        any = true;
        messageHit(cx, c, j.strOr(m, "text", ""), sys.parseIso(j.strOr(m, "createdAt", "")) orelse 0, key(.{ "mh", j.strOr(m, "id", "") }));
    };
    if (q.len >= 2) {
        var ti = s.store.timelines.iterator();
        while (ti.next()) |e| {
            const c = s.store.chat(e.key_ptr.*) orelse continue;
            if (!c.encrypted() or c.meBool("locked")) continue;
            const items = e.value_ptr.*.items.items;
            var i = items.len;
            while (i > 0) {
                i -= 1;
                const m = items[i];
                if (m.decrypt != .ok or !contains(m.text(), q)) continue;
                if (!hits_title) groupTitle(cx, t("Messages"));
                hits_title = true;
                any = true;
                messageHit(cx, c, m.text(), m.at, key(.{ "lh", m.id() }));
            }
        }
    }
    if (!any) kit.emptyState(cx, icons.search, t("No results"), t("Try a different name or @username."));
    ui.end();
}

fn messageHit(cx: Cx, c: *const data.Chat, body: []const u8, at: i64, k: u64) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 13, .height = .{ .px = 70 }, .padding = .xy(10, 0), .radius = 18, .pressed_background = cx.c.active }, .{ .on_press = .{ .open_chat = Id.of(c.id()) }, .key = k });
    chatAvatar(cx, c, 50);
    ui.begin(.{ .grow = 1, .width = .fill, .gap = 3 }, .{});
    ui.begin(.{ .direction = .row, .gap = 6 }, .{});
    ui.text(cx.s.store.title(c), .{ .font_size = 16, .weight = 500, .color = cx.c.text, .max_lines = 1, .grow = 1, .width = .fill });
    if (at > 0) ui.text(fmt.shortDate(cx.a(), at), .{ .font_size = 12, .color = cx.c.text_3 });
    ui.end();
    ui.text(fmt.plain(cx.a(), body, 120), .{ .font_size = 14, .color = cx.c.text_2, .max_lines = 1 });
    ui.end();
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// Archive, Saved, contacts, calls

fn archivePane(cx: Cx) void {
    const ui = cx.ui;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    paneHeader(cx, t("Archived chats"), true, false);
    endHeader(cx);
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 10, .end = 10, .bottom = 24 } }, key(.{"archive"}));
    const list = visibleChats(cx, true);
    for (list) |c| chatItem(cx, c, .{ .open_chat = Id.of(c.id()) });
    if (list.len == 0) kit.emptyState(cx, icons.archive, t("No archived chats"), t("Archived chats stay here, out of the way. Muted chats stay archived when new messages arrive."));
    ui.end();
    ui.end();
}

fn savedPane(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const a = cx.a();
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    paneHeader(cx, t("Saved"), false, true);
    endHeader(cx);
    ui.begin(.{ .padding = .{ .start = 14, .end = 14, .bottom = 10 }, .direction = .row }, .{});
    kit.searchBox(cx, .saved_search, t("Search saved chats"));
    ui.end();
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 10, .end = 10, .bottom = 24 } }, key(.{"saved"}));
    const q = std.mem.trim(u8, s.fields.get(.saved_search).get(), " ");
    var list: std.ArrayList(*data.Chat) = .empty;
    for (s.store.sorted(a, false)) |c| if (c.is("saved")) list.append(a, c) catch {};
    for (s.store.sorted(a, true)) |c| if (c.is("saved")) list.append(a, c) catch {};
    std.mem.sort(*data.Chat, list.items, {}, struct {
        fn lt(_: void, x: *data.Chat, y: *data.Chat) bool {
            return x.o.b("primary") and !y.o.b("primary");
        }
    }.lt);
    var shown: usize = 0;
    for (list.items) |c| {
        if (q.len > 0 and !contains(s.store.title(c), q) and !contains(c.o.s("about") orelse "", q)) continue;
        shown += 1;
        chatItem(cx, c, .{ .open_chat = Id.of(c.id()) });
    }
    if (q.len > 0 and shown == 0) kit.emptyState(cx, icons.search, t("No results"), null);
    if (q.len == 0 and list.items.len < 2 and s.store.chats_loaded) {
        kit.sectionNote(cx, t("Keep each topic in its own saved chat, like Work, Recipes or Ideas. Give it a name and say what it is for."));
        kit.row(cx, t("New saved chat"), .{ .icon = icons.plus, .on = .{ .push_pane = .{ .saved_edit = .{} } } });
    }
    ui.end();
    ui.end();
}

fn contactsPane(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    paneHeader(cx, t("Contacts"), false, true);
    kit.iconButton(cx, icons.userPlus, .{ .push_pane = .{ .picker = .add_contact } }, .{});
    endHeader(cx);
    ui.begin(.{ .padding = .{ .start = 12, .end = 12, .bottom = 8 }, .direction = .row }, .{});
    kit.searchBox(cx, .contacts, t("Search contacts"));
    ui.end();
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 8, .end = 8, .bottom = 24 } }, key(.{"contacts"}));
    if (s.contacts) |res| {
        const q = std.mem.trim(u8, s.fields.get(.contacts).get(), " ");
        var shown: usize = 0;
        for (j.arr(res.v, "contacts")) |u| {
            const id = j.strOr(u, "id", "");
            const obj = s.store.user(id);
            const name = if (obj) |o| s.store.userName(o) else j.strOr(u, "displayName", "");
            if (q.len > 0 and !contains(name, q) and !contains(j.strOr(u, "username", ""), q)) continue;
            shown += 1;
            const presence = if (obj) |o| o.get("presence") else j.field(u, "presence");
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 14, .min_height = 52, .padding = .xy(12, 8), .radius = theme.radius, .pressed_background = cx.c.active }, .{ .on_press = .{ .start_global = Id.of(id) }, .key = key(.{ "ct", id }) });
            kit.avatar(cx, .{ .name = name, .color = j.intOr(u, "color", 0), .image = j.str(u, "avatar"), .size = 46, .online = std.mem.eql(u8, j.strOr(presence, "status", ""), "online") }, 0);
            ui.begin(.{ .grow = 1, .width = .fill }, .{});
            ui.text(name, .{ .font_size = 16, .weight = 500, .color = cx.c.text, .max_lines = 1 });
            ui.text(text.presenceText(presence), .{ .font_size = 14, .color = cx.c.text_2, .max_lines = 1 });
            ui.end();
            ui.end();
        }
        if (shown == 0) kit.emptyState(cx, icons.contacts, t("No contacts yet"), t("Add people by their @username with the button above."));
    } else kit.spinner(cx);
    ui.end();
    ui.end();
}

fn callsPane(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const a = cx.a();
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    paneHeader(cx, t("Calls"), false, true);
    endHeader(cx);
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 8, .end = 8, .bottom = 24 } }, key(.{"calls"}));
    if (s.calls_list) |res| {
        var shown: usize = 0;
        for (j.arr(res.v, "calls"), 0..) |cl, i| {
            const c = s.store.chat(j.strOr(cl, "chatId", "")) orelse continue;
            shown += 1;
            const outgoing = j.truthy(cl, "outgoing");
            const status = j.strOr(cl, "status", "");
            const missed = !outgoing and (std.mem.eql(u8, status, "missed") or std.mem.eql(u8, status, "declined"));
            const kind = if (j.truthy(cl, "group")) t("Group call") else if (j.truthy(cl, "video")) t("Video") else t("Voice");
            var sub: std.ArrayList(u8) = .empty;
            sub.print(a, "{s} · {s}", .{ kind, fmt.shortDate(a, sys.parseIso(j.strOr(cl, "createdAt", "")) orelse 0) }) catch {};
            if (j.float(cl, "duration")) |d| if (d > 0) sub.print(a, " · {s}", .{fmt.duration(a, d)}) catch {};
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 4 }, .{ .key = key(.{ "clw", i }) });
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 14, .min_height = 60, .padding = .xy(12, 8), .radius = theme.radius, .pressed_background = cx.c.active, .grow = 1, .width = .fill }, .{ .on_press = .{ .open_chat = Id.of(c.id()) }, .key = key(.{ "cl", i }) });
            chatAvatar(cx, c, 46);
            ui.begin(.{ .grow = 1, .width = .fill, .gap = 2 }, .{});
            ui.text(s.store.title(c), .{ .font_size = 16, .weight = 500, .color = if (missed) cx.c.danger else cx.c.text, .max_lines = 1 });
            ui.begin(.{ .direction = .row, .gap = 4, .align_items = .center }, .{});
            ui.icon(if (outgoing) icons.callOut else icons.callIn, 14, cx.c.text_2, .{}, 0);
            ui.text(sub.items, .{ .font_size = 14, .color = cx.c.text_2, .max_lines = 1 });
            ui.end();
            ui.end();
            ui.end();
            // Call back (one-to-one calls).
            if (c.is("private")) kit.iconButton(cx, if (j.truthy(cl, "video")) icons.video else icons.phone, .{ .chat_action = .{ .what = if (j.truthy(cl, "video")) .call_video else .call_voice, .chat = Id.of(c.id()) } }, .{});
            ui.end();
        }
        if (shown == 0) kit.emptyState(cx, icons.phone, t("No calls yet"), t("Your recent calls will appear here."));
    } else kit.spinner(cx);
    ui.end();
    ui.end();
}
