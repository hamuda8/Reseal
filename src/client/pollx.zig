//! Voting in the bubble (Reseal-js message.js pollView): a tap votes, or (several answers) ticks
//! options for the Vote button; "View votes" lists who chose what (showVoters).

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");
const keys = @import("keys.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const t = zui.i18n.t;
const tmp = app.tmp;
const key = kit.key;

pub const Polls = struct {
    /// The poll whose options are being ticked, and which.
    msg: Id = .{},
    chosen: u32 = 0,
    voters: ?*data.Obj = null,
    voters_msg: Id = .{},
};

pub const Act = union(enum) {
    tap: struct { msg: Id, option: u8, multiple: bool },
    vote: Id,
    voters: Id,
};

pub fn msgOf(a: Act) Msg {
    return .{ .poll = a };
}

pub fn chosen(s: *const State, msg_id: []const u8, i: usize) bool {
    return i < 32 and s.polls.msg.eql(msg_id) and (s.polls.chosen >> @intCast(i)) & 1 == 1;
}

pub fn anyChosen(s: *const State, msg_id: []const u8) bool {
    return s.polls.msg.eql(msg_id) and s.polls.chosen != 0;
}

pub fn act(s: *State, a: Act) void {
    const p = &s.polls;
    switch (a) {
        .tap => |x| {
            if (!x.multiple) return views.onUi(s, .{ .vote = .{ .msg = x.msg, .option = x.option } });
            if (x.option >= 32) return;
            if (!p.msg.eql(x.msg.str())) {
                p.msg = x.msg;
                p.chosen = 0;
            }
            p.chosen ^= @as(u32, 1) << @intCast(x.option);
        },
        .vote => |id| {
            if (!p.msg.eql(id.str()) or p.chosen == 0) return;
            var list: std.ArrayList(u8) = .empty;
            var n: usize = 0;
            for (0..32) |i| if ((p.chosen >> @intCast(i)) & 1 == 1) {
                list.print(tmp(), "{s}{d}", .{ if (n > 0) "," else "", i }) catch return;
                n += 1;
            };
            p.chosen = 0;
            app.api(s, .POST, std.fmt.allocPrint(tmp(), "/chats/{s}/messages/{s}/vote", .{ s.open_chat.str(), id.str() }) catch return, std.fmt.allocPrint(tmp(), "{{\"options\":[{s}]}}", .{list.items}) catch return, .{ .vote = .{ .chat = s.open_chat, .msg = id } });
        },
        .voters => |id| {
            if (p.voters) |o| o.destroy();
            p.voters = null;
            p.voters_msg = id;
            s.modal = .poll_voters;
            app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/{s}/messages/{s}/voters", .{ s.open_chat.str(), id.str() }) catch return, null, .poll_voters);
        },
    }
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    switch (op) {
        .poll_voters => {
            if (!r.ok()) {
                s.modal = null;
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            const v = j.parse(tmp(), r.body) orelse return true;
            for (j.arr(v, "voters")) |x| if (j.str(x, "userId")) |u| keys.want(s, u);
            s.polls.voters = data.Obj.create(v) catch null;
        },
        else => return false,
    }
    return true;
}

pub fn votersSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, t("Votes"));
    const res = s.polls.voters orelse {
        kit.spinner(cx);
        return views.endSheet(cx);
    };
    const tl = s.store.existingTimeline(s.open_chat.str());
    const m = if (tl) |x| x.find(s.polls.voters_msg.str()) else null;
    const options = if (m) |mm| j.arr(j.obj(mm.content, "poll"), "options") else &.{};
    for (options, 0..) |o, i| {
        const label = if (o == .string) o.string else j.strOr(o, "text", "");
        var who: usize = 0;
        for (j.arr(res.v, "voters")) |x| for (j.arr(x, "options")) |n| {
            if (n == .integer and n.integer == @as(i64, @intCast(i))) who += 1;
        };
        ui.begin(.{ .padding = .{ .top = 12, .bottom = 4, .start = 12, .end = 12 } }, .{});
        ui.text(std.fmt.allocPrint(cx.a(), "{s} — {d}", .{ label, who }) catch "", .{ .font_size = 14, .weight = 700, .color = cx.c.text_2 });
        ui.end();
        for (j.arr(res.v, "voters")) |x| for (j.arr(x, "options")) |n| {
            if (n != .integer or n.integer != @as(i64, @intCast(i))) continue;
            const uid = j.strOr(x, "userId", "");
            ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 48, .padding = .xy(12, 4) }, .{ .key = key(.{ "pv", i, uid }) });
            const u = s.store.user(uid);
            kit.avatar(cx, .{ .name = s.store.displayName(uid), .color = if (u) |uu| uu.i("color") orelse 0 else 0, .image = if (u) |uu| uu.s("avatar") else null, .size = 36 }, key(.{ "pva", i, uid }));
            ui.text(s.store.displayName(uid), .{ .font_size = 16, .color = cx.c.text, .grow = 1, .width = .fill, .max_lines = 1 });
            ui.end();
        };
    }
    views.endSheet(cx);
}
