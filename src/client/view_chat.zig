//! The open chat (Reseal-js ui/chatview.js, ui/message.js, ui/composer.js): header with status
//! and typing, pinned bar, the message list, the composer; the menus (message actions, chat,
//! compose, mute), the info panel (ui/info.js) and the media viewer.
//!
//! The message list is a scroll view anchored at its end (zui beginScrollWith anchor_end): it
//! opens at the newest message, stays there as messages arrive, keeps its place when older ones
//! load above, and asks for more when scrolled to the top.

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
const vcompose = @import("view_compose.zig");
const markdown = @import("markdown.zig");
const rich = @import("rich.zig");
const vgroup = @import("view_group.zig");
const vlist = @import("view_list.zig");
const media = @import("media.zig");
const calls = @import("calls.zig");

const Cx = kit.Cx;
const Msg = app.Msg;
const Id = app.Id;
const Color = zui.Color;
const t = zui.i18n.t;
const key = kit.key;

/// What members can do by default in a group (Reseal-js ui/perm.js DEFAULT_PERMS).
pub const default_perms = [_]struct { key: []const u8, on: bool }{
    .{ .key = "sendMessages", .on = true },
    .{ .key = "sendMedia", .on = true },
    .{ .key = "sendVoice", .on = true },
    .{ .key = "sendPolls", .on = true },
    .{ .key = "sendLinks", .on = true },
    .{ .key = "addMembers", .on = true },
    .{ .key = "pinMessages", .on = false },
    .{ .key = "changeInfo", .on = false },
};

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

/// The client's mirror of the server's permission rules (ui/perm.js can), only to show or hide
/// controls.
pub fn can(c: *const data.Chat, action: []const u8) bool {
    const me = c.me() orelse return false;
    if (!j.eqlStr(me, "status", "active")) return false;
    if (c.is("private") or c.is("saved") or c.is("bot")) {
        for ([_][]const u8{ "addMembers", "banUsers", "addAdmins", "changeInfo", "inviteUsers" }) |x| if (eq(x, action)) return false;
        return true;
    }
    const role = c.role();
    if (eq(role, "owner")) return true;
    if (c.is("support")) {
        if (eq(role, "admin")) return true;
        for ([_][]const u8{ "sendMessages", "sendMedia", "sendVoice", "sendLinks", "sendPolls" }) |x| if (eq(x, action)) return true;
        return false;
    }
    if (eq(role, "admin")) {
        if (c.is("group")) for (default_perms) |p| if (eq(p.key, action)) return true;
        if (c.is("channel") and std.mem.startsWith(u8, action, "send")) return if (j.field(me, "rights.postMessages")) |v| !(v == .bool and !v.bool) else true;
        if (j.field(me, "rights")) |r| if (j.field(r, action)) |v| if (v == .bool) return v.bool;
        return !eq(action, "addAdmins");
    }
    if (c.is("channel")) return false;
    if (j.field(c.o.v, "permissions")) |p| if (j.field(p, action)) |v| if (v == .bool) return v.bool;
    for (default_perms) |p| if (eq(p.key, action)) return p.on;
    return false;
}

pub fn isAdmin(c: *const data.Chat) bool {
    return std.mem.eql(u8, c.role(), "owner") or std.mem.eql(u8, c.role(), "admin");
}

fn canCall(c: *const data.Chat) bool {
    return c.is("private") or c.is("group") or (c.is("channel") and isAdmin(c));
}

pub fn feature(s: *const app.State, name: []const u8) bool {
    if (s.mode != .embed) return true;
    const a = s.embed.app orelse return true;
    const f = j.field(a.v, "features") orelse return true;
    const v = j.field(f, name) orelse return true;
    return !(v == .bool and !v.bool);
}

// ---------------------------------------------------------------------------------------------
// The chat view

pub fn chatView(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const c = s.store.chat(s.open_chat.str()) orelse {
        ui.begin(.{ .width = .fill, .height = .fill, .justify = .center }, .{});
        kit.spinner(cx);
        ui.end();
        return;
    };
    ui.begin(.{ .width = .fill, .height = .fill, .background = cx.c.surface }, .{});
    header(cx, c);
    topBars(cx, c);
    messages(cx, c);
    composer(cx, c);
    @import("voice.zig").roundPreview(cx);
    ui.end();
}

/// Selection mode: how many, and what to do with them.
fn selectionBar(cx: Cx, c: *const data.Chat) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .height = .{ .px = theme.header_h }, .padding = .{ .start = if (cx.phone) 6 else 16, .end = 12 }, .background = col.surface }, .{ .key = zui.key("selection-bar") });
    kit.iconButton(cx, icons.close, .select_cancel, .{});
    ui.text(fmt.tn(cx.a(), @intCast(s.selected.items.len), "{n} selected", "{n} selected"), .{ .font_size = 16, .weight = 700, .color = col.text, .grow = 1, .width = .fill, .max_lines = 1 });
    const soft = if (cx.phone) null else col.surface_2;
    kit.iconButton(cx, icons.copy, .select_copy, .{ .background = soft });
    if (!c.o.b("protectedContent") and feature(s, "forwarding")) kit.iconButton(cx, icons.forward, .select_forward, .{ .background = soft });
    kit.iconButton(cx, icons.trash, .select_delete, .{ .background = soft, .color = col.danger });
    ui.end();
    kit.divider(cx);
}

fn header(cx: Cx, c: *const data.Chat) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    if (s.selecting) return selectionBar(cx, c);
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .height = .{ .px = theme.header_h }, .padding = .{ .start = if (cx.phone) 6 else 16, .end = 12 }, .background = col.surface }, .{});
    if (cx.phone) kit.iconButton(cx, icons.back, .close_chat, .{ .rtl = icons.back_rtl });
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .grow = 1, .width = .fill, .padding = .xy(8, 5), .radius = 14, .pressed_background = col.hover }, .{ .on_press = .{ .open_info = Id.of(c.id()) } });
    vlist.chatAvatar(cx, c, 42);
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6 }, .{});
    ui.text(s.store.title(c), .{ .font_size = 16, .weight = 700, .color = col.text, .max_lines = 1 });
    if (c.encrypted() and !c.is("saved")) ui.icon(icons.lockSmall, 15, col.success, .{}, 0);
    if (c.is("bot")) ui.icon(icons.sparkles, 14, col.text_2, .{}, 0);
    ui.end();
    const st = status(cx, c);
    ui.text(st.text, .{ .font_size = 13, .weight = if (st.accent) 550 else 400, .color = if (st.accent) col.accent else col.text_2, .max_lines = 1 });
    ui.end();
    ui.end();
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 4 }, .{});
    const peer = s.store.peer(c);
    const soft = if (cx.phone) null else col.surface_2;
    if (feature(s, "calls") and canCall(c) and !(peer != null and peer.?.b("deleted"))) {
        if (c.is("private")) {
            kit.iconButton(cx, icons.phone, .{ .call = .{ .start = .{ .chat = Id.of(c.id()), .video = false } } }, .{ .background = soft });
            if (feature(s, "video")) kit.iconButton(cx, icons.video, .{ .call = .{ .start = .{ .chat = Id.of(c.id()), .video = true } } }, .{ .background = soft });
        } else kit.iconButton(cx, icons.phone, .{ .call = .{ .start = .{ .chat = Id.of(c.id()), .video = false } } }, .{ .background = soft });
    }
    // Phones: search is in the menu (the title needs the room).
    if (!cx.phone) kit.iconButton(cx, icons.search, .{ .chat_action = .{ .what = .search, .chat = Id.of(c.id()) } }, .{ .background = soft });
    kit.iconButton(cx, icons.more, .{ .menu = .{ .menu = .{ .kind = .chat_header, .target = Id.of(c.id()) } } }, .{ .background = soft });
    ui.end();
    ui.end();
    kit.divider(cx);
}

fn nonEmpty(x: ?[]const u8) ?[]const u8 {
    const v = x orelse return null;
    return if (v.len == 0) null else v;
}

const Status = struct { text: []const u8, accent: bool = false };

fn status(cx: Cx, c: *const data.Chat) Status {
    const s = cx.s;
    const a = cx.a();
    const typing = text.typingText(s, c);
    if (typing.len > 0) return .{ .text = typing, .accent = true };
    if (c.isTeamChat()) {
        if (s.store.isTeamStaff(c)) {
            const u = s.store.user(j.strOr(c.o.v, "visitor.id", ""));
            const p = if (u) |x| text.presenceText(x.get("presence")) else "";
            return .{ .text = std.fmt.allocPrint(a, "{s}{s}{s}", .{ p, if (p.len > 0) " · " else "", j.strOr(c.o.v, "team.name", "") }) catch "", .accent = std.mem.eql(u8, p, t("online")) };
        }
        const online = if (s.members) |m| j.intOr(m.v, "online", 0) else 0;
        if (online > 1) return .{ .text = t("online"), .accent = true };
        return .{ .text = nonEmpty(j.str(c.o.v, "team.about")) orelse t("Your messages reach the whole team") };
    }
    if (c.is("private")) {
        const p = s.store.peer(c) orelse return .{ .text = "" };
        if (p.b("deleted")) return .{ .text = t("deleted account") };
        const tx = text.presenceText(p.get("presence"));
        return .{ .text = tx, .accent = std.mem.eql(u8, p.s("presence.status") orelse "", "online") };
    }
    if (c.is("bot")) {
        const p = s.store.peer(c);
        if (p) |x| if (x.s("bot.model")) |model| return .{ .text = std.fmt.allocPrint(a, "{s} · {s}", .{ t("AI assistant"), model }) catch "" };
        return .{ .text = t("bot") };
    }
    if (c.is("channel")) return .{ .text = fmt.tn(a, c.o.i("memberCount") orelse 0, "{n} subscriber", "{n} subscribers") };
    if (c.is("group") or c.is("support")) {
        var tx = fmt.tn(a, c.o.i("memberCount") orelse 0, "{n} member", "{n} members");
        if (s.members) |m| if (s.members_chat.eql(c.id())) {
            const online = j.intOr(m.v, "online", 0);
            if (online > 1) tx = std.fmt.allocPrint(a, "{s}, {s}", .{ tx, fmt.tf("{n} online", .{ .n = online }) }) catch tx;
        };
        return .{ .text = tx };
    }
    if (c.is("saved")) return .{ .text = nonEmpty(c.o.s("about")) orelse t("Notes, links and files · only you") };
    return .{ .text = "" };
}

