//! Messages (src/services/messages.js): sending, scheduling, editing, deleting, reactions,
//! polls, pins, reads and views, and the background jobs for scheduled and self-destructing
//! messages.
//!
//! End-to-end encrypted chats store only an `enc` envelope ({ e: key epoch, s, iv, ct, sig })
//! produced by the sender's device; the server never sees the text, media keys or file names.
//! Plain chats (channels, bots, apps with E2EE off) store readable content so they can be
//! searched, sent to webhooks and answered by AI. Messages are read and written through
//! store.zig: Reseal's chats keep them in Reseal's database, an app's chats in the app's.

const std = @import("std");
const A = @import("app.zig");
const v = @import("validate.zig");
const store = @import("store.zig");
const rt = @import("realtime.zig");
const ser = @import("serialize.zig");
const access = @import("access.zig");
const events = @import("events.zig");
const moderation = @import("moderation.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;
const Limits = A.Limits;
const Allocator = std.mem.Allocator;
const eq = access.eq;

const MEDIA_KINDS = [_][]const u8{ "photo", "video", "file", "voice", "round", "audio", "gif", "sticker" };
const ENTITY_TYPES = [_][]const u8{ "bold", "italic", "underline", "strike", "code", "pre", "spoiler", "link", "textlink", "mention", "mentionname", "hashtag", "quote", "email", "phone", "cashtag", "botcommand" };
const TAGS = [_][]const u8{ "photo", "video", "file", "voice", "round", "audio", "gif", "link", "poll", "location", "contact", "sticker", "music" };

fn idv(x: anytype) Val {
    return .{ .id = x };
}

fn col() *A.Cols {
    return &A.app.col;
}

// ---- Patterns -------------------------------------------------------------------------------

fn startsWithI(s: []const u8, p: []const u8) bool {
    return s.len >= p.len and std.ascii.eqlIgnoreCase(s[0..p.len], p);
}

fn httpUrl(s: []const u8) bool {
    return startsWithI(s, "http://") or startsWithI(s, "https://");
}

fn entityUrl(s: []const u8) bool {
    return httpUrl(s) or startsWithI(s, "mailto:") or startsWithI(s, "tel:");
}

/// /^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$/
fn thumbPattern(s: []const u8) bool {
    inline for (.{ "data:image/jpeg;base64,", "data:image/png;base64,", "data:image/webp;base64," }) |p| {
        if (std.mem.startsWith(u8, s, p)) {
            const rest = s[p.len..];
            if (rest.len == 0) return false;
            for (rest) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=')) return false;
            return true;
        }
    }
    return false;
}

fn inList(x: []const u8, list: []const []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

// ---- Input cleaning -------------------------------------------------------------------------

fn cleanEntities(r: *Rq, list: Val, text_len: usize) !?Val {
    const a = r.a;
    if (list.isNullish()) return null;
    try r.ensure(list == .arr and list.len() <= 200, "entities must be a list of at most 200 items", 400, null);
    var out = try Val.array(a);
    const tl: f64 = @floatFromInt(text_len);
    for (list.items(), 0..) |e, i| {
        _ = try v.reqObj(r, e, try r.fmt("entities[{d}]", .{i}));
        const t = try v.reqOneOf(r, e.get("t"), "entity type", &ENTITY_TYPES);
        const o = try v.reqInt(r, e.get("o"), "entity offset", .{ .min = 0, .max = tl });
        const l = try v.reqInt(r, e.get("l"), "entity length", .{ .min = 1, .max = tl });
        try r.ensure(o + l <= text_len, "entity is outside the text", 400, null);
        const x = try val.from(a, .{ .t = t, .o = o, .l = l });
        if (e.get("url") != .undef) try x.set(a, "url", try v.str(r, e.get("url"), "entity url", .{ .max = 2048, .pattern = entityUrl }));
        if (e.get("lang") != .undef) try x.set(a, "lang", try v.str(r, e.get("lang"), "entity lang", .{ .max = 32 }));
        if (e.get("userId") != .undef) try x.set(a, "userId", try r.str(idv(try v.reqId(r, e.get("userId"), "entity userId"))));
        try out.push(a, x);
    }
    return out;
}

fn optVal(x: anytype) Val {
    return switch (@typeInfo(@TypeOf(x))) {
        .optional => if (x) |y| (if (@TypeOf(y) == []const u8) Val{ .str = y } else Val.n(y)) else .undef,
        else => unreachable,
    };
}

fn cleanMediaItem(r: *Rq, m: Val, i: usize) !Val {
    const a = r.a;
    _ = try v.reqObj(r, m, try r.fmt("media[{d}]", .{i}));
    const out = try Val.object(a);
    try out.put(a, "id", idv(try v.reqId(r, m.get("id"), "media id")));
    try out.set(a, "kind", try v.reqOneOf(r, m.get("kind"), "media kind", &MEDIA_KINDS));
    try out.set(a, "mime", (try v.str(r, m.get("mime"), "mime", .{ .max = 120, .optional = true })) orelse "application/octet-stream");
    const fields = .{
        .{ "name", optVal(try v.str(r, m.get("name"), "file name", .{ .max = 255, .optional = true })) },
        .{ "size", optVal(try v.int(r, m.get("size"), "size", .{ .min = 0, .max = @floatFromInt(A.app.config.max_upload_bytes), .optional = true })) },
        .{ "w", optVal(try v.int(r, m.get("w"), "width", .{ .min = 0, .max = 20000, .optional = true })) },
        .{ "h", optVal(try v.int(r, m.get("h"), "height", .{ .min = 0, .max = 20000, .optional = true })) },
        .{ "duration", optVal(try v.num(r, m.get("duration"), "duration", .{ .min = 0, .max = 86400, .optional = true })) },
        .{ "waveform", optVal(try v.b64(r, m.get("waveform"), "waveform", 256, true)) },
        .{ "thumb", optVal(try v.str(r, m.get("thumb"), "thumb", .{ .max = 16000, .optional = true, .pattern = thumbPattern })) },
        .{ "spoiler", if (m.get("spoiler").isTrue()) Val.True else Val.undef },
        .{ "title", optVal(try v.str(r, m.get("title"), "title", .{ .max = 200, .optional = true })) },
        .{ "performer", optVal(try v.str(r, m.get("performer"), "performer", .{ .max = 200, .optional = true })) },
    };
    inline for (fields) |f| if (f[1] != .undef) try out.put(a, f[0], f[1]);
    return out;
}

fn cleanPoll(r: *Rq, p: Val, encrypted: bool) !Val {
    const a = r.a;
    _ = try v.reqObj(r, p, "poll");
    const multiple = p.get("multiple").isTrue();
    const quiz = p.get("quiz").isTrue();
    try r.ensure(!(multiple and quiz), "A quiz has exactly one correct answer", 400, null);
    const out = try val.from(a, .{ .multiple = multiple, .quiz = quiz, .anonymous = !(p.get("anonymous") == .bool and !p.get("anonymous").bool), .closed = false, .votes = try Val.array(a) });
    if (encrypted) {
        // The question and options are inside the encrypted envelope; the server only counts votes.
        try out.set(a, "optionCount", try v.reqInt(r, p.get("optionCount"), "poll optionCount", .{ .min = 2, .max = Limits.poll_options }));
    } else {
        try out.set(a, "question", try v.reqStr(r, p.get("question"), "poll question", .{ .min = 1, .max = 300 }));
        try r.ensure(p.get("options") == .arr, "poll options must be a list", 400, null);
        var opts = try Val.array(a);
        for (p.get("options").items(), 0..) |o, i| try opts.push(a, .{ .str = try v.reqStr(r, o, try r.fmt("option {d}", .{i + 1}), .{ .min = 1, .max = 100 }) });
        try out.put(a, "options", opts);
        try r.ensure(opts.len() >= 2 and opts.len() <= Limits.poll_options, try r.fmt("A poll needs 2 to {d} options", .{Limits.poll_options}), 400, null);
        try out.set(a, "optionCount", opts.len());
        if (quiz) {
            try out.set(a, "correct", try v.reqInt(r, p.get("correct"), "correct option", .{ .min = 0, .max = @floatFromInt(opts.len() - 1) }));
            try out.put(a, "explanation", optVal(try v.str(r, p.get("explanation"), "explanation", .{ .max = 200, .optional = true })));
        }
    }
    if (p.get("closeAt").truthy()) {
        const t: f64 = @floatFromInt(A.nowMs());
        try out.put(a, "closeAt", .{ .date = try v.reqInt(r, p.get("closeAt"), "closeAt", .{ .min = t, .max = t + 30 * 86400_000 }) });
    }
    return out;
}

fn cleanButtons(r: *Rq, rows: Val) !?Val {
    const a = r.a;
    if (rows.isNullish()) return null;
    try r.ensure(rows == .arr and rows.len() <= 8, "buttons must be at most 8 rows", 400, null);
    var out = try Val.array(a);
    for (rows.items()) |row| {
        try r.ensure(row == .arr and row.len() >= 1 and row.len() <= 4, "each button row has 1 to 4 buttons", 400, null);
        var o_row = try Val.array(a);
        for (row.items()) |b| {
            _ = try v.reqObj(r, b, "button");
            const x = try val.from(a, .{ .text = try v.reqStr(r, b.get("text"), "button text", .{ .min = 1, .max = 64 }) });
            if (b.get("url").truthy()) {
                try x.set(a, "url", try v.str(r, b.get("url"), "button url", .{ .max = 2048, .pattern = httpUrl }));
            } else try x.set(a, "data", try v.reqStr(r, b.get("data"), "button data", .{ .min = 1, .max = 128 }));
            try o_row.push(a, x);
        }
        try out.push(a, o_row);
    }
    return out;
}

fn cleanEnc(r: *Rq, enc: Val) !Val {
    return val.from(r.a, .{
        .e = try v.reqInt(r, enc.get("e"), "enc.e", .{ .min = 1 }),
        .s = optVal(try v.b64(r, enc.get("s"), "enc.s", 32, true)),
        .iv = try v.reqB64(r, enc.get("iv"), "enc.iv", 32),
        .ct = try v.reqB64(r, enc.get("ct"), "enc.ct", 96 * 1024),
        .sig = try v.reqB64(r, enc.get("sig"), "enc.sig", 160),
    });
}

pub const Origin = enum { user, api, bot };

/// Raw input into the fields stored on a message.
pub fn cleanContent(r: *Rq, chat: Val, input: Val, origin: Origin) !Val {
    const a = r.a;
    _ = try v.reqObj(r, input, "message");
    const out = try Val.object(a);
    const encrypted = chat.get("encrypted").truthy();
    if (encrypted) {
        _ = try v.reqObj(r, input.get("enc"), "enc");
        try r.ensure(input.get("text") == .undef and input.get("media") == .undef, "Encrypted chats only accept encrypted content", 400, "encrypted_only");
        try out.put(a, "enc", try cleanEnc(r, input.get("enc")));
        if (input.get("mediaIds") != .undef) try out.set(a, "mediaIds", try idList(a, try v.reqIds(r, input.get("mediaIds"), "mediaIds", 10)));
    } else {
        try r.ensure(input.get("enc") == .undef, "This chat is not end-to-end encrypted", 400, null);
        const has_media = input.get("media").len() > 0;
        const max_text: usize = if (has_media) Limits.caption_length else Limits.text_length;
        if (try v.str(r, input.get("text"), "text", .{ .max = max_text, .optional = true, .trim = false })) |text| {
            if (v.jsTrim(text).len > 0) {
                const t = v.trimEnd(text);
                try out.set(a, "text", t);
                if (try cleanEntities(r, input.get("entities"), v.utf16Len(t))) |ents| if (ents.len() > 0) try out.put(a, "entities", ents);
            }
        }
        if (input.get("media") != .undef) {
            const media = input.get("media");
            try r.ensure(media == .arr and media.len() >= 1 and media.len() <= 10, "media must have 1 to 10 items", 400, null);
            var list = try Val.array(a);
            var ids = try Val.array(a);
            for (media.items(), 0..) |m, i| {
                const c = try cleanMediaItem(r, m, i);
                try list.push(a, c);
                try ids.push(a, c.get("id"));
            }
            try out.put(a, "media", list);
            try out.put(a, "mediaIds", ids);
        }
        if (input.get("location") != .undef) {
            const l = input.get("location");
            _ = try v.reqObj(r, l, "location");
            try out.set(a, "location", .{
                .lat = (try v.num(r, l.get("lat"), "latitude", .{ .min = -90, .max = 90 })).?,
                .lng = (try v.num(r, l.get("lng"), "longitude", .{ .min = -180, .max = 180 })).?,
                .title = optVal(try v.str(r, l.get("title"), "location title", .{ .max = 120, .optional = true })),
                .address = optVal(try v.str(r, l.get("address"), "address", .{ .max = 300, .optional = true })),
                .accuracy = optVal(try v.num(r, l.get("accuracy"), "accuracy", .{ .min = 0, .max = 100000, .optional = true })),
            });
        }
        if (input.get("contact") != .undef) {
            const c = input.get("contact");
            _ = try v.reqObj(r, c, "contact");
            try out.set(a, "contact", .{
                .name = try v.reqStr(r, c.get("name"), "contact name", .{ .min = 1, .max = 128 }),
                .phone = optVal(try v.str(r, c.get("phone"), "phone", .{ .max = 40, .optional = true })),
                .username = optVal(try v.str(r, c.get("username"), "username", .{ .max = 32, .optional = true })),
                .userId = if (c.get("userId").truthy()) Val{ .str = try r.str(idv(try v.reqId(r, c.get("userId"), "contact userId"))) } else Val.undef,
            });
        }
        if (input.get("sticker") != .undef) {
            const st = input.get("sticker");
            _ = try v.reqObj(r, st, "sticker");
            try out.set(a, "sticker", .{ .emoji = try v.reqStr(r, st.get("emoji"), "sticker emoji", .{ .min = 1, .max = 16 }), .set = optVal(try v.str(r, st.get("set"), "sticker set", .{ .max = 64, .optional = true })) });
        }
        if (!input.get("preview").isNullish()) {
            const p = input.get("preview");
            _ = try v.reqObj(r, p, "preview");
            try out.set(a, "preview", .{
                .url = try v.reqStr(r, p.get("url"), "preview url", .{ .max = 2048, .pattern = httpUrl }),
                .title = optVal(try v.str(r, p.get("title"), "preview title", .{ .max = 300, .optional = true })),
                .description = optVal(try v.str(r, p.get("description"), "preview description", .{ .max = 600, .optional = true })),
                .siteName = optVal(try v.str(r, p.get("siteName"), "site name", .{ .max = 120, .optional = true })),
                .image = optVal(try v.str(r, p.get("image"), "preview image", .{ .max = 2048, .optional = true, .pattern = httpUrl })),
            });
        }
        if (origin != .user) {
            if (try cleanButtons(r, input.get("buttons"))) |b| try out.put(a, "buttons", b);
        }
    }
    if (input.get("poll") != .undef) try out.put(a, "poll", try cleanPoll(r, input.get("poll"), encrypted));
    if (input.get("metadata") != .undef) try out.put(a, "metadata", (try v.meta(r, input.get("metadata"))) orelse .undef);
    if (input.get("tags") != .undef) {
        const tags = input.get("tags");
        try r.ensure(tags == .arr and tags.len() <= 6, "tags must be a short list", 400, null);
        var list = try Val.array(a);
        for (tags.items()) |t| {
            const x = try v.reqOneOf(r, t, "tag", &TAGS);
            if (!containsStr(list, x)) try list.push(a, .{ .str = x });
        }
        try out.put(a, "tags", list);
    }
    if (input.get("mentions") != .undef) try out.put(a, "mentions", try idList(a, try v.reqIds(r, input.get("mentions"), "mentions", 50)));
    if (!input.get("replyTo").isNullish()) try out.put(a, "replyToId", idv(try v.reqId(r, input.get("replyTo"), "replyTo")));
    if (!input.get("fwd").isNullish() and !encrypted) {
        const f = input.get("fwd");
        _ = try v.reqObj(r, f, "fwd");
        try out.put(a, "fwdFrom", idv(try v.reqId(r, f.get("messageId"), "fwd.messageId")));
        if (!f.get("chatId").isNullish()) try out.put(a, "fwdChat", idv(try v.reqId(r, f.get("chatId"), "fwd.chatId")));
    }
    if (!input.get("forwarded").isNullish() and !encrypted) {
        // A copy forwarded by the client (from an encrypted chat). The label is informational.
        const f = input.get("forwarded");
        _ = try v.reqObj(r, f, "forwarded");
        try out.set(a, "fwdCopy", .{
            .fromName = if (try v.str(r, f.get("fromName"), "forwarded.fromName", .{ .max = 128, .optional = true })) |x| (if (x.len > 0) Val{ .str = x } else Val.null) else Val.null,
            .fromUserId = if (f.get("fromUserId").truthy()) idv(try v.reqId(r, f.get("fromUserId"), "forwarded.fromUserId")) else Val.null,
            .date = if (f.get("date").truthy()) Val{ .date = try v.reqInt(r, f.get("date"), "forwarded.date", .{ .min = 0 }) } else Val.null,
        });
    }
    if (!encrypted) {
        // Tags drive the shared-media tabs; for readable chats the server derives them itself.
        var tags = try Val.array(a);
        for (out.get("tags").items()) |t| try tags.push(a, t);
        for (out.get("media").items()) |m| if (!containsStr(tags, m.get("kind").str)) try tags.push(a, m.get("kind"));
        var link = out.get("preview").truthy();
        for (out.get("entities").items()) |e| if (eq(e.get("t"), "link") or eq(e.get("t"), "textlink")) {
            link = true;
        };
        if (link and !containsStr(tags, "link")) try tags.push(a, Val.s("link"));
        if (out.get("poll").truthy() and !containsStr(tags, "poll")) try tags.push(a, Val.s("poll"));
        if (out.get("location").truthy() and !containsStr(tags, "location")) try tags.push(a, Val.s("location"));
        if (out.get("contact").truthy() and !containsStr(tags, "contact")) try tags.push(a, Val.s("contact"));
        if (tags.len() > 0) {
            var filtered = try Val.array(a);
            for (tags.items()) |t| if (inList(t.str, &TAGS)) try filtered.push(a, t);
            try out.put(a, "tags", filtered);
        }
    }
    const has = out.get("enc").truthy() or out.get("text").truthy() or out.get("media").truthy() or out.get("location").truthy() or
        out.get("contact").truthy() or out.get("sticker").truthy() or out.get("poll").truthy() or out.get("fwdFrom").truthy();
    try r.ensure(has, "The message is empty", 400, "empty_message");
    return out;
}

fn containsStr(list: Val, x: []const u8) bool {
    for (list.items()) |e| if (eq(e, x)) return true;
    return false;
}

pub fn idList(a: Allocator, ids: []const A.ObjectId) !Val {
    var out = try Val.array(a);
    for (ids) |x| try out.push(a, idv(x));
    return out;
}

// ---- Sending --------------------------------------------------------------------------------

/// Checks that the sender may use each referenced file, and attaches the files to this chat.
fn claimMedia(r: *Rq, media_ids: Val, sender: Val, chat: Val) !void {
    const a = r.a;
    if (media_ids.len() == 0) return;
    const files = try col().media.find(a, .{ ._id = .{ .@"$in" = media_ids } }, .{ .projection = .{ .ownerId = 1, .chatIds = 1, .status = 1, .encrypted = 1 } });
    try r.ensure(files.len == media_ids.len(), "A referenced file does not exist", 400, "media_missing");
    var my_chats: ?[]Val = null;
    for (files) |f| {
        try r.ensure(eq(f.get("status"), "ready"), "A file has not finished uploading", 400, "media_not_ready");
        if (val.same(f.get("ownerId"), sender.get("_id"))) continue;
        // Forwarding someone else's file: the sender must be in a chat where the file was shared.
        if (my_chats == null) my_chats = try col().members.find(a, .{ .userId = sender.get("_id"), .status = "active" }, .{ .projection = .{ .chatId = 1 } });
        var ok = false;
        for (f.get("chatIds").items()) |c| for (my_chats.?) |m| if (val.same(m.get("chatId"), c)) {
            ok = true;
        };
        try r.ensure(ok, "You cannot use that file", 403, "media_forbidden");
    }
    _ = try col().media.updateMany(a, .{ ._id = .{ .@"$in" = media_ids } }, .{ .@"$addToSet" = .{ .chatIds = chat.get("_id") } }, .{});
}

fn resolveReply(r: *Rq, chat: Val, reply_to: Val) !?Val {
    if (!reply_to.truthy()) return null;
    const target = (try store.findOne(r, chat, reply_to, null)) orelse return null;
    if (target.get("seq").isNullish()) return null;
    return target;
}

/// Forwards a plain message into a plain chat (encrypted chats forward on the device).
fn resolveForward(r: *Rq, sender: Val, fwd_from: Val, fwd_chat: Val) !struct { fwd: Val, copy: Val } {
    const a = r.a;
    const not_deleted = try val.from(a, .{ .deletedAt = .{ .@"$exists" = false } });
    // Reseal's own messages can be found by id alone; a message in an app's storage needs its chat too.
    const from = if (fwd_chat.truthy()) try col().chats.findOne(a, .{ ._id = fwd_chat, .deletedAt = .{ .@"$exists" = false } }, .{}) else null;
    const original = (if (from) |f|
        try store.findOne(r, f, fwd_from, not_deleted)
    else
        try col().messages.findOne(a, .{ ._id = fwd_from, .deletedAt = .{ .@"$exists" = false } }, .{})) orelse return r.fail(400, "That message cannot be forwarded", "fwd_unavailable");
    try r.ensure(!original.get("enc").truthy(), "That message cannot be forwarded", 400, "fwd_unavailable");
    const membership = try col().members.findOne(a, .{ .chatId = original.get("chatId"), .userId = sender.get("_id"), .status = "active" }, .{});
    try r.ensure(membership != null, "That message cannot be forwarded", 403, "fwd_forbidden");
    const source = from orelse (try col().chats.findOne(a, .{ ._id = original.get("chatId") }, .{})) orelse Val.null;
    try r.ensure(!source.get("protectedContent").truthy(), "Forwarding is disabled in that chat", 403, "protected");
    const orig_sender = if (original.path("fwd.fromUserId").truthy()) null else try col().users.findOne(a, .{ ._id = original.get("senderId") }, .{ .projection = .{ .displayName = 1, .privacy = 1 } });
    const channel = eq(source.get("type"), "channel");
    const fwd = if (original.get("fwd").truthy()) original.get("fwd") else try val.from(a, .{
        .fromUserId = if (orig_sender) |os| (if (std.mem.eql(u8, os.path("privacy.forwards").asStr() orelse "everyone", "everyone")) original.get("senderId") else Val.null) else Val.null,
        .fromChatId = if (channel) source.get("_id") else Val.null,
        .fromName = if (channel) source.get("title") else if (orig_sender) |os| (if (os.get("displayName").truthy()) os.get("displayName") else Val.s("Deleted account")) else Val.s("Deleted account"),
        .fromMessageId = if (channel) original.get("_id") else Val.null,
        .date = original.get("createdAt"),
    });
    const copy = try Val.object(a);
    inline for (.{ "text", "entities", "media", "mediaIds", "location", "contact", "sticker", "tags", "preview" }) |k| if (original.get(k) != .undef) try copy.put(a, k, original.get(k));
    if (original.get("poll").truthy()) {
        const p = try val.clone(a, original.get("poll"));
        try p.put(a, "votes", try Val.array(a));
        try p.set(a, "closed", false);
        try copy.put(a, "poll", p);
    }
    return .{ .fwd = fwd, .copy = copy };
}

pub const SendOpts = struct { member: ?Val = null, origin: Origin = .user, skip_permissions: bool = false };

/// Sends a message (REST API, developer API, bots). Returns the stored message document.
pub fn sendMessage(r: *Rq, chat: Val, sender: Val, input: Val, o: SendOpts) !Val {
    const a = r.a;
    const member = o.member orelse (try col().members.findOne(a, .{ .chatId = chat.get("_id"), .userId = sender.get("_id") }, .{})) orelse Val.null;
    try r.ensure(member.truthy() and eq(member.get("status"), "active"), "You are not a member of this chat", 403, "not_member");
    const content = try cleanContent(r, chat, input, o.origin);
    const now_ms = A.nowMs();
    const now: Val = .{ .date = now_ms };
    const ctype = chat.get("type").asStr() orelse "";

    if (!o.skip_permissions) {
        try access.assertCan(r, chat, member, "sendMessages", if (std.mem.eql(u8, ctype, "channel")) "Only admins can post in this channel" else "You cannot send messages here");
        if (content.get("mediaIds").len() > 0 or content.get("sticker").truthy()) try access.assertCan(r, chat, member, "sendMedia", "Sending media is not allowed here");
        if (content.get("poll").truthy()) try access.assertCan(r, chat, member, "sendPolls", "Polls are not allowed here");
        if (std.mem.eql(u8, ctype, "private")) {
            const peer = try access.peerOf(r, chat, sender.get("_id"));
            if (peer.truthy() and try access.isBlocked(r, peer, sender.get("_id"))) return r.fail(403, "You cannot message this user", "blocked");
            if (peer.truthy() and try access.isBlocked(r, sender.get("_id"), peer)) return r.fail(403, "Unblock this user to send a message", "you_blocked");
        }
        const slow = chat.get("slowMode").asInt() orelse 0;
        const last = member.get("lastSentAt");
        if (slow > 0 and eq(member.get("role"), "member") and last == .date and !input.get("scheduledAt").truthy()) {
            const wait = slow * 1000 - (now_ms - last.date);
            if (wait > 0) return r.fail(429, try r.fmt("Slow mode is on. You can send again in {d}s", .{@divFloor(wait + 999, 1000)}), "slow_mode");
        }
        if (chat.get("encrypted").truthy()) {
            const epoch = chat.get("keyEpoch").asInt() orelse 0;
            try r.ensure(epoch > 0, "Encryption keys for this chat are not ready yet", 409, "no_epoch");
            const e = content.path("enc.e").asInt() orelse -1;
            try r.ensure(e == epoch or e == epoch - 1, "Encryption keys changed. Refresh and try again", 409, "stale_epoch");
        }
    }

    // Idempotency: a retried send with the same clientId returns the original message.
    const client_id = try v.str(r, input.get("clientId"), "clientId", .{ .max = 64, .optional = true });
    if (client_id) |cid| if (try store.byClientId(r, chat, sender.get("_id"), cid)) |existing| return existing;

    // Content checks (Wufour Moderation): only where the server can read the message, and only
    // for what a person typed. End-to-end encrypted chats are never checked.
    var moderation_stamp: ?Val = null;
    if (!chat.get("encrypted").truthy() and content.get("text").truthy() and o.origin == .user) {
        const outcome = try moderation.check(r, sender, try val.from(a, .{ .type = "message", .id = try r.str(chat.get("_id")), .field = chat.get("type") }), try val.from(a, .{ .text = content.get("text") }), null);
        moderation_stamp = try moderation.stamp(a, outcome);
    }

    try claimMedia(r, content.get("mediaIds"), sender, chat);

    const doc = try val.from(a, .{ .chatId = chat.get("_id"), .senderId = sender.get("_id"), .kind = "message", .createdAt = now, .reactions = try Val.object(a) });
    if (client_id) |cid| try doc.set(a, "clientId", cid);
    if (moderation_stamp) |m| try doc.put(a, "moderation", m);
    for (content.keys()) |kv| {
        if (inList(kv.k, &.{ "replyToId", "fwdFrom", "fwdChat", "fwdCopy" })) continue;
        try doc.put(a, kv.k, kv.v);
    }
    const fc = content.get("fwdCopy");
    if (fc.truthy()) try doc.set(a, "fwd", .{ .fromUserId = fc.get("fromUserId"), .fromChatId = Val.null, .fromName = fc.get("fromName"), .fromMessageId = Val.null, .date = fc.get("date") });
    const reply = try resolveReply(r, chat, content.get("replyToId"));
    if (reply) |rp| try doc.set(a, "replyTo", .{ .id = rp.get("_id"), .seq = rp.get("seq") });
    if (content.get("fwdFrom").truthy()) {
        const f = try resolveForward(r, sender, content.get("fwdFrom"), content.get("fwdChat"));
        for (f.copy.keys()) |kv| try doc.put(a, kv.k, kv.v);
        try doc.put(a, "fwd", f.fwd);
        if (f.copy.get("mediaIds").truthy()) try claimMedia(r, f.copy.get("mediaIds"), sender, chat);
    }
    if (!chat.get("encrypted").truthy() and doc.get("text").truthy()) try doc.set(a, "search", v.sliceUtf16(try v.jsLower(a, doc.get("text").str), 4000));
    if (input.get("silent").isTrue()) try doc.set(a, "silent", true);

    const ttl: i64 = if (input.get("ttl") != .undef) (try v.int(r, input.get("ttl"), "ttl", .{ .min = 0, .max = 365 * 86400 })) orelse 0 else chat.get("ttl").asInt() orelse 0;
    if (ttl != 0) try doc.set(a, "ttl", ttl);

    if (reply) |rp| if (rp.get("senderId").truthy() and !val.same(rp.get("senderId"), sender.get("_id"))) {
        var list = try Val.array(a);
        for (doc.get("mentions").items()) |m| if (!containsSame(list, m)) try list.push(a, m);
        if (!containsSame(list, rp.get("senderId"))) try list.push(a, rp.get("senderId"));
        try doc.put(a, "mentions", list);
    };

    // "Send when online": the message waits until the other person opens Reseal.
    const wait_for: ?Val = if (input.get("whenOnline").isTrue()) try whenOnlineTarget(r, chat, sender) else null;

    if (wait_for != null or !input.get("scheduledAt").isNullish()) {
        if (wait_for) |w| {
            // It goes out anyway after a year, and shows up (and can be sent now) with the scheduled ones.
            try doc.put(a, "waitFor", w);
            try doc.put(a, "scheduledAt", .{ .date = A.nowMs() + 365 * 86400_000 });
        } else {
            const t: f64 = @floatFromInt(A.nowMs());
            try doc.put(a, "scheduledAt", .{ .date = try v.reqInt(r, input.get("scheduledAt"), "scheduledAt", .{ .min = t + 5_000, .max = t + 365 * 86400_000 }) });
        }
        try doc.put(a, "seq", .null);
        try store.insert(r, chat, doc);
        _ = rt.toUser(a, sender.get("_id"), "message.scheduled", try ser.message(a, doc, sender.get("_id"), chat));
        return doc;
    }

    try doc.set(a, "seq", try nextSeq(r, chat.get("_id")));
    try stampExpiry(a, doc);
    store.insert(r, chat, doc) catch |e| {
        if (e == error.DuplicateKey) if (client_id) |cid| return (try store.byClientId(r, chat, sender.get("_id"), cid)) orelse e;
        return e;
    };
    try afterPublish(r, chat, doc, sender, false);
    return doc;
}

fn containsSame(list: Val, x: Val) bool {
    for (list.items()) |e| if (val.same(e, x)) return true;
    return false;
}

/// Self-destructing messages: the timer starts when the message goes out.
fn stampExpiry(a: Allocator, doc: Val) !void {
    const ttl = doc.get("ttl").asInt() orelse 0;
    const ca = doc.get("createdAt");
    if (ttl != 0 and ca == .date) try doc.put(a, "expiresAt", .{ .date = ca.date + ttl * 1000 });
}

/// Who a "send when online" message waits for, or null when they are online already. Only
/// offered when the sender can see the other person's online status.
fn whenOnlineTarget(r: *Rq, chat: Val, sender: Val) !?Val {
    const a = r.a;
    try r.ensure(eq(chat.get("type"), "private"), "\"Send when online\" works only in private chats", 400, "when_online_unavailable");
    const peer_id = try access.peerOf(r, chat, sender.get("_id"));
    const peer = if (peer_id.truthy()) try col().users.findOne(a, .{ ._id = peer_id }, .{ .projection = .{ .privacy = 1, .kind = 1, .deletedAt = 1 } }) else null;
    try r.ensure(peer != null and !peer.?.get("deletedAt").truthy() and !eq(peer.?.get("kind"), "bot"), "\"Send when online\" is not available here", 400, "when_online_unavailable");
    const is_contact = (try col().contacts.findOne(a, .{ .userId = peer_id, .contactId = sender.get("_id") }, .{ .projection = .{ ._id = 1 } })) != null;
    try r.ensure(rt.canSeePresence(peer_id, sender.get("_id"), peer.?.get("privacy"), is_contact), "This person hides when they are online", 403, "presence_hidden");
    return if (rt.isOnline(peer_id) and !rt.isAway(peer_id)) null else peer_id;
}

fn nextSeq(r: *Rq, chat_id: Val) !i64 {
    const updated = (try col().chats.findOneAndUpdate(r.a, .{ ._id = chat_id }, .{ .@"$inc" = .{ .seq = 1 } }, .{ .projection = .{ .seq = 1 } })) orelse return error.ChatGone;
    return updated.get("seq").asInt() orelse 0;
}

const MsgCtx = struct { doc: Val, chat: Val };

fn messageFor(c: MsgCtx, a: Allocator, uid: []const u8) anyerror!?Val {
    return try ser.message(a, c.doc, .{ .str = uid }, c.chat);
}

/// Fans out a freshly stored message: counters, chat list order, realtime, push, webhooks, bots.
fn afterPublish(r: *Rq, chat: Val, doc: Val, sender: ?Val, quiet: bool) !void {
    const a = r.a;
    const now = doc.get("createdAt");
    const seq = doc.get("seq");
    if (doc.get("expiresAt").truthy() and store.isAppChat(chat)) {
        // The app keeps the message; Reseal keeps only the timer, so it can remove it everywhere on time.
        _ = try col().messageTimers.insertOne(a, try val.from(a, .{ .chatId = chat.get("_id"), .messageId = doc.get("_id"), .seq = seq, .expiresAt = doc.get("expiresAt") }));
    }
    const summary = try lastMessageSummary(r, doc, chat);
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id"), .@"$or" = .{ .{ .@"lastMessage.seq" = .{ .@"$lt" = seq } }, .{ .lastMessage = .{ .@"$exists" = false } }, .{ .lastMessage = Val.null } } }, .{ .@"$set" = .{ .lastMessage = summary, .lastMessageAt = now } }, .{});

    const sender_id: Val = if (sender) |s_| s_.get("_id") else .null;
    const is_service = eq(doc.get("kind"), "service");
    const others = try val.from(a, .{ .chatId = chat.get("_id"), .status = "active", .userId = .{ .@"$ne" = sender_id } });
    if (!is_service or doc.path("service.notify").truthy()) {
        _ = try col().members.updateMany(a, others, .{ .@"$inc" = .{ .unread = 1 }, .@"$set" = .{ .lastActivityAt = now }, .@"$unset" = .{ .hiddenAt = "" } }, .{});
        if (doc.get("mentions").len() > 0) {
            var targets = try Val.array(a);
            for (doc.get("mentions").items()) |m| if (!val.same(m, sender_id)) try targets.push(a, m);
            const f = try val.clone(a, others);
            try f.set(a, "userId", .{ .@"$in" = targets });
            _ = try col().members.updateMany(a, f, .{ .@"$inc" = .{ .mentions = 1 } }, .{});
        }
        // A new message brings an archived chat back, unless it is muted.
        const f = try val.clone(a, others);
        try f.set(a, "archived", true);
        try f.set(a, "$or", .{ .{ .mutedUntil = Val.null }, .{ .mutedUntil = .{ .@"$lt" = now } }, .{ .mutedUntil = .{ .@"$exists" = false } } });
        _ = try col().members.updateMany(a, f, .{ .@"$set" = .{ .archived = false } }, .{});
    } else {
        _ = try col().members.updateMany(a, others, .{ .@"$set" = .{ .lastActivityAt = now } }, .{});
    }
    if (sender) |s_| if (!is_service) {
        _ = try col().members.updateOne(a, .{ .chatId = chat.get("_id"), .userId = s_.get("_id") }, .{
            .@"$set" = .{ .lastReadSeq = seq, .unread = 0, .mentions = 0, .markedUnread = false, .lastSentAt = now, .lastActivityAt = now },
            .@"$unset" = .{ .draft = "" },
        }, .{});
        if (doc.get("senderId").truthy()) try bumpReadTop(r, chat, s_.get("_id"), seq.asInt() orelse 0, !(s_.path("privacy.readReceipts") == .bool and !s_.path("privacy.readReceipts").bool));
    };

    rt.toChatEach(a, chat.get("_id"), "message", MsgCtx{ .doc = doc, .chat = chat }, messageFor);
    if (doc.get("reminder").truthy()) if (sender) |s_| {
        // Reminders show the Saved chat as unread until you look at it.
        if (try col().members.findOneAndUpdate(a, .{ .chatId = chat.get("_id"), .userId = s_.get("_id") }, .{ .@"$set" = .{ .markedUnread = true } }, .{})) |mine| {
            _ = rt.toUser(a, s_.get("_id"), "chat.state", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .me = (try ser.chat(a, chat, mine, s_.get("_id"), .{})).get("me") }));
        }
    };
    if (!quiet) try events.emit(a, .message_created, try val.from(a, .{ .chat = chat, .message = doc, .sender = if (sender) |s_| s_ else Val.null }));
}

