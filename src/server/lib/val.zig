//! A JavaScript-like dynamic value. Reseal-js passes plain objects between MongoDB, JSON and its
//! own code; porting it line by line is far simpler (and keeps every document shape exactly) when
//! Zig does the same. Numbers are f64 like JS numbers, objects keep their key order, `undef` is
//! JS `undefined`: left out of JSON objects, stored as null in BSON (the Node driver's default).

const std = @import("std");
const bson = @import("mongo").bson;

pub const ObjectId = bson.ObjectId;
pub const Allocator = std.mem.Allocator;

pub const Kv = struct { k: []const u8, v: Val };
pub const Obj = struct { items: std.ArrayList(Kv) = .empty };
pub const Arr = std.ArrayList(Val);

pub const Val = union(enum) {
    undef,
    null,
    bool: bool,
    num: f64,
    str: []const u8,
    id: ObjectId,
    /// Milliseconds since the epoch (JS Date).
    date: i64,
    arr: *Arr,
    obj: *Obj,
    bin: []const u8,
    regex: struct { pattern: []const u8, options: []const u8 },
    /// Other BSON values, kept as they are (decimal128, timestamps, ...).
    raw: bson.Value,

    pub const True: Val = .{ .bool = true };
    pub const False: Val = .{ .bool = false };

    pub fn n(x: anytype) Val {
        return .{ .num = switch (@typeInfo(@TypeOf(x))) {
            .int, .comptime_int => @floatFromInt(x),
            else => @floatCast(x),
        } };
    }

    pub fn s(x: []const u8) Val {
        return .{ .str = x };
    }

    pub fn object(a: Allocator) !Val {
        const o = try a.create(Obj);
        o.* = .{};
        return .{ .obj = o };
    }

    pub fn array(a: Allocator) !Val {
        const l = try a.create(Arr);
        l.* = .empty;
        return .{ .arr = l };
    }

    pub fn arrayOf(a: Allocator, list: []const Val) !Val {
        var v = try array(a);
        try v.arr.appendSlice(a, list);
        return v;
    }

    pub fn isObj(v: Val) bool {
        return v == .obj;
    }

    pub fn isArr(v: Val) bool {
        return v == .arr;
    }

    pub fn isNullish(v: Val) bool {
        return v == .undef or v == .null;
    }

    pub fn isUndef(v: Val) bool {
        return v == .undef;
    }

    /// JS truthiness.
    pub fn truthy(v: Val) bool {
        return switch (v) {
            .undef, .null => false,
            .bool => |b| b,
            .num => |x| x != 0 and !std.math.isNan(x),
            .str => |x| x.len > 0,
            else => true,
        };
    }

    /// `v[key]` for objects; undefined otherwise.
    pub fn get(v: Val, key: []const u8) Val {
        switch (v) {
            .obj => |o| {
                for (o.items.items) |kv| if (std.mem.eql(u8, kv.k, key)) return kv.v;
                return .undef;
            },
            .arr => |l| {
                const i = std.fmt.parseUnsigned(usize, key, 10) catch return .undef;
                return if (i < l.items.len) l.items[i] else .undef;
            },
            else => return .undef,
        }
    }

    /// `a.b.c` through nested objects (and arrays by index).
    pub fn path(v: Val, p: []const u8) Val {
        var cur = v;
        var it = std.mem.splitScalar(u8, p, '.');
        while (it.next()) |k| {
            if (cur.isNullish()) return .undef;
            cur = cur.get(k);
        }
        return cur;
    }

    pub fn has(v: Val, key: []const u8) bool {
        if (v != .obj) return false;
        for (v.obj.items.items) |kv| if (std.mem.eql(u8, kv.k, key)) return true;
        return false;
    }

    /// Sets a key; an existing key keeps its position (as in JS).
    pub fn put(v: Val, a: Allocator, key: []const u8, value: Val) !void {
        const o = v.obj;
        for (o.items.items) |*kv| if (std.mem.eql(u8, kv.k, key)) {
            kv.v = value;
            return;
        };
        try o.items.append(a, .{ .k = key, .v = value });
    }

    /// Sets a key from any Zig value (see `from`).
    pub fn set(v: Val, a: Allocator, key: []const u8, value: anytype) !void {
        return v.put(a, key, try from(a, value));
    }

    pub fn del(v: Val, key: []const u8) void {
        if (v != .obj) return;
        const o = v.obj;
        for (o.items.items, 0..) |kv, i| if (std.mem.eql(u8, kv.k, key)) {
            _ = o.items.orderedRemove(i);
            return;
        };
    }

    pub fn keys(v: Val) []const Kv {
        return if (v == .obj) v.obj.items.items else &.{};
    }

    pub fn items(v: Val) []Val {
        return if (v == .arr) v.arr.items else &.{};
    }

    pub fn len(v: Val) usize {
        return switch (v) {
            .arr => |l| l.items.len,
            .obj => |o| o.items.items.len,
            .str => |x| x.len,
            else => 0,
        };
    }

    pub fn push(v: Val, a: Allocator, x: Val) !void {
        try v.arr.append(a, x);
    }

    pub fn asStr(v: Val) ?[]const u8 {
        return if (v == .str) v.str else null;
    }

    pub fn asNum(v: Val) ?f64 {
        return if (v == .num) v.num else null;
    }

    /// Whole numbers only.
    pub fn asInt(v: Val) ?i64 {
        if (v != .num) return null;
        const x = v.num;
        if (!std.math.isFinite(x) or @floor(x) != x or @abs(x) > 9.007199254740991e15) return null;
        return @intFromFloat(x);
    }

    pub fn asBool(v: Val) ?bool {
        return if (v == .bool) v.bool else null;
    }

    pub fn asId(v: Val) ?ObjectId {
        return switch (v) {
            .id => |x| x,
            .str => |x| if (x.len == 24) (ObjectId.parse(x) catch null) else null,
            else => null,
        };
    }

    pub fn isTrue(v: Val) bool {
        return v == .bool and v.bool;
    }

    /// Strict equality for primitives (===); ObjectIds and dates by value.
    pub fn eql(x: Val, y: Val) bool {
        return switch (x) {
            .undef => y == .undef,
            .null => y == .null,
            .bool => |b| y == .bool and y.bool == b,
            .num => |b| y == .num and y.num == b,
            .str => |b| y == .str and std.mem.eql(u8, y.str, b),
            .id => |b| y == .id and std.mem.eql(u8, &y.id.bytes, &b.bytes),
            .date => |b| y == .date and y.date == b,
            .arr => |b| y == .arr and y.arr == b,
            .obj => |b| y == .obj and y.obj == b,
            else => false,
        };
    }
};

