//! A person's or a bot's info (Reseal-js info.js fillUser): Message, Call, Video and Mute at the
//! top, the username (copied with a tap), bio, AI model, the safety number with "Mark as
//! verified", groups in common, shared media, contacts, export, block and delete.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const icons = @import("icons.zig");
const kit = @import("ui.zig");
const fmt = @import("fmt.zig");
const text = @import("text.zig");
const views = @import("views.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const t = zui.i18n.t;
const tmp = app.tmp;
const key = kit.key;

pub const Act = union(enum) {
    copy_username: Id,
    contact: struct { user: Id, add: bool },
    common: Id,
    verify: Id,
    open_chat: Id,
};

fn msgOf(a: Act) Msg {
    return .{ .user_info = a };
}

pub fn act(s: *State, a: Act) void {
    switch (a) {
        .copy_username => |uid| if (s.store.user(uid.str())) |u| {
            app.fx.copy(std.fmt.allocPrint(tmp(), "@{s}", .{u.s("username") orelse ""}) catch return);
            app.toast(s, t("Username copied"));
        },
        .contact => |x| {
            if (x.add) {
                app.api(s, .POST, "/contacts", std.fmt.allocPrint(tmp(), "{{\"userId\":\"{s}\"}}", .{x.user.str()}) catch return, .contact_add);
            } else app.api(s, .DELETE, std.fmt.allocPrint(tmp(), "/contacts/{s}", .{x.user.str()}) catch return, null, .contact_remove);
            if (s.store.user(x.user.str())) |u| {
                u.set("inContacts", data.boolean(x.add)) catch {};
                u.set("isContact", data.boolean(x.add)) catch {};
            }
        },
        .common => |uid| {
            if (s.common) |c| c.destroy();
            s.common = null;
            s.modal = .common_groups;
            app.api(s, .GET, std.fmt.allocPrint(tmp(), "/users/{s}/common-groups", .{uid.str()}) catch return, null, .common_groups);
        },
        .verify => |uid| {
            const u = s.store.user(uid.str()) orelse return;
            const on = !isVerified(s, u);
            markVerified(s, u, on);
            app.toast(s, if (on) t("Marked as verified") else t("Verification removed"));
        },
        .open_chat => |cid| {
            s.modal = null;
            views.openChat(s, cid.str());
        },
    }
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    switch (op) {
        .common_groups => {
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            if (j.parse(tmp(), r.body)) |v| s.common = data.Obj.create(v) catch null;
        },
        else => return false,
    }
    return true;
}

// Trust on first use (e2ee.js knownKeys): "verified" holds while their keys stay the same.

fn knownKey(s: *const State, uid: []const u8) []const u8 {
    return std.fmt.allocPrint(tmp(), "known:{s}:{s}", .{ s.store.myId(), uid }) catch "";
}

pub fn isVerified(s: *const State, u: *const data.Obj) bool {
    const enc = u.s("keys.enc") orelse return false;
    const raw = zui.storage.get(tmp(), knownKey(s, u.s("id") orelse ""), .{}) orelse return false;
    var it = std.mem.splitScalar(u8, raw, '|');
    const known = it.next() orelse return false;
    _ = it.next();
    return std.mem.eql(u8, known, enc) and std.mem.eql(u8, it.next() orelse "", "1");
}

fn markVerified(s: *State, u: *const data.Obj, on: bool) void {
    const v = std.fmt.allocPrint(tmp(), "{s}|{s}|{s}", .{ u.s("keys.enc") orelse "", u.s("keys.sig") orelse "", if (on) "1" else "0" }) catch return;
    zui.storage.set(knownKey(s, u.s("id") orelse ""), v, .{});
}

/// The "Mark as verified" switch under a safety number.
pub fn verifyRow(cx: Cx, u: *const data.Obj) void {
    kit.row(cx, t("Mark as verified"), .{ .icon = icons.check, .subtitle = t("You will be warned if their keys ever change."), .switch_on = isVerified(cx.s, u), .on = msgOf(.{ .verify = Id.of(u.s("id") orelse "") }) });
}

fn quick(cx: Cx, ic: zui.Icon, label: []const u8, msg: Msg) void {
    const ui = cx.ui;
    ui.begin(.{ .align_items = .center, .gap = 4, .min_width = 72, .padding = .xy(10, 8), .radius = 14, .background = cx.c.surface_2, .pressed_background = cx.c.active }, .{ .on_press = msg, .key = key(.{ "uq", label }) });
    ui.icon(ic, 21, cx.c.accent, .{}, 0);
    ui.text(label, .{ .font_size = 12.5, .weight = 600, .color = cx.c.text, .max_lines = 1 });
    ui.end();
}

pub fn card(cx: Cx, u: *const data.Obj, c: ?*const data.Chat) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    const a = cx.a();
    const uid = u.s("id") orelse "";
    const me = s.store.isMe(uid);
    const bot = u.b("isBot") or (c != null and c.?.is("bot"));
    ui.begin(.{ .align_items = .center, .gap = 6, .padding = .{ .top = 12, .bottom = 14 } }, .{});
    kit.avatar(cx, .{ .name = s.store.userName(u), .color = u.i("color") orelse 0, .image = u.s("avatar"), .image_url = u.s("avatarUrl"), .size = 96 }, key(.{ "uc", uid }));
    ui.text(s.store.userName(u), .{ .font_size = 22, .weight = 800, .color = col.text, .text_align = .center });
    const status = if (u.b("deleted")) t("deleted account") else if (bot) (if (u.s("bot.model")) |model| std.fmt.allocPrint(a, "{s} · {s}", .{ t("AI assistant"), model }) catch "" else t("bot")) else text.presenceText(u.get("presence"));
    ui.text(status, .{ .font_size = 14, .color = col.text_2, .text_align = .center });
    ui.end();

    if (!me and !u.b("deleted")) {
        ui.begin(.{ .direction = .row, .justify = .center, .gap = 8, .padding = .{ .bottom = 10 } }, .{});
        quick(cx, icons.chat, t("Message"), if (c) |ch| msgOf(.{ .open_chat = Id.of(ch.id()) }) else .{ .start_global = Id.of(uid) });
        if (c) |ch| if (!bot and @import("view_chat.zig").feature(s, "calls")) {
            quick(cx, icons.phone, t("Call"), .{ .chat_action = .{ .what = .call_voice, .chat = Id.of(ch.id()) } });
            if (@import("view_chat.zig").feature(s, "video")) quick(cx, icons.video, t("Video"), .{ .chat_action = .{ .what = .call_video, .chat = Id.of(ch.id()) } });
        };
        if (c) |ch| {
            const muted = ch.isMuted();
            quick(cx, if (muted) icons.bell else icons.bellOff, if (muted) t("Unmute") else t("Mute"), .{ .chat_action = .{ .what = if (muted) .unmute else .mute, .chat = Id.of(ch.id()) } });
        }
        ui.end();
    }

    if (u.s("username")) |un| kit.row(cx, std.fmt.allocPrint(a, "@{s}", .{un}) catch "", .{ .icon = icons.at, .subtitle = t("Username"), .on = msgOf(.{ .copy_username = Id.of(uid) }) });
    if (u.s("bio")) |bio| if (bio.len > 0) kit.row(cx, bio, .{ .icon = icons.info, .subtitle = if (bot) t("Description") else t("Bio") });
    if (bot) if (u.s("bot.model")) |model| kit.row(cx, model, .{ .icon = icons.sparkles, .subtitle = t("AI model") });
    if (!me and !bot and u.get("keys") != null) {
        const verified = isVerified(s, u);
        kit.row(cx, t("View safety number"), .{ .icon = icons.shieldCheck, .subtitle = t("End-to-end encryption"), .value = if (verified) t("Verified") else null, .chevron = true, .on = .{ .menu = .{ .safety = Id.of(uid) } } });
    }
    // Glimpses kept on the profile (mine: also the archive).
    if (s.mode == .app and !bot and !u.b("blocked")) kit.row(cx, t("Glimpses"), .{ .icon = icons.image, .chevron = true, .on = if (me) .{ .stories = .archive } else .{ .stories = .{ .pinned_of = Id.of(uid) } } });
    const common = u.i("commonGroups") orelse 0;
    if (common > 0) kit.row(cx, fmt.tn(a, common, "{n} group in common", "{n} groups in common"), .{ .icon = icons.users, .chevron = true, .on = msgOf(.{ .common = Id.of(uid) }) });
    if (c) |ch| @import("sharedmedia.zig").section(cx, ch);

    if (me) return;
    ui.begin(.{ .padding = .{ .top = 12 } }, .{});
    if (!bot and s.mode == .app) {
        const in = u.b("inContacts") or u.b("isContact");
        kit.row(cx, if (in) t("Remove from contacts") else t("Add to contacts"), .{ .icon = if (in) icons.contacts else icons.userPlus, .on = msgOf(.{ .contact = .{ .user = Id.of(uid), .add = !in } }) });
    }
    if (c) |ch| {
        if (s.mode == .app and !ch.o.b("protectedContent")) kit.row(cx, t("Export chat"), .{ .icon = icons.download, .on = .{ .chat_action = .{ .what = .export_chat, .chat = Id.of(ch.id()) } } });
        if (!bot) kit.row(cx, if (u.b("blocked")) t("Unblock user") else t("Block user"), .{ .icon = icons.alertCircle, .danger = !u.b("blocked"), .on = .{ .chat_action = .{ .what = if (u.b("blocked")) .unblock else .block, .chat = Id.of(ch.id()) } } });
        kit.row(cx, t("More actions"), .{ .icon = icons.more, .on = .{ .menu = .{ .menu = .{ .kind = .chat_row, .target = Id.of(ch.id()) } } } });
        kit.row(cx, t("Delete chat"), .{ .icon = icons.trash, .danger = true, .on = .{ .chat_action = .{ .what = .delete, .chat = Id.of(ch.id()) } } });
    } else if (!s.store.isMe(uid)) {
        kit.row(cx, t("Send message"), .{ .icon = icons.chat, .on = .{ .start_global = Id.of(uid) } });
    }
    ui.end();
}

pub fn commonSheet(cx: Cx) void {
    const s = cx.s;
    views.sheet(cx, t("Groups in common"));
    if (s.common) |o| {
        for (j.arr(o.v, "chats")) |c| {
            const id = j.strOr(c, "id", "");
            const n = j.intOr(c, "memberCount", 0);
            cx.ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 56, .padding = .xy(12, 4), .radius = 12, .pressed_background = cx.c.active }, .{ .on_press = msgOf(.{ .open_chat = Id.of(id) }), .key = key(.{ "cg", id }) });
            kit.avatar(cx, .{ .name = j.strOr(c, "title", ""), .color = j.intOr(c, "color", 0), .image = j.str(c, "avatar"), .size = 42 }, key(.{ "cga", id }));
            cx.ui.begin(.{ .grow = 1, .width = .fill }, .{});
            cx.ui.text(j.strOr(c, "title", ""), .{ .font_size = 15, .weight = 600, .color = cx.c.text, .max_lines = 1 });
            cx.ui.text(fmt.tn(cx.a(), n, "{n} member", "{n} members"), .{ .font_size = 13, .color = cx.c.text_2 });
            cx.ui.end();
            cx.ui.end();
        }
    } else kit.spinner(cx);
    views.endSheet(cx);
}
