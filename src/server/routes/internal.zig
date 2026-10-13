//! Server-to-server endpoints for Wufour (src/routes/internal.js), behind Wufour's
//! INTERNAL_API_KEY in "X-Internal-Key".
//!
//! POST /api/internal/search { userId, query, limit, lang } powers the search bar on the Wufour
//! start page: the person's chats by title, people by username or a word of their name, public
//! groups and channels, and messages in the person's unencrypted chats.

const std = @import("std");
const A = @import("../app.zig");
const web = @import("../web.zig");
const v = @import("../validate.zig");
const account = @import("account.zig");
const val = A.val;
const Val = A.Val;
const Req = web.Req;

const MAX_TIME_MS = 1500;
const MAX_CHATS = 3000;

fn col() *A.Cols {
    return &A.app.col;
}

fn eq(x: Val, s: []const u8) bool {
    return x == .str and std.mem.eql(u8, x.str, s);
}

pub fn handle(q: *Req) !bool {
    if (q.is(.POST, "/api/internal/search")) {
        try search(q);
        return true;
    }
    return false;
}

const Labels = struct { members: []const u8, group: []const u8, channel: []const u8, private: []const u8, bot: []const u8, encrypted: []const u8, chat: []const u8, open: []const u8 };
const EN: Labels = .{ .members = "{d} members", .group = "Group", .channel = "Channel", .private = "Private chat", .bot = "Bot", .encrypted = "Encrypted", .chat = "Chat", .open = "Open Reseal" };
const AR: Labels = .{ .members = "{d} عضواً", .group = "مجموعة", .channel = "قناة", .private = "محادثة خاصة", .bot = "بوت", .encrypted = "مشفّرة", .chat = "محادثة", .open = "افتح رسيل" };

fn membersLabel(a: std.mem.Allocator, L: Labels, n: i64) ![]const u8 {
    return if (L.members[0] == '{') std.fmt.allocPrint(a, "{d} members", .{n}) else std.fmt.allocPrint(a, "{d} عضواً", .{n});
}

fn typeLabel(L: Labels, t: Val) []const u8 {
    const s = t.asStr() orelse return L.chat;
    if (std.mem.eql(u8, s, "group")) return L.group;
    if (std.mem.eql(u8, s, "channel")) return L.channel;
    if (std.mem.eql(u8, s, "private")) return L.private;
    if (std.mem.eql(u8, s, "bot")) return L.bot;
    return L.chat;
}

/// A photo as Reseal's client builds it; only photos everyone may see.
fn photo(a: std.mem.Allocator, media_id: Val, external: Val) ![]const u8 {
    if (external.truthy()) return val.str(a, external);
    if (media_id.truthy()) return std.fmt.allocPrint(a, "/m/{s}", .{try val.str(a, media_id)});
    return "";
}

