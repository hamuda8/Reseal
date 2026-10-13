//! The composer's markdown-like input to text + entities and back (Reseal-js core/format.js
//! parseMarkdown, toMarkdown, firstUrl). Offsets and lengths are in UTF-16 code units, as the
//! web app's (JavaScript string) entities are, so both apps format each other's messages alike.
//!
//! **bold**, __italic__, ~~strike~~, ++underline++, ||spoiler||, `code`, ```lang\npre```,
//! [label](https://url) and "> " quote lines.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entity = struct {
    t: []const u8,
    o: usize,
    l: usize,
    url: ?[]const u8 = null,
    lang: ?[]const u8 = null,
};

pub const Parsed = struct { text: []const u8, entities: []Entity };

/// UTF-16 length of UTF-8 text.
pub fn u16len(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return n;
}

/// The byte index of UTF-16 offset `o` in `s` (clamped).
pub fn byteAt(s: []const u8, o: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < o) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return @min(i, s.len);
}

const Rule = struct { open: []const u8, close: []const u8, t: []const u8, multiline: bool = false };
const rules = [_]Rule{
    .{ .open = "```", .close = "```", .t = "pre", .multiline = true },
    .{ .open = "`", .close = "`", .t = "code" },
    .{ .open = "**", .close = "**", .t = "bold" },
    .{ .open = "__", .close = "__", .t = "italic" },
    .{ .open = "~~", .close = "~~", .t = "strike" },
    .{ .open = "||", .close = "||", .t = "spoiler" },
    .{ .open = "++", .close = "++", .t = "underline" },
};

const Builder = struct {
    a: Allocator,
    text: std.ArrayList(u8) = .empty,
    entities: std.ArrayList(Entity) = .empty,

    fn pos(b: *const Builder) usize {
        return u16len(b.text.items);
    }
};

fn isLangChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '#' or c == '.' or c == '-';
}

fn parseInline(a: Allocator, src: []const u8) !Parsed {
    var b: Builder = .{ .a = a };
    var i: usize = 0;
    outer: while (i < src.len) {
        // [label](https://url)
        if (src[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, src, i + 1, ']')) |close| {
                const label = src[i + 1 .. close];
                if (label.len > 0 and label.len <= 200 and std.mem.indexOfScalar(u8, label, '\n') == null and close + 1 < src.len and src[close + 1] == '(') {
                    const rest = src[close + 2 ..];
                    if (std.mem.startsWith(u8, rest, "http://") or std.mem.startsWith(u8, rest, "https://")) {
                        var e: usize = 0;
                        while (e < rest.len and rest[e] != ')' and !std.ascii.isWhitespace(rest[e])) e += 1;
                        if (e < rest.len and rest[e] == ')' and e <= 2000) {
                            try b.entities.append(a, .{ .t = "textlink", .o = b.pos(), .l = u16len(label), .url = rest[0..e] });
                            try b.text.appendSlice(a, label);
                            i = close + 2 + e + 1;
                            continue;
                        }
                    }
                }
            }
        }
        for (rules) |r| {
            if (!std.mem.startsWith(u8, src[i..], r.open)) continue;
            const end = std.mem.indexOfPos(u8, src, i + r.open.len, r.close) orelse continue;
            if (end <= i + r.open.len) continue;
            if (!r.multiline and std.mem.indexOfScalar(u8, src[i..end], '\n') != null) continue;
            var inner = src[i + r.open.len .. end];
            var lang: ?[]const u8 = null;
            if (std.mem.eql(u8, r.t, "pre")) {
                if (std.mem.indexOfScalar(u8, inner, '\n')) |nl| {
                    const first = std.mem.trim(u8, inner[0..nl], " \t\r");
                    var ok = first.len > 0 and first.len <= 20;
                    for (first) |c| if (!isLangChar(c)) {
                        ok = false;
                    };
                    if (ok) {
                        lang = first;
                        inner = inner[nl + 1 ..];
                    } else if (inner[0] == '\n') inner = inner[1..];
                }
                if (inner.len > 0 and inner[inner.len - 1] == '\n') inner = inner[0 .. inner.len - 1];
            }
            if (inner.len == 0) continue;
            const start = b.pos();
            const nested: Parsed = if (std.mem.eql(u8, r.t, "code") or std.mem.eql(u8, r.t, "pre")) .{ .text = inner, .entities = &.{} } else try parseInline(a, inner);
            for (nested.entities) |e| {
                var x = e;
                x.o += start;
                try b.entities.append(a, x);
            }
            try b.entities.append(a, .{ .t = r.t, .o = start, .l = u16len(nested.text), .lang = lang });
            try b.text.appendSlice(a, nested.text);
            i = end + r.close.len;
            continue :outer;
        }
        try b.text.append(a, src[i]);
        i += 1;
    }
    return .{ .text = b.text.items, .entities = b.entities.items };
}

