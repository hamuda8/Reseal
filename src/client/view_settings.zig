//! Settings (Reseal-js ui/settings.js): the profile, notifications, privacy and encryption
//! (advanced protection, passcode, recovery key, fingerprint), appearance, language, blocked
//! people; the people picker and new group / channel / saved chat forms; safety numbers.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const fmt = @import("fmt.zig");
const text = @import("text.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");
const vlist = @import("view_list.zig");
const keys = @import("keys.zig");
const crypto = @import("crypto.zig");

const Cx = kit.Cx;
const Msg = app.Msg;
const Id = app.Id;
const Color = zui.Color;
const t = zui.i18n.t;
const key = kit.key;

fn body(cx: Cx, k: []const u8) void {
    cx.ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 8, .end = 8, .bottom = 28 } }, key(.{ "pane", k }));
}

fn padded(cx: Cx, k: []const u8) void {
    cx.ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 16, .end = 16, .top = 4, .bottom = 28 } }, key(.{ "pane", k }));
}

pub fn settingsRoot(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const me = s.store.me orelse return;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, t("Settings"), false, true);
    vlist.endHeader(cx);
    body(cx, "settings");
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 14, .padding = .xy(12, 10), .radius = 18, .pressed_background = cx.c.active }, .{ .on_press = .{ .push_pane = .profile } });
    kit.avatar(cx, .{ .name = me.s("displayName") orelse "", .color = me.i("color") orelse 0, .image = me.s("avatar"), .size = 64 }, key(.{"set-av"}));
    ui.begin(.{ .grow = 1, .width = .fill, .gap = 2 }, .{});
    ui.text(me.s("displayName") orelse "", .{ .font_size = 19, .weight = 750, .color = cx.c.text, .max_lines = 1 });
    ui.text(if (me.s("username")) |u| std.fmt.allocPrint(cx.a(), "@{s}", .{u}) catch "" else t("No username yet"), .{ .font_size = 14, .color = cx.c.text_2 });
    ui.text(t("online"), .{ .font_size = 13, .color = cx.c.accent });
    ui.end();
    ui.end();
    kit.divider(cx);
    ui.begin(.{ .padding = .all(8) }, .{});
    kit.row(cx, t("My account"), .{ .icon = icons.user, .on = .{ .push_pane = .profile } });
    kit.row(cx, t("Notifications and sounds"), .{ .icon = icons.bell, .on = .{ .push_pane = .notifications } });
    kit.row(cx, t("Privacy and security"), .{ .icon = icons.lock, .on = .{ .push_pane = .privacy } });
    kit.row(cx, t("Appearance"), .{ .icon = icons.palette, .on = .{ .push_pane = .appearance } });
    kit.row(cx, t("Chat folders"), .{ .icon = icons.folder, .on = .{ .push_pane = .folders } });
    if (s.mode == .app) kit.row(cx, t("Glimpse archive"), .{ .icon = icons.archive, .on = .{ .stories = .archive } });
    if (s.mode == .app) kit.row(cx, t("AI assistants"), .{ .icon = icons.sparkles, .on = .{ .bots = .open_list } });
    if (s.mode == .app and !(if (s.store.me) |m| m.s("appId") != null else false)) kit.row(cx, t("Developers"), .{ .icon = icons.code, .on = .{ .dev = .open } });
    kit.row(cx, t("Language"), .{ .icon = icons.globe, .value = if (s.lang == .ar) "العربية" else "English", .on = .{ .push_pane = .language } });
    kit.row(cx, t("Reseal features"), .{ .icon = icons.help, .on = .{ .profile = .tour } });
    ui.end();
    kit.divider(cx);
    ui.begin(.{ .padding = .all(8) }, .{});
    kit.row(cx, t("Log out"), .{ .icon = icons.logout, .danger = true, .on = .{ .menu = .{ .confirm = .{ .kind = .logout } } } });
    ui.end();
    ui.begin(.{ .padding = .all(16), .align_items = .center }, .{});
    ui.text(std.fmt.allocPrint(cx.a(), "Reseal {s} · {s}", .{ if (s.store.config) |c| c.s("version") orelse "" else "", t("by Wufour") }) catch "", .{ .font_size = 13, .color = cx.c.text_2, .text_align = .center });
    ui.end();
    ui.end();
    ui.end();
}