/// Publishes a message built by the server itself (AI replies, greetings). Fields are trusted.
/// With `quiet` the "message.created" event is held back (the caller emits it when done).
pub fn publishRaw(r: *Rq, chat: Val, sender: Val, fields: Val, quiet: bool) !Val {
    const a = r.a;
    const doc = try val.from(a, .{ .chatId = chat.get("_id"), .senderId = sender.get("_id"), .kind = "message", .createdAt = A.now(), .reactions = try Val.object(a) });
    for (fields.keys()) |kv| try doc.put(a, kv.k, kv.v);
    if (!chat.get("encrypted").truthy() and doc.get("text").truthy()) try doc.set(a, "search", v.sliceUtf16(try v.jsLower(a, doc.get("text").str), 4000));
    try doc.set(a, "seq", try nextSeq(r, chat.get("_id")));
    try store.insert(r, chat, doc);
    try afterPublish(r, chat, doc, sender, quiet);
    return doc;
}

/// A copy of the newest message, kept on the chat for the chat list. In an app's chats it holds
/// no content (that stays in the app's storage); fillLastMessages fetches it for the list.
pub fn lastMessageSummary(r: *Rq, doc: Val, chat: ?Val) !Val {
    const a = r.a;
    const out = try val.from(a, .{ .id = doc.get("_id"), .seq = doc.get("seq"), .senderId = doc.get("senderId"), .kind = doc.get("kind"), .createdAt = doc.get("createdAt") });
    if (chat != null and store.isAppChat(chat.?)) {
        inline for (.{ "service", "tags", "ttl" }) |k| if (doc.get(k) != .undef) try out.put(a, k, doc.get(k));
        if (eq(doc.get("kind"), "message")) try out.set(a, "contentInApp", true);
        return out;
    }
    inline for (.{ "enc", "service", "tags", "sticker", "fwd", "ttl" }) |k| if (doc.get(k) != .undef) try out.put(a, k, doc.get(k));
    if (doc.get("text").truthy()) try out.set(a, "text", v.sliceUtf16(doc.get("text").str, 300));
    if (doc.get("entities").truthy()) {
        var list = try Val.array(a);
        for (doc.get("entities").items()) |e| if ((e.get("o").asNum() orelse 0) < 300) try list.push(a, e);
        try out.put(a, "entities", list);
    }
    if (doc.get("media").truthy()) {
        var list = try Val.array(a);
        for (doc.get("media").items()) |m| try list.push(a, try val.from(a, .{ .kind = m.get("kind"), .name = m.get("name"), .thumb = Val.undef, .duration = m.get("duration") }));
        try out.put(a, "media", list);
    }
    if (doc.get("poll").truthy()) try out.set(a, "poll", .{ .question = doc.path("poll.question"), .optionCount = doc.path("poll.optionCount"), .quiz = doc.path("poll.quiz") });
    if (doc.get("location").truthy()) try out.set(a, "location", .{ .title = doc.path("location.title") });
    if (doc.get("contact").truthy()) try out.set(a, "contact", .{ .name = doc.path("contact.name") });
    return out;
}

