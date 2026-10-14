//! The info panel for Saved chats and for conversations with a team (Reseal-js info.js
//! savedInfo and teamInfo), and the panel's title for each kind of chat.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const icons = @import("icons.zig");
const kit = @import("ui.zig");
const fmt = @import("fmt.zig");
const vlist = @import("view_list.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const t = zui.i18n.t;
const tmp = app.tmp;
const key = kit.key;

pub const Counts = struct {
    chat: Id = .{},
    loaded: bool = false,
    visual: i64 = 0,
    files: i64 = 0,
};

/// Opening a saved chat's info asks for its counts.
pub fn opened(s: *State, c: *const data.Chat) void {
    if (!c.is("saved")) return;
    s.saved_counts = .{ .chat = Id.of(c.id()) };
    app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/{s}/media-counts", .{c.id()}) catch return, null, .media_counts);
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    switch (op) {
        .media_counts => {
            if (!r.ok()) return true;
            const v = j.parse(tmp(), r.body);
            const n = struct {
                fn of(x: ?j.Value, k: []const u8) i64 {
                    return j.intOr(j.obj(x, "counts"), k, 0);
                }
            }.of;
            s.saved_counts.visual = n(v, "photo") + n(v, "video") + n(v, "gif");
            s.saved_counts.files = n(v, "file") + n(v, "audio") + n(v, "voice");
            s.saved_counts.loaded = true;
        },
        else => return false,
    }
    return true;
}

/// The panel's title (infoPane titles in info.js).
pub fn title(s: *const State, c: *const data.Chat) []const u8 {
    if (c.is("saved")) return if (c.o.b("primary")) t("About Saved") else t("Saved chat info");
    if (c.isTeamChat() and !s.store.isTeamStaff(c)) return fmt.tf("About {name}", .{ .name = j.strOr(c.o.v, "team.name", "") });
    if (c.is("bot")) return t("Bot info");
    if (c.is("private") or c.isTeamChat()) return t("User info");
    return t("Info");
}

fn head(cx: Cx, c: *const data.Chat, name: []const u8, status: []const u8) void {
    const ui = cx.ui;
    ui.begin(.{ .align_items = .center, .gap = 6, .padding = .{ .top = 12, .bottom = 14 } }, .{});
    vlist.chatAvatar(cx, c, 96);
    ui.text(name, .{ .font_size = 22, .weight = 800, .color = cx.c.text, .text_align = .center });
    ui.text(status, .{ .font_size = 14, .color = cx.c.text_2, .text_align = .center });
    ui.end();
}

fn stat(cx: Cx, n: ?i64, label: []const u8) void {
    const ui = cx.ui;
    ui.begin(.{ .grow = 1, .width = .fill, .align_items = .center, .gap = 2, .padding = .xy(8, 10), .radius = 14, .background = cx.c.surface_2 }, .{ .key = key(.{ "stat", label }) });
    ui.text(if (n) |x| fmt.number(cx.a(), x) else "…", .{ .font_size = 18, .weight = 800, .color = cx.c.text });
    ui.text(label, .{ .font_size = 12.5, .color = cx.c.text_2 });
    ui.end();
}

pub fn savedBody(cx: Cx, c: *const data.Chat) void {
    const s = cx.s;
    const ui = cx.ui;
    head(cx, c, s.store.title(c), t("Only you can see this. Encrypted on your devices."));
    if (c.o.s("about")) |about| if (about.len > 0) kit.row(cx, about, .{ .icon = icons.info, .subtitle = t("Purpose") });
    kit.row(cx, t("Edit"), .{ .icon = icons.edit, .chevron = true, .on = .{ .chat_action = .{ .what = .saved_edit, .chat = Id.of(c.id()) } } });
    const counts = if (s.saved_counts.loaded and s.saved_counts.chat.eql(c.id())) s.saved_counts else null;
    ui.begin(.{ .direction = .row, .gap = 8, .padding = .xy(8, 8) }, .{});
    stat(cx, c.seq(), t("items"));
    stat(cx, if (counts) |x| x.visual else null, t("photos & videos"));
    stat(cx, if (counts) |x| x.files else null, t("files"));
    ui.end();
    @import("sharedmedia.zig").section(cx, c);
    ui.begin(.{ .padding = .{ .top = 12 } }, .{});
    if (s.mode == .app) kit.row(cx, t("Export chat"), .{ .icon = icons.download, .on = .{ .chat_action = .{ .what = .export_chat, .chat = Id.of(c.id()) } } });
    if (!c.o.b("primary")) kit.row(cx, t("Delete saved chat"), .{ .icon = icons.trash, .danger = true, .on = .{ .chat_action = .{ .what = .delete, .chat = Id.of(c.id()) } } });
    ui.end();
}

/// What a customer sees about the team they talk to: never the roster.
pub fn teamBody(cx: Cx, c: *const data.Chat) void {
    const s = cx.s;
    const ui = cx.ui;
    const about = j.strOr(c.o.v, "team.about", "");
    head(cx, c, j.strOr(c.o.v, "team.name", s.store.title(c)), if (about.len > 0) about else t("Your messages reach the whole team"));
    const muted = c.isMuted();
    ui.begin(.{ .direction = .row, .justify = .center, .padding = .{ .bottom = 10 } }, .{});
    ui.begin(.{ .align_items = .center, .gap = 4, .min_width = 76, .padding = .xy(10, 8), .radius = 14, .background = cx.c.surface_2, .pressed_background = cx.c.active }, .{ .on_press = .{ .chat_action = .{ .what = if (muted) .unmute else .mute, .chat = Id.of(c.id()) } }, .key = key(.{"team-mute"}) });
    ui.icon(if (muted) icons.bell else icons.bellOff, 21, cx.c.accent, .{}, 0);
    ui.text(if (muted) t("Unmute") else t("Mute"), .{ .font_size = 12.5, .weight = 600, .color = cx.c.text, .max_lines = 1 });
    ui.end();
    ui.end();
    if (c.encrypted()) kit.row(cx, t("Messages are end-to-end encrypted"), .{ .icon = icons.shieldCheck, .subtitle = t("Encryption") }) else kit.row(cx, t("Messages are stored encrypted on the server, not end-to-end"), .{ .icon = icons.globe, .subtitle = t("Encryption") });
    if (c.o.s("externalId") != null) if (j.obj(c.o.v, "metadata")) |md| if (j.field(md, "orderId")) |o| {
        const order = switch (o) {
            .string => |x| x,
            .integer => |x| std.fmt.allocPrint(cx.a(), "{d}", .{x}) catch "",
            else => "",
        };
        if (order.len > 0) kit.row(cx, order, .{ .icon = icons.file, .subtitle = t("Order") });
    };
    @import("sharedmedia.zig").section(cx, c);
    ui.begin(.{ .padding = .{ .top = 12 } }, .{});
    if (s.mode == .app) kit.row(cx, t("Export chat"), .{ .icon = icons.download, .on = .{ .chat_action = .{ .what = .export_chat, .chat = Id.of(c.id()) } } });
    kit.row(cx, t("Delete chat"), .{ .icon = icons.trash, .danger = true, .on = .{ .chat_action = .{ .what = .delete, .chat = Id.of(c.id()) } } });
    ui.end();
}
