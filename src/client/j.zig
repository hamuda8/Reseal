//! Small helpers for the server's JSON: reading fields of std.json.Value objects, copying values
//! into an owner's memory, merging objects (like JS Object.assign) and writing JSON text.

const std = @import("std");
pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;
const Allocator = std.mem.Allocator;

pub fn parse(a: Allocator, text: []const u8) ?Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always }) catch null;
}

pub fn field(v: ?Value, key: []const u8) ?Value {
    const o = v orelse return null;
    if (o != .object) return null;
    const x = o.object.get(key) orelse return null;
    if (x == .null) return null;
    return x;
}

/// `v.a.b.c` for a path "a.b.c".
pub fn path(v: ?Value, p: []const u8) ?Value {
    var cur = v;
    var it = std.mem.splitScalar(u8, p, '.');
    while (it.next()) |k| cur = field(cur, k);
    return cur;
}

pub fn str(v: ?Value, key: []const u8) ?[]const u8 {
    const x = path(v, key) orelse return null;
    return switch (x) {
        .string => |s| s,
        .number_string => |s| s,
        else => null,
    };
}

pub fn strOr(v: ?Value, key: []const u8, d: []const u8) []const u8 {
    return str(v, key) orelse d;
}

pub fn int(v: ?Value, key: []const u8) ?i64 {
    const x = path(v, key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(f) else null,
        .bool => |b| @intFromBool(b),
        else => null,
    };
}

pub fn intOr(v: ?Value, key: []const u8, d: i64) i64 {
    return int(v, key) orelse d;
}

pub fn float(v: ?Value, key: []const u8) ?f64 {
    const x = path(v, key) orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

pub fn floatOr(v: ?Value, key: []const u8, d: f64) f64 {
    return float(v, key) orelse d;
}

/// JS truthiness for the usual fields (true, non-zero, non-empty string, any object).
pub fn truthy(v: ?Value, key: []const u8) bool {
    const x = path(v, key) orelse return false;
    return switch (x) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        .string => |s| s.len > 0,
        else => true,
    };
}

pub fn arr(v: ?Value, key: []const u8) []Value {
    const x = path(v, key) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

pub fn obj(v: ?Value, key: []const u8) ?Value {
    const x = path(v, key) orelse return null;
    return if (x == .object) x else null;
}

pub fn eqlStr(v: ?Value, key: []const u8, s: []const u8) bool {
    return std.mem.eql(u8, str(v, key) orelse return false, s);
}

/// A deep copy of `v` in `a`.
pub fn clone(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |l| blk: {
            var out = std.json.Array.init(a);
            try out.ensureTotalCapacity(l.items.len);
            for (l.items) |x| out.appendAssumeCapacity(try clone(a, x));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out: ObjectMap = .empty;
            try out.ensureTotalCapacity(a, o.count());
            var it = o.iterator();
            while (it.next()) |e| out.putAssumeCapacity(try a.dupe(u8, e.key_ptr.*), try clone(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
    };
}

/// Object.assign(dst, src) with the values copied into `a` (dst's owner).
pub fn assign(a: Allocator, dst: *ObjectMap, src: Value) Allocator.Error!void {
    if (src != .object) return;
    var it = src.object.iterator();
    while (it.next()) |e| try dst.put(a, try a.dupe(u8, e.key_ptr.*), try clone(a, e.value_ptr.*));
}

pub fn emptyObject() Value {
    return .{ .object = .empty };
}

pub fn stringify(a: Allocator, v: anytype) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{}) catch return error.OutOfMemory;
}

/// `s` as a JSON string literal (with the quotes).
pub fn quote(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    return stringify(a, s);
}

/// Percent-encoding for URL parts (RFC 3986 unreserved characters stay).
pub fn urlEncode(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(a, ch);
        } else try out.print(a, "%{X:0>2}", .{ch});
    }
    return out.items;
}

/// The value of `name` in a query string ("a=1&b=2"), percent-decoded, or null.
pub fn queryParam(a: Allocator, query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        const raw = if (eq < pair.len) pair[eq + 1 ..] else "";
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '%' and i + 2 < raw.len) {
                const b = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch {
                    out.append(a, raw[i]) catch return null;
                    continue;
                };
                out.append(a, b) catch return null;
                i += 2;
            } else out.append(a, if (raw[i] == '+') ' ' else raw[i]) catch return null;
        }
        return out.items;
    }
    return null;
}

test "fields, assign, query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = parse(a, "{\"a\":{\"b\":3,\"s\":\"x\"},\"n\":null,\"t\":true}").?;
    try std.testing.expectEqual(@as(i64, 3), int(v, "a.b").?);
    try std.testing.expectEqualStrings("x", str(v, "a.s").?);
    try std.testing.expect(field(v, "n") == null);
    try std.testing.expect(truthy(v, "t"));
    try assign(a, &v.object, parse(a, "{\"t\":false,\"z\":1}").?);
    try std.testing.expect(!truthy(v, "t"));
    try std.testing.expectEqualStrings("a b/c", queryParam(a, "x=1&pk=a+b%2Fc", "pk").?);
}
