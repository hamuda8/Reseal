//! Reseal client: the same code for the web, Android and iOS.

const std = @import("std");
const zui = @import("zui");

pub const panic = zui.panic;

pub const Msg = union(enum) { none };
pub const State = struct {};

comptime {
    zui.exportApp(@This());
}

pub fn init() State {
    return .{};
}

pub fn update(_: *State, _: Msg) void {}

pub fn view(_: *const State, ui: *zui.Ui(Msg)) void {
    ui.setBackground(zui.Color.hex("#ffffff"));
    ui.begin(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center }, .{});
    ui.text("Reseal", .{ .font_size = 28, .weight = 700, .color = zui.Color.hex("#0f172a") });
    ui.end();
}
