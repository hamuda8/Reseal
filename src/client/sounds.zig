//! Reseal's sounds (Reseal-js core/sounds.js): the same tones, made here as WAV and played with
//! fx.play: the incoming-message chime and the sent whoosh (when Sounds is on), and the call
//! sounds (ringtone, dial tone, connect, hang-up), which play even with Sounds off.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");

const State = app.State;
const gpa = app.gpa;

const rate = 22050;

const Wave = enum { sine, triangle };

/// One tone of sounds.js: a frequency (gliding to another), an attack of 12 ms and an
/// exponential fall to silence over `dur`.
const Tone = struct { freq: f32, start: f32 = 0, dur: f32 = 0.15, gain: f32 = 0.15, wave: Wave = .sine, glide: ?f32 = null };

pub const Sound = enum { incoming, sent, ring, dial, connect, hangup };

fn tones(s: Sound) []const Tone {
    return switch (s) {
        .incoming => &.{ .{ .freq = 880, .dur = 0.12, .gain = 0.12 }, .{ .freq = 1320, .start = 0.09, .dur = 0.18, .gain = 0.1 } },
        .sent => &.{.{ .freq = 520, .glide = 900, .dur = 0.12, .gain = 0.05, .wave = .triangle }},
        .ring => &.{
            .{ .freq = 784, .start = 0, .dur = 0.26, .gain = 0.14, .wave = .triangle },
            .{ .freq = 1046, .start = 0.05, .dur = 0.22, .gain = 0.08 },
            .{ .freq = 784, .start = 0.32, .dur = 0.26, .gain = 0.14, .wave = .triangle },
            .{ .freq = 1046, .start = 0.37, .dur = 0.22, .gain = 0.08 },
        },
        .dial => &.{ .{ .freq = 440, .dur = 1.0, .gain = 0.05 }, .{ .freq = 480, .dur = 1.0, .gain = 0.05 } },
        .connect => &.{ .{ .freq = 660, .dur = 0.1, .gain = 0.07 }, .{ .freq = 990, .start = 0.1, .dur = 0.14, .gain = 0.07 } },
        .hangup => &.{ .{ .freq = 480, .dur = 0.18, .gain = 0.08 }, .{ .freq = 360, .start = 0.2, .dur = 0.3, .gain = 0.08 } },
    };
}

/// How long one round lasts: the ringtone repeats every 2.2 s and the dial tone every 3 s.
fn length(s: Sound) f32 {
    return switch (s) {
        .ring => 2.2,
        .dial => 3.0,
        else => blk: {
            var end: f32 = 0;
            for (tones(s)) |tn| end = @max(end, tn.start + tn.dur + 0.03);
            break :blk end;
        },
    };
}

/// 16-bit mono PCM WAV of the sound.
pub fn wav(a: std.mem.Allocator, s: Sound) ![]u8 {
    const n: usize = @intFromFloat(length(s) * rate);
    const buf = try a.alloc(u8, 44 + n * 2);
    const W = struct {
        fn put32(b: []u8, at: usize, v: u32) void {
            std.mem.writeInt(u32, b[at..][0..4], v, .little);
        }
        fn put16(b: []u8, at: usize, v: u16) void {
            std.mem.writeInt(u16, b[at..][0..2], v, .little);
        }
    };
    @memcpy(buf[0..4], "RIFF");
    W.put32(buf, 4, @intCast(36 + n * 2));
    @memcpy(buf[8..16], "WAVEfmt ");
    W.put32(buf, 16, 16);
    W.put16(buf, 20, 1);
    W.put16(buf, 22, 1);
    W.put32(buf, 24, rate);
    W.put32(buf, 28, rate * 2);
    W.put16(buf, 32, 2);
    W.put16(buf, 34, 16);
    @memcpy(buf[36..40], "data");
    W.put32(buf, 40, @intCast(n * 2));
    const samples = try a.alloc(f32, n);
    defer a.free(samples);
    @memset(samples, 0);
    for (tones(s)) |tn| {
        const s0: usize = @intFromFloat(tn.start * rate);
        const len: usize = @intFromFloat(tn.dur * rate);
        var phase: f32 = 0;
        for (0..len) |i| {
            const at = s0 + i;
            if (at >= n) break;
            const time = @as(f32, @floatFromInt(i)) / rate;
            // Exponential glide and envelope, as Web Audio's exponentialRampToValueAtTime.
            const f = if (tn.glide) |g| tn.freq * std.math.pow(f32, g / tn.freq, time / tn.dur) else tn.freq;
            phase += f / rate;
            phase -= @floor(phase);
            const v: f32 = switch (tn.wave) {
                .sine => @sin(phase * 2 * std.math.pi),
                .triangle => 1 - 4 * @abs(phase - 0.5),
            };
            const attack: f32 = 0.012;
            const env: f32 = if (time < attack)
                0.0001 * std.math.pow(f32, tn.gain / 0.0001, time / attack)
            else
                tn.gain * std.math.pow(f32, 0.0001 / tn.gain, (time - attack) / @max(0.001, tn.dur - attack));
            samples[at] += v * env;
        }
    }
    for (samples, 0..) |x, i| {
        const c = std.math.clamp(x, -1, 1);
        W.put16(buf, 44 + i * 2, @bitCast(@as(i16, @intFromFloat(c * 32767))));
    }
    return buf;
}

pub const Sounds = struct {
    cache: [6]?[]u8 = @splat(null),
    /// The ringtone or dial tone going on (looped), 0 for none.
    loop: u32 = 0,
};

fn bytes(s: *State, which: Sound) ?[]const u8 {
    const i = @intFromEnum(which);
    if (s.sounds.cache[i] == null) s.sounds.cache[i] = wav(gpa, which) catch return null;
    return s.sounds.cache[i];
}

fn onPlay(e: zui.PlayEvent) app.Msg {
    return .{ .sound = e };
}

/// A short sound once. Message sounds follow the Sounds switch; call sounds always play.
pub fn play(s: *State, which: Sound) void {
    const message = which == .incoming or which == .sent;
    if (message and !s.prefs.sounds) return;
    const data = bytes(s, which) orelse return;
    _ = app.fx.play(.{ .data = data, .mime = "audio/wav", .stream = if (message) .media else .call }, onPlay);
}

/// The ringtone (an incoming call) or the dial tone (calling out), until `stop`.
pub fn start(s: *State, which: Sound) void {
    stop(s);
    const data = bytes(s, which) orelse return;
    s.sounds.loop = app.fx.play(.{ .data = data, .mime = "audio/wav", .loop = true, .stream = if (which == .ring) .ringtone else .call }, onPlay);
}

pub fn stop(s: *State) void {
    if (s.sounds.loop != 0) app.fx.stopPlayback(s.sounds.loop);
    s.sounds.loop = 0;
}

test "sounds as WAV" {
    const a = std.testing.allocator;
    const w = try wav(a, .ring);
    defer a.free(w);
    try std.testing.expectEqualStrings("RIFF", w[0..4]);
    try std.testing.expectEqual(@as(usize, 44 + 2 * @as(usize, @intFromFloat(2.2 * rate))), w.len);
    // Sound at the start, silence at the end of the round.
    var loud: u32 = 0;
    for (0..200) |i| loud = @max(loud, @abs(@as(i32, std.mem.readInt(i16, w[44 + (2000 + i) * 2 ..][0..2], .little))));
    try std.testing.expect(loud > 1000);
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, w[w.len - 2 ..][0..2], .little));
}