fn topBars(cx: Cx, c: *const data.Chat) void {
    const ui = cx.ui;
    const col = cx.c;
    const s = cx.s;
    const call = j.obj(c.o.v, "call");
    const pinned = j.arr(c.o.v, "pinned");
    const bot = c.is("bot");
    if (call == null and pinned.len == 0 and !bot) return;
    ui.begin(.{ .gap = 8, .padding = .{ .start = 14, .end = 14, .top = 8 } }, .{});
    if (call) |cl| {
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .min_height = 50, .padding = .{ .start = 14, .end = 10, .top = 7, .bottom = 7 }, .radius = 16, .background = col.surface_2 }, .{});
        ui.icon(icons.phone, 18, col.success, .{}, 0);
        ui.text(std.fmt.allocPrint(cx.a(), "{s} · {s}", .{ if (j.truthy(cl, "video")) t("Video chat") else t("Voice chat"), fmt.tn(cx.a(), j.intOr(cl, "count", 0), "{n} participant", "{n} participants") }) catch "", .{ .font_size = 14, .weight = 650, .color = col.success, .grow = 1, .width = .fill });
        kit.button(cx, t("Join"), .{ .call = .{ .join = Id.of(c.id()) } }, .{ .small = true });
        ui.end();
    }
    if (pinned.len > 0) {
        // One pin at a time; a tap shows it and moves on to the next (pinnedBar).
        const idx: usize = if (s.extras.pin_index < pinned.len) s.extras.pin_index else 0;
        const pid = if (pinned[idx] == .string) pinned[idx].string else "";
        var line: []const u8 = t("Pinned message");
        if (s.store.existingTimeline(c.id())) |tl| if (tl.find(pid)) |m| {
            line = if (m.deleted()) t("Deleted message") else text.summary(s, m, true);
        };
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .min_height = 50, .padding = .{ .start = 14, .end = 6, .top = 7, .bottom = 7 }, .radius = 16, .background = col.surface_2 }, .{});
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .grow = 1, .width = .fill, .pressed_opacity = 0.85 }, .{ .on_press = .{ .extras = .{ .pin_tap = Id.of(pid) } }, .key = key(.{"pinbar"}) });
        // Up to four lines, the current one lit.
        ui.begin(.{ .gap = 2, .height = .{ .px = 34 }, .justify = .center }, .{});
        const shown = @min(pinned.len, 4);
        for (0..shown) |i| {
            const seg: f32 = (34 - 2 * @as(f32, @floatFromInt(shown - 1))) / @as(f32, @floatFromInt(shown));
            ui.begin(.{ .width = .{ .px = 3 }, .height = .{ .px = seg }, .radius = 2, .background = if (i == @min(idx, 3)) col.accent else col.accent.withAlpha(0.3) }, .{});
            ui.end();
        }
        ui.end();
        ui.begin(.{ .grow = 1, .width = .fill }, .{});
        ui.text(if (pinned.len > 1) fmt.tf("Pinned message #{n}", .{ .n = @as(i64, @intCast(idx + 1)) }) else t("Pinned message"), .{ .font_size = 12.5, .weight = 700, .color = col.accent });
        ui.text(line, .{ .font_size = 14, .color = col.text, .max_lines = 1 });
        ui.end();
        ui.end();
        if (can(c, "pinMessages")) kit.iconButton(cx, icons.close, .{ .extras = .{ .pin_unpin = Id.of(pid) } }, .{ .size = 32, .icon_size = 18 });
        ui.end();
    }
    if (bot) {
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .padding = .xy(14, 8), .radius = 16, .background = col.surface_2 }, .{});
        ui.icon(icons.info, 18, col.warning, .{}, 0);
        ui.text(t("Chats with AI assistants are not end-to-end encrypted. The assistant's provider processes your messages."), .{ .font_size = 13, .color = col.text_2, .grow = 1, .width = .fill });
        ui.end();
    }
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// The message list

fn messages(cx: Cx, c: *const data.Chat) void {
    const ui = cx.ui;
    const s = cx.s;
    const tl = s.store.existingTimeline(c.id());
    // Oldest at the top; the view starts at the end and stays there as messages arrive, and
    // keeps its place when older ones load above.
    ui.beginScrollWith(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .top = 10, .bottom = 14, .start = if (cx.phone) 10 else 22, .end = if (cx.phone) 10 else 22 }, .align_items = .center, .justify = .end }, .{ .key = key(.{ "msgs", c.id() }), .anchor_end = true, .keep_position = true, .on_scroll = onScroll });
    ui.begin(.{ .width = .fill, .max_width = 820 }, .{});
    if (tl == null or !tl.?.loaded) {
        kit.spinner(cx);
    } else {
        const list = tl.?;
        const items = list.items.items;
        const first_shown = if (items.len > s.show_count) items.len - s.show_count else 0;
        if (first_shown > 0 or list.has_older) {
            ui.begin(.{ .align_items = .center, .padding = .all(14) }, .{ .key = key(.{"older"}) });
            kit.button(cx, t("Load earlier messages"), .load_older, .{ .kind = .secondary, .small = true, .busy = list.loading });
            ui.end();
        } else intro(cx, c);
        for (items[first_shown..], first_shown..) |m, i| {
            const older = if (i > 0) items[i - 1] else null;
            const newer = if (i + 1 < items.len) items[i + 1] else if (list.pending.items.len > 0) list.pending.items[0] else null;
            // A day separator above the first message of each day.
            if (older == null or !fmt.sameDay(older.?.at, m.at)) daySep(cx, m.at);
            // The "unread" line sits above the first unread message.
            if (s.first_unread > 0 and m.seq() != null and m.seq().? == s.first_unread and !s.store.isMe(m.authorId())) unreadLine(cx);
            messageRow(cx, c, m, older, newer);
        }
        // Being sent (newest).
        for (list.pending.items, 0..) |m, pi| {
            const older = if (pi > 0) list.pending.items[pi - 1] else if (items.len > 0) items[items.len - 1] else null;
            messageRow(cx, c, m, older, if (pi + 1 < list.pending.items.len) list.pending.items[pi + 1] else null);
        }
    }
    ui.end();
    ui.end();
    @import("msgextras.zig").bottomButton(cx, c);
}

fn onScroll(e: zui.ScrollEvent) Msg {
    return if (e.reached_start) .reached_top else .{ .scroll_end = e.at_end };
}

/// A full-width row (separators, notes).
fn flipped(cx: Cx) void {
    cx.ui.begin(.{ .width = .fill }, .{});
}

fn daySep(cx: Cx, at: i64) void {
    const ui = cx.ui;
    flipped(cx);
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .padding = .{ .top = 14, .bottom = 10 } }, .{});
    ui.begin(.{ .grow = 1, .height = .{ .px = 1 }, .background = cx.c.border_strong }, .{});
    ui.end();
    ui.begin(.{ .padding = .xy(10, 4), .radius = 9, .background = cx.c.surface }, .{});
    ui.text(fmt.dayLabel(cx.a(), at), .{ .font_size = 12, .weight = 700, .color = cx.c.text_2 });
    ui.end();
    ui.begin(.{ .grow = 1, .height = .{ .px = 1 }, .background = cx.c.border_strong }, .{});
    ui.end();
    ui.end();
    ui.end();
}

fn unreadLine(cx: Cx) void {
    const ui = cx.ui;
    flipped(cx);
    ui.begin(.{ .align_items = .center, .padding = .xy(0, 12) }, .{});
    ui.begin(.{ .padding = .xy(14, 5), .radius = 10, .background = cx.c.accent_soft }, .{});
    ui.text(t("Unread messages"), .{ .font_size = 12.5, .weight = 700, .color = cx.c.accent });
    ui.end();
    ui.end();
    ui.end();
}

/// The card at the top of a chat (Reseal-js chatview intro): an assistant's greeting and
/// conversation starters, an encrypted chat's promise, a saved chat's purpose.
fn intro(cx: Cx, c: *const data.Chat) void {
    const ui = cx.ui;
    const col = cx.c;
    const s = cx.s;
    const bot = c.is("bot");
    var mine = false;
    var shown: usize = 0;
    if (s.store.existingTimeline(c.id())) |tl| for (tl.items.items) |m| {
        if (m.isService()) continue;
        shown += 1;
        if (s.store.isMe(m.authorId())) mine = true;
    };
    if (shown > 3 and !bot) return;
    if (!bot and !c.encrypted() and !c.is("saved")) {
        if (shown > 0) return;
    }
    const peer = s.store.peer(c);
    flipped(cx);
    ui.begin(.{ .align_items = .center, .padding = .{ .top = 24, .bottom = 22 } }, .{});
    ui.begin(.{ .max_width = 360, .align_items = .center, .gap = 6, .padding = .{ .top = 24, .bottom = 20, .start = 24, .end = 24 }, .radius = 24, .background = col.surface_2 }, .{});
    ui.begin(.{ .width = .{ .px = 44 }, .height = .{ .px = 44 }, .radius = 15, .background = col.brand, .align_items = .center, .justify = .center }, .{});
    ui.icon(if (bot) icons.sparkles else if (c.is("saved")) icons.bookmark else if (c.encrypted()) icons.shieldCheck else icons.chat, 24, Color.white, .{}, 0);
    ui.end();
    const body: zui.Style = .{ .font_size = 13.5, .color = col.text_2, .text_align = .center, .line_height = 1.6 };
    if (bot) {
        ui.text(s.store.title(c), .{ .font_size = 17, .weight = 700, .color = col.text, .text_align = .center });
        const about = if (peer) |p| (p.s("bio") orelse p.s("bot.description")) else null;
        ui.text(if (about != null and about.?.len > 0) about.? else t("Ask me anything."), body);
        if (!mine) if (peer) |p| if (p.get("bot")) |b| {
            ui.begin(.{ .direction = .row, .wrap = true, .justify = .center, .gap = 6, .padding = .{ .top = 8 } }, .{});
            for (j.arr(b, "starters"), 0..) |st, i| if (st == .string and i < 8) {
                ui.begin(.{ .padding = .xy(12, 7), .radius = 14, .background = col.surface, .border_width = 1, .border_color = col.border, .pressed_background = col.active }, .{ .on_press = .{ .chat_more = .{ .starter = .{ .chat = Id.of(c.id()), .i = @intCast(i) } } }, .key = key(.{ "starter", i }) });
                ui.text(st.string, .{ .font_size = 13.5, .color = col.text });
                ui.end();
            };
            ui.end();
        };
    } else if (c.is("saved")) {
        ui.text(s.store.title(c), .{ .font_size = 17, .weight = 700, .color = col.text, .text_align = .center });
        const about = c.o.s("about") orelse "";
        ui.text(if (about.len > 0) about else t("Your private space for notes, links, files and messages you want to keep. Encrypted and on all your devices."), body);
    } else if (c.encrypted()) {
        ui.text(t("Encrypted chat"), .{ .font_size = 17, .weight = 700, .color = col.text, .text_align = .center });
        ui.text(t("Messages, files and calls in this chat are encrypted on your devices before they are sent."), body);
        const verify: Msg = if (c.is("private") and peer != null) .{ .menu = .{ .safety = Id.of(peer.?.s("id") orelse "") } } else .{ .open_info = Id.of(c.id()) };
        ui.begin(.{ .padding = .xy(8, 4), .radius = 8, .pressed_opacity = 0.7 }, .{ .on_press = verify, .key = key(.{"verify-code"}) });
        ui.text(t("Verify the security code"), .{ .font_size = 13.5, .weight = 650, .color = col.accent });
        ui.end();
    } else {
        ui.text(t("No messages here yet"), .{ .font_size = 17, .weight = 700, .color = col.text, .text_align = .center });
    }
    ui.end();
    ui.end();
    ui.end();
}