pub fn pane(cx: Cx, p: app.Pane) void {
    switch (p) {
        .profile => profile(cx),
        .notifications => notifications(cx),
        .privacy => privacy(cx),
        .appearance => appearance(cx),
        .language => language(cx),
        .blocked => blocked(cx),
        .picker => |k| picker(cx, k),
        .group_details => |k| groupDetails(cx, k == .channel),
        .saved_edit => |id| savedEdit(cx, id),
        .folders => foldersPane(cx),
        .chat_lock => chatLockPane(cx),
        .bots => @import("bots.zig").listPane(cx),
        .bot_edit => @import("bots.zig").editPane(cx),
        .dev => @import("dev.zig").homePane(cx),
        .dev_app => @import("dev.zig").appPane(cx),
        .archive => {},
    }
}

fn profile(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const me = s.store.me orelse return;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, t("Edit profile"), true, false);
    vlist.endHeader(cx);
    padded(cx, "profile");
    @import("profile.zig").editableAvatar(cx, .{ .name = me.s("displayName") orelse "", .color = me.i("color") orelse 0, .image = me.s("avatar"), .size = 120 }, .me, me.s("avatar") != null);
    kit.field(cx, .profile_name, .{ .label = t("Name") });
    kit.field(cx, .profile_bio, .{ .multiline = true, .label = t("Bio"), .hint = t("Any details such as age, occupation or city.") });
    if (me.s("appId") == null) {
        ui.begin(.{ .padding = .{ .bottom = 0 } }, .{});
        kit.field(cx, .profile_username, .{ .label = t("Username"), .placeholder = "username" });
        ui.end();
        @import("profile.zig").usernameHint(cx);
    }
    kit.button(cx, t("Save"), .save_profile, .{ .block = true, .busy = s.busy });
    if (me.s("appId") == null) {
        ui.begin(.{ .padding = .{ .top = 24 } }, .{});
        kit.row(cx, t("Delete my account"), .{ .icon = icons.trash, .danger = true, .on = .{ .profile = .delete_account } });
        ui.end();
    }
    ui.end();
    ui.end();
}

fn chatLockPane(cx: Cx) void {
    const ui = cx.ui;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, t("Chat lock"), true, false);
    vlist.endHeader(cx);
    padded(cx, "chatlock");
    @import("chatlock.zig").pane(cx);
    ui.end();
    ui.end();
}

fn foldersPane(cx: Cx) void {
    const ui = cx.ui;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, t("Chat folders"), true, false);
    vlist.endHeader(cx);
    body(cx, "folders");
    @import("folders.zig").pane(cx);
    ui.end();
    ui.end();
}

fn notifications(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, t("Notifications and sounds"), true, false);
    vlist.endHeader(cx);
    body(cx, "notif");
    kit.sectionTitle(cx, t("Notifications"));
    kit.row(cx, if (zui.platform == .web and !cx.phone) t("Desktop notifications") else t("Notifications"), .{ .icon = icons.bell, .switch_on = s.prefs.notifications, .on = .{ .toggle_pref = .notifications } });
    kit.row(cx, t("Message preview"), .{ .icon = icons.eye, .subtitle = t("Show message text in notifications"), .switch_on = s.prefs.previews, .on = .{ .toggle_pref = .previews } });
    kit.row(cx, t("Sounds"), .{ .icon = icons.volume, .switch_on = s.prefs.sounds, .on = .{ .toggle_pref = .sounds } });
    kit.sectionNote(cx, t("Reseal notifies you of new messages while it is open in the background. Encrypted messages are decrypted on your device before being shown."));
    ui.end();
    ui.end();
}

