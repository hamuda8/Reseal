//! Assistants' replies as Markdown (Reseal-js markdown.js): headings, rules, tables, quotes,
//! lists, paragraphs and code blocks with Copy; inline **bold**, *italic*, `code`, ~~strike~~,
//! [links](https://…) and bare URLs, drawn with rich text. It tolerates unfinished input while a
//! reply streams. Under the reply: Stop while it streams, else Copy and (the latest) Regenerate.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const icons = @import("icons.zig");
const kit = @import("ui.zig");
const rich = @import("rich.zig");
const markdown = @import("markdown.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const Color = zui.Color;
const Entity = markdown.Entity;
const t = zui.i18n.t;
const tmp = app.tmp;
const key = kit.key;
const Allocator = std.mem.Allocator;

pub const Act = union(enum) {
    copy_code: struct { msg: Id, block: u16 },
    copy: Id,
    stop: Id,
    regenerate: Id,
    link: struct { msg: Id, unit: u16, at: u32 },
};

fn msgOf(a: Act) Msg {
    return .{ .ai = a };
}

/// A reply from an assistant (rendered as Markdown).
pub fn isAi(s: *const State, c: *const data.Chat, m: *const data.Message) bool {
    if (j.truthy(m.o.v, "bot")) return true;
    return c.is("bot") and !s.store.isMe(m.authorId()) and m.authorId().len > 0;
}

// ---------------------------------------------------------------------------------------------
// Inline

const Inline = struct { text: []const u8, entities: []Entity };

fn startsAt(s: []const u8, i: usize, p: []const u8) bool {
    return std.mem.startsWith(u8, s[i..], p);
}

/// Inline Markdown into text and entities (UTF-16 offsets, as message entities).
pub fn inlineOf(a: Allocator, src: []const u8) Inline {
    var out: std.ArrayList(u8) = .empty;
    var ents: std.ArrayList(Entity) = .empty;
    walk(a, src, &out, &ents);
    return .{ .text = out.items, .entities = ents.items };
}

fn walk(a: Allocator, src: []const u8, out: *std.ArrayList(u8), ents: *std.ArrayList(Entity)) void {
    var i: usize = 0;
    while (i < src.len) {
        // Pairs: ** __ ~~ ` * _
        const pairs = [_]struct { open: []const u8, ty: []const u8 }{
            .{ .open = "**", .ty = "bold" },
            .{ .open = "__", .ty = "bold" },
            .{ .open = "~~", .ty = "strike" },
            .{ .open = "`", .ty = "code" },
            .{ .open = "*", .ty = "italic" },
            .{ .open = "_", .ty = "italic" },
        };
        var done = false;
        for (pairs) |p| {
            if (!startsAt(src, i, p.open)) continue;
            const body_start = i + p.open.len;
            if (body_start >= src.len) break;
            // Single * and _ must not open on a space (a list marker or arithmetic).
            if (p.open.len == 1 and p.open[0] != '`' and std.ascii.isWhitespace(src[body_start])) break;
            // _ inside words (snake_case) is not emphasis.
            if (p.open[0] == '_' and i > 0 and std.ascii.isAlphanumeric(src[i - 1])) break;
            const close = std.mem.indexOfPos(u8, src, body_start, p.open) orelse break;
            if (close == body_start) break;
            const inner = src[body_start..close];
            if (std.mem.indexOfScalar(u8, inner, '\n') != null and p.open[0] != '`') break;
            const o = markdown.u16len(out.items);
            if (std.mem.eql(u8, p.ty, "code")) {
                out.appendSlice(a, inner) catch return;
            } else walk(a, inner, out, ents);
            ents.append(a, .{ .t = p.ty, .o = o, .l = markdown.u16len(out.items) - o }) catch {};
            i = close + p.open.len;
            done = true;
            break;
        }
        if (done) continue;
        // [text](url)
        if (src[i] == '[') if (std.mem.indexOfScalarPos(u8, src, i + 1, ']')) |rb| {
            if (rb + 1 < src.len and src[rb + 1] == '(') if (std.mem.indexOfScalarPos(u8, src, rb + 2, ')')) |rp| {
                const url = src[rb + 2 .. rp];
                const label = src[i + 1 .. rb];
                const safe = std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "mailto:");
                if (std.mem.indexOfAny(u8, url, " \n") == null) {
                    const o = markdown.u16len(out.items);
                    walk(a, label, out, ents);
                    if (safe) ents.append(a, .{ .t = "textlink", .o = o, .l = markdown.u16len(out.items) - o, .url = url }) catch {};
                    i = rp + 1;
                    continue;
                }
            };
        };
        out.append(a, src[i]) catch return;
        i += 1;
    }
}