/// A shallow copy of an object (`{ ...o }`).
pub fn clone(a: Allocator, v: Val) !Val {
    switch (v) {
        .obj => |o| {
            const out = try Val.object(a);
            try out.obj.items.appendSlice(a, o.items.items);
            return out;
        },
        .arr => |l| {
            const out = try Val.array(a);
            try out.arr.appendSlice(a, l.items);
            return out;
        },
        else => return v,
    }
}

/// A deep copy (structuredClone), into `a`.
pub fn deepClone(a: Allocator, v: Val) !Val {
    switch (v) {
        .obj => |o| {
            const out = try Val.object(a);
            try out.obj.items.ensureTotalCapacity(a, o.items.items.len);
            for (o.items.items) |kv| out.obj.items.appendAssumeCapacity(.{ .k = try a.dupe(u8, kv.k), .v = try deepClone(a, kv.v) });
            return out;
        },
        .arr => |l| {
            const out = try Val.array(a);
            for (l.items) |x| try out.arr.append(a, try deepClone(a, x));
            return out;
        },
        .str => |x| return .{ .str = try a.dupe(u8, x) },
        .bin => |x| return .{ .bin = try a.dupe(u8, x) },
        .regex => |x| return .{ .regex = .{ .pattern = try a.dupe(u8, x.pattern), .options = try a.dupe(u8, x.options) } },
        .raw => |x| return switch (x) {
            .string => |t| .{ .raw = .{ .string = try a.dupe(u8, t) } },
            .document, .array, .binary, .regex => .null,
            else => v,
        },
        else => return v,
    }
}

/// `{ ...base, ...extra }`
pub fn merge(a: Allocator, base: Val, extra: Val) !Val {
    const out = try clone(a, if (base == .obj) base else try Val.object(a));
    for (extra.keys()) |kv| try out.put(a, kv.k, kv.v);
    return out;
}

// ---------------------------------------------------------------------------------------------
// From Zig values
// ---------------------------------------------------------------------------------------------

