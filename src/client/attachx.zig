//! Sending files the way Reseal-js's attach dialog does (composer.js attachFiles): what was
//! picked waits in a sheet ("Send photo", "Send {n} items") with a caption, "Compress images"
//! (off: they go as files), "Hide with spoiler", more files (up to 10), then one message.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const icons = @import("icons.zig");
const kit = @import("ui.zig");
const fmt = @import("fmt.zig");
const views = @import("views.zig");
const media = @import("media.zig");
const send = @import("send.zig");
const markdown = @import("markdown.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const Color = zui.Color;
const t = zui.i18n.t;
const tmp = app.tmp;
const gpa = app.gpa;
const key = kit.key;

pub const max_items = 10;

const Staged = struct {
    bytes: []u8,
    name: []u8,
    mime: []u8,
    thumb: ?[]u8 = null,
    w: ?i64 = null,
    h: ?i64 = null,
    duration: ?f64 = null,
    seq: u32 = 0,

    fn free(x: *Staged) void {
        gpa.free(x.bytes);
        gpa.free(x.name);
        gpa.free(x.mime);
        if (x.thumb) |th| gpa.free(th);
    }

    fn kind(x: *const Staged) []const u8 {
        return media.kindOf(x.mime);
    }
};

pub const Attach = struct {
    items: std.ArrayList(Staged) = .empty,
    compress: bool = true,
    spoiler: bool = false,
    seq: u32 = 0,
};

pub const Act = union(enum) {
    remove: u32,
    compress,
    spoiler,
    more,
    send,
    cancel,
};

fn msgOf(a: Act) Msg {
    return .{ .attach_x = a };
}

fn clear(s: *State) void {
    for (s.attach.items.items) |*x| x.free();
    s.attach.items.clearRetainingCapacity();
}

/// A picked file (bytes owned by the caller's copy here) joins the sheet.
pub fn stage(s: *State, bytes: []u8, meta: media.Meta, as_file: bool) void {
    const limit = if (s.store.config) |cfg| j.intOr(cfg.v, "limits.maxUploadBytes", 0) else 0;
    if (limit > 0 and bytes.len > limit) {
        app.toastError(s, fmt.tf("{name} is larger than {size}", .{ .name = meta.name, .size = fmt.fileSize(tmp(), limit) }));
        gpa.free(bytes);
        return;
    }
    if (s.attach.items.items.len >= max_items) {
        gpa.free(bytes);
        return;
    }
    if (s.attach.items.items.len == 0) {
        s.attach.compress = !as_file;
        s.attach.spoiler = false;
        // The caption starts as what was typed.
        s.fields.getPtr(.attach_caption).set(s.fields.get(.composer).get());
    }
    s.attach.seq +%= 1;
    s.attach.items.append(gpa, .{
        .bytes = bytes,
        .name = gpa.dupe(u8, meta.name) catch return gpa.free(bytes),
        .mime = gpa.dupe(u8, meta.mime) catch return gpa.free(bytes),
        .thumb = if (meta.thumb) |th| gpa.dupe(u8, th) catch null else null,
        .w = meta.w,
        .h = meta.h,
        .duration = meta.duration,
        .seq = s.attach.seq,
    }) catch return gpa.free(bytes);
    s.modal = .attach_preview;
}

pub fn act(s: *State, a: Act) void {
    const at = &s.attach;
    switch (a) {
        .remove => |seq| {
            for (at.items.items, 0..) |*x, i| if (x.seq == seq) {
                x.free();
                _ = at.items.orderedRemove(i);
                break;
            };
            if (at.items.items.len == 0) s.modal = null;
        },
        .compress => at.compress = !at.compress,
        .spoiler => at.spoiler = !at.spoiler,
        .more => @import("compose.zig").act(s, if (at.compress) .pick_media else .pick_file),
        .cancel => {
            clear(s);
            s.modal = null;
        },
        .send => sendAll(s),
    }
}

fn visual(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "photo") or std.mem.eql(u8, kind, "video") or std.mem.eql(u8, kind, "gif");
}

fn sendAll(s: *State) void {
    const at = &s.attach;
    s.modal = null;
    if (at.items.items.len == 0 or !s.open_chat.isSet()) return clear(s);
    const chat = s.open_chat.str();
    const c = s.store.chat(chat) orelse return clear(s);
    const a = tmp();
    const raw = std.mem.trim(u8, s.fields.get(.attach_caption).get(), " \t\r\n");
    const p = markdown.parse(a, raw) catch return clear(s);
    const local = send.queueDraft(s, chat, .{ .text = p.text, .entities = p.entities, .reply_to = s.reply_to }) orelse return clear(s);
    s.reply_to = .{};
    for (at.items.items) |*x| {
        const kind = x.kind();
        const as_file = !at.compress and !std.mem.eql(u8, kind, "video");
        send.attachTo(s, local, x.bytes, .{
            .name = x.name,
            .mime = x.mime,
            .thumb = x.thumb,
            .w = x.w,
            .h = x.h,
            .duration = x.duration,
            .encrypted = c.encrypted(),
            .kind = if (as_file) "file" else null,
            .spoiler = at.spoiler and visual(kind),
        });
        // The bytes now belong to the upload.
        x.bytes = &.{};
    }
    clear(s);
    // What was typed went out as the caption.
    s.fields.getPtr(.composer).clear();
    @import("drafts.zig").clear(s, chat);
}

