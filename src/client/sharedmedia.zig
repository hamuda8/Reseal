//! Shared media in a chat's info (Reseal-js info.js sharedMedia): tabs for Media, Files, Links,
//! Voice and Music, each loaded with ?tag= from the server and decrypted here.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const icons = @import("icons.zig");
const kit = @import("ui.zig");
const fmt = @import("fmt.zig");
const media = @import("media.zig");
const keys = @import("keys.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const Color = zui.Color;
const t = zui.i18n.t;
const tmp = app.tmp;
const gpa = app.gpa;
const key = kit.key;

pub const Tab = enum { photo, file, link, voice, audio };

fn tags(tab: Tab) []const []const u8 {
    return switch (tab) {
        .photo => &.{ "photo", "video", "gif" },
        .file => &.{"file"},
        .link => &.{"link"},
        .voice => &.{ "voice", "round" },
        .audio => &.{"audio"},
    };
}

fn label(tab: Tab) []const u8 {
    return switch (tab) {
        .photo => t("Media"),
        .file => t("Files"),
        .link => t("Links"),
        .voice => t("Voice"),
        .audio => t("Music"),
    };
}

pub const Shared = struct {
    chat: Id = .{},
    tab: Tab = .photo,
    msgs: std.ArrayList(*data.Message) = .empty,
    pending: u8 = 0,
    seq: u32 = 0,

    fn clear(sh: *Shared) void {
        for (sh.msgs.items) |m| m.destroy();
        sh.msgs.clearRetainingCapacity();
    }
};

pub const Act = union(enum) {
    tab: Tab,
    open: struct { msg: Id, seq: i64 },
};

fn msgOf(a: Act) Msg {
    return .{ .shared = a };
}

/// The info of `chat` opened: its media tab loads.
pub fn opened(s: *State, chat: Id) void {
    s.shared.chat = chat;
    load(s, .photo);
}

fn load(s: *State, tab: Tab) void {
    const sh = &s.shared;
    sh.clear();
    sh.tab = tab;
    sh.seq +%= 1;
    sh.pending = 0;
    for (tags(tab)) |tag| {
        app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/{s}/messages?tag={s}&limit=60", .{ sh.chat.str(), tag }) catch return, null, .{ .shared = sh.seq });
        sh.pending += 1;
    }
}

pub fn act(s: *State, a: Act) void {
    switch (a) {
        .tab => |tab| if (tab != s.shared.tab or s.shared.pending == 0) load(s, tab),
        .open => |x| {
            // Shown in the chat, where the viewer and the player are.
            const chat = s.shared.chat;
            if (!s.open_chat.eql(chat.str())) @import("views.zig").openChat(s, chat.str());
            s.info = .{};
            @import("msgextras.zig").act(s, .{ .jump = .{ .msg = x.msg, .seq = x.seq } });
        },
    }
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const seq = switch (op) {
        .shared => |q| q,
        else => return false,
    };
    const sh = &s.shared;
    if (seq != sh.seq) return true;
    if (sh.pending > 0) sh.pending -= 1;
    if (!r.ok()) return true;
    const v = j.parse(tmp(), r.body);
    for (j.arr(v, "messages")) |raw| {
        const m = data.newMessage(raw) catch continue;
        sh.msgs.append(gpa, m) catch {
            m.destroy();
            continue;
        };
    }
    // Newest first.
    std.mem.sort(*data.Message, sh.msgs.items, {}, struct {
        fn lt(_: void, x: *data.Message, y: *data.Message) bool {
            return (x.seq() orelse 0) > (y.seq() orelse 0);
        }
    }.lt);
    hydrate(s);
    return true;
}

/// After each update: decrypt what can be, ask for the pictures shown.
pub fn after(s: *State) void {
    if (!s.shared.chat.isSet() or !s.info.eql(s.shared.chat.str())) return;
    hydrate(s);
    if (s.shared.tab != .photo) return;
    var n: usize = 0;
    for (s.shared.msgs.items) |m| {
        if (m.decrypt != .ok) continue;
        for (m.media()) |it| {
            if (!isVisual(it)) continue;
            n += 1;
            if (n > 60) return;
            if (std.mem.eql(u8, j.strOr(it, "kind", ""), "photo") and media.shown(s, it) == null) _ = media.file(s, it, false);
        }
    }
}

fn hydrate(s: *State) void {
    for (s.shared.msgs.items) |m| if (m.decrypt != .ok or m.content == null) keys.hydrate(s, s.shared.chat.str(), m);
}

fn isVisual(it: j.Value) bool {
    const k = j.strOr(it, "kind", "");
    return std.mem.eql(u8, k, "photo") or std.mem.eql(u8, k, "video") or std.mem.eql(u8, k, "gif");
}

fn inTab(tab: Tab, it: j.Value) bool {
    for (tags(tab)) |tag| if (std.mem.eql(u8, j.strOr(it, "kind", ""), tag)) return true;
    return false;
}

pub fn section(cx: Cx, c: *const data.Chat) void {
    const s = cx.s;
    const ui = cx.ui;
    const sh = &s.shared;
    if (!sh.chat.eql(c.id())) return;
    ui.beginScroll(.{ .direction = .row, .gap = 6, .padding = .{ .start = 8, .end = 8, .top = 14, .bottom = 8 }, .height = .{ .px = 56 } }, key(.{"shared-tabs"}));
    for ([_]Tab{ .photo, .file, .link, .voice, .audio }) |tab| {
        const on = sh.tab == tab;
        ui.begin(.{ .height = .{ .px = 32 }, .padding = .xy(13, 0), .radius = 11, .justify = .center, .background = if (on) cx.c.text else cx.c.surface_2 }, .{ .on_press = msgOf(.{ .tab = tab }), .key = key(.{ "stab", @intFromEnum(tab) }) });
        ui.text(label(tab), .{ .font_size = 13, .weight = 500, .color = if (on) cx.c.surface else cx.c.text_2, .max_lines = 1 });
        ui.end();
    }
    ui.end();
    if (sh.pending > 0 and sh.msgs.items.len == 0) return kit.spinner(cx);
    var any = false;
    const a = cx.a();
    switch (sh.tab) {
        .photo => {
            const cell = @max(60, (@min(cx.w, 420) - 40) / 3);
            ui.begin(.{ .direction = .row, .wrap = true, .gap = 3, .padding = .xy(8, 0) }, .{});
            for (sh.msgs.items) |m| {
                if (m.decrypt != .ok) continue;
                for (m.media()) |it| {
                    if (!isVisual(it)) continue;
                    any = true;
                    const id = j.strOr(it, "id", "");
                    ui.begin(.{ .width = .{ .px = cell }, .height = .{ .px = cell }, .radius = 6, .clip = true, .background = cx.c.surface_2, .align_items = .center, .justify = .center }, .{ .on_press = msgOf(.{ .open = .{ .msg = Id.of(m.id()), .seq = m.seq() orelse 0 } }), .key = key(.{ "smg", id }) });
                    if (media.shown(s, it)) |f| {
                        if (f.state == .ready) media.draw(ui, f, id, .{ .width = .{ .px = cell }, .height = .{ .px = cell }, .fit = .cover }, key(.{ "smgi", id }));
                    } else if (j.str(it, "thumb")) |th| {
                        ui.image(th, .{ .width = .{ .px = cell }, .height = .{ .px = cell }, .fit = .cover }, key(.{ "smgt", id }));
                    } else ui.icon(if (std.mem.eql(u8, j.strOr(it, "kind", ""), "photo")) icons.image else icons.video, 22, cx.c.text_3, .{}, 0);
                    if (j.field(it, "duration")) |d| if (d == .float or d == .integer) {
                        ui.begin(.{ .position = .absolute, .inset = .{ .bottom = 4, .end = 4 }, .padding = .xy(5, 1), .radius = 6, .background = cx.c.shade.withAlpha(0.53) }, .{});
                        ui.text(fmt.duration(a, j.floatOr(it, "duration", 0)), .{ .font_size = 12, .weight = 500, .color = cx.c.on_shade });
                        ui.end();
                    };
                    ui.end();
                }
            }
            ui.end();
        },
        .link => for (sh.msgs.items) |m| {
            if (m.decrypt != .ok or m.content == null) continue;
            any = true;
            const url = j.str(m.content, "preview.url") orelse firstUrl(m.text()) orelse "";
            const title = j.str(m.content, "preview.title") orelse if (url.len > 0) url else m.text();
            kit.row(cx, title, .{ .icon = icons.link, .subtitle = if (url.len > 0) url else null, .on = msgOf(.{ .open = .{ .msg = Id.of(m.id()), .seq = m.seq() orelse 0 } }), .k = key(.{ "sl", m.id() }) });
        },
        else => for (sh.msgs.items) |m| {
            if (m.decrypt != .ok) continue;
            for (m.media(), 0..) |it, i| {
                if (!inTab(sh.tab, it)) continue;
                any = true;
                const kind = j.strOr(it, "kind", "");
                const name = j.str(it, "name") orelse if (std.mem.eql(u8, kind, "voice")) t("Voice message") else if (std.mem.eql(u8, kind, "round")) t("Video message") else t("File");
                const size = j.intOr(it, "size", 0);
                const what = if (size > 0) fmt.fileSize(a, size) else fmt.duration(a, j.floatOr(it, "duration", 0));
                const sub = std.fmt.allocPrint(a, "{s} · {s}", .{ what, fmt.shortDate(a, m.at) }) catch "";
                const ic = if (std.mem.eql(u8, kind, "voice")) icons.mic else if (std.mem.eql(u8, kind, "round")) icons.video else if (std.mem.eql(u8, kind, "audio")) icons.music else icons.file;
                kit.row(cx, name, .{ .icon = ic, .subtitle = sub, .on = msgOf(.{ .open = .{ .msg = Id.of(m.id()), .seq = m.seq() orelse 0 } }), .k = key(.{ "sf", m.id(), i }) });
            }
        },
    }
    if (!any and sh.pending == 0) {
        ui.begin(.{ .align_items = .center, .gap = 8, .padding = .xy(12, 22) }, .{});
        ui.icon(switch (sh.tab) {
            .photo => icons.image,
            .link => icons.link,
            .voice => icons.mic,
            else => icons.file,
        }, 28, cx.c.text_3, .{}, 0);
        ui.text(t("Nothing here yet"), .{ .font_size = 14, .color = cx.c.text_2 });
        ui.end();
    }
}

fn firstUrl(text: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, text, "https://") orelse std.mem.indexOf(u8, text, "http://") orelse return null;
    var e = i;
    while (e < text.len and !std.ascii.isWhitespace(text[e])) e += 1;
    return text[i..e];
}
