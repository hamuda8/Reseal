//! The signed-in user (src/routes/account.js): profile, privacy, contacts, blocks, chat lock,
//! folders, keys, push and search. Every route here needs a signed-in user.

const std = @import("std");
const A = @import("../app.zig");
const web = @import("../web.zig");
const v = @import("../validate.zig");
const ser = @import("../serialize.zig");
const store = @import("../store.zig");
const rt = @import("../realtime.zig");
const keys = @import("../keys.zig");
const push = @import("../push.zig");
const auth = @import("../auth.zig");
const apps = @import("../apps.zig");
const wufour = @import("../wufour.zig");
const stories = @import("../stories.zig");
const moderation = @import("../moderation.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;
const Req = web.Req;

fn col() *A.Cols {
    return &A.app.col;
}

fn idv(x: A.ObjectId) Val {
    return .{ .id = x };
}

fn eq(x: Val, s: []const u8) bool {
    return x == .str and std.mem.eql(u8, x.str, s);
}

/// rateLimit(name, max, windowMs) middleware: per user (or per IP when signed out).
pub fn rateLimit(q: *Req, name: []const u8, max: f64, window_ms: f64) !void {
    const who = if (q.auth) |au| try q.r.str(au.user.get("_id")) else q.ip();
    if (!A.allow(try q.r.fmt("{s}:{s}", .{ name, who }), max, window_ms)) return q.r.fail(429, "Too many requests. Try again shortly.", "rate_limited");
}

pub fn handle(q: *Req) !bool {
    if (q.is(.GET, "/api/me")) return done(getMe(q));
    if (q.is(.PATCH, "/api/me")) return done(patchMe(q));
    if (q.is(.GET, "/api/username/:name")) return done(username(q));
    if (q.is(.DELETE, "/api/me")) return done(deleteMe(q));
    if (q.is(.POST, "/api/users/lookup")) return done(usersLookup(q));
    if (q.is(.POST, "/api/users/from-wufour")) return done(fromWufour(q));
    if (q.is(.GET, "/api/users/:id")) return done(getUser(q));
    if (q.is(.GET, "/api/users/:id/common-groups")) return done(commonGroups(q));
    if (q.is(.GET, "/api/search")) return done(search(q));
    if (q.is(.GET, "/api/search/messages")) return done(searchMessages(q));
    if (q.is(.GET, "/api/contacts")) return done(getContacts(q));
    if (q.is(.POST, "/api/contacts")) return done(addContact(q));
    if (q.is(.DELETE, "/api/contacts/:id")) return done(removeContact(q));
    if (q.is(.GET, "/api/blocks")) return done(getBlocks(q));
    if (q.is(.POST, "/api/blocks")) return done(addBlock(q));
    if (q.is(.DELETE, "/api/blocks/:id")) return done(removeBlock(q));
    if (q.is(.PUT, "/api/me/chat-lock")) return done(setLock(q));
    if (q.is(.POST, "/api/me/chat-lock/verify")) return done(verifyLock(q));
    if (q.is(.DELETE, "/api/me/chat-lock")) return done(removeLock(q));
    if (q.is(.GET, "/api/folders")) return done(getFolders(q));
    if (q.is(.POST, "/api/folders")) return done(addFolder(q));
    if (q.is(.PUT, "/api/folders/:id")) return done(putFolder(q));
    if (q.is(.POST, "/api/folders/order")) return done(orderFolders(q));
    if (q.is(.DELETE, "/api/folders/:id")) return done(deleteFolder(q));
    if (q.is(.GET, "/api/keys/backup")) return done(getBackup(q));
    if (q.is(.POST, "/api/keys/restore")) return done(restore(q));
    if (q.is(.PUT, "/api/keys/protection")) return done(protection(q));
    if (q.is(.PUT, "/api/keys")) return done(putKeys(q));
    if (q.is(.PUT, "/api/keys/backup")) return done(putBackup(q));
    if (q.is(.POST, "/api/keys/lookup")) return done(lookupKeys(q));
    if (q.is(.GET, "/api/keys/requests")) return done(keyRequests(q));
    if (q.is(.POST, "/api/push/subscribe")) return done(pushSubscribe(q));
    if (q.is(.POST, "/api/push/token")) return done(pushToken(q));
    if (q.is(.POST, "/api/push/unsubscribe")) return done(pushUnsubscribe(q));
    return false;
}

fn done(res: anyerror!void) anyerror!bool {
    try res;
    return true;
}

// ---- Profile ---------------------------------------------------------------------------------

fn getMe(q: *Req) !void {
    return q.json(.{ .user = try ser.me(q.r.a, q.user()) });
}

const PRIVACY_RULES = [_][]const u8{ "everyone", "contacts", "nobody" };

fn patchMe(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const b = try q.bodyObj();
    const me = q.user();
    const set = try Val.object(a);
    const unset = try Val.object(a);
    if (b.get("displayName") != .undef) {
        const name = try v.reqStr(r, b.get("displayName"), "displayName", .{ .min = 1, .max = 64 });
        try set.set("displayName", name);
        try set.set("displayNameLower", try v.jsLower(a, name));
    }
    if (b.get("bio") != .undef) try set.set("bio", try v.reqStr(r, b.get("bio"), "bio", .{ .max = 140 }));
    // Content checks (Wufour Moderation): the name and bio are visible to everyone.
    if (set.get("displayName") != .undef or set.get("bio") != .undef) {
        _ = try moderation.check(r, me, try val.from(a, .{ .type = "profile", .field = "me" }), try val.from(a, .{ .displayName = set.get("displayName"), .bio = set.get("bio") }), null);
    }
    if (b.get("username") != .undef) {
        try r.ensure(!me.get("appId").truthy(), "Usernames are managed by the app you are using", 400, null);
        if (b.get("username").truthy()) {
            const un = try v.reqStr(r, b.get("username"), "username", .{ .pattern = v.isUsername });
            try set.set("username", un);
            const lower = try v.jsLower(a, un);
            try set.set("usernameLower", lower);
            try r.ensure(!std.ascii.endsWithIgnoreCase(un, "bot"), "Only bots can have usernames ending in \"bot\"", 400, null);
            const taken = try col().chats.findOne(a, .{ .usernameLower = lower }, .{ .projection = .{ ._id = 1 } });
            try r.ensure(taken == null, "That username is taken", 409, "username_taken");
        } else {
            try unset.set("username", "");
            try unset.set("usernameLower", "");
        }
    }
    if (b.get("avatar") != .undef) {
        if (b.get("avatar").truthy()) {
            const m = try col().media.findOne(a, .{ ._id = try v.reqId(r, b.get("avatar"), "avatar"), .ownerId = me.get("_id"), .status = "ready" }, .{});
            try r.ensure(m != null and std.mem.startsWith(u8, m.?.get("mime").asStr() orelse "", "image/"), "Your photo must be an image you uploaded", 400, null);
            _ = try col().media.updateOne(a, .{ ._id = m.?.get("_id") }, .{ .@"$set" = .{ .public = true } }, .{});
            try set.set("avatar", m.?.get("_id"));
        } else try set.set("avatar", .null);
    }
    if (b.get("privacy") != .undef) {
        const p = try v.reqObj(r, b.get("privacy"), "privacy");
        for ([_][]const u8{ "lastSeen", "avatar", "calls", "groups", "forwards" }) |k| {
            if (p.get(k) != .undef) try set.set(try r.fmt("privacy.{s}", .{k}), try v.reqOneOf(r, p.get(k), try r.fmt("privacy.{s}", .{k}), &PRIVACY_RULES));
        }
        if (p.get("readReceipts") != .undef) try set.set("privacy.readReceipts", try v.reqBool(r, p.get("readReceipts"), "privacy.readReceipts"));
    }
    if (b.get("settings") != .undef) {
        // Client preferences synced across devices (theme, sounds, ...). Bounded, opaque to the server.
        const s = try v.reqObj(r, b.get("settings"), "settings");
        try r.ensure(v.utf16Len(try val.stringify(a, s)) <= 8192, "settings are too large", 400, null);
        _ = try v.metadata(r, s, "settings", 8192);
        for (s.keys(), s.vals()) |kv_k, kv_v| try set.set(try r.fmt("settings.{s}", .{kv_k}), kv_v);
    }
    const update = try Val.object(a);
    if (set.len() > 0) try update.set("$set", set);
    if (unset.len() > 0) try update.set("$unset", unset);
    if (update.len() > 0) _ = col().users.updateOne(a, .{ ._id = me.get("_id") }, update, .{}) catch |e| {
        if (e == error.DuplicateKey) return r.fail(409, "That username is taken", "username_taken");
        return e;
    };
    const fresh = (try col().users.findOne(a, .{ ._id = me.get("_id") }, .{})) orelse me;
    if (set.get("privacy.lastSeen") != .undef) rt.updatePrivacy(a, fresh.get("_id"), fresh.get("privacy"));
    _ = rt.toUser(a, fresh.get("_id"), "me.update", try ser.me(a, fresh));
    // Chat partners refresh the name and photo they show.
    if (set.get("displayName").truthy() or set.get("avatar") != .undef or set.get("username").truthy() or unset.get("username") != .undef) {
        const chats = try col().members.find(a, .{ .userId = fresh.get("_id"), .status = "active", .chatType = .{ .@"$in" = .{ "private", "group" } } }, .{ .projection = .{ .chatId = 1 }, .limit = 500 });
        var ids: std.ArrayList(Val) = .empty;
        for (chats) |c| try ids.append(a, c.get("chatId"));
        const peers = try col().members.find(a, .{ .chatId = .{ .@"$in" = ids.items }, .status = "active", .userId = .{ .@"$ne" = fresh.get("_id") } }, .{ .projection = .{ .userId = 1 } });
        var pids: std.ArrayList(Val) = .empty;
        for (peers) |p| try pids.append(a, p.get("userId"));
        rt.toUsers(a, pids.items, "user.update", try val.from(a, .{ .id = try r.str(fresh.get("_id")), .displayName = fresh.get("displayName"), .username = if (fresh.get("username").truthy()) fresh.get("username") else Val.null, .avatar = if (fresh.get("avatar").truthy()) Val{ .str = try r.str(fresh.get("avatar")) } else Val.null }));
    }
    return q.json(.{ .user = try ser.me(a, fresh) });
}

fn username(q: *Req) !void {
    const a = q.r.a;
    const name = q.param("name");
    if (!v.isUsername(name)) return q.json(.{ .available = false, .reason = "Use 4-32 letters, numbers and underscores, starting with a letter." });
    const lower = try v.jsLower(a, name);
    const u = try col().users.findOne(a, .{ .usernameLower = lower }, .{ .projection = .{ ._id = 1 } });
    const c = try col().chats.findOne(a, .{ .usernameLower = lower }, .{ .projection = .{ ._id = 1 } });
    const mine = u != null and val.same(u.?.get("_id"), q.user().get("_id"));
    const ok = mine or (u == null and c == null);
    return q.json(.{ .available = ok, .reason = if (ok) Val.null else Val.string("That username is taken.") });
}

fn deleteMe(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    try rateLimit(q, "delete-account", 3, 3600_000);
    const me = q.user();
    try r.ensure(eq(q.b("confirm"), "DELETE"), "Send { \"confirm\": \"DELETE\" } to delete your account", 400, null);
    const now = A.now();
    _ = try col().users.updateOne(a, .{ ._id = me.get("_id") }, .{
        .@"$set" = .{ .deletedAt = now, .displayName = "Deleted account", .displayNameLower = "deleted account", .bio = "", .avatar = Val.null },
        .@"$unset" = .{ .username = "", .usernameLower = "", .keys = "", .wufourId = "", .externalId = "" },
    }, .{});
    const memberships = try col().members.find(a, .{ .userId = me.get("_id"), .status = "active" }, .{});
    _ = try col().members.updateMany(a, .{ .userId = me.get("_id") }, .{ .@"$set" = .{ .status = "left", .leftAt = now } }, .{});
    _ = try col().contacts.deleteMany(a, .{ .@"$or" = .{ .{ .userId = me.get("_id") }, .{ .contactId = me.get("_id") } } });
    _ = try col().blocks.deleteMany(a, .{ .userId = me.get("_id") });
    _ = try col().folders.deleteMany(a, .{ .userId = me.get("_id") });
    _ = try col().pushSubs.deleteMany(a, .{ .userId = me.get("_id") });
    _ = try col().pushSubs.deleteMany(a, .{ .nativeUserId = me.get("_id") });
    _ = try col().chatKeys.deleteMany(a, .{ .userId = me.get("_id") });
    _ = try col().sessions.deleteMany(a, .{ .userId = me.get("_id") });
    try stories.removeAllOf(r, me.get("_id"));
    for (memberships) |m| rt.leftChat(me.get("_id"), m.get("chatId"));
    return q.json(.{ .ok = true });
}

// ---- Users ------------------------------------------------------------------------------------

/// Users as a viewer sees them, with their contact flags.
pub fn usersFor(r: *Rq, viewer: Val, users: []const Val, full: bool) !Val {
    const a = r.a;
    var ids: std.ArrayList(Val) = .empty;
    for (users) |u| try ids.append(a, u.get("_id"));
    const theirs = try col().contacts.find(a, .{ .userId = .{ .@"$in" = ids.items }, .contactId = viewer.get("_id") }, .{ .projection = .{ .userId = 1 } });
    const mine = try col().contacts.find(a, .{ .userId = viewer.get("_id"), .contactId = .{ .@"$in" = ids.items } }, .{ .projection = .{ .contactId = 1, .name = 1 } });
    var out = try Val.array(a);
    for (users) |u| {
        var they_have_me = false;
        for (theirs) |c| if (val.same(c.get("userId"), u.get("_id"))) {
            they_have_me = true;
        };
        const o = try ser.user(a, u, viewer.get("_id"), .{ .is_contact = they_have_me, .full = full });
        var c_: ?Val = null;
        for (mine) |c| if (val.same(c.get("contactId"), u.get("_id"))) {
            c_ = c;
        };
        try o.set("inContacts", c_ != null);
        if (c_) |c| if (c.get("name").truthy()) try o.set("contactName", c.get("name"));
        try out.push(o);
    }
    return out;
}

fn scope(u: Val) Val {
    return if (u.get("appId").truthy()) u.get("appId") else Val.null;
}

fn usersLookup(q: *Req) !void {
    const a = q.r.a;
    const ids = try v.reqIds(&q.r, q.b("ids"), "ids", 500);
    var list = try Val.array(a);
    for (ids) |x| try list.push(idv(x));
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = list }, .appId = scope(q.user()) }, .{});
    return q.json(.{ .users = try usersFor(&q.r, q.user(), users, false) });
}

