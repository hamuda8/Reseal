//! Headless tests of the whole app (zui's Driver): boot, key restore, a chat decrypted from
//! crypto.js vectors, sending, the widget's handshake.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const crypto = @import("crypto.zig");

const D = zui.host.Driver(app);
const testing = std.testing;
const host = zui.host;

const vectors_json = @embedFile("testdata/e2ee_vectors.json");

fn vec(a: std.mem.Allocator) j.Value {
    return j.parse(a, vectors_json).?;
}

fn state() *const app.State {
    return D.R.appState();
}

/// Boots signed in as Bob from the vectors (keys restored from an escrow backup made here).
fn bootAsBob(a: std.mem.Allocator) !void {
    const v = vec(a);
    const bob = j.obj(v, "bob").?;
    sys.setClock(sys.parseIso("2026-10-12T15:00:00Z").?, 0);
    // Tests run as the phone apps do: a Wufour token in secure storage.
    zui.storage.set("token", "tok_bob", .{ .secure = true });
    zui.storage.remove(std.fmt.allocPrint(a, "identity:{s}", .{j.str(v, "bobId").?}) catch "", .{ .secure = true });
    zui.storage.remove(std.fmt.allocPrint(a, "identity-public:{s}", .{j.str(v, "bobId").?}) catch "", .{});
    D.start(1280, 800);
    try testing.expect(D.respond("/api/config", 200, "{\"version\":\"test\"}"));
    const me = try std.fmt.allocPrint(a, "{{\"user\":{{\"id\":\"{s}\",\"displayName\":\"Bob Haddad\",\"color\":3,\"hasKeys\":true,\"keyMode\":\"standard\",\"keys\":{{\"enc\":\"{s}\",\"sig\":\"{s}\"}}}}}}", .{ j.str(v, "bobId").?, j.str(bob, "encPublic").?, j.str(bob, "sigPublic").? });
    try testing.expect(D.respond("/api/me", 200, me));
    // The automatic backup: the same keys, sealed with a key the server keeps.
    const id = try crypto.identityFromBundle(a, try j.stringify(a, bob));
    const esc = try crypto.escrowBackup(a, sys.random(), id);
    const restore = try std.fmt.allocPrint(a, "{{\"enc\":\"{s}\",\"sig\":\"{s}\",\"version\":1,\"provisioned\":false,\"escrow\":{s},\"escrowKey\":\"{s}\"}}", .{ j.str(bob, "encPublic").?, j.str(bob, "sigPublic").?, esc.box, esc.key });
    try testing.expect(D.respond("/api/keys/restore", 200, restore));
}

/// Delivers zui.keys answers (they arrive after the update, on zero-delay timers).
fn keyAnswers() void {
    var i: usize = 0;
    while (i < host.timers.items.len) {
        if (host.timers.items[i].ms != 0) {
            i += 1;
            continue;
        }
        const tm = host.timers.orderedRemove(i);
        D.R.timerDone(tm.id);
        i = 0;
    }
}

test "boot: keys restored from the automatic backup, chats load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try bootAsBob(arena.allocator());
    defer D.reset();
    try testing.expectEqual(app.Phase.ready, state().phase);
    try testing.expect(D.pending("/api/chats") != null);
    try testing.expect(std.mem.indexOf(u8, host.socket_url.items, "/ws") != null);
}

