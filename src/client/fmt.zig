//! Human-readable text: times and dates (as toLocaleTimeString/DateString give them in English and
//! Arabic), durations, sizes, plurals (Arabic's six forms), initials. Port of Reseal-js
//! core/format.js and the plural part of core/i18n.js.

const std = @import("std");
const zui = @import("zui");
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;

pub const t = zui.i18n.t;

pub fn isAr() bool {
    return std.mem.eql(u8, zui.i18n.language(), "ar");
}

/// Arabic-Indic digits in Arabic (as Intl.NumberFormat('ar') writes them).
pub fn digits(a: Allocator, s: []const u8) []const u8 {
    if (!isAr()) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            const cp: u21 = 0x0660 + @as(u21, c - '0');
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch 1;
            out.appendSlice(a, buf[0..n]) catch return s;
        } else out.append(a, c) catch return s;
    }
    return out.items;
}

pub fn number(a: Allocator, n: i64) []const u8 {
    return digits(a, std.fmt.allocPrint(a, "{d}", .{n}) catch return "");
}

fn pluralCategory(n: i64) []const u8 {
    const m = @mod(@abs(n), 100);
    if (n == 0) return "zero";
    if (n == 1) return "one";
    if (n == 2) return "two";
    if (m >= 3 and m <= 10) return "few";
    if (m >= 11 and m <= 99) return "many";
    return "other";
}

/// tn(n, '{n} member', '{n} members'): the right form, translated, with {n} filled.
pub fn tn(a: Allocator, n: i64, one: []const u8, other: []const u8) []const u8 {
    if (isAr()) {
        const key = std.fmt.allocPrint(a, "{s}|{s}", .{ other, pluralCategory(n) }) catch return other;
        const v = t(key);
        if (v.ptr != key.ptr) return fill(a, v, "n", number(a, n));
    }
    return fill(a, t(if (n == 1) one else other), "n", number(a, n));
}

/// Replaces `{name}` with `value`.
pub fn fill(a: Allocator, template: []const u8, name: []const u8, value: []const u8) []const u8 {
    const pat = std.fmt.allocPrint(a, "{{{s}}}", .{name}) catch return template;
    return std.mem.replaceOwned(u8, a, template, pat, value) catch template;
}

/// t(template) with several {name} fields.
pub fn tv(a: Allocator, template: []const u8, args: anytype) []const u8 {
    var s = t(template);
    inline for (comptime std.meta.fieldNames(@TypeOf(args))) |name| {
        const value = @field(args, name);
        const text: []const u8 = switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int => number(a, value),
            else => value,
        };
        s = fill(a, s, name, text);
    }
    return s;
}

const months_en = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const months_long_en = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const months_ar = [_][]const u8{ "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر" };
const days_en = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const days_long_en = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const days_ar = [_][]const u8{ "الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت" };

/// "9:41 AM" / "٩:٤١ ص".
pub fn time(a: Allocator, ms: i64) []const u8 {
    const c = sys.local(ms);
    const h12 = if (c.hour % 12 == 0) 12 else c.hour % 12;
    if (isAr()) return digits(a, std.fmt.allocPrint(a, "{d}:{d:0>2} {s}", .{ h12, c.minute, if (c.hour < 12) "ص" else "م" }) catch "");
    return std.fmt.allocPrint(a, "{d}:{d:0>2} {s}", .{ h12, c.minute, if (c.hour < 12) "AM" else "PM" }) catch "";
}

fn dayMonth(a: Allocator, c: sys.Civil, long: bool, year: bool) []const u8 {
    if (isAr()) {
        const s = if (year)
            std.fmt.allocPrint(a, "{d} {s} {d}", .{ c.day, months_ar[c.month - 1], c.year }) catch ""
        else
            std.fmt.allocPrint(a, "{d} {s}", .{ c.day, months_ar[c.month - 1] }) catch "";
        return digits(a, s);
    }
    const m = if (long) months_long_en[c.month - 1] else months_en[c.month - 1];
    if (year) return std.fmt.allocPrint(a, "{s} {d}, {d}", .{ m, c.day, c.year }) catch "";
    return std.fmt.allocPrint(a, "{s} {d}", .{ m, c.day }) catch "";
}

/// Chat list: the time today, the weekday this week, the date otherwise.
pub fn shortDate(a: Allocator, ms: i64) []const u8 {
    const now = sys.now();
    const today = sys.localDay(now);
    const day = sys.localDay(ms);
    const c = sys.local(ms);
    if (day == today) return time(a, ms);
    if (today - day < 6 and today > day) return if (isAr()) days_ar[c.weekday] else days_en[c.weekday];
    if (c.year == sys.local(now).year) return dayMonth(a, c, false, false);
    if (isAr()) return digits(a, std.fmt.allocPrint(a, "{d}/{d}/{d:0>2}", .{ c.day, c.month, @mod(c.year, 100) }) catch "");
    return std.fmt.allocPrint(a, "{s} {d}, {d:0>2}", .{ months_en[c.month - 1], c.day, @mod(c.year, 100) }) catch "";
}

/// The day separator in a chat: Today, Yesterday, "Monday, October 12", "October 12, 2025".
pub fn dayLabel(a: Allocator, ms: i64) []const u8 {
    const now = sys.now();
    const today = sys.localDay(now);
    const day = sys.localDay(ms);
    if (day == today) return t("Today");
    if (today - day == 1) return t("Yesterday");
    const c = sys.local(ms);
    const same_year = c.year == sys.local(now).year;
    const dm = dayMonth(a, c, true, !same_year);
    if (today - day < 6 and today > day) {
        if (isAr()) return std.fmt.allocPrint(a, "{s}، {s}", .{ days_ar[c.weekday], dm }) catch dm;
        return std.fmt.allocPrint(a, "{s}, {s}", .{ days_long_en[c.weekday], dm }) catch dm;
    }
    return dm;
}

