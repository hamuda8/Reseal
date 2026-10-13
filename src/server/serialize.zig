//! Shapes database documents into what clients see, applying privacy rules
//! (src/services/serialize.js).

const std = @import("std");
const A = @import("app.zig");
const rt = @import("realtime.zig");
const val = A.val;
const Val = A.Val;
const Allocator = std.mem.Allocator;

fn s(a: Allocator, v: Val) !Val {
    return val.sOrNull(a, v);
}

fn strEq(v: Val, x: []const u8) bool {
    return v == .str and std.mem.eql(u8, v.str, x);
}

/// A stable color index (0-7) for avatars without a photo.
pub fn colorOf(a: Allocator, id: Val) !u32 {
    const str = try val.toStr(a, id);
    var h: u32 = 0;
    // JS charCodeAt walks UTF-16 code units; ids are ASCII.
    for (str) |c| h = h *% 31 +% c;
    return h % 8;
}

pub const UserOpts = struct { is_contact: bool = false, full: bool = false };

pub fn user(a: Allocator, u: Val, viewer_id: Val, o: UserOpts) !Val {
    if (u.isNullish()) return .null;
    const self = val.same(u.get("_id"), viewer_id);
    const rule = u.path("privacy.avatar").asStr() orelse "everyone";
    const show_avatar = self or std.mem.eql(u8, rule, "everyone") or (std.mem.eql(u8, rule, "contacts") and o.is_contact);
    const k = u.get("keys");
    const out = try val.from(a, .{
        .id = try s(a, u.get("_id")),
        .kind = u.get("kind"),
        .displayName = u.get("displayName"),
        .username = if (u.get("username").truthy()) u.get("username") else Val.null,
        .avatar = if (show_avatar and u.get("avatar").truthy()) try s(a, u.get("avatar")) else Val.null,
        .avatarUrl = if (show_avatar and u.get("avatarUrl").truthy()) u.get("avatarUrl") else Val.null,
        .color = try colorOf(a, u.get("_id")),
        .isBot = strEq(u.get("kind"), "bot"),
        .deleted = u.get("deletedAt").truthy(),
        .presence = try rt.presenceFor(a, u, viewer_id, o.is_contact),
        .keys = if (k.truthy()) try val.from(a, .{ .enc = k.get("enc"), .sig = k.get("sig"), .version = if (k.get("version").truthy()) k.get("version") else Val.number(1), .updatedAt = k.get("updatedAt") }) else Val.null,
    });
    if (o.full or self) {
        try out.set("bio", if (u.get("bio").truthy()) u.get("bio") else Val.string(""));
        try out.set("isContact", o.is_contact);
    }
    if (strEq(u.get("kind"), "bot") and u.get("botInfo").truthy()) {
        const bi = u.get("botInfo");
        try out.set("bot", .{
            .description = if (bi.get("description").truthy()) bi.get("description") else Val.string(""),
            .model = if (bi.get("model").truthy()) bi.get("model") else Val.null,
            .ownerId = try s(a, bi.get("ownerId")),
            .starters = if (bi.get("starters").truthy()) bi.get("starters") else try Val.array(a),
        });
    }
    if (strEq(u.get("kind"), "app") and u.get("role").truthy()) try out.set("role", u.get("role"));
    return out;
}

/// The signed-in user's own profile, including private settings.
pub fn me(a: Allocator, u: Val) !Val {
    const out = try user(a, u, u.get("_id"), .{ .full = true });
    const k = u.get("keys");
    try out.set("appId", try s(a, u.get("appId")));
    try out.set("privacy", if (u.get("privacy").truthy()) u.get("privacy") else try Val.object(a));
    try out.set("settings", if (u.get("settings").truthy()) u.get("settings") else try Val.object(a));
    try out.set("isAdmin", u.get("isAdmin").truthy());
    try out.set("guest", u.get("guest").truthy());
    try out.set("hasKeys", k.get("enc").truthy());
    try out.set("keyBackup", k.get("backup").truthy());
    // 'standard' = automatic key backup; 'advanced' = passcode only the user knows.
    try out.set("keyMode", if (k.get("enc").truthy()) (if (k.get("mode").truthy()) k.get("mode") else Val.string("advanced")) else Val.null);
    try out.set("chatLock", u.get("chatLock").truthy());
    try out.set("createdAt", u.get("createdAt"));
    return out;
}

