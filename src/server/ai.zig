//! AI chat through OpenRouter (src/services/ai.js).
//!
//! A bot is a Reseal user (kind "bot") with a model, a system prompt and an OpenRouter key. It
//! answers in its private chats, in support chats until a human takes over, and in groups when
//! mentioned or replied to. Replies stream to every open tab. Chats with bots are never
//! end-to-end encrypted: the server must read them to answer.

const std = @import("std");
const Io = std.Io;
const A = @import("app.zig");
const v = @import("validate.zig");
const rt = @import("realtime.zig");
const ser = @import("serialize.zig");
const msgs = @import("messages.zig");
const store = @import("store.zig");
const events = @import("events.zig");
const auth = @import("auth.zig");

const moderation = @import("moderation.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

fn col() *A.Cols {
    return &A.app.col;
}

fn eq(x: Val, s: []const u8) bool {
    return x == .str and std.mem.eql(u8, x.str, s);
}

// ---- Replies being written, so they can be stopped -------------------------------------------

const Generating = struct { chat_id: [24]u8, stop: std.atomic.Value(bool) = .init(false) };
var gen_lock: Io.Mutex = .init;
var generating: std.AutoHashMapUnmanaged([24]u8, *Generating) = .empty;

fn key24(v_: Val) [24]u8 {
    var buf: [40]u8 = undefined;
    const k = val.keyOf(v_, &buf) orelse "";
    var out: [24]u8 = @splat('0');
    @memcpy(out[0..@min(24, k.len)], k[0..@min(24, k.len)]);
    return out;
}

// ---- Bot management ---------------------------------------------------------------------------

fn modelPattern(s: []const u8) bool {
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == ':' or c == '/')) return false;
    return true;
}

fn cleanBotFields(r: *Rq, body: Val, partial: bool) !Val {
    const a = r.a;
    const out = try Val.object(a);
    if (!partial or body.get("name") != .undef) if (try v.str(r, body.get("name"), "name", .{ .min = 1, .max = 64, .optional = partial })) |x| try out.set("name", x);
    if (body.get("description") != .undef) try out.set("description", try v.reqStr(r, body.get("description"), "description", .{ .max = 500 }));
    if (!partial or body.get("model") != .undef) if (try v.str(r, body.get("model"), "model", .{ .min = 3, .max = 120, .pattern = modelPattern, .optional = partial })) |x| try out.set("model", x);
    if (body.get("systemPrompt") != .undef) try out.set("systemPrompt", try v.reqStr(r, body.get("systemPrompt"), "systemPrompt", .{ .max = 20000, .trim = false }));
    if (body.get("temperature") != .undef) try out.set("temperature", (try v.num(r, body.get("temperature"), "temperature", .{ .min = 0, .max = 2 })).?);
    if (body.get("maxTokens") != .undef) try out.set("maxTokens", try v.reqInt(r, body.get("maxTokens"), "maxTokens", .{ .min = 16, .max = 32000 }));
    if (body.get("contextMessages") != .undef) try out.set("contextMessages", try v.reqInt(r, body.get("contextMessages"), "contextMessages", .{ .min = 1, .max = 100 }));
    if (body.get("greeting") != .undef) try out.set("greeting", try v.reqStr(r, body.get("greeting"), "greeting", .{ .max = 2000 }));
    inline for (.{ "public", "allowGroups", "vision" }) |k| if (body.get(k) != .undef) try out.set(k, try v.reqBool(r, body.get(k), k));
    if (body.get("starters") != .undef) {
        const st = body.get("starters");
        try r.ensure(st == .arr and st.len() <= 6, "starters must be a list of up to 6 prompts", 400, null);
        var list = try Val.array(a);
        for (st.items()) |x| try list.push(Val{ .str = try v.reqStr(r, x, "starter", .{ .min = 1, .max = 120 }) });
        try out.set("starters", list);
    }
    return out;
}

fn orDefault(x: Val, d: Val) Val {
    return if (x.isNullish()) d else x;
}

pub fn describeBot(r: *Rq, bot: Val, bot_user: Val) !Val {
    const a = r.a;
    return val.from(a, .{
        .id = try r.str(bot.get("_id")),
        .name = bot_user.get("displayName"),
        .username = if (bot_user.get("username").truthy()) bot_user.get("username") else Val.null,
        .avatar = if (bot_user.get("avatar").truthy()) Val{ .str = try r.str(bot_user.get("avatar")) } else Val.null,
        .description = if (bot_user.path("botInfo.description").truthy()) bot_user.path("botInfo.description") else Val.string(""),
        .model = bot.get("model"),
        .systemPrompt = if (bot.get("systemPrompt").truthy()) bot.get("systemPrompt") else Val.string(""),
        .temperature = orDefault(bot.get("temperature"), Val.number(0.7)),
        .maxTokens = orDefault(bot.get("maxTokens"), Val.number(1024)),
        .contextMessages = orDefault(bot.get("contextMessages"), Val.number(20)),
        .greeting = if (bot.get("greeting").truthy()) bot.get("greeting") else Val.string(""),
        .starters = if (bot.get("starters").truthy()) bot.get("starters") else try Val.array(a),
        .public = bot.get("public").truthy(),
        .allowGroups = !(bot.get("allowGroups") == .bool and !bot.get("allowGroups").bool),
        .vision = bot.get("vision").truthy(),
        .hasKey = bot.get("apiKeySealed").truthy() or A.app.config.openrouter_key.len > 0,
        .ownKey = bot.get("apiKeySealed").truthy(),
        .keyHint = if (bot.get("keyHint").truthy()) bot.get("keyHint") else Val.null,
        .appId = if (bot.get("appId").truthy()) Val{ .str = try r.str(bot.get("appId")) } else Val.null,
        .stats = if (bot.get("stats").truthy()) bot.get("stats") else try val.from(a, .{ .replies = 0, .promptTokens = 0, .completionTokens = 0 }),
        .createdAt = bot.get("createdAt"),
    });
}