/// Any Zig value as a Val: structs → objects (field order kept), tuples and slices → arrays,
/// strings → strings, numbers → numbers, null optionals → undefined, enum literals → strings.
pub fn from(a: Allocator, x: anytype) Allocator.Error!Val {
    const T = @TypeOf(x);
    switch (T) {
        Val => return x,
        ObjectId => return .{ .id = x },
        bson.DateTime => return .{ .date = x.ms },
        bson.Doc => return fromDoc(a, x) catch .null,
        // `Val.null` / `Val.undef` in a struct literal are the union's tag, not a Val.
        std.meta.Tag(Val) => return switch (x) {
            .null => .null,
            .undef => .undef,
            else => .{ .str = @tagName(x) },
        },
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool => return .{ .bool = x },
        .int, .comptime_int => return .{ .num = @floatFromInt(x) },
        .float, .comptime_float => return .{ .num = @floatCast(x) },
        .null => return .null,
        .optional => return if (x) |y| from(a, y) else .undef,
        .@"enum", .enum_literal => return .{ .str = @tagName(x) },
        .pointer => |p| {
            if (p.size == .one) switch (@typeInfo(p.child)) {
                .array => |arr| {
                    if (arr.child == u8) return .{ .str = x };
                    var out = try Val.array(a);
                    for (x) |e| try out.push(a, try from(a, e));
                    return out;
                },
                else => return from(a, x.*),
            };
            if (p.child == u8) return .{ .str = x };
            var out = try Val.array(a);
            for (x) |e| try out.push(a, try from(a, e));
            return out;
        },
        .array => |arr| {
            if (arr.child == u8) return .{ .str = try a.dupe(u8, &x) };
            var out = try Val.array(a);
            for (x) |e| try out.push(a, try from(a, e));
            return out;
        },
        .@"struct" => |st| {
            if (st.is_tuple) {
                var out = try Val.array(a);
                inline for (x) |e| try out.push(a, try from(a, e));
                return out;
            }
            const out = try Val.object(a);
            inline for (comptime std.meta.fieldNames(T)) |name| {
                try out.obj.items.append(a, .{ .k = name, .v = try from(a, @field(x, name)) });
            }
            return out;
        },
        else => @compileError("cannot convert " ++ @typeName(T) ++ " to Val"),
    }
}

// ---------------------------------------------------------------------------------------------
// Strings like JS String(x)
// ---------------------------------------------------------------------------------------------

/// `String(v)` for ids, strings, numbers and booleans; null and undefined as JS prints them.
pub fn str(a: Allocator, v: Val) ![]const u8 {
    return switch (v) {
        .undef => "undefined",
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .num => |x| fmtNum(a, x),
        .str => |x| x,
        .id => |x| a.dupe(u8, &x.toHex()),
        .date => |ms| isoDate(a, ms),
        else => "[object Object]",
    };
}

/// String(x) === String(y), the way Reseal-js compares ids.
pub fn same(x: Val, y: Val) bool {
    var b1: [40]u8 = undefined;
    var b2: [40]u8 = undefined;
    const sx = keyOf(x, &b1) orelse return false;
    const sy = keyOf(y, &b2) orelse return false;
    return std.mem.eql(u8, sx, sy);
}

/// A short string form for ids, strings and numbers (null for anything else).
pub fn keyOf(v: Val, buf: *[40]u8) ?[]const u8 {
    return switch (v) {
        .id => |x| blk: {
            buf[0..24].* = x.toHex();
            break :blk buf[0..24];
        },
        .str => |x| x,
        .num => |x| fmtNumBuf(buf, x),
        .null => "null",
        .undef => "undefined",
        .bool => |b| if (b) "true" else "false",
        else => null,
    };
}

/// The id as a 24-character hex string; null when `v` is not an id.
pub fn hex(a: Allocator, v: Val) !?[]const u8 {
    return switch (v) {
        .id => |x| try a.dupe(u8, &x.toHex()),
        .str => |x| x,
        else => null,
    };
}

/// `s(x)` of serialize.js: null and undefined stay null, anything else becomes a string.
pub fn sOrNull(a: Allocator, v: Val) !Val {
    if (v.isNullish()) return .null;
    return .{ .str = try str(a, v) };
}