fn sameRun(a: ?*data.Message, b: *data.Message) bool {
    const x = a orelse return false;
    if (x.isService() or b.isService()) return false;
    if (!std.mem.eql(u8, x.authorId(), b.authorId())) return false;
    return @abs(x.at - b.at) < 5 * 60_000 and fmt.sameDay(x.at, b.at);
}

fn messageRow(cx: Cx, c: *const data.Chat, m: *data.Message, older: ?*data.Message, newer: ?*data.Message) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    const a = cx.a();
    const k = if (m.local_id != 0) key(.{ "local", m.local_id }) else key(.{ "m", m.id() });
    if (m.isService()) {
        ui.begin(.{ .width = .fill, .align_items = .center, .padding = .xy(0, 8) }, .{ .key = k });
        ui.text(text.serviceText(s, m), .{ .font_size = 12.5, .weight = 550, .color = col.text_3, .text_align = .center, .max_width = 520 });
        ui.end();
        return;
    }
    const mine = s.store.isMe(m.authorId());
    const out = mine and !c.is("channel");
    const group_names = s.store.showsSenderNames(c) and !mine;
    const run_start = !sameRun(older, m);
    const run_end = !sameRun(newer, m);
    const max_w = @min(580, (if (cx.phone) cx.w else cx.w - 400) * if (cx.phone) @as(f32, 0.84) else 0.76);
    const selected = (s.selecting and m.local_id == 0 and s.isSelected(m.id())) or (m.local_id == 0 and s.extras.highlight.eql(m.id()));
    ui.begin(.{ .direction = .row, .align_items = .end, .gap = 8, .width = .fill, .justify = if (out) .end else .start, .padding = .{ .top = if (run_start) 10 else 1.5, .bottom = 1.5 }, .background = if (selected) col.accent_soft else null, .radius = if (selected) 12 else 0 }, .{ .key = k });
    if (s.selecting and m.local_id == 0) {
        // The selection mark, on the far side from the bubble's tail.
        ui.begin(.{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 11, .border_width = if (selected) 0 else 1.5, .border_color = col.border_strong, .background = if (selected) col.brand else null, .align_items = .center, .justify = .center, .align_self = .center }, .{});
        if (selected) ui.icon(icons.check, 14, col.on_accent, .{}, 0);
        ui.end();
    }
    if (group_names) {
        if (run_end) {
            const u = s.store.user(m.senderId());
            kit.avatar(cx, .{ .name = if (u) |x| s.store.userName(x) else "…", .color = if (u) |x| x.i("color") orelse 0 else 0, .image = if (u) |x| x.s("avatar") else null, .size = 34 }, 0);
        } else {
            ui.begin(.{ .width = .{ .px = 34 } }, .{});
            ui.end();
        }
    }
    const tap: ?Msg = if (m.local_id != 0)
        (if (m.state == .failed) Msg{ .menu = .{ .menu = .{ .kind = .message, .target = Id.of(c.id()), .item = Id.of(std.fmt.allocPrint(a, "local:{d}", .{m.local_id}) catch "") } } } else null)
    else
        .{ .message_tap = Id.of(m.id()) };
    const media_items = m.media();
    // Pictures, videos and round videos stand alone; voice messages and files sit in a bubble.
    const media_only = media_items.len > 0 and m.text().len == 0 and m.decrypt == .ok and !m.deleted() and for (media_items) |it| {
        const mk = j.strOr(it, "kind", "file");
        if (!(std.mem.eql(u8, mk, "photo") or std.mem.eql(u8, mk, "gif") or std.mem.eql(u8, mk, "video") or std.mem.eql(u8, mk, "round"))) break false;
    } else true;
    const bg = if (media_only) null else if (out) col.bubble_out else col.bubble_in;
    const fg = if (out) col.bubble_out_text else col.bubble_in_text;
    const small: f32 = 7;
    const big: f32 = if (s.prefs.square_bubbles) 6 else theme.bubble_radius;
    _ = small;
    ui.begin(.{ .max_width = max_w, .min_width = 60, .padding = if (media_only) .{} else .{ .top = 8, .bottom = 8, .start = 13, .end = 13 }, .radius = big, .background = bg, .gap = 2, .clip = media_only }, .{ .on_press = tap, .on_long_press = if (m.local_id == 0 and !s.selecting) Msg{ .message_action = .{ .what = .select, .msg = Id.of(m.id()) } } else null, .on_context = tap });
    if (group_names and run_start) {
        const u = s.store.user(m.senderId());
        ui.text(if (u) |x| s.store.userName(x) else "…", .{ .font_size = 13.5, .weight = 700, .color = theme.nameColor(if (u) |x| x.i("color") orelse 0 else 0, col.dark), .max_lines = 1 });
    }
    if (m.deleted()) {
        ui.text(t("Deleted message"), .{ .font_size = cx.fs, .color = fg });
    } else if (m.decrypt != .ok) {
        decryptNote(cx, m, fg);
    } else {
        if (j.obj(m.content, "fwd")) |fwd| {
            const from = if (j.str(fwd, "fromUserId")) |uid| s.store.displayName(uid) else j.str(fwd, "fromName") orelse t("Hidden sender");
            ui.text(std.fmt.allocPrint(a, "{s} {s}", .{ t("Forwarded from"), from }) catch "", .{ .font_size = 13, .color = fg, .opacity = 0.85 });
        }
        if (j.obj(m.content, "story") != null) {
            ui.begin(.{ .direction = .row, .gap = 8, .padding = .{ .bottom = 2 } }, .{});
            ui.begin(.{ .width = .{ .px = 3 }, .radius = 2, .background = fg.withAlpha(0.55) }, .{});
            ui.end();
            ui.text(t("Replied to a glimpse"), .{ .font_size = 13, .weight = 600, .color = fg, .opacity = 0.85 });
            ui.end();
        }
        if (j.str(m.o.v, "replyTo.id")) |rid| {
            // Pressing the quote shows the message it answers.
            ui.begin(.{}, .{ .on_press = .{ .extras = .{ .jump = .{ .msg = Id.of(rid), .seq = j.intOr(m.o.v, "replyTo.seq", 0) } } } });
            replyQuote(cx, c, rid, out);
            ui.end();
        }
        if (media_items.len > 0) mediaBlock(cx, m, media_items, max_w, out);
        if (j.obj(m.content, "poll")) |p| pollBlock(cx, m, p, fg);
        if (j.obj(m.content, "location")) |loc| card(cx, icons.location, j.str(loc, "title") orelse t("Location"), j.str(loc, "address") orelse std.fmt.allocPrint(a, "{d:.5}, {d:.5}", .{ j.floatOr(loc, "lat", 0), j.floatOr(loc, "lng", 0) }) catch "", fg);
        if (j.obj(m.content, "contact")) |ct| card(cx, icons.user, j.strOr(ct, "name", ""), j.str(ct, "phone") orelse "", fg);
        if (j.obj(m.content, "sticker")) |st| ui.text(j.strOr(st, "emoji", ""), .{ .font_size = 96, .line_height = 1.1 });
        const txt = m.text();
        if (txt.len > 0) {
            const big_emoji = isEmojiOnly(txt);
            if (big_emoji) {
                ui.text(txt, .{ .font_size = 42, .color = fg, .line_height = 1.15 });
            } else {
                rich.text(cx, txt, markdown.fromJson(a, j.field(m.content, "entities")), .{ .fg = fg, .link = if (out) fg else col.accent, .revealed = s.isRevealed(m.id()), .msg = if (m.local_id == 0) m.id() else "", .font_size = cx.fs + 0.5 });
            }
        }
        if (j.obj(m.content, "preview")) |pv| if (j.str(pv, "title") != null or j.str(pv, "description") != null) linkCard(cx, pv, fg);
        // Inline buttons (a link opens, the others answer the bot).
        for (j.arr(m.content, "buttons"), 0..) |row, ri| {
            ui.begin(.{ .direction = .row, .gap = 4, .padding = .{ .top = 4 } }, .{ .key = key(.{ "ibr", m.id(), ri }) });
            for (if (row == .array) row.array.items else &[_]j.Value{}, 0..) |b, bi| {
                if (ri > 15 or bi > 15) break;
                ui.begin(.{ .grow = 1, .width = .fill, .direction = .row, .gap = 5, .align_items = .center, .justify = .center, .padding = .xy(10, 8), .radius = 10, .background = fg.withAlpha(0.1), .pressed_background = fg.withAlpha(0.2) }, .{ .on_press = if (m.local_id == 0) Msg{ .chat_more = .{ .button = .{ .msg = Id.of(m.id()), .row = @intCast(ri), .col = @intCast(bi) } } } else null, .key = key(.{ "ib", m.id(), ri, bi }) });
                ui.text(j.strOr(b, "text", ""), .{ .font_size = 13.5, .weight = 650, .color = fg, .max_lines = 1 });
                if (j.str(b, "url") != null) ui.icon(icons.external, 13, fg, .{}, 0);
                ui.end();
            }
            ui.end();
        }
        if (m.verified != null and !m.verified.?) {
            ui.begin(.{ .direction = .row, .gap = 4, .align_items = .center }, .{});
            ui.icon(icons.alert, 14, col.warning, .{}, 0);
            ui.text(t("Unverified sender"), .{ .font_size = 12, .color = col.warning });
            ui.end();
        }
    }
    metaRow(cx, c, m, out, media_only);
    reactions(cx, m, out);
    if (m.state == .failed) {
        ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center, .padding = .{ .top = 6 } }, .{});
        ui.icon(icons.alertCircle, 16, if (out) Color.white else col.danger, .{}, 0);
        ui.text(m.err orelse t("Not sent"), .{ .font_size = 13, .color = if (out) Color.white else col.danger });
        ui.end();
    }
    ui.end();
    ui.end();
}