/// Puts the newest message's content back on chats from apps before they are shown, one request
/// per app. A chat keeps its content-free summary when the app cannot be reached.
pub fn fillLastMessages(r: *Rq, chats: []Val) !void {
    const a = r.a;
    var done: std.ArrayList(usize) = .empty;
    for (chats, 0..) |c, i| {
        if (!c.path("lastMessage.contentInApp").truthy()) continue;
        if (std.mem.indexOfScalar(usize, done.items, i) != null) continue;
        // Every chat of the same app, in one request.
        var group: std.ArrayList(usize) = .empty;
        for (chats, 0..) |c2, j| if (c2.path("lastMessage.contentInApp").truthy() and val.same(c2.get("appId"), c.get("appId"))) {
            try group.append(a, j);
            try done.append(a, j);
        };
        var ids = try Val.array(a);
        for (group.items) |j| try ids.push(a, try r.sn(chats[j].path("lastMessage.id")));
        const res = store.callApp(r, c.get("appId"), "get", try val.from(a, .{ .ids = ids }), null) catch {
            r.err = null;
            continue;
        };
        for (group.items) |j| {
            for (res.get("messages").items()) |rec| {
                const d = (store.fromRecord(r, rec) catch null) orelse continue;
                if (val.same(d.get("_id"), chats[j].path("lastMessage.id")) and val.same(d.get("chatId"), chats[j].get("_id"))) {
                    try chats[j].put(a, "lastMessage", try lastMessageSummary(r, d, null));
                    break;
                }
            }
        }
    }
}