const Rule = struct { key: app.PrivacyKey, title: []const u8, note: []const u8 };
const rules = [_]Rule{
    .{ .key = .lastSeen, .title = "Last seen & online", .note = "If you hide your last seen, you will not see other people's either." },
    .{ .key = .avatar, .title = "Profile photo", .note = "Who can see your profile photo." },
    .{ .key = .calls, .title = "Calls", .note = "Who can call you." },
    .{ .key = .groups, .title = "Groups", .note = "Who can add you to groups. Others can still send you an invite link." },
    .{ .key = .forwards, .title = "Forwarded messages", .note = "Whether forwarded messages link back to your account." },
};

fn ruleLabel(v: []const u8) []const u8 {
    if (std.mem.eql(u8, v, "contacts")) return t("My contacts");
    if (std.mem.eql(u8, v, "nobody")) return t("Nobody");
    return t("Everybody");
}

fn privacy(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const me = s.store.me orelse return;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, t("Privacy and security"), true, false);
    vlist.endHeader(cx);
    body(cx, "privacy");
    kit.sectionTitle(cx, t("Privacy"));
    for (rules) |r| {
        const cur = j.strOr(me.v, std.fmt.allocPrint(cx.a(), "privacy.{s}", .{@tagName(r.key)}) catch "", "everyone");
        // Each rule cycles Everybody → My contacts → Nobody.
        const next: app.PrivacyValue = if (std.mem.eql(u8, cur, "everyone")) .contacts else if (std.mem.eql(u8, cur, "contacts")) .nobody else .everyone;
        kit.row(cx, t(r.title), .{ .value = ruleLabel(cur), .subtitle = t(r.note), .on = .{ .set_privacy = .{ .key = r.key, .value = next } }, .k = key(.{ "rule", @intFromEnum(r.key) }) });
    }
    const receipts = j.field(me.v, "privacy.readReceipts") == null or j.truthy(me.v, "privacy.readReceipts");
    kit.row(cx, t("Read receipts"), .{ .subtitle = t("If off, you will not see read receipts from others either"), .switch_on = receipts, .on = .toggle_read_receipts });
    kit.row(cx, t("Blocked users"), .{ .chevron = true, .on = .{ .push_pane = .blocked } });
    if (s.mode == .app) kit.row(cx, t("Devices"), .{ .icon = icons.devices, .subtitle = t("Signed-in devices are managed by Wufour"), .on = .{ .profile = .devices } });
    kit.row(cx, t("Chat lock"), .{ .chevron = true, .on = .{ .push_pane = .chat_lock } });
    kit.divider(cx);
    protection(cx);
    kit.divider(cx);
    kit.sectionTitle(cx, t("Security"));
    kit.row(cx, t("Log out of this device"), .{ .icon = icons.logout, .danger = true, .on = .{ .menu = .{ .confirm = .{ .kind = .logout } } } });
    ui.end();
    ui.end();
}

/// Encryption: automatic (default) or advanced protection (a passcode).
fn protection(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const c = cx.c;
    const me = s.store.me orelse return;
    const advanced = std.mem.eql(u8, me.s("keyMode") orelse "", "advanced");
    kit.sectionTitle(cx, t("Encryption"));
    ui.begin(.{ .direction = .row, .gap = 14, .padding = .all(14), .radius = 18, .background = if (advanced) c.accent_soft else c.surface_2, .align_items = .start }, .{});
    ui.begin(.{ .width = .{ .px = 40 }, .height = .{ .px = 40 }, .radius = 13, .background = c.brand, .align_items = .center, .justify = .center }, .{});
    ui.icon(if (advanced) icons.key else icons.shieldCheck, 22, Color.white, .{}, 0);
    ui.end();
    ui.begin(.{ .grow = 1, .width = .fill, .gap = 4 }, .{});
    ui.text(if (advanced) t("Advanced protection is on") else t("Your chats are encrypted"), .{ .font_size = 15, .weight = 700, .color = c.text });
    ui.text(if (advanced) t("Your keys are locked with a passcode only you know. Reseal cannot restore them; you need the passcode or recovery key on new devices.") else t("Messages are encrypted on your devices. Your keys are backed up securely, so signing in on a new device just works. You will be told when that happens."), .{ .font_size = 13.5, .color = c.text_2, .line_height = 1.5 });
    ui.end();
    ui.end();
    if (advanced) {
        kit.row(cx, t("Change passcode"), .{ .icon = icons.key, .on = .{ .menu = .change_passcode } });
        kit.row(cx, t("New recovery key"), .{ .icon = icons.shield, .on = .{ .menu = .new_recovery } });
        kit.row(cx, t("Turn off advanced protection"), .{ .icon = icons.unlock, .subtitle = t("Go back to automatic key backup"), .on = .{ .menu = .disable_advanced } });
    } else kit.row(cx, t("Advanced protection"), .{ .icon = icons.lock, .subtitle = t("Lock your keys with a passcode only you know"), .on = .{ .menu = .enable_advanced } });
    kit.row(cx, t("My key fingerprint"), .{ .icon = icons.fingerprint, .on = .{ .menu = .fingerprint } });
}

