//! The call screen and the incoming-call banner (Reseal-js ui/calls.js and app.css .call-*).
//! Video comes through zui's ui.video; where the device cannot do calls yet, the screen says so.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const icons = @import("icons.zig");
const fmt = @import("fmt.zig");
const kit = @import("ui.zig");
const calls = @import("calls.zig");

const Cx = kit.Cx;
const Msg = app.Msg;
const Color = zui.Color;
const t = zui.i18n.t;
const key = kit.key;

const stage_bg = Color.hex("#0a0b14");

pub fn overlay(cx: Cx) void {
    const s = cx.s;
    if (s.call.status != .idle) callScreen(cx);
    if (s.call.incoming != null) incoming(cx);
}

fn callButton(cx: Cx, ic: zui.Icon, label: []const u8, msg: Msg, kind: enum { normal, on, danger, accept }) void {
    const ui = cx.ui;
    const bg = switch (kind) {
        .normal => Color.hex("#ffffff1f"),
        .on => Color.white,
        .danger => cx.c.danger,
        .accept => cx.c.success,
    };
    ui.begin(.{ .width = .{ .px = if (cx.phone) 60 else 70 }, .align_items = .center, .gap = 8 }, .{ .on_press = msg, .key = key(.{ "cb", label }) });
    ui.begin(.{ .width = .{ .px = 60 }, .height = .{ .px = 60 }, .radius = 21, .background = bg, .align_items = .center, .justify = .center }, .{});
    ui.icon(ic, 24, if (kind == .on) Color.hex("#12141c") else Color.white, .{}, 0);
    ui.end();
    ui.text(label, .{ .font_size = 12.5, .weight = 600, .color = Color.hex("#ffffffd9"), .text_align = .center, .max_lines = 1 });
    ui.end();
}