test "a crypto.js message decrypts in the chat list and the chat" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try bootAsBob(a);
    defer D.reset();
    const v = vec(a);
    const chat_id = j.str(v, "chatId").?;
    const alice = j.obj(v, "alice").?;
    const msg = j.arr(v, "messages")[0];
    const chats = try std.fmt.allocPrint(a, "{{\"chats\":[{{\"id\":\"{s}\",\"type\":\"private\",\"encrypted\":true,\"keyEpoch\":3,\"peer\":{{\"id\":\"{s}\",\"displayName\":\"Alice Carter\",\"color\":2}},\"me\":{{\"role\":\"member\",\"status\":\"active\",\"unread\":1}},\"lastMessage\":{{\"id\":\"m1\",\"chatId\":\"{s}\",\"seq\":1,\"senderId\":\"{s}\",\"authorId\":\"{s}\",\"kind\":\"message\",\"createdAt\":\"2026-10-12T14:59:00Z\",\"enc\":{s}}}}}]}}", .{
        chat_id, j.str(v, "aliceId").?, chat_id, j.str(v, "aliceId").?, j.str(v, "aliceId").?, try j.stringify(a, j.field(msg, "env").?),
    });
    try testing.expect(D.respond("/api/chats", 200, chats));
    try testing.expect(D.findText("Alice Carter") != 0);
    // The key: wrapped for Bob by Alice; her public keys come from a lookup.
    const w = j.obj(v, "wrap").?;
    const keys = try std.fmt.allocPrint(a, "{{\"keys\":[{{\"epoch\":3,\"by\":\"{s}\",\"eph\":\"{s}\",\"iv\":\"{s}\",\"ct\":\"{s}\",\"sig\":\"{s}\"}}]}}", .{ j.str(v, "aliceId").?, j.str(w, "eph").?, j.str(w, "iv").?, j.str(w, "ct").?, j.str(w, "sig").? });
    try testing.expect(D.respond(try std.fmt.allocPrint(a, "/chats/{s}/keys", .{chat_id}), 200, keys));
    const users = try std.fmt.allocPrint(a, "{{\"users\":[{{\"id\":\"{s}\",\"displayName\":\"Alice Carter\",\"keys\":{{\"enc\":\"{s}\",\"sig\":\"{s}\"}}}}]}}", .{ j.str(v, "aliceId").?, j.str(alice, "encPublic").?, j.str(alice, "sigPublic").? });
    try testing.expect(D.respond("/api/users/lookup", 200, users));
    keyAnswers();
    try testing.expect(D.findText("Hello Bob 👋 — مرحبا") != 0);

    // Open the chat: the message list loads and shows the same message.
    try D.press("Alice Carter");
    const page = try std.fmt.allocPrint(a, "{{\"messages\":[{{\"id\":\"m1\",\"chatId\":\"{s}\",\"seq\":1,\"senderId\":\"{s}\",\"authorId\":\"{s}\",\"kind\":\"message\",\"createdAt\":\"2026-10-12T14:59:00Z\",\"enc\":{s}}}],\"floor\":0}}", .{ chat_id, j.str(v, "aliceId").?, j.str(v, "aliceId").?, try j.stringify(a, j.field(msg, "env").?) });
    try testing.expect(D.respond("/messages", 200, page));
    try testing.expect(D.findText("Hello Bob 👋 — مرحبا") != 0);

    // Reply: encrypted with the chat key, posted, and readable with crypto's own code.
    try D.typeInto("Message", "Hi Alice");
    D.R.dispatch(.send_text);
    // It leaves once zui.keys has signed it.
    keyAnswers();
    var body: []const u8 = "";
    for (host.fetches.items) |f| if (std.mem.endsWith(u8, f.url, "/messages") and std.mem.eql(u8, f.method, "POST")) {
        body = f.body;
    };
    try testing.expect(body.len > 0);
    const sent = j.parse(a, body).?;
    const env = try std.json.parseFromValueLeaky(crypto.Envelope, a, j.field(sent, "enc").?, .{ .ignore_unknown_fields = true });
    const raw = try crypto.fromB64(a, j.str(v, "chatKey").?);
    const d = try crypto.decryptMessage(a, raw[0..32].*, env, chat_id, j.str(v, "bobId").?, j.str(j.obj(v, "bob"), "sigPublic"));
    try testing.expect(d.verified);
    try testing.expectEqualStrings("{\"v\":1,\"t\":\"Hi Alice\"}", d.payload);
}