// ---------------------------------------------------------------------------------------------
// Blocks

const Kind = enum { para, heading, rule, code, quote, bullet, number, table_head, table_row };

const Block = struct {
    kind: Kind,
    text: []const u8 = "",
    level: u8 = 0,
    lang: []const u8 = "",
    /// Lists: the item's number; tables: the cells (separated by '\x1f').
    n: u32 = 0,
};

fn trimLine(l: []const u8) []const u8 {
    return std.mem.trim(u8, l, " \t\r");
}

fn isRule(l: []const u8) bool {
    const x = trimLine(l);
    if (x.len < 3) return false;
    const c = x[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var n: usize = 0;
    for (x) |ch| {
        if (ch == c) n += 1 else if (ch != ' ') return false;
    }
    return n >= 3;
}

fn isTableLine(l: []const u8) bool {
    const x = trimLine(l);
    return x.len >= 2 and x[0] == '|' and x[x.len - 1] == '|';
}

fn isTableSep(l: []const u8) bool {
    const x = trimLine(l);
    if (x.len < 3) return false;
    var dashes: usize = 0;
    for (x) |ch| {
        if (ch == '-') dashes += 1 else if (ch != '|' and ch != ':' and ch != ' ') return false;
    }
    return dashes >= 3;
}

fn cellsOf(a: Allocator, l: []const u8) []const u8 {
    var x = trimLine(l);
    if (x.len > 0 and x[0] == '|') x = x[1..];
    if (x.len > 0 and x[x.len - 1] == '|') x = x[0 .. x.len - 1];
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, x, '|');
    var first = true;
    while (it.next()) |c| {
        if (!first) out.append(a, 0x1f) catch {};
        first = false;
        out.appendSlice(a, trimLine(c)) catch {};
    }
    return out.items;
}

const ListItem = struct { number: ?u32, text: []const u8 };

fn listItem(l: []const u8) ?ListItem {
    var i: usize = 0;
    while (i < l.len and l[i] == ' ') i += 1;
    if (i + 1 < l.len and (l[i] == '-' or l[i] == '*' or l[i] == '+') and l[i + 1] == ' ') return .{ .number = null, .text = l[i + 2 ..] };
    var e = i;
    while (e < l.len and std.ascii.isDigit(l[e])) e += 1;
    if (e > i and e + 1 < l.len and (l[e] == '.' or l[e] == ')') and l[e + 1] == ' ') return .{ .number = std.fmt.parseInt(u32, l[i..e], 10) catch 1, .text = l[e + 2 ..] };
    return null;
}