fn fromWufour(q: *Req) !void {
    const r = &q.r;
    try rateLimit(q, "from-wufour", 60, 3600_000);
    try r.ensure(!q.user().get("appId").truthy(), "User not found", 404, "user_not_found");
    const wu = (try wufour.findById(r, try v.reqStr(r, q.b("wufourId"), "wufourId", .{ .max = 64 }))) orelse return r.fail(404, "That Wufour account was not found", "user_not_found");
    const u = try auth.upsertWufourUser(r, try val.from(r.a, .{ .userId = wu.get("id"), .username = wu.get("username") }));
    const out = try usersFor(r, q.user(), &.{u}, false);
    return q.json(.{ .user = out.items()[0] });
}

fn getUser(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const id = try v.reqId(r, q.pv("id"), "id");
    const me = q.user();
    const u = (try col().users.findOne(a, .{ ._id = id }, .{})) orelse return r.fail(404, "User not found", "user_not_found");
    try r.ensure(std.mem.eql(u8, try val.toStr(a, if (u.get("appId").truthy()) u.get("appId") else Val.string("")), try val.toStr(a, if (me.get("appId").truthy()) me.get("appId") else Val.string(""))), "User not found", 404, "user_not_found");
    const out = (try usersFor(r, me, &.{u}, true)).items()[0];
    const blocked = try col().blocks.findOne(a, .{ .userId = me.get("_id"), .blockedId = u.get("_id") }, .{});
    const blocked_me = try col().blocks.findOne(a, .{ .userId = u.get("_id"), .blockedId = me.get("_id") }, .{});
    try out.set("blocked", blocked != null);
    if (blocked_me != null) {
        try out.set("presence", .{ .status = "long_ago" });
        try out.set("avatar", .null);
    }
    // Groups you share with this person.
    const mine = try col().members.find(a, .{ .userId = me.get("_id"), .status = "active", .chatType = "group" }, .{ .projection = .{ .chatId = 1 } });
    var ids: std.ArrayList(Val) = .empty;
    for (mine) |m| try ids.append(a, m.get("chatId"));
    try out.set("commonGroups", try col().members.count(a, .{ .userId = u.get("_id"), .status = "active", .chatId = .{ .@"$in" = ids.items } }, .{}));
    if (eq(u.get("kind"), "bot")) {
        const bot = try col().bots.findOne(a, .{ ._id = u.get("_id") }, .{ .projection = .{ .starters = 1, .model = 1 } });
        const b = try val.clone(a, if (out.get("bot").truthy()) out.get("bot") else try Val.object(a));
        try b.set("starters", if (bot != null and bot.?.get("starters").truthy()) bot.?.get("starters") else try Val.array(a));
        try b.set("model", if (bot != null and bot.?.get("model").truthy()) bot.?.get("model") else Val.null);
        try out.set("bot", b);
    }
    return q.json(.{ .user = out });
}