fn appearance(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const c = cx.c;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, t("Appearance"), true, false);
    vlist.endHeader(cx);
    body(cx, "appearance");
    kit.sectionTitle(cx, t("Theme"));
    ui.begin(.{ .direction = .row, .gap = 10, .padding = .xy(12, 4) }, .{});
    const cards = [_]struct { th: app.Theme, label: []const u8, bg: Color, a: Color }{
        .{ .th = .light, .label = "Light", .bg = Color.hex("#e7ecf3"), .a = Color.white },
        .{ .th = .dark, .label = "Dark", .bg = Color.hex("#0b0e12"), .a = Color.hex("#1b2028") },
        .{ .th = .auto, .label = "System", .bg = Color.hex("#7d848f"), .a = Color.white },
    };
    for (cards) |card| {
        const on = s.prefs.theme == card.th;
        ui.begin(.{ .grow = 1, .width = .fill, .gap = 8, .align_items = .center }, .{ .on_press = .{ .set_theme = card.th }, .key = key(.{ "theme", @intFromEnum(card.th) }) });
        ui.begin(.{ .width = .fill, .height = .{ .px = 72 }, .radius = 14, .background = card.bg, .padding = .all(10), .gap = 6, .border_width = if (on) 2 else 1, .border_color = if (on) c.accent else c.border }, .{});
        ui.begin(.{ .width = .{ .px = 50 }, .height = .{ .px = 12 }, .radius = 6, .background = card.a }, .{});
        ui.end();
        ui.begin(.{ .width = .{ .px = 40 }, .height = .{ .px = 12 }, .radius = 6, .background = c.accent, .align_self = .end }, .{});
        ui.end();
        ui.end();
        ui.text(t(card.label), .{ .font_size = 13.5, .weight = 600, .color = if (on) c.accent else c.text_2 });
        ui.end();
    }
    ui.end();
    kit.sectionTitle(cx, t("Accent color"));
    ui.begin(.{ .direction = .row, .gap = 10, .padding = .xy(12, 4) }, .{});
    for (theme.accents, 0..) |ac, i| {
        const on = s.prefs.accent == i;
        ui.begin(.{ .width = .{ .px = 34 }, .height = .{ .px = 34 }, .radius = 17, .background = ac[0], .align_items = .center, .justify = .center, .border_width = if (on) 3 else 0, .border_color = c.surface }, .{ .on_press = .{ .set_accent = @intCast(i) }, .key = key(.{ "acc", i }) });
        if (on) ui.icon(icons.check, 18, Color.white, .{}, 0);
        ui.end();
    }
    ui.end();
    kit.sectionTitle(cx, t("Text size"));
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .padding = .xy(12, 4) }, .{});
    kit.iconButton(cx, icons.minus, .{ .set_font = -1 }, .{ .soft = true });
    ui.text(std.fmt.allocPrint(cx.a(), "{d}px", .{@as(u32, @intFromFloat(s.prefs.font))}) catch "", .{ .font_size = 15, .color = c.text, .grow = 1, .width = .fill, .text_align = .center });
    kit.iconButton(cx, icons.plus, .{ .set_font = 1 }, .{ .soft = true });
    ui.end();
    kit.sectionTitle(cx, t("Chats"));
    kit.row(cx, t("Message corners"), .{ .icon = icons.chat, .value = if (s.prefs.square_bubbles) t("Square") else t("Rounded"), .on = .{ .toggle_pref = .square_bubbles } });
    kit.row(cx, t("Send with Enter"), .{ .switch_on = s.prefs.send_with_enter, .on = .{ .toggle_pref = .send_with_enter } });
    kit.row(cx, t("Animations"), .{ .switch_on = s.prefs.animations, .on = .{ .toggle_pref = .animations } });
    kit.row(cx, t("Link previews"), .{ .switch_on = s.prefs.link_previews, .on = .{ .toggle_pref = .link_previews } });
    ui.end();
    ui.end();
}

