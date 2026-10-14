//! The info panel of a group or channel (Reseal-js ui/info.js groupInfo, editPane, adminsPane,
//! bannedPane, requestsPane, invitesPane) and its sheets (a member's actions, admin rights, a new
//! invite link, slow mode, reactions).

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
const vlist = @import("view_list.zig");
const vchat = @import("view_chat.zig");
const group = @import("group.zig");

const Cx = kit.Cx;
const Msg = app.Msg;
const Id = app.Id;
const t = zui.i18n.t;
const key = kit.key;
const can = vchat.can;
const isAdmin = vchat.isAdmin;

fn act(a: group.Act) Msg {
    return .{ .group = a };
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

/// The panel's title and whether it has a back button (a page other than the first).
pub fn pageTitle(s: *const app.State, c: *const data.Chat) ?[]const u8 {
    return switch (s.group.page) {
        .main => if (c.is("channel")) t("Channel info") else t("Group info"),
        .edit => t("Edit"),
        .admins => t("Administrators"),
        .banned => t("Banned users"),
        .requests => t("Join requests"),
        .invites => t("Invite links"),
    };
}

pub fn canEdit(c: *const data.Chat) bool {
    return isAdmin(c) or can(c, "changeInfo");
}

pub fn body(cx: Cx, c: *const data.Chat) void {
    switch (cx.s.group.page) {
        .main => main(cx, c),
        .edit => edit(cx, c),
        .admins => memberList(cx, c, t("Nobody here yet")),
        .banned => banned(cx, c),
        .requests => requests(cx, c),
        .invites => invites(cx, c),
    }
}

fn main(cx: Cx, c: *const data.Chat) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    const a = cx.a();
    const channel = c.is("channel");
    ui.begin(.{ .align_items = .center, .gap = 6, .padding = .{ .top = 12, .bottom = 12 } }, .{});
    vlist.chatAvatar(cx, c, 96);
    ui.text(s.store.title(c), .{ .font_size = 22, .weight = 800, .color = col.text, .text_align = .center });
    const count = c.o.i("memberCount") orelse 0;
    ui.text(if (channel) fmt.tn(a, count, "{n} subscriber", "{n} subscribers") else fmt.tn(a, count, "{n} member", "{n} members"), .{ .font_size = 14, .color = col.text_2, .text_align = .center });
    ui.end();
    // Quick actions.
    ui.begin(.{ .direction = .row, .justify = .center, .gap = 8, .padding = .{ .bottom = 10 } }, .{});
    const muted = c.isMuted();
    quick(cx, if (muted) icons.bell else icons.bellOff, if (muted) t("Unmute") else t("Mute"), .{ .chat_action = .{ .what = if (muted) .unmute else .mute, .chat = Id.of(c.id()) } });
    if (!channel and @import("view_chat.zig").feature(s, "calls")) quick(cx, icons.phone, t("Voice chat"), .{ .call = .{ .join = Id.of(c.id()) } });
    if (can(c, "addMembers") or can(c, "inviteUsers")) quick(cx, icons.userPlus, t("Add"), .{ .push_pane = .{ .picker = .add_members } });
    if (!eq(c.role(), "owner")) quick(cx, icons.logout, t("Leave"), .{ .chat_action = .{ .what = .leave, .chat = Id.of(c.id()) } });
    ui.end();
    if (c.o.s("about")) |about| if (about.len > 0) kit.row(cx, about, .{ .icon = icons.info, .subtitle = t("Description") });
    if (c.o.s("username")) |un| {
        kit.row(cx, std.fmt.allocPrint(a, "@{s}", .{un}) catch "", .{ .icon = icons.link, .subtitle = t("Public link"), .on = act(.copy_link) });
    } else if (can(c, "inviteUsers") or can(c, "addMembers")) {
        kit.row(cx, t("Invite links"), .{ .icon = icons.link, .chevron = true, .on = act(.{ .page = .invites }) });
    }
    if (c.encrypted()) kit.row(cx, t("Messages are end-to-end encrypted"), .{ .icon = icons.shieldCheck, .subtitle = t("Encryption") }) else kit.row(cx, t("Messages are stored encrypted on the server, not end-to-end"), .{ .icon = icons.globe, .subtitle = t("Encryption") });
    if (c.o.i("ttl")) |ttl| if (ttl > 0) kit.row(cx, fmt.tf("Messages disappear after {time}", .{ .time = fmt.longDuration(a, ttl) }), .{ .icon = icons.timer, .subtitle = t("Auto-delete") });
    if (canEdit(c)) kit.row(cx, t("Edit"), .{ .icon = icons.edit, .chevron = true, .on = act(.{ .page = .edit }) });

    if (!channel or isAdmin(c)) {
        kit.sectionTitle(cx, if (channel) t("Subscribers") else t("Members"));
        if (isAdmin(c) and s.group.requests > 0) kit.row(cx, fmt.tn(a, s.group.requests, "{n} join request", "{n} join requests"), .{ .icon = icons.userPlus, .chevron = true, .on = act(.{ .page = .requests }) });
        if (s.members) |mres| if (s.members_chat.eql(c.id())) {
            const list = j.arr(mres.v, "members");
            // More than 15: a search over the names.
            if (list.len > 15) {
                ui.begin(.{ .direction = .row, .padding = .xy(8, 4) }, .{});
                kit.searchBox(cx, .member_search, t("Search members"));
                ui.end();
            }
            const q = std.mem.trim(u8, s.fields.get(.member_search).get(), " ");
            for (list) |m| {
                if (q.len > 0 and list.len > 15) {
                    const nm = j.strOr(m, "user.displayName", "");
                    const un = j.strOr(m, "user.username", "");
                    if (std.ascii.findIgnoreCase(nm, q) == null and std.ascii.findIgnoreCase(un, q) == null) continue;
                }
                memberRow(cx, c, m);
            }
        };
    }
    ui.begin(.{ .padding = .{ .top = 12 } }, .{});
    kit.row(cx, t("More actions"), .{ .icon = icons.more, .on = .{ .menu = .{ .menu = .{ .kind = .chat_row, .target = Id.of(c.id()) } } } });
    if (eq(c.role(), "owner")) kit.row(cx, if (channel) t("Delete channel") else t("Delete group"), .{ .icon = icons.trash, .danger = true, .on = .{ .chat_action = .{ .what = .delete, .chat = Id.of(c.id()) } } });
    ui.end();
}