fn callScreen(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const c = &s.call;
    const ch = s.store.chat(c.chat.str());
    if (c.minimized) {
        ui.begin(.{ .position = .absolute, .inset = .{ .bottom = 20, .end = 20 }, .width = .{ .px = 260 }, .direction = .row, .align_items = .center, .gap = 10, .padding = .all(12), .radius = 20, .background = stage_bg }, .{ .on_press = .{ .call = .minimize } });
        ui.icon(icons.phone, 20, cx.c.success, .{}, 0);
        ui.begin(.{ .grow = 1, .width = .fill }, .{});
        ui.text(calls.title(s), .{ .font_size = 14, .weight = 650, .color = Color.white, .max_lines = 1 });
        ui.text(calls.statusText(s), .{ .font_size = 12, .color = Color.hex("#ffffffcc") });
        ui.end();
        ui.end();
        return;
    }
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 }, .background = stage_bg }, .{});
    // Stage: the other person's video, or their picture and the status.
    var remote_shown = false;
    if (!c.group) if (c.peers.items.len > 0) {
        const p = c.peers.items[0];
        if (p.remote != 0 and p.media.video) {
            ui.video(p.remote, .{ .cover = false }, .{ .position = .absolute, .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 } }, key(.{ "rv", p.conn.str() }));
            remote_shown = true;
        }
    };
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .padding = .xy(18, 16) }, .{});
    kit.iconButton(cx, icons.minimize, .{ .call = .minimize }, .{ .color = Color.hex("#ffffffd9"), .background = Color.hex("#ffffff14") });
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    ui.end();
    if (c.emoji.get().len > 0) {
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 6, .padding = .xy(12, 6), .radius = 12, .background = Color.hex("#ffffff1a") }, .{});
        ui.icon(if (c.unverified) icons.alert else icons.lock, 14, Color.white, .{}, 0);
        ui.text(c.emoji.get(), .{ .font_size = 15, .line_height = 1.2 });
        ui.end();
    }
    if (ch != null and !c.group) kit.iconButton(cx, icons.chat, .{ .call = .open_chat }, .{ .color = Color.hex("#ffffffd9"), .background = Color.hex("#ffffff14") });
    ui.end();
    ui.begin(.{ .grow = 1, .width = .fill, .height = .fill, .align_items = .center, .justify = .center }, .{});
    if (c.group) {
        groupGrid(cx);
    } else if (!remote_shown) {
        ui.begin(.{ .align_items = .center, .gap = 14 }, .{});
        if (ch) |cc| {
            const vlist = @import("view_list.zig");
            vlist.chatAvatar(cx, cc, 136);
        }
        ui.text(calls.title(s), .{ .font_size = 28, .weight = 800, .color = Color.white, .text_align = .center });
        ui.text(calls.statusText(s), .{ .font_size = 15, .color = Color.hex("#ffffffbf"), .text_align = .center, .max_width = 320 });
        if (c.peers.items.len > 0 and !c.peers.items[0].media.audio) {
            ui.begin(.{ .direction = .row, .gap = 6, .align_items = .center, .opacity = 0.8 }, .{});
            ui.icon(icons.micOff, 18, Color.white, .{}, 0);
            ui.text(t("Microphone off"), .{ .font_size = 14, .color = Color.white });
            ui.end();
        }
        ui.end();
    }
    ui.end();
    // My camera, small in the corner.
    if (c.local != 0 and (c.camera_on or c.screen_on) and !c.group) {
        ui.begin(.{ .position = .absolute, .inset = .{ .bottom = if (cx.phone) 140 else 120, .end = 22 }, .width = .{ .px = if (cx.phone) 120 else 210 }, .height = .{ .px = if (cx.phone) 90 else 158 }, .radius = 20, .clip = true, .background = Color.hex("#111111") }, .{});
        ui.video(if (c.screen_on) c.screen else c.local, .{ .mirror = !c.screen_on, .cover = true }, .{ .width = .fill, .height = .fill }, key(.{"lv"}));
        ui.end();
    }
    // Controls
    ui.begin(.{ .direction = .row, .justify = .center, .gap = if (cx.phone) 8 else 16, .padding = .{ .top = 18, .bottom = 34, .start = 16, .end = 16 } }, .{});
    if (c.status == .ended or c.status == .unavailable) {
        callButton(cx, icons.close, t("Close"), .{ .call = .{ .dismiss = c.seq } }, .normal);
    } else {
        callButton(cx, if (c.muted) icons.micOff else icons.mic, if (c.muted) t("Unmute") else t("Mute"), .{ .call = .mute }, if (c.muted) .on else .normal);
        callButton(cx, if (c.camera_on) icons.video else icons.videoOff, t("Camera"), .{ .call = .camera }, if (c.camera_on) .on else .normal);
        if (zui.platform == .web and !cx.phone) callButton(cx, if (c.screen_on) icons.screenOff else icons.screen, t("Screen"), .{ .call = .screen }, if (c.screen_on) .on else .normal);
        if (zui.platform != .web or cx.phone) callButton(cx, icons.cameraSwitch, t("Flip"), .{ .call = .switch_camera }, .normal);
        if (c.group) callButton(cx, icons.hand, if (c.hand) t("Lower hand") else t("Raise hand"), .{ .call = .hand }, if (c.hand) .on else .normal);
        callButton(cx, icons.phoneOff, if (c.group) t("Leave") else t("End"), .{ .call = .hangup }, .danger);
    }
    ui.end();
    ui.end();
}

fn groupGrid(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const c = &s.call;
    const n = c.peers.items.len + 1;
    const cols: usize = if (n <= 1) 1 else if (n <= 4) 2 else if (n <= 9) 3 else 4;
    const use_cols = if (cx.phone) @min(cols, 2) else cols;
    const tile_w = (cx.w - 36 - 10 * @as(f32, @floatFromInt(use_cols - 1))) / @as(f32, @floatFromInt(use_cols));
    const tile_h = @min(tile_w * 0.75, 320);
    ui.begin(.{ .width = .fill, .padding = .xy(18, 0), .gap = 10 }, .{});
    var i: usize = 0;
    while (i < n) {
        ui.begin(.{ .direction = .row, .gap = 10, .justify = .center }, .{});
        var k: usize = 0;
        while (k < use_cols and i < n) : (k += 1) {
            if (i == 0) {
                const me = s.store.me;
                tile(cx, if (me) |m| m.s("displayName") orelse "" else "", if (me) |m| m.i("color") orelse 0 else 0, if (c.camera_on or c.screen_on) (if (c.screen_on) c.screen else c.local) else 0, !c.muted, true, c.hand, tile_w, tile_h, "self");
            } else {
                const p = c.peers.items[i - 1];
                tile(cx, s.store.displayName(p.user.str()), if (s.store.user(p.user.str())) |u| u.i("color") orelse 0 else 0, if (p.media.video) p.remote else 0, p.media.audio, false, p.hand, tile_w, tile_h, p.conn.str());
            }
            i += 1;
        }
        ui.end();
    }
    ui.end();
    if (c.status == .active and c.peers.items.len == 0) {
        ui.begin(.{ .padding = .{ .top = 20 } }, .{});
        ui.text(t("Waiting for others to join…"), .{ .font_size = 15, .color = Color.hex("#ffffffbf") });
        ui.end();
    }
}

