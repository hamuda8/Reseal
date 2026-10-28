//! Message text with its entities (Reseal-js ui/markdown.js renderEntities): bold, italic,
//! underline, strike, `code`, links and @mentions as runs of one zui rich text; ```pre``` blocks
//! and "> " quotes as their own boxes; ||spoilers|| hidden behind ░ until shown from the message
//! menu. Plain web addresses and @usernames become links too. A link sends `.rich_link` with the
//! message and the byte where the link starts; views.zig opens what is there.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const kit = @import("ui.zig");
const markdown = @import("markdown.zig");

const Cx = kit.Cx;
const Color = zui.Color;
const Entity = markdown.Entity;
const Span = kit.Ui.Span;
const Id = app.Id;

fn isBlock(e: Entity) bool {
    return std.mem.eql(u8, e.t, "pre") or std.mem.eql(u8, e.t, "quote");
}

pub fn hasSpoiler(entities: []const Entity) bool {
    for (entities) |e| if (std.mem.eql(u8, e.t, "spoiler")) return true;
    return false;
}

pub const Opts = struct {
    fg: Color,
    link: Color,
    revealed: bool = false,
    /// The message the links belong to ("" for none: no links).
    msg: []const u8 = "",
    font_size: f32,
    /// An assistant's Markdown: which of the reply's texts this is (its links say so).
    unit: ?u16 = null,
};

pub fn text(cx: Cx, txt: []const u8, entities: []const Entity, o: Opts) void {
    const a = cx.a();
    const shown = if (o.revealed) txt else hideSpoilers(a, txt, entities);
    var blocks: std.ArrayList(Entity) = .empty;
    for (entities) |e| if (isBlock(e)) blocks.append(a, e) catch {};
    std.mem.sort(Entity, blocks.items, {}, struct {
        fn lt(_: void, x: Entity, y: Entity) bool {
            return x.o < y.o;
        }
    }.lt);
    var pos: usize = 0; // UTF-16
    for (blocks.items) |b| {
        if (b.o < pos) continue;
        if (b.o > pos) run(cx, shown, entities, pos, b.o, o, false);
        if (std.mem.eql(u8, b.t, "pre")) {
            const s = markdown.byteAt(shown, b.o);
            const e = markdown.byteAt(shown, b.o + b.l);
            cx.ui.begin(.{ .padding = .xy(10, 8), .radius = 10, .background = o.fg.withAlpha(0.08), .width = .fill }, .{});
            if (b.lang) |lang| if (lang.len > 0) cx.ui.text(lang, .{ .font_size = 12, .weight = 700, .color = o.fg, .opacity = 0.65 });
            cx.ui.textWith(std.mem.trim(u8, shown[s..e], "\n"), .{ .font_size = o.font_size - 1.5, .mono = true, .color = o.fg, .line_height = 1.45 }, .{ .selectable = true });
            cx.ui.end();
        } else {
            cx.ui.begin(.{ .direction = .row, .gap = 8 }, .{});
            cx.ui.begin(.{ .width = .{ .px = 3 }, .radius = 2, .background = o.fg.withAlpha(0.5) }, .{});
            cx.ui.end();
            cx.ui.begin(.{ .grow = 1, .width = .fill, .opacity = 0.9 }, .{});
            run(cx, shown, entities, b.o, b.o + b.l, o, true);
            cx.ui.end();
            cx.ui.end();
        }
        pos = b.o + b.l;
    }
    const end = markdown.u16len(shown);
    if (pos < end) run(cx, shown, entities, pos, end, o, false);
}

/// Where plain addresses and @usernames are (byte ranges).
const Auto = struct { s: usize, e: usize };