pub fn blocks(a: Allocator, src: []const u8) []Block {
    var out: std.ArrayList(Block) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| lines.append(a, std.mem.trimEnd(u8, l, "\r")) catch {};
    const L = lines.items;
    var para: std.ArrayList(u8) = .empty;
    const flush = struct {
        fn f(al: Allocator, p: *std.ArrayList(u8), o: *std.ArrayList(Block)) void {
            if (p.items.len > 0) o.append(al, .{ .kind = .para, .text = al.dupe(u8, p.items) catch "" }) catch {};
            p.clearRetainingCapacity();
        }
    }.f;
    var i: usize = 0;
    while (i < L.len) {
        const line = L[i];
        const tl = trimLine(line);
        if (std.mem.startsWith(u8, tl, "```")) {
            flush(a, &para, &out);
            const lang = trimLine(tl[3..]);
            var body: std.ArrayList(u8) = .empty;
            i += 1;
            while (i < L.len and !std.mem.startsWith(u8, trimLine(L[i]), "```")) : (i += 1) {
                if (body.items.len > 0) body.append(a, '\n') catch {};
                body.appendSlice(a, L[i]) catch {};
            }
            i += 1;
            out.append(a, .{ .kind = .code, .text = body.items, .lang = lang }) catch {};
            continue;
        }
        if (tl.len > 0 and tl[0] == '#') {
            var n: usize = 0;
            while (n < tl.len and tl[n] == '#') n += 1;
            if (n <= 6 and n < tl.len and tl[n] == ' ') {
                flush(a, &para, &out);
                out.append(a, .{ .kind = .heading, .level = @intCast(n), .text = tl[n + 1 ..] }) catch {};
                i += 1;
                continue;
            }
        }
        if (isRule(line)) {
            flush(a, &para, &out);
            out.append(a, .{ .kind = .rule }) catch {};
            i += 1;
            continue;
        }
        if (isTableLine(line) and i + 1 < L.len and isTableSep(L[i + 1])) {
            flush(a, &para, &out);
            out.append(a, .{ .kind = .table_head, .text = cellsOf(a, line) }) catch {};
            i += 2;
            while (i < L.len and isTableLine(L[i])) : (i += 1) out.append(a, .{ .kind = .table_row, .text = cellsOf(a, L[i]) }) catch {};
            continue;
        }
        if (tl.len > 0 and tl[0] == '>') {
            flush(a, &para, &out);
            var q: std.ArrayList(u8) = .empty;
            while (i < L.len and trimLine(L[i]).len > 0 and trimLine(L[i])[0] == '>') : (i += 1) {
                if (q.items.len > 0) q.append(a, '\n') catch {};
                q.appendSlice(a, std.mem.trimStart(u8, trimLine(L[i])[1..], " ")) catch {};
            }
            out.append(a, .{ .kind = .quote, .text = q.items }) catch {};
            continue;
        }
        if (listItem(line)) |li| {
            flush(a, &para, &out);
            out.append(a, .{ .kind = if (li.number != null) .number else .bullet, .text = li.text, .n = li.number orelse 0 }) catch {};
            i += 1;
            continue;
        }
        if (tl.len == 0) {
            flush(a, &para, &out);
            i += 1;
            continue;
        }
        if (para.items.len > 0) para.append(a, '\n') catch {};
        para.appendSlice(a, line) catch {};
        i += 1;
    }
    flush(a, &para, &out);
    return out.items;
}

/// The texts drawn with rich text, in order (a table's cells one by one): link taps name one.
fn units(a: Allocator, bs: []const Block) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (bs) |b| switch (b.kind) {
        .rule, .code => {},
        .table_head, .table_row => {
            var it = std.mem.splitScalar(u8, b.text, 0x1f);
            while (it.next()) |c| out.append(a, c) catch {};
        },
        else => out.append(a, b.text) catch {},
    };
    return out.items;
}

// ---------------------------------------------------------------------------------------------
// Drawing