/// Posts a service notice ("Alice joined", "Call ended"): plain metadata, never message text.
pub fn serviceMessage(r: *Rq, chat: Val, actor_id: Val, action: []const u8, extra: Val, notify: bool) !Val {
    const a = r.a;
    const actor: Val = if (actor_id.truthy()) actor_id else .null;
    const service = try val.from(a, .{ .action = action, .actorId = actor });
    for (extra.keys()) |kv| try service.put(a, kv.k, kv.v);
    try service.put(a, "notify", if (notify) Val.True else Val.undef);
    const doc = try val.from(a, .{ .chatId = chat.get("_id"), .senderId = actor, .kind = "service", .service = service, .createdAt = A.now() });
    try doc.set(a, "seq", try nextSeq(r, chat.get("_id")));
    try store.insert(r, chat, doc);
    try afterPublish(r, chat, doc, if (actor_id.truthy()) try val.from(a, .{ ._id = actor_id }) else null, false);
    return doc;
}

// ---- Reading history ------------------------------------------------------------------------

/// The lowest seq a member may see (cleared history, or hidden pre-join history).
pub fn visibleFrom(chat: Val, member: Val) i64 {
    var from = member.get("clearedSeq").asInt() orelse 0;
    if (eq(chat.get("type"), "group") and chat.get("historyVisible") == .bool and !chat.get("historyVisible").bool) from = @max(from, member.get("joinedSeq").asInt() orelse 0);
    return from;
}