/// A location or contact: an icon tile beside a title and a line.
fn card(cx: Cx, ic: zui.Icon, title: []const u8, sub: []const u8, fg: Color) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .min_width = 220, .padding = .xy(0, 3) }, .{});
    ui.begin(.{ .width = .{ .px = 46 }, .height = .{ .px = 46 }, .radius = 14, .background = fg.withAlpha(0.1), .align_items = .center, .justify = .center }, .{});
    ui.icon(ic, 24, fg, .{}, 0);
    ui.end();
    ui.begin(.{ .grow = 1, .width = .fill, .gap = 1 }, .{});
    ui.text(title, .{ .font_size = 14.5, .weight = 650, .color = fg, .max_lines = 2 });
    if (sub.len > 0) ui.text(sub, .{ .font_size = 13, .color = fg, .opacity = 0.75, .max_lines = 1 });
    ui.end();
    ui.end();
}

/// A link preview inside a bubble (opened from the message menu).
fn linkCard(cx: Cx, p: j.Value, fg: Color) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .gap = 8, .padding = .{ .top = 4 } }, .{});
    ui.begin(.{ .width = .{ .px = 3 }, .radius = 2, .background = fg.withAlpha(0.55) }, .{});
    ui.end();
    ui.begin(.{ .grow = 1, .width = .fill, .gap = 2, .padding = .{ .start = 4 } }, .{});
    if (j.str(p, "siteName")) |x| ui.text(x, .{ .font_size = 12.5, .weight = 700, .color = fg, .opacity = 0.8, .max_lines = 1 });
    if (j.str(p, "title")) |x| ui.text(x, .{ .font_size = 14, .weight = 650, .color = fg, .max_lines = 2 });
    if (j.str(p, "description")) |x| ui.text(x, .{ .font_size = 13, .color = fg, .opacity = 0.85, .max_lines = 3 });
    ui.end();
    ui.end();
}

fn isEmojiOnly(s: []const u8) bool {
    if (s.len == 0 or s.len > 24) return false;
    var it = (std.unicode.Utf8View.init(s) catch return false).iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x2000 and cp != 0x200D and cp != 0xFE0F) return false;
        if (cp != 0x200D and cp != 0xFE0F and !(cp >= 0x1F3FB and cp <= 0x1F3FF)) n += 1;
    }
    return n > 0 and n <= 3;
}

fn decryptNote(cx: Cx, m: *const data.Message, fg: Color) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .gap = 8, .align_items = .center }, .{});
    if (m.decrypt == .pending) {
        ui.spinner(16, fg, .{}, key(.{ "dspin", m.id() }));
    } else ui.icon(if (m.decrypt == .failed) icons.alert else icons.lock, 18, fg, .{ .opacity = 0.8 }, 0);
    ui.text(switch (m.decrypt) {
        .pending => t("Decrypting…"),
        .nokey => t("Waiting for the key to this message. It will appear when a member who has it comes online."),
        .failed => t("This message could not be decrypted."),
        .ok => "",
    }, .{ .font_size = 14, .color = fg, .opacity = 0.85 });
    ui.end();
}

fn replyQuote(cx: Cx, c: *const data.Chat, rid: []const u8, out: bool) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    var name: []const u8 = "";
    var line: []const u8 = t("Deleted message");
    if (s.store.existingTimeline(c.id())) |tl| if (tl.find(rid)) |target| {
        name = if (target.senderId().len > 0) s.store.displayName(target.senderId()) else t("Channel");
        line = text.summary(s, target, true);
    };
    ui.begin(.{ .direction = .row, .gap = 8, .padding = .{ .top = 6, .bottom = 7, .start = 10, .end = 10 }, .radius = 12, .background = if (out) Color.hex("#ffffff29") else col.accent.mix(0.09, Color.transparent) }, .{});
    ui.begin(.{ .width = .{ .px = 3 }, .radius = 2, .background = if (out) Color.hex("#ffffffd9") else col.accent, .align_self = .stretch }, .{});
    ui.end();
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    if (name.len > 0) ui.text(name, .{ .font_size = 13, .weight = 700, .color = if (out) Color.white else col.accent, .max_lines = 1 });
    ui.text(line, .{ .font_size = 13.5, .color = if (out) col.bubble_out_text else col.bubble_in_text, .max_lines = 1, .opacity = 0.85 });
    ui.end();
    ui.end();
}

/// One photo, GIF or video of a message, `w` by `h`.
fn visualTile(cx: Cx, m: *const data.Message, item: j.Value, i: usize, w: f32, h: f32, radius: f32, press: ?Msg) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    const kind = j.strOr(item, "kind", "file");
    const vc = @import("voice.zig");
        ui.begin(.{ .width = .{ .px = w }, .height = .{ .px = h }, .radius = radius, .clip = true, .background = col.surface_3, .align_items = .center, .justify = .center }, .{ .key = key(.{ "media", j.strOr(item, "id", ""), i }), .on_press = press });
        if (j.str(item, "thumb")) |th| ui.image(th, .{ .position = .absolute, .inset = .{ .top = 0, .start = 0 }, .width = .{ .px = w }, .height = .{ .px = h } }, key(.{ "thumb", j.strOr(item, "id", "") }));
        const f = media.shown(s, item);
        if (std.mem.eql(u8, kind, "video")) {
            // Plays in place (tap again to pause).
            if (vc.videoPlaying(s, m, @intCast(i))) |player| {
                ui.video(player, .{ .cover = false }, .{ .position = .absolute, .inset = .{ .top = 0, .start = 0 }, .width = .{ .px = w }, .height = .{ .px = h } }, key(.{ "vid", j.strOr(item, "id", "") }));
                ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .start = 0 }, .width = .{ .px = w }, .height = .{ .px = h } }, .{ .on_press = .{ .voice = .{ .play = .{ .msg = Id.of(m.id()), .index = @intCast(i) } } } });
                ui.end();
            } else {
                ui.begin(.{ .width = .{ .px = 54 }, .height = .{ .px = 54 }, .radius = 18, .background = Color.hex("#0a0c1473"), .align_items = .center, .justify = .center }, .{ .on_press = if (m.local_id == 0) Msg{ .voice = .{ .play = .{ .msg = Id.of(m.id()), .index = @intCast(i) } } } else null });
                if (s.voice.waiting and s.voice.playing_msg.eql(m.id())) ui.spinner(24, Color.white, .{}, 0) else ui.icon(icons.play, 26, Color.white, .{}, 0);
                ui.end();
            }
        } else if (f) |file| {
            if (file.state == .ready) media.draw(ui, file, j.strOr(item, "id", ""), .{ .position = .absolute, .inset = .{ .top = 0, .start = 0 }, .width = .{ .px = w }, .height = .{ .px = h } }, key(.{ "full", j.strOr(item, "id", "") }));
        }
        // Hidden with a spoiler: covered until tapped.
        if (j.truthy(item, "spoiler") and !s.isRevealed(m.id())) {
            ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .start = 0 }, .width = .{ .px = w }, .height = .{ .px = h }, .background = col.surface_3, .align_items = .center, .justify = .center, .gap = 6 }, .{ .on_press = if (m.local_id == 0) Msg{ .message_action = .{ .what = .reveal, .msg = Id.of(m.id()) } } else null, .key = key(.{ "spl", j.strOr(item, "id", ""), i }) });
            ui.icon(icons.eyeOff, 26, col.text_2, .{}, 0);
            ui.text(t("Spoiler"), .{ .font_size = 13, .weight = 650, .color = col.text_2 });
            ui.end();
        }
        if (m.local_id != 0 and m.state == .sending) {
            ui.begin(.{ .width = .{ .px = 54 }, .height = .{ .px = 54 }, .radius = 18, .background = Color.hex("#0a0c1480"), .align_items = .center, .justify = .center }, .{});
            ui.text(std.fmt.allocPrint(cx.a(), "{d}%", .{@as(u32, @intFromFloat(m.progress * 100))}) catch "", .{ .font_size = 12, .weight = 700, .color = Color.white });
            ui.end();
        }
        ui.end();
}

fn isVisual(item: j.Value) bool {
    const kind = j.strOr(item, "kind", "file");
    return std.mem.eql(u8, kind, "photo") or std.mem.eql(u8, kind, "gif") or std.mem.eql(u8, kind, "video");
}

/// Two to ten photos and videos as one album (rows of two, an odd first one across).
fn album(cx: Cx, m: *const data.Message, items: []j.Value, max_w: f32) void {
    const ui = cx.ui;
    const total = @min(max_w, 420);
    var idx: [10]usize = undefined;
    var n: usize = 0;
    for (items, 0..) |it, i| if (isVisual(it) and n < idx.len) {
        idx[n] = i;
        n += 1;
    };
    ui.begin(.{ .gap = 3, .width = .{ .px = total }, .radius = 16, .clip = true }, .{});
    var k: usize = 0;
    if (n % 2 == 1) {
        const it = items[idx[0]];
        const w0: f32 = @floatFromInt(j.intOr(it, "w", 320));
        const h0: f32 = @floatFromInt(j.intOr(it, "h", 240));
        visualTile(cx, m, it, idx[0], total, @min(320, total * h0 / @max(1, w0)), 0, openMsg(m, idx[0]));
        k = 1;
    }
    while (k < n) : (k += 2) {
        ui.begin(.{ .direction = .row, .gap = 3 }, .{});
        const cell = (total - 3) / 2;
        for (0..2) |o| visualTile(cx, m, items[idx[k + o]], idx[k + o], cell, cell * 0.85, 0, openMsg(m, idx[k + o]));
        ui.end();
    }
    ui.end();
}