pub fn render(cx: Cx, m: *const data.Message, fg: Color, link: Color, font_size: f32) void {
    const ui = cx.ui;
    const a = cx.a();
    const bs = blocks(a, m.text());
    var unit: u16 = 0;
    const id = if (m.local_id == 0) m.id() else "";
    ui.begin(.{ .gap = 6 }, .{});
    var bi: usize = 0;
    while (bi < bs.len) : (bi += 1) {
        const b = bs[bi];
        switch (b.kind) {
            .para, .heading, .quote, .bullet, .number => {
                const p = inlineOf(a, b.text);
                const size: f32 = if (b.kind == .heading) font_size + @as(f32, @floatFromInt(@max(0, 4 - @as(i32, b.level)))) * 1.5 else font_size;
                var ents: std.ArrayList(Entity) = .empty;
                ents.appendSlice(a, p.entities) catch {};
                if (b.kind == .heading) ents.append(a, .{ .t = "bold", .o = 0, .l = markdown.u16len(p.text) }) catch {};
                const o: rich.Opts = .{ .fg = fg, .link = link, .msg = id, .font_size = size, .unit = unit };
                switch (b.kind) {
                    .quote => {
                        ui.begin(.{ .direction = .row, .gap = 8 }, .{});
                        ui.begin(.{ .width = .{ .px = 3 }, .radius = 2, .background = fg.withAlpha(0.5) }, .{});
                        ui.end();
                        ui.begin(.{ .grow = 1, .width = .fill, .opacity = 0.9 }, .{});
                        rich.text(cx, p.text, ents.items, o);
                        ui.end();
                        ui.end();
                    },
                    .bullet, .number => {
                        ui.begin(.{ .direction = .row, .gap = 6, .padding = .{ .start = 4 } }, .{});
                        ui.text(if (b.kind == .bullet) "•" else std.fmt.allocPrint(a, "{d}.", .{b.n}) catch "", .{ .font_size = font_size, .color = fg, .min_width = 14 });
                        ui.begin(.{ .grow = 1, .width = .fill }, .{});
                        rich.text(cx, p.text, ents.items, o);
                        ui.end();
                        ui.end();
                    },
                    else => rich.text(cx, p.text, ents.items, o),
                }
                unit += 1;
            },
            .rule => {
                ui.begin(.{ .height = .{ .px = 1 }, .width = .fill, .background = fg.withAlpha(0.25) }, .{});
                ui.end();
            },
            .code => {
                ui.begin(.{ .padding = .xy(10, 8), .radius = 10, .background = fg.withAlpha(0.08), .width = .fill, .gap = 4 }, .{});
                ui.begin(.{ .direction = .row, .align_items = .center }, .{});
                ui.text(b.lang, .{ .font_size = 11.5, .weight = 700, .color = fg, .opacity = 0.65, .grow = 1, .width = .fill });
                if (id.len > 0) {
                    ui.begin(.{ .padding = .xy(8, 3), .radius = 8, .pressed_background = fg.withAlpha(0.15) }, .{ .on_press = msgOf(.{ .copy_code = .{ .msg = Id.of(id), .block = @intCast(@min(bi, 65535)) } }), .key = key(.{ "aicopy", id, bi }) });
                    ui.text(t("Copy"), .{ .font_size = 12, .weight = 650, .color = fg, .opacity = 0.8 });
                    ui.end();
                }
                ui.end();
                ui.textWith(b.text, .{ .font_size = font_size - 1.5, .mono = true, .color = fg, .line_height = 1.45 }, .{ .selectable = true });
                ui.end();
            },
            .table_head => {
                ui.begin(.{ .radius = 8, .border_width = 1, .border_color = fg.withAlpha(0.2), .clip = true }, .{ .key = key(.{ "aitable", id, bi }) });
                var r = bi;
                while (r < bs.len and (r == bi or bs[r].kind == .table_row)) : (r += 1) {
                    const head = r == bi;
                    ui.begin(.{ .direction = .row, .background = if (head) fg.withAlpha(0.08) else null }, .{});
                    var it = std.mem.splitScalar(u8, bs[r].text, 0x1f);
                    while (it.next()) |cell| {
                        const p = inlineOf(a, cell);
                        var ents: std.ArrayList(Entity) = .empty;
                        ents.appendSlice(a, p.entities) catch {};
                        if (head) ents.append(a, .{ .t = "bold", .o = 0, .l = markdown.u16len(p.text) }) catch {};
                        ui.begin(.{ .grow = 1, .width = .fill, .padding = .xy(8, 5) }, .{});
                        rich.text(cx, p.text, ents.items, .{ .fg = fg, .link = link, .msg = id, .font_size = font_size - 1, .unit = unit });
                        ui.end();
                        unit += 1;
                    }
                    ui.end();
                }
                ui.end();
                bi = r - 1;
            },
            .table_row => {},
        }
    }
    ui.end();
}

/// Stop / Copy / Regenerate under an assistant's reply.
pub fn actions(cx: Cx, c: *const data.Chat, m: *const data.Message, fg: Color) void {
    if (m.local_id != 0) return;
    const ui = cx.ui;
    const id = Id.of(m.id());
    ui.begin(.{ .direction = .row, .gap = 6, .padding = .{ .top = 4 } }, .{});
    if (m.o.b("streaming")) {
        button(cx, icons.close, t("Stop"), msgOf(.{ .stop = id }), fg);
    } else {
        button(cx, icons.copy, t("Copy"), msgOf(.{ .copy = id }), fg);
        if (isLatest(cx.s, c, m)) button(cx, icons.refresh, t("Regenerate"), msgOf(.{ .regenerate = id }), fg);
    }
    ui.end();
}