fn quick(cx: Cx, ic: zui.Icon, label: []const u8, msg: Msg) void {
    const ui = cx.ui;
    ui.begin(.{ .align_items = .center, .gap = 4, .min_width = 76, .padding = .xy(10, 8), .radius = 14, .background = cx.c.surface_2, .pressed_background = cx.c.active }, .{ .on_press = msg });
    ui.icon(ic, 21, cx.c.accent, .{}, 0);
    ui.text(label, .{ .font_size = 12.5, .weight = 600, .color = cx.c.text, .max_lines = 1 });
    ui.end();
}

/// Someone in the members list: their name, presence and role; a tap opens their profile, the
/// end button (for admins who may act on them) their actions.
fn memberRow(cx: Cx, c: *const data.Chat, m: j.Value) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    const u = j.obj(m, "user") orelse return;
    const uid = j.strOr(u, "id", "");
    const role = j.strOr(m, "role", "");
    const obj = s.store.user(uid);
    const me = s.store.isMe(uid);
    var name = if (obj) |o| s.store.userName(o) else j.strOr(u, "displayName", "");
    if (me) name = std.fmt.allocPrint(cx.a(), "{s} ({s})", .{ name, t("you") }) catch name;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 52, .padding = .xy(12, 6), .radius = theme.radius, .pressed_background = col.active }, .{ .on_press = if (me) null else Msg{ .open_user = Id.of(uid) }, .key = key(.{ "mem", uid }) });
    kit.avatar(cx, .{ .name = if (obj) |o| s.store.userName(o) else j.strOr(u, "displayName", ""), .color = j.intOr(u, "color", 0), .image = j.str(u, "avatar"), .size = 42, .online = eq(j.strOr(u, "presence.status", ""), "online") }, 0);
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    ui.text(name, .{ .font_size = 15, .weight = 550, .color = col.text, .max_lines = 1 });
    ui.text(if (j.truthy(u, "isBot")) t("bot") else text.presenceText(if (obj) |o| o.get("presence") else j.field(u, "presence")), .{ .font_size = 13, .color = col.text_2, .max_lines = 1 });
    ui.end();
    if (eq(role, "owner")) ui.text(t("owner"), .{ .font_size = 12.5, .color = col.text_3 }) else if (eq(role, "admin")) ui.text(if (j.str(m, "title")) |tt| (if (tt.len > 0) tt else t("admin")) else t("admin"), .{ .font_size = 12.5, .color = col.text_3, .max_lines = 1 });
    ui.end();
    // A separate button: nested pressable views would take each other's taps.
    if (!me and !eq(role, "owner") and (can(c, "banUsers") or can(c, "addAdmins"))) {
        ui.begin(.{ .direction = .row, .justify = .end, .padding = .{ .end = 6 } }, .{ .key = key(.{ "memact", uid }) });
        kit.button(cx, t("Manage"), act(.{ .member_menu = Id.of(uid) }), .{ .small = true, .kind = .plain });
        ui.end();
    }
}