pub fn fullDate(a: Allocator, ms: i64) []const u8 {
    const c = sys.local(ms);
    return std.fmt.allocPrint(a, "{s}, {s}", .{ dayMonth(a, c, false, true), time(a, ms) }) catch "";
}

pub fn sameDay(x: i64, y: i64) bool {
    return sys.localDay(x) == sys.localDay(y);
}

/// m:ss or h:mm:ss.
pub fn duration(a: Allocator, seconds: f64) []const u8 {
    const s: u64 = @intFromFloat(@max(0, @round(seconds)));
    const hh = s / 3600;
    const mm = (s % 3600) / 60;
    const ss = s % 60;
    const out = if (hh > 0)
        std.fmt.allocPrint(a, "{d}:{d:0>2}:{d:0>2}", .{ hh, mm, ss }) catch ""
    else
        std.fmt.allocPrint(a, "{d}:{d:0>2}", .{ mm, ss }) catch "";
    return digits(a, out);
}

pub fn longDuration(a: Allocator, seconds: i64) []const u8 {
    const s = seconds;
    if (s < 60) return tn(a, s, "{n} second", "{n} seconds");
    if (s < 3600) return tn(a, @divTrunc(s + 30, 60), "{n} minute", "{n} minutes");
    if (s < 86400) return tn(a, @divTrunc(s + 1800, 3600), "{n} hour", "{n} hours");
    if (s < 7 * 86400) return tn(a, @divTrunc(s + 43200, 86400), "{n} day", "{n} days");
    if (s < 30 * 86400) return tn(a, @divTrunc(s, 7 * 86400), "{n} week", "{n} weeks");
    return tn(a, @divTrunc(s, 30 * 86400), "{n} month", "{n} months");
}

pub fn fileSize(a: Allocator, bytes: i64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB" };
    var n: f64 = @floatFromInt(@max(0, bytes));
    var i: usize = 0;
    while (n >= 1024 and i < units.len - 1) : (i += 1) n /= 1024;
    const s = if (n < 10 and i > 0)
        std.fmt.allocPrint(a, "{d:.1} {s}", .{ n, units[i] }) catch ""
    else
        std.fmt.allocPrint(a, "{d} {s}", .{ @as(u64, @intFromFloat(@round(n))), units[i] }) catch "";
    return digits(a, s);
}

/// Up to two initials: "Alice Carter" -> "AC", "bob" -> "B".
pub fn initials(a: Allocator, name: []const u8) []const u8 {
    var parts: [2][]const u8 = .{ "", "" };
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, name, " \t\n");
    while (it.next()) |p| {
        if (count == 0) parts[0] = p;
        parts[1] = p;
        count += 1;
    }
    if (count == 0) return "?";
    var out: std.ArrayList(u8) = .empty;
    const first = struct {
        fn f(s: []const u8) []const u8 {
            const n = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
            return s[0..@min(n, s.len)];
        }
    }.f;
    out.appendSlice(a, first(parts[0])) catch return "?";
    if (count > 1) out.appendSlice(a, first(parts[1])) catch {};
    for (out.items) |*c| c.* = std.ascii.toUpper(c.*);
    return out.items;
}

/// The first word of a name.
pub fn firstName(name: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, name, ' ');
    return it.next() orelse name;
}

/// One line of text (newlines and runs of spaces become one space), cut to `max` characters.
pub fn plain(a: Allocator, s: []const u8, max: usize) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    var chars: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const ch = s[i..@min(s.len, i + n)];
        i += n;
        if (ch.len == 1 and std.ascii.isWhitespace(ch[0])) {
            space = out.items.len > 0;
            continue;
        }
        if (space) {
            out.append(a, ' ') catch break;
            space = false;
        }
        if (chars >= max) {
            out.appendSlice(a, "…") catch {};
            break;
        }
        out.appendSlice(a, ch) catch break;
        chars += 1;
    }
    return out.items;
}

test "formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    sys.setClock(sys.parseIso("2026-10-12T15:00:00Z").?, 180);
    try std.testing.expectEqualStrings("12:41 PM", time(a, sys.parseIso("2026-10-12T09:41:00Z").?));
    try std.testing.expectEqualStrings("Today", dayLabel(a, sys.parseIso("2026-10-12T09:41:00Z").?));
    try std.testing.expectEqualStrings("Yesterday", dayLabel(a, sys.parseIso("2026-10-11T09:41:00Z").?));
    try std.testing.expectEqualStrings("Sat", shortDate(a, sys.parseIso("2026-10-10T09:41:00Z").?));
    try std.testing.expectEqualStrings("Sep 2", shortDate(a, sys.parseIso("2026-09-02T09:41:00Z").?));
    try std.testing.expectEqualStrings("1:05", duration(a, 65));
    try std.testing.expectEqualStrings("2.0 KB", fileSize(a, 2048));
    try std.testing.expectEqualStrings("AC", initials(a, "Alice  Carter"));
    try std.testing.expectEqualStrings("3 members", tn(a, 3, "{n} member", "{n} members"));
    try std.testing.expectEqualStrings("a b c", plain(a, " a\n b  c ", 100));
}