pub fn sheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const at = &s.attach;
    const items = at.items.items;
    if (items.len == 0) return;
    const first = items[0].kind();
    const title = if (items.len > 1) fmt.tf("Send {n} items", .{ .n = @as(i64, @intCast(items.len)) }) else if (std.mem.eql(u8, first, "photo") and at.compress) t("Send photo") else if (std.mem.eql(u8, first, "video")) t("Send video") else t("Send file");
    views.sheet(cx, title);
    ui.begin(.{ .direction = .row, .wrap = true, .gap = 8, .padding = .xy(12, 4) }, .{});
    const single = items.len == 1;
    for (items) |*x| {
        const kind = x.kind();
        const show_visual = at.compress and visual(kind);
        const size: f32 = if (single) @min(cx.w - 64, 380) else 112;
        if (show_visual) {
            ui.begin(.{ .width = .{ .px = size }, .height = .{ .px = if (single) size * 0.75 else size }, .radius = 14, .clip = true, .background = cx.c.surface_2, .align_items = .center, .justify = .center }, .{ .key = key(.{ "att", x.seq }) });
            if (std.mem.eql(u8, kind, "photo") or std.mem.eql(u8, kind, "gif")) {
                ui.imageBytes(x.bytes, std.fmt.allocPrint(cx.a(), "att-{d}", .{x.seq}) catch "att", .{ .width = .fill, .height = .fill, .fit = .cover }, key(.{ "atti", x.seq }));
            } else if (x.thumb) |th| {
                ui.image(th, .{ .width = .fill, .height = .fill, .fit = .cover }, key(.{ "attt", x.seq }));
            } else ui.icon(icons.video, 30, cx.c.text_3, .{}, 0);
            removeButton(cx, x.seq);
            ui.end();
        } else {
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .padding = .xy(10, 8), .radius = 14, .background = cx.c.surface_2, .width = .fill }, .{ .key = key(.{ "attf", x.seq }) });
            ui.icon(icons.file, 24, cx.c.accent, .{}, 0);
            ui.begin(.{ .grow = 1, .width = .fill }, .{});
            ui.text(x.name, .{ .font_size = 14.5, .weight = 600, .color = cx.c.text, .max_lines = 1 });
            ui.text(fmt.fileSize(cx.a(), @intCast(x.bytes.len)), .{ .font_size = 12.5, .color = cx.c.text_2 });
            ui.end();
            kit.iconButton(cx, icons.close, msgOf(.{ .remove = x.seq }), .{ .size = 32 });
            ui.end();
        }
    }
    ui.end();
    var any_visual = false;
    for (items) |*x| if (visual(x.kind())) {
        any_visual = true;
    };
    if (any_visual) {
        kit.row(cx, t("Compress images"), .{ .icon = icons.image, .switch_on = at.compress, .on = msgOf(.compress) });
        kit.row(cx, t("Hide with spoiler"), .{ .icon = icons.eyeOff, .switch_on = at.spoiler, .on = msgOf(.spoiler) });
    }
    ui.begin(.{ .padding = .xy(12, 6) }, .{});
    ui.begin(.{ .padding = .xy(14, 10), .radius = 14, .background = cx.c.surface_2 }, .{});
    ui.input(.{ .key = zui.key("attach_caption"), .value = s.fields.get(.attach_caption).get(), .placeholder = t("Add a caption…"), .on_change = app.onField(.attach_caption), .multiline = true, .style = .{ .width = .fill, .font_size = 15, .color = cx.c.text } });
    ui.end();
    ui.end();
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .top = 8, .bottom = 8, .start = 8, .end = 8 } }, .{});
    if (items.len < max_items) kit.button(cx, t("Add"), msgOf(.more), .{ .kind = .ghost, .icon = icons.plus });
    ui.begin(.{ .grow = 1 }, .{});
    ui.end();
    kit.button(cx, t("Cancel"), msgOf(.cancel), .{ .kind = .ghost });
    kit.button(cx, t("Send"), msgOf(.send), .{ .icon = icons.send });
    ui.end();
    views.endSheet(cx);
}

fn removeButton(cx: Cx, seq: u32) void {
    cx.ui.begin(.{ .position = .absolute, .inset = .{ .top = 6, .end = 6 } }, .{});
    kit.iconButton(cx, icons.close, msgOf(.{ .remove = seq }), .{ .size = 28, .color = Color.white, .background = Color.hex("#0a0c1499") });
    cx.ui.end();
}