pub fn createBot(r: *Rq, owner: Val, body: Val, app_id: Val) !Val {
    const a = r.a;
    const f = try cleanBotFields(r, body, false);
    // Content checks (Wufour Moderation): the name, description and greeting are what people see.
    _ = try moderation.check(r, owner, try val.from(a, .{ .type = "bot", .field = "create" }), try val.from(a, .{ .name = f.get("name"), .description = f.get("description"), .greeting = f.get("greeting") }), null);
    const now = A.now();
    const name = f.get("name").str;
    const user_doc = try val.from(a, .{
        .kind = "bot",
        .appId = app_id,
        .displayName = name,
        .displayNameLower = try v.jsLower(a, name),
        .bio = if (f.get("description").truthy()) f.get("description") else Val.string(""),
        .avatar = Val.null,
        .privacy = try auth.defaultPrivacy(a),
        .settings = try Val.object(a),
        .createdAt = now,
        .lastSeenAt = now,
        .botInfo = .{ .ownerId = owner.get("_id"), .description = if (f.get("description").truthy()) f.get("description") else Val.string(""), .model = f.get("model"), .starters = if (f.get("starters").truthy()) f.get("starters") else try Val.array(a) },
    });
    if (body.get("username").truthy()) {
        const un = try v.reqStr(r, body.get("username"), "username", .{ .pattern = v.isUsername });
        try r.ensure(std.ascii.endsWithIgnoreCase(un, "bot"), "Bot usernames must end in \"bot\"", 400, null);
        try user_doc.set("username", un);
        try user_doc.set("usernameLower", try v.jsLower(a, un));
    }
    const id = col().users.insertOne(a, user_doc) catch |e| {
        if (e == error.DuplicateKey) return r.fail(409, "That username is taken", "username_taken");
        return e;
    };
    const api_key: ?[]const u8 = if (body.get("apiKey").truthy()) try v.reqStr(r, body.get("apiKey"), "apiKey", .{ .min = 10, .max = 300 }) else null;
    const bot = try val.from(a, .{
        ._id = id,
        .ownerId = owner.get("_id"),
        .appId = app_id,
        .model = f.get("model"),
        .systemPrompt = if (f.get("systemPrompt").truthy()) f.get("systemPrompt") else Val.string("You are a helpful, friendly assistant. Answer clearly and concisely."),
        .temperature = orDefault(f.get("temperature"), Val.number(0.7)),
        .maxTokens = orDefault(f.get("maxTokens"), Val.number(1024)),
        .contextMessages = orDefault(f.get("contextMessages"), Val.number(20)),
        .greeting = if (f.get("greeting").truthy()) f.get("greeting") else Val.string(""),
        .public = orDefault(f.get("public"), Val.False),
        .allowGroups = orDefault(f.get("allowGroups"), Val.True),
        .vision = orDefault(f.get("vision"), Val.False),
        .starters = if (f.get("starters").truthy()) f.get("starters") else try Val.array(a),
        .apiKeySealed = try A.seal(a, api_key),
        .keyHint = try A.hint(a, api_key),
        .stats = .{ .replies = 0, .promptTokens = 0, .completionTokens = 0 },
        .createdAt = now,
        .updatedAt = now,
    });
    _ = try col().bots.insertOne(a, bot);
    return describeBot(r, bot, user_doc);
}

