//! Glimpses (stories): photos, videos and text that leave the feed after a day
//! (src/services/stories.js). An expired story stays in the author's archive, and the author can
//! pin any story to their profile. Stories are end-to-end encrypted like chats: the content is
//! encrypted with a random key wrapped for every viewer; the server keeps who may view a story
//! and who viewed it, never what it shows.

const std = @import("std");
const A = @import("app.zig");
const v = @import("validate.zig");
const rt = @import("realtime.zig");
const keys = @import("keys.zig");
const apps = @import("apps.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;
const Limits = A.Limits;

fn col() *A.Cols {
    return &A.app.col;
}

fn containsSame(list: Val, x: Val) bool {
    for (list.items()) |e| if (val.same(e, x)) return true;
    return false;
}

fn addUnique(a: std.mem.Allocator, list: *std.ArrayList([]const u8), s: []const u8) !void {
    for (list.items) |x| if (std.mem.eql(u8, x, s)) return;
    try list.append(a, s);
}

pub const Audience = struct { users: []Val, contact_ids: [][]const u8, chat_ids: [][]const u8 };

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// People who may see this person's stories: contacts and private-chat partners, minus anyone
/// blocked either way.
pub fn audienceOf(r: *Rq, user: Val) !Audience {
    const a = r.a;
    const contacts = try col().contacts.find(a, .{ .userId = user.get("_id") }, .{ .projection = .{ .contactId = 1 } });
    const pairs = try col().members.find(a, .{ .userId = user.get("_id"), .chatType = "private", .status = "active" }, .{ .projection = .{ .chatId = 1 } });
    const blocks = try col().blocks.find(a, .{ .@"$or" = .{ .{ .userId = user.get("_id") }, .{ .blockedId = user.get("_id") } } }, .{});
    var pair_ids: std.ArrayList(Val) = .empty;
    for (pairs) |p| try pair_ids.append(a, p.get("chatId"));
    const peers = if (pairs.len > 0) try col().members.find(a, .{ .chatId = .{ .@"$in" = pair_ids.items }, .userId = .{ .@"$ne" = user.get("_id") } }, .{ .projection = .{ .userId = 1 } }) else val.none[0..];
    var blocked: std.ArrayList([]const u8) = .empty;
    for (blocks) |b| try blocked.append(a, try r.str(if (val.same(b.get("userId"), user.get("_id"))) b.get("blockedId") else b.get("userId")));
    var contact_ids: std.ArrayList([]const u8) = .empty;
    for (contacts) |c| try addUnique(a, &contact_ids, try r.str(c.get("contactId")));
    var chat_ids: std.ArrayList([]const u8) = .empty;
    for (peers) |p| try addUnique(a, &chat_ids, try r.str(p.get("userId")));
    var ids: std.ArrayList(Val) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    for ([_][][]const u8{ contact_ids.items, chat_ids.items }) |list| for (list) |id| {
        if (has(seen.items, id) or has(blocked.items, id)) continue;
        try seen.append(a, id);
        if (v.oidStr(id)) |o| try ids.append(a, .{ .id = o });
    };
    const users = if (ids.items.len > 0) try col().users.find(a, .{ ._id = .{ .@"$in" = ids.items }, .kind = .{ .@"$ne" = "bot" }, .deletedAt = .{ .@"$exists" = false }, .@"keys.enc" = .{ .@"$exists" = true } }, .{}) else val.none[0..];
    return .{ .users = users, .contact_ids = contact_ids.items, .chat_ids = chat_ids.items };
}

fn refPattern(s: []const u8) bool {
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

pub fn createStory(r: *Rq, user: Val, body: Val) !Val {
    const a = r.a;
    try apps.assertFeature(r, user, "stories", "Glimpses are turned off in this app");
    try r.ensure(user.path("keys.enc").truthy(), "Set up encryption first", 400, "no_keys");
    const now = A.nowMs();
    const active = try col().stories.count(a, .{ .userId = user.get("_id"), .expiresAt = .{ .@"$gt" = Val{ .date = now } } }, .{});
    try r.ensure(active < Limits.stories, try r.fmt("You can have up to {d} glimpses at a time", .{Limits.stories}), 400, "too_many_stories");

    const ref = try v.reqStr(r, body.get("ref"), "ref", .{ .min = 16, .max = 32, .pattern = refPattern });
    const e = try v.reqObj(r, body.get("enc"), "enc");
    const enc = try val.from(a, .{
        .e = 1,
        .s = if (try v.b64(r, e.get("s"), "enc.s", 32, true)) |x| Val{ .str = x } else Val.undef,
        .iv = try v.reqB64(r, e.get("iv"), "enc.iv", 32),
        .ct = try v.reqB64(r, e.get("ct"), "enc.ct", 64 * 1024),
        .sig = try v.reqB64(r, e.get("sig"), "enc.sig", 160),
    });
    const audience = try v.reqOneOf(r, if (body.get("audience").truthy()) body.get("audience") else Val.string("contacts"), "audience", &.{ "contacts", "chats", "selected" });
    const pinned = try v.reqBool(r, if (body.get("pinned").isNullish()) Val.False else body.get("pinned"), "pinned");
    if (pinned) try assertPinRoom(r, user);
    const klist = body.get("keys");
    try r.ensure(klist == .arr and klist.len() >= 1 and klist.len() <= Limits.story_viewers + 1, "keys must be a list", 400, null);
    var wraps: std.ArrayList(Val) = .empty;
    for (klist.items(), 0..) |w, i| try wraps.append(a, try keys.cleanWrap(r, w, i));
    for (wraps.items, 0..) |w, i| for (wraps.items[0..i]) |w2| if (val.same(w.get("userId"), w2.get("userId"))) return r.fail(400, "Each viewer may appear once", null);
    var self = false;
    for (wraps.items) |w| if (val.same(w.get("userId"), user.get("_id"))) {
        self = true;
    };
    try r.ensure(self, "Include a key for yourself", 400, null);

    // Only people in the author's circle can be given a key.
    const aud = try audienceOf(r, user);
    var keep = try Val.array(a);
    var viewer_ids = try Val.array(a);
    for (wraps.items) |w| {
        const mine = val.same(w.get("userId"), user.get("_id"));
        var allowed = false;
        for (aud.users) |u| if (val.same(u.get("_id"), w.get("userId"))) {
            allowed = true;
        };
        if (mine or allowed) {
            try keep.push(w);
            if (!mine) try viewer_ids.push(w.get("userId"));
        }
    }
    const media_ids = try v.reqIds(r, if (body.get("mediaIds").truthy()) body.get("mediaIds") else try Val.array(a), "mediaIds", 1);
    if (media_ids.len > 0) {
        const file = try col().media.findOne(a, .{ ._id = media_ids[0], .ownerId = user.get("_id"), .status = "ready" }, .{ .projection = .{ ._id = 1 } });
        try r.ensure(file != null, "Upload the file first", 400, "media_missing");
    }
    var mids = try Val.array(a);
    for (media_ids) |m| try mids.push(Val{ .id = m });
    const doc = try val.from(a, .{
        .userId = user.get("_id"),
        .ref = ref,
        .enc = enc,
        .mediaIds = mids,
        .audience = audience,
        .pinned = pinned,
        .keys = keep,
        .viewerIds = viewer_ids,
        .seenBy = try Val.array(a),
        .views = try Val.array(a),
        .createdAt = Val{ .date = now },
        .expiresAt = Val{ .date = now + Limits.story_hours * 3600_000 },
    });
    const id = try col().stories.insertOne(a, doc);
    if (media_ids.len > 0) _ = try col().media.updateOne(a, .{ ._id = media_ids[0] }, .{ .@"$set" = .{ .storyId = id } }, .{});
    var to: std.ArrayList(Val) = .empty;
    try to.append(a, user.get("_id"));
    try to.appendSlice(a, viewer_ids.items());
    rt.toUsers(a, to.items, "story.new", try val.from(a, .{ .userId = try r.str(user.get("_id")), .id = try r.str(id) }));
    return doc;
}

/// A story for one viewer: only their own key, and view details only for the author.
pub fn storyFor(r: *Rq, st: Val, viewer_id: Val) !Val {
    const a = r.a;
    const mine = val.same(st.get("userId"), viewer_id);
    var key: Val = .null;
    for (st.get("keys").items()) |k| if (val.same(k.get("userId"), viewer_id)) {
        key = try val.from(a, .{ .userId = try r.str(k.get("userId")), .eph = k.get("eph"), .iv = k.get("iv"), .ct = k.get("ct"), .sig = k.get("sig") });
        break;
    };
    const out = try val.from(a, .{
        .id = try r.str(st.get("_id")),
        .userId = try r.str(st.get("userId")),
        .ref = st.get("ref"),
        .enc = st.get("enc"),
        .key = key,
        .createdAt = st.get("createdAt"),
        .expiresAt = st.get("expiresAt"),
        .pinned = st.get("pinned").truthy(),
        .seen = mine or containsSame(st.get("seenBy"), viewer_id),
    });
    if (mine) {
        try out.set("audience", st.get("audience"));
        try out.set("viewerCount", st.get("viewerIds").len());
        try out.set("viewCount", st.get("views").len());
    }
    return out;
}

fn blockedSet(r: *Rq, user: Val) ![][]const u8 {
    const blocks = try col().blocks.find(r.a, .{ .@"$or" = .{ .{ .userId = user.get("_id") }, .{ .blockedId = user.get("_id") } } }, .{});
    var out: std.ArrayList([]const u8) = .empty;
    for (blocks) |b| try out.append(r.a, try r.str(if (val.same(b.get("userId"), user.get("_id"))) b.get("blockedId") else b.get("userId")));
    return out.items;
}

/// Every story the user may see right now: their own and those shared with them.
pub fn feed(r: *Rq, user: Val) ![]Val {
    const a = r.a;
    const list = try col().stories.find(a, .{ .@"$or" = .{ .{ .userId = user.get("_id") }, .{ .viewerIds = user.get("_id") } }, .expiresAt = .{ .@"$gt" = A.now() } }, .{ .sort = .{ .createdAt = 1 }, .limit = 2000 });
    if (list.len == 0) return list;
    // Someone who blocked the viewer since posting (or was blocked) drops out.
    const blocked = try blockedSet(r, user);
    var out: std.ArrayList(Val) = .empty;
    for (list) |st| if (!has(blocked, try r.str(st.get("userId")))) try out.append(a, st);
    return out.items;
}

/// The author can always watch (the archive); people it was shared with while it is up, and
/// afterwards only if the author pinned it.
fn canWatch(st: Val, user: Val) bool {
    if (val.same(st.get("userId"), user.get("_id"))) return true;
    if (!containsSame(st.get("viewerIds"), user.get("_id"))) return false;
    const exp = st.get("expiresAt");
    return (exp == .date and exp.date > A.nowMs()) or st.get("pinned").truthy();
}

fn blockedBetween(r: *Rq, x: Val, y: Val) !bool {
    return (try col().blocks.findOne(r.a, .{ .@"$or" = .{ .{ .userId = x, .blockedId = y }, .{ .userId = y, .blockedId = x } } }, .{ .projection = .{ ._id = 1 } })) != null;
}

pub fn viewable(r: *Rq, user: Val, story_id: Val) !Val {
    const st = (try col().stories.findOne(r.a, .{ ._id = story_id }, .{})) orelse return r.fail(404, "Glimpse not found", "story_not_found");
    try r.ensure(canWatch(st, user), "Glimpse not found", 404, "story_not_found");
    try r.ensure(val.same(st.get("userId"), user.get("_id")) or !(try blockedBetween(r, user.get("_id"), st.get("userId"))), "Glimpse not found", 404, "story_not_found");
    return st;
}

/// The author's own stories, newest first, including the ones that left the feed.
pub fn archive(r: *Rq, user: Val, before: ?A.ObjectId, limit: i64) ![]Val {
    const q = try val.from(r.a, .{ .userId = user.get("_id") });
    if (before) |b| try q.set("_id", .{ .@"$lt" = b });
    return col().stories.find(r.a, q, .{ .sort = .{ ._id = -1 }, .limit = @min(@max(1, limit), 100) });
}

/// Stories someone pinned to their profile that this user may watch, newest first.
pub fn pinnedOf(r: *Rq, user: Val, author_id: Val) ![]Val {
    const mine = val.same(author_id, user.get("_id"));
    if (!mine and try blockedBetween(r, user.get("_id"), author_id)) return &.{};
    const q = try val.from(r.a, .{ .userId = author_id, .pinned = true });
    if (!mine) try q.set("viewerIds", user.get("_id"));
    return col().stories.find(r.a, q, .{ .sort = .{ ._id = -1 }, .limit = Limits.pinned_stories });
}

fn assertPinRoom(r: *Rq, user: Val) !void {
    const n = try col().stories.count(r.a, .{ .userId = user.get("_id"), .pinned = true }, .{});
    try r.ensure(n < Limits.pinned_stories, try r.fmt("You can pin up to {d} glimpses to your profile", .{Limits.pinned_stories}), 400, "too_many_pinned");
}

/// Pins a story to the author's profile (it stays watchable after a day), or takes it off.
pub fn setPinned(r: *Rq, user: Val, story_id: Val, pinned: bool) !Val {
    const a = r.a;
    const st = (try col().stories.findOne(a, .{ ._id = story_id, .userId = user.get("_id") }, .{})) orelse return r.fail(404, "Glimpse not found", "story_not_found");
    if (st.get("pinned").truthy() == pinned) return st;
    if (pinned) try assertPinRoom(r, user);
    _ = try col().stories.updateOne(a, .{ ._id = st.get("_id") }, .{ .@"$set" = .{ .pinned = pinned } }, .{});
    var to: std.ArrayList(Val) = .empty;
    try to.append(a, st.get("userId"));
    try to.appendSlice(a, st.get("viewerIds").items());
    rt.toUsers(a, to.items, "story.pin", try val.from(a, .{ .id = try r.str(st.get("_id")), .userId = try r.str(st.get("userId")), .pinned = pinned }));
    const out = try val.clone(a, st);
    try out.set("pinned", pinned);
    return out;
}

/// Records a view. People who turned read receipts off are not listed.
pub fn markViewed(r: *Rq, user: Val, st: Val) !void {
    const a = r.a;
    if (val.same(st.get("userId"), user.get("_id"))) return;
    const res = try col().stories.updateOne(a, .{ ._id = st.get("_id"), .seenBy = .{ .@"$ne" = user.get("_id") } }, .{ .@"$push" = .{ .seenBy = user.get("_id") } }, .{});
    if (res.modified == 0 or (user.path("privacy.readReceipts") == .bool and !user.path("privacy.readReceipts").bool)) return;
    _ = try col().stories.updateOne(a, .{ ._id = st.get("_id"), .@"views.userId" = .{ .@"$ne" = user.get("_id") } }, .{ .@"$push" = .{ .views = .{ .userId = user.get("_id"), .at = A.now() } } }, .{});
    _ = rt.toUser(a, st.get("userId"), "story.view", try val.from(a, .{ .id = try r.str(st.get("_id")), .viewCount = st.get("views").len() + 1 }));
}

pub fn deleteStory(r: *Rq, user: Val, story_id: Val) !void {
    const st = (try col().stories.findOne(r.a, .{ ._id = story_id, .userId = user.get("_id") }, .{})) orelse return r.fail(404, "Glimpse not found", "story_not_found");
    try removeStories(r, &.{st});
}

fn removeStories(r: *Rq, list: []const Val) !void {
    const a = r.a;
    if (list.len == 0) return;
    var ids: std.ArrayList(Val) = .empty;
    var media_ids: std.ArrayList(Val) = .empty;
    for (list) |st| {
        try ids.append(a, st.get("_id"));
        try media_ids.appendSlice(a, st.get("mediaIds").items());
    }
    _ = try col().stories.deleteMany(a, .{ ._id = .{ .@"$in" = ids.items } });
    if (media_ids.items.len > 0) {
        _ = try col().mediaChunks.deleteMany(a, .{ .mediaId = .{ .@"$in" = media_ids.items } });
        _ = try col().media.deleteMany(a, .{ ._id = .{ .@"$in" = media_ids.items } });
    }
    for (list) |st| {
        var to: std.ArrayList(Val) = .empty;
        try to.append(a, st.get("userId"));
        try to.appendSlice(a, st.get("viewerIds").items());
        rt.toUsers(a, to.items, "story.delete", try val.from(a, .{ .id = try r.str(st.get("_id")), .userId = try r.str(st.get("userId")) }));
    }
}

/// Can this user read a story's file? (Used by the media routes.)
pub fn canReadStoryMedia(r: *Rq, user: Val, m: Val) !bool {
    if (!m.get("storyId").truthy()) return false;
    const st = (try col().stories.findOne(r.a, .{ ._id = m.get("storyId") }, .{ .projection = .{ .userId = 1, .viewerIds = 1, .expiresAt = 1, .pinned = 1 } })) orelse return false;
    return canWatch(st, user);
}

/// When an account is deleted its stories (archived and pinned too) go with it.
pub fn removeAllOf(r: *Rq, user_id: Val) !void {
    while (true) {
        const list = try col().stories.find(r.a, .{ .userId = user_id }, .{ .limit = 500 });
        if (list.len == 0) return;
        try removeStories(r, list);
    }
}
