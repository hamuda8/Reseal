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
    try testing.expect(D.findText("Hello Bob 👋 — مرحبا") != 0);

    // Open the chat: the message list loads and shows the same message.
    try D.press("Alice Carter");
    const page = try std.fmt.allocPrint(a, "{{\"messages\":[{{\"id\":\"m1\",\"chatId\":\"{s}\",\"seq\":1,\"senderId\":\"{s}\",\"authorId\":\"{s}\",\"kind\":\"message\",\"createdAt\":\"2026-10-12T14:59:00Z\",\"enc\":{s}}}],\"floor\":0}}", .{ chat_id, j.str(v, "aliceId").?, j.str(v, "aliceId").?, try j.stringify(a, j.field(msg, "env").?) });
    try testing.expect(D.respond("/messages", 200, page));
    try testing.expect(D.findText("Hello Bob 👋 — مرحبا") != 0);

    // Reply: encrypted with the chat key, posted, and readable with crypto's own code.
    try D.typeInto("Message", "Hi Alice");
    D.R.dispatch(.send_text);
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