pub fn updateBot(r: *Rq, bot: Val, body: Val) !Val {
    const a = r.a;
    const f = try cleanBotFields(r, body, true);
    if (f.get("name") != .undef or f.get("description") != .undef or f.get("greeting") != .undef) {
        _ = try moderation.check(r, null, try val.from(a, .{ .type = "bot", .id = try r.str(bot.get("_id")), .field = "update" }), try val.from(a, .{ .name = f.get("name"), .description = f.get("description"), .greeting = f.get("greeting") }), null);
    }
    const bot_set = try val.from(a, .{ .updatedAt = A.now() });
    const user_set = try Val.object(a);
    inline for (.{ "model", "systemPrompt", "temperature", "maxTokens", "contextMessages", "greeting", "public", "allowGroups", "vision", "starters" }) |k| if (f.get(k) != .undef) try bot_set.set(k, f.get(k));
    if (f.get("name").truthy()) {
        try user_set.set("displayName", f.get("name"));
        try user_set.set("displayNameLower", try v.jsLower(a, f.get("name").str));
    }
    if (f.get("description") != .undef) {
        try user_set.set("botInfo.description", f.get("description"));
        try user_set.set("bio", f.get("description"));
    }
    if (f.get("model").truthy()) try user_set.set("botInfo.model", f.get("model"));
    if (f.get("starters").truthy()) try user_set.set("botInfo.starters", f.get("starters"));
    if (body.get("apiKey") != .undef) {
        const api_key: ?[]const u8 = if (body.get("apiKey").truthy()) try v.reqStr(r, body.get("apiKey"), "apiKey", .{ .min = 10, .max = 300 }) else null;
        try bot_set.set("apiKeySealed", try A.seal(a, api_key));
        try bot_set.set("keyHint", try A.hint(a, api_key));
    }
    if (body.get("avatar") != .undef) {
        if (body.get("avatar").truthy()) {
            const m = try col().media.findOne(a, .{ ._id = try v.reqId(r, body.get("avatar"), "avatar"), .ownerId = bot.get("ownerId"), .status = "ready" }, .{});
            try r.ensure(m != null and std.mem.startsWith(u8, m.?.get("mime").asStr() orelse "", "image/"), "Avatar must be an image you uploaded", 400, null);
            _ = try col().media.updateOne(a, .{ ._id = m.?.get("_id") }, .{ .@"$set" = .{ .public = true } }, .{});
            try user_set.set("avatar", m.?.get("_id"));
        } else try user_set.set("avatar", .null);
    }
    if (body.get("username") != .undef and body.get("username").truthy()) {
        const un = try v.reqStr(r, body.get("username"), "username", .{ .pattern = v.isUsername });
        try r.ensure(std.ascii.endsWithIgnoreCase(un, "bot"), "Bot usernames must end in \"bot\"", 400, null);
        try user_set.set("username", un);
        try user_set.set("usernameLower", try v.jsLower(a, un));
    }
    _ = try col().bots.updateOne(a, .{ ._id = bot.get("_id") }, .{ .@"$set" = bot_set }, .{});
    if (user_set.len() > 0) _ = col().users.updateOne(a, .{ ._id = bot.get("_id") }, .{ .@"$set" = user_set }, .{}) catch |e| {
        if (e == error.DuplicateKey) return r.fail(409, "That username is taken", "username_taken");
        return e;
    };
    const fresh = (try col().bots.findOne(a, .{ ._id = bot.get("_id") }, .{})) orelse bot;
    const user = (try col().users.findOne(a, .{ ._id = bot.get("_id") }, .{})) orelse Val.null;
    return describeBot(r, fresh, user);
}

pub fn deleteBot(r: *Rq, bot: Val) !void {
    _ = try col().bots.deleteOne(r.a, .{ ._id = bot.get("_id") });
    _ = try col().users.updateOne(r.a, .{ ._id = bot.get("_id") }, .{ .@"$set" = .{ .deletedAt = A.now(), .displayName = "Deleted bot" }, .@"$unset" = .{ .username = "", .usernameLower = "" } }, .{});
}

// ---- Models list (public OpenRouter endpoint, cached) -----------------------------------------

var models_lock: Io.Mutex = .init;
var models_at: i64 = 0;
var models_json: ?[]u8 = null;

pub fn listModels(r: *Rq) !Val {
    const a = r.a;
    const io = A.app.io;
    {
        models_lock.lockUncancelable(io);
        defer models_lock.unlock(io);
        if (models_json) |j| if (A.nowMs() - models_at < 3600_000) return val.parseJson(a, j);
    }
    const url = try r.fmt("{s}/models", .{A.app.config.openrouter_url});
    var list = try Val.array(a);
    if (A.app.fetch.fetch(a, url, .{ .timeout_ms = 10_000, .follow = true })) |res| {
        const json = val.parseJson(a, res.body) catch Val.null;
        for (json.get("data").items()) |m| {
            const pr = m.get("pricing");
            const prompt = v.toNumber(pr.get("prompt"));
            const completion = v.toNumber(pr.get("completion"));
            var vision = false;
            for (m.path("architecture.input_modalities").items()) |x| if (eq(x, "image")) {
                vision = true;
            };
            try list.push(try val.from(a, .{
                .id = m.get("id"),
                .name = m.get("name"),
                .context = m.get("context_length"),
                .vision = vision,
                .free = pr.truthy() and prompt == 0 and completion == 0,
                .promptPrice = if (pr.truthy()) Val{ .num = prompt * 1e6 } else Val.null,
                .completionPrice = if (pr.truthy()) Val{ .num = completion * 1e6 } else Val.null,
            }));
        }
        std.mem.sort(Val, list.arr.items.items, {}, struct {
            fn lt(_: void, x: Val, y: Val) bool {
                // Close to localeCompare: case is ignored.
                return std.ascii.orderIgnoreCase(x.get("name").asStr() orelse "", y.get("name").asStr() orelse "") == .lt;
            }
        }.lt);
    } else |_| {}
    models_lock.lockUncancelable(io);
    defer models_lock.unlock(io);
    if (list.len() > 0) {
        if (models_json) |j| A.app.gpa.free(j);
        models_json = A.app.gpa.dupe(u8, try val.stringify(a, list)) catch null;
        models_at = A.nowMs();
        return list;
    }
    if (models_json) |j| return val.parseJson(a, j);
    for ([_][]const u8{ "openai/gpt-4o-mini", "anthropic/claude-sonnet-4.5", "google/gemini-2.5-flash", "meta-llama/llama-3.3-70b-instruct" }) |id| {
        try list.push(try val.from(a, .{ .id = id, .name = id, .context = Val.null, .vision = false, .free = false }));
    }
    return list;
}

