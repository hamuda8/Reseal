//! Voice and video calls: one-to-one and group (mesh). Port of Reseal-js ui/calls.js: the same
//! signalling over /ws (call.start / accept / join / signal / media / hangup ...), with every
//! offer and answer signed by the sender's identity key ("reseal/call/v1|call|from|to|type|sdp")
//! and checked against the key we know for them, so a server in the middle cannot swap them.
//!
//! The media (microphone, camera, the connection) is zui's: fx.openMedia, fx.openPeer and
//! ui.video. On the web that is the browser's RTCPeerConnection, so calls work with Reseal-js
//! clients; on Android and iOS zui answers "unsupported" until its engine (reseal-rtc) is in,
//! and the call screen says so.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");
const fmt = @import("fmt.zig");

const State = app.State;
const Id = app.Id;
const Text = app.Text;
const gpa = app.gpa;
const t = zui.i18n.t;
const tmp = app.tmp;

const emoji_list = [_][]const u8{ "🐶", "🐱", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔", "🐧", "🦉", "🦄", "🐝", "🦋", "🐢", "🐙", "🐬", "🐳", "🌵", "🌻", "🍀", "🍄", "🌙", "⭐", "🔥", "🌈", "❄️", "🌊", "🍎", "🍋", "🍉", "🍇", "🍓", "🥑", "🥕", "🍕", "🍩", "🎂", "☕", "⚽", "🏀", "🎸", "🎲", "🚀", "✈️", "🚲", "⛵", "🏠", "⏰", "💡", "🔑", "🎁", "📚", "✏️", "🎈", "🔔", "🎧", "🧩", "🪐", "🌍" };

pub const Status = enum { idle, ringing, connecting, active, ended, unavailable };

pub const PeerMedia = struct { audio: bool = true, video: bool = false, screen: bool = false };

pub const Peer = struct {
    conn: Id,
    user: Id,
    peer: u32 = 0,
    remote: u32 = 0,
    remote_video: bool = false,
    connected: bool = false,
    /// Was connected, then the connection dropped ("Reconnecting…").
    lost: bool = false,
    verified: ?bool = null,
    media: PeerMedia = .{},
    hand: bool = false,
    local_fp: [96]u8 = undefined,
    local_fp_len: u8 = 0,
    remote_fp: [96]u8 = undefined,
    remote_fp_len: u8 = 0,
};

pub const Incoming = struct { call: Id, chat: Id, from: Id, name: Text = .{}, avatar: Id = .{}, video: bool = false };

/// What to do once the microphone (and camera) are on.
const After = enum { none, start, accept, join };

pub const CallState = struct {
    status: Status = .idle,
    id: Id = .{},
    chat: Id = .{},
    video: bool = false,
    group: bool = false,
    outgoing: bool = false,
    after: After = .none,
    local: u32 = 0,
    camera_stream: u32 = 0,
    screen: u32 = 0,
    muted: bool = false,
    camera_on: bool = false,
    screen_on: bool = false,
    hand: bool = false,
    started_at: i64 = 0,
    minimized: bool = false,
    ice: Text = .{},
    peers: std.ArrayList(Peer) = .empty,
    incoming: ?Incoming = null,
    reason: Text = .{},
    emoji: Text = .{},
    unverified: bool = false,
    seq: u32 = 0,
    /// Answered on the system call screen before the call reached the app.
    answer_pending: Id = .{},
    system_started: bool = false,
};

/// Socket requests waiting for their ack.
pub const SocketReq = union(enum) { start: u32, accept: u32, join: u32, group_start: struct { seq: u32, video: bool } };

pub const Action = union(enum) {
    start: struct { chat: Id, video: bool },
    join: Id,
    accept: bool,
    decline,
    hangup,
    mute,
    camera,
    screen,
    switch_camera,
    minimize,
    hand,
    dismiss: u32,
    open_chat,
};

const notify_id: u32 = 0x00CA11;

fn onMedia(e: zui.MediaEvent) app.Msg {
    return .{ .media = e };
}

fn onPeer(e: zui.PeerEvent) app.Msg {
    return .{ .peer = e };
}

pub fn act(s: *State, a: Action) void {
    const c = &s.call;
    switch (a) {
        .start => |x| start(s, x.chat.str(), x.video),
        .join => |chat| joinGroup(s, chat.str(), null, false),
        .accept => |video| accept(s, video),
        .decline => {
            const inc = c.incoming orelse return;
            app.wsSend(s, "call.decline", std.fmt.allocPrint(tmp(), "{{\"callId\":\"{s}\"}}", .{inc.call.str()}) catch return);
            closeIncoming(s);
        },
        .hangup => {
            if (c.id.isSet()) app.wsSend(s, "call.hangup", std.fmt.allocPrint(tmp(), "{{\"callId\":\"{s}\"}}", .{c.id.str()}) catch "{}");
            end(s, t("Call ended"));
        },
        .mute => {
            c.muted = !c.muted;
            if (c.local != 0) app.fx.mediaEnable(c.local, !c.muted, c.camera_on);
            sendMedia(s);
        },
        .camera => toggleCamera(s),
        .screen => toggleScreen(s),
        .switch_camera => if (c.local != 0) app.fx.switchCamera(c.local),
        .minimize => c.minimized = !c.minimized,
        .hand => {
            // Group calls: a raised hand shows on my tile for everyone (call.reaction).
            if (!c.id.isSet()) return;
            c.hand = !c.hand;
            app.wsSend(s, "call.reaction", std.fmt.allocPrint(tmp(), "{{\"callId\":\"{s}\",\"emoji\":\"\\u270b\",\"hand\":{}}}", .{ c.id.str(), c.hand }) catch return);
        },
        .dismiss => |seq| if (seq == c.seq and c.status == .ended or c.status == .unavailable and seq == c.seq) reset(s),
        .open_chat => {
            c.minimized = true;
            s.open_chat = c.chat;
        },
    }
}

fn reset(s: *State) void {
    const c = &s.call;
    const inc = c.incoming;
    c.peers.clearRetainingCapacity();
    c.* = .{ .peers = c.peers, .ice = c.ice, .reason = c.reason, .emoji = c.emoji, .seq = c.seq, .incoming = inc };
    c.ice.clear();
    c.emoji.clear();
}

pub fn inCall(s: *const State) bool {
    return s.call.status != .idle and s.call.status != .ended and s.call.status != .unavailable;
}

fn myConn(s: *const State) []const u8 {
    return s.ws.conn_id.get();
}

// ---------------------------------------------------------------------------------------------
// Starting, answering, joining

fn start(s: *State, chat_id: []const u8, video: bool) void {
    if (inCall(s)) return app.toast(s, t("You are already in a call."));
    const ch = s.store.chat(chat_id) orelse return;
    if (ch.is("group") or ch.is("channel") or ch.is("support")) {
        s.call.seq += 1;
        if (!app.wsRequest(s, "call.start", std.fmt.allocPrint(tmp(), "{{\"chatId\":\"{s}\",\"video\":{}}}", .{ chat_id, video }) catch return, .{ .group_start = .{ .seq = s.call.seq, .video = video } }))
            app.toastError(s, t("You are offline."));
        s.call.chat = Id.of(chat_id);
        return;
    }
    begin(s, chat_id, video, false, true);
    s.call.status = .ringing;
    s.call.after = .start;
    openMedia(s);
}

fn begin(s: *State, chat_id: []const u8, video: bool, group: bool, outgoing: bool) void {
    reset(s);
    const c = &s.call;
    c.seq += 1;
    c.chat = Id.of(chat_id);
    c.video = video;
    c.camera_on = video;
    c.group = group;
    c.outgoing = outgoing;
    c.status = .connecting;
    c.reason.clear();
}

fn openMedia(s: *State) void {
    s.call.local = app.fx.openMedia(.{ .audio = true, .video = s.call.video }, onMedia);
}

pub fn joinGroup(s: *State, chat_id: []const u8, call_id: ?[]const u8, video: bool) void {
    if (inCall(s)) return app.toast(s, t("You are already in a call."));
    const ch = s.store.chat(chat_id) orelse return;
    const id = call_id orelse j.str(ch.o.v, "call.id") orelse return start(s, chat_id, video);
    begin(s, chat_id, video, true, false);
    s.call.id = Id.of(id);
    s.call.after = .join;
    openMedia(s);
}

fn accept(s: *State, video: bool) void {
    const inc = s.call.incoming orelse return;
    const chat = inc.chat;
    const call_id = inc.call;
    // The system call screen stays: it becomes the ongoing call.
    s.call.incoming = null;
    app.fx.cancelNotify(notify_id);
    begin(s, chat.str(), video, false, false);
    s.call.id = call_id;
    s.call.after = .accept;
    sync_ensure(s, chat.str());
    openMedia(s);
}

fn sync_ensure(s: *State, chat: []const u8) void {
    @import("sync.zig").ensureChat(s, chat);
}

/// Media events: the microphone and camera are on (or not).
pub fn onMediaEvent(s: *State, e: zui.MediaEvent) void {
    const c = &s.call;
    if (e.stream == c.camera_stream and c.camera_stream != 0) return onCameraStream(s, e);
    if (e.stream == c.screen and c.screen != 0) return onScreenStream(s, e);
    if (e.stream != c.local) return;
    switch (e.kind) {
        .ready => {
            const after = c.after;
            c.after = .none;
            switch (after) {
                .start => _ = app.wsRequest(s, "call.start", std.fmt.allocPrint(tmp(), "{{\"chatId\":\"{s}\",\"video\":{}}}", .{ c.chat.str(), c.video }) catch return, .{ .start = c.seq }) or offline(s),
                .accept => _ = app.wsRequest(s, "call.accept", std.fmt.allocPrint(tmp(), "{{\"callId\":\"{s}\",\"video\":{}}}", .{ c.id.str(), c.video }) catch return, .{ .accept = c.seq }) or offline(s),
                .join => _ = app.wsRequest(s, "call.join", std.fmt.allocPrint(tmp(), "{{\"callId\":\"{s}\",\"audio\":true,\"video\":{}}}", .{ c.id.str(), c.video }) catch return, .{ .join = c.seq }) or offline(s),
                .none => {},
            }
        },
        .failed => {
            if (std.mem.eql(u8, e.data, "unsupported")) {
                // This device cannot do calls yet: say so, and decline an incoming one politely.
                if (c.after == .accept) app.wsSend(s, "call.decline", std.fmt.allocPrint(tmp(), "{{\"callId\":\"{s}\"}}", .{c.id.str()}) catch "{}");
                c.after = .none;
                c.local = 0;
                c.status = .unavailable;
                c.reason.set(t("Calls are not available on this device yet."));
                return;
            }
            if (c.video) {
                // No camera (or permission): fall back to voice.
                c.video = false;
                c.camera_on = false;
                openMedia(s);
                return;
            }
            c.local = 0;
            if (c.after == .accept and c.id.isSet()) app.wsSend(s, "call.decline", std.fmt.allocPrint(tmp(), "{{\"callId\":\"{s}\"}}", .{c.id.str()}) catch "{}");
            c.after = .none;
            app.toastError(s, t("Allow microphone access to make calls."));
            end(s, t("Call ended"));
        },
        .ended => {},
    }
}

fn offline(s: *State) bool {
    app.toastError(s, t("You are offline."));
    end(s, t("Call ended"));
    return false;
}

/// Acks of call.start / call.accept / call.join.
pub fn onAck(s: *State, req: SocketReq, ok: bool, result: ?j.Value, err: []const u8) void {
    const c = &s.call;
    switch (req) {
        .group_start => |x| {
            if (!ok) return app.toastError(s, err);
            if (x.seq != c.seq) return;
            const chat = c.chat;
            joinGroup(s, chat.str(), j.str(result, "callId"), x.video);
        },
        .start, .accept, .join => |seq| {
            if (seq != c.seq or c.status == .ended) return;
            if (!ok) {
                app.toastError(s, if (err.len > 0) err else t("Call ended"));
                return end(s, t("Call ended"));
            }
            c.ice.set(j.stringify(tmp(), j.field(result, "iceServers") orelse j.Value{ .array = std.json.Array.init(tmp()) }) catch "[]");
            switch (req) {
                .start => {
                    c.id = Id.of(j.strOr(result, "callId", ""));
                    if (j.truthy(result, "busy")) {
                        app.toast(s, fmt.tf("{name} is on another call.", .{ .name = title(s) }));
                        return end(s, t("Line busy"));
                    }
                    c.status = .ringing;
                    app.fx.startCall(.{ .id = c.id.str(), .name = title(s), .video = c.video });
                },
                .accept => for (j.arr(result, "peers")) |p| addPeer(s, p, false),
                .join => {
                    c.status = .active;
                    c.started_at = sys.now();
                    for (j.arr(result, "peers")) |p| addPeer(s, p, true);
                },
                else => {},
            }
        },
    }
}

fn addPeer(s: *State, info: j.Value, initiator: bool) void {
    _ = initiator;
    const c = &s.call;
    const conn = j.strOr(info, "connId", "");
    if (conn.len == 0 or findPeer(s, conn) != null) return;
    const polite = std.mem.order(u8, myConn(s), conn) == .gt;
    var p: Peer = .{ .conn = Id.of(conn), .user = Id.of(j.strOr(info, "userId", "")) };
    if (j.obj(info, "media")) |m| p.media = .{ .audio = j.truthy(m, "audio"), .video = j.truthy(m, "video"), .screen = j.truthy(m, "screen") };
    keys.want(s, p.user.str());
    const stream = if (c.screen_on and c.screen != 0) c.screen else c.local;
    p.peer = app.fx.openPeer(.{ .ice_servers = c.ice.get(), .polite = polite, .stream = stream }, onPeer);
    c.peers.append(gpa, p) catch {};
}

fn findPeer(s: *State, conn: []const u8) ?*Peer {
    for (s.call.peers.items) |*p| if (p.conn.eql(conn)) return p;
    return null;
}

fn peerById(s: *State, id: u32) ?*Peer {
    for (s.call.peers.items) |*p| if (p.peer == id) return p;
    return null;
}

fn removePeer(s: *State, conn: []const u8) void {
    for (s.call.peers.items, 0..) |p, i| if (p.conn.eql(conn)) {
        app.fx.closePeer(p.peer);
        _ = s.call.peers.orderedRemove(i);
        return;
    };
}

/// What a peer connection reports: signals to relay, its state, the other side's stream.
pub fn onPeerEvent(s: *State, e: zui.PeerEvent) void {
    const c = &s.call;
    const p = peerById(s, e.peer) orelse return;
    switch (e.kind) {
        .signal => {
            const v = j.parse(tmp(), e.data) orelse return;
            const a = tmp();
            var d: []const u8 = "";
            if (j.obj(v, "description")) |desc| {
                const typ = j.strOr(desc, "type", "");
                const sdp = j.strOr(desc, "sdp", "");
                setFp(&p.local_fp, &p.local_fp_len, sdp);
                const signed = std.fmt.allocPrint(a, "reseal/call/v1|{s}|{s}|{s}|{s}|{s}", .{ c.id.str(), myConn(s), p.conn.str(), typ, sdp }) catch return;
                const sig = keys.signText(s, signed);
                d = std.fmt.allocPrint(a, "{{\"description\":{{\"type\":{s},\"sdp\":{s}}},\"sig\":{s}}}", .{ j.quote(a, typ) catch return, j.quote(a, sdp) catch return, if (sig) |x| j.quote(a, x) catch "null" else "null" }) catch return;
                updateFingerprint(s);
            } else if (j.field(v, "candidate")) |cand| {
                d = std.fmt.allocPrint(a, "{{\"candidate\":{s}}}", .{j.stringify(a, cand) catch return}) catch return;
            } else return;
            keys.wsSendSigned(s, "call.signal", std.fmt.allocPrint(a, "{{\"callId\":\"{s}\",\"to\":\"{s}\",\"data\":{s}}}", .{ c.id.str(), p.conn.str(), d }) catch return);
        },
        .state => {
            if (std.mem.eql(u8, e.data, "connected")) {
                p.connected = true;
                p.lost = false;
                if (c.status != .active) {
                    app.fx.callConnected(c.id.str());
                    c.status = .active;
                    // The web's clock comes every 20 s until the call asks for it every second:
                    // start counting at the first fresh one.
                    if (c.started_at == 0 and zui.platform != .web) c.started_at = sys.now();
                }
            } else if (std.mem.eql(u8, e.data, "failed") or std.mem.eql(u8, e.data, "disconnected")) {
                if (p.connected) p.lost = true;
                p.connected = false;
            }
        },
        .track => {
            p.remote = e.stream;
            p.remote_video = true;
        },
    }
}

fn setFp(buf: *[96]u8, len: *u8, sdp: []const u8) void {
    const key = "a=fingerprint:";
    const i = std.mem.indexOf(u8, sdp, key) orelse return;
    const rest = sdp[i + key.len ..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
    const fp_start = rest[sp + 1 ..];
    const end_i = std.mem.indexOfAny(u8, fp_start, "\r\n ") orelse fp_start.len;
    const fp = fp_start[0..@min(end_i, buf.len)];
    @memcpy(buf[0..fp.len], fp);
    len.* = @intCast(fp.len);
}

/// Both sides show the same emoji derived from the two DTLS fingerprints (1:1 calls).
fn updateFingerprint(s: *State) void {
    const c = &s.call;
    if (c.group or c.peers.items.len == 0) return;
    const p = &c.peers.items[0];
    if (p.local_fp_len == 0 or p.remote_fp_len == 0) return;
    const l = p.local_fp[0..p.local_fp_len];
    const r = p.remote_fp[0..p.remote_fp_len];
    const first_l = std.mem.order(u8, l, r) != .gt;
    const pair = std.fmt.allocPrint(tmp(), "{s}|{s}", .{ if (first_l) l else r, if (first_l) r else l }) catch return;
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pair, &d, .{});
    var out: std.ArrayList(u8) = .empty;
    for (d[0..4]) |b| out.appendSlice(tmp(), emoji_list[b % emoji_list.len]) catch {};
    c.emoji.set(out.items);
}

fn sendMedia(s: *State) void {
    const c = &s.call;
    if (!c.id.isSet()) return;
    app.wsSend(s, "call.media", std.fmt.allocPrint(tmp(), "{{\"callId\":\"{s}\",\"audio\":{},\"video\":{},\"screen\":{}}}", .{ c.id.str(), !c.muted, c.camera_on or c.screen_on, c.screen_on }) catch return);
}

fn toggleCamera(s: *State) void {
    const c = &s.call;
    if (c.local == 0) return;
    if (c.camera_on) {
        c.camera_on = false;
        app.fx.mediaEnable(c.local, !c.muted, false);
        sendMedia(s);
        return;
    }
    if (c.video) {
        c.camera_on = true;
        app.fx.mediaEnable(c.local, !c.muted, true);
        sendMedia(s);
        return;
    }
    // A voice call: open the camera (with the microphone) and send that instead.
    c.camera_stream = app.fx.openMedia(.{ .audio = true, .video = true }, onMedia);
}

fn onCameraStream(s: *State, e: zui.MediaEvent) void {
    const c = &s.call;
    switch (e.kind) {
        .ready => {
            const old = c.local;
            c.local = c.camera_stream;
            c.camera_stream = 0;
            c.video = true;
            c.camera_on = true;
            app.fx.mediaEnable(c.local, !c.muted, true);
            if (!c.screen_on) for (c.peers.items) |p| app.fx.peerStream(p.peer, c.local);
            if (old != 0) app.fx.closeMedia(old);
            sendMedia(s);
        },
        .failed => {
            c.camera_stream = 0;
            app.toastError(s, t("Could not turn on the camera."));
        },
        .ended => {},
    }
}

fn toggleScreen(s: *State) void {
    const c = &s.call;
    if (c.screen_on) return stopScreen(s);
    c.screen = app.fx.openMedia(.{ .audio = false, .screen = true }, onMedia);
}

fn onScreenStream(s: *State, e: zui.MediaEvent) void {
    const c = &s.call;
    switch (e.kind) {
        .ready => {
            c.screen_on = true;
            for (c.peers.items) |p| app.fx.peerStream(p.peer, c.screen);
            sendMedia(s);
        },
        .failed => c.screen = 0,
        .ended => stopScreen(s),
    }
}

fn stopScreen(s: *State) void {
    const c = &s.call;
    if (c.screen != 0) app.fx.closeMedia(c.screen);
    c.screen = 0;
    c.screen_on = false;
    for (c.peers.items) |p| app.fx.peerStream(p.peer, c.local);
    sendMedia(s);
}

pub fn end(s: *State, reason: []const u8) void {
    const c = &s.call;
    if (c.status == .idle or c.status == .ended) return;
    for (c.peers.items) |p| app.fx.closePeer(p.peer);
    c.peers.clearRetainingCapacity();
    if (c.local != 0) app.fx.closeMedia(c.local);
    if (c.screen != 0) app.fx.closeMedia(c.screen);
    if (c.camera_stream != 0) app.fx.closeMedia(c.camera_stream);
    c.local = 0;
    c.screen = 0;
    c.camera_stream = 0;
    c.status = .ended;
    c.reason.set(reason);
    app.fx.cancelNotify(notify_id);
    if (c.id.isSet()) app.fx.endCall(c.id.str());
    app.fx.after(900, .{ .call = .{ .dismiss = c.seq } });
}

pub fn title(s: *const State) []const u8 {
    const ch = s.store.chat(s.call.chat.str()) orelse return "";
    return s.store.title(ch);
}

pub fn statusText(s: *const State) []const u8 {
    const c = &s.call;
    return switch (c.status) {
        .ringing => if (c.outgoing) t("Ringing…") else t("Connecting…"),
        .connecting => t("Connecting…"),
        .ended, .unavailable => c.reason.get(),
        .active => if (!c.group and c.peers.items.len > 0 and c.peers.items[0].lost) t("Reconnecting…") else activeText(c),
        .idle => "",
    };
}

fn activeText(c: anytype) []const u8 {
    return switch (c.status) {
        .active => if (c.group) fmt.tn(tmp(), @intCast(c.peers.items.len + 1), "{n} participant", "{n} participants") else if (c.started_at > 0) fmt.duration(tmp(), @as(f64, @floatFromInt(sys.now() - c.started_at)) / 1000) else fmt.duration(tmp(), 0),
        else => "",
    };
}

// ---------------------------------------------------------------------------------------------
// Incoming calls and socket events

fn closeIncoming(s: *State) void {
    if (s.call.incoming) |inc| app.fx.endCall(inc.call.str());
    s.call.incoming = null;
    app.fx.cancelNotify(notify_id);
}

pub fn onEvent(s: *State, typ: []const u8, d: j.Value) void {
    const c = &s.call;
    const eq = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    const call_id = j.strOr(d, "callId", "");
    if (eq(typ, "call.incoming")) {
        if (inCall(s) or c.incoming != null) {
            app.wsSend(s, "call.decline", std.fmt.allocPrint(tmp(), "{{\"callId\":\"{s}\",\"busy\":true}}", .{call_id}) catch return);
            return;
        }
        var inc: Incoming = .{ .call = Id.of(call_id), .chat = Id.of(j.strOr(d, "chatId", "")), .from = Id.of(j.strOr(d, "from.id", "")), .video = j.truthy(d, "video") };
        inc.name.set(j.strOr(d, "from.displayName", ""));
        inc.avatar = Id.of(j.strOr(d, "from.avatar", ""));
        c.incoming = inc;
        // The phone's own incoming-call screen (also over the lock screen); the web draws its own.
        app.fx.ringCall(.{ .id = call_id, .name = j.strOr(d, "from.displayName", "Reseal"), .video = inc.video });
        if (c.answer_pending.eql(call_id)) {
            c.answer_pending = .{};
            accept(s, inc.video);
            return;
        }
        // Rings over the lock screen on phones; stays until answered on the web.
        app.fx.notify(.{ .id = notify_id, .title = j.strOr(d, "from.displayName", "Reseal"), .body = if (inc.video) t("Incoming video call") else t("Incoming voice call"), .urgent = true });
        return;
    }
    if (eq(typ, "call.taken")) {
        if (c.incoming) |inc| if (inc.call.eql(call_id)) closeIncoming(s);
        return;
    }
    if (eq(typ, "call.ended")) {
        if (c.incoming) |inc| if (inc.call.eql(call_id)) closeIncoming(s);
        if (c.id.eql(call_id) and inCall(s)) {
            const st = j.strOr(d, "status", "");
            const reason = if (eq(st, "declined")) t("Call declined") else if (eq(st, "missed")) t("No answer") else if (eq(st, "busy")) t("Line busy") else t("Call ended");
            if (!eq(st, "ended")) app.toast(s, reason);
            end(s, reason);
        }
        return;
    }
    if (eq(typ, "call.group")) {
        const ch = s.store.chat(j.strOr(d, "chatId", "")) orelse return;
        if (j.truthy(d, "ended")) {
            ch.o.set("call", .null) catch {};
        } else {
            const v = std.fmt.allocPrint(tmp(), "{{\"id\":\"{s}\",\"video\":{},\"count\":{d}}}", .{ call_id, j.truthy(d, "video"), j.intOr(d, "count", 0) }) catch return;
            ch.o.set("call", j.parse(tmp(), v) orelse return) catch {};
        }
        return;
    }
    if (!inCall(s) or !c.id.eql(call_id)) return;
    if (eq(typ, "call.accepted")) {
        c.status = .connecting;
        addPeer(s, d, true);
    } else if (eq(typ, "call.participant_joined")) {
        addPeer(s, d, false);
    } else if (eq(typ, "call.participant_left")) {
        removePeer(s, j.strOr(d, "connId", ""));
    } else if (eq(typ, "call.media")) {
        if (findPeer(s, j.strOr(d, "connId", ""))) |p| if (j.obj(d, "media")) |m| {
            p.media = .{ .audio = j.truthy(m, "audio"), .video = j.truthy(m, "video"), .screen = j.truthy(m, "screen") };
        };
    } else if (eq(typ, "call.reaction")) {
        if (findPeer(s, j.strOr(d, "connId", ""))) |p| if (eq(j.strOr(d, "emoji", ""), "✋")) {
            p.hand = j.truthy(d, "hand");
        };
    } else if (eq(typ, "call.signal")) {
        onSignal(s, d);
    }
}

fn onSignal(s: *State, d: j.Value) void {
    const from = j.strOr(d, "from", "");
    const from_user = j.strOr(d, "fromUser", "");
    const p = findPeer(s, from) orelse blk: {
        addPeer(s, d, false);
        // addPeer reads connId/userId; a signal names them from/fromUser.
        if (findPeer(s, from) == null) {
            const info = std.fmt.allocPrint(tmp(), "{{\"connId\":\"{s}\",\"userId\":\"{s}\"}}", .{ from, from_user }) catch return;
            addPeer(s, j.parse(tmp(), info) orelse return, false);
        }
        break :blk findPeer(s, from) orelse return;
    };
    const sd = j.obj(d, "data") orelse return;
    const a = tmp();
    if (j.obj(sd, "description")) |desc| {
        const typ = j.strOr(desc, "type", "");
        const sdp = j.strOr(desc, "sdp", "");
        // Check the signature against the key we know for this person.
        if (keys.senderSig(s, from_user) != null) {
            const signed = std.fmt.allocPrint(a, "reseal/call/v1|{s}|{s}|{s}|{s}|{s}", .{ s.call.id.str(), from, myConn(s), typ, sdp }) catch return;
            const ok = if (j.str(sd, "sig")) |sig| keys.verifyFrom(s, from_user, sig, signed) else false;
            p.verified = ok;
            if (!ok) {
                s.call.unverified = true;
                app.toastError(s, t("This call could not be verified. It may not be secure."));
            }
        }
        setFp(&p.remote_fp, &p.remote_fp_len, sdp);
        app.fx.peerSignal(p.peer, std.fmt.allocPrint(a, "{{\"description\":{{\"type\":{s},\"sdp\":{s}}}}}", .{ j.quote(a, typ) catch return, j.quote(a, sdp) catch return }) catch return);
        updateFingerprint(s);
    } else if (j.field(sd, "candidate")) |cand| {
        app.fx.peerSignal(p.peer, std.fmt.allocPrint(a, "{{\"candidate\":{s}}}", .{j.stringify(a, cand) catch return}) catch return);
    }
}

/// The web shell's messages about calls (none needed today; zui carries the media).
pub fn onRtc(_: *State, _: j.Value) void {}

/// What the person did on the phone's call screen.
pub fn onSystem(s: *State, kind: zui.CallEvent.Kind, id: Id) void {
    const c = &s.call;
    switch (kind) {
        .answer => {
            if (c.incoming) |inc| {
                if (inc.call.eql(id.str())) return accept(s, inc.video);
            }
            // Opened by answering before the call reached the app: accept it when it does.
            c.answer_pending = id;
        },
        .decline => if (c.incoming) |inc| {
            if (inc.call.eql(id.str())) act(s, .decline);
        },
        .end => if (c.id.eql(id.str()) and inCall(s)) act(s, .hangup) else if (c.incoming) |inc| {
            if (inc.call.eql(id.str())) act(s, .decline);
        },
    }
}

/// A fresh clock arrived (web): the call's timer starts with it.
pub fn onClock(s: *State) void {
    if (s.call.status == .active and s.call.started_at == 0) s.call.started_at = sys.now();
}