pub fn reactionsOf(a: Allocator, reactions: Val, viewer_id: Val, anonymous: bool) !Val {
    var out = try Val.array(a);
    if (reactions != .obj) return out;
    const Entry = struct { emoji: []const u8, users: []Val };
    var list: std.ArrayList(Entry) = .empty;
    for (reactions.keys(), reactions.vals()) |kv_k, kv_v| {
        if (kv_v != .arr or kv_v.len() == 0) continue;
        try list.append(a, .{ .emoji = kv_k, .users = kv_v.items() });
    }
    // Stable, by count, highest first.
    std.mem.sort(Entry, list.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return x.users.len > y.users.len;
        }
    }.lt);
    for (list.items) |e| {
        var me_ = false;
        for (e.users) |u| if (val.same(u, viewer_id)) {
            me_ = true;
        };
        var recent = try Val.array(a);
        if (!anonymous) {
            const start = if (e.users.len > 3) e.users.len - 3 else 0;
            for (e.users[start..]) |u| try recent.push(try s(a, u));
        }
        try out.push(try val.from(a, .{ .emoji = e.emoji, .count = e.users.len, .me = me_, .recent = recent }));
    }
    return out;
}

pub fn message(a: Allocator, m: Val, viewer_id: Val, chat_: Val) !Val {
    if (m.isNullish()) return .null;
    const viewer = try s(a, viewer_id);
    const channel = strEq(chat_.get("type"), "channel");
    const out = try val.from(a, .{
        .id = try s(a, m.get("_id")),
        .chatId = try s(a, m.get("chatId")),
        .seq = if (m.get("seq").isNullish()) Val.null else m.get("seq"),
        .senderId = if (channel and !chat_.get("signMessages").truthy()) Val.null else try s(a, m.get("senderId")),
        .authorId = try s(a, m.get("senderId")),
        .kind = if (m.get("kind").truthy()) m.get("kind") else Val.string("message"),
        .createdAt = m.get("createdAt"),
    });
    if (m.get("clientId").truthy() and eqNullable(try s(a, m.get("senderId")), viewer)) try out.set("clientId", m.get("clientId"));
    if (m.get("deletedAt").truthy()) {
        try out.set("deleted", true);
        return out;
    }
    if (m.get("enc").truthy()) try out.set("enc", m.get("enc"));
    if (m.get("text") != .undef) try out.set("text", m.get("text"));
    if (m.get("entities").len() > 0) try out.set("entities", m.get("entities"));
    if (m.get("media").len() > 0) {
        var list = try Val.array(a);
        for (m.get("media").items()) |x| {
            const c = try val.clone(a, x);
            try c.set("id", try s(a, x.get("id")));
            try list.push(c);
        }
        try out.set("media", list);
    }
    inline for (.{ "location", "contact", "sticker", "preview" }) |k| if (m.get(k).truthy()) try out.set(k, m.get(k));
    if (m.get("service").truthy()) {
        const svc = try val.clone(a, m.get("service"));
        try svc.set("actorId", try s(a, m.path("service.actorId")));
        const t = m.path("service.targetIds");
        if (t == .arr) {
            var ids = try Val.array(a);
            for (t.items()) |x| try ids.push(try s(a, x));
            try svc.set("targetIds", ids);
        } else try svc.set("targetIds", .undef);
        try out.set("service", svc);
    }
    if (m.get("replyTo").truthy()) try out.set("replyTo", .{ .id = try s(a, m.path("replyTo.id")), .seq = if (m.path("replyTo.seq").isNullish()) Val.null else m.path("replyTo.seq") });
    if (m.get("fwd").truthy()) {
        const f = try val.clone(a, m.get("fwd"));
        try f.set("fromUserId", try s(a, m.path("fwd.fromUserId")));
        try f.set("fromChatId", try s(a, m.path("fwd.fromChatId")));
        try out.set("fwd", f);
    }
    if (m.get("tags").len() > 0) try out.set("tags", m.get("tags"));
    if (m.get("mentions").len() > 0) {
        var list = try Val.array(a);
        for (m.get("mentions").items()) |x| try list.push(try s(a, x));
        try out.set("mentions", list);
    }
    if (m.get("poll").truthy()) try out.set("poll", try poll(a, m.get("poll"), viewer));
    if (m.get("editedAt").truthy()) try out.set("editedAt", m.get("editedAt"));
    if (m.get("silent").truthy()) try out.set("silent", true);
    if (m.get("ttl").truthy()) {
        try out.set("ttl", m.get("ttl"));
        try out.set("expiresAt", m.get("expiresAt"));
    }
    if (m.get("scheduledAt").truthy()) try out.set("scheduledAt", m.get("scheduledAt"));
    if (m.get("waitFor").truthy()) try out.set("whenOnline", true);
    if (m.get("views").truthy()) try out.set("views", m.get("views"));
    if (m.get("streaming").truthy()) try out.set("streaming", true);
    inline for (.{ "error", "bot", "metadata", "buttons" }) |k| if (m.get(k).truthy()) try out.set(k, m.get(k));
    if (m.get("system").truthy()) try out.set("system", true);
    if (m.get("reminder").truthy()) try out.set("reminder", true);
    const reactions = try reactionsOf(a, m.get("reactions"), viewer, channel);
    if (reactions.len() > 0) try out.set("reactions", reactions);
    return out;
}