fn commonGroups(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const id = try v.reqId(r, q.pv("id"), "id");
    const mine = try col().members.find(a, .{ .userId = q.user().get("_id"), .status = "active", .chatType = "group" }, .{ .projection = .{ .chatId = 1 } });
    var ids: std.ArrayList(Val) = .empty;
    for (mine) |m| try ids.append(a, m.get("chatId"));
    const shared = try col().members.find(a, .{ .userId = id, .status = "active", .chatId = .{ .@"$in" = ids.items } }, .{ .projection = .{ .chatId = 1 }, .limit = 100 });
    var sids: std.ArrayList(Val) = .empty;
    for (shared) |m| try sids.append(a, m.get("chatId"));
    const chats = try col().chats.find(a, .{ ._id = .{ .@"$in" = sids.items } }, .{ .projection = .{ .title = 1, .avatar = 1, .memberCount = 1, .type = 1 } });
    var out = try Val.array(a);
    for (chats) |c| try out.push(try val.from(a, .{ .id = try r.str(c.get("_id")), .title = c.get("title"), .avatar = if (c.get("avatar").truthy()) Val{ .str = try r.str(c.get("avatar")) } else Val.null, .color = try ser.colorOf(a, c.get("_id")), .memberCount = c.get("memberCount"), .type = c.get("type") }));
    return q.json(.{ .chats = out });
}