fn autoLinks(a: std.mem.Allocator, txt: []const u8, from: usize, to: usize) []Auto {
    var out: std.ArrayList(Auto) = .empty;
    var i = from;
    while (i < to) {
        const word_start = i == 0 or std.ascii.isWhitespace(txt[i - 1]) or txt[i - 1] == '(';
        if (word_start and (std.mem.startsWith(u8, txt[i..to], "https://") or std.mem.startsWith(u8, txt[i..to], "http://"))) {
            var e = i;
            while (e < to and !std.ascii.isWhitespace(txt[e])) e += 1;
            while (e > i and std.mem.indexOfScalar(u8, ".,!?;:)\"'", txt[e - 1]) != null) e -= 1;
            out.append(a, .{ .s = i, .e = e }) catch {};
            i = e;
            continue;
        }
        // #hashtags (they open the chat's search).
        if (word_start and txt[i] == '#' and i + 1 < to and (std.ascii.isAlphabetic(txt[i + 1]) or txt[i + 1] >= 0x80)) {
            var e = i + 1;
            while (e < to and (std.ascii.isAlphanumeric(txt[e]) or txt[e] == '_' or txt[e] >= 0x80)) e += 1;
            out.append(a, .{ .s = i, .e = e }) catch {};
            i = e;
            continue;
        }
        if (word_start and txt[i] == '@' and i + 1 < to) {
            var e = i + 1;
            while (e < to and (std.ascii.isAlphanumeric(txt[e]) or txt[e] == '_')) e += 1;
            if (e - i >= 4) {
                out.append(a, .{ .s = i, .e = e }) catch {};
                i = e;
                continue;
            }
        }
        i += 1;
    }
    return out.items;
}

/// One rich text for [from, to) (UTF-16 offsets): runs split where entities start and end.
fn run(cx: Cx, txt: []const u8, entities: []const Entity, from: usize, to: usize, o: Opts, in_quote: bool) void {
    const a = cx.a();
    var s = markdown.byteAt(txt, from);
    var e = markdown.byteAt(txt, to);
    // Lines next to a block lose their joining line break.
    while (s < e and txt[s] == '\n') s += 1;
    while (e > s and txt[e - 1] == '\n') e -= 1;
    if (s >= e) return;
    // Entity ranges in bytes (inline ones).
    const Range = struct { s: usize, e: usize, ent: Entity };
    var ranges: std.ArrayList(Range) = .empty;
    for (entities) |en| {
        if (isBlock(en)) continue;
        const bs = markdown.byteAt(txt, en.o);
        const be = markdown.byteAt(txt, en.o + en.l);
        if (be <= s or bs >= e) continue;
        ranges.append(a, .{ .s = @max(bs, s), .e = @min(be, e), .ent = en }) catch {};
    }
    const autos = if (o.msg.len > 0) autoLinks(a, txt, s, e) else &.{};
    // Cut points.
    var cuts: std.ArrayList(usize) = .empty;
    cuts.append(a, s) catch {};
    cuts.append(a, e) catch {};
    for (ranges.items) |r| {
        cuts.append(a, r.s) catch {};
        cuts.append(a, r.e) catch {};
    }
    for (autos) |r| {
        cuts.append(a, r.s) catch {};
        cuts.append(a, r.e) catch {};
    }
    std.mem.sort(usize, cuts.items, {}, std.sort.asc(usize));
    var spans: std.ArrayList(Span) = .empty;
    var prev: usize = s;
    for (cuts.items) |c| {
        if (c <= prev) continue;
        var sp: Span = .{ .text = txt[prev..c] };
        var link_at: ?usize = null;
        for (ranges.items) |r| if (r.s <= prev and r.e >= c) {
            const ty = r.ent.t;
            if (std.mem.eql(u8, ty, "bold")) sp.bold = true;
            if (std.mem.eql(u8, ty, "italic")) sp.italic = true;
            if (std.mem.eql(u8, ty, "underline")) sp.underline = true;
            if (std.mem.eql(u8, ty, "strike")) sp.strike = true;
            if (std.mem.eql(u8, ty, "code")) {
                sp.mono = true;
                // A tap copies inline code.
                if (link_at == null) link_at = r.s;
            }
            if (std.mem.eql(u8, ty, "textlink") or std.mem.eql(u8, ty, "url") or std.mem.eql(u8, ty, "mention")) link_at = r.s;
        };
        for (autos) |r| if (r.s <= prev and r.e >= c and link_at == null) {
            link_at = r.s;
        };
        if (link_at) |at| if (o.msg.len > 0) {
            sp.link = if (o.unit) |u| .{ .ai = .{ .link = .{ .msg = Id.of(o.msg), .unit = u, .at = @intCast(at) } } } else .{ .rich_link = .{ .msg = Id.of(o.msg), .at = @intCast(at) } };
            sp.color = o.link;
            sp.underline = true;
        };
        spans.append(a, sp) catch {};
        prev = c;
    }
    _ = in_quote;
    cx.ui.richText(spans.items, .{ .font_size = o.font_size, .color = o.fg, .line_height = 1.45 }, .{});
}