fn memberList(cx: Cx, c: *const data.Chat, empty: []const u8) void {
    const s = cx.s;
    const l = s.group.list orelse return kit.spinner(cx);
    if (s.group.list_page != s.group.page) return kit.spinner(cx);
    const list = j.arr(l.v, "members");
    if (list.len == 0) return kit.emptyState(cx, icons.users, empty, null);
    for (list) |m| memberRow(cx, c, m);
}

fn banned(cx: Cx, c: *const data.Chat) void {
    _ = c;
    const s = cx.s;
    const l = s.group.list orelse return kit.spinner(cx);
    if (s.group.list_page != .banned) return kit.spinner(cx);
    const list = j.arr(l.v, "members");
    if (list.len == 0) return kit.emptyState(cx, icons.check, t("Nobody is banned"), null);
    for (list) |m| personWithButtons(cx, m, &.{.{ .label = t("Unban"), .msg = act(.{ .unban = Id.of(userId(m)) }), .kind = .ghost }});
}

fn requests(cx: Cx, c: *const data.Chat) void {
    _ = c;
    const s = cx.s;
    const l = s.group.list orelse return kit.spinner(cx);
    if (s.group.list_page != .requests) return kit.spinner(cx);
    const list = j.arr(l.v, "members");
    if (list.len == 0) return kit.emptyState(cx, icons.userPlus, t("No pending requests"), null);
    for (list) |m| personWithButtons(cx, m, &.{
        .{ .label = t("Add"), .msg = act(.{ .approve = Id.of(userId(m)) }), .kind = .primary },
        .{ .label = t("Dismiss"), .msg = act(.{ .dismiss_request = Id.of(userId(m)) }), .kind = .ghost },
    });
}

fn userId(m: j.Value) []const u8 {
    return j.strOr(m, "userId", j.strOr(m, "user.id", ""));
}

const RowButton = struct { label: []const u8, msg: Msg, kind: kit.ButtonKind };

fn personWithButtons(cx: Cx, m: j.Value, buttons: []const RowButton) void {
    const ui = cx.ui;
    const uid = userId(m);
    const u = j.obj(m, "user");
    const name = if (cx.s.store.user(uid)) |o| cx.s.store.userName(o) else j.strOr(u, "displayName", "");
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .min_height = 56, .padding = .xy(12, 6) }, .{ .key = key(.{ "person", uid }) });
    kit.avatar(cx, .{ .name = name, .color = j.intOr(u, "color", 0), .image = j.str(u, "avatar"), .size = 42 }, 0);
    ui.text(name, .{ .font_size = 15, .weight = 550, .color = cx.c.text, .max_lines = 1, .grow = 1, .width = .fill });
    for (buttons) |b| kit.button(cx, b.label, b.msg, .{ .small = true, .kind = b.kind });
    ui.end();
}