pub fn parse(a: Allocator, input: []const u8) !Parsed {
    // Quote blocks ("> " lines outside code fences), then inline formatting in each block.
    const Seg = struct { quote: bool, lines: std.ArrayList([]const u8) = .empty };
    var segs: std.ArrayList(Seg) = .empty;
    var fence = false;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        const is_quote = !fence and std.mem.startsWith(u8, line, "> ");
        if (std.mem.count(u8, line, "```") % 2 == 1) fence = !fence;
        const content = if (is_quote) line[2..] else line;
        if (segs.items.len > 0 and segs.items[segs.items.len - 1].quote == is_quote) {
            try segs.items[segs.items.len - 1].lines.append(a, content);
        } else {
            var s: Seg = .{ .quote = is_quote };
            try s.lines.append(a, content);
            try segs.append(a, s);
        }
    }
    var b: Builder = .{ .a = a };
    for (segs.items, 0..) |seg, idx| {
        const joined = try std.mem.join(a, "\n", seg.lines.items);
        const r = try parseInline(a, joined);
        const start = b.pos();
        for (r.entities) |e| {
            var x = e;
            x.o += start;
            try b.entities.append(a, x);
        }
        if (seg.quote and r.text.len > 0) try b.entities.append(a, .{ .t = "quote", .o = start, .l = u16len(r.text) });
        try b.text.appendSlice(a, r.text);
        if (idx < segs.items.len - 1) try b.text.append(a, '\n');
    }
    const total = b.pos();
    var keep: std.ArrayList(Entity) = .empty;
    for (b.entities.items) |e| if (e.l > 0 and e.o + e.l <= total) try keep.append(a, e);
    return .{ .text = b.text.items, .entities = keep.items };
}

/// Entities as the JSON the server and the payload carry ([{"t","o","l",...}]).
pub fn entitiesJson(a: Allocator, entities: []const Entity) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (entities, 0..) |e, i| {
        if (i > 0) try out.append(a, ',');
        try out.print(a, "{{\"t\":\"{s}\",\"o\":{d},\"l\":{d}", .{ e.t, e.o, e.l });
        if (e.url) |u| try out.print(a, ",\"url\":{f}", .{std.json.fmt(u, .{})});
        if (e.lang) |l| try out.print(a, ",\"lang\":{f}", .{std.json.fmt(l, .{})});
        try out.append(a, '}');
    }
    try out.append(a, ']');
    return out.items;
}

const Insert = struct { at: usize, s: []const u8, open: bool, len: usize };

/// Text + entities back to the composer's markdown (for editing).
/// Entities from a message's JSON (skipping malformed ones).
pub fn fromJson(a: Allocator, v: ?std.json.Value) []Entity {
    var out: std.ArrayList(Entity) = .empty;
    const arr = v orelse return out.items;
    if (arr != .array) return out.items;
    for (arr.array.items) |e| {
        if (e != .object) continue;
        const ty = e.object.get("t") orelse e.object.get("type") orelse continue;
        const off = e.object.get("o") orelse e.object.get("offset") orelse continue;
        const len = e.object.get("l") orelse e.object.get("length") orelse continue;
        if (ty != .string or off != .integer or len != .integer or off.integer < 0 or len.integer <= 0) continue;
        const url = e.object.get("url");
        const lang = e.object.get("lang");
        out.append(a, .{
            .t = ty.string,
            .o = @intCast(off.integer),
            .l = @intCast(len.integer),
            .url = if (url != null and url.? == .string) url.?.string else null,
            .lang = if (lang != null and lang.? == .string) lang.?.string else null,
        }) catch {};
    }
    return out.items;
}