test "phones: no token shows the sign-in form, which signs in with Wufour" {
    zui.storage.remove("token", .{ .secure = true });
    D.start(400, 800);
    defer D.reset();
    try testing.expectEqual(app.Phase.login, state().phase);
    try D.typeInto("name@example.com", "bob@example.com");
    try D.typeInto("Password", "secret");
    try D.press("Sign in");
    try testing.expect(D.pending("/api/auth/login") != null);
    try testing.expect(D.respond("/api/auth/login", 200, "{\"success\":true,\"token\":\"tok_bob\"}"));
    try testing.expectEqualStrings("tok_bob", host.stored.get("token").?);
    try testing.expect(D.pending("/api/config") != null);
}

test "widget: handshake with the page, token, signed-out without one" {
    D.startWith(400, 700, "/embed?pk=rsl_pk_test");
    defer D.reset();
    try testing.expect(D.pending("/api/embed/config?pk=rsl_pk_test") != null);
    try testing.expect(D.respond("/api/embed/config", 200, "{\"app\":{\"name\":\"Taazur\",\"allowedOrigins\":[\"https://taazur.example\"],\"widget\":{\"locale\":\"en\"},\"features\":{}}}"));
    try testing.expect(std.mem.indexOf(u8, host.posted.items, "\"type\":\"reseal:ready\"") != null);
    try testing.expect(std.mem.indexOf(u8, host.posted.items, "https://taazur.example") != null);
    D.R.hostMessage("{\"type\":\"reseal:init\",\"token\":\"rsl_ut_abc\",\"options\":{}}");
    try testing.expect(D.pending("/api/config") != null);
    var auth = false;
    for (host.fetches.items) |f| if (std.mem.indexOf(u8, f.headers, "Bearer rsl_ut_abc") != null) {
        auth = true;
    };
    try testing.expect(auth);
}

test "new group: pick people, name it, create" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try bootAsBob(arena.allocator());
    defer D.reset();
    try testing.expect(D.respond("/api/chats", 200, "{\"chats\":[]}"));
    D.R.dispatch(.{ .menu = .{ .menu = .{ .kind = .compose } } });
    try D.press("New group");
    try testing.expect(state().modal == null);
    try testing.expect(D.respond("/api/contacts", 200, "{\"contacts\":[{\"id\":\"u3\",\"displayName\":\"Carol Nasser\",\"username\":\"carol\",\"color\":4}]}"));
    try D.press("Carol Nasser");
    try testing.expectEqual(@as(usize, 1), state().picked.items.len);
    try D.press("Next");
    try D.typeInto("Group name", "Launch crew");
    try D.press("Create");
    var body: []const u8 = "";
    for (host.fetches.items) |f| if (std.mem.endsWith(u8, f.url, "/api/chats") and std.mem.eql(u8, f.method, "POST")) {
        body = f.body;
    };
    try testing.expect(std.mem.indexOf(u8, body, "\"members\":[\"u3\"]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"title\":\"Launch crew\"") != null);
}

fn lastPost(suffix: []const u8) []const u8 {
    var body: []const u8 = "";
    for (host.fetches.items) |f| if (std.mem.endsWith(u8, f.url, suffix) and std.mem.eql(u8, f.method, "POST")) {
        body = f.body;
    };
    return body;
}

