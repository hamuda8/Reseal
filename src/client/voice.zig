//! Voice messages and round video messages (Reseal-js composer.js recorder, message.js
//! voiceBubble/roundVideo, ui/player.js), and playing them, and videos, with zui's recording and
//! playback API.
//!
//! The composer's send button is a microphone (or a camera, for round videos) while there is no
//! text; a long press switches between the two, as the web app's button does. Recording shows a
//! timer, the live level and Cancel; Send sends. A voice message carries its duration and a
//! 48-bar waveform (0-31, base64), as media.js waveformOf makes; round videos are 384x384.
//! Recordings are AAC in M4A and MP4 (WebM on some browsers); the web app records WebM/Opus,
//! which browsers and Android play.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const media = @import("media.zig");
const send = @import("send.zig");
const icons = @import("icons.zig");
const fmt = @import("fmt.zig");
const kit = @import("ui.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const Color = zui.Color;
const t = zui.i18n.t;
const tmp = app.tmp;
const gpa = app.gpa;
const key = kit.key;

pub const Mode = enum { voice, round };

pub const Act = union(enum) {
    record,
    toggle_mode,
    finish,
    cancel,
    /// Play or pause a message's media item.
    play: struct { msg: Id, index: u8 },
    stop,
};

pub const Voice = struct {
    mode: Mode = .voice,
    mode_loaded: bool = false,
    recorder: u32 = 0,
    recording: bool = false,
    cancelled: bool = false,
    elapsed_ms: u32 = 0,
    level: f32 = 0,
    levels: std.ArrayList(f32) = .empty,
    last_typing: i64 = 0,
    /// What plays now (one at a time).
    player: u32 = 0,
    playing_msg: Id = .{},
    playing_index: u8 = 0,
    paused: bool = false,
    position_ms: u32 = 0,
    duration_ms: u32 = 0,
    /// Waiting for the file to download before it can play.
    waiting: bool = false,
};

fn onRecord(e: zui.RecordEvent) Msg {
    return .{ .record_event = e };
}

fn onPlay(e: zui.PlayEvent) Msg {
    return .{ .play_event = e };
}

pub fn mode(s: *State) Mode {
    if (!s.voice.mode_loaded) {
        s.voice.mode_loaded = true;
        if (zui.storage.get(tmp(), "recordMode", .{})) |m| {
            if (std.mem.eql(u8, m, "round")) s.voice.mode = .round;
        }
    }
    return s.voice.mode;
}

pub fn act(s: *State, a: Act) void {
    const v = &s.voice;
    switch (a) {
        .record => {
            if (v.recording or !s.open_chat.isSet()) return;
            const round = mode(s) == .round;
            v.recording = true;
            v.cancelled = false;
            v.elapsed_ms = 0;
            v.level = 0;
            v.levels.clearRetainingCapacity();
            stopPlaying(s);
            v.recorder = app.fx.startRecording(.{ .video = round, .max_ms = if (round) 60_000 else 3_600_000 }, onRecord);
        },
        .toggle_mode => {
            v.mode = if (mode(s) == .voice) .round else .voice;
            zui.storage.set("recordMode", @tagName(v.mode), .{});
            app.toast(s, if (v.mode == .round) t("Video messages: tap to record a round video") else t("Voice messages: tap to record"));
        },
        .finish => if (v.recording) app.fx.stopRecording(v.recorder),
        .cancel => if (v.recording) {
            v.cancelled = true;
            app.fx.cancelRecording(v.recorder);
            endRecording(s);
        },
        .play => |x| togglePlay(s, x.msg.str(), x.index),
        .stop => stopPlaying(s),
    }
}

fn endRecording(s: *State) void {
    const v = &s.voice;
    v.recording = false;
    v.recorder = 0;
    if (s.open_chat.isSet()) app.wsSend(s, "typing", std.fmt.allocPrint(tmp(), "{{\"chatId\":\"{s}\",\"action\":\"cancel\"}}", .{s.open_chat.str()}) catch return);
}

pub fn onRecordEvent(s: *State, e: zui.RecordEvent) void {
    const v = &s.voice;
    if (e.recorder != v.recorder or v.recorder == 0) return;
    switch (e.kind) {
        .started => {},
        .level => {
            v.level = e.level;
            v.elapsed_ms = e.duration_ms;
            v.levels.append(gpa, e.level) catch {};
            // "recording a voice message…" for the others, every 3 s.
            const now = sys.now();
            if (now - v.last_typing > 3000 and s.open_chat.isSet()) {
                v.last_typing = now;
                app.wsSend(s, "typing", std.fmt.allocPrint(tmp(), "{{\"chatId\":\"{s}\",\"action\":\"{s}\"}}", .{ s.open_chat.str(), if (v.mode == .round) "recording_video" else "recording_voice" }) catch return);
            }
        },
        .failed => {
            endRecording(s);
            app.toastError(s, if (std.mem.eql(u8, e.data, "denied")) t("Allow microphone access to record.") else if (std.mem.eql(u8, e.data, "unsupported")) t("Recording is not available on this device yet.") else t("Could not record."));
        },
        .done => {
            const round = v.mode == .round;
            const secs = @as(f64, @floatFromInt(@max(e.duration_ms, v.elapsed_ms))) / 1000;
            endRecording(s);
            if (v.cancelled or secs < 0.7 or e.data.len == 0) return;
            const bytes = gpa.dupe(u8, e.data) catch return;
            const mime = if (e.mime.len > 0) e.mime else if (round) "video/mp4" else "audio/mp4";
            send.attachRecording(s, bytes, .{
                .name = if (round) "video-message" else "voice-message",
                .mime = mime,
                .kind = if (round) "round" else "voice",
                .duration = secs,
                .waveform = if (round) null else waveform(tmp(), v.levels.items),
                .w = if (round) 384 else null,
                .h = if (round) 384 else null,
                .encrypted = false,
            });
        },
    }
}

/// 48 peaks (0-31) of the levels heard while recording, packed into base64 (media.js waveformOf).
pub fn waveform(a: std.mem.Allocator, levels: []const f32) ?[]const u8 {
    if (levels.len == 0) return null;
    const n_bars = 48;
    var peaks: [n_bars]f32 = @splat(0);
    for (levels, 0..) |l, i| {
        const b = @min(n_bars - 1, i * n_bars / levels.len);
        peaks[b] = @max(peaks[b], l);
    }
    var top: f32 = 0;
    for (peaks) |p| top = @max(top, p);
    var out: [n_bars]u8 = undefined;
    for (peaks, &out) |p, *o| o.* = if (top > 0) @intFromFloat(@round(p / top * 31)) else 0;
    const enc = std.base64.standard.Encoder;
    const buf = a.alloc(u8, enc.calcSize(n_bars)) catch return null;
    return enc.encode(buf, &out);
}

/// The waveform's bars (0-31), or a flat line.
fn bars(a: std.mem.Allocator, b64: ?[]const u8) []const u8 {
    const flat = a.alloc(u8, 48) catch return &.{};
    @memset(flat, 4);
    const w = b64 orelse return flat;
    const dec = std.base64.standard.Decoder;
    const out = a.alloc(u8, dec.calcSizeForSlice(w) catch return flat) catch return flat;
    dec.decode(out, w) catch return flat;
    return if (out.len > 0) out else flat;
}

// ---------------------------------------------------------------------------------------------
// Playback

fn itemOf(s: *State, msg_id: []const u8, index: u8) ?j.Value {
    const tl = s.store.existingTimeline(s.open_chat.str()) orelse return null;
    const m = tl.find(msg_id) orelse return null;
    const items = m.media();
    return if (index < items.len) items[index] else null;
}

fn togglePlay(s: *State, msg_id: []const u8, index: u8) void {
    const v = &s.voice;
    if (v.player != 0 and v.playing_msg.eql(msg_id) and v.playing_index == index) {
        v.paused = !v.paused;
        if (v.paused) app.fx.pausePlayback(v.player) else app.fx.resumePlayback(v.player);
        return;
    }
    stopPlaying(s);
    v.playing_msg = Id.of(msg_id);
    v.playing_index = index;
    v.position_ms = 0;
    v.duration_ms = 0;
    v.paused = false;
    v.waiting = true;
    const item = itemOf(s, msg_id, index) orelse return;
    _ = media.file(s, item, false);
    tryStart(s);
}

/// Starts the waiting item once its file is here (called again as downloads finish).
pub fn tryStart(s: *State) void {
    const v = &s.voice;
    if (!v.waiting) return;
    const item = itemOf(s, v.playing_msg.str(), v.playing_index) orelse return;
    const f = media.shown(s, item) orelse return;
    switch (f.state) {
        .loading => return,
        .failed => {
            v.waiting = false;
            return app.toastError(s, t("Could not play this."));
        },
        .ready => {},
    }
    v.waiting = false;
    const kind = j.strOr(item, "kind", "");
    const video = std.mem.eql(u8, kind, "round") or std.mem.eql(u8, kind, "video");
    const mime = j.strOr(item, "mime", if (video) "video/mp4" else "audio/mp4");
    if (f.bytes.len > 0) {
        v.player = app.fx.play(.{ .data = f.bytes, .mime = mime, .video = video }, onPlay);
    } else {
        const url = if (std.mem.startsWith(u8, f.url, "/")) std.fmt.allocPrint(tmp(), "{s}{s}", .{ app.server, f.url }) catch return else f.url;
        v.player = app.fx.play(.{ .url = url, .mime = mime, .video = video }, onPlay);
    }
}

pub fn stopPlaying(s: *State) void {
    const v = &s.voice;
    if (v.player != 0) app.fx.stopPlayback(v.player);
    v.player = 0;
    v.playing_msg = .{};
    v.waiting = false;
}

pub fn onPlayEvent(s: *State, e: zui.PlayEvent) void {
    const v = &s.voice;
    if (e.player != v.player) return;
    switch (e.kind) {
        .ready, .progress => {
            v.position_ms = e.position_ms;
            if (e.duration_ms > 0) v.duration_ms = e.duration_ms;
        },
        .ended => {
            const ended = v.playing_msg;
            stopPlaying(s);
            playNextVoice(s, ended.str());
        },
        .failed => {
            stopPlaying(s);
            app.toastError(s, t("Could not play this."));
        },
    }
}

/// After a voice message, the next one in the chat plays (player.js next).
fn playNextVoice(s: *State, after: []const u8) void {
    const tl = s.store.existingTimeline(s.open_chat.str()) orelse return;
    var found = false;
    for (tl.items.items) |m| {
        if (found) {
            for (m.media(), 0..) |it, i| if (std.mem.eql(u8, j.strOr(it, "kind", ""), "voice")) {
                return togglePlay(s, m.id(), @intCast(i));
            };
            return;
        }
        if (std.mem.eql(u8, m.id(), after)) found = true;
    }
}

// ---------------------------------------------------------------------------------------------
// Views

fn msg(a: Act) Msg {
    return .{ .voice = a };
}

/// While recording, the composer shows this instead of the input.
pub fn recordingBar(cx: Cx) void {
    const ui = cx.ui;
    const v = cx.s.voice;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .min_height = 50, .padding = .xy(14, 3), .grow = 1, .width = .fill }, .{ .key = zui.key("recording") });
    ui.begin(.{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .radius = 5, .background = cx.c.danger }, .{});
    ui.end();
    ui.text(fmt.duration(cx.a(), @as(f64, @floatFromInt(v.elapsed_ms)) / 1000), .{ .font_size = 15, .weight = 650, .color = cx.c.text, .min_width = 44 });
    // The last levels, as bars.
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 2, .grow = 1, .width = .fill, .height = .{ .px = 28 }, .clip = true, .justify = .end }, .{});
    const n = v.levels.items.len;
    const from = if (n > 60) n - 60 else 0;
    for (v.levels.items[from..], from..) |l, i| {
        ui.begin(.{ .width = .{ .px = 3 }, .height = .{ .px = @max(3, l * 28) }, .radius = 1.5, .background = cx.c.accent }, .{ .key = key(.{ "lv", i }) });
        ui.end();
    }
    ui.end();
    kit.button(cx, t("Cancel"), msg(.cancel), .{ .small = true, .kind = .ghost });
    ui.end();
}