fn tile(cx: Cx, name: []const u8, color: i64, stream: u32, audio: bool, self: bool, hand: bool, w: f32, h: f32, k: []const u8) void {
    const ui = cx.ui;
    ui.begin(.{ .width = .{ .px = w }, .height = .{ .px = h }, .radius = 22, .clip = true, .background = Color.hex("#ffffff0f"), .align_items = .center, .justify = .center }, .{ .key = key(.{ "tile", k }) });
    if (stream != 0) {
        ui.video(stream, .{ .mirror = self, .cover = true }, .{ .position = .absolute, .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 } }, key(.{ "tv", k }));
    } else kit.avatar(cx, .{ .name = name, .color = color, .size = 84 }, 0);
    ui.begin(.{ .position = .absolute, .inset = .{ .bottom = 10, .start = 12 }, .direction = .row, .align_items = .center, .gap = 6, .padding = .xy(11, 4), .radius = 11, .background = Color.hex("#00000073") }, .{});
    if (!audio) ui.icon(icons.micOff, 15, Color.white, .{}, 0);
    ui.text(if (self) t("You") else name, .{ .font_size = 13, .weight = 650, .color = Color.white, .max_lines = 1 });
    ui.end();
    if (hand) {
        ui.begin(.{ .position = .absolute, .inset = .{ .top = 10, .end = 12 } }, .{});
        ui.text("✋", .{ .font_size = 22 });
        ui.end();
    }
    ui.end();
}

/// The ringing banner at the top (the phones also show their own call screen).
fn incoming(cx: Cx) void {
    const ui = cx.ui;
    const inc = cx.s.call.incoming.?;
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 18, .start = 0, .end = 0 }, .align_items = .center, .padding = .xy(12, 0) }, .{});
    ui.begin(.{ .width = .fill, .max_width = 380, .direction = .row, .align_items = .center, .gap = 12, .padding = .{ .top = 12, .bottom = 12, .start = 14, .end = 12 }, .radius = 24, .background = Color.hex("#10121cf0") }, .{});
    kit.avatar(cx, .{ .name = inc.name.get(), .image = if (inc.avatar.isSet()) inc.avatar.str() else null, .size = 48, .color = if (cx.s.store.user(inc.from.str())) |u| u.i("color") orelse 0 else 0 }, 0);
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    ui.text(inc.name.get(), .{ .font_size = 15, .weight = 750, .color = Color.white, .max_lines = 1 });
    ui.text(if (inc.video) t("Incoming video call") else t("Incoming voice call"), .{ .font_size = 13, .color = Color.hex("#ffffffbf") });
    ui.end();
    round(cx, icons.phoneOff, cx.c.danger, .{ .call = .decline });
    if (inc.video) round(cx, icons.video, cx.c.success, .{ .call = .{ .accept = true } });
    round(cx, icons.phone, cx.c.success, .{ .call = .{ .accept = false } });
    ui.end();
    ui.end();
}

fn round(cx: Cx, ic: zui.Icon, bg: Color, msg: Msg) void {
    cx.ui.begin(.{ .width = .{ .px = 46 }, .height = .{ .px = 46 }, .radius = 16, .background = bg, .align_items = .center, .justify = .center }, .{ .on_press = msg });
    cx.ui.icon(ic, 22, Color.white, .{}, 0);
    cx.ui.end();
}