fn language(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, t("Language"), true, false);
    vlist.endHeader(cx);
    body(cx, "lang");
    kit.row(cx, "English", .{ .subtitle = "English", .value = if (s.lang == .en) "✓" else null, .on = .{ .set_lang = .en } });
    kit.row(cx, "العربية", .{ .subtitle = "Arabic", .value = if (s.lang == .ar) "✓" else null, .on = .{ .set_lang = .ar } });
    ui.end();
    ui.end();
}

fn blocked(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, t("Blocked users"), true, false);
    vlist.endHeader(cx);
    body(cx, "blocked");
    kit.row(cx, t("Block someone"), .{ .icon = icons.plus, .on = .{ .push_pane = .{ .picker = .block } } });
    if (s.blocked) |b| {
        const list = j.arr(b.v, "users");
        for (list) |u| {
            const id = j.strOr(u, "id", "");
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .padding = .xy(12, 8) }, .{ .key = key(.{ "bl", id }) });
            kit.avatar(cx, .{ .name = j.strOr(u, "displayName", ""), .color = j.intOr(u, "color", 0), .image = j.str(u, "avatar"), .size = 42 }, 0);
            ui.text(j.strOr(u, "displayName", ""), .{ .font_size = 15, .weight = 550, .color = cx.c.text, .grow = 1, .width = .fill, .max_lines = 1 });
            kit.button(cx, t("Unblock"), .{ .menu = .{ .confirm = .{ .kind = .unblock, .target = Id.of(id) } } }, .{ .kind = .ghost, .small = true });
            ui.end();
        }
        if (list.len == 0) kit.emptyState(cx, icons.check, t("Nobody is blocked"), null);
    } else kit.spinner(cx);
    ui.end();
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// People picker, new group / channel, saved chats

fn picked(s: *const app.State, id: []const u8) bool {
    for (s.picked.items) |p| if (p.eql(id)) return true;
    return false;
}

fn picker(cx: Cx, kind: app.Picker) void {
    const ui = cx.ui;
    const s = cx.s;
    const c = cx.c;
    const multi = kind == .new_group or kind == .add_members;
    const title = switch (kind) {
        .new_message => t("New message"),
        .new_group, .add_members => t("Add members"),
        .add_contact => t("Add contact"),
        .block => t("Block user"),
    };
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, title, true, false);
    if (multi) kit.button(cx, if (kind == .new_group) t("Next") else t("Add"), .picker_done, .{ .small = true, .disabled = kind == .add_members and s.picked.items.len == 0 });
    vlist.endHeader(cx);
    ui.begin(.{ .padding = .{ .start = 14, .end = 14, .bottom = 8 }, .direction = .row }, .{});
    kit.searchBox(cx, .picker, t("Search people"));
    ui.end();
    if (multi and s.picked.items.len > 0) {
        ui.beginScroll(.{ .direction = .row, .gap = 6, .padding = .{ .start = 14, .end = 14, .bottom = 8 }, .height = .{ .px = 42 } }, key(.{"chips"}));
        for (s.picked.items) |p| {
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6, .height = .{ .px = 32 }, .padding = .{ .start = 4, .end = 10 }, .radius = 11, .background = c.accent_soft }, .{ .on_press = .{ .unpick_user = p }, .key = key(.{ "pk", p.str() }) });
            const u = s.store.user(p.str());
            kit.avatar(cx, .{ .name = if (u) |x| s.store.userName(x) else "?", .color = if (u) |x| x.i("color") orelse 0 else 0, .size = 24 }, 0);
            ui.text(if (u) |x| fmt.firstName(s.store.userName(x)) else "…", .{ .font_size = 14, .color = c.text });
            ui.icon(icons.close, 14, c.text_2, .{}, 0);
            ui.end();
        }
        ui.end();
    }
    body(cx, "picker");
    var seen = std.StringHashMap(void).init(cx.a());
    const q = std.mem.trim(u8, s.fields.get(.picker).get(), " ");
    if (s.picker_results != null and q.len >= 2) {
        for (j.arr(s.picker_results.?.v, "users")) |u| personRow(cx, u, multi, &seen);
    }
    if (s.contacts) |cts| {
        var first = true;
        for (j.arr(cts.v, "contacts")) |u| {
            const name = j.strOr(u, "displayName", "");
            if (q.len > 0 and std.ascii.findIgnoreCase(name, q) == null and std.ascii.findIgnoreCase(j.strOr(u, "username", ""), q) == null) continue;
            if (first) kit.sectionTitle(cx, t("Contacts"));
            first = false;
            personRow(cx, u, multi, &seen);
        }
    }
    if (seen.count() == 0) kit.emptyState(cx, icons.search, if (q.len > 0) t("Nobody found") else t("Find people"), t("Search by name or @username."));
    ui.end();
    ui.end();
}

