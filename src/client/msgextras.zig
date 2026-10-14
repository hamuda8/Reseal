//! More of what a message offers (Reseal-js chatview.js): its link ("Copy message link"), who
//! has seen it ("Seen by…"), its details (sent, edited, encryption, disappearing, views), any
//! emoji as a reaction ("More reactions"), pinning with or without notifying everyone, and
//! jumping to a message (a reply's quote, the pinned bar, a /c/<id>#<seq> link) with a
//! highlight, loading the history around it when needed. Also the scroll-to-bottom button.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const sync = @import("sync.zig");
const icons = @import("icons.zig");
const fmt = @import("fmt.zig");
const text = @import("text.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const t = zui.i18n.t;
const tmp = app.tmp;
const key = kit.key;

pub const Act = union(enum) {
    copy_link: Id,
    seen_by: Id,
    details: Id,
    more_reactions: Id,
    pin_ask: Id,
    pin_notify,
    pin_confirm,
    jump: struct { msg: Id, seq: i64 = 0 },
    unhighlight: u32,
    to_bottom,
    next_mention,
    pin_tap: Id,
    pin_unpin: Id,
};

pub const Extras = struct {
    target: Id = .{},
    readers: ?*data.Obj = null,
    pin_notify: bool = true,
    /// A message being looked for (its history loads first).
    pending_jump: Id = .{},
    highlight: Id = .{},
    highlight_seq: u32 = 0,
    at_bottom: bool = true,
    /// The pin the pinned bar shows.
    pin_index: usize = 0,
};

fn path(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(tmp(), f, args) catch "";
}

fn message(s: *State, id: []const u8) ?*data.Message {
    const tl = s.store.existingTimeline(s.open_chat.str()) orelse return null;
    return tl.find(id);
}

pub fn act(s: *State, a: Act) void {
    const x = &s.extras;
    switch (a) {
        .copy_link => |id| {
            s.modal = null;
            const c = s.store.chat(s.open_chat.str()) orelse return;
            const m = message(s, id.str()) orelse return;
            const base = std.mem.trimEnd(u8, if (s.store.config) |cfg| cfg.s("publicUrl") orelse "" else "", "/");
            const seq = m.seq() orelse 0;
            if (c.o.s("username")) |un| {
                app.fx.copy(path("{s}/@{s}#{d}", .{ base, un, seq }));
                app.toast(s, t("Link copied"));
            } else {
                app.fx.copy(path("{s}/c/{s}#{d}", .{ base, c.id(), seq }));
                app.toast(s, t("Link copied. It opens for people in this chat."));
            }
        },
        .seen_by => |id| {
            x.target = id;
            if (x.readers) |o| o.destroy();
            x.readers = null;
            s.modal = .seen_by;
            app.api(s, .GET, path("/chats/{s}/messages/{s}/readers", .{ s.open_chat.str(), id.str() }), null, .seen_by);
        },
        .details => |id| {
            x.target = id;
            s.modal = .message_details;
        },
        .more_reactions => |id| {
            s.compose.react_to = id;
            s.modal = .{ .compose = .emoji };
        },
        .pin_ask => |id| {
            const c = s.store.chat(s.open_chat.str()) orelse return;
            x.target = id;
            // Private and saved chats pin without asking.
            if (c.is("private") or c.is("saved") or c.is("bot")) {
                x.pin_notify = false;
                return act(s, .pin_confirm);
            }
            x.pin_notify = true;
            s.modal = .pin_message;
        },
        .pin_notify => x.pin_notify = !x.pin_notify,
        .pin_confirm => {
            s.modal = null;
            app.api(s, .POST, path("/chats/{s}/messages/{s}/pin", .{ s.open_chat.str(), x.target.str() }), if (x.pin_notify) "{\"silent\":false}" else "{\"silent\":true}", .pin);
        },
        .jump => |jmp| jump(s, jmp.msg.str(), jmp.seq),
        .unhighlight => |seq| if (seq == x.highlight_seq) {
            x.highlight = .{};
        },
        .pin_tap => |pid| {
            const n = if (s.store.chat(s.open_chat.str())) |c| j.arr(c.o.v, "pinned").len else 0;
            jump(s, pid.str(), 0);
            s.extras.pin_index = if (n > 0) (s.extras.pin_index + 1) % n else 0;
        },
        .pin_unpin => |pid| app.api(s, .POST, std.fmt.allocPrint(tmp(), "/chats/{s}/messages/{s}/pin", .{ s.open_chat.str(), pid.str() }) catch return, "{\"unpin\":true}", .pin),
        .next_mention => if (s.open_chat.isSet()) {
            // The first unread message that mentions me, else the bottom.
            const c = s.store.chat(s.open_chat.str()) orelse return;
            const read = c.meInt("lastReadSeq");
            if (s.store.existingTimeline(c.id())) |tl| for (tl.items.items) |m| {
                if ((m.seq() orelse 0) <= read) continue;
                for (j.arr(m.o.v, "mentions")) |mid| if (mid == .string and s.store.isMe(mid.string)) return jump(s, m.id(), m.seq() orelse 0);
            };
            act(s, .to_bottom);
        },
        .to_bottom => if (s.open_chat.isSet()) {
            const tl = s.store.existingTimeline(s.open_chat.str());
            if (tl != null and tl.?.has_newer) {
                sync.loadMessages(s, s.open_chat.str(), .latest, 0);
            }
            app.fx.scrollTo(key(.{ "msgs", s.open_chat.str() }), .end, true);
        },
    }
}

/// Shows message `id` (with sequence `seq` when known): scrolled to and highlighted.
pub fn jump(s: *State, id: []const u8, seq: i64) void {
    s.modal = null;
    if (!s.open_chat.isSet()) return;
    if (message(s, id) != null) return show(s, id);
    s.extras.pending_jump = Id.of(id);
    if (seq > 0) {
        sync.loadMessages(s, s.open_chat.str(), .around, seq);
    } else {
        app.api(s, .GET, path("/chats/{s}/messages/{s}", .{ s.open_chat.str(), id }), null, .jump_lookup);
    }
}

fn show(s: *State, id: []const u8) void {
    const x = &s.extras;
    x.pending_jump = .{};
    // Older messages beyond what is shown come into view first.
    if (s.store.existingTimeline(s.open_chat.str())) |tl| {
        for (tl.items.items, 0..) |m, i| if (std.mem.eql(u8, m.id(), id)) {
            const from_end = tl.items.items.len - i;
            if (from_end > s.show_count) s.show_count = from_end + 10;
        };
    }
    x.highlight = Id.of(id);
    x.highlight_seq +%= 1;
    app.fx.scrollTo(key(.{ "msgs", s.open_chat.str() }), .{ .child = key(.{ "m", id }) }, true);
    app.fx.after(1600, .{ .extras = .{ .unhighlight = x.highlight_seq } });
}

/// History around a message came in: show the one looked for.
pub fn afterLoad(s: *State) void {
    const x = &s.extras;
    if (!x.pending_jump.isSet()) return;
    const id = x.pending_jump;
    if (message(s, id.str()) != null) show(s, id.str()) else {
        x.pending_jump = .{};
        app.toastError(s, t("That message is no longer available."));
    }
}

pub fn onScroll(s: *State, at_end: bool) void {
    s.extras.at_bottom = at_end;
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const x = &s.extras;
    const v = j.parse(tmp(), r.body);
    switch (op) {
        .seen_by => if (r.ok()) {
            if (x.readers) |o| o.destroy();
            x.readers = data.Obj.create(v orelse return true) catch null;
            for (j.arr(v, "userIds")) |u| if (u == .string) @import("keys.zig").want(s, u.string);
        },
        .jump_lookup => {
            if (!r.ok()) {
                x.pending_jump = .{};
                app.toastError(s, t("That message is no longer available."));
                return true;
            }
            const seq = j.intOr(v, "message.seq", 0);
            if (seq <= 0) {
                x.pending_jump = .{};
                return true;
            }
            sync.loadMessages(s, s.open_chat.str(), .around, seq);
        },
        else => return false,
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Views

fn msg(a: Act) Msg {
    return .{ .extras = a };
}

pub fn seenBySheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, t("Seen by"));
    const o = s.extras.readers orelse {
        kit.spinner(cx);
        views.endSheet(cx);
        return;
    };
    const ids = j.arr(o.v, "userIds");
    if (ids.len == 0) kit.emptyState(cx, icons.eye, t("Nobody yet"), null);
    for (ids) |u| if (u == .string) {
        const user = s.store.user(u.string);
        const name = if (user) |x| s.store.userName(x) else "…";
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 52, .padding = .xy(12, 6), .radius = 12, .pressed_background = cx.c.active }, .{ .on_press = .{ .open_user = Id.of(u.string) }, .key = key(.{ "seen", u.string }) });
        kit.avatar(cx, .{ .name = name, .color = if (user) |x| x.i("color") orelse 0 else 0, .image = if (user) |x| x.s("avatar") else null, .size = 40 }, 0);
        ui.text(name, .{ .font_size = 15, .color = cx.c.text, .max_lines = 1 });
        ui.end();
    };
    views.endSheet(cx);
}