fn fmtNumBuf(buf: *[40]u8, x: f64) []const u8 {
    if (std.math.isNan(x)) return "NaN";
    if (std.math.isInf(x)) return if (x > 0) "Infinity" else "-Infinity";
    if (@floor(x) == x and @abs(x) < 1e21) {
        if (x == 0) return "0";
        return std.fmt.bufPrint(buf, "{d}", .{@as(i128, @intFromFloat(x))}) catch "0";
    }
    const abs = @abs(x);
    if (abs >= 1e21 or abs < 1e-6) {
        // JS: 1e+21, 1.5e-7
        var tmp: [40]u8 = undefined;
        const e = std.fmt.bufPrint(&tmp, "{e}", .{x}) catch return "0";
        const epos = std.mem.indexOfScalar(u8, e, 'e') orelse return e;
        const mant = e[0..epos];
        const exp = e[epos + 1 ..];
        const sign: []const u8 = if (exp.len > 0 and exp[0] == '-') "-" else "+";
        const digits = std.mem.trimStart(u8, std.mem.trimStart(u8, exp, "+-"), "0");
        return std.fmt.bufPrint(buf, "{s}e{s}{s}", .{ mant, sign, if (digits.len == 0) "0" else digits }) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d}", .{x}) catch "0";
}

pub fn fmtNum(a: Allocator, x: f64) ![]const u8 {
    var buf: [40]u8 = undefined;
    return a.dupe(u8, fmtNumBuf(&buf, x));
}

// ---------------------------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------------------------

/// `new Date(ms).toISOString()`
pub fn isoDate(a: Allocator, ms: i64) ![]const u8 {
    var buf: [32]u8 = undefined;
    return a.dupe(u8, isoDateBuf(&buf, ms));
}