fn personRow(cx: Cx, u: j.Value, multi: bool, seen: *std.StringHashMap(void)) void {
    const ui = cx.ui;
    const s = cx.s;
    const id = j.strOr(u, "id", "");
    if (id.len == 0 or seen.contains(id) or s.store.isMe(id)) return;
    seen.put(id, {}) catch {};
    const on = picked(s, id);
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 56, .padding = .xy(12, 6), .radius = theme.radius, .pressed_background = cx.c.active }, .{ .on_press = if (on) .{ .unpick_user = Id.of(id) } else .{ .pick_user = Id.of(id) }, .key = key(.{ "pp", id }) });
    kit.avatar(cx, .{ .name = j.strOr(u, "displayName", ""), .color = j.intOr(u, "color", 0), .image = j.str(u, "avatar"), .size = 44 }, 0);
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    ui.text(j.strOr(u, "displayName", ""), .{ .font_size = 15, .weight = 550, .color = cx.c.text, .max_lines = 1 });
    const sub = if (j.str(u, "username")) |un| std.fmt.allocPrint(cx.a(), "@{s}", .{un}) catch "" else text.presenceText(j.field(u, "presence"));
    ui.text(sub, .{ .font_size = 13, .color = cx.c.text_2, .max_lines = 1 });
    ui.end();
    if (multi) {
        ui.begin(.{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 8, .border_width = if (on) 0 else 1.5, .border_color = cx.c.border_strong, .background = if (on) cx.c.brand else null, .align_items = .center, .justify = .center }, .{});
        if (on) ui.icon(icons.check, 14, Color.white, .{}, 0);
        ui.end();
    }
    ui.end();
}

fn groupDetails(cx: Cx, channel: bool) void {
    const ui = cx.ui;
    const s = cx.s;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, if (channel) t("New channel") else t("New group"), true, false);
    vlist.endHeader(cx);
    padded(cx, "group");
    ui.begin(.{ .align_items = .center, .padding = .{ .top = 8, .bottom = 20 } }, .{});
    kit.avatar(cx, .{ .icon = if (channel) icons.megaphone else icons.users, .color = 2, .size = 120 }, 0);
    ui.end();
    kit.field(cx, .group_name, .{ .placeholder = if (channel) t("Channel name") else t("Group name") });
    kit.field(cx, .group_about, .{ .multiline = true, .placeholder = t("Description (optional)") });
    if (!channel) {
        kit.row(cx, t("End-to-end encrypted"), .{ .icon = icons.lock, .subtitle = t("Turn off for large public groups or to add AI assistants"), .switch_on = s.new_group_encrypted, .on = .toggle_encrypted });
        if (s.picked.items.len > 0) kit.sectionNote(cx, fmt.tn(cx.a(), @intCast(s.picked.items.len), "{n} member will be added", "{n} members will be added"));
    } else kit.sectionNote(cx, t("Channels broadcast to unlimited subscribers. They are not end-to-end encrypted."));
    ui.begin(.{ .padding = .{ .top = 12 } }, .{});
    kit.button(cx, t("Create"), .create_group, .{ .block = true, .busy = s.busy });
    ui.end();
    ui.end();
    ui.end();
}

