//! The composer's sheets (attach, send options, schedule, disappearing, poll, emoji, emoji
//! stickers, scheduled messages) and the bars above the input (@mention suggestions, the link
//! preview). The app's own chrome stays emoji-free: the picker's tabs are words; only the emoji
//! people send are emoji.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const fmt = @import("fmt.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");
const vchat = @import("view_chat.zig");
const compose = @import("compose.zig");
const emoji = @import("emoji_data.zig");

const Cx = kit.Cx;
const Msg = app.Msg;
const Id = app.Id;
const t = zui.i18n.t;
const key = kit.key;

fn act(a: compose.Act) Msg {
    return .{ .compose = a };
}

pub fn sheet(cx: Cx, which: compose.Sheet) void {
    switch (which) {
        .attach => attachSheet(cx),
        .options => optionsSheet(cx),
        .schedule => scheduleSheet(cx),
        .ttl => ttlSheet(cx),
        .poll => pollSheet(cx),
        .emoji => emojiSheet(cx),
        .sticker => stickerSheet(cx),
        .scheduled => scheduledSheet(cx),
    }
}

fn openChat(cx: Cx) ?*const data.Chat {
    return cx.s.store.chat(cx.s.open_chat.str());
}

fn attachSheet(cx: Cx) void {
    const s = cx.s;
    views.sheet(cx, t("Attach"));
    if (vchat.feature(s, "photos") or vchat.feature(s, "files")) {
        if (zui.platform != .web) views.menuItem(cx, icons.camera, t("Camera"), act(.take_photo), false);
        views.menuItem(cx, icons.image, if (zui.platform == .web) t("Photo or video") else t("Photo"), act(.pick_media), false);
    }
    if (vchat.feature(s, "files")) views.menuItem(cx, icons.file, t("File"), act(.pick_file), false);
    if (vchat.feature(s, "polls")) views.menuItem(cx, icons.poll, t("Poll"), act(.{ .open = .poll }), false);
    if (vchat.feature(s, "location")) views.menuItem(cx, icons.location, t("Location"), act(.location), false);
    views.menuItem(cx, icons.smile, t("Emoji"), act(.{ .open = .emoji }), false);
    views.menuItem(cx, icons.sticker, t("Stickers"), act(.{ .open = .sticker }), false);
    if (vchat.feature(s, "scheduled")) views.menuItem(cx, icons.calendar, t("Scheduled messages"), act(.{ .open = .scheduled }), false);
    views.endSheet(cx);
}

fn optionsSheet(cx: Cx) void {
    const s = cx.s;
    const c = openChat(cx) orelse return;
    views.sheet(cx, t("Send options"));
    if (!c.is("saved")) views.menuItem(cx, icons.bellOff, t("Send without sound"), act(.silent), false);
    if (vchat.feature(s, "scheduled")) {
        views.menuItem(cx, icons.calendar, if (c.is("saved")) t("Set a reminder") else t("Schedule message"), act(.{ .open = .schedule }), false);
        if (s.store.peer(c)) |p| if (!p.b("deleted") and std.mem.eql(u8, p.s("presence.status") orelse "", "offline"))
            views.menuItem(cx, icons.scheduleSend, t("Send when online"), act(.when_online), false);
    }
    if (vchat.feature(s, "selfDestruct") and !c.is("channel")) views.menuItem(cx, icons.timer, t("Send as disappearing…"), act(.{ .open = .ttl }), false);
    views.endSheet(cx);
}

fn scheduleSheet(cx: Cx) void {
    const s = cx.s;
    const c = openChat(cx) orelse return;
    const reminder = c.is("saved");
    views.sheet(cx, if (reminder) t("Set a reminder") else t("Schedule message"));
    for (compose.schedule_presets, 0..) |p, i| views.menuItem(cx, icons.clock, t(p.label), act(.{ .schedule_in = @intCast(i) }), false);
    kit.sectionTitle(cx, if (reminder) t("Remind me at") else t("Send at"));
    cx.ui.begin(.{ .padding = .xy(12, 0) }, .{});
    // The platform's own date and time pickers.
    const parts = compose.scheduleParts(s);
    cx.ui.begin(.{ .direction = .row, .gap = 8, .padding = .{ .bottom = 12 } }, .{});
    pickerButton(cx, icons.calendar, if (parts.date.len > 0) fmt.shortDate(cx.a(), compose.parseLocal(std.fmt.allocPrint(cx.a(), "{s} 12:00", .{parts.date}) catch "") orelse 0) else t("Date"), act(.pick_date));
    pickerButton(cx, icons.clock, if (parts.time.len > 0) parts.time else t("Time"), act(.pick_time));
    cx.ui.end();
    kit.button(cx, if (reminder) t("Set reminder") else t("Schedule"), act(.schedule_custom), .{ .block = true });
    cx.ui.end();
    views.endSheet(cx);
}