test "composer: formatting, a quiz, a scheduled message, emoji" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try bootAsBob(arena.allocator());
    defer D.reset();
    try testing.expect(D.respond("/api/chats", 200, "{\"chats\":[{\"id\":\"g1\",\"type\":\"group\",\"title\":\"Launch crew\",\"encrypted\":false,\"me\":{\"role\":\"owner\",\"status\":\"active\",\"unread\":0}}]}"));
    try D.press("Launch crew");
    try testing.expect(D.respond("/messages", 200, "{\"messages\":[],\"floor\":0}"));

    // **bold** and a quote line: text without the marks, entities in UTF-16 units.
    try D.typeInto("Message", "**Hi** all\n> quoted");
    D.R.dispatch(.send_text);
    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();
    const sent = j.parse(a2.allocator(), lastPost("/chats/g1/messages")).?;
    try testing.expectEqualStrings("Hi all\nquoted", j.str(sent, "text").?);
    try testing.expectEqualStrings("bold", j.str(j.arr(sent, "entities")[0], "t").?);
    try testing.expectEqual(@as(i64, 2), j.int(j.arr(sent, "entities")[0], "l").?);
    try testing.expect(D.respond("/chats/g1/messages", 200, "{\"message\":{\"id\":\"m1\",\"chatId\":\"g1\",\"seq\":1,\"senderId\":\"65f1a2b3c4d5e6f708192a02\",\"kind\":\"message\",\"text\":\"Hi all\",\"createdAt\":\"2026-10-12T15:00:00Z\"}}"));

    // A quiz from the attach sheet.
    D.R.dispatch(.attach);
    try D.press("Poll");
    try D.typeInto("Ask a question", "Capital of Jordan?");
    try D.typeInto("Option 1", "Irbid");
    try D.typeInto("Option 2", "Amman");
    try D.press("Quiz mode");
    D.R.dispatch(.{ .compose = .{ .poll_correct = 1 } });
    try D.press("Send");
    const quiz = j.parse(a2.allocator(), lastPost("/chats/g1/messages")).?;
    try testing.expectEqualStrings("Capital of Jordan?", j.str(quiz, "poll.question").?);
    try testing.expect(j.truthy(quiz, "poll.quiz"));
    try testing.expectEqual(@as(i64, 1), j.int(quiz, "poll.correct").?);
    try testing.expect(D.respond("/chats/g1/messages", 200, "{\"message\":{\"id\":\"m2\",\"chatId\":\"g1\",\"seq\":2,\"senderId\":\"65f1a2b3c4d5e6f708192a02\",\"kind\":\"message\",\"text\":\"\",\"createdAt\":\"2026-10-12T15:00:00Z\"}}"));

    // Scheduled for in an hour, from the send options.
    try D.typeInto("Message", "later");
    D.R.dispatch(.{ .compose = .{ .open = .options } });
    try D.press("Schedule message");
    try D.press("In 1 hour");
    const later = j.parse(a2.allocator(), lastPost("/chats/g1/messages")).?;
    try testing.expectEqualStrings("later", j.str(later, "text").?);
    try testing.expectEqual(sys.now() + 3_600_000, j.int(later, "scheduledAt").?);

    // Emoji go into the composer (the picker's tabs are words).
    D.R.dispatch(.{ .compose = .{ .open = .emoji } });
    try testing.expect(D.findText("Smileys & people") != 0);
    D.R.dispatch(.{ .compose = .{ .emoji = .{ .cat = 0, .i = 0 } } });
    try testing.expect(state().fields.get(.composer).get().len > 0);
}

test "multi-select: pick two messages, delete both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try bootAsBob(arena.allocator());
    defer D.reset();
    try testing.expect(D.respond("/api/chats", 200, "{\"chats\":[{\"id\":\"g1\",\"type\":\"group\",\"title\":\"Launch crew\",\"encrypted\":false,\"me\":{\"role\":\"owner\",\"status\":\"active\",\"unread\":0}}]}"));
    try D.press("Launch crew");
    try testing.expect(D.respond("/messages", 200, "{\"messages\":[{\"id\":\"m1\",\"chatId\":\"g1\",\"seq\":1,\"senderId\":\"u9\",\"kind\":\"message\",\"text\":\"first one\",\"createdAt\":\"2026-10-12T14:00:00Z\"},{\"id\":\"m2\",\"chatId\":\"g1\",\"seq\":2,\"senderId\":\"u9\",\"kind\":\"message\",\"text\":\"second one\",\"createdAt\":\"2026-10-12T14:01:00Z\"}],\"floor\":0}"));
    D.R.dispatch(.{ .message_action = .{ .what = .select, .msg = app.Id.of("m1") } });
    try testing.expect(D.findText("1 selected") != 0);
    try D.press("second one");
    try testing.expect(D.findText("2 selected") != 0);
    D.R.dispatch(.select_delete);
    try testing.expect(D.findText("Delete 2 messages?") != 0);
    D.R.dispatch(.confirm);
    const body = lastPost("/chats/g1/messages/delete");
    try testing.expect(std.mem.indexOf(u8, body, "\"ids\":[\"m1\",\"m2\"]") != null);
    try testing.expect(!state().selecting);
}