fn openMsg(m: *const data.Message, i: usize) ?Msg {
    if (m.local_id != 0) return null;
    return .{ .open_media = .{ .msg = Id.of(m.id()), .index = @intCast(@min(i, 255)) } };
}

fn mediaBlock(cx: Cx, m: *const data.Message, items: []j.Value, max_w: f32, out: bool) void {
    const ui = cx.ui;
    const col = cx.c;
    var visuals: usize = 0;
    for (items) |it| {
        if (isVisual(it)) visuals += 1;
    }
    if (visuals > 1) album(cx, m, items, max_w);
    for (items, 0..) |item, i| {
        const kind = j.strOr(item, "kind", "file");
        const vc = @import("voice.zig");
        if (std.mem.eql(u8, kind, "voice")) {
            vc.voiceBubble(cx, m, item, @intCast(i), if (out) col.bubble_out_text else col.bubble_in_text, if (out) Color.hex("#ffffff38") else col.brand);
            continue;
        }
        if (std.mem.eql(u8, kind, "round")) {
            vc.roundBubble(cx, m, item, @intCast(i));
            continue;
        }
        const visual = std.mem.eql(u8, kind, "photo") or std.mem.eql(u8, kind, "gif") or std.mem.eql(u8, kind, "video");
        if (visual) {
            if (visuals > 1) continue;
            const w0: f32 = @floatFromInt(j.intOr(item, "w", 320));
            const h0: f32 = @floatFromInt(j.intOr(item, "h", 240));
            const w = @min(@min(max_w, 420), w0);
            const h = @min(420, w * h0 / @max(1, w0));
            visualTile(cx, m, item, i, w, h, 16, null);
        } else {
            // A file card.
            const name = j.strOr(item, "name", t("File"));
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .padding = .xy(if (m.text().len > 0) 0 else 13, if (m.text().len > 0) 3 else 9), .min_width = 220 }, .{});
            ui.begin(.{ .width = .{ .px = 48 }, .height = .{ .px = 48 }, .radius = 15, .background = if (out) Color.hex("#ffffff38") else col.brand, .align_items = .center, .justify = .center }, .{});
            ui.icon(if (std.mem.eql(u8, kind, "audio") or std.mem.eql(u8, kind, "voice")) icons.music else icons.file, 22, Color.white, .{}, 0);
            ui.end();
            ui.begin(.{ .grow = 1, .width = .fill }, .{});
            ui.text(name, .{ .font_size = 14.5, .weight = 650, .color = if (out) col.bubble_out_text else col.bubble_in_text, .max_lines = 1 });
            ui.text(fmt.fileSize(cx.a(), j.intOr(item, "size", 0)), .{ .font_size = 12.5, .color = if (out) col.bubble_out_text else col.bubble_in_text, .opacity = 0.72 });
            ui.end();
            ui.end();
        }
    }
}

/// A poll or quiz (pollView): results once voted (or closed, or for the author of a public poll);
/// a tap on an option votes (several answers: ticks it for the Vote button).
fn pollBlock(cx: Cx, m: *const data.Message, p: j.Value, fg: Color) void {
    const ui = cx.ui;
    const col = cx.c;
    const state = j.obj(m.o.v, "poll");
    const quiz = j.truthy(state, "quiz");
    const anonymous = if (j.field(state, "anonymous")) |x| !(x == .bool and !x.bool) else true;
    const closed = j.truthy(state, "closed");
    const my_vote = j.arr(state, "myVote");
    const total = j.intOr(state, "total", 0);
    const show = my_vote.len > 0 or closed or (cx.s.store.isMe(m.authorId()) and total > 0 and !anonymous);
    const correct: i64 = j.intOr(p, "correct", j.intOr(state, "correct", -1));
    const multiple = j.truthy(state, "multiple");
    const pollx = @import("pollx.zig");
    const can_vote = !show and !closed and m.local_id == 0 and !cx.s.selecting;
    ui.begin(.{ .gap = 6, .min_width = 260, .padding = .xy(0, 3) }, .{});
    ui.text(j.strOr(p, "question", ""), .{ .font_size = 15, .weight = 700, .color = fg });
    const kind = if (closed) t("Final results") else if (quiz) (if (anonymous) t("Anonymous quiz") else t("Quiz")) else if (anonymous) t("Anonymous poll") else t("Public poll");
    ui.text(kind, .{ .font_size = 12.5, .color = fg, .opacity = 0.7 });
    const counts = j.arr(state, "counts");
    for (j.arr(p, "options"), 0..) |o, i| {
        const label = if (o == .string) o.string else j.strOr(o, "text", "");
        const n: i64 = if (i < counts.len and counts[i] == .integer) counts[i].integer else 0;
        const mine = for (my_vote) |x| {
            if (x == .integer and x.integer == @as(i64, @intCast(i))) break true;
        } else false;
        const right = quiz and show and correct == @as(i64, @intCast(i));
        const wrong = quiz and show and mine and !right;
        const pct: i64 = if (total > 0) @divTrunc(n * 100 + @divTrunc(total, 2), total) else 0;
        const ticked = pollx.chosen(cx.s, m.id(), i);
        ui.begin(.{ .gap = 5, .padding = .xy(10, 8), .radius = 12, .background = fg.withAlpha(0.07), .pressed_background = fg.withAlpha(0.14) }, .{ .on_press = if (can_vote) pollx.msgOf(.{ .tap = .{ .msg = Id.of(m.id()), .option = @intCast(@min(i, 255)), .multiple = multiple } }) else null, .key = key(.{ "popt", m.id(), i }) });
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8 }, .{});
        if (show) {
            ui.text(std.fmt.allocPrint(cx.a(), "{d}%", .{pct}) catch "", .{ .font_size = 13, .weight = 750, .color = fg, .min_width = 36 });
        } else {
            ui.begin(.{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .radius = if (multiple) 5 else 9, .border_width = if (ticked) 0 else 1.5, .border_color = fg.withAlpha(0.45), .background = if (ticked) col.accent else null, .align_items = .center, .justify = .center }, .{});
            if (ticked) ui.icon(icons.check, 12, Color.white, .{}, 0);
            ui.end();
        }
        ui.text(label, .{ .font_size = 14.5, .color = fg, .grow = 1, .width = .fill });
        if (right) ui.icon(icons.check, 17, col.success, .{}, 0) else if (wrong) ui.icon(icons.close, 17, col.danger, .{}, 0) else if (mine) ui.icon(icons.check, 17, fg, .{}, 0);
        ui.end();
        if (show) {
            // The bar: a filled part and the rest, in proportion.
            ui.begin(.{ .direction = .row, .height = .{ .px = 4 }, .radius = 2, .background = fg.withAlpha(0.12), .clip = true }, .{});
            if (pct > 0) {
                ui.begin(.{ .grow = @floatFromInt(pct), .height = .{ .px = 4 }, .background = if (right) col.success else if (wrong) col.danger else fg.withAlpha(0.7) }, .{});
                ui.end();
            }
            if (pct < 100) {
                ui.begin(.{ .grow = @floatFromInt(100 - pct), .height = .{ .px = 4 } }, .{});
                ui.end();
            }
            ui.end();
        }
        ui.end();
    }
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8 }, .{});
    ui.text(if (total > 0) fmt.tn(cx.a(), total, "{n} vote", "{n} votes") else t("No votes yet"), .{ .font_size = 12.5, .color = fg, .opacity = 0.7, .grow = 1, .width = .fill });
    if (can_vote and multiple and pollx.anyChosen(cx.s, m.id())) pollButton(cx, t("Vote"), pollx.msgOf(.{ .vote = Id.of(m.id()) }), fg);
    if (!anonymous and total > 0 and show) pollButton(cx, t("View votes"), pollx.msgOf(.{ .voters = Id.of(m.id()) }), fg);
    ui.end();
    if (quiz and show) if (j.str(p, "explanation")) |ex| if (ex.len > 0) {
        ui.begin(.{ .direction = .row, .gap = 6, .align_items = .start }, .{});
        ui.icon(icons.info, 15, fg, .{}, 0);
        ui.text(ex, .{ .font_size = 13, .color = fg, .opacity = 0.85, .grow = 1, .width = .fill });
        ui.end();
    };
    ui.end();
}

fn pollButton(cx: Cx, label: []const u8, msg: Msg, fg: Color) void {
    const ui = cx.ui;
    ui.begin(.{ .padding = .xy(12, 6), .radius = 10, .background = fg.withAlpha(0.1), .pressed_background = fg.withAlpha(0.2) }, .{ .on_press = msg, .key = key(.{ "pbtn", label }) });
    ui.text(label, .{ .font_size = 13, .weight = 700, .color = fg });
    ui.end();
}