fn isLatest(s: *const State, c: *const data.Chat, m: *const data.Message) bool {
    const tl = s.store.existingTimeline(c.id()) orelse return false;
    var i = tl.items.items.len;
    while (i > 0) {
        i -= 1;
        const x = tl.items.items[i];
        if (x.isService()) continue;
        return x == m;
    }
    return false;
}

fn button(cx: Cx, ic: zui.Icon, label: []const u8, msg: Msg, fg: Color) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 5, .padding = .xy(9, 5), .radius = 9, .background = fg.withAlpha(0.08), .pressed_background = fg.withAlpha(0.18) }, .{ .on_press = msg, .key = key(.{ "aiact", label }) });
    ui.icon(ic, 14, fg, .{}, 0);
    ui.text(label, .{ .font_size = 12.5, .weight = 650, .color = fg });
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// Acting

fn find(s: *State, id: Id) ?*data.Message {
    const tl = s.store.existingTimeline(s.open_chat.str()) orelse return null;
    return tl.find(id.str());
}

pub fn act(s: *State, a: Act) void {
    switch (a) {
        .copy_code => |x| {
            const m = find(s, x.msg) orelse return;
            const bs = blocks(tmp(), m.text());
            if (x.block >= bs.len) return;
            app.fx.copy(bs[x.block].text);
            app.toast(s, t("Code copied"));
        },
        .copy => |id| {
            const m = find(s, id) orelse return;
            app.fx.copy(m.text());
            app.toast(s, t("Copied"));
        },
        .stop => |id| app.api(s, .POST, std.fmt.allocPrint(tmp(), "/chats/{s}/messages/{s}/stop", .{ s.open_chat.str(), id.str() }) catch return, "{}", .ignore),
        .regenerate => |id| app.api(s, .POST, std.fmt.allocPrint(tmp(), "/chats/{s}/messages/{s}/regenerate", .{ s.open_chat.str(), id.str() }) catch return, "{}", .ignore),
        .link => |x| {
            const m = find(s, x.msg) orelse return;
            const us = units(tmp(), blocks(tmp(), m.text()));
            if (x.unit >= us.len) return;
            const p = inlineOf(tmp(), us[x.unit]);
            switch (rich.linkAt(p.text, p.entities, x.at)) {
                .url => |u| app.fx.openUrl(u, true),
                .username => |name| app.api(s, .GET, std.fmt.allocPrint(tmp(), "/chats/by-username/{s}", .{j.urlEncode(tmp(), name) catch return}) catch return, null, .open_username),
                .hashtag => |tag| @import("views.zig").searchFor(s, tag),
                .code => |code| {
                    app.fx.copy(code);
                    app.toast(s, t("Copied"));
                },
                .none => {},
            }
        },
    }
}

test "assistant markdown: blocks and inline" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const bs = blocks(al, "# Plan\n\nSome **bold** and `code`.\n\n- one\n- two\n\n```zig\nconst x = 1;\n```\n| a | b |\n|---|---|\n| 1 | 2 |\n---\n> quoted");
    try std.testing.expectEqual(Kind.heading, bs[0].kind);
    try std.testing.expectEqual(Kind.para, bs[1].kind);
    try std.testing.expectEqual(Kind.bullet, bs[2].kind);
    try std.testing.expectEqual(Kind.bullet, bs[3].kind);
    try std.testing.expectEqual(Kind.code, bs[4].kind);
    try std.testing.expectEqualStrings("const x = 1;", bs[4].text);
    try std.testing.expectEqual(Kind.table_head, bs[5].kind);
    try std.testing.expectEqual(Kind.table_row, bs[6].kind);
    try std.testing.expectEqual(Kind.rule, bs[7].kind);
    try std.testing.expectEqual(Kind.quote, bs[8].kind);
    const p = inlineOf(al, "Some **bold**, *it* and [Wufour](https://wufour.com) and snake_case_name");
    try std.testing.expectEqualStrings("Some bold, it and Wufour and snake_case_name", p.text);
    try std.testing.expectEqual(@as(usize, 3), p.entities.len);
    try std.testing.expectEqualStrings("textlink", p.entities[2].t);
}