pub fn pickerButton(cx: Cx, ic: zui.Icon, label: []const u8, m: Msg) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .grow = 1, .width = .fill, .height = .{ .px = 46 }, .padding = .xy(14, 0), .radius = theme.radius, .border_width = 1, .border_color = cx.c.border_strong, .background = cx.c.surface_2, .pressed_background = cx.c.active }, .{ .on_press = m });
    ui.icon(ic, 18, cx.c.text_2, .{}, 0);
    ui.text(label, .{ .font_size = 15, .color = cx.c.text, .max_lines = 1 });
    ui.end();
}

fn ttlSheet(cx: Cx) void {
    views.sheet(cx, t("Send as disappearing…"));
    for (compose.ttl_presets) |p| views.menuItem(cx, icons.timer, fmt.tf("Disappear after {time}", .{ .time = t(p.label) }), act(.{ .ttl = p.seconds }), false);
    views.endSheet(cx);
}

fn pollSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const p = &s.compose;
    views.sheet(cx, if (p.poll_quiz) t("New quiz") else t("New poll"));
    ui.begin(.{ .padding = .{ .start = 12, .end = 12, .top = 4 } }, .{});
    kit.field(cx, .poll_question, .{ .label = t("Question"), .placeholder = t("Ask a question") });
    ui.text(t("Options"), .{ .font_size = 13, .weight = 600, .color = cx.c.text_2 });
    ui.begin(.{ .gap = 8, .padding = .{ .top = 7, .bottom = 8 } }, .{});
    inline for (compose.poll_fields, 0..) |f, i| {
        if (i < p.poll_options) {
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8 }, .{ .key = key(.{ "poll-row", i }) });
            if (p.poll_quiz) {
                const on = p.poll_correct == i;
                ui.begin(.{ .width = .{ .px = 26 }, .height = .{ .px = 26 }, .radius = 13, .border_width = 2, .border_color = if (on) cx.c.success else cx.c.border_strong, .background = if (on) cx.c.success else null, .align_items = .center, .justify = .center }, .{ .on_press = act(.{ .poll_correct = i }) });
                if (on) ui.icon(icons.check, 16, zui.Color.white, .{}, 0);
                ui.end();
            }
            ui.begin(.{ .grow = 1, .width = .fill, .height = .{ .px = 44 }, .padding = .xy(14, 0), .radius = theme.radius, .border_width = 1, .border_color = cx.c.border_strong, .background = cx.c.surface_2, .justify = .center }, .{});
            ui.input(.{ .key = zui.key(@tagName(f)), .value = s.fields.get(f).get(), .placeholder = fmt.tf("Option {n}", .{ .n = @as(i64, i + 1) }), .on_change = app.onField(f), .on_submit = act(.poll_more), .style = .{ .width = .fill, .font_size = 15, .color = cx.c.text } });
            ui.end();
            ui.end();
        }
    }
    ui.end();
    ui.begin(.{ .direction = .row, .gap = 8 }, .{});
    if (p.poll_options < compose.poll_fields.len) kit.button(cx, t("Add an option"), act(.poll_more), .{ .small = true, .kind = .secondary, .icon = icons.plus });
    if (p.poll_options > 2) kit.button(cx, t("Remove"), act(.poll_less), .{ .small = true, .kind = .ghost, .icon = icons.minus });
    ui.end();
    ui.end();
    kit.row(cx, t("Anonymous voting"), .{ .switch_on = p.poll_anonymous, .on = act(.{ .poll_toggle = .anonymous }) });
    if (!p.poll_quiz) kit.row(cx, t("Multiple answers"), .{ .switch_on = p.poll_multiple, .on = act(.{ .poll_toggle = .multiple }) });
    kit.row(cx, t("Quiz mode"), .{ .switch_on = p.poll_quiz, .on = act(.{ .poll_toggle = .quiz }), .subtitle = t("One answer is correct. Tap the circle next to it.") });
    ui.begin(.{ .padding = .{ .start = 12, .end = 12, .top = 8 } }, .{});
    if (p.poll_quiz) kit.field(cx, .poll_explanation, .{ .label = t("Explanation"), .placeholder = t("Shown after answering (optional)") });
    kit.button(cx, t("Send"), act(.poll_send), .{ .block = true, .large = true });
    ui.end();
    views.endSheet(cx);
}

// ---------------------------------------------------------------------------------------------
// Emoji

const per_row = 8;

