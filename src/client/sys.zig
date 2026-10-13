//! What the app needs from the device that zui's effects do not carry: the wall clock, the
//! local time zone and secure random bytes.
//!
//! - Android and iOS: libc (clock_gettime, localtime_r, arc4random_buf).
//! - Web: the page has no wasm imports beyond zui's, so the web shell (shells/web/index.html)
//!   sends {"t":"env","seed":<32 random bytes, base64>,"now":<ms>,"tz":<minutes east of UTC>}
//!   at start and {"t":"clock",...} every 20 s through the app's hostMessage. The seed feeds a
//!   ChaCha20 generator (std.Random.ChaCha), re-keyed with every message that carries entropy.
//! - Tests (headless): a fixed clock the test sets, a fixed seed.

const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");

const native = (zui.platform == .android or zui.platform == .ios) and builtin.link_libc;

const timespec = extern struct { sec: i64, nsec: c_long };
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

const c = if (native) struct {
    extern "c" fn clock_gettime(clk: c_int, tp: *timespec) c_int;
    extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
    extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;
} else struct {};

/// Clock and offset as last reported (web, tests).
var reported_now: i64 = 1_760_000_000_000;
var reported_tz: i32 = 0;
var drbg: std.Random.ChaCha = undefined;
var seeded = false;

/// Milliseconds since 1970 (UTC).
pub fn now() i64 {
    if (native) {
        var ts: timespec = undefined;
        if (c.clock_gettime(0, &ts) == 0) return ts.sec * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }
    return reported_now;
}

/// Minutes east of UTC for the local time at `ms`.
pub fn tzOffsetMin(ms: i64) i32 {
    if (native) {
        const t: i64 = @divFloor(ms, 1000);
        var tm: Tm = undefined;
        if (c.localtime_r(&t, &tm) != null) return @intCast(@divTrunc(tm.gmtoff, 60));
    }
    return reported_tz;
}

/// From the web shell (or a test): the time and offset now.
pub fn setClock(ms: i64, tz_min: i32) void {
    reported_now = ms;
    reported_tz = tz_min;
}

/// Entropy from the web shell (crypto.getRandomValues); safe to call again.
pub fn addEntropy(bytes: []const u8) void {
    if (!seeded) {
        var seed: [32]u8 = @splat(0);
        std.crypto.hash.sha2.Sha256.hash(bytes, &seed, .{});
        drbg = std.Random.ChaCha.init(seed);
        seeded = true;
    } else drbg.addEntropy(bytes);
}

/// Whether secure random bytes are available yet (the web waits for the shell's seed).
pub fn canRandom() bool {
    return native or seeded or zui.platform == .headless;
}

fn fill(_: *anyopaque, buf: []u8) void {
    if (native) {
        c.arc4random_buf(buf.ptr, buf.len);
        return;
    }
    if (!seeded) {
        // Only tests get here without a seed (the web refuses to make keys until it has one).
        if (zui.platform != .headless) @panic("no entropy yet");
        drbg = std.Random.ChaCha.init(@splat(42));
        seeded = true;
    }
    drbg.fill(buf);
}

var dummy: u8 = 0;

/// Cryptographically secure randomness.
pub fn random() std.Random {
    return .{ .ptr = &dummy, .fillFn = fill };
}

pub fn randomBytes(comptime n: usize) [n]u8 {
    var b: [n]u8 = undefined;
    random().bytes(&b);
    return b;
}

// ---------------------------------------------------------------------------------------------
// Calendar arithmetic (proleptic Gregorian, days since 1970-01-01)

pub const Civil = struct { year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8, weekday: u8 };

pub fn daysFromCivil(y0: i32, m: u32, d: u32) i64 {
    const y: i64 = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @intCast((m + 9) % 12);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromMs(ms: i64) Civil {
    const secs = @divFloor(ms, 1000);
    const days = @divFloor(secs, 86400);
    const sod: u32 = @intCast(secs - days * 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y: i32 = @intCast(yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0));
    return .{
        .year = y,
        .month = m,
        .day = d,
        .hour = @intCast(sod / 3600),
        .minute = @intCast((sod / 60) % 60),
        .second = @intCast(sod % 60),
        .weekday = @intCast(@mod(days + 4, 7)), // 1970-01-01 was a Thursday; 0 = Sunday
    };
}

/// The local calendar date/time of a UTC instant.
pub fn local(ms: i64) Civil {
    return civilFromMs(ms + @as(i64, tzOffsetMin(ms)) * 60_000);
}

/// Local midnight (as a day number) of an instant.
pub fn localDay(ms: i64) i64 {
    return @divFloor(ms + @as(i64, tzOffsetMin(ms)) * 60_000, 86_400_000);
}

/// "2026-10-12T09:41:05.123Z" (or with an offset) to ms; null if it is not a date.
pub fn parseIso(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ')) return null;
    const num = struct {
        fn f(x: []const u8) ?u32 {
            return std.fmt.parseInt(u32, x, 10) catch null;
        }
    }.f;
    const y = num(s[0..4]) orelse return null;
    const mo = num(s[5..7]) orelse return null;
    const d = num(s[8..10]) orelse return null;
    const h = num(s[11..13]) orelse return null;
    const mi = num(s[14..16]) orelse return null;
    const se = num(s[17..19]) orelse return null;
    var ms: i64 = 0;
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var scale: i64 = 100;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            ms += @as(i64, s[i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    var off: i64 = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-') and s.len >= i + 6) {
        const oh = num(s[i + 1 .. i + 3]) orelse 0;
        const om = num(s[i + 4 .. i + 6]) orelse 0;
        off = (@as(i64, oh) * 60 + om) * 60_000;
        if (s[i] == '-') off = -off;
    }
    const days = daysFromCivil(@intCast(y), mo, d);
    return (days * 86400 + @as(i64, h) * 3600 + @as(i64, mi) * 60 + se) * 1000 + ms - off;
}

test "dates" {
    const t = std.testing;
    const ms = parseIso("2026-10-12T09:41:05.250Z").?;
    const cv = civilFromMs(ms);
    try t.expectEqual(@as(i32, 2026), cv.year);
    try t.expectEqual(@as(u8, 10), cv.month);
    try t.expectEqual(@as(u8, 12), cv.day);
    try t.expectEqual(@as(u8, 9), cv.hour);
    try t.expectEqual(@as(u8, 41), cv.minute);
    try t.expectEqual(@as(u8, 1), cv.weekday); // a Monday
    try t.expectEqual(@as(i64, 250), @mod(ms, 1000));
    try t.expectEqual(parseIso("2026-10-12T12:41:05.250+03:00").?, ms);
    try t.expectEqual(@as(i64, 0), parseIso("1970-01-01T00:00:00Z").?);
}