fn metaRow(cx: Cx, c: *const data.Chat, m: *const data.Message, out: bool, overlay: bool) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    const color = if (overlay) Color.white else if (out) col.bubble_meta_out else col.bubble_meta_in;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 3, .align_self = .end, .padding = if (overlay) .{ .top = 2, .bottom = 2, .start = 8, .end = 8 } else .{}, .radius = 9, .background = if (overlay) Color.hex("#0a0c1473") else null, .position = if (overlay) .absolute else .flow, .inset = if (overlay) .{ .bottom = 8, .end = 8 } else .{} }, .{});
    if (j.intOr(m.o.v, "ttl", 0) > 0) ui.icon(icons.timer, 13, color, .{}, 0);
    for (m.media()) |it| if (j.str(it, "key") != null) {
        ui.icon(icons.lockSmall, 12, color, .{}, 0);
        break;
    };
    const views_n = j.intOr(m.o.v, "views", 0);
    if (views_n > 0) {
        ui.icon(icons.eye, 13, color, .{}, 0);
        ui.text(fmt.compact(cx.a(), views_n), .{ .font_size = 11.5, .color = color });
    }
    if (j.str(m.o.v, "editedAt") != null) ui.text(t("edited"), .{ .font_size = 11.5, .color = color });
    // Channels that sign posts: the author's name.
    if (c.is("channel") and c.o.b("signMessages") and m.authorId().len > 0) ui.text(s.store.displayName(m.authorId()), .{ .font_size = 11.5, .color = color, .max_lines = 1 });
    ui.text(fmt.time(cx.a(), if (m.at > 0) m.at else sys.now()), .{ .font_size = 11.5, .color = color });
    if (s.store.isMe(m.authorId()) and !c.is("channel") and !c.is("saved")) {
        switch (m.state) {
            .sending => ui.icon(icons.clock, 16, color, .{}, 0),
            .failed => ui.icon(icons.alertCircle, 16, col.danger, .{}, 0),
            .scheduled => ui.icon(icons.calendar, 16, color, .{}, 0),
            .sent => {
                const read = (c.o.i("readSeq") orelse 0) >= (m.seq() orelse std.math.maxInt(i64));
                ui.icon(if (read) icons.checks else icons.check, 16, if (read and !out) col.accent else color, .{}, 0);
            },
        }
    }
    ui.end();
}

fn reactions(cx: Cx, m: *const data.Message, out: bool) void {
    const list = j.arr(m.o.v, "reactions");
    if (list.len == 0) return;
    const ui = cx.ui;
    const col = cx.c;
    ui.begin(.{ .direction = .row, .gap = 5, .padding = .{ .top = 7 } }, .{});
    for (list) |r| {
        const me = j.truthy(r, "me");
        const bg = if (out) (if (me) Color.white else Color.hex("#ffffff2e")) else if (me) col.accent_soft else col.surface;
        const fg = if (out) (if (me) col.accent else Color.white) else if (me) col.accent else col.text;
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 5, .height = .{ .px = 28 }, .padding = .{ .start = 6, .end = 9 }, .radius = 10, .background = bg, .border_width = if (out) 0 else 1, .border_color = if (me) col.accent else col.border }, .{});
        ui.text(j.strOr(r, "emoji", ""), .{ .font_size = 16, .line_height = 1.1 });
        ui.text(fmt.number(cx.a(), j.intOr(r, "count", 0)), .{ .font_size = 13, .weight = 700, .color = fg });
        ui.end();
    }
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// Composer

fn composer(cx: Cx, c: *const data.Chat) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    const peer = s.store.peer(c);
    ui.begin(.{ .padding = if (cx.phone) .{ .top = 6, .bottom = 8, .start = 8, .end = 8 } else .{ .top = 8, .bottom = 16, .start = 22, .end = 22 }, .align_items = .center }, .{});
    ui.begin(.{ .width = .fill, .max_width = 820 }, .{});
    // Why one cannot write here.
    if (c.o.b("preview")) {
        blocked(cx, null, .{ .join_chat = Id.of(c.id()) }, if (c.is("channel")) t("Join channel") else t("Join group"));
    } else if (c.is("channel") and !can(c, "sendMessages")) {
        const muted = c.isMuted();
        blocked(cx, if (muted) icons.bell else icons.bellOff, .{ .chat_action = .{ .what = if (muted) .unmute else .mute, .chat = Id.of(c.id()) } }, if (muted) t("Unmute") else t("Mute"));
    } else if (c.is("private") and peer != null and peer.?.b("blocked")) {
        blocked(cx, null, .{ .chat_action = .{ .what = .unblock, .chat = Id.of(c.id()) } }, t("Unblock"));
    } else if (c.is("private") and peer != null and peer.?.b("deleted")) {
        note(cx, t("This account was deleted."));
    } else if (!can(c, "sendMessages")) {
        note(cx, t("Only admins can send messages here."));
    } else {
        ui.begin(.{ .direction = .row, .align_items = .end, .gap = 8 }, .{});
        kit.iconButton(cx, icons.attach, .attach, .{ .size = if (cx.phone) 46 else 50, .soft = true });
        ui.begin(.{ .grow = 1, .width = .fill, .background = col.surface_2, .radius = 18 }, .{});
        if (s.reply_to.isSet() or s.editing.isSet()) replyBar(cx, c);
        vcompose.bars(cx, c);
        if (s.voice.recording) @import("voice.zig").recordingBar(cx) else {
        ui.begin(.{ .direction = .row, .align_items = .center, .min_height = 50, .padding = .{ .start = 14, .end = 4, .top = 3, .bottom = 3 } }, .{});
        // Enter sends when "Send with Enter" is on (a keyboard); otherwise, and on phones, it
        // starts a new line and the send button sends.
        const lines = cx.phone or zui.platform != .web or !s.prefs.send_with_enter;
        ui.input(.{
            .key = zui.key("composer"),
            .value = s.fields.get(.composer).get(),
            .placeholder = if (c.is("channel")) t("Broadcast") else if (c.is("saved")) t("Write a note…") else t("Message"),
            .on_change = app.onField(.composer),
            .on_submit = .{ .submit = .composer },
            .multiline = lines,
            .return_key = if (lines) .default else .send,
            .style = .{ .grow = 1, .width = .fill, .font_size = cx.fs + 0.5, .color = col.text, .max_height = 180 },
        });
        kit.iconButton(cx, icons.smile, .{ .compose = .{ .open = .emoji } }, .{ .size = 40 });
        ui.end();
        }
        ui.end();
// With nothing typed, the button records (a voice message, or a round video: a long press
        // switches); a long press or right click on Send opens the send options (sendMenu).
        const kind_feature: []const u8 = if (s.voice.mode == .round) "videoMessages" else "voiceMessages";
        const mic = !s.editing.isSet() and s.fields.get(.composer).trimmed().len == 0 and feature(s, kind_feature) and (zui.platform == .web or zui.platform == .android or zui.platform == .ios);
        const recording = s.voice.recording;
        const options: ?Msg = if (mic) Msg{ .voice = .toggle_mode } else if (!s.editing.isSet()) Msg{ .compose = .{ .open = .options } } else null;
        const press: Msg = if (recording) .{ .voice = .finish } else if (mic) .{ .voice = .record } else .send_text;
        ui.begin(.{ .width = .{ .px = 50 }, .height = .{ .px = 50 }, .radius = 17, .background = if (recording) col.danger else col.brand, .align_items = .center, .justify = .center, .pressed_opacity = 0.85 }, .{ .on_press = press, .on_long_press = if (recording) null else options, .on_context = if (recording) null else options });
        ui.icon(if (s.editing.isSet()) icons.check else if (mic and !recording) @import("voice.zig").micIcon(s) else if (s.lang == .ar) icons.send_rtl else icons.send, 22, col.on_accent, .{}, 0);
        ui.end();
        ui.end();
    }
    ui.end();
    ui.end();
}

fn blocked(cx: Cx, ic: ?zui.Icon, msg: Msg, label: []const u8) void {
    cx.ui.begin(.{ .align_items = .center }, .{});
    cx.ui.begin(.{ .min_width = 240 }, .{});
    kit.button(cx, label, msg, .{ .large = true, .icon = ic, .block = true });
    cx.ui.end();
    cx.ui.end();
}

fn note(cx: Cx, s: []const u8) void {
    cx.ui.begin(.{ .align_items = .center }, .{});
    cx.ui.begin(.{ .padding = .xy(20, 12), .radius = 16, .background = cx.c.surface_2 }, .{});
    cx.ui.text(s, .{ .font_size = 14, .color = cx.c.text_2, .text_align = .center });
    cx.ui.end();
    cx.ui.end();
}

fn replyBar(cx: Cx, c: *const data.Chat) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    const editing = s.editing.isSet();
    const id = if (editing) s.editing.str() else s.reply_to.str();
    var title: []const u8 = if (editing) t("Edit message") else t("Reply");
    var line: []const u8 = "";
    if (s.store.existingTimeline(c.id())) |tl| if (tl.find(id)) |m| {
        if (!editing) title = fmt.tf("Reply to {name}", .{ .name = s.store.displayName(m.senderId()) });
        line = text.summary(s, m, true);
    };
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .padding = .{ .top = 9, .bottom = 2, .start = 14, .end = 8 } }, .{});
    ui.icon(if (editing) icons.edit else icons.reply, 20, col.accent, .{}, 0);
    ui.begin(.{ .grow = 1, .width = .fill, .padding = .{ .start = 9 }, .border_width = 0 }, .{});
    ui.text(title, .{ .font_size = 13, .weight = 700, .color = col.accent, .max_lines = 1 });
    ui.text(line, .{ .font_size = 13.5, .color = col.text_2, .max_lines = 1 });
    ui.end();
    kit.iconButton(cx, icons.close, .cancel_reply, .{ .size = 32 });
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// Menus

pub fn menu(cx: Cx, kind: app.MenuKind, target: Id, item: Id) void {
    switch (kind) {
        .compose => composeMenu(cx),
        .chat_header => if (item.eql("search")) searchSheet(cx, target) else chatMenu(cx, target),
        .chat_row => chatMenu(cx, target),
        .mute => muteMenu(cx, target),
        .message => messageMenu(cx, target, item),
        .member => vgroup.memberMenu(cx, target, item),
        .slow_mode => vgroup.slowModeMenu(cx),
        .reactions_setting => vgroup.reactionsMenu(cx),
        .folder_pick => @import("folders.zig").pickSheet(cx, target),
        .ttl => @import("chatmore.zig").ttlSheet(cx, target),
        .chip => @import("listextras.zig").chipSheet(cx),
        .embed, .call_devices => {},
    }
}

fn composeMenu(cx: Cx) void {
    views.sheet(cx, t("New"));
    views.menuItem(cx, icons.user, t("New message"), .{ .push_pane = .{ .picker = .new_message } }, false);
    views.menuItem(cx, icons.users, t("New group"), .{ .push_pane = .{ .picker = .new_group } }, false);
    views.menuItem(cx, icons.megaphone, t("New channel"), .{ .push_pane = .{ .group_details = .channel } }, false);
    views.menuItem(cx, icons.bookmark, t("New saved chat"), .{ .push_pane = .{ .saved_edit = .{} } }, false);
    if (cx.s.mode == .app) views.menuItem(cx, icons.sparkles, t("Chat with AI"), .{ .bots = .open_list }, false);
    views.endSheet(cx);
}