fn emojiSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, t("Emoji"));
    ui.begin(.{ .padding = .{ .start = 4, .end = 4, .bottom = 8 } }, .{});
    kit.searchBox(cx, .emoji_search, t("Search emoji"));
    ui.end();
    const q = s.fields.get(.emoji_search).trimmed();
    if (q.len > 0) {
        const found = compose.search(cx.a(), q);
        if (found.len == 0) {
            kit.sectionNote(cx, t("No emoji found"));
        } else {
            var list: std.ArrayList([]const u8) = .empty;
            for (found) |i| list.append(cx.a(), emoji.keywords[i].emoji) catch {};
            grid(cx, list.items, 254, found);
        }
        views.endSheet(cx);
        return;
    }
    // Tabs: words, not emoji.
    ui.begin(.{ .direction = .row, .gap = 6, .padding = .{ .bottom = 8 } }, .{});
    tab(cx, t("Recent"), 255);
    ui.end();
    var row: usize = 0;
    while (row * 4 < emoji.categories.len) : (row += 1) {
        ui.begin(.{ .direction = .row, .gap = 6, .padding = .{ .bottom = 6 } }, .{ .key = key(.{ "tabs", row }) });
        for (emoji.categories[row * 4 .. @min(row * 4 + 4, emoji.categories.len)], row * 4..) |c, i| tab(cx, t(c.name), @intCast(i));
        ui.end();
    }
    const cat = s.compose.emoji_tab;
    if (cat == 255) {
        var list: std.ArrayList([]const u8) = .empty;
        for (s.compose.recent.items) |e| list.append(cx.a(), e) catch {};
        grid(cx, list.items, 255, null);
    } else if (cat < emoji.categories.len) {
        grid(cx, emoji.categories[cat].list, cat, null);
    }
    views.endSheet(cx);
}

fn tab(cx: Cx, label: []const u8, i: u8) void {
    const on = cx.s.compose.emoji_tab == i;
    cx.ui.begin(.{ .padding = .xy(11, 6), .radius = 10, .background = if (on) cx.c.accent_soft else cx.c.surface_2, .pressed_opacity = 0.8 }, .{ .on_press = act(.{ .emoji_tab = i }), .key = key(.{ "tab", i }) });
    cx.ui.text(label, .{ .font_size = 12.5, .weight = 650, .color = if (on) cx.c.accent else cx.c.text_2, .max_lines = 1 });
    cx.ui.end();
}

fn grid(cx: Cx, list: []const []const u8, cat: u8, index: ?[]const u16) void {
    const ui = cx.ui;
    var i: usize = 0;
    while (i < list.len) : (i += per_row) {
        ui.begin(.{ .direction = .row, .justify = .start }, .{ .key = key(.{ "erow", cat, i }) });
        for (list[i..@min(i + per_row, list.len)], i..) |e, k| {
            const idx: u16 = if (index) |ix| ix[k] else @intCast(k);
            ui.begin(.{ .width = .{ .px = 46 }, .height = .{ .px = 46 }, .radius = 12, .align_items = .center, .justify = .center, .pressed_background = cx.c.hover }, .{ .on_press = act(.{ .emoji = .{ .cat = cat, .i = idx } }) });
            ui.text(e, .{ .font_size = 27, .line_height = 1.1 });
            ui.end();
        }
        ui.end();
    }
}

fn stickerSheet(cx: Cx) void {
    const ui = cx.ui;
    views.sheet(cx, t("Stickers"));
    const n = 4;
    var i: usize = 0;
    while (i < emoji.stickers.len) : (i += n) {
        ui.begin(.{ .direction = .row, .justify = .center, .gap = 6 }, .{ .key = key(.{ "srow", i }) });
        for (emoji.stickers[i..@min(i + n, emoji.stickers.len)], i..) |e, k| {
            ui.begin(.{ .width = .{ .px = 88 }, .height = .{ .px = 88 }, .radius = 18, .align_items = .center, .justify = .center, .pressed_background = cx.c.hover }, .{ .on_press = act(.{ .sticker = @intCast(k) }) });
            ui.text(e, .{ .font_size = 56, .line_height = 1.1 });
            ui.end();
        }
        ui.end();
    }
    views.endSheet(cx);
}

// ---------------------------------------------------------------------------------------------
// Scheduled messages

