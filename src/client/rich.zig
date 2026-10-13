//! Message text with its entities (Reseal-js ui/markdown.js renderEntities), as far as zui text
//! goes today: one style per text run, no inline spans. So:
//!   - ```pre``` blocks and "> " quotes become their own boxes (mono on a tint; a bar beside),
//!   - a bold or `code` entity that covers a whole run sets that run's weight or font,
//!   - ||spoilers|| are hidden behind ░ until shown from the message menu,
//!   - inline bold/italic/underline/strike inside a line, and tappable links and @mentions, wait
//!     for zui rich text spans (the words show as plain text).

const std = @import("std");
const zui = @import("zui");
const kit = @import("ui.zig");
const markdown = @import("markdown.zig");

const Cx = kit.Cx;
const Color = zui.Color;
const Entity = markdown.Entity;

fn isBlock(e: Entity) bool {
    return std.mem.eql(u8, e.t, "pre") or std.mem.eql(u8, e.t, "quote");
}

pub fn hasSpoiler(entities: []const Entity) bool {
    for (entities) |e| if (std.mem.eql(u8, e.t, "spoiler")) return true;
    return false;
}

pub fn text(cx: Cx, txt: []const u8, entities: []const Entity, fg: Color, revealed: bool) void {
    const a = cx.a();
    const shown = if (revealed) txt else hideSpoilers(a, txt, entities);
    if (entities.len == 0) return run(cx, shown, fg, .{});
    // Block entities in order of offset (they do not overlap one another).
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
        if (b.o > pos) plainRun(cx, shown, entities, pos, b.o, fg);
        const s = markdown.byteAt(shown, b.o);
        const e = markdown.byteAt(shown, b.o + b.l);
        const body = std.mem.trim(u8, shown[s..e], "\n");
        if (std.mem.eql(u8, b.t, "pre")) {
            cx.ui.begin(.{ .padding = .xy(10, 8), .radius = 10, .background = fg.withAlpha(0.08), .width = .fill }, .{});
            if (b.lang) |lang| if (lang.len > 0) cx.ui.text(lang, .{ .font_size = 11.5, .weight = 700, .color = fg, .opacity = 0.65 });
            cx.ui.text(body, .{ .font_size = cx.fs - 1, .mono = true, .color = fg, .line_height = 1.45 });
            cx.ui.end();
        } else {
            cx.ui.begin(.{ .direction = .row, .gap = 8 }, .{});
            cx.ui.begin(.{ .width = .{ .px = 3 }, .radius = 2, .background = fg.withAlpha(0.5) }, .{});
            cx.ui.end();
            cx.ui.text(body, .{ .font_size = cx.fs + 0.5, .color = fg, .opacity = 0.9, .line_height = 1.45, .grow = 1, .width = .fill });
            cx.ui.end();
        }
        pos = b.o + b.l;
    }
    const end = markdown.u16len(shown);
    if (pos < end) plainRun(cx, shown, entities, pos, end, fg);
}

const RunStyle = struct { bold: bool = false, mono: bool = false };

/// The text between blocks: styled when one entity covers all of it.
fn plainRun(cx: Cx, txt: []const u8, entities: []const Entity, from: usize, to: usize, fg: Color) void {
    var s = markdown.byteAt(txt, from);
    var e = markdown.byteAt(txt, to);
    // Lines next to a block lose their joining line break.
    while (s < e and txt[s] == '\n') s += 1;
    while (e > s and txt[e - 1] == '\n') e -= 1;
    if (s >= e) return;
    var st: RunStyle = .{};
    for (entities) |en| {
        if (en.o > from or en.o + en.l < to) continue;
        if (std.mem.eql(u8, en.t, "bold")) st.bold = true;
        if (std.mem.eql(u8, en.t, "code")) st.mono = true;
    }
    run(cx, txt[s..e], fg, st);
}

fn run(cx: Cx, s: []const u8, fg: Color, st: RunStyle) void {
    cx.ui.text(s, .{ .font_size = if (st.mono) cx.fs - 0.5 else cx.fs + 0.5, .weight = if (st.bold) 700 else 400, .mono = st.mono, .color = fg, .line_height = 1.45 });
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
        // One ░ per UTF-16 unit, so the entities' offsets still fit.
        if (hidden and txt[i] != '\n') {
            for (0..w) |_| out.appendSlice(a, "░") catch {};
        } else out.appendSlice(a, txt[i..end]) catch {};
        i = end;
        u += w;
    }
    return out.items;
}

test "spoilers hidden, blocks kept apart" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const p = try markdown.parse(arena.allocator(), "see ||secret|| now");
    const hidden = hideSpoilers(arena.allocator(), p.text, p.entities);
    try std.testing.expectEqualStrings("see ░░░░░░ now", hidden);
}