fn muteMenu(cx: Cx, target: Id) void {
    views.sheet(cx, t("Mute…"));
    const opts = [_]struct { h: i64, label: []const u8 }{ .{ .h = 1, .label = "For 1 hour" }, .{ .h = 8, .label = "For 8 hours" }, .{ .h = 48, .label = "For 2 days" }, .{ .h = -1, .label = "Forever" } };
    for (opts) |o| views.menuItem(cx, icons.bellOff, t(o.label), .{ .mute_for = .{ .chat = target, .hours = o.h } }, false);
    views.endSheet(cx);
}

fn chatMenu(cx: Cx, target: Id) void {
    const s = cx.s;
    const c = s.store.chat(target.str()) orelse return;
    const id = target;
    const muted = c.isMuted();
    const unread = c.unread() > 0 or c.meBool("markedUnread");
    const pair = c.is("private") or c.is("bot") or c.is("saved") or (c.isTeamChat() and !s.store.isTeamStaff(c));
    views.sheet(cx, s.store.title(c));
    const act = struct {
        fn f(what: app.ChatAction, chat: Id) Msg {
            return .{ .chat_action = .{ .what = what, .chat = chat } };
        }
    }.f;
    const info_label = if (c.is("saved")) (if (c.o.b("primary")) t("About Saved") else t("Saved chat info")) else if (c.is("private") or c.is("bot") or s.store.isTeamStaff(c)) t("View profile") else if (c.is("channel")) t("Channel info") else t("Group info");
    views.menuItem(cx, icons.info, info_label, act(.info, id), false);
    views.menuItem(cx, icons.search, t("Search in chat"), act(.search, id), false);
    if (!c.archived()) views.menuItem(cx, if (c.pinnedAt() != 0) icons.unpin else icons.pin, if (c.pinnedAt() != 0) t("Unpin") else t("Pin"), act(if (c.pinnedAt() != 0) .unpin else .pin, id), false);
    if (!c.is("saved")) {
        views.menuItem(cx, if (muted) icons.bell else icons.bellOff, if (muted) t("Unmute") else t("Mute…"), act(if (muted) .unmute else .mute, id), false);
        views.menuItem(cx, if (c.archived()) icons.unarchive else icons.archive, if (c.archived()) t("Unarchive") else t("Archive"), act(if (c.archived()) .unarchive else .archive, id), false);
    }
    views.menuItem(cx, if (unread) icons.checks else icons.chat, if (unread) t("Mark as read") else t("Mark as unread"), act(if (unread) .mark_read else .mark_unread, id), false);
    if (s.mode == .app) views.menuItem(cx, icons.folder, t("Add to folder"), act(.add_to_folder, id), false);
    @import("chatmore.zig").menuItems(cx, c);
    if (s.mode == .app and !c.o.b("protectedContent")) views.menuItem(cx, icons.download, t("Export chat"), act(.export_chat, id), false);
    if (s.mode == .app) views.menuItem(cx, if (c.meBool("locked")) icons.unlock else icons.lock, if (c.meBool("locked")) t("Remove lock") else t("Lock chat"), act(if (c.meBool("locked")) .unlock else .lock, id), false);
    if (c.is("saved")) views.menuItem(cx, icons.edit, t("Edit"), act(.saved_edit, id), false);
    if (c.is("private")) {
        if (s.store.peer(c)) |p| {
            if (!p.b("isContact")) views.menuItem(cx, icons.userPlus, t("Add to contacts"), act(.add_contact, id), false);
            if (c.encrypted() and p.get("keys") != null) views.menuItem(cx, icons.shieldCheck, t("Verify safety number"), act(.show_safety, id), false);
            views.menuItem(cx, icons.alertCircle, if (p.b("blocked")) t("Unblock user") else t("Block user"), act(if (p.b("blocked")) .unblock else .block, id), p.b("blocked") == false);
        }
    }
    if (!c.is("saved")) views.menuItem(cx, icons.trash, t("Clear history"), act(.clear, id), true);
    if (c.is("saved") and !c.o.b("primary")) views.menuItem(cx, icons.trash, t("Clear history"), act(.clear, id), true);
    if (pair) {
        views.menuItem(cx, icons.trash, if (c.is("saved")) (if (c.o.b("primary")) t("Clear Saved Messages") else t("Delete saved chat")) else t("Delete chat"), act(.delete, id), true);
    } else if (std.mem.eql(u8, c.role(), "owner")) {
        views.menuItem(cx, icons.trash, if (c.is("channel")) t("Delete channel") else t("Delete group"), act(.delete, id), true);
    } else if (!s.store.isTeamStaff(c)) {
        views.menuItem(cx, icons.logout, if (c.is("channel")) t("Leave channel") else t("Leave group"), act(.leave, id), true);
    }
    views.endSheet(cx);
}

fn searchSheet(cx: Cx, target: Id) void {
    const s = cx.s;
    const ui = cx.ui;
    const c = s.store.chat(target.str()) orelse return;
    views.sheet(cx, t("Search in chat"));
    ui.begin(.{ .padding = .xy(8, 4), .direction = .row }, .{});
    kit.searchBox(cx, .chat_search, t("Search messages"));
    ui.end();
    const q = std.mem.trim(u8, s.fields.get(.chat_search).get(), " ");
    var n: usize = 0;
    if (q.len >= 2) {
        if (s.store.existingTimeline(c.id())) |tl| {
            var i = tl.items.items.len;
            while (i > 0 and n < 60) {
                i -= 1;
                const m = tl.items.items[i];
                if (m.decrypt != .ok or !containsCi(m.text(), q)) continue;
                n += 1;
                hitRow(cx, s.store.displayName(m.senderId()), m.text(), m.at, m.id());
            }
        }
        if (s.msg_search) |res| for (j.arr(res.v, "messages")) |m| {
            n += 1;
            hitRow(cx, s.store.displayName(j.strOr(m, "senderId", "")), j.strOr(m, "text", ""), sys.parseIso(j.strOr(m, "createdAt", "")) orelse 0, j.strOr(m, "id", ""));
        };
        if (n == 0) kit.emptyState(cx, icons.search, t("No results"), if (c.encrypted()) t("Encrypted chats are searched on this device, in the messages loaded so far.") else null);
    }
    views.endSheet(cx);
}

fn containsCi(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    return false;
}

fn hitRow(cx: Cx, name: []const u8, body: []const u8, at: i64, id: []const u8) void {
    const ui = cx.ui;
    ui.begin(.{ .padding = .xy(12, 8), .radius = 12, .gap = 2, .pressed_background = cx.c.hover }, .{ .on_press = .{ .message_tap = Id.of(id) }, .key = key(.{ "hit", id }) });
    ui.begin(.{ .direction = .row, .gap = 6 }, .{});
    ui.text(name, .{ .font_size = 14, .weight = 650, .color = cx.c.text, .grow = 1, .width = .fill, .max_lines = 1 });
    ui.text(fmt.shortDate(cx.a(), at), .{ .font_size = 12, .color = cx.c.text_3 });
    ui.end();
    ui.text(fmt.plain(cx.a(), body, 140), .{ .font_size = 14, .color = cx.c.text_2, .max_lines = 2 });
    ui.end();
}

