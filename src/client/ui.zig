//! Reseal's building blocks (Reseal-js ui/kit.js and the shared CSS components): avatars
//! (squircles with initials or a picture), buttons, icon buttons, list rows, switches, fields,
//! section titles, badges, empty states.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const fmt = @import("fmt.zig");
const media = @import("media.zig");

const Msg = app.Msg;
const Color = zui.Color;
pub const Ui = zui.Ui(Msg);
pub const Style = zui.Style;
pub const Icon = zui.Icon;

/// What every view function needs.
pub const Cx = struct {
    ui: *Ui,
    s: *const app.State,
    c: theme.Colors,
    /// One pane at a time with a tab bar (≤ 760 wide).
    phone: bool,
    w: f32,
    h: f32,
    fs: f32,

    pub fn t(cx: Cx, english: []const u8) []const u8 {
        _ = cx;
        return zui.i18n.t(english);
    }
    pub fn a(cx: Cx) std.mem.Allocator {
        return cx.ui.arena();
    }
};

pub fn key(parts: anytype) u64 {
    var h = std.hash.Wyhash.init(0);
    inline for (parts) |p| {
        switch (@typeInfo(@TypeOf(p))) {
            .int, .comptime_int => h.update(std.mem.asBytes(&@as(u64, @intCast(p)))),
            .pointer => h.update(p),
            else => h.update(std.mem.asBytes(&p)),
        }
    }
    return h.final();
}

// ---------------------------------------------------------------------------------------------
// Avatars

pub const AvatarOpts = struct {
    name: []const u8 = "?",
    color: i64 = 0,
    /// A media id (public: /m/<id>) or a full address.
    image: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    size: f32 = 48,
    icon: ?Icon = null,
    saved: bool = false,
    square: bool = false,
    online: ?bool = null,
};