const SEARCH_MS = 1500;
const SEARCH_CHATS = 3000;

/// RegExp-escaped (str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).
pub fn escapeRe(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, ".*+?^${}()|[]\\", c) != null) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.items;
}

fn regex(a: std.mem.Allocator, pattern: []const u8, options: []const u8) !Val {
    _ = a;
    return .{ .regex = .{ .pattern = pattern, .options = options } };
}

fn search(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    try rateLimit(q, "search", 60, 60_000);
    var text = try v.reqStr(r, q.qv("q"), "q", .{ .min = 1, .max = 64 });
    if (text.len > 0 and text[0] == '@') text = text[1..];
    const me = q.user();
    const scope_ = scope(me);
    const lower = try v.jsLower(a, text);
    const re = try regex(a, try r.fmt("^{s}", .{try escapeRe(a, lower)}), "");
    const word_re = try regex(a, try r.fmt("(^|\\s){s}", .{try escapeRe(a, lower)}), "");
    if (scope_ != .null) try apps.assertFeature(r, me, "userSearch", "Search is turned off in this app");
    const username_key = if (scope_ != .null) try regex(a, try r.fmt("^{s}", .{try escapeRe(a, try r.fmt("{s}:{s}", .{ try r.str(scope_), lower }))}), "") else re;
    const long = v.utf16Len(text) >= 2;
    const by_username = if (long) try col().users.find(a, .{ .appId = scope_, .usernameLower = username_key, .deletedAt = .{ .@"$exists" = false } }, .{ .limit = 15, .maxTimeMS = SEARCH_MS }) else val.none[0..];
    const by_name = if (long) try col().users.find(a, .{ .appId = scope_, .displayNameLower = word_re, .deletedAt = .{ .@"$exists" = false }, .kind = .{ .@"$ne" = "bot" } }, .{ .limit = 15, .maxTimeMS = SEARCH_MS }) else val.none[0..];
    const public_chats = if (long) try col().chats.find(a, .{ .appId = scope_, .usernameLower = re, .deletedAt = .{ .@"$exists" = false } }, .{ .limit = 10, .maxTimeMS = SEARCH_MS }) else val.none[0..];
    const memberships = try col().members.find(a, .{ .userId = me.get("_id"), .status = "active" }, .{ .projection = .{ .chatId = 1 }, .sort = .{ .lastActivityAt = -1 }, .limit = SEARCH_CHATS, .maxTimeMS = SEARCH_MS });
    var mids: std.ArrayList(Val) = .empty;
    for (memberships) |m| try mids.append(a, m.get("chatId"));
    const my_chats = try col().chats.find(a, .{ ._id = .{ .@"$in" = mids.items }, .title = .{ .@"$regex" = try escapeRe(a, text), .@"$options" = "i" }, .deletedAt = .{ .@"$exists" = false } }, .{ .limit = 20, .maxTimeMS = SEARCH_MS });
    var users: std.ArrayList(Val) = .empty;
    for ([_][]Val{ by_username, by_name }) |list| for (list) |u| {
        var dup = false;
        for (users.items) |x| if (val.same(x.get("_id"), u.get("_id"))) {
            dup = true;
        };
        if (dup or val.same(u.get("_id"), me.get("_id"))) continue;
        try users.append(a, u);
    };
    var bot_ids: std.ArrayList(Val) = .empty;
    for (users.items) |u| if (eq(u.get("kind"), "bot")) try bot_ids.append(a, u.get("_id"));
    const bots = try col().bots.find(a, .{ ._id = .{ .@"$in" = bot_ids.items } }, .{ .projection = .{ .public = 1, .ownerId = 1, .appId = 1 } });
    var visible: std.ArrayList(Val) = .empty;
    for (users.items) |u| {
        if (eq(u.get("kind"), "bot")) {
            var ok = false;
            for (bots) |b| if (val.same(b.get("_id"), u.get("_id")) and (b.get("public").truthy() or val.same(b.get("ownerId"), me.get("_id")) or (b.get("appId").truthy() and val.same(b.get("appId"), me.get("appId"))))) {
                ok = true;
            };
            if (!ok) continue;
        }
        if (visible.items.len < 20) try visible.append(a, u);
    }
    // Wufour accounts that have not opened Reseal yet can be messaged too.
    var wufour_list = try Val.array(a);
    if (scope_ == .null and v.utf16Len(text) >= 3 and wufour.directoryEnabled()) {
        const found = try wufour.lookup(r, text);
        var fids: std.ArrayList(Val) = .empty;
        for (found) |f| try fids.append(a, f.get("id"));
        const known = try col().users.find(a, .{ .wufourId = .{ .@"$in" = fids.items } }, .{ .projection = .{ .wufourId = 1 } });
        for (found) |f| {
            var k = false;
            for (known) |x| if (val.same(x.get("wufourId"), f.get("id"))) {
                k = true;
            };
            if (k or val.same(f.get("id"), me.get("wufourId"))) continue;
            try wufour_list.push(try val.from(a, .{ .wufourId = f.get("id"), .username = f.get("username"), .displayName = f.get("username") }));
        }
    }
    var chats_out = try Val.array(a);
    var all: std.ArrayList(Val) = .empty;
    try all.appendSlice(a, my_chats);
    for (public_chats) |c| {
        var dup = false;
        for (my_chats) |m| if (val.same(m.get("_id"), c.get("_id"))) {
            dup = true;
        };
        if (!dup) try all.append(a, c);
    }
    for (all.items[0..@min(20, all.items.len)]) |c| {
        var member = false;
        for (memberships) |m| if (val.same(m.get("chatId"), c.get("_id"))) {
            member = true;
        };
        try chats_out.push(try val.from(a, .{
            .id = try r.str(c.get("_id")),
            .type = c.get("type"),
            .title = c.get("title"),
            .username = if (c.get("username").truthy()) c.get("username") else Val.null,
            .avatar = if (c.get("avatar").truthy()) Val{ .str = try r.str(c.get("avatar")) } else Val.null,
            .color = try ser.colorOf(a, c.get("_id")),
            .memberCount = c.get("memberCount"),
            .encrypted = c.get("encrypted").truthy(),
            .member = member,
        }));
    }
    return q.json(.{ .users = try usersFor(r, me, visible.items, false), .wufour = wufour_list, .chats = chats_out });
}

