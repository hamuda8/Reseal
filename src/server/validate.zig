//! Small input validators (src/util/validate.js). Each returns the cleaned value or fails the
//! request with a 400 "invalid_input" whose message names the field.

const std = @import("std");
const A = @import("app.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;
const ObjectId = A.ObjectId;

fn fail(r: *Rq, name: []const u8, why: []const u8) error{ Http, OutOfMemory } {
    return r.fail(400, try std.fmt.allocPrint(r.a, "{s} {s}", .{ name, why }), "invalid_input");
}

fn missing(v: Val) bool {
    return v == .undef or v == .null or (v == .str and v.str.len == 0);
}

pub const StrOpts = struct {
    min: usize = 0,
    max: usize = 1000,
    optional: bool = false,
    trim: bool = true,
    pattern: ?*const fn ([]const u8) bool = null,
    lower: bool = false,
};

/// Text; null when optional and missing.
pub fn str(r: *Rq, value: Val, name: []const u8, o: StrOpts) !?[]const u8 {
    if (missing(value)) {
        if (o.optional) return null;
        if (o.min > 0) return fail(r, name, "is required");
        return "";
    }
    if (value != .str) return fail(r, name, "must be text");
    var out = if (o.trim) jsTrim(value.str) else value.str;
    if (o.lower) out = try std.ascii.allocLowerString(r.a, out);
    const n = utf16Len(out);
    if (n < o.min) return fail(r, name, try r.fmt("must be at least {d} characters", .{o.min}));
    if (n > o.max) return fail(r, name, try r.fmt("must be at most {d} characters", .{o.max}));
    if (o.pattern) |p| if (!p(out)) return fail(r, name, "has an invalid format");
    return out;
}

/// Required text (min > 0 or not optional): never null.
pub fn reqStr(r: *Rq, value: Val, name: []const u8, o: StrOpts) ![]const u8 {
    return (try str(r, value, name, o)) orelse "";
}

pub const NumOpts = struct {
    min: f64 = -std.math.inf(f64),
    max: f64 = std.math.inf(f64),
    optional: bool = false,
};

pub fn int(r: *Rq, value: Val, name: []const u8, o: NumOpts) !?i64 {
    if (missing(value)) {
        if (o.optional) return null;
        return fail(r, name, "is required");
    }
    const x = toNumber(value);
    if (!std.math.isFinite(x) or @floor(x) != x) return fail(r, name, "must be a whole number");
    if (x < o.min or x > o.max) return fail(r, name, try r.fmt("must be between {s} and {s}", .{ try val.fmtNum(r.a, o.min), try val.fmtNum(r.a, o.max) }));
    return clampInt(x);
}

pub fn reqInt(r: *Rq, value: Val, name: []const u8, o: NumOpts) !i64 {
    return (try int(r, value, name, o)) orelse 0;
}

pub fn num(r: *Rq, value: Val, name: []const u8, o: NumOpts) !?f64 {
    if (missing(value)) {
        if (o.optional) return null;
        return fail(r, name, "is required");
    }
    const x = toNumber(value);
    if (!std.math.isFinite(x) or x < o.min or x > o.max) return fail(r, name, try r.fmt("must be a number between {s} and {s}", .{ try val.fmtNum(r.a, o.min), try val.fmtNum(r.a, o.max) }));
    return x;
}

pub fn boolean(r: *Rq, value: Val, name: []const u8, optional: bool) !?bool {
    if (value == .undef or value == .null) {
        if (optional) return null;
        return fail(r, name, "is required");
    }
    if (value != .bool) return fail(r, name, "must be true or false");
    return value.bool;
}

pub fn reqBool(r: *Rq, value: Val, name: []const u8) !bool {
    return (try boolean(r, value, name, false)) orelse false;
}

/// One of the allowed strings.
pub fn oneOf(r: *Rq, value: Val, name: []const u8, allowed: []const []const u8, optional: bool) !?[]const u8 {
    if (value == .undef or value == .null) {
        if (optional) return null;
        return fail(r, name, "is required");
    }
    if (value == .str) for (allowed) |x| if (std.mem.eql(u8, x, value.str)) return x;
    return fail(r, name, try r.fmt("must be one of: {s}", .{try std.mem.join(r.a, ", ", allowed)}));
}

pub fn reqOneOf(r: *Rq, value: Val, name: []const u8, allowed: []const []const u8) ![]const u8 {
    return (try oneOf(r, value, name, allowed, false)) orelse allowed[0];
}

/// One of the allowed numbers.
pub fn oneOfNum(r: *Rq, value: Val, name: []const u8, allowed: []const i64) !i64 {
    if (value == .undef or value == .null) return fail(r, name, "is required");
    if (value == .num) for (allowed) |x| if (@as(f64, @floatFromInt(x)) == value.num) return x;
    var parts: std.ArrayList(u8) = .empty;
    for (allowed, 0..) |x, i| {
        if (i > 0) try parts.appendSlice(r.a, ", ");
        try parts.print(r.a, "{d}", .{x});
    }
    return fail(r, name, try r.fmt("must be one of: {s}", .{parts.items}));
}

/// An ObjectId from a 24-character hex string (or an ObjectId).
pub fn id(r: *Rq, value: Val, name: []const u8, optional: bool) !?ObjectId {
    if (missing(value)) {
        if (optional) return null;
        return fail(r, name, "is required");
    }
    if (oid(value)) |x| return x;
    return fail(r, name, "is not a valid id");
}

pub fn reqId(r: *Rq, value: Val, name: []const u8) !ObjectId {
    return (try id(r, value, name, false)).?;
}

/// db.js `oid`: an ObjectId, or null when the value is not a valid id.
pub fn oid(value: Val) ?ObjectId {
    return switch (value) {
        .id => |x| x,
        .str => |s| if (s.len == 24 and isHex(s)) (ObjectId.parse(s) catch null) else null,
        else => null,
    };
}

pub fn oidStr(s: []const u8) ?ObjectId {
    return oid(.{ .str = s });
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// A list of ids, duplicates removed, order kept.
pub fn ids(r: *Rq, value: Val, name: []const u8, max: usize, optional: bool) !?[]ObjectId {
    if (value == .undef or value == .null) {
        if (optional) return null;
        return fail(r, name, "is required");
    }
    if (value != .arr) return fail(r, name, "must be a list");
    if (value.len() > max) return fail(r, name, try r.fmt("must have at most {d} items", .{max}));
    var out: std.ArrayList(ObjectId) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (value.items()) |x| {
        const key = try val.str(r.a, x);
        if (seen.contains(key)) continue;
        try seen.put(r.a, key, {});
        try out.append(r.a, (try id(r, .{ .str = key }, name, false)).?);
    }
    return out.items;
}

pub fn reqIds(r: *Rq, value: Val, name: []const u8, max: usize) ![]ObjectId {
    return (try ids(r, value, name, max, false)).?;
}

pub fn b64(r: *Rq, value: Val, name: []const u8, max_bytes: usize, optional: bool) !?[]const u8 {
    if (missing(value)) {
        if (optional) return null;
        return fail(r, name, "is required");
    }
    if (value != .str or !isB64(value.str)) return fail(r, name, "must be base64");
    if (value.str.len > (max_bytes * 4 + 2) / 3 + 4) return fail(r, name, "is too large");
    return value.str;
}

pub fn reqB64(r: *Rq, value: Val, name: []const u8, max_bytes: usize) ![]const u8 {
    return (try b64(r, value, name, max_bytes, false)).?;
}

/// /^[A-Za-z0-9+/_-]*={0,2}$/
fn isB64(s: []const u8) bool {
    var end = s.len;
    var pad: usize = 0;
    while (end > 0 and s[end - 1] == '=' and pad < 2) : (pad += 1) end -= 1;
    for (s[0..end]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '_' or c == '-')) return false;
    return true;
}

pub fn obj(r: *Rq, value: Val, name: []const u8, optional: bool) !?Val {
    if (value == .undef or value == .null) {
        if (optional) return null;
        return fail(r, name, "is required");
    }
    if (value != .obj) return fail(r, name, "must be an object");
    return value;
}

pub fn reqObj(r: *Rq, value: Val, name: []const u8) !Val {
    return (try obj(r, value, name, false)).?;
}

/// Arbitrary JSON metadata from integrators, bounded in size and safe for MongoDB.
pub fn metadata(r: *Rq, value: Val, name: []const u8, max_bytes: usize) !?Val {
    if (value == .undef or value == .null) return null;
    _ = try reqObj(r, value, name);
    if (utf16Len(try val.stringify(r.a, value)) > max_bytes) return fail(r, name, try r.fmt("must be under {d} bytes of JSON", .{max_bytes}));
    if (!keysOk(value)) return fail(r, name, "keys must not start with $ or contain dots");
    return value;
}

pub fn meta(r: *Rq, value: Val) !?Val {
    return metadata(r, value, "metadata", 8192);
}

fn keysOk(v: Val) bool {
    switch (v) {
        .obj => for (v.keys()) |kv| {
            if (kv.k.len > 0 and kv.k[0] == '$') return false;
            if (std.mem.indexOfScalar(u8, kv.k, '.') != null) return false;
            if (!keysOk(kv.v)) return false;
        },
        .arr => for (v.items()) |x| if (!keysOk(x)) return false,
        else => {},
    }
    return true;
}

/// /^[a-zA-Z][a-zA-Z0-9_]{3,31}$/
pub fn isUsername(s: []const u8) bool {
    if (s.len < 4 or s.len > 32 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// /^#[0-9a-fA-F]{6}$/
pub fn isHexColor(s: []const u8) bool {
    return s.len == 7 and s[0] == '#' and isHex(s[1..]);
}

/// JS `Number(value)`.
pub fn toNumber(v: Val) f64 {
    return switch (v) {
        .num => |x| x,
        .bool => |b| if (b) 1 else 0,
        .null => 0,
        .str => |s| blk: {
            const t = jsTrim(s);
            if (t.len == 0) break :blk 0;
            if (std.mem.eql(u8, t, "Infinity") or std.mem.eql(u8, t, "+Infinity")) break :blk std.math.inf(f64);
            if (std.mem.eql(u8, t, "-Infinity")) break :blk -std.math.inf(f64);
            if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) break :blk @floatFromInt(std.fmt.parseInt(i64, t[2..], 16) catch break :blk std.math.nan(f64));
            for (t) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-')) break :blk std.math.nan(f64);
            break :blk std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
        },
        .date => |ms| @floatFromInt(ms),
        .arr => |l| if (l.items.len == 0) 0 else if (l.items.len == 1) toNumber(l.items[0]) else std.math.nan(f64),
        else => std.math.nan(f64),
    };
}

/// Length in UTF-16 code units, as JS `.length` counts.
pub fn utf16Len(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        const l: usize = if (c < 0x80) 1 else if (c >> 5 == 0b110) 2 else if (c >> 4 == 0b1110) 3 else if (c >> 3 == 0b11110) 4 else 1;
        n += if (l == 4) 2 else 1;
        i += l;
    }
    return n;
}

/// The first `count` UTF-16 code units of `s` (String.prototype.slice(0, count)), without
/// splitting a UTF-8 sequence.
pub fn sliceUtf16(s: []const u8, count: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        const l: usize = if (c < 0x80) 1 else if (c >> 5 == 0b110) 2 else if (c >> 4 == 0b1110) 3 else if (c >> 3 == 0b11110) 4 else 1;
        const units: usize = if (l == 4) 2 else 1;
        if (n + units > count) break;
        n += units;
        i += l;
    }
    return s[0..@min(i, s.len)];
}

