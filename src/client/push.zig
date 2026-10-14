//! Push on the phones: once the keys are ready the device registers (zui fx.registerPush: FCM
//! on Android, APNs and PushKit VoIP on iOS) and its tokens go to POST /api/push/subscribe as
//! { token, kind }. The browser keeps its Web Push subscription from the shell.
//!
//! The server pushes an incoming call as an urgent data message ({type:"call", callId,
//! chatId, title, video}); `pushMessage` turns it into `.push = .call`, which the runtime
//! handles before pushMessage returns, so fx.ringCall reaches the phone's call screen at
//! once: Android's ZuiCallService, iOS's CallKit (which PushKit requires before the VoIP push
//! handler returns, or iOS stops delivering VoIP pushes). The app may not be running: zui then
//! started it without a screen. Answering opens the app, and the call is picked up once it
//! is connected (calls.zig answer_pending). A ring nobody answers stops after 45 s.
//! Messages ({type:"message", title, body, chatId}) come as notifications the system shows
//! while the app is away; when one reaches the app while it is hidden it is shown here.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");

pub const Event = union(enum) {
    token: struct { token: []const u8, kind: zui.PushKind },
    message: []const u8,
    /// A pushed call still ringing after its time: stop it.
    ring_over: app.Id,
};

const ring_ms = 45_000;
const message_notify_base: u32 = 0x00C4A700;

pub fn register() void {
    if (zui.platform == .web) return; // the shell subscribes the browser
    app.fx.registerPush(.{});
}

pub fn update(s: *app.State, e: Event) void {
    switch (e) {
        .token => |tk| {
            if (tk.kind == .web) return;
            zui.log("push token ({t}): {s}", .{ tk.kind, tk.token });
            if (s.bearer.get().len == 0) return;
            const body = std.fmt.allocPrint(app.tmp(), "{{\"token\":{s},\"kind\":\"{t}\"}}", .{ j.quote(app.tmp(), tk.token) catch return, tk.kind }) catch return;
            app.api(s, .POST, "/push/subscribe", body, .ignore);
        },
        .message => |text| message(s, text),
        .ring_over => |id| {
            // Answered meanwhile: the call is the app's now.
            if (s.call.status == .active or s.call.status == .connecting) return;
            if (s.call.incoming) |inc| if (inc.call.eql(id.str())) return;
            app.fx.endCall(id.str());
        },
    }
}

fn message(s: *app.State, text: []const u8) void {
    const v = j.parse(app.tmp(), text) orelse return;
    const kind = j.strOr(v, "type", "");
    if (std.mem.eql(u8, kind, "call")) {
        const call_id = j.strOr(v, "callId", "");
        if (call_id.len == 0) return;
        const video = std.mem.eql(u8, j.strOr(v, "video", ""), "1") or std.mem.eql(u8, j.strOr(v, "video", ""), "true");
        app.fx.ringCall(.{ .id = call_id, .name = j.strOr(v, "title", "Reseal"), .video = video, .label = if (video) zui.i18n.t("Video call") else zui.i18n.t("Voice call") });
        app.fx.after(ring_ms, .{ .push = .{ .ring_over = app.Id.of(call_id) } });
        return;
    }
    // On screen the live connection shows messages already.
    if (app.env.visible and s.phase == .ready) return;
    const title = j.strOr(v, "title", "Reseal");
    const body = j.strOr(v, "body", "");
    const chat = j.strOr(v, "chatId", "");
    app.fx.notify(.{ .id = message_notify_base +% @as(u32, @truncate(std.hash.Wyhash.hash(0, chat))) % 0x1000, .title = title, .body = body });
}

pub fn pushToken(token: []const u8, kind: zui.PushKind) ?app.Msg {
    return .{ .push = .{ .token = .{ .token = token, .kind = kind } } };
}

pub fn pushMessage(json: []const u8) ?app.Msg {
    return .{ .push = .{ .message = json } };
}