fn searchMessages(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    try rateLimit(q, "search", 60, 60_000);
    const text = try v.reqStr(r, q.qv("q"), "q", .{ .min = 2, .max = 100 });
    const me = q.user();
    const memberships = try col().members.find(a, .{ .userId = me.get("_id"), .status = "active" }, .{ .projection = .{ .chatId = 1, .clearedSeq = 1 }, .sort = .{ .lastActivityAt = -1 }, .limit = SEARCH_CHATS, .maxTimeMS = SEARCH_MS });
    var chat_ids: std.ArrayList(Val) = .empty;
    const only = q.query("chatId");
    for (memberships) |m| {
        if (only) |o| if (!std.mem.eql(u8, try r.str(m.get("chatId")), o)) continue;
        try chat_ids.append(a, m.get("chatId"));
    }
    const plain = try col().chats.find(a, .{ ._id = .{ .@"$in" = chat_ids.items }, .encrypted = false }, .{ .projection = .{ .type = 1, .signMessages = 1, .appId = 1 }, .maxTimeMS = SEARCH_MS });
    var pids: std.ArrayList(Val) = .empty;
    for (plain) |c| try pids.append(a, c.get("_id"));
    const visible = try val.from(a, .{ .deletedAt = .{ .@"$exists" = false }, .hiddenFor = .{ .@"$ne" = me.get("_id") }, .seq = .{ .@"$ne" = Val.null } });
    var rows: []Val = undefined;
    if (me.get("appId").truthy()) {
        // An app user's chats all belong to the app, which searches its own storage.
        const found = try store.searchApp(r, me.get("appId"), pids.items, text);
        var keep: std.ArrayList(Val) = .empty;
        for (found) |m| if (store.matches(a, m, visible)) try keep.append(a, m);
        rows = keep.items;
    } else {
        const filter = try val.from(a, .{ .chatId = .{ .@"$in" = pids.items }, .@"$text" = .{ .@"$search" = text } });
        for (visible.keys(), visible.vals()) |kv_k, kv_v| try filter.set(kv_k, kv_v);
        rows = try col().messages.find(a, filter, .{ .projection = .{ .score = .{ .@"$meta" = "textScore" } }, .sort = .{ .createdAt = -1 }, .limit = 50, .maxTimeMS = SEARCH_MS });
    }
    var out = try Val.array(a);
    for (rows) |m| {
        var cleared: i64 = 0;
        for (memberships) |mm| if (val.same(mm.get("chatId"), m.get("chatId"))) {
            cleared = mm.get("clearedSeq").asInt() orelse 0;
        };
        if ((m.get("seq").asNum() orelse 0) <= @as(f64, @floatFromInt(cleared))) continue;
        var chat: Val = .null;
        for (plain) |c| if (val.same(c.get("_id"), m.get("chatId"))) {
            chat = c;
        };
        try out.push(try ser.message(a, m, me.get("_id"), chat));
    }
    return q.json(.{ .messages = out });
}