/// String.prototype.trim: ASCII whitespace and the Unicode spaces JS trims.
pub fn jsTrim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end) {
        const l = spaceLen(s[start..end]);
        if (l == 0) break;
        start += l;
    }
    while (end > start) {
        const l = spaceLenEnd(s[start..end]);
        if (l == 0) break;
        end -= l;
    }
    return s[start..end];
}

const unicode_spaces = [_][]const u8{
    "\u{00A0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
    "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}",
    "\u{205F}", "\u{3000}", "\u{FEFF}",
};

fn spaceLen(s: []const u8) usize {
    if (s.len == 0) return 0;
    switch (s[0]) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => return 1,
        else => {},
    }
    for (unicode_spaces) |u| if (std.mem.startsWith(u8, s, u)) return u.len;
    return 0;
}

fn spaceLenEnd(s: []const u8) usize {
    if (s.len == 0) return 0;
    switch (s[s.len - 1]) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => return 1,
        else => {},
    }
    for (unicode_spaces) |u| if (std.mem.endsWith(u8, s, u)) return u.len;
    return 0;
}

/// `text.replace(/\s+$/, '')`
pub fn trimEnd(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        const l = spaceLenEnd(s[0..end]);
        if (l == 0) break;
        end -= l;
    }
    return s[0..end];
}

/// JS toLowerCase for the ASCII range, leaving other characters as they are.
pub fn lower(r: *Rq, s: []const u8) ![]const u8 {
    return std.ascii.allocLowerString(r.a, s);
}

test "validators" {
    try std.testing.expect(isUsername("alice_1"));
    try std.testing.expect(!isUsername("1alice"));
    try std.testing.expectEqualStrings("hi", jsTrim(" \u{00A0}hi\n"));
    try std.testing.expectEqual(@as(usize, 2), utf16Len("😀"));
    try std.testing.expectEqualStrings("a", sliceUtf16("a😀", 2));
    try std.testing.expectEqual(@as(f64, 12), toNumber(.{ .str = " 12 " }));
}

/// A JS number as an integer, truncated and kept in the range where f64 is exact (casting a
/// larger value would trap).
pub fn clampInt(x: f64) i64 {
    if (std.math.isNan(x)) return 0;
    const t = @trunc(x);
    if (t > 9.007199254740991e15) return 9007199254740991;
    if (t < -9.007199254740991e15) return -9007199254740991;
    return @intFromFloat(t);
}