// ---- Answering --------------------------------------------------------------------------------

fn imagePart(r: *Rq, media_id: Val) !?Val {
    const a = r.a;
    const m = (try col().media.findOne(a, .{ ._id = media_id, .status = "ready", .encrypted = false }, .{})) orelse return null;
    const mime = m.get("mime").asStr() orelse "";
    const ok_mime = std.mem.eql(u8, mime, "image/png") or std.mem.eql(u8, mime, "image/jpeg") or std.mem.eql(u8, mime, "image/webp") or std.mem.eql(u8, mime, "image/gif");
    if (!ok_mime or (m.get("size").asNum() orelse 0) > 5 * 1024 * 1024) return null;
    const chunks = try col().mediaChunks.find(a, .{ .mediaId = media_id }, .{ .sort = .{ .n = 1 } });
    var buf: std.ArrayList(u8) = .empty;
    for (chunks) |c| if (c.get("data") == .bin) try buf.appendSlice(a, c.get("data").bin);
    const enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(buf.items.len));
    _ = std.base64.standard.Encoder.encode(enc, buf.items);
    return try val.from(a, .{ .type = "image_url", .image_url = .{ .url = try r.fmt("data:{s};base64,{s}", .{ mime, enc }) } });
}

fn describeNonText(r: *Rq, m: Val) ![]const u8 {
    const a = r.a;
    var parts: std.ArrayList([]const u8) = .empty;
    for (m.get("media").items()) |x| try parts.append(a, if (x.get("name").truthy()) try r.fmt("[{s}: {s}]", .{ try r.str(x.get("kind")), try r.str(x.get("name")) }) else try r.fmt("[{s}]", .{try r.str(x.get("kind"))}));
    if (m.get("poll").truthy()) {
        var opts: std.ArrayList([]const u8) = .empty;
        for (m.path("poll.options").items()) |o| try opts.append(a, try r.str(o));
        try parts.append(a, try r.fmt("[poll: {s} — {s}]", .{ try r.str(m.path("poll.question")), try std.mem.join(a, " / ", opts.items) }));
    }
    if (m.get("location").truthy()) {
        const l = m.get("location");
        try parts.append(a, try r.fmt("[location: {s}, {s}{s}]", .{ try r.str(l.get("lat")), try r.str(l.get("lng")), if (l.get("title").truthy()) try r.fmt(" ({s})", .{try r.str(l.get("title"))}) else "" }));
    }
    if (m.get("contact").truthy()) try parts.append(a, try r.fmt("[contact: {s}]", .{try r.str(m.path("contact.name"))}));
    if (m.get("sticker").truthy()) try parts.append(a, try r.fmt("[sticker {s}]", .{try r.str(m.path("sticker.emoji"))}));
    return std.mem.join(a, " ", parts.items);
}

fn utcString(a: std.mem.Allocator, ms: i64) ![]const u8 {
    // Date.prototype.toUTCString: "Mon, 12 Oct 2026 01:02:03 GMT"
    const days = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(ms, 1000)) };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ days[@intCast(ed.day % 7)], md.day_index + 1, months[md.month.numeric() - 1], yd.year, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