pub fn avatar(cx: Cx, o: AvatarOpts, k: u64) void {
    const ui = cx.ui;
    const bg = if (o.saved) cx.c.brand else theme.avatarColor(o.color);
    const radius = o.size * if (o.square) @as(f32, 0.30) else 0.34;
    ui.begin(.{ .width = .{ .px = o.size }, .height = .{ .px = o.size }, .align_items = .center, .justify = .center }, .{ .key = k });
    ui.begin(.{ .width = .{ .px = o.size }, .height = .{ .px = o.size }, .background = bg, .radius = radius, .align_items = .center, .justify = .center, .clip = true }, .{});
    if (o.saved) {
        ui.icon(icons.bookmark, o.size * 0.48, Color.white, .{}, 0);
    } else if (o.icon) |ic| {
        ui.icon(ic, o.size * 0.48, Color.white, .{}, 0);
    } else {
        ui.text(fmt.initials(cx.a(), o.name), .{ .font_size = @round(o.size * 0.36), .weight = 650, .color = Color.white, .line_height = 1.1 });
    }
    const url = o.image_url orelse if (o.image) |id| (if (id.len > 0) media.mediaUrl(cx.a(), id) else null) else null;
    if (url) |u| ui.image(u, .{ .position = .absolute, .inset = .{ .top = 0, .start = 0 }, .width = .{ .px = o.size }, .height = .{ .px = o.size } }, key(.{ "av", u }));
    ui.end();
    if (o.online) |on| if (on) {
        const d = @max(12, o.size * 0.3);
        ui.begin(.{ .position = .absolute, .inset = .{ .bottom = -2, .end = -2 }, .width = .{ .px = d }, .height = .{ .px = d }, .radius = d / 2, .background = cx.c.online, .border_width = 3, .border_color = cx.c.surface }, .{});
        ui.end();
    };
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// Buttons

pub const ButtonKind = enum { primary, secondary, ghost, plain, danger, danger_ghost };

pub const ButtonOpts = struct {
    kind: ButtonKind = .primary,
    icon: ?Icon = null,
    large: bool = false,
    small: bool = false,
    block: bool = false,
    disabled: bool = false,
    busy: bool = false,
};

pub fn button(cx: Cx, label: []const u8, msg: Msg, o: ButtonOpts) void {
    const ui = cx.ui;
    const c = cx.c;
    const bg: ?Color, const fg: Color = switch (o.kind) {
        .primary => .{ c.brand, c.on_accent },
        .secondary => .{ c.accent_soft, c.accent },
        .ghost => .{ null, c.accent },
        .plain => .{ c.surface_2, c.text },
        .danger => .{ c.danger, Color.white },
        .danger_ghost => .{ null, c.danger },
    };
    const h: f32 = if (o.large) 52 else if (o.small) 34 else 44;
    ui.begin(.{
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .gap = 8,
        .height = .{ .px = h },
        .padding = .xy(if (o.small) 14 else 20, 0),
        .radius = if (o.large) 16 else if (o.small) 11 else theme.radius,
        .background = bg,
        .width = if (o.block) .fill else .auto,
        .align_self = if (o.block) .stretch else null,
        .opacity = if (o.disabled or o.busy) 0.5 else 1,
        .pressed_opacity = 0.85,
    }, .{ .on_press = if (o.disabled or o.busy) null else msg });
    if (o.icon) |ic| ui.icon(ic, 20, fg, .{}, 0);
    ui.text(if (o.busy) "…" else label, .{ .font_size = if (o.large) 16 else if (o.small) 14 else 15, .weight = 650, .color = fg, .max_lines = 1 });
    ui.end();
}

pub const IconButtonOpts = struct { size: f32 = 40, soft: bool = false, active: bool = false, color: ?Color = null, background: ?Color = null, icon_size: f32 = 22, rtl: ?Icon = null };

pub fn iconButton(cx: Cx, ic: Icon, msg: ?Msg, o: IconButtonOpts) void {
    const ui = cx.ui;
    const c = cx.c;
    const bg = o.background orelse if (o.active) c.accent_soft else if (o.soft) c.surface_2 else null;
    const fg = o.color orelse if (o.active) c.accent else if (o.soft) c.text else c.text_2;
    ui.begin(.{ .width = .{ .px = o.size }, .height = .{ .px = o.size }, .radius = if (o.size >= 48) 16 else if (o.size <= 32) 10 else 13, .background = bg, .align_items = .center, .justify = .center, .pressed_background = c.active }, .{ .on_press = msg });
    // Arrows point the other way in right-to-left languages.
    ui.icon(if (cx.s.lang == .ar) o.rtl orelse ic else ic, o.icon_size, fg, .{}, 0);
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// Lists

pub const RowOpts = struct {
    icon: ?Icon = null,
    subtitle: ?[]const u8 = null,
    value: ?[]const u8 = null,
    danger: bool = false,
    chevron: bool = false,
    on: ?Msg = null,
    switch_on: ?bool = null,
    k: u64 = 0,
};

/// A settings-style row: icon, title (and subtitle), value or switch.
pub fn row(cx: Cx, title: []const u8, o: RowOpts) void {
    const ui = cx.ui;
    const c = cx.c;
    const fg = if (o.danger) c.danger else c.text;
    // Title and its value/switch on one line, the explanation below at full width (zui measures a
    // row's children against the whole width, so wrapped text beside a value would be cut).
    ui.begin(.{ .gap = 2, .min_height = 52, .padding = .xy(12, 8), .radius = theme.radius, .pressed_background = c.active, .justify = .center }, .{ .on_press = o.on, .key = o.k });
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 14 }, .{});
    if (o.icon) |ic| {
        ui.begin(.{ .padding = .xy(3, 0) }, .{});
        ui.icon(ic, 22, if (o.danger) c.danger else c.text_2, .{}, 0);
        ui.end();
    }
    ui.text(title, .{ .font_size = 15, .weight = 550, .color = fg, .max_lines = 1, .grow = 1, .width = .fill });
    if (o.value) |v| ui.text(v, .{ .font_size = 14, .color = c.text_2, .max_lines = 1 });
    if (o.switch_on) |on| switchView(cx, on);
    if (o.chevron) ui.icon(if (cx.s.lang == .ar) icons.chevronRight_rtl else icons.chevronRight, 18, c.text_3, .{}, 0);
    ui.end();
    if (o.subtitle) |sub| {
        ui.begin(.{ .padding = .{ .start = if (o.icon != null) 42 else 0, .end = if (o.switch_on != null) 58 else 0 } }, .{});
        ui.text(sub, .{ .font_size = 13.5, .color = c.text_2, .line_height = 1.45 });
        ui.end();
    }
    ui.end();
}

pub fn switchView(cx: Cx, on: bool) void {
    const ui = cx.ui;
    const c = cx.c;
    ui.begin(.{ .width = .{ .px = 44 }, .height = .{ .px = 26 }, .radius = 13, .background = if (on) c.brand else c.surface_3, .border_width = if (on) 0 else 1, .border_color = c.border, .direction = .row, .align_items = .center, .padding = .xy(3, 0), .justify = if (on) .end else .start }, .{});
    ui.begin(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .radius = 10, .background = Color.white }, .{});
    ui.end();
    ui.end();
}

pub fn sectionTitle(cx: Cx, title: []const u8) void {
    cx.ui.begin(.{ .padding = .{ .top = 12, .bottom = 6, .start = 12, .end = 12 } }, .{});
    cx.ui.text(upper(cx.a(), title), .{ .font_size = 12, .weight = 700, .color = cx.c.text_3 });
    cx.ui.end();
}

pub fn sectionNote(cx: Cx, text: []const u8) void {
    cx.ui.begin(.{ .padding = .{ .top = 4, .bottom = 10, .start = 12, .end = 12 } }, .{});
    cx.ui.text(text, .{ .font_size = 13, .color = cx.c.text_2, .line_height = 1.55 });
    cx.ui.end();
}