fn search(q: *Req) !void {
    const r = &q.r;
    const a = r.a;
    const expected = A.app.config.wufour_internal_key;
    const given = q.header("x-internal-key") orelse "";
    if (!(expected.len >= 32 and A.safeEqual(given, expected))) return q.jsonStatus(401, .{ .@"error" = .{ .message = "Unauthorized", .code = "unauthorized" } });

    var text = v.jsTrim(if (q.b("query").truthy()) try r.str(q.b("query")) else "");
    if (text.len > 0 and text[0] == '@') text = text[1..];
    text = v.sliceUtf16(text, 64);
    const lim_n = v.toNumber(q.b("limit"));
    const limit: i64 = @min(@max(if (std.math.isFinite(lim_n) and @trunc(lim_n) != 0) v.clampInt(lim_n) else 4, 1), 10);
    const wufour_id = if (q.b("userId").truthy()) try r.str(q.b("userId")) else "";
    const L = if (eq(q.b("lang"), "ar")) AR else EN;
    const more = try val.from(a, .{ .label = L.open, .url = "/" });
    if (v.utf16Len(text) < 2 or wufour_id.len == 0) return q.json(.{ .results = try Val.array(a), .more = more });
    const alive = .{ .@"$exists" = false };
    const me = (try col().users.findOne(a, .{ .wufourId = wufour_id, .deletedAt = alive }, .{ .projection = .{ ._id = 1 }, .maxTimeMS = MAX_TIME_MS })) orelse return q.json(.{ .results = try Val.array(a), .more = more });
    const lower = try v.jsLower(a, text);
    const prefix: Val = .{ .regex = .{ .pattern = try r.fmt("^{s}", .{try account.escapeRe(a, lower)}), .options = "" } };
    const word: Val = .{ .regex = .{ .pattern = try r.fmt("(^|\\s){s}", .{try account.escapeRe(a, lower)}), .options = "" } };
    const memberships = try col().members.find(a, .{ .userId = me.get("_id"), .status = "active" }, .{ .projection = .{ .chatId = 1, .clearedSeq = 1 }, .sort = .{ .lastActivityAt = -1 }, .limit = MAX_CHATS, .maxTimeMS = MAX_TIME_MS });
    var chat_ids: std.ArrayList(Val) = .empty;
    for (memberships) |m| try chat_ids.append(a, m.get("chatId"));
    const proj_user = .{ .username = 1, .displayName = 1, .avatar = 1, .avatarUrl = 1, .privacy = 1, .kind = 1 };
    const my_chats = try col().chats.find(a, .{ ._id = .{ .@"$in" = chat_ids.items }, .title = .{ .@"$regex" = try account.escapeRe(a, text), .@"$options" = "i" }, .deletedAt = alive }, .{ .projection = .{ .title = 1, .type = 1, .memberCount = 1, .encrypted = 1, .avatar = 1 }, .limit = limit, .maxTimeMS = MAX_TIME_MS });
    const by_username = try col().users.find(a, .{ .appId = Val.null, .usernameLower = prefix, .deletedAt = alive, ._id = .{ .@"$ne" = me.get("_id") } }, .{ .projection = proj_user, .limit = limit, .maxTimeMS = MAX_TIME_MS });
    const by_name = try col().users.find(a, .{ .appId = Val.null, .displayNameLower = word, .deletedAt = alive, .kind = .{ .@"$ne" = "bot" }, ._id = .{ .@"$ne" = me.get("_id") } }, .{ .projection = proj_user, .limit = limit, .maxTimeMS = MAX_TIME_MS });
    const public_chats = try col().chats.find(a, .{ .appId = Val.null, .usernameLower = prefix, .deletedAt = alive }, .{ .projection = .{ .title = 1, .type = 1, .username = 1, .memberCount = 1, .avatar = 1 }, .limit = 3, .maxTimeMS = MAX_TIME_MS });
    const plain = if (v.utf16Len(text) >= 3) try col().chats.find(a, .{ ._id = .{ .@"$in" = chat_ids.items }, .encrypted = false }, .{ .projection = .{ .title = 1 }, .maxTimeMS = MAX_TIME_MS }) else val.none[0..];

    // People: username matches first, then name matches; bots only when public.
    var people: std.ArrayList(Val) = .empty;
    for ([_][]Val{ by_username, by_name }) |list| for (list) |u| {
        var dup = false;
        for (people.items) |x| if (val.same(x.get("_id"), u.get("_id"))) {
            dup = true;
        };
        if (!dup) try people.append(a, u);
    };
    var bot_ids: std.ArrayList(Val) = .empty;
    for (people.items) |u| if (eq(u.get("kind"), "bot")) try bot_ids.append(a, u.get("_id"));
    if (bot_ids.items.len > 0) {
        const open = try col().bots.find(a, .{ ._id = .{ .@"$in" = bot_ids.items }, .public = true }, .{ .projection = .{ ._id = 1 }, .maxTimeMS = MAX_TIME_MS });
        var keep: std.ArrayList(Val) = .empty;
        for (people.items) |u| {
            if (eq(u.get("kind"), "bot")) {
                var ok = false;
                for (open) |b| if (val.same(b.get("_id"), u.get("_id"))) {
                    ok = true;
                };
                if (!ok) continue;
            }
            try keep.append(a, u);
        }
        people = keep;
    }
    if (people.items.len > limit) people.items.len = @intCast(limit);

    // A person opens the private chat with me when there is one, otherwise /@username.
    const me_s = try r.str(me.get("_id"));
    var pair_keys = try Val.array(a);
    for (people.items) |u| {
        const us = try r.str(u.get("_id"));
        try pair_keys.push(a, .{ .str = if (std.mem.order(u8, me_s, us) == .gt) try r.fmt("{s}:{s}", .{ us, me_s }) else try r.fmt("{s}:{s}", .{ me_s, us }) });
    }
    const pairs = if (people.items.len > 0) try col().chats.find(a, .{ .pairKey = .{ .@"$in" = pair_keys } }, .{ .projection = .{ .pairKey = 1 }, .maxTimeMS = MAX_TIME_MS }) else val.none[0..];

    var results = try Val.array(a);
    for (my_chats) |c| {
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.append(a, typeLabel(L, c.get("type")));
        const mc = c.get("memberCount").asInt() orelse 0;
        if (mc > 2) try parts.append(a, try membersLabel(a, L, mc));
        if (c.get("encrypted").truthy()) try parts.append(a, L.encrypted);
        try results.push(a, try val.from(a, .{ .kind = "chat", .title = if (c.get("title").truthy()) c.get("title") else Val.s(L.chat), .subtitle = try std.mem.join(a, " · ", parts.items), .meta = "", .image = try photo(a, c.get("avatar"), .null), .url = try r.fmt("/c/{s}", .{try r.str(c.get("_id"))}) }));
    }
    for (people.items, 0..) |u, i| {
        var chat_id: ?[]const u8 = null;
        for (pairs) |p| if (eq(p.get("pairKey"), pair_keys.items()[i].str)) {
            chat_id = try r.str(p.get("_id"));
        };
        const url = if (chat_id) |c| try r.fmt("/c/{s}", .{c}) else if (u.get("username").truthy()) try r.fmt("/@{s}", .{try web.encodeComponent(a, try r.str(u.get("username")))}) else continue;
        const everyone = std.mem.eql(u8, u.path("privacy.avatar").asStr() orelse "everyone", "everyone");
        try results.push(a, try val.from(a, .{
            .kind = if (eq(u.get("kind"), "bot")) "bot" else "user",
            .title = if (u.get("displayName").truthy()) u.get("displayName") else u.get("username"),
            .subtitle = if (u.get("username").truthy()) Val{ .str = try r.fmt("@{s}", .{try r.str(u.get("username"))}) } else Val.s(""),
            .meta = if (eq(u.get("kind"), "bot")) L.bot else "",
            .image = if (everyone) try photo(a, u.get("avatar"), u.get("avatarUrl")) else "",
            .url = url,
        }));
    }
    for (public_chats) |c| {
        var mine = false;
        for (my_chats) |m| if (val.same(m.get("_id"), c.get("_id"))) {
            mine = true;
        };
        if (mine) continue;
        const un = try r.str(c.get("username"));
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.append(a, try r.fmt("@{s}", .{un}));
        if (c.get("memberCount").truthy()) try parts.append(a, try membersLabel(a, L, c.get("memberCount").asInt() orelse 0));
        try results.push(a, try val.from(a, .{ .kind = "chat", .title = if (c.get("title").truthy()) c.get("title") else Val{ .str = try r.fmt("@{s}", .{un}) }, .subtitle = try std.mem.join(a, " · ", parts.items), .meta = typeLabel(L, c.get("type")), .image = try photo(a, c.get("avatar"), .null), .url = try r.fmt("/@{s}", .{try web.encodeComponent(a, un)}) }));
    }
    if (plain.len > 0) {
        var pids: std.ArrayList(Val) = .empty;
        for (plain) |c| try pids.append(a, c.get("_id"));
        const msgs = col().messages.find(a, .{ .chatId = .{ .@"$in" = pids.items }, .@"$text" = .{ .@"$search" = text }, .deletedAt = alive, .hiddenFor = .{ .@"$ne" = me.get("_id") }, .seq = .{ .@"$ne" = Val.null } }, .{ .projection = .{ .chatId = 1, .seq = 1, .text = 1, .search = 1, .createdAt = 1 }, .sort = .{ .createdAt = -1 }, .limit = 12, .maxTimeMS = MAX_TIME_MS }) catch &.{};
        var shown: usize = 0;
        for (msgs) |m| {
            if (shown >= 3) break;
            var cleared: f64 = 0;
            for (memberships) |mm| if (val.same(mm.get("chatId"), m.get("chatId"))) {
                cleared = mm.get("clearedSeq").asNum() orelse 0;
            };
            if ((m.get("seq").asNum() orelse 0) <= cleared) continue;
            shown += 1;
            const raw = if (m.get("text").truthy()) try r.str(m.get("text")) else if (m.get("search").truthy()) try r.str(m.get("search")) else "";
            var collapsed: std.ArrayList(u8) = .empty;
            var space = false;
            for (raw) |c| {
                if (std.ascii.isWhitespace(c)) {
                    if (!space) try collapsed.append(a, ' ');
                    space = true;
                } else {
                    space = false;
                    try collapsed.append(a, c);
                }
            }
            const snippet = v.sliceUtf16(collapsed.items, 120);
            var title: []const u8 = L.chat;
            for (plain) |c| if (val.same(c.get("_id"), m.get("chatId")) and c.get("title").truthy()) {
                title = try r.str(c.get("title"));
            };
            const ca = m.get("createdAt");
            try results.push(a, try val.from(a, .{ .kind = "message", .title = if (snippet.len > 0) snippet else L.chat, .subtitle = title, .meta = if (ca == .date) (try val.isoDate(a, ca.date))[0..10] else "", .image = "", .url = try r.fmt("/c/{s}#{s}", .{ try r.str(m.get("chatId")), try r.str(m.get("seq")) }) }));
        }
    }
    try q.setHeader("cache-control", "no-store");
    return q.json(.{ .results = results, .more = more });
}