pub const HistoryOpts = struct { before: ?i64 = null, after: ?i64 = null, around: ?i64 = null, limit: i64 = 50, kind: ?[]const u8 = null, tag: ?[]const u8 = null };

pub fn history(r: *Rq, chat: Val, member: Val, o: HistoryOpts) ![]Val {
    const a = r.a;
    const lim = @min(@max(o.limit, 1), 100);
    const floor = visibleFrom(chat, member);
    const filter = try val.from(a, .{ .hiddenFor = .{ .@"$ne" = member.get("userId") } });
    if (o.kind) |k| try filter.set(a, "kind", k);
    if (o.tag) |t| try filter.set(a, "tags", t);
    if (o.around) |around| {
        const half = @divFloor(lim, 2);
        const older = try store.list(r, chat, .{ .filter = filter, .after = floor, .before = around + 1, .limit = half + 1 });
        const newer = try store.list(r, chat, .{ .filter = filter, .after = @max(floor, around), .asc = true, .limit = lim - half });
        var out: std.ArrayList(Val) = .empty;
        var i = older.len;
        while (i > 0) {
            i -= 1;
            try out.append(a, older[i]);
        }
        try out.appendSlice(a, newer);
        return out.items;
    }
    if (o.after) |after| return store.list(r, chat, .{ .filter = filter, .after = @max(floor, after), .asc = true, .limit = lim });
    const docs = try store.list(r, chat, .{ .filter = filter, .after = floor, .before = o.before, .limit = lim });
    std.mem.reverse(Val, docs);
    return docs;
}

// ---- Editing and deleting -------------------------------------------------------------------

pub fn editMessage(r: *Rq, chat: Val, member: Val, user: Val, message_id: Val, input: Val) !Val {
    const a = r.a;
    const msg = (try store.findOne(r, chat, message_id, try val.from(a, .{ .deletedAt = .{ .@"$exists" = false } }))) orelse return r.fail(404, "Message not found", "message_not_found");
    try r.ensure(eq(msg.get("kind"), "message"), "Message not found", 404, "message_not_found");
    const own = val.same(msg.get("senderId"), user.get("_id"));
    const channel_editor = eq(chat.get("type"), "channel") and access.can(chat, member, "editMessages");
    try r.ensure(own or channel_editor, "You can only edit your own messages", 403, "not_author");
    if (!eq(chat.get("type"), "saved") and msg.get("seq") != .null) {
        const ca = msg.get("createdAt");
        try r.ensure(ca == .date and A.nowMs() - ca.date < Limits.edit_window_ms, "This message is too old to edit", 403, "edit_window");
    }
    try r.ensure(!msg.get("fwd").truthy(), "Forwarded messages cannot be edited", 403, "forwarded");

    const set = try Val.object(a);
    const unset = try Val.object(a);
    if (chat.get("encrypted").truthy()) {
        _ = try v.reqObj(r, input.get("enc"), "enc");
        const enc = try cleanEnc(r, input.get("enc"));
        try set.put(a, "enc", enc);
        try r.ensure((enc.get("e").asInt() orelse 0) >= (chat.get("keyEpoch").asInt() orelse 0) - 1, "Encryption keys changed. Refresh and try again", 409, "stale_epoch");
        if (input.get("tags") != .undef) try set.put(a, "tags", input.get("tags"));
    } else {
        const max_text: usize = if (msg.get("media").len() > 0) Limits.caption_length else Limits.text_length;
        const text = try v.str(r, input.get("text"), "text", .{ .max = max_text, .optional = true, .trim = false });
        if (text != null and v.jsTrim(text.?).len > 0) {
            const t = v.trimEnd(text.?);
            try set.set(a, "text", t);
            try set.set(a, "search", v.sliceUtf16(try v.jsLower(a, t), 4000));
            // Content checks (Wufour Moderation): only reached in readable chats.
            try set.put(a, "moderation", try moderation.stamp(a, try moderation.check(r, user, try val.from(a, .{ .type = "message", .id = try r.str(chat.get("_id")), .field = "edit" }), try val.from(a, .{ .text = t }), null)));
            if (try cleanEntities(r, input.get("entities"), v.utf16Len(t))) |ents| {
                if (ents.len() > 0) try set.put(a, "entities", ents) else try unset.set(a, "entities", "");
            } else try unset.set(a, "entities", "");
        } else {
            try r.ensure(msg.get("media").len() > 0 or msg.get("poll").truthy(), "The message is empty", 400, "empty_message");
            try unset.set(a, "text", "");
            try unset.set(a, "entities", "");
            try unset.set(a, "search", "");
        }
        if (input.get("preview") == .null) try unset.set(a, "preview", "");
        if (input.get("buttons") != .undef and msg.get("buttons").truthy()) try set.put(a, "buttons", (try cleanButtons(r, input.get("buttons"))) orelse .undef);
    }
    if (msg.get("seq") != .null) try set.put(a, "editedAt", A.now());
    const upd = try val.from(a, .{ .@"$set" = set });
    if (unset.len() > 0) try upd.put(a, "$unset", unset);
    const updated = (try store.update(r, chat, msg.get("_id"), upd)) orelse return r.fail(404, "Message not found", "message_not_found");

    if (updated.get("seq") == .null) {
        _ = rt.toUser(a, user.get("_id"), "message.scheduled", try ser.message(a, updated, user.get("_id"), chat));
        return updated;
    }
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id"), .@"lastMessage.id" = msg.get("_id") }, .{ .@"$set" = .{ .lastMessage = try lastMessageSummary(r, updated, chat) } }, .{});
    rt.toChatEach(a, chat.get("_id"), "message.edit", MsgCtx{ .doc = updated, .chat = chat }, messageFor);
    try events.emit(a, .message_edited, try val.from(a, .{ .chat = chat, .message = updated, .editor = user }));
    return updated;
}

/// Deletes messages for everyone (tombstones) or only for the caller.
pub fn deleteMessages(r: *Rq, chat: Val, member: Val, user: Val, ids: []const Val, for_everyone: bool) !Val {
    const a = r.a;
    const found = try store.findMany(r, chat, ids);
    if (found.len == 0) return val.from(a, .{ .deleted = try Val.array(a) });
    const t = chat.get("type").asStr() orelse "";
    const may_others = std.mem.eql(u8, t, "private") or std.mem.eql(u8, t, "saved") or std.mem.eql(u8, t, "bot") or access.can(chat, member, "deleteMessages");
    const cid = try r.str(chat.get("_id"));

    if (!for_everyone and !std.mem.eql(u8, t, "channel")) {
        var mine: std.ArrayList(Val) = .empty;
        var strs = try Val.array(a);
        for (found) |m| {
            try mine.append(a, m.get("_id"));
            try strs.push(a, try r.sn(m.get("_id")));
        }
        try store.updateMany(r, chat, mine.items, try val.from(a, .{ .@"$addToSet" = .{ .hiddenFor = user.get("_id") } }));
        _ = rt.toUser(a, user.get("_id"), "message.delete", try val.from(a, .{ .chatId = cid, .ids = strs, .forEveryone = false }));
        try recountUnread(r, chat, &.{user.get("_id")}, null);
        return val.from(a, .{ .deleted = strs });
    }

    var allowed: std.ArrayList(Val) = .empty;
    for (found) |m| if (val.same(m.get("senderId"), user.get("_id")) or may_others) try allowed.append(a, m);
    try r.ensure(allowed.items.len > 0, "You cannot delete these messages", 403, "no_permission");
    var scheduled: std.ArrayList(Val) = .empty;
    var published: std.ArrayList(Val) = .empty;
    var allowed_strs = try Val.array(a);
    for (allowed.items) |m| {
        try allowed_strs.push(a, try r.sn(m.get("_id")));
        if (m.get("seq") == .null) try scheduled.append(a, m.get("_id")) else try published.append(a, m);
    }
    if (scheduled.items.len > 0) _ = try col().messages.deleteMany(a, .{ ._id = .{ .@"$in" = scheduled.items }, .chatId = chat.get("_id") });
    if (published.items.len > 0) {
        var pids: std.ArrayList(Val) = .empty;
        var pstrs = try Val.array(a);
        var max_seq: i64 = 0;
        for (published.items) |m| {
            try pids.append(a, m.get("_id"));
            try pstrs.push(a, try r.sn(m.get("_id")));
            max_seq = @max(max_seq, m.get("seq").asInt() orelse 0);
        }
        try store.updateMany(r, chat, pids.items, try val.from(a, .{
            .@"$set" = .{ .deletedAt = A.now(), .deletedBy = user.get("_id") },
            .@"$unset" = .{ .enc = "", .text = "", .entities = "", .media = "", .poll = "", .location = "", .contact = "", .sticker = "", .preview = "", .search = "", .reactions = "", .fwd = "", .buttons = "", .metadata = "" },
        }));
        _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id"), .pinned = .{ .@"$in" = pids.items } }, .{ .@"$pull" = .{ .pinned = .{ .@"$in" = pids.items } } }, .{});
        try refreshLastMessage(r, chat);
        try recountUnread(r, chat, null, max_seq);
        rt.toChat(a, chat.get("_id"), "message.delete", try val.from(a, .{ .chatId = cid, .ids = pstrs, .forEveryone = true }), null);
        try events.emit(a, .message_deleted, try val.from(a, .{ .chat = chat, .ids = pids.items, .by = user }));
    }
    if (scheduled.items.len > 0) {
        var sstrs = try Val.array(a);
        for (scheduled.items) |x| try sstrs.push(a, try r.sn(x));
        _ = rt.toUser(a, user.get("_id"), "message.delete", try val.from(a, .{ .chatId = cid, .ids = sstrs, .scheduled = true }));
    }
    return val.from(a, .{ .deleted = allowed_strs });
}