fn eqNullable(x: Val, y: Val) bool {
    if (x == .null or y == .null) return x == .null and y == .null;
    return val.same(x, y);
}

pub fn poll(a: Allocator, p: Val, viewer: Val) !Val {
    const votes = p.get("votes").items();
    const n: usize = if (p.get("optionCount").asInt()) |x| @intCast(@max(x, 0)) else 0;
    const counts = try a.alloc(f64, n);
    @memset(counts, 0);
    var my_vote: Val = .null;
    for (votes) |vote| {
        for (vote.get("o").items()) |o| if (o.asInt()) |i| {
            if (i >= 0 and i < n) counts[@intCast(i)] += 1;
        };
        if (eqNullable(try s(a, vote.get("u")), viewer)) my_vote = vote.get("o");
    }
    const show = my_vote.truthy() or p.get("closed").truthy();
    var counts_v: Val = .null;
    if (show) {
        counts_v = try Val.array(a);
        for (counts) |c| try counts_v.push(Val{ .num = c });
    }
    const out = try val.from(a, .{
        .question = p.get("question"),
        .options = p.get("options"),
        .optionCount = p.get("optionCount"),
        .multiple = p.get("multiple").truthy(),
        .quiz = p.get("quiz").truthy(),
        .anonymous = !(p.get("anonymous") == .bool and !p.get("anonymous").bool),
        .closed = p.get("closed").truthy(),
        .total = votes.len,
        .myVote = my_vote,
        .counts = counts_v,
    });
    if (p.get("quiz").truthy() and show) {
        try out.set("correct", if (p.get("correct").isNullish()) Val.null else p.get("correct"));
        if (p.get("explanation").truthy()) try out.set("explanation", p.get("explanation"));
    }
    return out;
}

pub fn member(a: Allocator, m: Val) !Val {
    const admin = strEq(m.get("role"), "admin");
    return val.from(a, .{
        .userId = try s(a, m.get("userId")),
        .role = m.get("role"),
        .rights = if (admin) (if (m.get("rights").truthy()) m.get("rights") else Val.null) else Val.undef,
        .title = if (m.get("title").truthy()) m.get("title") else Val.null,
        .joinedAt = m.get("joinedAt"),
        .status = m.get("status"),
        .invitedBy = try s(a, m.get("invitedBy")),
    });
}

/// Highest "read up to" among members other than the viewer: drives the double check marks.
pub fn outboxRead(c: Val, viewer_id: Val) Val {
    for (c.get("readTop").items()) |r| if (!val.same(r.get("u"), viewer_id)) return r.get("s");
    return Val.number(0);
}

pub const ChatOpts = struct {
    peer: Val = .null,
    last_message: Val = .undef,
    active_call: Val = .null,
    team: Val = .null,
    visitor: Val = .null,
};

fn orZero(v: Val) Val {
    return if (v.truthy()) v else Val.number(0);
}