test "group admin: members, admin rights, permissions, join requests" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try bootAsBob(arena.allocator());
    defer D.reset();
    try testing.expect(D.respond("/api/chats", 200, "{\"chats\":[{\"id\":\"g1\",\"type\":\"group\",\"title\":\"Launch crew\",\"memberCount\":2,\"encrypted\":false,\"me\":{\"role\":\"owner\",\"status\":\"active\",\"unread\":0}}]}"));
    try D.press("Launch crew");
    try testing.expect(D.respond("/messages", 200, "{\"messages\":[],\"floor\":0}"));
    D.R.dispatch(.{ .open_info = app.Id.of("g1") });
    try testing.expect(D.respond("filter=requests", 200, "{\"members\":[{\"userId\":\"u7\",\"status\":\"requested\",\"user\":{\"id\":\"u7\",\"displayName\":\"Dan Saleh\"}}]}"));
    try testing.expect(D.respond("/chats/g1/members?limit=200", 200, "{\"members\":[{\"userId\":\"65f1a2b3c4d5e6f708192a02\",\"role\":\"owner\",\"user\":{\"id\":\"65f1a2b3c4d5e6f708192a02\",\"displayName\":\"Bob Haddad\"}},{\"userId\":\"u3\",\"role\":\"member\",\"user\":{\"id\":\"u3\",\"displayName\":\"Carol Nasser\"}}],\"total\":2}"));
    try testing.expect(D.findText("Group info") != 0);
    try testing.expect(D.findText("1 join request") != 0);
    // Carol: make her an admin without the right to ban.
    try D.press("Manage");
    try D.press("Make admin");
    try D.press("Ban users");
    try D.press("Save");
    const body = lastPost("/chats/g1/members/u3/admin");
    try testing.expect(std.mem.indexOf(u8, body, "\"banUsers\":false") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"changeInfo\":true") != null);
    // Edit: members may no longer add people.
    D.R.dispatch(.{ .group = .{ .page = .edit } });
    try D.press("Add members");
    var patched: []const u8 = "";
    for (host.fetches.items) |f| if (std.mem.endsWith(u8, f.url, "/chats/g1") and std.mem.eql(u8, f.method, "PATCH")) {
        patched = f.body;
    };
    try testing.expectEqualStrings("{\"permissions\":{\"addMembers\":false}}", patched);
    // Join requests: approve Dan.
    D.R.dispatch(.{ .group = .{ .page = .requests } });
    try testing.expect(D.respond("filter=requests", 200, "{\"members\":[{\"userId\":\"u7\",\"status\":\"requested\",\"user\":{\"id\":\"u7\",\"displayName\":\"Dan Saleh\"}}]}"));
    try D.press("Add");
    try testing.expect(std.mem.indexOf(u8, lastPost("/chats/g1/requests/u7"), "\"approve\":true") != null);
}