fn messageMenu(cx: Cx, chat_id: Id, item: Id) void {
    const s = cx.s;
    const ui = cx.ui;
    const c = s.store.chat(chat_id.str()) orelse return;
    const tl = s.store.existingTimeline(chat_id.str()) orelse return;
    // A message that could not be sent: try again or drop it.
    if (std.mem.startsWith(u8, item.str(), "local:")) {
        const local = std.fmt.parseInt(u32, item.str()["local:".len..], 10) catch return;
        views.sheet(cx, t("Not sent"));
        views.menuItem(cx, icons.refresh, t("Try again"), .{ .retry_send = local }, false);
        views.menuItem(cx, icons.trash, t("Delete"), .{ .cancel_send = local }, true);
        views.endSheet(cx);
        return;
    }
    const m = tl.find(item.str()) orelse return;
    const mine = s.store.isMe(m.authorId());
    const id = item;
    const act = struct {
        fn f(what: app.MessageAction, msg: Id) Msg {
            return .{ .message_action = .{ .what = what, .msg = msg } };
        }
    }.f;
    views.sheet(cx, null);
    // Quick reactions
    if (feature(s, "reactions") and !m.deleted()) {
        ui.beginScroll(.{ .direction = .row, .gap = 2, .padding = .{ .top = 12, .bottom = 6, .start = 4, .end = 4 }, .height = .{ .px = 60 } }, key(.{"rx"}));
        for (views.quick_reactions, 0..) |e, i| {
            ui.begin(.{ .width = .{ .px = 42 }, .height = .{ .px = 42 }, .radius = 21, .align_items = .center, .justify = .center, .pressed_background = cx.c.hover }, .{ .on_press = .{ .react = .{ .msg = id, .emoji = @intCast(i) } }, .key = key(.{ "rx", i }) });
            ui.text(e, .{ .font_size = 24, .line_height = 1.1 });
            ui.end();
        }
        // More reactions: any emoji.
        ui.begin(.{ .width = .{ .px = 42 }, .height = .{ .px = 42 }, .radius = 21, .align_items = .center, .justify = .center, .pressed_background = cx.c.hover }, .{ .on_press = .{ .extras = .{ .more_reactions = id } }, .key = key(.{"rx-more"}) });
        ui.icon(icons.chevronDown, 20, cx.c.text_2, .{}, 0);
        ui.end();
        ui.end();
    }
    const content_ok = !m.deleted() and m.decrypt == .ok;
    if (can(c, "sendMessages") and !m.deleted()) views.menuItem(cx, icons.reply, t("Reply"), act(.reply, id), false);
    const editable = mine and content_ok and j.obj(m.content, "fwd") == null and j.obj(m.content, "poll") == null and m.text().len > 0 and (c.is("saved") or sys.now() - m.at < 48 * 3_600_000);
    if (editable) views.menuItem(cx, icons.edit, t("Edit"), act(.edit, id), false);
    if (content_ok and m.text().len > 0 and !c.o.b("protectedContent")) views.menuItem(cx, icons.copy, t("Copy text"), act(.copy, id), false);
    for (m.media(), 0..) |it, i| {
        if (i >= 4) break;
        views.menuItem(cx, icons.download, std.fmt.allocPrint(cx.a(), "{s}: {s}", .{ t("Download"), j.strOr(it, "name", j.strOr(it, "kind", "")) }) catch t("Download"), .{ .download = .{ .msg = id, .index = @intCast(i) } }, false);
        const kind = j.strOr(it, "kind", "");
        if (std.mem.eql(u8, kind, "photo") or std.mem.eql(u8, kind, "gif")) views.menuItem(cx, icons.image, t("Open"), .{ .open_media = .{ .msg = id, .index = @intCast(i) } }, false);
    }
    if (j.obj(m.content, "poll")) |p| if (!j.truthy(m.o.v, "poll.closed")) {
        for (j.arr(p, "options"), 0..) |o, i| {
            if (i >= 10) break;
            const label = if (o == .string) o.string else j.strOr(o, "text", "");
            views.menuItem(cx, icons.poll, fmt.tf("Vote: {option}", .{ .option = label }), .{ .vote = .{ .msg = id, .option = @intCast(i) } }, false);
        }
        if (j.arr(m.o.v, "poll.myVote").len > 0 and !j.truthy(m.o.v, "poll.quiz")) views.menuItem(cx, icons.refresh, t("Retract vote"), act(.retract_vote, id), false);
        if (s.store.isMe(m.authorId())) views.menuItem(cx, icons.lock, t("Stop poll"), act(.close_poll, id), false);
    };
    if (j.obj(m.content, "location") != null) views.menuItem(cx, icons.location, t("Open in Maps"), act(.open_map, id), false);
    if (j.str(m.content, "preview.url") != null) views.menuItem(cx, icons.external, t("Open link"), act(.open_link, id), false);
    if (rich.hasSpoiler(markdown.fromJson(cx.a(), j.field(m.content, "entities")))) views.menuItem(cx, icons.eye, if (s.isRevealed(m.id())) t("Hide spoiler") else t("Show spoiler"), act(.reveal, id), false);
    const pinned = for (j.arr(c.o.v, "pinned")) |x| {
        if (x == .string and std.mem.eql(u8, x.string, m.id())) break true;
    } else false;
    if (can(c, "pinMessages") and !m.deleted()) views.menuItem(cx, if (pinned) icons.unpin else icons.pin, if (pinned) t("Unpin") else t("Pin"), act(if (pinned) .unpin else .pin, id), false);
    if (content_ok and !c.o.b("protectedContent") and feature(s, "forwarding")) views.menuItem(cx, icons.forward, t("Forward"), act(.forward, id), false);
    if (!m.deleted() and !c.o.b("protectedContent") and m.seq() != null) views.menuItem(cx, icons.link, t("Copy message link"), .{ .extras = .{ .copy_link = id } }, false);
    if (mine and !c.is("private") and !c.is("saved") and !c.is("channel") and (c.o.i("memberCount") orelse 0) <= 100) views.menuItem(cx, icons.eye, t("Seen by…"), .{ .extras = .{ .seen_by = id } }, false);
    if (s.mode == .app) views.menuItem(cx, icons.selectCircle, t("Select"), act(.select, id), false);
    views.menuItem(cx, icons.info, t("Details"), .{ .extras = .{ .details = id } }, false);
    if (content_ok and !c.is("saved") and s.mode == .app and m.text().len > 0) views.menuItem(cx, icons.bookmark, t("Save to Saved Messages"), act(.save, id), false);
    if (j.arr(m.o.v, "reactions").len > 0) views.menuItem(cx, icons.heart, t("Reactions"), .{ .menu = .{ .reactions = id } }, false);
    const deletable = mine or can(c, "deleteMessages") or c.is("private") or c.is("saved") or c.is("bot") or !c.is("channel");
    if (deletable) views.menuItem(cx, icons.trash, t("Delete"), act(.delete, id), true);
    views.endSheet(cx);
}

/// An invite link's group or channel, before joining (main.js joinFlow).
pub fn joinSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const inv = s.invite orelse return;
    const c = j.obj(inv.v, "chat") orelse return;
    const approval = j.truthy(inv.v, "requestApproval");
    const channel = j.eqlStr(c, "type", "channel");
    views.sheet(cx, if (approval) t("Request to join") else t("Join"));
    ui.begin(.{ .align_items = .center, .gap = 6, .padding = .{ .top = 8, .bottom = 12, .start = 12, .end = 12 } }, .{});
    kit.avatar(cx, .{ .name = j.strOr(c, "title", ""), .color = j.intOr(c, "color", 0), .image = j.str(c, "avatar"), .size = 96 }, 0);
    ui.text(j.strOr(c, "title", ""), .{ .font_size = 20, .weight = 700, .color = cx.c.text, .text_align = .center });
    const n = j.intOr(c, "memberCount", 0);
    ui.text(if (channel) fmt.tn(cx.a(), n, "{n} subscriber", "{n} subscribers") else fmt.tn(cx.a(), n, "{n} member", "{n} members"), .{ .font_size = 14, .color = cx.c.text_2 });
    if (j.str(c, "about")) |ab| if (ab.len > 0) ui.text(ab, .{ .font_size = 14, .color = cx.c.text_2, .text_align = .center });
    if (j.truthy(c, "encrypted")) {
        ui.begin(.{ .direction = .row, .gap = 6, .align_items = .center }, .{});
        ui.icon(icons.lock, 14, cx.c.text_2, .{}, 0);
        ui.text(t("End-to-end encrypted"), .{ .font_size = 14, .color = cx.c.text_2 });
        ui.end();
    }
    ui.end();
    ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .start = 12, .end = 12, .bottom = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, if (approval) t("Request to join") else if (channel) t("Join channel") else t("Join group"), .join_invite, .{});
    ui.end();
    views.endSheet(cx);
}

pub fn forwardSheet(cx: Cx) void {
    const s = cx.s;
    views.sheet(cx, t("Forward to…"));
    for (s.store.sorted(cx.a(), false)) |c| {
        if (c.o.b("preview")) continue;
        vlist.chatItem(cx, c, .{ .forward_to = Id.of(c.id()) });
    }
    views.endSheet(cx);
}

pub fn reactionsSheet(cx: Cx) void {
    const s = cx.s;
    views.sheet(cx, t("Reactions"));
    if (s.reactions_detail) |r| {
        for (j.arr(r.v, "reactions")) |x| {
            const emoji = j.strOr(x, "emoji", "");
            for (j.arr(x, "userIds")) |u| if (u == .string) {
                kit.row(cx, s.store.displayName(u.string), .{ .value = emoji, .k = key(.{ "rxu", emoji, u.string }) });
            };
            for (j.arr(x, "users")) |u| {
                kit.row(cx, j.strOr(u, "displayName", ""), .{ .value = emoji, .k = key(.{ "rxu2", emoji, j.strOr(u, "id", "") }) });
            }
        }
    } else kit.spinner(cx);
    views.endSheet(cx);
}

// ---------------------------------------------------------------------------------------------
// Info panel (ui/info.js): the person or group, members, actions

pub fn infoPanel(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const col = cx.c;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6, .height = .{ .px = theme.header_h }, .padding = .xy(14, 0) }, .{});
    const gchat: ?*const data.Chat = if (s.user_info.isSet()) null else if (s.store.chat(s.info.str())) |c| (if (c.is("private") or c.is("bot") or c.is("saved") or c.isTeamChat()) null else c) else null;
    if (gchat != null and s.group.page != .main) {
        kit.iconButton(cx, icons.back, .{ .group = .{ .page = if (s.group.page == .admins or s.group.page == .banned) .edit else .main } }, .{ .rtl = icons.back_rtl });
    } else kit.iconButton(cx, icons.close, .close_info, .{});
    const ptitle = if (gchat) |c| vgroup.pageTitle(s, c) orelse t("Info") else if (s.user_info.isSet()) (if (s.store.user(s.user_info.str())) |u| (if (u.b("isBot")) t("Bot info") else t("User info")) else t("Info")) else if (s.store.chat(s.info.str())) |c| @import("infopanes.zig").title(s, c) else t("Info");
    ui.text(ptitle, .{ .font_size = 20, .weight = 750, .color = col.text, .grow = 1, .width = .fill, .max_lines = 1 });
    ui.end();
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 8, .end = 8, .bottom = 24 } }, key(.{"info"}));
    if (s.user_info.isSet()) {
        if (s.store.user(s.user_info.str())) |u| userCard(cx, u, null);
    } else if (s.store.chat(s.info.str())) |c| {
        const panes = @import("infopanes.zig");
        if (c.is("private") or c.is("bot")) {
            if (s.store.peer(c)) |u| userCard(cx, u, c);
        } else if (c.is("saved")) {
            panes.savedBody(cx, c);
        } else if (c.isTeamChat() and !s.store.isTeamStaff(c)) {
            panes.teamBody(cx, c);
        } else if (c.isTeamChat()) {
            // Team staff see the customer.
            if (s.store.user(j.strOr(c.o.v, "visitor.id", ""))) |u| userCard(cx, u, c);
        } else {
            vgroup.body(cx, c);
            @import("sharedmedia.zig").section(cx, c);
        }
    }
    ui.end();
    ui.end();
}

fn userCard(cx: Cx, u: *const data.Obj, c: ?*const data.Chat) void {
    return @import("userinfo.zig").card(cx, u, c);
}

// Loading pictures as messages are shown: views cannot fetch, so the chat asks after updates.
pub fn wantMedia(s: *app.State) void {
    if (!s.open_chat.isSet()) return;
    const tl = s.store.existingTimeline(s.open_chat.str()) orelse return;
    const items = tl.items.items;
    const from = if (items.len > s.show_count) items.len - s.show_count else 0;
    for (items[from..]) |m| {
        if (m.decrypt != .ok) continue;
        for (m.media()) |it| {
            const kind = j.strOr(it, "kind", "");
            if (!std.mem.eql(u8, kind, "photo") and !std.mem.eql(u8, kind, "gif")) continue;
            if (media.shown(s, it) == null) _ = media.file(s, it, false);
        }
    }
}

test {
    _ = calls;
}