pub fn chat(a: Allocator, c: Val, membership: Val, viewer_id: Val, o: ChatOpts) !Val {
    const ka = c.get("keyEpochAt");
    const old_key = c.get("encrypted").truthy() and c.get("keyEpoch").truthy() and ka.truthy() and ka == .date and A.nowMs() - ka.date > 7 * 86400_000;
    var pinned = try Val.array(a);
    for (c.get("pinned").items()) |p| try pinned.push(try s(a, p));
    const is_group = strEq(c.get("type"), "group");
    const out = try val.from(a, .{
        .id = try s(a, c.get("_id")),
        .type = c.get("type"),
        .encrypted = c.get("encrypted").truthy(),
        .title = if (c.get("title").truthy()) c.get("title") else Val.string(""),
        .about = if (c.get("about").truthy()) c.get("about") else Val.string(""),
        .avatar = try s(a, c.get("avatar")),
        .color = try colorOf(a, c.get("_id")),
        .username = if (c.get("username").truthy()) c.get("username") else Val.null,
        .memberCount = orZero(c.get("memberCount")),
        .seq = orZero(c.get("seq")),
        .keyEpoch = orZero(c.get("keyEpoch")),
        // Keys also rotate once a week: the next sender's device starts a new epoch.
        .rotationNeeded = c.get("rotationNeeded").truthy() or old_key,
        .lastMessageAt = if (c.get("lastMessageAt").truthy()) c.get("lastMessageAt") else c.get("createdAt"),
        .createdAt = c.get("createdAt"),
        .createdBy = try s(a, c.get("createdBy")),
        .pinned = pinned,
        .permissions = if (is_group) try val.clone(a, if (c.get("permissions").truthy()) c.get("permissions") else try Val.object(a)) else Val.undef,
        .slowMode = orZero(c.get("slowMode")),
        .ttl = orZero(c.get("ttl")),
        .signMessages = c.get("signMessages").truthy(),
        .historyVisible = !(c.get("historyVisible") == .bool and !c.get("historyVisible").bool),
        .joinApproval = c.get("joinApproval").truthy(),
        .protectedContent = c.get("protectedContent").truthy(),
        // null = all allowed, [] = none, [..] = only these
        .reactions = if (c.get("reactions").truthy()) c.get("reactions") else Val.null,
        .readSeq = outboxRead(c, viewer_id),
        .appId = try s(a, c.get("appId")),
        .externalId = if (c.get("externalId").truthy()) c.get("externalId") else Val.null,
        .metadata = if (c.get("metadata").truthy()) c.get("metadata") else Val.null,
        .botId = try s(a, c.get("botId")),
        .teamId = try s(a, c.get("teamId")),
        .visitorId = try s(a, c.get("visitorId")),
    });
    // A team chat: the visitor sees the team (a store, a department); the staff see the visitor.
    if (o.team.truthy()) try out.set("team", o.team);
    if (o.visitor.truthy()) try out.set("visitor", o.visitor);
    // The Saved chat every account starts with; extra Saved chats are topics the person created.
    if (strEq(c.get("type"), "saved")) try out.set("primary", c.get("pairKey").truthy());
    if (o.last_message != .undef) try out.set("lastMessage", o.last_message);
    if (o.peer.truthy()) try out.set("peer", o.peer);
    if (o.active_call.truthy()) try out.set("call", o.active_call);
    if (membership.truthy()) {
        const m = membership;
        try out.set("me", .{
            .role = m.get("role"),
            .rights = if (strEq(m.get("role"), "admin") and m.get("rights").truthy()) m.get("rights") else Val.null,
            .status = m.get("status"),
            .unread = orZero(m.get("unread")),
            .mentions = orZero(m.get("mentions")),
            .reactionsUnread = orZero(m.get("reactionsUnread")),
            .lastReadSeq = orZero(m.get("lastReadSeq")),
            .mutedUntil = if (m.get("mutedUntil").truthy()) m.get("mutedUntil") else Val.null,
            .pinnedAt = if (m.get("pinnedAt").truthy()) m.get("pinnedAt") else Val.null,
            .archived = m.get("archived").truthy(),
            .markedUnread = m.get("markedUnread").truthy(),
            .clearedSeq = orZero(m.get("clearedSeq")),
            .joinedSeq = orZero(m.get("joinedSeq")),
            .draft = if (m.get("draft").truthy()) m.get("draft") else Val.null,
            .locked = m.get("locked").truthy(),
        });
    }
    return out;
}