// ---- Contacts and blocks ----------------------------------------------------------------------

fn contactIdsOf(r: *Rq, user: Val) ![]Val {
    const rows = try col().contacts.find(r.a, .{ .userId = user.get("_id") }, .{ .projection = .{ .contactId = 1 } });
    var out: std.ArrayList(Val) = .empty;
    for (rows) |c| try out.append(r.a, c.get("contactId"));
    return out.items;
}

fn getContacts(q: *Req) !void {
    const a = q.r.a;
    const rows = try col().contacts.find(a, .{ .userId = q.user().get("_id") }, .{});
    var ids: std.ArrayList(Val) = .empty;
    for (rows) |c| try ids.append(a, c.get("contactId"));
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = ids.items }, .deletedAt = .{ .@"$exists" = false } }, .{});
    return q.json(.{ .contacts = try usersFor(&q.r, q.user(), users, false) });
}

fn addContact(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const me = q.user();
    const id = try v.reqId(r, q.b("userId"), "userId");
    try r.ensure(!val.same(idv(id), me.get("_id")), "You cannot add yourself", 400, null);
    const u = (try col().users.findOne(a, .{ ._id = id, .appId = scope(me), .deletedAt = .{ .@"$exists" = false } }, .{})) orelse return r.fail(404, "User not found", "user_not_found");
    const name = try v.str(r, q.b("name"), "name", .{ .max = 64, .optional = true });
    _ = try col().contacts.updateOne(a, .{ .userId = me.get("_id"), .contactId = id }, .{ .@"$set" = .{ .name = if (name) |n| (if (n.len > 0) Val{ .str = n } else Val.null) else Val.null }, .@"$setOnInsert" = .{ .createdAt = A.now() } }, .{ .upsert = true });
    rt.updateContacts(me.get("_id"), try contactIdsOf(r, me));
    const out = try usersFor(r, me, &.{u}, false);
    return q.json(.{ .contact = out.items()[0] });
}

fn removeContact(q: *Req) !void {
    const r = &q.r;
    _ = try col().contacts.deleteOne(r.a, .{ .userId = q.user().get("_id"), .contactId = try v.reqId(r, q.pv("id"), "id") });
    rt.updateContacts(q.user().get("_id"), try contactIdsOf(r, q.user()));
    return q.json(.{ .ok = true });
}

fn getBlocks(q: *Req) !void {
    const a = q.r.a;
    const rows = try col().blocks.find(a, .{ .userId = q.user().get("_id") }, .{ .sort = .{ .createdAt = -1 } });
    var ids: std.ArrayList(Val) = .empty;
    for (rows) |b| try ids.append(a, b.get("blockedId"));
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = ids.items } }, .{});
    return q.json(.{ .users = try usersFor(&q.r, q.user(), users, false) });
}

fn addBlock(q: *Req) !void {
    const r = &q.r;
    const id = try v.reqId(r, q.b("userId"), "userId");
    try r.ensure(!val.same(idv(id), q.user().get("_id")), "You cannot block yourself", 400, null);
    _ = try col().blocks.updateOne(r.a, .{ .userId = q.user().get("_id"), .blockedId = id }, .{ .@"$setOnInsert" = .{ .createdAt = A.now() } }, .{ .upsert = true });
    _ = rt.toUser(r.a, q.user().get("_id"), "blocks.update", try val.from(r.a, .{ .userId = try r.str(idv(id)), .blocked = true }));
    return q.json(.{ .ok = true });
}

fn removeBlock(q: *Req) !void {
    const r = &q.r;
    const id = try v.reqId(r, q.pv("id"), "id");
    _ = try col().blocks.deleteOne(r.a, .{ .userId = q.user().get("_id"), .blockedId = id });
    _ = rt.toUser(r.a, q.user().get("_id"), "blocks.update", try val.from(r.a, .{ .userId = try r.str(idv(id)), .blocked = false }));
    return q.json(.{ .ok = true });
}

// ---- Chat lock: one code unlocks every locked chat, on every device. The server keeps a slow
// salted hash only. ------------------------------------------------------------------------------

const LOCK_ITERATIONS = 210_000;

fn lockHash(code: []const u8, salt: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&out, code, salt, LOCK_ITERATIONS, std.crypto.auth.hmac.sha2.HmacSha256);
    return out;
}

fn lockCodeMatches(r: *Rq, user: Val, code: Val) !bool {
    const lock = user.get("chatLock");
    if (!lock.truthy() or code != .str or code.str.len == 0) return false;
    const salt = try A.lenientBase64(r.a, lock.get("salt").asStr() orelse "");
    const want = try A.lenientBase64(r.a, lock.get("hash").asStr() orelse "");
    const got = try lockHash(code.str, salt);
    return want.len == 32 and std.crypto.timing_safe.eql([32]u8, got, want[0..32].*);
}

fn b64e(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    return std.base64.standard.Encoder.encode(out, bytes);
}