fn buildContext(r: *Rq, bot: Val, bot_user: Val, chat: Val, upto_seq: i64) !Val {
    const a = r.a;
    const limit = bot.get("contextMessages").asInt() orelse 20;
    const rows = try store.list(r, chat, .{ .filter = try val.from(a, .{ .kind = "message", .deletedAt = .{ .@"$exists" = false }, .@"error" = .{ .@"$exists" = false } }), .before = upto_seq + 1, .limit = limit });
    std.mem.reverse(Val, rows);
    var sender_ids: std.ArrayList(Val) = .empty;
    for (rows) |m| if (v.oid(.{ .str = try r.str(m.get("senderId")) })) |x| try sender_ids.append(a, .{ .id = x });
    const names = try col().users.find(a, .{ ._id = .{ .@"$in" = sender_ids.items } }, .{ .projection = .{ .displayName = 1 } });
    const multi = eq(chat.get("type"), "group") or eq(chat.get("type"), "support");
    var messages = try Val.array(a);
    const system = try std.mem.join(a, "\n", &.{
        if (bot.get("systemPrompt").truthy()) bot.get("systemPrompt").str else "You are a helpful assistant.",
        try r.fmt("\nYou are \"{s}\", chatting inside Reseal, a messaging app. Current time: {s}.", .{ try r.str(bot_user.get("displayName")), try utcString(a, A.nowMs()) }),
    });
    var full: []const u8 = system;
    if (multi) full = try r.fmt("{s}\nThis is a group conversation; user messages start with the sender's name.", .{full});
    full = try r.fmt("{s}\nFormat replies with Markdown when it helps (lists, **bold**, `code`, fenced code blocks).", .{full});
    try messages.push(try val.from(a, .{ .role = "system", .content = full }));
    for (rows) |m| {
        const mine = val.same(m.get("senderId"), bot_user.get("_id"));
        const text_part = if (m.get("text").truthy()) m.get("text").str else "";
        const extra = try describeNonText(r, m);
        var text: []const u8 = if (text_part.len > 0 and extra.len > 0) try r.fmt("{s}\n{s}", .{ text_part, extra }) else if (text_part.len > 0) text_part else extra;
        if (multi and !mine) {
            var name: []const u8 = "Someone";
            for (names) |u| if (val.same(u.get("_id"), m.get("senderId"))) {
                name = try r.str(u.get("displayName"));
            };
            text = try r.fmt("{s}: {s}", .{ name, text });
        }
        var has_photo = false;
        for (m.get("media").items()) |x| if (eq(x.get("kind"), "photo")) {
            has_photo = true;
        };
        if (!mine and bot.get("vision").truthy() and has_photo) {
            var content = try Val.array(a);
            try content.push(try val.from(a, .{ .type = "text", .text = if (text.len > 0) text else "What is in this image?" }));
            var n: usize = 0;
            for (m.get("media").items()) |x| {
                if (!eq(x.get("kind"), "photo") or n >= 4) continue;
                n += 1;
                if (try imagePart(r, x.get("id"))) |p| try content.push(p);
            }
            try messages.push(try val.from(a, .{ .role = "user", .content = content }));
        } else if (text.len > 0) {
            try messages.push(try val.from(a, .{ .role = if (mine) "assistant" else "user", .content = text }));
        }
    }
    return messages;
}

const Stream = struct {
    r: *Rq,
    chat: Val,
    msg_id: Val,
    text: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(u8) = .empty,
    last_flush: i64 = 0,
    last_save: i64 = 0,

    fn delta(s: *Stream, d: []const u8) !void {
        try s.text.appendSlice(s.r.a, d);
        try s.pending.appendSlice(s.r.a, d);
        if (A.nowMs() - s.last_flush >= 60) try s.flush();
    }

    fn flush(s: *Stream) !void {
        s.last_flush = A.nowMs();
        if (s.pending.items.len == 0) return;
        const a = s.r.a;
        rt.toChat(a, s.chat.get("_id"), "message.stream", try val.from(a, .{ .chatId = try s.r.str(s.chat.get("_id")), .id = try s.r.str(s.msg_id), .delta = try a.dupe(u8, s.pending.items), .length = v.utf16Len(s.text.items) }), null);
        s.pending.clearRetainingCapacity();
        // Partial text is saved now and then so a reload mid-reply shows it (not to an app's storage).
        if (A.nowMs() - s.last_save > 1500 and !store.isAppChat(s.chat)) {
            s.last_save = A.nowMs();
            _ = col().messages.updateOne(a, .{ ._id = s.msg_id }, .{ .@"$set" = .{ .text = try a.dupe(u8, s.text.items) } }, .{}) catch {};
        }
    }
};

const CompleteError = error{ AiError, Stopped };