fn invites(cx: Cx, c: *const data.Chat) void {
    _ = c;
    const ui = cx.ui;
    const s = cx.s;
    const a = cx.a();
    kit.sectionNote(cx, t("Anyone with an invite link can join. You can limit links by time or number of uses, or require admin approval."));
    ui.begin(.{ .padding = .{ .start = 8, .end = 8, .bottom = 8 } }, .{});
    kit.button(cx, t("Create invite link"), act(.invite_new), .{ .block = true, .icon = icons.plus });
    ui.end();
    const l = s.group.list orelse return kit.spinner(cx);
    if (s.group.list_page != .invites) return kit.spinner(cx);
    for (j.arr(l.v, "invites")) |inv| {
        const code = j.strOr(inv, "code", "");
        const link = j.strOr(inv, "link", "");
        var parts: std.ArrayList(u8) = .empty;
        const limit = j.intOr(inv, "usageLimit", 0);
        const uses = j.intOr(inv, "uses", 0);
        parts.appendSlice(a, if (limit > 0) fmt.tf("{used} of {limit} used", .{ .used = uses, .limit = limit }) else fmt.tn(a, uses, "{n} joined", "{n} joined")) catch {};
        if (j.str(inv, "expiresAt")) |e| if (sys.parseIso(e)) |ms| parts.print(a, " · {s}", .{fmt.tf("expires {date}", .{ .date = fmt.shortDate(a, ms) })}) catch {};
        if (j.truthy(inv, "requestApproval")) parts.print(a, " · {s}", .{t("needs approval")}) catch {};
        const shown = if (j.str(inv, "name")) |n| (if (n.len > 0) n else stripScheme(link)) else stripScheme(link);
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6 }, .{ .key = key(.{ "inv", code }) });
        ui.begin(.{ .grow = 1, .width = .fill }, .{});
        kit.row(cx, shown, .{ .icon = icons.link, .subtitle = parts.items, .on = act(.{ .invite_copy = Id.of(code) }) });
        ui.end();
        kit.iconButton(cx, icons.trash, act(.{ .invite_revoke = Id.of(code) }), .{ .size = 36, .color = cx.c.danger });
        ui.end();
    }
}

fn stripScheme(link: []const u8) []const u8 {
    if (std.mem.indexOf(u8, link, "://")) |i| return link[i + 3 ..];
    return link;
}