pub fn isoDateBuf(buf: *[32]u8, ms: i64) []const u8 {
    const secs = @divFloor(ms, 1000);
    const milli: u64 = @intCast(ms - secs * 1000);
    const days = @divFloor(secs, 86400);
    const sod: u64 = @intCast(secs - days * 86400);
    const ymd = civilFromDays(days);
    if (ymd.y < 0 or ymd.y > 9999) {
        return std.fmt.bufPrint(buf, "{s}{d:0>6}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ if (ymd.y < 0) "-" else "+", @abs(ymd.y), ymd.m, ymd.d, sod / 3600, sod / 60 % 60, sod % 60, milli }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ @as(u64, @intCast(ymd.y)), ymd.m, ymd.d, sod / 3600, sod / 60 % 60, sod % 60, milli }) catch "";
}

const Ymd = struct { y: i64, m: u32, d: u32 };

/// Howard Hinnant's days-to-civil algorithm.
fn civilFromDays(z0: i64) Ymd {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Parses what `new Date(string)` accepts in practice: ISO dates ("2026-10-12",
/// "2026-10-12T01:02:03.456Z", with an offset) and plain millisecond numbers.
pub fn parseDate(text: []const u8) ?i64 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return null;
    if (std.fmt.parseInt(i64, t, 10)) |ms| return ms else |_| {}
    if (t.len < 10 or t[4] != '-' or t[7] != '-') return null;
    const y = std.fmt.parseInt(i64, t[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(i64, t[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, t[8..10], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    var ms: i64 = daysFromCivil(y, mo, d) * 86400_000;
    if (t.len == 10) return ms;
    if (t[10] != 'T' and t[10] != ' ') return null;
    var i: usize = 11;
    if (t.len < i + 5) return null;
    const hh = std.fmt.parseInt(i64, t[i .. i + 2], 10) catch return null;
    const mm = std.fmt.parseInt(i64, t[i + 3 .. i + 5], 10) catch return null;
    i += 5;
    var ss: i64 = 0;
    var frac: i64 = 0;
    if (i < t.len and t[i] == ':') {
        if (t.len < i + 3) return null;
        ss = std.fmt.parseInt(i64, t[i + 1 .. i + 3], 10) catch return null;
        i += 3;
        if (i < t.len and t[i] == '.') {
            i += 1;
            var digits: u32 = 0;
            while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) {
                if (digits < 3) frac = frac * 10 + (t[i] - '0');
                digits += 1;
            }
            while (digits < 3) : (digits += 1) frac *= 10;
        }
    }
    ms += ((hh * 60 + mm) * 60 + ss) * 1000 + frac;
    if (i == t.len) return ms; // local time; the server runs in UTC
    if (t[i] == 'Z') return ms;
    if (t[i] == '+' or t[i] == '-') {
        if (t.len < i + 6) return null;
        const oh = std.fmt.parseInt(i64, t[i + 1 .. i + 3], 10) catch return null;
        const om = std.fmt.parseInt(i64, t[i + 4 .. i + 6], 10) catch return null;
        const off = (oh * 60 + om) * 60_000;
        return if (t[i] == '+') ms - off else ms + off;
    }
    return null;
}

// ---------------------------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------------------------

pub const ParseError = error{ BadJson, OutOfMemory };

/// `JSON.parse`: duplicate keys keep the last value, numbers become f64.
pub fn parseJson(a: Allocator, text: []const u8) ParseError!Val {
    const jv = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .duplicate_field_behavior = .use_last, .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadJson,
    };
    return fromJson(a, jv);
}

pub fn fromJson(a: Allocator, jv: std.json.Value) Allocator.Error!Val {
    return switch (jv) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .num = @floatFromInt(i) },
        .float => |f| .{ .num = f },
        .number_string => |x| .{ .num = std.fmt.parseFloat(f64, x) catch std.math.nan(f64) },
        .string => |x| .{ .str = x },
        .array => |l| blk: {
            var out = try Val.array(a);
            try out.arr.ensureTotalCapacity(a, l.items.len);
            for (l.items) |e| out.arr.appendAssumeCapacity(try fromJson(a, e));
            break :blk out;
        },
        .object => |o| blk: {
            const out = try Val.object(a);
            try out.obj.items.ensureTotalCapacity(a, o.count());
            var it = o.iterator();
            while (it.next()) |e| out.obj.items.appendAssumeCapacity(.{ .k = e.key_ptr.*, .v = try fromJson(a, e.value_ptr.*) });
            break :blk out;
        },
    };
}

/// `JSON.stringify(v)`
pub fn stringify(a: Allocator, v: Val) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try writeJson(&out.writer, v);
    return out.written();
}

pub fn writeJson(w: *std.Io.Writer, v: Val) std.Io.Writer.Error!void {
    switch (v) {
        .undef, .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .num => |x| {
            if (!std.math.isFinite(x)) return w.writeAll("null");
            var buf: [40]u8 = undefined;
            try w.writeAll(fmtNumBuf(&buf, x));
        },
        .str => |x| try writeString(w, x),
        .id => |x| try w.print("\"{s}\"", .{&x.toHex()}),
        .date => |ms| {
            var buf: [32]u8 = undefined;
            try w.print("\"{s}\"", .{isoDateBuf(&buf, ms)});
        },
        .arr => |l| {
            try w.writeByte('[');
            for (l.items, 0..) |e, i| {
                if (i > 0) try w.writeByte(',');
                try writeJson(w, e);
            }
            try w.writeByte(']');
        },
        .obj => |o| {
            try w.writeByte('{');
            var first = true;
            for (o.items.items) |kv| {
                if (kv.v == .undef) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try writeString(w, kv.k);
                try w.writeByte(':');
                try writeJson(w, kv.v);
            }
            try w.writeByte('}');
        },
        // A BSON Binary serializes as its base64 text (bson's Binary.toJSON).
        .bin => |x| {
            try w.writeByte('"');
            try std.base64.standard.Encoder.encodeWriter(w, x);
            try w.writeByte('"');
        },
        .regex => try w.writeAll("{}"),
        .raw => |x| switch (x) {
            .timestamp => |t| try w.print("{d}", .{t}),
            else => try w.writeAll("null"),
        },
    }
}

/// A JSON string as JSON.stringify writes it (non-ASCII left as is).
pub fn writeString(w: *std.Io.Writer, x: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (x, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (esc == null and c >= 0x20) continue;
        try w.writeAll(x[start..i]);
        if (esc) |e| try w.writeAll(e) else try w.print("\\u{x:0>4}", .{c});
        start = i + 1;
    }
    try w.writeAll(x[start..]);
    try w.writeByte('"');
}

// ---------------------------------------------------------------------------------------------
// BSON
// ---------------------------------------------------------------------------------------------

/// A BSON document as a Val, the way the Node driver reads it (int32, int64 and doubles become
/// numbers; dates, ids, binaries as themselves).
pub fn fromDoc(a: Allocator, d: bson.Doc) !Val {
    const out = try Val.object(a);
    var it = d.iterator();
    while (try it.next()) |e| try out.obj.items.append(a, .{ .k = e.key, .v = try fromBson(a, e.value) });
    return out;
}

pub fn fromBson(a: Allocator, v: bson.Value) error{ OutOfMemory, InvalidBson, UnsupportedBsonType }!Val {
    return switch (v) {
        .double => |x| .{ .num = x },
        .int32 => |x| .{ .num = @floatFromInt(x) },
        .int64 => |x| .{ .num = @floatFromInt(x) },
        .string => |x| .{ .str = x },
        .boolean => |x| .{ .bool = x },
        .null => .null,
        .object_id => |x| .{ .id = x },
        .datetime => |x| .{ .date = x.ms },
        .document => |x| try fromDoc(a, x),
        .array => |x| blk: {
            var out = try Val.array(a);
            var it = x.iterator();
            while (try it.next()) |e| try out.push(a, try fromBson(a, e.value));
            break :blk out;
        },
        .binary => |x| .{ .bin = x.data },
        .regex => |x| .{ .regex = .{ .pattern = x.pattern, .options = x.options } },
        .other => |t| if (t == .undefined) .undef else .{ .raw = v },
        else => .{ .raw = v },
    };
}

/// An object as a BSON document.
pub fn toDoc(a: Allocator, v: Val) !bson.Doc {
    var b = try bson.Builder.init(a);
    if (v == .obj) for (v.obj.items.items) |kv| try putBson(&b, kv.k, kv.v);
    return b.finish();
}

pub fn putBson(b: *bson.Builder, key: []const u8, v: Val) !void {
    switch (v) {
        .undef, .null => try b.null_(key),
        .bool => |x| try b.boolean(key, x),
        .num => |x| {
            // The Node driver: whole numbers in the int32 range are int32, everything else double.
            if (@floor(x) == x and x >= -2147483648 and x <= 2147483647) try b.int32(key, @intFromFloat(x)) else try b.double(key, x);
        },
        .str => |x| try b.string(key, x),
        .id => |x| try b.objectId(key, x),
        .date => |x| try b.datetime(key, .{ .ms = x }),
        .arr => |l| {
            try b.beginArray(key);
            for (l.items) |e| try putBson(b, "", e);
            try b.end();
        },
        .obj => |o| {
            try b.beginDoc(key);
            for (o.items.items) |kv| try putBson(b, kv.k, kv.v);
            try b.end();
        },
        .bin => |x| try b.binary(key, .{ .data = x }),
        .regex => |x| try b.value(key, .{ .regex = .{ .pattern = x.pattern, .options = x.options } }),
        .raw => |x| try b.value(key, x),
    }
}

// ---------------------------------------------------------------------------------------------
// Extended JSON (relaxed), as BSON's EJSON.serialize / deserialize write and read it
// ---------------------------------------------------------------------------------------------

/// EJSON.serialize(doc, { relaxed: true })
pub fn toEjson(a: Allocator, v: Val) !Val {
    return switch (v) {
        .id => |x| try from(a, .{ .@"$oid" = try a.dupe(u8, &x.toHex()) }),
        .date => |ms| if (ms >= 0 and ms <= 253402300799999)
            try from(a, .{ .@"$date" = try isoDate(a, ms) })
        else
            try from(a, .{ .@"$date" = .{ .@"$numberLong" = try std.fmt.allocPrint(a, "{d}", .{ms}) } }),
        .num => |x| if (std.math.isFinite(x)) v else try from(a, .{ .@"$numberDouble" = if (std.math.isNan(x)) "NaN" else if (x > 0) "Infinity" else "-Infinity" }),
        .bin => |x| blk: {
            const enc = try a.alloc(u8, std.base64.standard.Encoder.calcSize(x.len));
            _ = std.base64.standard.Encoder.encode(enc, x);
            break :blk try from(a, .{ .@"$binary" = .{ .base64 = enc, .subType = "00" } });
        },
        .regex => |x| try from(a, .{ .@"$regularExpression" = .{ .pattern = x.pattern, .options = x.options } }),
        .arr => |l| blk: {
            var out = try Val.array(a);
            for (l.items) |e| try out.push(a, if (e == .undef) .null else try toEjson(a, e));
            break :blk out;
        },
        .obj => |o| blk: {
            const out = try Val.object(a);
            for (o.items.items) |kv| {
                if (kv.v == .undef) continue;
                try out.obj.items.append(a, .{ .k = kv.k, .v = try toEjson(a, kv.v) });
            }
            break :blk out;
        },
        .raw => .null,
        else => v,
    };
}

/// EJSON.deserialize(value, { relaxed: true })
pub fn fromEjson(a: Allocator, v: Val) !Val {
    switch (v) {
        .arr => |l| {
            var out = try Val.array(a);
            for (l.items) |e| try out.push(a, try fromEjson(a, e));
            return out;
        },
        .obj => |o| {
            if (o.items.items.len >= 1 and o.items.items[0].k.len > 0 and o.items.items[0].k[0] == '$') {
                if (ejsonScalar(a, v)) |x| return x;
            }
            const out = try Val.object(a);
            for (o.items.items) |kv| try out.obj.items.append(a, .{ .k = kv.k, .v = try fromEjson(a, kv.v) });
            return out;
        },
        else => return v,
    }
}

fn ejsonScalar(a: Allocator, v: Val) ?Val {
    if (v.get("$oid").asStr()) |h| if (v.len() == 1) return if (ObjectId.parse(h)) |id| Val{ .id = id } else |_| null;
    const d = v.get("$date");
    if (d != .undef and v.len() == 1) {
        return switch (d) {
            .str => |t| if (parseDate(t)) |ms| Val{ .date = ms } else null,
            .num => |x| Val{ .date = @intFromFloat(x) },
            .obj => if (d.get("$numberLong").asStr()) |t| (if (std.fmt.parseInt(i64, t, 10)) |ms| Val{ .date = ms } else |_| null) else null,
            else => null,
        };
    }
    inline for (.{ "$numberInt", "$numberLong", "$numberDouble" }) |k| {
        if (v.get(k).asStr()) |t| if (v.len() == 1) {
            if (std.mem.eql(u8, t, "NaN")) return Val{ .num = std.math.nan(f64) };
            if (std.mem.eql(u8, t, "Infinity")) return Val{ .num = std.math.inf(f64) };
            if (std.mem.eql(u8, t, "-Infinity")) return Val{ .num = -std.math.inf(f64) };
            return Val{ .num = std.fmt.parseFloat(f64, t) catch return null };
        };
    }
    const b = v.get("$binary");
    if (b == .obj and v.len() == 1) {
        const text = b.get("base64").asStr() orelse return null;
        const out = a.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(text) catch return null) catch return null;
        std.base64.standard.Decoder.decode(out, text) catch return null;
        return Val{ .bin = out };
    }
    const re = v.get("$regularExpression");
    if (re == .obj and v.len() == 1) return Val{ .regex = .{ .pattern = re.get("pattern").asStr() orelse "", .options = re.get("options").asStr() orelse "" } };
    return null;
}

const testing = std.testing;

test "json round trip keeps order, drops undefined, formats like JS" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parseJson(a, "{\"b\":1,\"a\":[1.5,\"x\\n\",null,true],\"c\":{\"d\":1e21}}");
    try v.put(a, "u", .undef);
    try v.put(a, "b", Val.n(2));
    try testing.expectEqualStrings("{\"b\":2,\"a\":[1.5,\"x\\n\",null,true],\"c\":{\"d\":1e+21}}", try stringify(a, v));
    try testing.expectEqualStrings("2026-10-12T01:02:03.456Z", try isoDate(a, parseDate("2026-10-12T01:02:03.456Z").?));
    try testing.expectEqual(@as(i64, 0), parseDate("1970-01-01T00:00:00.000Z").?);
    try testing.expectEqualStrings("0.1", try fmtNum(a, 0.1));
    try testing.expectEqualStrings("-5", try fmtNum(a, -5));
}

test "bson and ejson" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = ObjectId.generateAt(testing.io, 1_700_000_000);
    const v = try from(a, .{ ._id = id, .n = 3, .f = 2.5, .at = Val{ .date = 1234 }, .tags = .{ "a", "b" }, .u = Val.undef });
    const d = try toDoc(a, v);
    try testing.expectEqual(@as(i32, 3), d.get("n").?.int32);
    try testing.expect(d.get("u").? == .null);
    const back = try fromDoc(a, d);
    try testing.expect(same(back.get("_id"), .{ .id = id }));
    const e = try toEjson(a, back);
    try testing.expectEqualStrings("1970-01-01T00:00:01.234Z", e.path("at.$date").asStr().?);
    const r = try fromEjson(a, try parseJson(a, try stringify(a, e)));
    try testing.expectEqual(@as(i64, 1234), r.get("at").date);
    try testing.expect(same(r.get("_id"), .{ .id = id }));
}

/// An empty, mutable list (where an `if` needs a `[]Val` on its other branch).
pub var none: [0]Val = .{};
