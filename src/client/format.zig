//! Formatting in the composer (Reseal-js composer.js): a bar over a selection with Bold, Italic,
//! Underline, Strikethrough, Monospace, Spoiler and Link; the same as shortcuts (Ctrl/Command+B,
//! I, U; +Shift+X, M, P; K for a link). The text gets the composer's Markdown marks (**, __, ++,
//! ~~, `, ||, [label](url)), which are sent as entities.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const icons = @import("icons.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");

const State = app.State;
const Cx = kit.Cx;
const Msg = app.Msg;
const t = zui.i18n.t;
const tmp = app.tmp;
const key = kit.key;

pub const Mark = enum { bold, italic, underline, strike, mono, spoiler };

fn marks(m: Mark) []const u8 {
    return switch (m) {
        .bold => "**",
        .italic => "__",
        .underline => "++",
        .strike => "~~",
        .mono => "`",
        .spoiler => "||",
    };
}

pub const Format = struct {
    /// The composer's selection, as it last told.
    sel: zui.Selection = .{ .start = 0, .end = 0 },
    /// The composer has the keyboard.
    focused: bool = false,
    /// What the link prompt replaces.
    link_sel: zui.Selection = .{ .start = 0, .end = 0 },
    link_error: bool = false,
};

pub const Act = union(enum) {
    selected: zui.Selection,
    focus: bool,
    wrap: Mark,
    link_open,
    link_add,
};

fn msgOf(a: Act) Msg {
    return .{ .format = a };
}

pub fn onSelect(sel: zui.Selection) Msg {
    return msgOf(.{ .selected = sel });
}

const composer_key = zui.key("composer");

fn current(s: *State) zui.Selection {
    const text = s.fields.get(.composer).get();
    var sel = app.fx.selection(composer_key) orelse s.fmt.sel;
    sel.start = @min(sel.start, @as(u32, @intCast(text.len)));
    sel.end = @min(@max(sel.end, sel.start), @as(u32, @intCast(text.len)));
    return sel;
}

fn setText(s: *State, text: []const u8, sel: zui.Selection) void {
    s.fields.getPtr(.composer).set(text);
    @import("drafts.zig").typed(s);
    app.fx.selectText(composer_key, sel);
    s.fmt.sel = sel;
}

pub fn act(s: *State, a: Act) void {
    const f = &s.fmt;
    switch (a) {
        .selected => |sel| f.sel = sel,
        .focus => |on| f.focused = on,
        .wrap => |m| {
            const text = s.fields.get(.composer).get();
            const sel = current(s);
            const mk = marks(m);
            const out = std.fmt.allocPrint(tmp(), "{s}{s}{s}{s}{s}", .{ text[0..sel.start], mk, text[sel.start..sel.end], mk, text[sel.end..] }) catch return;
            const n: u32 = @intCast(mk.len);
            setText(s, out, .{ .start = sel.start + n, .end = sel.end + n });
        },
        .link_open => {
            f.link_sel = current(s);
            f.link_error = false;
            s.fields.getPtr(.link_url).set("https://");
            s.modal = .link_prompt;
        },
        .link_add => {
            const url = std.mem.trim(u8, s.fields.get(.link_url).get(), " ");
            const ok = (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) and url.len > 8 and std.mem.indexOfAny(u8, url, " \n") == null;
            if (!ok) {
                f.link_error = true;
                return;
            }
            s.modal = null;
            const text = s.fields.get(.composer).get();
            const sel = f.link_sel;
            const st = @min(sel.start, @as(u32, @intCast(text.len)));
            const en = @min(@max(sel.end, st), @as(u32, @intCast(text.len)));
            const label = if (en > st) text[st..en] else "link";
            const out = std.fmt.allocPrint(tmp(), "{s}[{s}]({s}){s}", .{ text[0..st], label, url, text[en..] }) catch return;
            const end: u32 = st + @as(u32, @intCast(label.len + url.len + 4));
            setText(s, out, .{ .start = end, .end = end });
        },
    }
}

/// Ctrl/Command shortcuts while the composer has the keyboard (keyboard.zig).
pub fn shortcut(letter: u8, shift: bool) ?Act {
    return switch (letter) {
        'b' => if (!shift) .{ .wrap = .bold } else null,
        'i' => if (!shift) .{ .wrap = .italic } else null,
        'u' => if (!shift) .{ .wrap = .underline } else null,
        'x' => if (shift) .{ .wrap = .strike } else null,
        'm' => if (shift) .{ .wrap = .mono } else null,
        'p' => if (shift) .{ .wrap = .spoiler } else null,
        'k' => if (!shift) .link_open else null,
        else => null,
    };
}

/// The bar over a selection in the composer.
pub fn bar(cx: Cx) void {
    const s = cx.s;
    if (!s.fmt.focused or s.fmt.sel.end <= s.fmt.sel.start) return;
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .gap = 2, .padding = .{ .top = 6, .start = 6, .end = 6 } }, .{ .key = zui.key("format-bar") });
    const items = [_]struct { zui.Icon, []const u8, Act }{
        .{ icons.bold, t("Bold"), .{ .wrap = .bold } },
        .{ icons.italic, t("Italic"), .{ .wrap = .italic } },
        .{ icons.underline, t("Underline"), .{ .wrap = .underline } },
        .{ icons.strike, t("Strikethrough"), .{ .wrap = .strike } },
        .{ icons.mono, t("Monospace"), .{ .wrap = .mono } },
        .{ icons.spoiler, t("Spoiler"), .{ .wrap = .spoiler } },
        .{ icons.link, t("Link"), .link_open },
    };
    for (items) |it| kit.iconButton(cx, it[0], msgOf(it[2]), .{ .size = 34, .icon_size = 18, .label = it[1] });
    ui.end();
}

pub fn linkSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, t("Add link"));
    ui.begin(.{ .padding = .xy(12, 6), .gap = 8 }, .{});
    kit.field(cx, .link_url, .{ .label = t("URL"), .placeholder = "https://", .err = if (s.fmt.link_error) t("Enter a full link starting with https://") else null, .submit = msgOf(.link_add) });
    ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .top = 4, .bottom = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, t("Add"), msgOf(.link_add), .{});
    ui.end();
    ui.end();
    views.endSheet(cx);
}

test "shortcut letters" {
    try std.testing.expectEqual(Act{ .wrap = .bold }, shortcut('b', false).?);
    try std.testing.expectEqual(Act{ .wrap = .spoiler }, shortcut('p', true).?);
    try std.testing.expect(shortcut('c', false) == null);
}