fn savedEdit(cx: Cx, id: Id) void {
    const ui = cx.ui;
    const s = cx.s;
    const c = if (id.isSet()) s.store.chat(id.str()) else null;
    const primary = if (c) |cc| cc.o.b("primary") else false;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, if (c != null) t("Edit saved chat") else t("New saved chat"), true, false);
    vlist.endHeader(cx);
    padded(cx, "savededit");
    if (!primary) {
        kit.field(cx, .saved_title, .{ .label = t("Name"), .placeholder = t("For example: Work, Recipes, Ideas") });
    } else {
        // The default saved chat keeps its name (shown, not editable).
        ui.begin(.{ .gap = 6, .padding = .{ .bottom = 12 } }, .{});
        ui.text(t("Name"), .{ .font_size = 13.5, .weight = 650, .color = cx.c.text_2 });
        ui.begin(.{ .padding = .xy(14, 11), .radius = 14, .background = cx.c.surface_2, .opacity = 0.7 }, .{});
        ui.text(s.store.title(c.?), .{ .font_size = 15, .color = cx.c.text });
        ui.end();
        ui.text(t("Your default saved chat keeps its name."), .{ .font_size = 12.5, .color = cx.c.text_3 });
        ui.end();
    }
    kit.field(cx, .saved_about, .{ .multiline = true, .label = t("Purpose"), .placeholder = t("What will you keep here?"), .hint = t("Shown under the name, so you remember what goes here.") });
    kit.button(cx, if (c != null) t("Save") else t("Create"), .save_saved, .{ .block = true });
    ui.end();
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// Encryption sheets

pub fn passcodeForm(cx: Cx, m: app.Modal) void {
    const ui = cx.ui;
    const s = cx.s;
    const title, const note, const action = switch (m) {
        .enable_advanced => .{ t("Advanced protection"), t("With advanced protection, even Reseal cannot restore your keys. If you lose your passcode and recovery key, older messages cannot be recovered on new devices."), t("Turn on") },
        .disable_advanced => .{ t("Turn off advanced protection"), t("Enter your passcode. Your keys will be backed up automatically again, so new devices sign in without it."), t("Turn off") },
        .change_passcode => .{ t("Change passcode"), "", t("Change") },
        .new_recovery => .{ t("New recovery key"), t("Enter your passcode. Your old recovery key will stop working."), t("Continue") },
        else => return,
    };
    views.sheet(cx, title);
    ui.begin(.{ .padding = .xy(12, 6) }, .{});
    if (note.len > 0) {
        ui.begin(.{ .padding = .{ .bottom = 12 } }, .{});
        ui.text(note, .{ .font_size = 15, .color = cx.c.text_2, .line_height = 1.6 });
        ui.end();
    }
    switch (m) {
        .enable_advanced => {
            kit.field(cx, .passcode, .{ .label = t("Passcode"), .placeholder = t("New passcode") });
            kit.field(cx, .passcode_2, .{ .placeholder = t("Repeat the passcode") });
        },
        .change_passcode => {
            kit.field(cx, .passcode, .{ .label = t("Current passcode"), .placeholder = t("Current passcode") });
            kit.field(cx, .passcode_2, .{ .label = t("New passcode"), .placeholder = t("New passcode") });
            kit.field(cx, .passcode_3, .{ .placeholder = t("Repeat the new passcode") });
        },
        else => kit.field(cx, .passcode, .{ .label = t("Passcode"), .placeholder = t("Your passcode") }),
    }
    ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .bottom = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, action, .advanced_submit, .{ .busy = s.busy });
    ui.end();
    ui.end();
    views.endSheet(cx);
}

