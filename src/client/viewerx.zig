//! The media viewer (Reseal-js viewer.js): every photo and video of the loaded chat in order,
//! Previous/Next with "i / n", who sent it and when, the caption, and Show in chat, Reply,
//! Forward, Download and Close.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const icons = @import("icons.zig");
const kit = @import("ui.zig");
const fmt = @import("fmt.zig");
const media = @import("media.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const Color = zui.Color;
const t = zui.i18n.t;
const key = kit.key;

pub const Act = union(enum) {
    go: i8,
    show_in_chat,
    reply,
    forward,
    /// A finger, the mouse or the wheel on the picture (zui.gesture).
    pointer: zui.Pointer,
    zoom,
};

/// Zoom and pan (viewer.js): pinch or the wheel zoom 1-5x, a double tap toggles 2.5x, a drag
/// moves a zoomed picture; unzoomed, a sideways swipe goes to the next or previous one and a
/// vertical one closes.
pub const Zoom = struct {
    gestures: zui.gesture.Recognizer = .{},
    scale: f32 = 1,
    x: f32 = 0,
    y: f32 = 0,
};

fn zoomTo(s: *State, z: f32) void {
    s.vzoom.scale = std.math.clamp(z, 1, 5);
    if (s.vzoom.scale == 1) {
        s.vzoom.x = 0;
        s.vzoom.y = 0;
    }
}

fn onPointer(p: zui.Pointer) Msg {
    return msgOf(.{ .pointer = p });
}

fn msgOf(a: Act) Msg {
    return .{ .viewer_x = a };
}

const Item = struct { msg: *data.Message, index: u8 };

fn visual(it: j.Value) bool {
    const k = j.strOr(it, "kind", "");
    return std.mem.eql(u8, k, "photo") or std.mem.eql(u8, k, "video") or std.mem.eql(u8, k, "gif");
}

/// The photos and videos of the open chat, oldest first, and where the viewer is among them.
fn list(s: *const State, a: std.mem.Allocator) struct { items: []Item, at: usize } {
    var out: std.ArrayList(Item) = .empty;
    var at: usize = 0;
    const v = s.viewer orelse return .{ .items = &.{}, .at = 0 };
    const tl = s.store.existingTimeline(s.open_chat.str()) orelse return .{ .items = &.{}, .at = 0 };
    for (tl.items.items) |m| {
        if (m.decrypt != .ok or m.local_id != 0) continue;
        for (m.media(), 0..) |it, i| {
            if (!visual(it) or i > 255) continue;
            if (m.local_id == 0 and v.msg.eql(m.id()) and v.index == i) at = out.items.len;
            out.append(a, .{ .msg = m, .index = @intCast(i) }) catch break;
        }
    }
    return .{ .items = out.items, .at = at };
}

pub fn act(s: *State, a: Act) void {
    const v = s.viewer orelse return;
    switch (a) {
        .zoom => zoomTo(s, if (s.vzoom.scale > 1) 1 else 2),
        .pointer => |p| {
            const z = &s.vzoom;
            switch (z.gestures.feed(p)) {
                .pinch => |g| {
                    zoomTo(s, z.scale * g.scale);
                    if (z.scale > 1) {
                        z.x += g.dx;
                        z.y += g.dy;
                    }
                },
                .wheel => |g| zoomTo(s, z.scale * (if (g.delta < 0) @as(f32, 1.15) else @as(f32, 1.0 / 1.15))),
                .double_tap => zoomTo(s, if (z.scale > 1) 1 else 2.5),
                .pan => |g| if (z.scale > 1) {
                    z.x += g.dx;
                    z.y += g.dy;
                },
                .swipe => |dir| if (z.scale == 1) switch (dir) {
                    .left => act(s, .{ .go = if (zui.i18n.isRtl()) -1 else 1 }),
                    .right => act(s, .{ .go = if (zui.i18n.isRtl()) 1 else -1 }),
                    .up, .down => s.viewer = null,
                },
                else => {},
            }
        },
        .go => |d| {
            const l = list(s, app.tmp());
            const n = @as(i64, @intCast(l.at)) + d;
            if (n < 0 or n >= l.items.len) return;
            const next = l.items[@intCast(n)];
            s.vzoom = .{};
            @import("views.zig").onUi(s, .{ .open_media = .{ .msg = Id.of(next.msg.id()), .index = next.index } });
        },
        .show_in_chat => {
            s.viewer = null;
            const tl = s.store.existingTimeline(s.open_chat.str()) orelse return;
            const m = tl.find(v.msg.str()) orelse return;
            @import("msgextras.zig").act(s, .{ .jump = .{ .msg = v.msg, .seq = m.seq() orelse 0 } });
        },
        .reply => {
            s.viewer = null;
            @import("views.zig").onUi(s, .{ .message_action = .{ .what = .reply, .msg = v.msg } });
        },
        .forward => {
            s.viewer = null;
            @import("fwdpick.zig").open(s, v.msg, false);
        },
    }
}

fn topButton(cx: Cx, ic: zui.Icon, msg: Msg) void {
    kit.iconButton(cx, ic, msg, .{ .color = cx.c.on_shade, .background = cx.c.on_shade.withAlpha(0.12) });
}

pub fn view(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const v = s.viewer orelse return;
    const c = s.store.chat(s.open_chat.str());
    const protected = if (c) |ch| ch.o.b("protectedContent") else false;
    const l = list(s, cx.a());
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 }, .background = cx.c.shade.withAlpha(0.95), .align_items = .center, .justify = .center }, .{});
    var shown_any = false;
    var failed = false;
    var current: ?*data.Message = null;
    if (s.store.existingTimeline(s.open_chat.str())) |tl| if (tl.find(v.msg.str())) |m| {
        current = m;
        const items = m.media();
        if (v.index < items.len) {
            const item = items[v.index];
            const w0: f32 = @floatFromInt(j.intOr(item, "w", 800));
            const h0: f32 = @floatFromInt(j.intOr(item, "h", 600));
            const scale = @min((cx.w - 40) / @max(1, w0), (cx.h - 180) / @max(1, h0), 1);
            const z = s.vzoom;
            const w = w0 * scale * z.scale;
            const h = h0 * scale * z.scale;
            // The whole screen hears the fingers; the picture sits in the middle, moved by the pan.
            ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 }, .clip = true }, .{ .on_pointer = onPointer, .key = key(.{"vstage"}) });
            const left = (cx.w - w) / 2 + (if (zui.i18n.isRtl()) -z.x else z.x);
            const top = (cx.h - h) / 2 + z.y;
            const at: zui.Style = .{ .position = .absolute, .inset = .{ .top = top, .start = left }, .width = .{ .px = w }, .height = .{ .px = h } };
            if (media.shown(s, item)) |f| {
                if (f.state == .ready) {
                    media.draw(ui, f, j.strOr(item, "id", ""), at, key(.{ "view", j.strOr(item, "id", "") }));
                    shown_any = true;
                } else if (f.state == .failed) failed = true;
            }
            if (!shown_any and !failed) if (j.str(item, "thumb")) |th| {
                var st = at;
                st.opacity = 0.6;
                ui.image(th, st, key(.{ "vthumb", j.strOr(item, "id", "") }));
                shown_any = true;
            };
            ui.end();
        }
    };
    if (failed) {
        ui.text(t("Could not load this file."), .{ .font_size = 16, .color = cx.c.on_shade, .opacity = 0.8, .line_height = 1.5 });
    } else if (!shown_any) kit.spinner(cx);

    // Top: who and when (and where in the list), then the actions.
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 12, .start = 14, .end = 14 }, .direction = .row, .align_items = .center, .gap = 8 }, .{});
    if (current) |m| {
        const sender = m.senderId();
        const name = if (sender.len > 0) s.store.displayName(sender) else if (c) |ch| s.store.title(ch) else "";
        const u = if (sender.len > 0) s.store.user(sender) else null;
        kit.avatar(cx, .{ .name = name, .color = if (u) |uu| uu.i("color") orelse 0 else 0, .image = if (u) |uu| uu.s("avatar") else null, .size = 36 }, key(.{"vwho"}));
        ui.begin(.{ .grow = 1, .width = .fill }, .{});
        ui.text(name, .{ .font_size = 14, .weight = 700, .color = cx.c.on_shade, .max_lines = 1 });
        const when = fmt.fullDate(cx.a(), m.at);
        const sub = if (l.items.len > 1) std.fmt.allocPrint(cx.a(), "{s} · {d} / {d}", .{ when, l.at + 1, l.items.len }) catch when else when;
        ui.text(sub, .{ .font_size = 12, .color = cx.c.on_shade, .opacity = 0.75, .max_lines = 1 });
        ui.end();
    } else {
        ui.begin(.{ .grow = 1 }, .{});
        ui.end();
    }
    topButton(cx, icons.chat, msgOf(.show_in_chat));
    topButton(cx, icons.reply, msgOf(.reply));
    if (!protected) {
        topButton(cx, icons.forward, msgOf(.forward));
        topButton(cx, icons.download, .{ .download = .{ .msg = v.msg, .index = v.index } });
    }
    topButton(cx, icons.zoomIn, msgOf(.zoom));
    topButton(cx, icons.close, .close_viewer);
    ui.end();

    // Previous and next.
    if (l.items.len > 1) {
        const rtl = zui.i18n.isRtl();
        if (l.at > 0) {
            ui.begin(.{ .position = .absolute, .inset = .{ .start = 10 } }, .{});
            topButton(cx, if (rtl) icons.chevronRight else icons.chevronLeft, msgOf(.{ .go = -1 }));
            ui.end();
        }
        if (l.at + 1 < l.items.len) {
            ui.begin(.{ .position = .absolute, .inset = .{ .end = 10 } }, .{});
            topButton(cx, if (rtl) icons.chevronLeft else icons.chevronRight, msgOf(.{ .go = 1 }));
            ui.end();
        }
    }
    // The caption.
    if (current) |m| if (m.text().len > 0) {
        ui.begin(.{ .position = .absolute, .inset = .{ .bottom = 18, .start = 16, .end = 16 }, .align_items = .center }, .{});
        ui.begin(.{ .padding = .xy(14, 8), .radius = 12, .background = cx.c.shade.withAlpha(0.5), .max_width = 640 }, .{});
        ui.text(m.text(), .{ .font_size = 14, .color = cx.c.on_shade, .line_height = 1.45, .max_lines = 4 });
        ui.end();
        ui.end();
    };
    ui.end();
}