/// The round camera preview above the composer while recording a video message.
pub fn roundPreview(cx: Cx) void {
    const v = cx.s.voice;
    if (!v.recording or v.mode != .round or v.recorder == 0) return;
    const ui = cx.ui;
    ui.begin(.{ .position = .absolute, .inset = .{ .bottom = 90 }, .width = .fill, .align_items = .center }, .{});
    ui.begin(.{ .width = .{ .px = 220 }, .height = .{ .px = 220 }, .radius = 110, .clip = true, .background = Color.black, .border_width = 3, .border_color = cx.c.danger }, .{});
    ui.video(v.recorder, .{ .mirror = true, .cover = true }, .{ .width = .fill, .height = .fill }, key(.{"round-preview"}));
    ui.end();
    ui.end();
}

pub fn micIcon(s: *const State) zui.Icon {
    return if (s.voice.mode == .round) icons.video else icons.mic;
}

/// A voice message in a bubble: play/pause, the waveform (played part highlighted), the time.
pub fn voiceBubble(cx: Cx, m: *const data.Message, item: j.Value, index: u8, fg: Color, accent: Color) void {
    const ui = cx.ui;
    const v = cx.s.voice;
    const a = cx.a();
    const mine = v.playing_msg.eql(m.id()) and v.playing_index == index and m.local_id == 0;
    const playing = mine and v.player != 0 and !v.paused;
    const total_ms: f64 = if (mine and v.duration_ms > 0) @floatFromInt(v.duration_ms) else j.floatOr(item, "duration", 0) * 1000;
    const frac: f32 = if (mine and total_ms > 0) @floatCast(@as(f64, @floatFromInt(v.position_ms)) / total_ms) else 0;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .min_width = 230, .padding = .xy(0, 3) }, .{});
    const press: ?Msg = if (m.local_id == 0) msg(.{ .play = .{ .msg = Id.of(m.id()), .index = index } }) else null;
    ui.begin(.{ .width = .{ .px = 44 }, .height = .{ .px = 44 }, .radius = 22, .background = accent, .align_items = .center, .justify = .center, .pressed_opacity = 0.8 }, .{ .on_press = press });
    if (mine and v.waiting) ui.spinner(20, Color.white, .{}, 0) else ui.icon(if (playing) icons.pause else icons.play, 20, Color.white, .{}, 0);
    ui.end();
    ui.begin(.{ .grow = 1, .width = .fill, .gap = 4 }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 2, .height = .{ .px = 26 } }, .{});
    const bs = bars(a, j.str(item, "waveform"));
    const played: usize = @intFromFloat(@round(frac * @as(f32, @floatFromInt(bs.len))));
    for (bs, 0..) |b, i| {
        ui.begin(.{ .width = .{ .px = 3 }, .height = .{ .px = @max(3, @as(f32, @floatFromInt(b)) / 31 * 24) }, .radius = 1.5, .background = if (i < played) fg else fg.withAlpha(0.35) }, .{ .key = key(.{ "wb", i }) });
        ui.end();
    }
    ui.end();
    const shown_ms: f64 = if (mine and v.position_ms > 0) @floatFromInt(v.position_ms) else total_ms;
    ui.text(fmt.duration(a, shown_ms / 1000), .{ .font_size = 12.5, .color = fg, .opacity = 0.75 });
    ui.end();
    ui.end();
}