pub fn recoveryKey(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const c = cx.c;
    views.sheet(cx, t("Your recovery key"));
    ui.begin(.{ .padding = .xy(12, 6), .gap = 14 }, .{});
    ui.text(t("If you forget your passcode, this key is the only way to unlock your chats. Save it somewhere safe, like a password manager."), .{ .font_size = 15, .color = c.text_2, .line_height = 1.6 });
    ui.begin(.{ .padding = .all(16), .radius = 16, .background = c.surface_2, .align_items = .center }, .{});
    ui.text(s.recovery_shown.get(), .{ .font_size = 17, .weight = 700, .mono = true, .color = c.text, .text_align = .center, .line_height = 1.6 });
    ui.end();
    ui.begin(.{ .direction = .row, .gap = 8 }, .{});
    kit.button(cx, t("Copy"), .copy_recovery, .{ .kind = .secondary, .icon = icons.copy, .block = true });
    ui.end();
    kit.button(cx, t("I saved my recovery key"), .close_modal, .{ .block = true });
    ui.end();
    views.endSheet(cx);
}

pub fn fingerprint(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    views.sheet(cx, t("My key fingerprint"));
    ui.begin(.{ .padding = .xy(12, 6), .gap = 14 }, .{});
    ui.text(t("This fingerprint identifies your encryption keys. It changes only if you reset them."), .{ .font_size = 15, .color = cx.c.text_2, .line_height = 1.6 });
    if (keys.myPublic(s)) |p| {
        const fp = crypto.fingerprint(cx.a(), p.enc, p.sig) catch return;
        const hex = std.fmt.bytesToHex(fp[0..16].*, .upper);
        grid(cx, &hex, 4, 4);
    }
    ui.end();
    views.endSheet(cx);
}

/// Groups of characters in rows of `per_row` (fingerprints and safety numbers).
fn grid(cx: Cx, chars: []const u8, group: usize, per_row: usize) void {
    const ui = cx.ui;
    var i: usize = 0;
    ui.begin(.{ .gap = 8, .padding = .all(14), .radius = 16, .background = cx.c.surface_2, .align_items = .center }, .{});
    while (i < chars.len) {
        ui.begin(.{ .direction = .row, .gap = 14, .no_mirror = true }, .{});
        var n: usize = 0;
        while (n < per_row and i < chars.len) : (n += 1) {
            const end = @min(chars.len, i + group);
            ui.text(cx.a().dupe(u8, chars[i..end]) catch "", .{ .font_size = 17, .weight = 650, .mono = true, .color = cx.c.text });
            i = end;
        }
        ui.end();
    }
    ui.end();
}

/// The safety number two people compare (crypto.js safetyNumber).
pub fn safety(cx: Cx, user_id: []const u8) void {
    const ui = cx.ui;
    const s = cx.s;
    views.sheet(cx, t("Verify safety number"));
    ui.begin(.{ .padding = .xy(12, 6), .gap = 14 }, .{});
    const u = s.store.user(user_id);
    const mine = keys.myPublic(s);
    if (u != null and mine != null and u.?.s("keys.enc") != null) {
        const sn = crypto.safetyNumber(cx.a(), mine.?.enc, mine.?.sig, u.?.s("keys.enc").?, u.?.s("keys.sig") orelse "") catch return;
        ui.text(fmt.tf("Compare these numbers with {name}, in person or on a call. If they match, your chat is end-to-end encrypted with the right keys.", .{ .name = s.store.userName(u.?) }), .{ .font_size = 15, .color = cx.c.text_2, .line_height = 1.6 });
        var digits: std.ArrayList(u8) = .empty;
        for (sn.groups) |g| digits.appendSlice(cx.a(), &g) catch {};
        grid(cx, digits.items, 5, 4);
        var em: std.ArrayList(u8) = .empty;
        for (sn.emoji) |e| em.appendSlice(cx.a(), e) catch {};
        ui.begin(.{ .align_items = .center }, .{});
        ui.text(em.items, .{ .font_size = 28, .line_height = 1.3 });
        ui.end();
        @import("userinfo.zig").verifyRow(cx, u.?);
    } else ui.text(t("This person has not set up encryption yet."), .{ .font_size = 15, .color = cx.c.text_2 });
    ui.end();
    views.endSheet(cx);
}