fn detailRow(cx: Cx, label: []const u8, value: []const u8) void {
    const ui = cx.ui;
    ui.begin(.{ .gap = 2, .padding = .xy(12, 8) }, .{});
    ui.text(label, .{ .font_size = 12.5, .weight = 600, .color = cx.c.text_2 });
    ui.text(value, .{ .font_size = 15, .color = cx.c.text });
    ui.end();
}

pub fn detailsSheet(cx: Cx) void {
    const s = cx.s;
    const a = cx.a();
    views.sheet(cx, t("Message details"));
    const tl = s.store.existingTimeline(s.open_chat.str());
    const m = if (tl) |x| x.find(s.extras.target.str()) else null;
    if (m) |mm| {
        detailRow(cx, t("Sent"), fmt.fullDate(a, mm.at));
        if (mm.o.s("editedAt")) |e| if (sys.parseIso(e)) |ms| detailRow(cx, t("Edited"), fmt.fullDate(a, ms));
        const enc = if (mm.enc() != null) (if (mm.verified orelse false) t("End-to-end encrypted, signature verified") else t("End-to-end encrypted, signature NOT verified")) else t("Not end-to-end encrypted");
        detailRow(cx, t("Encryption"), enc);
        const ttl = j.intOr(mm.o.v, "ttl", 0);
        if (ttl > 0) detailRow(cx, t("Disappears"), fmt.tf("Disappears after {time}", .{ .time = fmt.longDuration(a, ttl) }));
        if (j.int(mm.o.v, "views")) |n| detailRow(cx, t("Views"), fmt.number(a, n));
    }
    views.endSheet(cx);
}