pub fn refreshLastMessage(r: *Rq, chat: Val) !void {
    const a = r.a;
    const newest = try store.latest(r, chat, try val.from(a, .{ .deletedAt = .{ .@"$exists" = false } }));
    if (newest) |n| {
        _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = .{ .lastMessage = try lastMessageSummary(r, n, chat) } }, .{});
    } else {
        _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = .{ .lastMessage = Val.null } }, .{});
    }
}

/// Recounts unread messages for members (after deletions, or a read).
pub fn recountUnread(r: *Rq, chat: Val, user_ids: ?[]const Val, below_seq: ?i64) !void {
    const a = r.a;
    const filter = try val.from(a, .{ .chatId = chat.get("_id"), .status = "active" });
    if (user_ids) |ids| try filter.set(a, "userId", .{ .@"$in" = ids });
    if (below_seq) |b| try filter.set(a, "lastReadSeq", .{ .@"$lt" = b });
    const members = try col().members.find(a, filter, .{ .projection = .{ .userId = 1, .lastReadSeq = 1, .clearedSeq = 1 }, .limit = 500 });
    if (members.len == 0) return;
    const fromOf = struct {
        fn f(m: Val) i64 {
            return @max(m.get("lastReadSeq").asInt() orelse 0, m.get("clearedSeq").asInt() orelse 0);
        }
    }.f;
    var recent: ?[]Val = null;
    if (store.isAppChat(chat)) {
        // An app's storage is asked once for the unread part of the chat; the counting happens here.
        var lo: i64 = std.math.maxInt(i64);
        for (members) |m| lo = @min(lo, fromOf(m));
        recent = try store.list(r, chat, .{ .filter = try val.from(a, .{ .deletedAt = .{ .@"$exists" = false }, .kind = "message" }), .after = lo, .asc = true, .limit = 999 });
    }
    for (members) |m| {
        const mine = try val.from(a, .{ .senderId = .{ .@"$ne" = m.get("userId") }, .hiddenFor = .{ .@"$ne" = m.get("userId") } });
        var unread: i64 = 0;
        if (recent) |list| {
            for (list) |d| if ((d.get("seq").asInt() orelse 0) > fromOf(m) and store.matches(a, d, mine)) {
                unread += 1;
            };
        } else {
            const f = try val.clone(a, mine);
            try f.set(a, "deletedAt", .{ .@"$exists" = false });
            try f.set(a, "kind", "message");
            unread = try store.count(r, chat, f, fromOf(m));
        }
        _ = try col().members.updateOne(a, .{ ._id = m.get("_id") }, .{ .@"$set" = .{ .unread = unread } }, .{});
        _ = rt.toUser(a, m.get("userId"), "chat.unread", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .unread = unread }));
    }
}

// ---- Reactions, polls, pins -------------------------------------------------------------------

fn isEmojiCodepoint(c: u21) bool {
    return switch (c) {
        '#', '*', '0'...'9' => true, // keycap bases (Emoji_Component)
        0x200D, 0xFE0F, 0x20E3 => true,
        0x00A9, 0x00AE, 0x203C, 0x2049, 0x2122, 0x2139 => true,
        0x2194...0x2199, 0x21A9...0x21AA, 0x231A...0x231B, 0x2328, 0x2388, 0x23CF, 0x23E9...0x23F3, 0x23F8...0x23FA => true,
        0x24C2, 0x25AA...0x25AB, 0x25B6, 0x25C0, 0x25FB...0x25FE => true,
        0x2600...0x27BF => true,
        0x2934...0x2935, 0x2B05...0x2B07, 0x2B1B...0x2B1C, 0x2B50, 0x2B55, 0x3030, 0x303D, 0x3297, 0x3299 => true,
        0x1F000...0x1FAFF => true,
        0x1FC00...0x1FFFD => true,
        0xE0020...0xE007F => true,
        else => false,
    };
}

/// /^[\p{Extended_Pictographic}\p{Emoji_Component}‍️⃣]{1,16}$/u
fn isEmoji(s: []const u8) bool {
    const view = std.unicode.Utf8View.init(s) catch return false;
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |c| {
        if (!isEmojiCodepoint(c)) return false;
        n += 1;
    }
    return n >= 1 and n <= 16;
}

const ReactCtx = struct { chat: Val, id: Val, reactions: Val, actor: []const u8, emoji: []const u8, on: bool, author: Val, channel: bool };

fn reactionsFor(c: ReactCtx, a: Allocator, uid: []const u8) anyerror!?Val {
    return try val.from(a, .{ .chatId = try val.str(a, c.chat.get("_id")), .id = try val.str(a, c.id), .reactions = try ser.reactionsOf(a, c.reactions, .{ .str = uid }, c.channel), .actorId = c.actor, .emoji = c.emoji, .on = c.on, .authorId = c.author });
}

pub fn react(r: *Rq, chat: Val, user: Val, message_id: Val, emoji_v: Val, add: bool) !Val {
    const a = r.a;
    const emoji = emoji_v.asStr() orelse "";
    try r.ensure(emoji_v == .str and isEmoji(emoji) and std.mem.indexOfScalar(u8, emoji, '.') == null and !std.mem.startsWith(u8, emoji, "$"), "That reaction is not supported", 400, "bad_reaction");
    if (chat.get("reactions") == .arr) try r.ensure(containsStr(chat.get("reactions"), emoji), "That reaction is not allowed here", 403, "reaction_not_allowed");
    const msg = (try store.findOne(r, chat, message_id, try val.from(a, .{ .deletedAt = .{ .@"$exists" = false }, .seq = .{ .@"$ne" = Val.null } }))) orelse return r.fail(404, "Message not found", "message_not_found");
    try r.ensure(eq(msg.get("kind"), "message"), "Message not found", 404, "message_not_found");
    const key = try r.fmt("reactions.{s}", .{emoji});
    var updated: ?Val = null;
    if (add) {
        var mine: std.ArrayList([]const u8) = .empty;
        for (msg.get("reactions").keys()) |kv| if (containsSame(kv.v, user.get("_id"))) try mine.append(a, kv.k);
        // Up to three different reactions per person; the oldest one makes room.
        const ops = try Val.object(a);
        const add_set = try Val.object(a);
        try add_set.put(a, key, user.get("_id"));
        try ops.put(a, "$addToSet", add_set);
        var has_it = false;
        for (mine.items) |e| if (std.mem.eql(u8, e, emoji)) {
            has_it = true;
        };
        if (mine.items.len >= 3 and !has_it) {
            const pull = try Val.object(a);
            try pull.put(a, try r.fmt("reactions.{s}", .{mine.items[0]}), user.get("_id"));
            try ops.put(a, "$pull", pull);
        }
        updated = try store.update(r, chat, msg.get("_id"), ops);
        if (!val.same(msg.get("senderId"), user.get("_id")) and msg.get("senderId").truthy()) {
            _ = try col().members.updateOne(a, .{ .chatId = chat.get("_id"), .userId = msg.get("senderId") }, .{ .@"$inc" = .{ .reactionsUnread = 1 } }, .{});
        }
    } else {
        const pull = try Val.object(a);
        try pull.put(a, key, user.get("_id"));
        updated = try store.update(r, chat, msg.get("_id"), try val.from(a, .{ .@"$pull" = pull }));
    }
    var u = updated orelse return r.fail(404, "Message not found", "message_not_found");
    // Remove empty reaction lists so they do not pile up.
    const unset = try Val.object(a);
    for (u.get("reactions").keys()) |kv| if (kv.v.len() == 0) try unset.set(a, try r.fmt("reactions.{s}", .{kv.k}), "");
    if (unset.len() > 0) {
        if (try store.update(r, chat, msg.get("_id"), try val.from(a, .{ .@"$unset" = unset }))) |x| u = x;
    }
    rt.toChatEach(a, chat.get("_id"), "message.reactions", ReactCtx{ .chat = chat, .id = msg.get("_id"), .reactions = u.get("reactions"), .actor = try r.str(user.get("_id")), .emoji = emoji, .on = add, .author = try r.sn(msg.get("senderId")), .channel = eq(chat.get("type"), "channel") }, reactionsFor);
    try events.emit(a, .message_reaction, try val.from(a, .{ .chat = chat, .message = msg, .user = user, .emoji = emoji, .on = add }));
    return ser.reactionsOf(a, u.get("reactions"), user.get("_id"), false);
}