/// Streams a completion from OpenRouter into `s`. Returns the usage report, if any.
fn complete(r: *Rq, api_key: []const u8, bot: Val, messages: Val, g: *Generating, s: *Stream) !Val {
    const a = r.a;
    const body = try val.stringify(a, try val.from(a, .{
        .model = bot.get("model"),
        .messages = messages,
        .temperature = orDefault(bot.get("temperature"), Val.number(0.7)),
        .max_tokens = orDefault(bot.get("maxTokens"), Val.number(1024)),
        .stream = true,
        .usage = .{ .include = true },
    }));
    const url = try r.fmt("{s}/chat/completions", .{A.app.config.openrouter_url});
    var req = try A.app.fetch.http.request(.POST, try std.Uri.parse(url), .{
        .keep_alive = false,
        .headers = .{ .accept_encoding = .omit, .content_type = .{ .override = "application/json" } },
        .extra_headers = &.{
            .{ .name = "Authorization", .value = try r.fmt("Bearer {s}", .{api_key}) },
            .{ .name = "HTTP-Referer", .value = A.app.config.public_url },
            .{ .name = "X-Title", .value = "Reseal" },
        },
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    var w = try req.sendBodyUnflushed(&.{});
    try w.writer.writeAll(body);
    try w.end();
    try req.connection.?.flush();
    var res = try req.receiveHead(&.{});
    var transfer: [256]u8 = undefined;
    const reader = res.reader(&transfer);
    const status: u16 = @backingInt(res.head.status);
    if (status < 200 or status >= 300) {
        const raw: []const u8 = reader.allocRemaining(a, .limited(64 * 1024)) catch "";
        var detail: []const u8 = "";
        if (val.parseJson(a, raw)) |j| {
            detail = j.path("error.message").asStr() orelse v.sliceUtf16(try val.stringify(a, j), 300);
        } else |_| {}
        return r.fail(502, if (detail.len > 0) try r.fmt("The AI service answered {d}: {s}", .{ status, detail }) else try r.fmt("The AI service answered {d}", .{status}), "ai_error");
    }
    var usage: Val = .null;
    var buf: std.ArrayList(u8) = .empty;
    const started = A.nowMs();
    while (true) {
        if (g.stop.load(.acquire)) return error.Stopped;
        if (A.nowMs() - started > 180_000) return r.fail(502, "timeout", "ai_error");
        // Whatever has arrived, as soon as it arrives (a read into a fixed buffer would wait for
        // it to fill, and the reply would show up all at once).
        if (reader.bufferedLen() == 0) reader.fillMore() catch break;
        const got = reader.buffered();
        if (got.len == 0) break;
        try buf.appendSlice(a, got);
        reader.toss(got.len);
        while (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
            const line = std.mem.trim(u8, buf.items[0..nl], " \t\r");
            const rest = try a.dupe(u8, buf.items[nl + 1 ..]);
            defer {
                buf.clearRetainingCapacity();
                buf.appendSlice(a, rest) catch {};
            }
            if (line.len == 0 or line[0] == ':' or !std.mem.startsWith(u8, line, "data:")) continue;
            const data = std.mem.trim(u8, line[5..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) return usage;
            const json = val.parseJson(a, data) catch continue;
            if (json.get("error").truthy()) return r.fail(502, json.path("error.message").asStr() orelse "The AI service failed", "ai_error");
            if (json.get("choices").len() > 0) {
                const d = json.get("choices").items()[0].path("delta.content");
                if (d.asStr()) |t| if (t.len > 0) try s.delta(t);
            }
            if (json.get("usage").truthy()) usage = json.get("usage");
        }
        // Deltas go out with each network read (the 60 ms batching of Reseal-js, without its timer).
        try s.flush();
    }
    return usage;
}

const Job = struct {
    arena: std.heap.ArenaAllocator,
    bot: Val,
    bot_user: Val,
    chat: Val,
    trigger_seq: i64,
    existing: ?Val,
};

fn startGenerate(bot: Val, bot_user: Val, chat: Val, trigger_seq: i64, existing: ?Val) !void {
    const gpa = A.app.gpa;
    const job = try gpa.create(Job);
    job.* = .{ .arena = .init(gpa), .bot = .null, .bot_user = .null, .chat = .null, .trigger_seq = trigger_seq, .existing = null };
    const ja = job.arena.allocator();
    job.bot = try val.deepClone(ja, bot);
    job.bot_user = try val.deepClone(ja, bot_user);
    job.chat = try val.deepClone(ja, chat);
    if (existing) |e| job.existing = try val.deepClone(ja, e);
    A.spawn(runGenerate, .{job});
}

fn runGenerate(job: *Job) void {
    defer {
        job.arena.deinit();
        A.app.gpa.destroy(job);
    }
    var r: Rq = .{ .a = job.arena.allocator() };
    generate(&r, job.bot, job.bot_user, job.chat, job.trigger_seq, job.existing) catch |e| std.log.err("AI reply failed: {t}", .{e});
}

fn generate(r: *Rq, bot: Val, bot_user: Val, chat: Val, trigger_seq: i64, existing: ?Val) !void {
    const a = r.a;
    const api_key = A.unseal(a, bot.get("apiKeySealed")) orelse A.app.config.openrouter_key;
    const cid = try r.str(chat.get("_id"));
    rt.toChat(a, chat.get("_id"), "typing", try val.from(a, .{ .chatId = cid, .userId = try r.str(bot_user.get("_id")), .action = "typing" }), null);
    const messages = try buildContext(r, bot, bot_user, chat, trigger_seq);

    var msg: Val = undefined;
    if (existing) |e| {
        _ = try store.update(r, chat, e.get("_id"), try val.from(a, .{ .@"$set" = .{ .text = "", .streaming = true }, .@"$unset" = .{ .@"error" = "", .entities = "" } }));
        msg = try val.clone(a, e);
        try msg.set("text", "");
        try msg.set("streaming", true);
        msg.del("error");
        rt.toChatEach(a, chat.get("_id"), "message.edit", MsgCtx{ .doc = msg, .chat = chat }, messageFor);
    } else {
        msg = try msgs.publishRaw(r, chat, bot_user, try val.from(a, .{ .text = "", .streaming = true, .bot = .{ .model = bot.get("model"), .markdown = true } }), true);
    }
    const g = try A.app.gpa.create(Generating);
    g.* = .{ .chat_id = key24(chat.get("_id")) };
    const mkey = key24(msg.get("_id"));
    {
        gen_lock.lockUncancelable(A.app.io);
        defer gen_lock.unlock(A.app.io);
        try generating.put(A.app.gpa, mkey, g);
    }
    var s: Stream = .{ .r = r, .chat = chat, .msg_id = msg.get("_id") };
    var err_text: ?[]const u8 = null;
    var usage: Val = .null;
    var stopped = false;
    if (api_key.len == 0) {
        err_text = "This bot has no OpenRouter API key yet. Its owner can add one in the bot settings.";
    } else if (complete(r, api_key, bot, messages, g, &s)) |u| {
        usage = u;
    } else |e| switch (e) {
        error.Stopped => stopped = true, // stopped by the user
        error.Http => err_text = if (r.err) |he| he.message else "The AI service failed",
        else => err_text = "fetch failed",
    }
    r.err = null;
    s.flush() catch {};
    {
        gen_lock.lockUncancelable(A.app.io);
        defer gen_lock.unlock(A.app.io);
        _ = generating.remove(mkey);
    }
    A.app.gpa.destroy(g);

    const text = s.text.items;
    const set = try Val.object(a);
    try set.set("text", if (text.len > 0) text else if (err_text != null) "" else "…");
    if (err_text) |e| {
        try set.set("error", v.sliceUtf16(e, 500));
        if (text.len == 0) try set.set("text", try r.fmt("⚠️ {s}", .{e}));
    }
    if (stopped) {
        const b = try val.clone(a, if (msg.get("bot").truthy()) msg.get("bot") else try Val.object(a));
        try b.set("stopped", true);
        try b.set("model", bot.get("model"));
        try b.set("markdown", true);
        try set.set("bot", b);
    }
    try set.set("search", v.sliceUtf16(try v.jsLower(a, set.get("text").str), 4000));
    const final = (try store.update(r, chat, msg.get("_id"), try val.from(a, .{ .@"$set" = set, .@"$unset" = .{ .streaming = "" } }))) orelse blk: {
        const f = try val.clone(a, msg);
        for (set.keys(), set.vals()) |kv_k, kv_v| try f.set(kv_k, kv_v);
        f.del("streaming");
        break :blk f;
    };
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id"), .@"lastMessage.id" = msg.get("_id") }, .{ .@"$set" = .{ .lastMessage = try msgs.lastMessageSummary(r, final, chat) } }, .{});
    rt.toChatEach(a, chat.get("_id"), "message.edit", MsgCtx{ .doc = final, .chat = chat }, messageFor);
    _ = try col().bots.updateOne(a, .{ ._id = bot.get("_id") }, .{ .@"$inc" = .{ .@"stats.replies" = 1, .@"stats.promptTokens" = usage.get("prompt_tokens").asInt() orelse 0, .@"stats.completionTokens" = usage.get("completion_tokens").asInt() orelse 0 } }, .{});
    if (existing == null) {
        try events.emit(a, .message_created, try val.from(a, .{ .chat = chat, .message = final, .sender = bot_user }));
    } else try events.emit(a, .message_edited, try val.from(a, .{ .chat = chat, .message = final, .editor = bot_user }));
}

const MsgCtx = struct { doc: Val, chat: Val };

fn messageFor(c: MsgCtx, a: std.mem.Allocator, uid: []const u8) anyerror!?Val {
    return try ser.message(a, c.doc, .{ .str = uid }, c.chat);
}

fn botsToAnswer(r: *Rq, chat: Val, message: Val, sender: Val) ![]Val {
    const a = r.a;
    if (chat.get("encrypted").truthy() or !eq(message.get("kind"), "message") or !sender.truthy() or eq(sender.get("kind"), "bot")) return &.{};
    const t = chat.get("type").asStr() orelse "";
    var out: std.ArrayList(Val) = .empty;
    if (std.mem.eql(u8, t, "bot")) {
        if (chat.get("botId").truthy()) try out.append(a, chat.get("botId"));
        return out.items;
    }
    if (std.mem.eql(u8, t, "support")) {
        if (chat.get("botId").truthy() and !chat.get("handoff").truthy()) try out.append(a, chat.get("botId"));
        return out.items;
    }
    if (!std.mem.eql(u8, t, "group")) return &.{};
    // In groups, bots answer when mentioned (@name or a mention entity) or replied to.
    const members = try col().members.find(a, .{ .chatId = chat.get("_id"), .status = "active" }, .{ .projection = .{ .userId = 1 } });
    var ids: std.ArrayList(Val) = .empty;
    for (members) |m| try ids.append(a, m.get("userId"));
    const bots = try col().users.find(a, .{ ._id = .{ .@"$in" = ids.items }, .kind = "bot" }, .{ .projection = .{ .username = 1 } });
    if (bots.len == 0) return &.{};
    const replied = if (message.path("replyTo.id").truthy()) try store.findOne(r, chat, message.path("replyTo.id"), null) else null;
    const text = try v.jsLower(a, message.get("text").asStr() orelse "");
    for (bots) |b| {
        var hit = false;
        for (message.get("mentions").items()) |m| if (val.same(m, b.get("_id"))) {
            hit = true;
        };
        if (b.get("username").asStr()) |un| if (std.mem.indexOf(u8, text, try r.fmt("@{s}", .{try v.jsLower(a, un)})) != null) {
            hit = true;
        };
        if (replied) |rp| if (val.same(rp.get("senderId"), b.get("_id"))) {
            hit = true;
        };
        if (hit) try out.append(a, b.get("_id"));
    }
    return out.items;
}

pub fn onEvent(r: *Rq, kind: events.Kind, p: Val) !void {
    const a = r.a;
    switch (kind) {
        .message_created => {
            const chat = p.get("chat");
            const message = p.get("message");
            const sender = p.get("sender");
            for (try botsToAnswer(r, chat, message, sender)) |bot_id| {
                const bot = (try col().bots.findOne(a, .{ ._id = bot_id }, .{})) orelse continue;
                const bot_user = (try col().users.findOne(a, .{ ._id = bot_id }, .{})) orelse continue;
                if (bot_user.get("deletedAt").truthy()) continue;
                if (eq(chat.get("type"), "group") and bot.get("allowGroups") == .bool and !bot.get("allowGroups").bool) continue;
                if (!A.allow(try r.fmt("ai:{s}", .{try r.str(sender.get("_id"))}), 30, 60_000)) {
                    _ = try msgs.publishRaw(r, chat, bot_user, try val.from(a, .{ .text = "⚠️ You are sending messages too quickly. Please wait a moment.", .@"error" = "rate_limited" }), false);
                    continue;
                }
                try startGenerate(bot, bot_user, chat, message.get("seq").asInt() orelse 0, null);
            }
            // Support chats: once a human agent writes, the bot steps back.
            if (eq(chat.get("type"), "support") and !chat.get("handoff").truthy() and sender.truthy() and !eq(sender.get("kind"), "bot") and eq(message.get("kind"), "message") and !val.same(sender.get("_id"), chat.get("visitorId"))) {
                _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = .{ .handoff = true, .handoffAt = A.now(), .agentId = sender.get("_id") } }, .{});
            }
        },
        .bot_chat_started => {
            const bot = try col().bots.findOne(a, .{ ._id = p.get("botUserId") }, .{});
            const bot_user = try col().users.findOne(a, .{ ._id = p.get("botUserId") }, .{});
            if (bot != null and bot_user != null and bot.?.get("greeting").truthy()) {
                _ = try msgs.publishRaw(r, p.get("chat"), bot_user.?, try val.from(a, .{ .text = bot.?.get("greeting"), .bot = .{ .markdown = true, .greeting = true } }), false);
            }
        },
        else => {},
    }
}

pub fn stop(message_id: Val, chat_id: Val) bool {
    gen_lock.lockUncancelable(A.app.io);
    defer gen_lock.unlock(A.app.io);
    const g = generating.get(key24(message_id)) orelse return false;
    if (!std.mem.eql(u8, &g.chat_id, &key24(chat_id))) return false;
    g.stop.store(true, .release);
    return true;
}

pub fn regenerate(r: *Rq, chat: Val, message_id: Val, requester: Val) !void {
    const a = r.a;
    const msg = (try store.findOne(r, chat, message_id, try val.from(a, .{ .deletedAt = .{ .@"$exists" = false } }))) orelse return r.fail(400, "Only AI replies can be regenerated", null);
    try r.ensure(msg.get("bot").truthy(), "Only AI replies can be regenerated", 400, null);
    {
        gen_lock.lockUncancelable(A.app.io);
        defer gen_lock.unlock(A.app.io);
        try r.ensure(!generating.contains(key24(msg.get("_id"))), "This reply is still being written", 409, null);
    }
    const newer = try store.list(r, chat, .{ .filter = try val.from(a, .{ .kind = "message", .deletedAt = .{ .@"$exists" = false } }), .after = msg.get("seq").asInt() orelse 0, .asc = true, .limit = 1 });
    try r.ensure(newer.len == 0, "Only the latest reply can be regenerated", 409, null);
    const bot = try col().bots.findOne(a, .{ ._id = msg.get("senderId") }, .{});
    const bot_user = try col().users.findOne(a, .{ ._id = msg.get("senderId") }, .{});
    try r.ensure(bot != null and bot_user != null, "This bot no longer exists", 404, null);
    try r.ensure(A.allow(try r.fmt("ai:{s}", .{try r.str(requester.get("_id"))}), 30, 60_000), "Too many requests. Wait a moment.", 429, null);
    try startGenerate(bot.?, bot_user.?, chat, (msg.get("seq").asInt() orelse 1) - 1, msg);
}

/// Hands a support chat to the human team.
pub fn requestHuman(r: *Rq, chat: Val, user: Val) !void {
    const a = r.a;
    try r.ensure(eq(chat.get("type"), "support"), "Only support chats can be handed to a person", 400, null);
    _ = try col().chats.updateOne(a, .{ ._id = chat.get("_id") }, .{ .@"$set" = .{ .handoff = true, .handoffAt = A.now() } }, .{});
    const agents = try col().members.find(a, .{ .chatId = chat.get("_id"), .status = "active", .role = "admin" }, .{ .projection = .{ .userId = 1 } });
    var ids: std.ArrayList(Val) = .empty;
    for (agents) |x| try ids.append(a, x.get("userId"));
    const humans = try col().users.find(a, .{ ._id = .{ .@"$in" = ids.items }, .kind = .{ .@"$ne" = "bot" } }, .{ .projection = .{ ._id = 1 } });
    var hids: std.ArrayList(Val) = .empty;
    for (humans) |h| try hids.append(a, h.get("_id"));
    rt.toUsers(a, hids.items, "support.handoff", try val.from(a, .{ .chatId = try r.str(chat.get("_id")), .visitorId = try r.str(user.get("_id")) }));
    try events.emit(a, .support_handoff, try val.from(a, .{ .chat = chat, .user = user }));
}