pub fn toMarkdown(a: Allocator, text: []const u8, entities: []const Entity) ![]const u8 {
    var ins: std.ArrayList(Insert) = .empty;
    const marks = [_][2][]const u8{ .{ "bold", "**" }, .{ "italic", "__" }, .{ "strike", "~~" }, .{ "code", "`" }, .{ "spoiler", "||" }, .{ "underline", "++" } };
    for (entities) |e| {
        var done = false;
        for (marks) |m| if (std.mem.eql(u8, e.t, m[0])) {
            try ins.append(a, .{ .at = e.o, .s = m[1], .open = true, .len = e.l });
            try ins.append(a, .{ .at = e.o + e.l, .s = m[1], .open = false, .len = e.l });
            done = true;
        };
        if (done) continue;
        if (std.mem.eql(u8, e.t, "pre")) {
            try ins.append(a, .{ .at = e.o, .s = try std.fmt.allocPrint(a, "```{s}\n", .{e.lang orelse ""}), .open = true, .len = e.l });
            try ins.append(a, .{ .at = e.o + e.l, .s = "\n```", .open = false, .len = e.l });
        } else if (std.mem.eql(u8, e.t, "textlink")) {
            try ins.append(a, .{ .at = e.o, .s = "[", .open = true, .len = e.l });
            try ins.append(a, .{ .at = e.o + e.l, .s = try std.fmt.allocPrint(a, "]({s})", .{e.url orelse ""}), .open = false, .len = e.l });
        } else if (std.mem.eql(u8, e.t, "quote")) {
            // "> " at the start of every line of the quote.
            var o = e.o;
            const start_b = byteAt(text, e.o);
            const end_b = byteAt(text, e.o + e.l);
            var bi = start_b;
            while (bi < end_b) : (bi += 1) {
                if (bi == start_b or text[bi - 1] == '\n') {
                    o = u16len(text[0..bi]);
                    try ins.append(a, .{ .at = o, .s = "> ", .open = true, .len = std.math.maxInt(usize) });
                }
            }
        }
    }
    std.mem.sort(Insert, ins.items, {}, struct {
        fn lt(_: void, x: Insert, y: Insert) bool {
            if (x.at != y.at) return x.at > y.at;
            if (x.open == y.open) return if (x.open) x.len < y.len else x.len > y.len;
            return x.open;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, text);
    for (ins.items) |x| {
        const at = byteAt(out.items, x.at);
        try out.insertSlice(a, at, x.s);
    }
    return out.items;
}

/// The first link (a text link's address, else a bare http(s):// or www. address).
pub fn firstUrl(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const rest = text[i..];
        const www = std.ascii.startsWithIgnoreCase(rest, "www.");
        if (!(std.ascii.startsWithIgnoreCase(rest, "https://") or std.ascii.startsWithIgnoreCase(rest, "http://") or www)) continue;
        if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]))) continue;
        var e: usize = 0;
        while (e < rest.len and !std.ascii.isWhitespace(rest[e]) and rest[e] != '<' and rest[e] != '>' and rest[e] != '"' and rest[e] != '\'') e += 1;
        while (e > 0 and std.mem.indexOfScalar(u8, ".,;:!?)]}", rest[e - 1]) != null) e -= 1;
        if (e > 8) return rest[0..e];
    }
    return null;
}

/// @usernames written in the text.
pub fn usernames(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '@') continue;
        if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_' or text[i - 1] == '@')) continue;
        var e = i + 1;
        while (e < text.len and (std.ascii.isAlphanumeric(text[e]) or text[e] == '_')) e += 1;
        const name = text[i + 1 .. e];
        if (name.len >= 4 and name.len <= 32 and std.ascii.isAlphabetic(name[0])) try out.append(a, name);
        i = e;
    }
    return out.items;
}

test "markdown both ways" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, "Hi **bold** and __it__ [site](https://x.dev)\n> quoted 👋\n```zig\nconst x = 1;\n```");
    try std.testing.expectEqualStrings("Hi bold and it site\nquoted 👋\nconst x = 1;", p.text);
    try std.testing.expectEqual(@as(usize, 5), p.entities.len);
    try std.testing.expectEqualStrings("bold", p.entities[0].t);
    try std.testing.expectEqual(@as(usize, 3), p.entities[0].o);
    try std.testing.expectEqual(@as(usize, 4), p.entities[0].l);
    const md = try toMarkdown(a, p.text, p.entities);
    const again = try parse(a, md);
    try std.testing.expectEqualStrings(p.text, again.text);
    try std.testing.expectEqual(p.entities.len, again.entities.len);
    try std.testing.expectEqualStrings("https://x.dev", firstUrl("see https://x.dev, ok").?);
    try std.testing.expectEqual(@as(usize, 2), u16len("👋"));
    const names = try usernames(a, "hey @alice and @bob_1x, mail a@b.c");
    try std.testing.expectEqual(@as(usize, 2), names.len);
}