pub fn vote(r: *Rq, chat: Val, user: Val, message_id: Val, options: Val) !Val {
    const a = r.a;
    const msg = (try store.findOne(r, chat, message_id, try val.from(a, .{ .deletedAt = .{ .@"$exists" = false } }))) orelse return r.fail(404, "Poll not found", "poll_not_found");
    const poll = msg.get("poll");
    try r.ensure(poll.truthy(), "Poll not found", 404, "poll_not_found");
    const close_at = poll.get("closeAt");
    try r.ensure(!poll.get("closed").truthy() and !(close_at == .date and close_at.date < A.nowMs()), "This poll is closed", 403, "poll_closed");
    try r.ensure(options == .arr, "options must be a list", 400, null);
    const count_: f64 = @floatFromInt((poll.get("optionCount").asInt() orelse 0) - 1);
    var chosen = try Val.array(a);
    for (options.items()) |o| {
        const x = try v.reqInt(r, o, "option", .{ .min = 0, .max = count_ });
        var dup = false;
        for (chosen.items()) |c| if (c.num == @as(f64, @floatFromInt(x))) {
            dup = true;
        };
        if (!dup) try chosen.push(a, Val.n(x));
    }
    var previous = false;
    for (poll.get("votes").items()) |x| if (val.same(x.get("u"), user.get("_id"))) {
        previous = true;
    };
    var updated: ?Val = null;
    const pull = try val.from(a, .{ .@"$pull" = .{ .@"poll.votes" = .{ .u = user.get("_id") } } });
    if (chosen.len() == 0) {
        try r.ensure(!poll.get("quiz").truthy(), "Quiz answers cannot be taken back", 403, "quiz_final");
        updated = try store.update(r, chat, msg.get("_id"), pull);
    } else {
        try r.ensure(poll.get("multiple").truthy() or chosen.len() == 1, "Choose one option", 400, null);
        try r.ensure(!previous or !poll.get("quiz").truthy(), "You already answered this quiz", 409, "already_voted");
        _ = try store.update(r, chat, msg.get("_id"), pull);
        updated = try store.update(r, chat, msg.get("_id"), try val.from(a, .{ .@"$push" = .{ .@"poll.votes" = .{ .u = user.get("_id"), .o = chosen, .at = A.now() } } }));
    }
    return broadcastPoll(r, chat, updated orelse msg);
}

pub fn closePoll(r: *Rq, chat: Val, member: Val, user: Val, message_id: Val) !Val {
    const a = r.a;
    const msg = (try store.findOne(r, chat, message_id, null)) orelse return r.fail(404, "Poll not found", "poll_not_found");
    try r.ensure(msg.get("poll").truthy(), "Poll not found", 404, "poll_not_found");
    try r.ensure(val.same(msg.get("senderId"), user.get("_id")) or access.can(chat, member, "deleteMessages"), "Only the author can close this poll", 403, "no_permission");
    const updated = try store.update(r, chat, msg.get("_id"), try val.from(a, .{ .@"$set" = .{ .@"poll.closed" = true } }));
    return broadcastPoll(r, chat, updated orelse msg);
}

const PollCtx = struct { chat: Val, msg: Val };

fn pollFor(c: PollCtx, a: Allocator, uid: []const u8) anyerror!?Val {
    return try val.from(a, .{ .chatId = try val.str(a, c.chat.get("_id")), .id = try val.str(a, c.msg.get("_id")), .poll = try ser.poll(a, c.msg.get("poll"), .{ .str = uid }) });
}

fn broadcastPoll(r: *Rq, chat: Val, updated: Val) !Val {
    rt.toChatEach(r.a, chat.get("_id"), "message.poll", PollCtx{ .chat = chat, .msg = updated }, pollFor);
    return updated.get("poll");
}

/// Voters of a non-anonymous poll.
pub fn pollVoters(r: *Rq, chat: Val, message_id: Val) !Val {
    const a = r.a;
    const msg = (try store.findOne(r, chat, message_id, null)) orelse return r.fail(404, "Poll not found", "poll_not_found");
    try r.ensure(msg.get("poll").truthy(), "Poll not found", 404, "poll_not_found");
    try r.ensure(msg.path("poll.anonymous") == .bool and !msg.path("poll.anonymous").bool, "This poll is anonymous", 403, "anonymous");
    var out = try Val.array(a);
    for (msg.path("poll.votes").items()) |x| try out.push(a, try val.from(a, .{ .userId = try r.sn(x.get("u")), .options = x.get("o"), .at = x.get("at") }));
    return out;
}

pub fn pin(r: *Rq, chat: Val, member: Val, user: Val, message_id: Val, silent: bool, unpin: bool) !Val {
    const a = r.a;
    try access.assertCan(r, chat, member, "pinMessages", "You cannot pin messages here");
    const msg = (try store.findOne(r, chat, message_id, try val.from(a, .{ .deletedAt = .{ .@"$exists" = false }, .seq = .{ .@"$ne" = Val.null } }))) orelse return r.fail(404, "Message not found", "message_not_found");
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$pull" = .{ .pinned = msg.get("_id") } }, .{});
    if (!unpin) _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$push" = .{ .pinned = .{ .@"$each" = .{msg.get("_id")}, .@"$position" = 0, .@"$slice" = 100 } } }, .{});
    const fresh = (try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{ .projection = .{ .pinned = 1 } })) orelse Val.null;
    var pinned = try Val.array(a);
    for (fresh.get("pinned").items()) |p| try pinned.push(a, try r.sn(p));
    rt.toChat(a, chat.get("_id"), "chat.pins", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .pinned = pinned }), null);
    if (!unpin and !silent and !eq(chat.get("type"), "saved")) {
        _ = try serviceMessage(r, chat, user.get("_id"), "pinned", try val.from(a, .{ .messageId = msg.get("_id"), .seq = msg.get("seq") }), true);
    }
    return pinned;
}

pub fn unpinAll(r: *Rq, chat: Val, member: Val) !void {
    const a = r.a;
    try access.assertCan(r, chat, member, "pinMessages", "You cannot unpin messages here");
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = .{ .pinned = try Val.array(a) } }, .{});
    rt.toChat(a, chat.get("_id"), "chat.pins", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .pinned = try Val.array(a) }), null);
}

// ---- Read receipts and views ----------------------------------------------------------------

/// Keeps the three furthest readers on the chat: enough to draw check marks without a query per chat.
fn bumpReadTop(r: *Rq, chat: Val, user_id: Val, seq: i64, share: bool) !void {
    const a = r.a;
    if (!share) return;
    const fresh = try col().chats.findOne(a, .{ ._id = chat.get("_id") }, .{ .projection = .{ .readTop = 1 } });
    var top: std.ArrayList(Val) = .empty;
    if (fresh) |f| for (f.get("readTop").items()) |x| if (!val.same(x.get("u"), user_id)) try top.append(a, x);
    try top.append(a, try val.from(a, .{ .u = user_id, .s = seq }));
    std.mem.sort(Val, top.items, {}, struct {
        fn lt(_: void, x: Val, y: Val) bool {
            return (x.get("s").asNum() orelse 0) > (y.get("s").asNum() orelse 0);
        }
    }.lt);
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = .{ .readTop = top.items[0..@min(3, top.items.len)] } }, .{});
}

pub fn markRead(r: *Rq, chat: Val, member: Val, user: Val, seq: i64) !Val {
    const a = r.a;
    const chat_seq = chat.get("seq").asInt() orelse 0;
    const up_to = @min(seq, chat_seq);
    const last = member.get("lastReadSeq").asInt() orelse 0;
    if (up_to <= last and !member.get("markedUnread").truthy() and !member.get("mentions").truthy() and !member.get("reactionsUnread").truthy()) {
        return val.from(a, .{ .lastReadSeq = last, .unread = member.get("unread").asInt() orelse 0 });
    }
    const last_read = @max(up_to, last);
    const unread: i64 = if (last_read >= chat_seq) 0 else try store.count(r, chat, try val.from(a, .{
        .senderId = .{ .@"$ne" = user.get("_id") },
        .deletedAt = .{ .@"$exists" = false },
        .hiddenFor = .{ .@"$ne" = user.get("_id") },
        .kind = "message",
    }), @max(last_read, member.get("clearedSeq").asInt() orelse 0));
    const set = try val.from(a, .{ .lastReadSeq = last_read, .unread = unread, .markedUnread = false });
    if (unread == 0) {
        try set.set(a, "mentions", 0);
        try set.set(a, "reactionsUnread", 0);
    }
    _ = try col().members.updateOne(a, .{ ._id = member.get("_id") }, .{ .@"$set" = set }, .{});
    const mentions: Val = if (set.get("mentions") != .undef) set.get("mentions") else if (!member.get("mentions").isNullish()) member.get("mentions") else Val.n(0);
    _ = rt.toUser(a, user.get("_id"), "chat.read", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .lastReadSeq = last_read, .unread = unread, .mentions = mentions }));
    const receipts = !(user.path("privacy.readReceipts") == .bool and !user.path("privacy.readReceipts").bool);
    if (up_to > last and receipts and !eq(chat.get("type"), "channel")) {
        try bumpReadTop(r, chat, user.get("_id"), last_read, true);
        rt.toChat(a, chat.get("_id"), "read", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .userId = try r.str(user.get("_id")), .seq = last_read }), user.get("_id"));
    }
    return val.from(a, .{ .lastReadSeq = last_read, .unread = unread });
}

/// Members who read a message (small groups only).
pub fn readers(r: *Rq, chat: Val, user: Val, message_id: Val) !Val {
    const a = r.a;
    try r.ensure(eq(chat.get("type"), "group") and (chat.get("memberCount").asInt() orelse 0) <= 100, "Read receipts are only listed in small groups", 403, "unavailable");
    const msg = try store.findOne(r, chat, message_id, null);
    try r.ensure(msg != null and val.same(msg.?.get("senderId"), user.get("_id")), "You can only see who read your own messages", 403, "not_author");
    const rows = try col().members.find(a, .{ .chatId = chat.get("_id"), .status = "active", .lastReadSeq = .{ .@"$gte" = msg.?.get("seq") }, .userId = .{ .@"$ne" = user.get("_id") } }, .{ .projection = .{ .userId = 1 }, .limit = 100 });
    var ids: std.ArrayList(Val) = .empty;
    for (rows) |x| try ids.append(a, x.get("userId"));
    const users = try col().users.find(a, .{ ._id = .{ .@"$in" = ids.items }, .@"privacy.readReceipts" = .{ .@"$ne" = false } }, .{ .projection = .{ ._id = 1 } });
    var out = try Val.array(a);
    for (users) |u| try out.push(a, try r.sn(u.get("_id")));
    return out;
}