fn edit(cx: Cx, c: *const data.Chat) void {
    const ui = cx.ui;
    const a = cx.a();
    const channel = c.is("channel");
    if (can(c, "changeInfo")) @import("profile.zig").editableAvatar(cx, .{ .name = cx.s.store.title(c), .color = c.o.i("color") orelse 0, .image = c.o.s("avatar"), .size = 110 }, .{ .chat = Id.of(c.id()) }, c.o.s("avatar") != null);
    if (can(c, "changeInfo")) {
        ui.begin(.{ .padding = .{ .start = 12, .end = 12, .top = 8 } }, .{});
        kit.field(cx, .info_title, .{ .label = if (channel) t("Channel name") else t("Group name") });
        kit.field(cx, .info_about, .{ .label = t("Description"), .multiline = true });
        kit.button(cx, t("Save"), act(.save_info), .{ .block = true });
        ui.end();
    }
    if (eq(c.role(), "owner") and !c.encrypted()) {
        kit.sectionTitle(cx, t("Public link"));
        kit.sectionNote(cx, if (c.o.s("username") != null) t("Anyone can find and join") else t("Only people with an invite link can join"));
        ui.begin(.{ .padding = .xy(12, 0) }, .{});
        kit.field(cx, .chat_username, .{ .placeholder = "my_group", .hint = t("Use 4-32 letters, numbers and underscores. Leave empty to make it private."), .submit = act(.save_username) });
        kit.button(cx, t("Save link"), act(.save_username), .{ .kind = .secondary, .small = true });
        ui.end();
    }
    if (c.is("group") and isAdmin(c)) {
        kit.sectionTitle(cx, t("What members can do"));
        for (vchat.default_perms, 0..) |p, i| {
            const on = if (j.field(c.o.v, "permissions")) |pv| (if (j.field(pv, p.key)) |v| (v == .bool and v.bool) else p.on) else p.on;
            kit.row(cx, t(group.perm_labels[i]), .{ .switch_on = on, .on = act(.{ .perm = @intCast(i) }), .k = key(.{ "perm", i }) });
        }
    }
    if (isAdmin(c)) {
        kit.sectionTitle(cx, t("Settings"));
        if (c.is("group")) {
            const slow = c.o.i("slowMode") orelse 0;
            kit.row(cx, t("Slow mode"), .{ .icon = icons.clock, .value = if (slow > 0) slowLabel(a, slow) else t("Off"), .on = .{ .menu = .{ .menu = .{ .kind = .slow_mode, .target = Id.of(c.id()) } } } });
            const hist = if (c.o.get("historyVisible")) |v| !(v == .bool and !v.bool) else true;
            kit.row(cx, t("Chat history for new members"), .{ .switch_on = hist, .subtitle = t("New members can read earlier messages"), .on = act(.{ .setting = .history }) });
        }
        if (channel) kit.row(cx, t("Sign messages"), .{ .switch_on = c.o.b("signMessages"), .subtitle = t("Show the admin's name on posts"), .on = act(.{ .setting = .sign }) });
        if (c.o.s("username") != null) kit.row(cx, t("Approve new members"), .{ .switch_on = c.o.b("joinApproval"), .on = act(.{ .setting = .approval }) });
        kit.row(cx, t("Restrict saving content"), .{ .switch_on = c.o.b("protectedContent"), .subtitle = t("Members cannot forward or copy messages"), .on = act(.{ .setting = .protected }) });
        const reactions = c.o.get("reactions");
        const rlabel = if (reactions == null or reactions.? == .null) t("All") else if (reactions.? == .array and reactions.?.array.items.len > 0) std.fmt.allocPrint(a, "{d}", .{reactions.?.array.items.len}) catch "" else t("Off");
        kit.row(cx, t("Reactions"), .{ .icon = icons.heart, .value = rlabel, .on = .{ .menu = .{ .menu = .{ .kind = .reactions_setting, .target = Id.of(c.id()) } } } });
        kit.row(cx, t("Administrators"), .{ .icon = icons.star, .chevron = true, .on = act(.{ .page = .admins }) });
        kit.row(cx, t("Banned users"), .{ .icon = icons.alertCircle, .chevron = true, .on = act(.{ .page = .banned }) });
        kit.row(cx, t("Invite links"), .{ .icon = icons.link, .chevron = true, .on = act(.{ .page = .invites }) });
    }
}

fn slowLabel(a: std.mem.Allocator, secs: i64) []const u8 {
    if (secs == 0) return t("Off");
    if (secs < 60) return std.fmt.allocPrint(a, "{d} {s}", .{ secs, t("s") }) catch "";
    if (secs < 3600) return std.fmt.allocPrint(a, "{d} {s}", .{ @divTrunc(secs, 60), t("min") }) catch "";
    return std.fmt.allocPrint(a, "1 {s}", .{t("h")}) catch "";
}

// ---------------------------------------------------------------------------------------------
// Sheets

pub fn memberMenu(cx: Cx, chat_id: Id, uid: Id) void {
    const s = cx.s;
    const c = s.store.chat(chat_id.str()) orelse return;
    const m = group.member(s, uid.str());
    const role = if (m) |mv| j.strOr(mv, "role", "") else "";
    const name = if (s.store.user(uid.str())) |u| s.store.userName(u) else "";
    views.sheet(cx, name);
    if (can(c, "addAdmins") and !eq(role, "admin")) views.menuItem(cx, icons.star, t("Make admin"), act(.{ .admin_rights = uid }), false);
    if (can(c, "addAdmins") and eq(role, "admin")) {
        views.menuItem(cx, icons.edit, t("Edit admin rights"), act(.{ .admin_rights = uid }), false);
        views.menuItem(cx, icons.minus, t("Dismiss admin"), act(.{ .dismiss_admin = uid }), false);
    }
    if (eq(c.role(), "owner") and eq(role, "admin")) views.menuItem(cx, icons.crown, t("Transfer ownership"), act(.{ .transfer = uid }), false);
    if (can(c, "banUsers")) {
        views.menuItem(cx, icons.logout, if (c.is("channel")) t("Remove from channel") else t("Remove from group"), act(.{ .remove = uid }), true);
        views.menuItem(cx, icons.alertCircle, t("Ban"), act(.{ .ban = uid }), true);
    }
    views.endSheet(cx);
}