fn upper(a: std.mem.Allocator, s: []const u8) []const u8 {
    const out = a.dupe(u8, s) catch return s;
    for (out) |*ch| ch.* = std.ascii.toUpper(ch.*);
    return out;
}

pub fn divider(cx: Cx) void {
    cx.ui.begin(.{ .height = .{ .px = 1 }, .background = cx.c.border, .width = .fill }, .{});
    cx.ui.end();
}

pub fn badge(cx: Cx, text: []const u8, muted: bool) void {
    const ui = cx.ui;
    ui.begin(.{ .min_width = 20, .height = .{ .px = 20 }, .padding = .xy(6, 0), .radius = 7, .background = if (muted) cx.c.surface_3 else cx.c.brand, .align_items = .center, .justify = .center }, .{});
    ui.text(text, .{ .font_size = 11.5, .weight = 700, .color = if (muted) cx.c.text_2 else cx.c.on_accent, .line_height = 1.2 });
    ui.end();
}

pub fn emptyState(cx: Cx, ic: Icon, title: []const u8, text: ?[]const u8) void {
    const ui = cx.ui;
    const c = cx.c;
    ui.begin(.{ .align_items = .center, .justify = .center, .gap = 10, .padding = .xy(24, 40), .width = .fill }, .{});
    ui.begin(.{ .width = .{ .px = 84 }, .height = .{ .px = 84 }, .radius = 28, .background = c.accent_soft, .align_items = .center, .justify = .center }, .{});
    ui.icon(ic, 38, c.accent, .{}, 0);
    ui.end();
    ui.text(title, .{ .font_size = 18, .weight = 700, .color = c.text, .text_align = .center });
    if (text) |tx| ui.text(tx, .{ .font_size = 14.5, .color = c.text_2, .text_align = .center, .max_width = 300, .line_height = 1.55 });
    ui.end();
}

pub fn spinner(cx: Cx) void {
    const ui = cx.ui;
    ui.begin(.{ .align_items = .center, .padding = .all(16), .width = .fill }, .{});
    // A ring with a gap (static: a turning one would redraw every frame).
    const r: f32 = 11;
    var pts: [40][2]f32 = undefined;
    for (0..pts.len) |i| {
        const ang = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(pts.len - 1)) * std.math.pi * 1.5;
        pts[i] = .{ 12 + r * @cos(ang), 12 + r * @sin(ang) };
    }
    const owned = ui.arena().dupe([2]f32, &pts) catch return;
    ui.path(owned, .{ .color = cx.c.accent, .width = 2.5 }, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 } }, 0);
    ui.end();
}

pub const FieldOpts = struct {
    placeholder: []const u8 = "",
    label: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    err: ?[]const u8 = null,
    k: u64 = 0,
    mono: bool = false,
    submit: ?Msg = null,
};

/// A labelled text input (.field / .input).
pub fn field(cx: Cx, comptime f: app.Field, o: FieldOpts) void {
    const ui = cx.ui;
    const c = cx.c;
    ui.begin(.{ .gap = 7, .padding = .{ .bottom = 16 }, .width = .fill }, .{});
    if (o.label) |l| ui.text(l, .{ .font_size = 13, .weight = 600, .color = c.text_2 });
    ui.begin(.{ .height = .{ .px = 46 }, .padding = .xy(14, 0), .radius = theme.radius, .border_width = 1, .border_color = if (o.err != null) c.danger else c.border_strong, .background = c.surface_2, .justify = .center, .width = .fill }, .{});
    ui.input(.{ .key = if (o.k != 0) o.k else zui.key(@tagName(f)), .value = cx.s.fields.get(f).get(), .placeholder = o.placeholder, .on_change = app.onField(f), .on_submit = o.submit orelse .{ .submit = f }, .style = .{ .width = .fill, .font_size = 15, .color = c.text, .mono = o.mono } });
    ui.end();
    if (o.err) |e| ui.text(e, .{ .font_size = 12.5, .color = c.danger });
    if (o.hint) |h| ui.text(h, .{ .font_size = 12.5, .color = c.text_3, .line_height = 1.45 });
    ui.end();
}

/// The search box (.search).
pub fn searchBox(cx: Cx, comptime f: app.Field, placeholder: []const u8) void {
    const ui = cx.ui;
    const c = cx.c;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 9, .height = .{ .px = 42 }, .padding = .xy(14, 0), .radius = 14, .background = c.surface_2, .grow = 1, .width = .fill }, .{ .key = zui.key("box-" ++ @tagName(f)) });
    ui.icon(icons.search, 18, c.text_3, .{}, 0);
    ui.input(.{ .key = zui.key(@tagName(f)), .value = cx.s.fields.get(f).get(), .placeholder = placeholder, .on_change = app.onField(f), .on_focus = if (f == .search) .{ .toggle_search = true } else null, .style = .{ .grow = 1, .width = .fill, .font_size = 15, .color = c.text } });
    ui.end();
}
