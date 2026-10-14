//! The call's Devices menu (Reseal-js calls.js devicesMenu): microphones, cameras and where the
//! sound plays (earpiece, loudspeaker, a headset), the one in use ticked; Open chat in a
//! one-to-one call. zui lists and switches them (fx.mediaDevices, fx.useMediaDevice).

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
const gpa = app.gpa;
const key = kit.key;

const Device = struct { kind: zui.MediaDevice.Kind, id: []u8, label: []u8, type: []u8, current: bool };

pub const Devices = struct {
    list: std.ArrayList(Device) = .empty,
    loaded: bool = false,

    fn clear(d: *Devices) void {
        for (d.list.items) |x| {
            gpa.free(x.id);
            gpa.free(x.label);
            gpa.free(x.type);
        }
        d.list.clearRetainingCapacity();
    }
};

pub const Act = union(enum) {
    open,
    got: []const zui.MediaDevice,
    use: u8,
};

fn msgOf(a: Act) Msg {
    return .{ .call_devices = a };
}

fn onDevices(list: []const zui.MediaDevice) Msg {
    return msgOf(.{ .got = list });
}

pub fn act(s: *State, a: Act) void {
    const d = &s.call_devices;
    switch (a) {
        .open => {
            d.loaded = false;
            s.modal = .{ .menu = .{ .kind = .call_devices } };
            app.fx.mediaDevices(s.call.local, onDevices);
        },
        .got => |list| {
            d.clear();
            for (list) |x| d.list.append(gpa, .{
                .kind = x.kind,
                .id = gpa.dupe(u8, x.id) catch continue,
                .label = gpa.dupe(u8, x.label) catch continue,
                .type = gpa.dupe(u8, x.type) catch continue,
                .current = x.current,
            }) catch {};
            d.loaded = true;
        },
        .use => |i| {
            if (i >= d.list.items.len) return;
            const x = d.list.items[i];
            app.fx.useMediaDevice(s.call.local, x.kind, x.id);
            for (d.list.items) |*y| if (y.kind == x.kind) {
                y.current = y == &d.list.items[i];
            };
            // Ask again: a route change can change the others too.
            app.fx.mediaDevices(s.call.local, onDevices);
        },
    }
}

/// The device's name in the app's words where the platform gives a kind, else its own.
fn nameOf(x: Device, n: usize) []const u8 {
    const ty = x.type;
    if (std.mem.eql(u8, ty, "earpiece")) return t("Phone");
    if (std.mem.eql(u8, ty, "speaker")) return t("Speaker");
    if (std.mem.eql(u8, ty, "front")) return t("Front camera");
    if (std.mem.eql(u8, ty, "back")) return t("Back camera");
    if (x.label.len > 0) return x.label;
    if (std.mem.eql(u8, ty, "builtin")) return t("Microphone");
    if (std.mem.eql(u8, ty, "bluetooth")) return "Bluetooth";
    if (std.mem.eql(u8, ty, "wired") or std.mem.eql(u8, ty, "usb")) return t("Headset");
    return std.fmt.allocPrint(app.tmp(), "{s} {d}", .{ switch (x.kind) {
        .microphone => t("Microphone"),
        .camera => t("Camera"),
        .speaker => t("Speaker"),
    }, n }) catch "";
}

pub fn sheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const d = &s.call_devices;
    views.sheet(cx, t("Devices"));
    if (!d.loaded) kit.spinner(cx);
    for ([_]zui.MediaDevice.Kind{ .microphone, .camera, .speaker }) |kind| {
        var n: usize = 0;
        for (d.list.items, 0..) |x, i| {
            if (x.kind != kind) continue;
            n += 1;
            if (n == 1) kit.sectionTitle(cx, switch (kind) {
                .microphone => t("Microphone"),
                .camera => t("Camera"),
                .speaker => t("Speaker"),
            });
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 44, .padding = .xy(12, 6), .radius = 12, .pressed_background = cx.c.hover }, .{ .on_press = msgOf(.{ .use = @intCast(@min(i, 255)) }), .key = key(.{ "dev", i }) });
            ui.icon(switch (kind) {
                .microphone => icons.mic,
                .camera => icons.video,
                .speaker => icons.volume,
            }, 19, cx.c.text_2, .{}, 0);
            ui.text(nameOf(x, n), .{ .font_size = 14.5, .weight = 550, .color = cx.c.text, .grow = 1, .width = .fill, .max_lines = 1 });
            if (x.current) ui.icon(icons.check, 18, cx.c.accent, .{}, 0);
            ui.end();
        }
    }
    if (!s.call.group and s.call.chat.isSet()) {
        ui.begin(.{ .padding = .{ .top = 8 } }, .{});
        views.menuItem(cx, icons.chat, t("Open chat"), .{ .call = .open_chat }, false);
        ui.end();
    }
    views.endSheet(cx);
}