fn scheduledSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, t("Scheduled messages"));
    const list = if (s.compose.scheduled) |o| j.arr(o.v, "messages") else &.{};
    if (s.compose.scheduled == null) {
        kit.spinner(cx);
    } else if (list.len == 0) {
        kit.emptyState(cx, icons.calendar, t("No scheduled messages"), t("Choose \"Schedule message\" in the send options."));
    }
    for (list) |m| {
        const id = j.strOr(m, "id", "");
        const at = sys_parse(j.strOr(m, "scheduledAt", ""));
        const when = if (j.truthy(m, "whenOnline")) t("When online") else if (at) |ms| fmt.fullDate(cx.a(), ms) else "";
        ui.begin(.{ .gap = 6, .padding = .xy(12, 10), .radius = theme.radius, .background = cx.c.surface_2 }, .{ .key = key(.{ "sched", id }) });
        ui.text(when, .{ .font_size = 12.5, .weight = 650, .color = cx.c.accent });
        ui.text(scheduledLine(cx, m), .{ .font_size = 14.5, .color = cx.c.text, .max_lines = 3 });
        ui.begin(.{ .direction = .row, .gap = 8 }, .{});
        kit.button(cx, t("Send now"), act(.{ .scheduled_send = Id.of(id) }), .{ .small = true, .kind = .secondary });
        kit.button(cx, t("Delete"), act(.{ .scheduled_delete = Id.of(id) }), .{ .small = true, .kind = .danger_ghost });
        ui.end();
        ui.end();
        ui.begin(.{ .height = .{ .px = 8 } }, .{});
        ui.end();
    }
    views.endSheet(cx);
}

fn sys_parse(iso: []const u8) ?i64 {
    return @import("sys.zig").parseIso(iso);
}

fn scheduledLine(cx: Cx, m: j.Value) []const u8 {
    if (j.str(m, "text")) |tx| if (tx.len > 0) return tx;
    _ = cx;
    if (j.obj(m, "enc") != null) return t("Encrypted message");
    if (j.obj(m, "poll") != null) return t("Poll");
    return t("Message");
}

// ---------------------------------------------------------------------------------------------
// Above the input

/// The @mention suggestions and the link preview, inside the composer box.
pub fn bars(cx: Cx, c: *const data.Chat) void {
    mentionBar(cx, c);
    previewBar(cx);
}

fn mentionBar(cx: Cx, c: *const data.Chat) void {
    const s = cx.s;
    const ui = cx.ui;
    if (c.is("private") or c.is("saved")) return;
    const q = compose.mentionQuery(s) orelse return;
    const members = if (s.members) |m| (if (s.members_chat.eql(c.id())) j.arr(m.v, "members") else &.{}) else &.{};
    var shown: usize = 0;
    for (members) |mb| {
        const u = j.obj(mb, "user") orelse continue;
        const uid = j.strOr(u, "id", "");
        if (std.mem.eql(u8, s.store.myId(), uid)) continue;
        const un = j.strOr(u, "username", "");
        const name = j.strOr(u, "name", un);
        if (q.len > 0 and !std.ascii.startsWithIgnoreCase(un, q) and !std.ascii.startsWithIgnoreCase(name, q)) continue;
        if (shown == 0) ui.begin(.{ .padding = .{ .top = 6, .start = 6, .end = 6 } }, .{ .key = zui.key("mentions") });
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .padding = .xy(8, 5), .radius = 12, .pressed_background = cx.c.hover }, .{ .on_press = act(.{ .mention = Id.of(uid) }), .key = key(.{ "mention", uid }) });
        kit.avatar(cx, .{ .name = name, .color = j.intOr(u, "color", 0), .image = j.str(u, "avatar"), .size = 30 }, key(.{ "mav", uid }));
        ui.text(name, .{ .font_size = 14, .weight = 600, .color = cx.c.text, .max_lines = 1 });
        if (un.len > 0) ui.text(std.fmt.allocPrint(cx.a(), "@{s}", .{un}) catch "", .{ .font_size = 13, .color = cx.c.text_3, .max_lines = 1 });
        ui.end();
        shown += 1;
        if (shown >= 5) break;
    }
    if (shown > 0) ui.end();
}

fn previewBar(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const p = s.compose.preview orelse return;
    if (s.editing.isSet()) return;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .padding = .{ .top = 9, .bottom = 2, .start = 14, .end = 8 } }, .{ .key = zui.key("link-preview") });
    ui.icon(icons.link, 20, cx.c.accent, .{}, 0);
    ui.begin(.{ .grow = 1, .width = .fill, .padding = .{ .start = 9 } }, .{});
    ui.text(p.s("title") orelse p.s("siteName") orelse p.s("url") orelse "", .{ .font_size = 13, .weight = 700, .color = cx.c.accent, .max_lines = 1 });
    ui.text(p.s("description") orelse p.s("url") orelse "", .{ .font_size = 13.5, .color = cx.c.text_2, .max_lines = 1 });
    ui.end();
    kit.iconButton(cx, icons.close, act(.dismiss_preview), .{ .size = 32 });
    ui.end();
}