pub fn adminRights(cx: Cx) void {
    const s = cx.s;
    const c = s.store.chat(s.info.str()) orelse return;
    views.sheet(cx, t("Admin rights"));
    cx.ui.begin(.{ .padding = .{ .start = 12, .end = 12, .top = 4 } }, .{});
    kit.field(cx, .admin_title, .{ .label = t("Custom title"), .placeholder = t("admin") });
    cx.ui.end();
    for (group.rights, 0..) |r, i| {
        if (r.channel_only and !c.is("channel")) continue;
        kit.row(cx, t(r.label), .{ .switch_on = s.group.admin_rights & (@as(u16, 1) << @intCast(i)) != 0, .on = act(.{ .right = @intCast(i) }), .k = key(.{ "right", i }) });
    }
    cx.ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .top = 8, .bottom = 8, .end = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, t("Save"), act(.save_admin), .{});
    cx.ui.end();
    views.endSheet(cx);
}

pub fn inviteNew(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const g = &s.group;
    views.sheet(cx, t("New invite link"));
    ui.begin(.{ .padding = .{ .start = 12, .end = 12, .top = 4 } }, .{});
    kit.field(cx, .invite_name, .{ .label = t("Name"), .placeholder = t("Link name (optional)") });
    ui.end();
    kit.sectionTitle(cx, t("Expires"));
    for (group.invite_expiry, 0..) |e, i| radio(cx, t(e.label), g.invite_expires == i, act(.{ .invite_expires = @intCast(i) }), key(.{ "exp", i }));
    kit.sectionTitle(cx, t("Limit"));
    for (group.invite_limits, 0..) |l, i| {
        const label = if (l == 0) t("No limit") else if (l == 1) t("1 person") else std.fmt.allocPrint(cx.a(), "{d}", .{l}) catch "";
        radio(cx, label, g.invite_limit == i, act(.{ .invite_limit = @intCast(i) }), key(.{ "lim", i }));
    }
    kit.row(cx, t("Request admin approval"), .{ .switch_on = g.invite_approval, .on = act(.invite_approval) });
    ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .top = 8, .bottom = 8, .end = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, t("Create"), act(.invite_create), .{});
    ui.end();
    views.endSheet(cx);
}

fn radio(cx: Cx, label: []const u8, on: bool, msg: Msg, k: u64) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 44, .padding = .xy(12, 4), .radius = theme.radius, .pressed_background = cx.c.active }, .{ .on_press = msg, .key = k });
    ui.begin(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .radius = 10, .border_width = if (on) 6 else 1.5, .border_color = if (on) cx.c.brand else cx.c.border_strong }, .{});
    ui.end();
    ui.text(label, .{ .font_size = 15, .color = cx.c.text });
    ui.end();
}

pub fn slowModeMenu(cx: Cx) void {
    views.sheet(cx, t("Slow mode"));
    for (group.slow_modes) |secs| views.menuItem(cx, icons.clock, slowLabel(cx.a(), secs), act(.{ .slow_mode = secs }), false);
    views.endSheet(cx);
}

pub fn reactionsMenu(cx: Cx) void {
    views.sheet(cx, t("Reactions"));
    views.menuItem(cx, icons.heart, t("All reactions"), act(.{ .reactions = .all }), false);
    views.menuItem(cx, icons.heart, t("Only the six quick reactions"), act(.{ .reactions = .quick }), false);
    views.menuItem(cx, icons.close, t("No reactions"), act(.{ .reactions = .none }), false);
    views.endSheet(cx);
}