/// What a link at byte `at` of a message's text points to.
pub const Target = union(enum) { url: []const u8, username: []const u8, hashtag: []const u8, code: []const u8, none };

pub fn linkAt(txt: []const u8, entities: []const Entity, at: usize) Target {
    for (entities) |en| {
        if (markdown.byteAt(txt, en.o) != at) continue;
        if (std.mem.eql(u8, en.t, "textlink")) if (en.url) |u| return .{ .url = u };
    }
    for (entities) |en| {
        if (markdown.byteAt(txt, en.o) != at or !std.mem.eql(u8, en.t, "code")) continue;
        return .{ .code = txt[at..markdown.byteAt(txt, en.o + en.l)] };
    }
    if (at >= txt.len) return .none;
    const rest = txt[at..];
    if (std.mem.startsWith(u8, rest, "http://") or std.mem.startsWith(u8, rest, "https://")) {
        var e: usize = 0;
        while (e < rest.len and !std.ascii.isWhitespace(rest[e])) e += 1;
        while (e > 0 and std.mem.indexOfScalar(u8, ".,!?;:)\"'", rest[e - 1]) != null) e -= 1;
        return .{ .url = rest[0..e] };
    }
    if (rest[0] == '#') {
        var e: usize = 1;
        while (e < rest.len and (std.ascii.isAlphanumeric(rest[e]) or rest[e] == '_' or rest[e] >= 0x80)) e += 1;
        return .{ .hashtag = rest[0..e] };
    }
    if (rest[0] == '@') {
        var e: usize = 1;
        while (e < rest.len and (std.ascii.isAlphanumeric(rest[e]) or rest[e] == '_')) e += 1;
        return .{ .username = rest[1..e] };
    }
    return .none;
}

/// The text with spoiler ranges replaced by ░ (one per UTF-16 unit; line breaks kept).
pub fn hideSpoilers(a: std.mem.Allocator, txt: []const u8, entities: []const Entity) []const u8 {
    if (!hasSpoiler(entities)) return txt;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var u: usize = 0; // UTF-16 position
    while (i < txt.len) {
        const len = std.unicode.utf8ByteSequenceLength(txt[i]) catch 1;
        const w: usize = if (len == 4) 2 else 1;
        const hidden = for (entities) |e| {
            if (std.mem.eql(u8, e.t, "spoiler") and u >= e.o and u < e.o + e.l) break true;
        } else false;
        const end = @min(i + len, txt.len);
        // One ░ per UTF-16 unit, so the entities' offsets still fit... but ░ is 3 bytes: byte
        // offsets after it move, so callers use UTF-16 offsets (byteAt) on the shown text.
        if (hidden and txt[i] != '\n') {
            for (0..w) |_| out.appendSlice(a, "░") catch {};
        } else out.appendSlice(a, txt[i..end]) catch {};
        i = end;
        u += w;
    }
    return out.items;
}

test "spoilers hidden" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try markdown.parse(arena.allocator(), "see ||secret|| now");
    try std.testing.expectEqualStrings("see ░░░░░░ now", hideSpoilers(arena.allocator(), p.text, p.entities));
}

test "links in text" {
    try std.testing.expectEqualStrings("https://x.dev/a", linkAt("see https://x.dev/a, ok", &.{}, 4).url);
    try std.testing.expectEqualStrings("carol", linkAt("hi @carol!", &.{}, 3).username);
}
