//! Glimpses (src/routes/stories.js): post, watch, see who viewed, pin, delete.

const std = @import("std");
const A = @import("../app.zig");
const web = @import("../web.zig");
const v = @import("../validate.zig");
const stories = @import("../stories.zig");
const apps = @import("../apps.zig");
const account = @import("account.zig");
const val = A.val;
const Val = A.Val;
const Req = web.Req;

fn col() *A.Cols {
    return &A.app.col;
}

fn done(res: anyerror!void) anyerror!bool {
    try res;
    return true;
}

pub fn handle(q: *Req) !bool {
    if (q.is(.GET, "/api/stories")) return done(feed(q));
    if (q.is(.GET, "/api/stories/audience")) return done(audience(q));
    if (q.is(.GET, "/api/stories/archive")) return done(archive(q));
    if (q.is(.GET, "/api/stories/pinned/:userId")) return done(pinned(q));
    if (q.is(.POST, "/api/stories/:id/pin")) return done(pin(q));
    if (q.is(.POST, "/api/stories")) return done(create(q));
    if (q.is(.POST, "/api/stories/:id/view")) return done(view(q));
    if (q.is(.GET, "/api/stories/:id/views")) return done(views(q));
    if (q.is(.DELETE, "/api/stories/:id")) return done(delete(q));
    return false;
}

fn listOut(q: *Req, list: []const Val) !Val {
    var out = try Val.array(q.r.a);
    for (list) |st| try out.push(q.r.a, try stories.storyFor(&q.r, st, q.user().get("_id")));
    return out;
}

fn feed(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const list = try stories.feed(r, q.user());
    var ids: std.ArrayList(Val) = .empty;
    for (list) |st| {
        if (val.same(st.get("userId"), q.user().get("_id"))) continue;
        var dup = false;
        for (ids.items) |x| if (val.same(x, st.get("userId"))) {
            dup = true;
        };
        if (!dup) try ids.append(a, st.get("userId"));
    }
    const authors = if (ids.items.len > 0) try col().users.find(a, .{ ._id = .{ .@"$in" = ids.items } }, .{}) else val.none[0..];
    return q.json(.{ .stories = try listOut(q, list), .users = try account.usersFor(r, q.user(), authors, false) });
}

/// Who a new story can be shared with, with their public keys.
fn audience(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    try apps.assertFeature(r, q.user(), "stories", "Glimpses are turned off in this app");
    const aud = try stories.audienceOf(r, q.user());
    const out = try account.usersFor(r, q.user(), aud.users, false);
    for (out.items()) |u| {
        const id = u.get("id").asStr() orelse "";
        var contact = false;
        var chat = false;
        for (aud.contact_ids) |x| if (std.mem.eql(u8, x, id)) {
            contact = true;
        };
        for (aud.chat_ids) |x| if (std.mem.eql(u8, x, id)) {
            chat = true;
        };
        try u.set(a, "contact", contact);
        try u.set(a, "chat", chat);
    }
    return q.json(.{ .users = out });
}

fn archive(q: *Req) !void {
    const r = &q.r;
    const lim = v.toNumber(q.qv("limit"));
    const list = try stories.archive(r, q.user(), try v.id(r, q.qv("before"), "before", true), if (std.math.isFinite(lim) and lim != 0) v.clampInt(lim) else 60);
    return q.json(.{ .stories = try listOut(q, list) });
}

fn pinned(q: *Req) !void {
    const r = &q.r;
    const author: Val = .{ .id = try v.reqId(r, q.pv("userId"), "userId") };
    const list = try stories.pinnedOf(r, q.user(), author);
    const user = if (!val.same(author, q.user().get("_id")) and list.len > 0) try col().users.findOne(r.a, .{ ._id = author }, .{}) else null;
    return q.json(.{ .stories = try listOut(q, list), .users = if (user) |u| try account.usersFor(r, q.user(), &.{u}, false) else try Val.array(r.a) });
}

fn pin(q: *Req) !void {
    const r = &q.r;
    const st = try stories.setPinned(r, q.user(), .{ .id = try v.reqId(r, q.pv("id"), "id") }, try v.reqBool(r, q.b("pinned"), "pinned"));
    return q.json(.{ .story = try stories.storyFor(r, st, q.user().get("_id")) });
}

fn create(q: *Req) !void {
    try account.rateLimit(q, "story", 30, 3600_000);
    const st = try stories.createStory(&q.r, q.user(), try q.bodyObj());
    return q.json(.{ .story = try stories.storyFor(&q.r, st, q.user().get("_id")) });
}

fn view(q: *Req) !void {
    try account.rateLimit(q, "story-view", 600, 3600_000);
    const r = &q.r;
    const st = try stories.viewable(r, q.user(), .{ .id = try v.reqId(r, q.pv("id"), "id") });
    try stories.markViewed(r, q.user(), st);
    return q.json(.{ .ok = true });
}

fn views(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const st = try stories.viewable(r, q.user(), .{ .id = try v.reqId(r, q.pv("id"), "id") });
    try r.ensure(val.same(st.get("userId"), q.user().get("_id")), "Only the author can see who viewed a glimpse", 403, "not_author");
    var ids: std.ArrayList(Val) = .empty;
    for (st.get("views").items()) |x| try ids.append(a, x.get("userId"));
    const users = if (ids.items.len > 0) try col().users.find(a, .{ ._id = .{ .@"$in" = ids.items } }, .{}) else val.none[0..];
    const serialized = try account.usersFor(r, q.user(), users, false);
    var out = try Val.array(a);
    const vs = st.get("views").items();
    var i = vs.len;
    while (i > 0) {
        i -= 1;
        for (serialized.items()) |u| if (val.same(u.get("id"), vs[i].get("userId"))) {
            try out.push(a, try val.from(a, .{ .user = u, .at = vs[i].get("at") }));
            break;
        };
    }
    return q.json(.{ .views = out, .viewerCount = st.get("viewerIds").len() });
}

fn delete(q: *Req) !void {
    try stories.deleteStory(&q.r, q.user(), .{ .id = try v.reqId(&q.r, q.pv("id"), "id") });
    return q.json(.{ .ok = true });
}