fn setLock(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    try rateLimit(q, "chat-lock", 10, 3600_000);
    const me = q.user();
    const code = try v.reqStr(r, q.b("code"), "code", .{ .min = 4, .max = 64, .trim = false });
    if (me.get("chatLock").truthy()) try r.ensure(try lockCodeMatches(r, me, q.b("current")), "Your current chat lock code is not right", 403, "wrong_code");
    var salt: [16]u8 = undefined;
    A.app.io.random(&salt);
    const hash = try lockHash(code, &salt);
    const lock = try val.from(a, .{ .salt = try b64e(a, &salt), .hash = try b64e(a, &hash), .updatedAt = A.now() });
    _ = try col().users.updateOne(a, .{ ._id = me.get("_id") }, .{ .@"$set" = .{ .chatLock = lock } }, .{});
    const u = try val.clone(a, me);
    try u.set("chatLock", lock);
    return q.json(.{ .user = try ser.me(a, u) });
}

fn verifyLock(q: *Req) !void {
    const r = &q.r;
    try rateLimit(q, "chat-lock-verify", 8, 15 * 60_000);
    try r.ensure(q.user().get("chatLock").truthy(), "You have not set a chat lock code", 400, "no_lock_code");
    try r.ensure(try lockCodeMatches(r, q.user(), q.b("code")), "That code is not right", 403, "wrong_code");
    return q.json(.{ .ok = true });
}

fn removeLock(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    try rateLimit(q, "chat-lock-verify", 8, 15 * 60_000);
    const me = q.user();
    try r.ensure(try lockCodeMatches(r, me, q.b("code")), "That code is not right", 403, "wrong_code");
    const locked = try col().members.find(a, .{ .userId = me.get("_id"), .locked = true }, .{});
    _ = try col().members.updateMany(a, .{ .userId = me.get("_id"), .locked = true }, .{ .@"$unset" = .{ .locked = "" } }, .{});
    _ = try col().users.updateOne(a, .{ ._id = me.get("_id") }, .{ .@"$unset" = .{ .chatLock = "" } }, .{});
    var ids: std.ArrayList(Val) = .empty;
    for (locked) |m| try ids.append(a, m.get("chatId"));
    const list = try col().chats.find(a, .{ ._id = .{ .@"$in" = ids.items } }, .{});
    for (list) |chat| {
        for (locked) |m| if (val.same(m.get("chatId"), chat.get("_id"))) {
            const mm = try val.clone(a, m);
            try mm.set("locked", false);
            _ = rt.toUser(a, me.get("_id"), "chat.state", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .me = (try ser.chat(a, chat, mm, me.get("_id"), .{})).get("me") }));
            break;
        };
    }
    const u = try val.clone(a, me);
    u.del("chatLock");
    return q.json(.{ .user = try ser.me(a, u) });
}

// ---- Chat folders (filters live on the client; the server stores and syncs them) ------------

fn cleanFolder(r: *Rq, b: Val) !Val {
    const a = r.a;
    const types = [_][]const u8{ "contacts", "noncontacts", "groups", "channels", "bots" };
    var include = try Val.array(a);
    for (b.get("include").items()) |t| {
        const s = t.asStr() orelse continue;
        var known = false;
        for (types) |x| if (std.mem.eql(u8, x, s)) {
            known = true;
        };
        var dup = false;
        for (include.items()) |y| if (std.mem.eql(u8, y.str, s)) {
            dup = true;
        };
        if (known and !dup) try include.push(t);
    }
    const emoji = try v.str(r, b.get("emoji"), "emoji", .{ .max = 8, .optional = true });
    var chat_ids = try Val.array(a);
    for (try v.reqIds(r, if (b.get("chatIds").truthy()) b.get("chatIds") else try Val.array(a), "chatIds", 200)) |x| try chat_ids.push(idv(x));
    var ex_ids = try Val.array(a);
    for (try v.reqIds(r, if (b.get("excludeChatIds").truthy()) b.get("excludeChatIds") else try Val.array(a), "excludeChatIds", 200)) |x| try ex_ids.push(idv(x));
    return val.from(a, .{
        .name = try v.reqStr(r, b.get("name"), "name", .{ .min = 1, .max = 24 }),
        .emoji = if (emoji) |e| (if (e.len > 0) Val{ .str = e } else Val.null) else Val.null,
        .include = include,
        .chatIds = chat_ids,
        .excludeChatIds = ex_ids,
        .excludeMuted = b.get("excludeMuted").isTrue(),
        .excludeRead = b.get("excludeRead").isTrue(),
        .excludeArchived = !(b.get("excludeArchived") == .bool and !b.get("excludeArchived").bool),
    });
}

fn folderOut(r: *Rq, f: Val) !Val {
    const a = r.a;
    const out = try val.clone(a, f);
    try out.set("id", Val{ .str = try r.str(f.get("_id")) });
    try out.set("_id", .undef);
    try out.set("userId", .undef);
    var ids = try Val.array(a);
    for (f.get("chatIds").items()) |x| try ids.push(Val{ .str = try r.str(x) });
    try out.set("chatIds", ids);
    var ex = try Val.array(a);
    for (f.get("excludeChatIds").items()) |x| try ex.push(Val{ .str = try r.str(x) });
    try out.set("excludeChatIds", ex);
    return out;
}

fn getFolders(q: *Req) !void {
    const a = q.r.a;
    const rows = try col().folders.find(a, .{ .userId = q.user().get("_id") }, .{ .sort = .{ .order = 1 } });
    var out = try Val.array(a);
    for (rows) |f| try out.push(try folderOut(&q.r, f));
    return q.json(.{ .folders = out });
}

fn addFolder(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const n = try col().folders.count(a, .{ .userId = q.user().get("_id") }, .{});
    try r.ensure(n < A.Limits.folders, try r.fmt("You can have up to {d} folders", .{A.Limits.folders}), 400, null);
    const doc = try val.from(a, .{ .userId = q.user().get("_id") });
    const folder = try cleanFolder(r, try q.bodyObj());
    for (folder.keys(), folder.vals()) |fk, fv| try doc.set(fk, fv);
    try doc.set("order", n);
    try doc.set("createdAt", A.now());
    _ = try col().folders.insertOne(a, doc);
    _ = rt.toUser(a, q.user().get("_id"), "folders.update", try Val.object(a));
    return q.json(.{ .folder = try folderOut(r, doc) });
}