test "folders: create one with groups and a chat, then filter by it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try bootAsBob(arena.allocator());
    defer D.reset();
    try testing.expect(D.respond("/api/chats", 200, "{\"chats\":[{\"id\":\"g1\",\"type\":\"group\",\"title\":\"Launch crew\",\"me\":{\"role\":\"owner\",\"status\":\"active\",\"unread\":0}},{\"id\":\"p1\",\"type\":\"private\",\"peer\":{\"id\":\"u3\",\"displayName\":\"Carol Nasser\"},\"me\":{\"role\":\"member\",\"status\":\"active\",\"unread\":0}}]}"));
    D.R.dispatch(.{ .folder = .create });
    try D.typeInto("Folder name", "Work");
    // ("Groups" is also a chip of the chat list behind the sheet.)
    D.R.dispatch(.{ .folder = .{ .kind = 2 } });
    D.R.dispatch(.{ .folder = .{ .toggle_chat = app.Id.of("p1") } });
    try D.press("Save");
    const body = lastPost("/api/folders");
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"Work\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"include\":[\"groups\"]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"chatIds\":[\"p1\"]") != null);
    // The list asked at boot, the new folder, then the list again.
    try testing.expect(D.respond("/api/folders", 200, "{\"folders\":[]}"));
    try testing.expect(D.respond("/api/folders", 200, "{\"folder\":{\"id\":\"f1\"}}"));
    try testing.expect(D.respond("/api/folders", 200, "{\"folders\":[{\"id\":\"f1\",\"name\":\"Work\",\"include\":[\"groups\"],\"chatIds\":[\"p1\"],\"excludeChatIds\":[]}]}"));
    try testing.expect(D.findText("Work") != 0);
}

test "chat lock: a locked chat asks for the code before it opens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try bootAsBob(arena.allocator());
    defer D.reset();
    try testing.expect(D.respond("/api/chats", 200, "{\"chats\":[{\"id\":\"g1\",\"type\":\"group\",\"title\":\"Launch crew\",\"lastMessage\":{\"id\":\"m1\",\"chatId\":\"g1\",\"seq\":1,\"senderId\":\"u9\",\"kind\":\"message\",\"text\":\"secret plans\",\"createdAt\":\"2026-10-12T14:00:00Z\"},\"me\":{\"role\":\"owner\",\"status\":\"active\",\"unread\":0,\"locked\":true}}]}"));
    try testing.expect(D.findText("secret plans") == 0);
    try testing.expect(D.findText("Locked chat") != 0);
    try D.press("Launch crew");
    try testing.expect(!state().open_chat.isSet());
    try testing.expect(D.findText("Unlock chat") != 0);
    try D.typeInto("Chat lock code", "4321");
    try D.press("Unlock");
    try testing.expect(std.mem.indexOf(u8, lastPost("/api/me/chat-lock/verify"), "\"code\":\"4321\"") != null);
    try testing.expect(D.respond("/api/me/chat-lock/verify", 200, "{\"ok\":true}"));
    try testing.expect(state().open_chat.eql("g1"));
}

test "export: a plain-text export of a chat, saved as a file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try bootAsBob(arena.allocator());
    defer D.reset();
    try testing.expect(D.respond("/api/chats", 200, "{\"chats\":[{\"id\":\"g1\",\"type\":\"group\",\"title\":\"Launch crew\",\"encrypted\":false,\"me\":{\"role\":\"owner\",\"status\":\"active\",\"unread\":0}}]}"));
    D.R.dispatch(.{ .chat_action = .{ .what = .export_chat, .chat = app.Id.of("g1") } });
    try D.press("Plain text");
    try D.press("Export");
    try testing.expect(D.respond("/chats/g1/messages?limit=100", 200, "{\"messages\":[{\"id\":\"m2\",\"chatId\":\"g1\",\"seq\":2,\"senderId\":\"u9\",\"kind\":\"message\",\"text\":\"second\",\"createdAt\":\"2026-10-12T14:01:00Z\"},{\"id\":\"m1\",\"chatId\":\"g1\",\"seq\":1,\"senderId\":\"u9\",\"kind\":\"message\",\"text\":\"first\",\"createdAt\":\"2026-10-12T14:00:00Z\"}],\"floor\":0}"));
    try testing.expect(std.mem.endsWith(u8, host.saved_name.items, ".txt"));
    const saved = host.saved_data.items;
    const first = std.mem.indexOf(u8, saved, "first") orelse return error.NotSaved;
    const second = std.mem.indexOf(u8, saved, "second") orelse return error.NotSaved;
    try testing.expect(first < second);
    try testing.expect(state().modal == null);
}