/// Channel post views: each subscriber counts once per post.
pub fn addViews(r: *Rq, chat: Val, member: Val, up_to_seq: i64) !void {
    const a = r.a;
    if (!eq(chat.get("type"), "channel")) return;
    const from = member.get("viewedSeq").asInt() orelse 0;
    const to = @min(up_to_seq, chat.get("seq").asInt() orelse 0);
    if (to <= from) return;
    const claimed = try col().members.updateOne(a, .{ ._id = member.get("_id"), .@"$or" = .{ .{ .viewedSeq = .{ .@"$lt" = to } }, .{ .viewedSeq = .{ .@"$exists" = false } } } }, .{ .@"$set" = .{ .viewedSeq = to } }, .{});
    if (claimed.modified == 0) return;
    const posts = try store.list(r, chat, .{ .filter = try val.from(a, .{ .kind = "message" }), .after = @max(from, to - 200), .before = to + 1, .asc = true, .limit = 200 });
    var ids: std.ArrayList(Val) = .empty;
    for (posts) |p| try ids.append(a, p.get("_id"));
    try store.updateMany(r, chat, ids.items, try val.from(a, .{ .@"$inc" = .{ .views = 1 } }));
}

// ---- Background jobs: scheduled messages and self-destruct timers -----------------------------

fn publishScheduled(r: *Rq) !void {
    const due = try col().messages.find(r.a, .{ .scheduledAt = .{ .@"$lte" = A.now() } }, .{ .limit = 50 });
    for (due) |msg| publishOne(r, msg) catch |e| std.log.err("Scheduled message failed: {t}", .{e});
}

/// "Send now" on a scheduled message or reminder.
pub fn publishScheduledNow(r: *Rq, chat: Val, user: Val, id: Val) !void {
    const msg = (try col().messages.findOne(r.a, .{ ._id = id, .chatId = chat.get("_id"), .senderId = user.get("_id"), .scheduledAt = .{ .@"$type" = "date" } }, .{})) orelse return r.fail(404, "Scheduled message not found", null);
    try publishOne(r, msg);
}

fn publishOne(r: *Rq, msg: Val) !void {
    const a = r.a;
    // Claim it so two servers (or two ticks) never publish the same message.
    const claimed = try col().messages.updateOne(a, .{ ._id = msg.get("_id"), .scheduledAt = msg.get("scheduledAt") }, .{ .@"$unset" = .{ .scheduledAt = "", .waitFor = "" } }, .{});
    if (claimed.modified == 0) return;
    const chat = try col().chats.findOne(a, .{ ._id = msg.get("chatId") }, .{});
    const member = if (chat) |c| try col().members.findOne(a, .{ .chatId = c.get("_id"), .userId = msg.get("senderId"), .status = "active" }, .{}) else null;
    if (chat == null or member == null) {
        _ = try col().messages.deleteOne(a, .{ ._id = msg.get("_id") });
        return;
    }
    const c = chat.?;
    const cid = try r.str(c.get("_id"));
    const e = msg.path("enc.e").asInt();
    if (c.get("encrypted").truthy() and msg.get("enc").truthy() and e != null and e.? < (c.get("keyEpoch").asInt() orelse 0) - 1) {
        // The key changed while it waited; the sender's device must re-encrypt it.
        _ = try col().messages.deleteOne(a, .{ ._id = msg.get("_id") });
        _ = rt.toUser(a, msg.get("senderId"), "message.delete", try val.from(a, .{ .chatId = cid, .ids = .{try r.str(msg.get("_id"))}, .scheduled = true, .reason = "stale_epoch" }));
        return;
    }
    const seq = try nextSeq(r, c.get("_id"));
    const created = A.now();
    // A note scheduled in a Saved chat is a reminder to yourself.
    const reminder = eq(c.get("type"), "saved");
    const sent = try val.clone(a, msg);
    sent.del("scheduledAt");
    sent.del("waitFor");
    try sent.set(a, "seq", seq);
    try sent.put(a, "createdAt", created);
    if (reminder) try sent.set(a, "reminder", true);
    try stampExpiry(a, sent);
    if (store.isAppChat(c)) {
        // Sent now, so it leaves Reseal for the app's storage. If the app cannot take it, it stays
        // scheduled and is retried.
        store.insert(r, c, sent) catch |err| {
            _ = try col().messages.updateOne(a, .{ ._id = msg.get("_id") }, .{ .@"$set" = .{ .scheduledAt = Val{ .date = A.nowMs() + 60_000 } } }, .{});
            return err;
        };
        _ = try col().messages.deleteOne(a, .{ ._id = msg.get("_id") });
    } else {
        const set = try val.from(a, .{ .seq = seq, .createdAt = created });
        if (reminder) try set.set(a, "reminder", true);
        if (sent.get("expiresAt").truthy()) try set.put(a, "expiresAt", sent.get("expiresAt"));
        _ = try col().messages.updateOne(a, .{ ._id = msg.get("_id") }, .{ .@"$set" = set }, .{});
    }
    _ = rt.toUser(a, msg.get("senderId"), "message.delete", try val.from(a, .{ .chatId = cid, .ids = .{try r.str(msg.get("_id"))}, .scheduled = true, .published = true }));
    const sender = try col().users.findOne(a, .{ ._id = msg.get("senderId") }, .{});
    try afterPublish(r, c, sent, sender, false);
}

/// "Send when online" messages whose recipient just came online are due now.
fn releaseWhenOnline(r: *Rq) !void {
    const a = r.a;
    const waiting = try col().messages.distinct(a, "waitFor", .{ .waitFor = .{ .@"$type" = "objectId" } });
    var online: std.ArrayList(Val) = .empty;
    for (waiting) |id| if (rt.isOnline(id) and !rt.isAway(id)) try online.append(a, id);
    if (online.items.len > 0) _ = try col().messages.updateMany(a, .{ .waitFor = .{ .@"$in" = online.items } }, .{ .@"$set" = .{ .scheduledAt = Val{ .date = 0 } } }, .{});
}

fn expireMessages(r: *Rq) !void {
    const a = r.a;
    const expired = try col().messages.find(a, .{ .expiresAt = .{ .@"$lte" = A.now() } }, .{ .projection = .{ .chatId = 1, .mediaIds = 1, .seq = 1 }, .limit = 200 });
    if (expired.len == 0) return;
    var ids: std.ArrayList(Val) = .empty;
    for (expired) |m| try ids.append(a, m.get("_id"));
    _ = try col().messages.deleteMany(a, .{ ._id = .{ .@"$in" = ids.items } });
    var done: std.ArrayList(usize) = .empty;
    for (expired, 0..) |m, i| {
        if (std.mem.indexOfScalar(usize, done.items, i) != null) continue;
        var list: std.ArrayList(Val) = .empty;
        for (expired, 0..) |m2, j| if (val.same(m2.get("chatId"), m.get("chatId"))) {
            try list.append(a, m2);
            try done.append(a, j);
        };
        if (try col().chats.findOne(a, .{ ._id = m.get("chatId") }, .{})) |chat| try afterExpiry(r, chat, list.items);
    }
}

fn afterExpiry(r: *Rq, chat: Val, list: []const Val) !void {
    const a = r.a;
    var ids: std.ArrayList(Val) = .empty;
    var strs = try Val.array(a);
    var max_seq: i64 = 0;
    for (list) |m| {
        try ids.append(a, m.get("_id"));
        try strs.push(a, try r.sn(m.get("_id")));
        max_seq = @max(max_seq, m.get("seq").asInt() orelse 0);
    }
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$pull" = .{ .pinned = .{ .@"$in" = ids.items } } }, .{});
    try refreshLastMessage(r, chat);
    try recountUnread(r, chat, null, max_seq + 1);
    rt.toChat(a, chat.get("_id"), "message.delete", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .ids = strs, .forEveryone = true, .expired = true }), null);
}

/// Self-destruct timers of messages kept by apps: Reseal tells the app to delete them, then
/// everyone's devices.
fn expireAppMessages(r: *Rq) !void {
    const a = r.a;
    const due = try col().messageTimers.find(a, .{ .expiresAt = .{ .@"$lte" = A.now() } }, .{ .limit = 200 });
    var done: std.ArrayList(usize) = .empty;
    for (due, 0..) |t, i| {
        if (std.mem.indexOfScalar(usize, done.items, i) != null) continue;
        var timers: std.ArrayList(Val) = .empty;
        var ids: std.ArrayList(Val) = .empty;
        var mids: std.ArrayList(Val) = .empty;
        for (due, 0..) |t2, j| if (val.same(t2.get("chatId"), t.get("chatId"))) {
            try timers.append(a, t2);
            try ids.append(a, t2.get("_id"));
            try mids.append(a, t2.get("messageId"));
            try done.append(a, j);
        };
        const chat = (try col().chats.findOne(a, .{ ._id = t.get("chatId"), .deletedAt = .{ .@"$exists" = false } }, .{})) orelse {
            _ = try col().messageTimers.deleteMany(a, .{ ._id = .{ .@"$in" = ids.items } });
            continue;
        };
        store.remove(r, chat, mids.items) catch {
            // The app's storage is down: try again in a minute.
            r.err = null;
            _ = try col().messageTimers.updateMany(a, .{ ._id = .{ .@"$in" = ids.items } }, .{ .@"$set" = .{ .expiresAt = Val{ .date = A.nowMs() + 60_000 } } }, .{});
            continue;
        };
        _ = try col().messageTimers.deleteMany(a, .{ ._id = .{ .@"$in" = ids.items } });
        var list: std.ArrayList(Val) = .empty;
        for (timers.items) |x| try list.append(a, try val.from(a, .{ ._id = x.get("messageId"), .seq = x.get("seq") }));
        try afterExpiry(r, chat, list.items);
    }
}

/// Every 2 seconds: "send when online", scheduled messages, self-destruct timers.
pub fn jobsLoop() void {
    while (true) {
        A.app.io.sleep(.fromSeconds(2), .awake) catch return;
        var arena = std.heap.ArenaAllocator.init(A.app.gpa);
        defer arena.deinit();
        var r: Rq = .{ .a = arena.allocator() };
        releaseWhenOnline(&r) catch |e| std.log.err("Message jobs failed: {t}", .{e});
        publishScheduled(&r) catch |e| std.log.err("Message jobs failed: {t}", .{e});
        expireMessages(&r) catch |e| std.log.err("Message jobs failed: {t}", .{e});
        expireAppMessages(&r) catch |e| std.log.err("Message jobs failed: {t}", .{e});
    }
}