fn putFolder(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const id = try v.reqId(r, q.pv("id"), "id");
    const updated = (try col().folders.findOneAndUpdate(a, .{ ._id = id, .userId = q.user().get("_id") }, .{ .@"$set" = try cleanFolder(r, try q.bodyObj()) }, .{ .returnDocument = .after })) orelse return r.fail(404, "Folder not found", null);
    _ = rt.toUser(a, q.user().get("_id"), "folders.update", try Val.object(a));
    return q.json(.{ .folder = try folderOut(r, updated) });
}

fn orderFolders(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const ids = try v.reqIds(r, q.b("ids"), "ids", 50);
    for (ids, 0..) |id, order| _ = try col().folders.updateOne(a, .{ ._id = id, .userId = q.user().get("_id") }, .{ .@"$set" = .{ .order = order } }, .{});
    _ = rt.toUser(a, q.user().get("_id"), "folders.update", try Val.object(a));
    return q.json(.{ .ok = true });
}

fn deleteFolder(q: *Req) !void {
    const r = &q.r;
    _ = try col().folders.deleteOne(r.a, .{ ._id = try v.reqId(r, q.pv("id"), "id"), .userId = q.user().get("_id") });
    _ = rt.toUser(r.a, q.user().get("_id"), "folders.update", try Val.object(r.a));
    return q.json(.{ .ok = true });
}

// ---- End-to-end encryption keys ---------------------------------------------------------------

fn getBackup(q: *Req) !void {
    const r = &q.r;
    try rateLimit(q, "key-backup", 20, 3600_000);
    const k = q.user().get("keys");
    try r.ensure(k.get("enc").truthy(), "No encryption keys yet", 404, "no_keys");
    // The passcode-protected backup (advanced protection); the automatic one is /keys/restore.
    const b = k.get("backup");
    return q.json(.{ .enc = k.get("enc"), .sig = k.get("sig"), .version = if (k.get("version").truthy()) k.get("version") else Val.number(1), .mode = if (k.get("mode").truthy()) k.get("mode") else Val.string("advanced"), .backup = .{ .passcode = b.get("passcode"), .recovery = b.get("recovery") } });
}

fn restore(q: *Req) !void {
    try rateLimit(q, "key-restore", 20, 3600_000);
    return q.json(try keys.restoreEscrow(&q.r, q.user(), q.header("user-agent") orelse ""));
}

fn protection(q: *Req) !void {
    const r = &q.r;
    try rateLimit(q, "keys", 10, 3600_000);
    try keys.setProtection(r, q.user(), try q.bodyObj());
    const fresh = (try col().users.findOne(r.a, .{ ._id = q.user().get("_id") }, .{})) orelse q.user();
    _ = rt.toUser(r.a, q.user().get("_id"), "me.update", try ser.me(r.a, fresh));
    return q.json(.{ .ok = true, .mode = fresh.path("keys.mode") });
}

fn putKeys(q: *Req) !void {
    const r = &q.r;
    try rateLimit(q, "keys", 10, 3600_000);
    const user = try val.clone(r.a, q.user());
    const k = try keys.publishUserKeys(r, user, try q.bodyObj());
    _ = rt.toUser(r.a, q.user().get("_id"), "me.update", try ser.me(r.a, user));
    return q.json(.{ .ok = true, .version = k.get("version") });
}

fn putBackup(q: *Req) !void {
    try rateLimit(q, "keys", 10, 3600_000);
    try keys.updateBackup(&q.r, q.user(), try q.bodyObj());
    return q.json(.{ .ok = true });
}

fn lookupKeys(q: *Req) !void {
    const r = &q.r;
    const ids = try v.reqIds(r, q.b("userIds"), "userIds", 1000);
    var list: std.ArrayList(Val) = .empty;
    for (ids) |x| try list.append(r.a, idv(x));
    return q.json(.{ .keys = try keys.publicKeys(r, list.items) });
}

fn keyRequests(q: *Req) !void {
    return q.json(.{ .requests = try keys.pendingRequests(&q.r, q.user()) });
}

// ---- Push notifications ---------------------------------------------------------------------

fn pushSubscribe(q: *Req) !void {
    const r = &q.r;
    const body = try q.bodyObj();
    // The phone apps: { token, kind } (FCM, APNs, VoIP).
    if (body.get("token").truthy()) {
        try push.saveNative(r, q.user(), body);
        return q.json(.{ .ok = true });
    }
    try r.ensure(push.pushEnabled(), "Push notifications are not configured on this server", 501, "push_disabled");
    try push.subscribe(r, q.user(), body);
    return q.json(.{ .ok = true });
}

/// The widget's service worker fetches chat keys for notification previews with this token.
fn pushToken(q: *Req) !void {
    const r = &q.r;
    try rateLimit(q, "push-token", 20, 3600_000);
    try r.ensure(q.user().get("appId").truthy(), "Reseal accounts use their sign-in for this", 400, null);
    const t = try auth.issueUserToken(r, q.user(), 90 * 86400, q.user().get("appId"), "push");
    return q.json(.{ .token = t.token, .expiresAt = t.expiresAt });
}

fn pushUnsubscribe(q: *Req) !void {
    try push.unsubscribe(&q.r, q.user(), q.b("endpoint"));
    return q.json(.{ .ok = true });
}