/// A round video message: the circle, the video while it plays (tap to play / pause).
pub fn roundBubble(cx: Cx, m: *const data.Message, item: j.Value, index: u8) void {
    const ui = cx.ui;
    const v = cx.s.voice;
    const mine = v.playing_msg.eql(m.id()) and v.playing_index == index and m.local_id == 0;
    const size: f32 = 220;
    ui.begin(.{ .width = .{ .px = size }, .height = .{ .px = size }, .radius = size / 2, .clip = true, .background = cx.c.surface_3, .align_items = .center, .justify = .center }, .{ .on_press = if (m.local_id == 0) msg(.{ .play = .{ .msg = Id.of(m.id()), .index = index } }) else null, .key = key(.{ "round", j.strOr(item, "id", "") }) });
    if (j.str(item, "thumb")) |th| ui.image(th, .{ .position = .absolute, .inset = .{ .top = 0, .start = 0 }, .width = .{ .px = size }, .height = .{ .px = size } }, 0);
    if (mine and v.player != 0) {
        ui.video(v.player, .{ .cover = true }, .{ .position = .absolute, .inset = .{ .top = 0, .start = 0 }, .width = .{ .px = size }, .height = .{ .px = size } }, key(.{ "rv", j.strOr(item, "id", "") }));
    } else if (mine and v.waiting) {
        ui.spinner(28, Color.white, .{}, 0);
    } else {
        ui.begin(.{ .width = .{ .px = 54 }, .height = .{ .px = 54 }, .radius = 27, .background = Color.hex("#0a0c1473"), .align_items = .center, .justify = .center }, .{});
        ui.icon(icons.play, 26, Color.white, .{}, 0);
        ui.end();
    }
    const secs: f64 = if (mine and v.position_ms > 0) @as(f64, @floatFromInt(v.position_ms)) / 1000 else j.floatOr(item, "duration", 0);
    ui.begin(.{ .position = .absolute, .inset = .{ .bottom = 14, .start = 0, .end = 0 }, .align_items = .center }, .{});
    ui.begin(.{ .padding = .xy(8, 2), .radius = 9, .background = Color.hex("#0a0c1473") }, .{});
    ui.text(fmt.duration(cx.a(), secs), .{ .font_size = 12, .weight = 600, .color = Color.white });
    ui.end();
    ui.end();
    ui.end();
}

/// A video in a bubble: tap to play it there.
pub fn videoPlaying(s: *const State, m: *const data.Message, index: u8) ?u32 {
    const v = s.voice;
    if (v.player != 0 and v.playing_msg.eql(m.id()) and v.playing_index == index) return v.player;
    return null;
}

test "waveform: 48 bars from levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var levels: [96]f32 = undefined;
    for (&levels, 0..) |*l, i| l.* = @as(f32, @floatFromInt(i % 10)) / 10;
    const w = waveform(arena.allocator(), &levels).?;
    const b = bars(arena.allocator(), w);
    try std.testing.expectEqual(@as(usize, 48), b.len);
    var top: u8 = 0;
    for (b) |x| top = @max(top, x);
    try std.testing.expectEqual(@as(u8, 31), top);
}