test "assistants and the developer console" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try bootAsBob(arena.allocator());
    defer D.reset();
    try testing.expect(D.respond("/api/chats", 200, "{\"chats\":[]}"));
    // A new assistant.
    D.R.dispatch(.{ .bots = .open_list });
    try testing.expect(D.respond("/api/bots/discover", 200, "{\"bots\":[]}"));
    try testing.expect(D.respond("/api/bots", 200, "{\"bots\":[]}"));
    try D.press("Create an assistant");
    try D.typeInto("e.g. Travel Planner", "Trip helper");
    D.R.dispatch(.{ .bots = .temp_up });
    D.R.dispatch(.{ .bots = .save });
    const bot = lastPost("/api/bots");
    try testing.expect(std.mem.indexOf(u8, bot, "\"name\":\"Trip helper\"") != null);
    try testing.expect(std.mem.indexOf(u8, bot, "\"temperature\":0.8") != null);
    // A new app in the console.
    D.R.dispatch(.{ .dev = .open });
    try testing.expect(D.respond("/api/dev/apps", 200, "{\"apps\":[]}"));
    try D.press("Create an app");
    try D.typeInto("e.g. My Store", "Shop");
    D.R.dispatch(.{ .dev = .create_submit });
    try testing.expect(std.mem.indexOf(u8, lastPost("/api/dev/apps"), "\"name\":\"Shop\"") != null);
    try testing.expect(D.respond("/api/dev/apps", 200, "{\"app\":{\"id\":\"a1\",\"name\":\"Shop\",\"secretKey\":\"rsl_sk_test\"}}"));
    try testing.expect(D.findText("Secret key") != 0);
    try testing.expectEqualStrings("rsl_sk_test", state().dev.secret.get());
}

test "voice message: record, upload, send with duration and waveform" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try bootAsBob(arena.allocator());
    defer D.reset();
    try testing.expect(D.respond("/api/chats", 200, "{\"chats\":[{\"id\":\"g1\",\"type\":\"group\",\"title\":\"Launch crew\",\"encrypted\":false,\"me\":{\"role\":\"owner\",\"status\":\"active\",\"unread\":0}}]}"));
    try D.press("Launch crew");
    try testing.expect(D.respond("/messages", 200, "{\"messages\":[],\"floor\":0}"));
    D.R.dispatch(.{ .voice = .record });
    const rec = state().voice.recorder;
    try testing.expect(state().voice.recording);
    for (0..20) |i| D.R.dispatch(.{ .record_event = .{ .kind = .level, .recorder = rec, .level = @as(f32, @floatFromInt(i % 5)) / 5, .duration_ms = @intCast(i * 100) } });
    D.R.dispatch(.{ .record_event = .{ .kind = .done, .recorder = rec, .duration_ms = 2500, .data = "m4a-bytes", .mime = "audio/mp4" } });
    try testing.expect(!state().voice.recording);
    try testing.expect(D.respond("/api/media", 200, "{\"id\":\"md1\",\"chunks\":1,\"chunkSize\":1048576}"));
    try testing.expect(D.respond("/api/media/md1/chunks/0", 200, "{}"));
    try testing.expect(D.respond("/api/media/md1/complete", 200, "{}"));
    const body = lastPost("/chats/g1/messages");
    try testing.expect(std.mem.indexOf(u8, body, "\"kind\":\"voice\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"duration\":2.5") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"waveform\":\"") != null);
}