pub fn pinSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, t("Pin message"));
    ui.begin(.{ .padding = .xy(12, 6), .gap = 12 }, .{});
    ui.text(t("Pin this message at the top of the chat?"), .{ .font_size = 15, .color = cx.c.text_2, .line_height = 1.5 });
    const on = s.extras.pin_notify;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 44 }, .{ .on_press = msg(.pin_notify) });
    ui.begin(.{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 8, .border_width = if (on) 0 else 1.5, .border_color = cx.c.border_strong, .background = if (on) cx.c.brand else null, .align_items = .center, .justify = .center }, .{});
    if (on) ui.icon(icons.check, 14, zui.Color.white, .{}, 0);
    ui.end();
    ui.text(t("Notify all members"), .{ .font_size = 15, .color = cx.c.text });
    ui.end();
    ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .top = 8, .bottom = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, t("Pin"), msg(.pin_confirm), .{});
    ui.end();
    ui.end();
    views.endSheet(cx);
}

/// The round "scroll to bottom" button over the messages (with the unread count).
pub fn bottomButton(cx: Cx, c: *const data.Chat) void {
    const s = cx.s;
    // Next mention, above the scroll-down button.
    if (c.meInt("mentions") > 0) {
        const up: f32 = if (s.extras.at_bottom) 0 else 56;
        cx.ui.begin(.{ .position = .absolute, .inset = .{ .bottom = (if (cx.phone) @as(f32, 80) else 96) + up, .end = if (cx.phone) 14 else 26 } }, .{ .key = key(.{"next-mention"}) });
        cx.ui.begin(.{ .width = .{ .px = 46 }, .height = .{ .px = 46 }, .radius = 23, .background = cx.c.surface, .border_width = 1, .border_color = cx.c.border, .shadow = .{ .y = 2, .blur = 10 }, .align_items = .center, .justify = .center, .pressed_opacity = 0.85 }, .{ .on_press = msg(.next_mention) });
        cx.ui.icon(icons.at, 22, cx.c.accent, .{}, 0);
        cx.ui.end();
        cx.ui.end();
    }
    const tl = s.store.existingTimeline(c.id());
    const newer = if (tl) |x| x.has_newer else false;
    if (s.extras.at_bottom and !newer) return;
    const ui = cx.ui;
    ui.begin(.{ .position = .absolute, .inset = .{ .bottom = if (cx.phone) 80 else 96, .end = if (cx.phone) 14 else 26 } }, .{ .key = key(.{"to-bottom"}) });
    ui.begin(.{ .width = .{ .px = 46 }, .height = .{ .px = 46 }, .radius = 23, .background = cx.c.surface, .border_width = 1, .border_color = cx.c.border, .shadow = .{ .y = 2, .blur = 10 }, .align_items = .center, .justify = .center, .pressed_opacity = 0.85 }, .{ .on_press = msg(.to_bottom) });
    ui.icon(icons.arrowDown, 22, cx.c.text_2, .{}, 0);
    ui.end();
    const unread = c.unread();
    if (unread > 0) {
        ui.begin(.{ .position = .absolute, .inset = .{ .top = -6, .end = -4 } }, .{});
        kit.badge(cx, fmt.number(cx.a(), unread), c.isMuted());
        ui.end();
    }
    ui.end();
}
