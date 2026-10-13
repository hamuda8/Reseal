//! Export a chat to a file on this device (Reseal-js ui/export.js). Encrypted chats never reach
//! the server as plaintext, so the export is built here: the history is loaded page by page and
//! decrypted with this device's keys, attachments are downloaded (and decrypted) one by one, and
//! everything goes into a ZIP (a web page, JSON or plain text plus a "files" folder). An export
//! without attachments is a single file, saved with zui's saveFile.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");
const crypto = @import("crypto.zig");
const fmt = @import("fmt.zig");
const text = @import("text.zig");
const markdown = @import("markdown.zig");
const icons = @import("icons.zig");
const theme = @import("theme.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");
const vcompose = @import("view_compose.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const t = zui.i18n.t;
const tmp = app.tmp;
const gpa = app.gpa;

const page_size = 100;

pub const Format = enum { html, json, txt };
pub const Period = enum { all, days30, year, custom };

pub const media_kinds = [_]struct { label: []const u8, kinds: []const []const u8 }{
    .{ .label = "Photos", .kinds = &.{ "photo", "gif", "sticker" } },
    .{ .label = "Videos and video messages", .kinds = &.{ "video", "round" } },
    .{ .label = "Voice messages and audio", .kinds = &.{ "voice", "audio" } },
    .{ .label = "Files", .kinds = &.{"file"} },
};
pub const size_limits = [_]u32{ 8, 32, 128, 0 };

pub const Options = struct {
    format: Format = .html,
    media: [media_kinds.len]bool = .{ true, true, true, true },
    max_mb: u8 = 1,
    period: Period = .all,
};

pub const Act = union(enum) {
    open: Id,
    format: Format,
    media: u8,
    max_mb: u8,
    period: Period,
    start,
    cancel,
    pick_from,
    pick_to,
    set_from: Id,
    set_to: Id,
};

const Item = struct { msg: usize, index: usize };
const FileOut = struct { path: []const u8, bytes: []const u8, at: i64 };

pub const Phase = enum { loading, decrypting, files, packing };

/// A running export.
pub const Run = struct {
    arena: std.heap.ArenaAllocator,
    chat: Id,
    opts: Options,
    from: i64,
    to: i64,
    phase: Phase = .loading,
    msgs: std.ArrayList(*data.Message) = .empty,
    items: std.ArrayList(Item) = .empty,
    cur: usize = 0,
    files: std.ArrayList(FileOut) = .empty,
    /// "<message id>:<index>" -> path in the ZIP.
    paths: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The attachment being fetched.
    key: ?crypto.FileKey = null,
    chunks: u32 = 0,
    parts: std.ArrayList(u8) = .empty,
    seq: u32 = 0,

    fn alloc(r: *Run) std.mem.Allocator {
        return r.arena.allocator();
    }
};

pub const Export = struct {
    opts: Options = .{},
    chat: Id = .{},
    run: ?*Run = null,
    seq: u32 = 0,
};

fn path(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(tmp(), f, args) catch "";
}

pub fn act(s: *State, a: Act) void {
    const e = &s.exporter;
    switch (a) {
        .open => |id| {
            s.modal = null;
            e.opts = .{};
            e.chat = id;
            s.fields.getPtr(.export_from).clear();
            s.fields.getPtr(.export_to).clear();
            s.modal = .export_options;
        },
        .format => |f| e.opts.format = f,
        .media => |i| if (i < media_kinds.len) {
            e.opts.media[i] = !e.opts.media[i];
        },
        .max_mb => |i| e.opts.max_mb = @min(i, size_limits.len - 1),
        .period => |p| e.opts.period = p,
        .start => start(s),
        .cancel => {
            stop(s);
            s.modal = null;
        },
        .pick_from => app.fx.pickDate(.{ .value = s.fields.get(.export_from).get() }, onFrom),
        .pick_to => app.fx.pickDate(.{ .value = s.fields.get(.export_to).get() }, onTo),
        .set_from => |d| s.fields.getPtr(.export_from).set(d.str()),
        .set_to => |d| s.fields.getPtr(.export_to).set(d.str()),
    }
}

fn onFrom(d: []const u8) Msg {
    return .{ .export_chat = .{ .set_from = Id.of(d) } };
}

fn onTo(d: []const u8) Msg {
    return .{ .export_chat = .{ .set_to = Id.of(d) } };
}

fn start(s: *State) void {
    const e = &s.exporter;
    const now = sys.now();
    var from: i64 = std.math.minInt(i64);
    var to: i64 = std.math.maxInt(i64);
    switch (e.opts.period) {
        .all => {},
        .days30 => from = now - 30 * 86_400_000,
        .year => from = now - 365 * 86_400_000,
        .custom => {
            const f = s.fields.get(.export_from).trimmed();
            const tt = s.fields.get(.export_to).trimmed();
            if (f.len == 0 and tt.len == 0) return app.toastError(s, t("Choose dates"));
            if (f.len > 0) from = dayStart(f) orelse return app.toastError(s, t("Use the form 2026-01-31."));
            if (tt.len > 0) to = (dayStart(tt) orelse return app.toastError(s, t("Use the form 2026-01-31."))) + 86_400_000 - 1;
        },
    }
    stop(s);
    const r = gpa.create(Run) catch return;
    e.seq += 1;
    r.* = .{ .arena = .init(gpa), .chat = e.chat, .opts = e.opts, .from = from, .to = to, .seq = e.seq };
    e.run = r;
    s.modal = .export_progress;
    loadPage(s, r, 0);
}

fn dayStart(d: []const u8) ?i64 {
    return @import("compose.zig").parseLocal(std.fmt.allocPrint(tmp(), "{s} 00:00", .{d}) catch return null);
}

fn stop(s: *State) void {
    const r = s.exporter.run orelse return;
    for (r.msgs.items) |m| m.destroy();
    r.msgs.deinit(gpa);
    r.parts.deinit(gpa);
    r.arena.deinit();
    gpa.destroy(r);
    s.exporter.run = null;
}

fn loadPage(s: *State, r: *Run, before: i64) void {
    const q = if (before > 0) path("&before={d}", .{before}) else "";
    app.api(s, .GET, path("/chats/{s}/messages?limit={d}{s}", .{ r.chat.str(), page_size, q }), null, .{ .export_page = r.seq });
}

fn current(s: *State, seq: u32) ?*Run {
    const r = s.exporter.run orelse return null;
    return if (r.seq == seq) r else null;
}

pub fn onAnswer(s: *State, op: app.Op, resp: zui.Response) bool {
    switch (op) {
        .export_page => |seq| {
            const r = current(s, seq) orelse return true;
            if (!resp.ok()) return fail(s, app.apiError(resp).message);
            const v = j.parse(tmp(), resp.body);
            const page = j.arr(v, "messages");
            var oldest: i64 = 0;
            var oldest_at: i64 = std.math.maxInt(i64);
            for (page) |raw| {
                const m = data.newMessage(raw) catch continue;
                if (oldest == 0 or (m.seq() orelse 0) < oldest) {
                    oldest = m.seq() orelse 0;
                    oldest_at = m.at;
                }
                if (m.at < r.from or m.at > r.to) {
                    m.destroy();
                    continue;
                }
                r.msgs.append(gpa, m) catch m.destroy();
            }
            const floor = j.intOr(v, "floor", 0);
            if (page.len < page_size or oldest <= floor + 1 or oldest_at < r.from) return finishLoading(s, r);
            loadPage(s, r, oldest);
        },
        .export_info => |seq| {
            const r = current(s, seq) orelse return true;
            if (!resp.ok()) {
                skipFile(s, r);
                return true;
            }
            const v = j.parse(tmp(), resp.body);
            if (r.key == null) {
                // A plain file: its bytes from the signed link.
                const url = j.strOr(v, "media.url", "");
                if (url.len == 0) {
                skipFile(s, r);
                return true;
            }
                const full = if (std.mem.startsWith(u8, url, "/")) path("{s}{s}", .{ app.server, url }) else url;
                app.fetchRaw(s, full, .{ .export_plain = r.seq });
                return true;
            }
            r.chunks = @intCast(@max(1, j.intOr(v, "media.chunks", 1)));
            r.parts.clearRetainingCapacity();
            fetchChunk(s, r, 0);
        },
        .export_chunk => |x| {
            const r = current(s, x.seq) orelse return true;
            if (!resp.ok()) {
                skipFile(s, r);
                return true;
            }
            const plain = crypto.decryptChunk(tmp(), r.key.?, x.index, x.index == r.chunks - 1, resp.body) catch {
                skipFile(s, r);
                return true;
            };
            r.parts.appendSlice(gpa, plain) catch {
                skipFile(s, r);
                return true;
            };
            if (x.index + 1 < r.chunks) {
                fetchChunk(s, r, x.index + 1);
            } else {
                keepFile(s, r, r.parts.items);
                r.parts.clearRetainingCapacity();
            }
        },
        .export_plain => |seq| {
            const r = current(s, seq) orelse return true;
            if (!resp.ok()) {
                skipFile(s, r);
                return true;
            }
            keepFile(s, r, resp.body);
        },
        else => return false,
    }
    return true;
}

fn fail(s: *State, why: []const u8) bool {
    stop(s);
    s.modal = null;
    app.toastError(s, why);
    return true;
}

fn finishLoading(s: *State, r: *Run) bool {
    std.mem.sort(*data.Message, r.msgs.items, {}, struct {
        fn lt(_: void, x: *data.Message, y: *data.Message) bool {
            return (x.seq() orelse 0) < (y.seq() orelse 0);
        }
    }.lt);
    r.phase = .decrypting;
    for (r.msgs.items) |m| if (m.enc() != null) keys.hydrate(s, r.chat.str(), m);
    // Attachments to include.
    for (r.msgs.items, 0..) |m, mi| {
        if (m.decrypt != .ok or m.deleted()) continue;
        for (m.media(), 0..) |item, ii| if (wanted(r.opts, item)) r.items.append(r.alloc(), .{ .msg = mi, .index = ii }) catch {};
    }
    r.phase = .files;
    nextFile(s, r);
    return true;
}

fn wanted(o: Options, item: j.Value) bool {
    const kind = j.strOr(item, "kind", "file");
    for (media_kinds, 0..) |g, i| for (g.kinds) |k| if (std.mem.eql(u8, k, kind)) {
        if (!o.media[i]) return false;
        const mb = size_limits[o.max_mb];
        if (mb > 0 and j.intOr(item, "size", 0) > @as(i64, mb) * 1024 * 1024) return false;
        return true;
    };
    return false;
}

fn nextFile(s: *State, r: *Run) void {
    if (r.cur >= r.items.items.len) return pack(s, r);
    const it = r.items.items[r.cur];
    const item = r.msgs.items[it.msg].media()[it.index];
    const id = j.str(item, "id") orelse return skipFile(s, r);
    r.key = null;
    if (j.str(item, "key")) |kb| {
        r.key = crypto.fileKeyFromB64(tmp(), kb, j.strOr(item, "iv", "")) catch return skipFile(s, r);
    }
    app.api(s, .GET, path("/media/{s}", .{id}), null, .{ .export_info = r.seq });
}

fn fetchChunk(s: *State, r: *Run, index: u32) void {
    const it = r.items.items[r.cur];
    const id = j.strOr(r.msgs.items[it.msg].media()[it.index], "id", "");
    app.api(s, .GET, path("/media/{s}/chunks/{d}", .{ id, index }), null, .{ .export_chunk = .{ .seq = r.seq, .index = index } });
}

fn skipFile(s: *State, r: *Run) void {
    r.cur += 1;
    nextFile(s, r);
}

fn keepFile(s: *State, r: *Run, bytes: []const u8) void {
    const it = r.items.items[r.cur];
    const m = r.msgs.items[it.msg];
    const item = m.media()[it.index];
    const a = r.alloc();
    const name = uniqueName(r, fileName(a, m, item, it.index));
    r.files.append(a, .{ .path = name, .bytes = a.dupe(u8, bytes) catch return skipFile(s, r), .at = m.at }) catch {};
    r.paths.put(a, std.fmt.allocPrint(a, "{s}:{d}", .{ m.id(), it.index }) catch "", name) catch {};
    skipFile(s, r);
}

const ext_by_mime = [_][2][]const u8{
    .{ "image/jpeg", "jpg" }, .{ "image/png", "png" },  .{ "image/webp", "webp" },     .{ "image/gif", "gif" }, .{ "image/avif", "avif" },
    .{ "video/mp4", "mp4" },  .{ "video/webm", "webm" }, .{ "video/quicktime", "mov" }, .{ "audio/ogg", "ogg" }, .{ "audio/webm", "weba" },
    .{ "audio/mpeg", "mp3" }, .{ "audio/mp4", "m4a" },  .{ "audio/wav", "wav" },       .{ "application/pdf", "pdf" },
};

fn extFor(item: j.Value) []const u8 {
    const name = j.strOr(item, "name", "");
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        const e = name[dot + 1 ..];
        if (e.len >= 1 and e.len <= 5) return e;
    }
    const mime = j.strOr(item, "mime", "");
    for (ext_by_mime) |kv| if (std.mem.eql(u8, kv[0], mime)) return kv[1];
    if (std.mem.indexOfScalar(u8, mime, '/')) |i| if (mime.len > i + 1) return mime[i + 1 ..];
    return "bin";
}

fn safeName(a: std.mem.Allocator, s: []const u8) []const u8 {
    const out = a.dupe(u8, std.mem.trim(u8, s, " ")) catch return "file";
    for (out) |*ch| if (ch.* < 0x20 or std.mem.indexOfScalar(u8, "\\/:*?\"<>|", ch.*) != null) {
        ch.* = '_';
    };
    return out;
}

fn fileName(a: std.mem.Allocator, m: *const data.Message, item: j.Value, index: usize) []const u8 {
    var base = j.strOr(item, "name", "");
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base = base[0..dot];
    const label = if (base.len > 0) safeName(a, base) else std.fmt.allocPrint(a, "{s}-{d}{s}", .{ j.strOr(item, "kind", "file"), m.seq() orelse 0, if (index > 0) (std.fmt.allocPrint(a, "-{d}", .{index + 1}) catch "") else "" }) catch "file";
    return std.fmt.allocPrint(a, "files/{s}.{s}", .{ label, extFor(item) }) catch "files/file";
}

fn uniqueName(r: *Run, name: []const u8) []const u8 {
    var candidate = name;
    var n: usize = 2;
    while (true) : (n += 1) {
        const taken = for (r.files.items) |f| {
            if (std.mem.eql(u8, f.path, candidate)) break true;
        } else false;
        if (!taken) return candidate;
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
        candidate = std.fmt.allocPrint(r.alloc(), "{s} ({d}){s}", .{ name[0..dot], n, name[dot..] }) catch return name;
    }
}

// ---------------------------------------------------------------------------------------------
// Writing

fn pack(s: *State, r: *Run) void {
    r.phase = .packing;
    const a = r.alloc();
    const c = s.store.chat(r.chat.str());
    const title = if (c) |cc| s.store.title(cc) else "chat";
    const ext = @tagName(r.opts.format);
    const main = switch (r.opts.format) {
        .html => renderHtml(s, r, a, title),
        .json => renderJson(s, r, a),
        .txt => renderText(s, r, a, title),
    };
    const day = sys.local(sys.now());
    const stamp = std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(day.year)), day.month, day.day }) catch "";
    const safe = safeName(a, title);
    var name: []const u8 = undefined;
    var bytes: []const u8 = undefined;
    var mime: []const u8 = undefined;
    if (r.files.items.len == 0) {
        name = std.fmt.allocPrint(a, "Reseal - {s} - {s}.{s}", .{ safe, stamp, ext }) catch "export";
        bytes = main;
        mime = switch (r.opts.format) {
            .html => "text/html;charset=utf-8",
            .json => "application/json",
            .txt => "text/plain;charset=utf-8",
        };
    } else {
        var zip: Zip = .{ .a = a };
        for (r.files.items) |f| zip.add(f.path, f.bytes, f.at);
        zip.add(std.fmt.allocPrint(a, "messages.{s}", .{ext}) catch "messages", main, sys.now());
        name = std.fmt.allocPrint(a, "Reseal - {s} - {s}.zip", .{ safe, stamp }) catch "export.zip";
        bytes = zip.finish();
        mime = "application/zip";
    }
    save(name, mime, bytes);
    app.toast(s, fmt.tf("Export saved as {name}", .{ .name = name }));
    stop(s);
    s.modal = null;
}

/// Downloads it (web), saves it to Downloads (Android) or offers the share sheet (iOS).
fn save(name: []const u8, mime: []const u8, bytes: []const u8) void {
    app.fx.saveFile(.{ .name = name, .mime = mime, .data = bytes });
}

fn nameOf(s: *const State, id: []const u8) []const u8 {
    if (id.len == 0) return "";
    return s.store.displayName(id);
}

fn fileLabel(item: j.Value) []const u8 {
    if (j.str(item, "name")) |n| if (n.len > 0) return n;
    const kind = j.strOr(item, "kind", "file");
    const map = .{ .{ "photo", "Photo" }, .{ "video", "Video" }, .{ "round", "Video message" }, .{ "voice", "Voice message" }, .{ "audio", "Audio" }, .{ "sticker", "Sticker" } };
    inline for (map) |kv| if (std.mem.eql(u8, kind, kv[0])) return t(kv[1]);
    if (std.mem.eql(u8, kind, "gif")) return "GIF";
    return t("File");
}

fn esc(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) void {
    for (s) |ch| switch (ch) {
        '&' => out.appendSlice(a, "&amp;") catch {},
        '<' => out.appendSlice(a, "&lt;") catch {},
        '>' => out.appendSlice(a, "&gt;") catch {},
        '"' => out.appendSlice(a, "&quot;") catch {},
        '\'' => out.appendSlice(a, "&#39;") catch {},
        else => out.append(a, ch) catch {},
    };
}

/// Message text with its entities as HTML (bold, italic, code, links, quotes, spoilers...).
pub fn textHtml(out: *std.ArrayList(u8), a: std.mem.Allocator, txt: []const u8, entities: []const markdown.Entity) void {
    const Mark = struct { at: usize, close: bool, len: usize, tag: []const u8 };
    var marks: std.ArrayList(Mark) = .empty;
    for (entities) |e| {
        const open: []const u8, const close: []const u8 = if (std.mem.eql(u8, e.t, "bold")) .{ "<b>", "</b>" } else if (std.mem.eql(u8, e.t, "italic")) .{ "<i>", "</i>" } else if (std.mem.eql(u8, e.t, "underline")) .{ "<u>", "</u>" } else if (std.mem.eql(u8, e.t, "strike")) .{ "<s>", "</s>" } else if (std.mem.eql(u8, e.t, "code")) .{ "<code class=\"inline\">", "</code>" } else if (std.mem.eql(u8, e.t, "pre")) .{ "<pre class=\"code\">", "</pre>" } else if (std.mem.eql(u8, e.t, "quote")) .{ "<blockquote class=\"quote\">", "</blockquote>" } else if (std.mem.eql(u8, e.t, "spoiler")) .{ "<span class=\"spoiler\">", "</span>" } else if (std.mem.eql(u8, e.t, "textlink") and e.url != null) .{ blk: {
            var o: std.ArrayList(u8) = .empty;
            o.appendSlice(a, "<a href=\"") catch {};
            esc(&o, a, e.url.?);
            o.appendSlice(a, "\">") catch {};
            break :blk o.items;
        }, "</a>" } else continue;
        marks.append(a, .{ .at = markdown.byteAt(txt, e.o), .close = false, .len = e.l, .tag = open }) catch {};
        marks.append(a, .{ .at = markdown.byteAt(txt, e.o + e.l), .close = true, .len = e.l, .tag = close }) catch {};
    }
    std.mem.sort(Mark, marks.items, {}, struct {
        fn lt(_: void, x: Mark, y: Mark) bool {
            if (x.at != y.at) return x.at < y.at;
            if (x.close != y.close) return x.close; // close before open at the same place
            return if (x.close) x.len < y.len else x.len > y.len;
        }
    }.lt);
    var pos: usize = 0;
    for (marks.items) |mk| {
        if (mk.at > pos) esc(out, a, txt[pos..mk.at]);
        pos = @max(pos, mk.at);
        out.appendSlice(a, mk.tag) catch {};
    }
    if (pos < txt.len) esc(out, a, txt[pos..]);
}

fn renderHtml(s: *State, r: *Run, a: std.mem.Allocator, title: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = struct {
        fn str(o: *std.ArrayList(u8), al: std.mem.Allocator, x: []const u8) void {
            o.appendSlice(al, x) catch {};
        }
    }.str;
    const encrypted = if (s.store.chat(r.chat.str())) |c| c.encrypted() else false;
    w(&out, a, "<!doctype html>\n<html lang=\"");
    w(&out, a, if (s.lang == .ar) "ar\" dir=\"rtl\">" else "en\" dir=\"ltr\">");
    w(&out, a, "\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    esc(&out, a, title);
    w(&out, a, "</title>\n<style>\n" ++ css ++ "</style>\n</head>\n<body>\n<header><h1>");
    esc(&out, a, title);
    w(&out, a, "</h1><p>");
    esc(&out, a, fmt.tn(a, @intCast(r.msgs.items.len), "{n} message", "{n} messages"));
    w(&out, a, " · ");
    esc(&out, a, fmt.tf("Exported {date}", .{ .date = fmt.fullDate(a, sys.now()) }));
    if (encrypted) {
        w(&out, a, " · ");
        esc(&out, a, t("End-to-end encrypted"));
    }
    w(&out, a, "</p></header>\n<main>");
    var prev: i64 = 0;
    for (r.msgs.items) |m| {
        if (prev == 0 or !fmt.sameDay(prev, m.at)) {
            w(&out, a, "<div class=\"day\">");
            esc(&out, a, fmt.dayLabel(a, m.at));
            w(&out, a, "</div>\n");
        }
        prev = m.at;
        const anchor = std.fmt.allocPrint(a, "m{d}", .{m.seq() orelse 0}) catch "";
        if (m.isService() or m.deleted()) {
            out.print(a, "<div class=\"service\" id=\"{s}\">", .{anchor}) catch {};
            esc(&out, a, if (m.deleted()) t("Deleted message") else text.serviceText(s, m));
            w(&out, a, "</div>\n");
            continue;
        }
        const mine = s.store.isMe(m.authorId());
        out.print(a, "<div class=\"msg{s}\" id=\"{s}\"><div class=\"head\"><b>", .{ if (mine) " out" else "", anchor }) catch {};
        esc(&out, a, nameOf(s, m.senderId()));
        w(&out, a, "</b><time>");
        esc(&out, a, fmt.time(a, m.at));
        w(&out, a, "</time>");
        if (j.str(m.o.v, "editedAt") != null) {
            w(&out, a, "<span class=\"meta\">");
            esc(&out, a, t("edited"));
            w(&out, a, "</span>");
        }
        w(&out, a, "</div>");
        if (m.decrypt != .ok) {
            w(&out, a, "<div class=\"text muted\">");
            esc(&out, a, if (m.decrypt == .nokey) t("Waiting for encryption key") else t("Message could not be decrypted"));
            w(&out, a, "</div>");
        } else {
            const c = m.content;
            if (j.obj(c, "fwd")) |f| {
                w(&out, a, "<div class=\"fwd\">");
                esc(&out, a, fmt.tf("Forwarded from {name}", .{ .name = j.str(f, "fromName") orelse nameOf(s, j.strOr(f, "fromUserId", "")) }));
                w(&out, a, "</div>");
            }
            for (m.media(), 0..) |item, i| attachmentHtml(&out, a, r, m, item, i);
            if (j.obj(c, "sticker")) |st| {
                w(&out, a, "<div class=\"text big\">");
                esc(&out, a, j.strOr(st, "emoji", ""));
                w(&out, a, "</div>");
            }
            if (m.text().len > 0) {
                w(&out, a, "<div class=\"text\">");
                textHtml(&out, a, m.text(), markdown.fromJson(a, j.field(c, "entities")));
                w(&out, a, "</div>");
            }
            if (j.obj(c, "poll")) |p| {
                w(&out, a, "<div class=\"poll\"><b>");
                esc(&out, a, std.fmt.allocPrint(a, "{s}: {s}", .{ t("Poll"), j.strOr(p, "question", "") }) catch "");
                w(&out, a, "</b>");
                const counts = j.arr(m.o.v, "poll.counts");
                for (j.arr(p, "options"), 0..) |o, i| {
                    w(&out, a, "<div class=\"opt\">");
                    esc(&out, a, if (o == .string) o.string else "");
                    out.print(a, "<span class=\"meta\">{d}</span></div>", .{if (i < counts.len and counts[i] == .integer) counts[i].integer else 0}) catch {};
                }
                w(&out, a, "</div>");
            }
            if (j.obj(c, "location")) |loc| {
                out.print(a, "<div class=\"att file\">{s}: ", .{t("Location")}) catch {};
                esc(&out, a, j.strOr(loc, "title", ""));
                out.print(a, " ({d:.5}, {d:.5})</div>", .{ j.floatOr(loc, "lat", 0), j.floatOr(loc, "lng", 0) }) catch {};
            }
            if (j.obj(c, "contact")) |ct| {
                out.print(a, "<div class=\"att file\">{s}: ", .{t("Contact")}) catch {};
                esc(&out, a, j.strOr(ct, "name", ""));
                w(&out, a, "</div>");
            }
        }
        const reactions = j.arr(m.o.v, "reactions");
        if (reactions.len > 0) {
            w(&out, a, "<div class=\"reactions\">");
            for (reactions) |rx| {
                w(&out, a, "<span>");
                esc(&out, a, j.strOr(rx, "emoji", ""));
                out.print(a, " {d}</span>", .{j.intOr(rx, "count", 0)}) catch {};
            }
            w(&out, a, "</div>");
        }
        w(&out, a, "</div>\n");
    }
    w(&out, a, "</main>\n<footer>");
    esc(&out, a, t("Exported from Reseal"));
    w(&out, a, "</footer>\n</body>\n</html>\n");
    return out.items;
}

fn attachmentHtml(out: *std.ArrayList(u8), a: std.mem.Allocator, r: *Run, m: *const data.Message, item: j.Value, index: usize) void {
    const key = std.fmt.allocPrint(a, "{s}:{d}", .{ m.id(), index }) catch "";
    const label = fileLabel(item);
    const kind = j.strOr(item, "kind", "file");
    const p = r.paths.get(key) orelse {
        out.appendSlice(a, "<div class=\"att missing\">") catch {};
        esc(out, a, label);
        out.print(a, " <span class=\"meta\">({s})</span></div>", .{t("not included")}) catch {};
        return;
    };
    const is = struct {
        fn f(k: []const u8, list: []const []const u8) bool {
            for (list) |x| if (std.mem.eql(u8, k, x)) return true;
            return false;
        }
    }.f;
    if (is(kind, &.{ "photo", "gif", "sticker" })) {
        out.appendSlice(a, "<a class=\"att\" href=\"") catch {};
        esc(out, a, p);
        out.appendSlice(a, "\"><img src=\"") catch {};
        esc(out, a, p);
        out.appendSlice(a, "\" alt=\"\" loading=\"lazy\"></a>") catch {};
    } else if (is(kind, &.{ "video", "round" })) {
        out.print(a, "<video class=\"att{s}\" src=\"", .{if (std.mem.eql(u8, kind, "round")) " round" else ""}) catch {};
        esc(out, a, p);
        out.appendSlice(a, "\" controls preload=\"metadata\"></video>") catch {};
    } else if (is(kind, &.{ "voice", "audio" })) {
        out.appendSlice(a, "<div class=\"att\"><audio src=\"") catch {};
        esc(out, a, p);
        out.appendSlice(a, "\" controls preload=\"metadata\"></audio></div>") catch {};
    } else {
        out.appendSlice(a, "<a class=\"att file\" href=\"") catch {};
        esc(out, a, p);
        out.appendSlice(a, "\" download>") catch {};
        esc(out, a, label);
        out.appendSlice(a, "</a>") catch {};
    }
}

const css =
    \\  :root { color-scheme: light dark; --bg: #f3f4f8; --card: #fff; --text: #14161d; --muted: #6b7280; --accent: #6c5cff; --in: #fff; --out: #e7e4ff; --line: #e5e7eb; }
    \\  @media (prefers-color-scheme: dark) { :root { --bg: #0f1117; --card: #171a23; --text: #e6e8ef; --muted: #8b90a0; --in: #1c2030; --out: #2a2556; --line: #262a38; } }
    \\  * { box-sizing: border-box; }
    \\  body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
    \\  header { position: sticky; top: 0; background: var(--card); border-bottom: 1px solid var(--line); padding: 14px 20px; }
    \\  header h1 { margin: 0; font-size: 18px; } header p { margin: 2px 0 0; color: var(--muted); font-size: 13px; }
    \\  main { max-width: 820px; margin: 0 auto; padding: 16px; }
    \\  .day { text-align: center; color: var(--muted); font-size: 12.5px; margin: 20px 0 10px; }
    \\  .service { text-align: center; color: var(--muted); font-size: 13px; margin: 8px 0; }
    \\  .msg { background: var(--in); border-radius: 16px; padding: 10px 14px; margin: 6px 0; max-width: 78%; box-shadow: 0 1px 2px rgba(0,0,0,.05); overflow-wrap: anywhere; }
    \\  .msg.out { background: var(--out); margin-inline-start: auto; }
    \\  .head { display: flex; gap: 10px; align-items: baseline; font-size: 13px; color: var(--muted); } .head b { color: var(--accent); }
    \\  .text { white-space: pre-wrap; } .text.big { font-size: 42px; line-height: 1.2; } .muted, .meta { color: var(--muted); font-size: 12.5px; }
    \\  .fwd { color: var(--accent); font-size: 13px; }
    \\  .att { display: block; margin: 6px 0; color: inherit; } .att img { max-width: 100%; max-height: 480px; border-radius: 12px; display: block; } video.att { max-width: 100%; border-radius: 12px; } video.round { width: 240px; height: 240px; border-radius: 50%; object-fit: cover; }
    \\  .att.file { text-decoration: none; background: rgba(127,127,127,.12); padding: 8px 12px; border-radius: 10px; } .att.missing { opacity: .7; }
    \\  .poll .opt { display: flex; justify-content: space-between; gap: 12px; padding: 4px 0; border-bottom: 1px solid var(--line); }
    \\  .reactions { display: flex; gap: 6px; margin-top: 6px; } .reactions span { background: rgba(127,127,127,.14); border-radius: 999px; padding: 1px 9px; font-size: 13px; }
    \\  a { color: var(--accent); } pre.code { background: rgba(127,127,127,.12); padding: 10px; border-radius: 10px; overflow: auto; } code.inline { background: rgba(127,127,127,.14); border-radius: 5px; padding: 0 4px; } blockquote.quote { border-inline-start: 3px solid var(--accent); margin: 4px 0; padding: 2px 10px; } .spoiler { background: var(--muted); color: transparent; border-radius: 4px; } .spoiler:hover { background: none; color: inherit; }
    \\  footer { text-align: center; color: var(--muted); font-size: 12px; padding: 24px; }
    \\
;

fn renderJson(s: *State, r: *Run, a: std.mem.Allocator) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const c = s.store.chat(r.chat.str());
    var people: std.StringArrayHashMapUnmanaged(void) = .empty;
    out.print(a, "{{\n  \"exportedAt\": \"{s}\",\n  \"app\": \"Reseal\",\n  \"chat\": {{\"id\":\"{s}\",\"type\":{s},\"title\":{s},\"encrypted\":{}}},\n  \"messages\": [", .{
        isoNow(a),
        r.chat.str(),
        j.quote(a, if (c) |cc| cc.o.s("type") orelse "" else "") catch "\"\"",
        j.quote(a, if (c) |cc| s.store.title(cc) else "") catch "\"\"",
        if (c) |cc| cc.encrypted() else false,
    }) catch {};
    for (r.msgs.items, 0..) |m, i| {
        if (i > 0) out.append(a, ',') catch {};
        const from = m.senderId();
        if (from.len > 0) people.put(a, from, {}) catch {};
        out.print(a, "\n    {{\"id\":\"{s}\",\"seq\":{d},\"date\":{s},\"from\":{s},\"kind\":{s}", .{
            m.id(),
            m.seq() orelse 0,
            j.quote(a, m.o.s("createdAt") orelse "") catch "null",
            if (from.len > 0) (j.quote(a, from) catch "null") else "null",
            j.quote(a, m.o.s("kind") orelse "message") catch "\"message\"",
        }) catch {};
        if (m.o.s("editedAt")) |e| out.print(a, ",\"editedAt\":{s}", .{j.quote(a, e) catch "null"}) catch {};
        if (m.deleted()) {
            out.appendSlice(a, ",\"deleted\":true}") catch {};
            continue;
        }
        if (m.isService()) {
            out.print(a, ",\"service\":{s},\"text\":{s}}}", .{ j.stringify(a, j.field(m.o.v, "service") orelse .null) catch "null", j.quote(a, text.serviceText(s, m)) catch "\"\"" }) catch {};
            continue;
        }
        if (m.decrypt != .ok) {
            out.print(a, ",\"undecryptable\":\"{s}\"}}", .{@tagName(m.decrypt)}) catch {};
            continue;
        }
        const ct = m.content;
        if (m.text().len > 0) out.print(a, ",\"text\":{s}", .{j.quote(a, m.text()) catch "\"\""}) catch {};
        if (j.field(ct, "entities")) |e| if (e == .array and e.array.items.len > 0) out.print(a, ",\"entities\":{s}", .{j.stringify(a, e) catch "[]"}) catch {};
        const media = m.media();
        if (media.len > 0) {
            out.appendSlice(a, ",\"media\":[") catch {};
            for (media, 0..) |item, k| {
                const key = std.fmt.allocPrint(a, "{s}:{d}", .{ m.id(), k }) catch "";
                out.print(a, "{s}{{\"kind\":{s},\"name\":{s},\"mime\":{s},\"size\":{d},\"file\":{s}}}", .{
                    if (k > 0) "," else "",
                    j.quote(a, j.strOr(item, "kind", "file")) catch "null",
                    if (j.str(item, "name")) |n| (j.quote(a, n) catch "null") else "null",
                    if (j.str(item, "mime")) |n| (j.quote(a, n) catch "null") else "null",
                    j.intOr(item, "size", 0),
                    if (r.paths.get(key)) |p| (j.quote(a, p) catch "null") else "null",
                }) catch {};
            }
            out.append(a, ']') catch {};
        }
        if (j.obj(ct, "poll")) |p| out.print(a, ",\"poll\":{{\"question\":{s},\"options\":{s},\"counts\":{s},\"total\":{d},\"quiz\":{}}}", .{
            j.quote(a, j.strOr(p, "question", "")) catch "\"\"",
            j.stringify(a, j.field(p, "options") orelse .null) catch "[]",
            j.stringify(a, j.field(m.o.v, "poll.counts") orelse .null) catch "null",
            j.intOr(m.o.v, "poll.total", 0),
            j.truthy(m.o.v, "poll.quiz"),
        }) catch {};
        inline for (.{ "location", "contact", "sticker" }) |k| if (j.field(ct, k)) |x| {
            out.print(a, ",\"" ++ k ++ "\":{s}", .{j.stringify(a, x) catch "null"}) catch {};
        };
        if (j.obj(ct, "fwd")) |f| out.print(a, ",\"forwardedFrom\":{{\"name\":{s},\"userId\":{s}}}", .{
            if (j.str(f, "fromName")) |n| (j.quote(a, n) catch "null") else "null",
            if (j.str(f, "fromUserId")) |n| (j.quote(a, n) catch "null") else "null",
        }) catch {};
        if (j.obj(m.o.v, "replyTo")) |rt| out.print(a, ",\"replyTo\":{{\"id\":{s},\"seq\":{d}}}", .{ j.quote(a, j.strOr(rt, "id", "")) catch "null", j.intOr(rt, "seq", 0) }) catch {};
        const reactions = j.arr(m.o.v, "reactions");
        if (reactions.len > 0) {
            out.appendSlice(a, ",\"reactions\":[") catch {};
            for (reactions, 0..) |rx, k| out.print(a, "{s}{{\"emoji\":{s},\"count\":{d}}}", .{ if (k > 0) "," else "", j.quote(a, j.strOr(rx, "emoji", "")) catch "\"\"", j.intOr(rx, "count", 0) }) catch {};
            out.append(a, ']') catch {};
        }
        out.append(a, '}') catch {};
    }
    out.appendSlice(a, "\n  ],\n  \"people\": [") catch {};
    for (people.keys(), 0..) |id, i| {
        const u = s.store.user(id);
        out.print(a, "{s}\n    {{\"id\":\"{s}\",\"name\":{s},\"username\":{s}}}", .{
            if (i > 0) "," else "",
            id,
            j.quote(a, nameOf(s, id)) catch "\"\"",
            if (u) |uu| (if (uu.s("username")) |n| (j.quote(a, n) catch "null") else "null") else "null",
        }) catch {};
    }
    out.appendSlice(a, "\n  ]\n}\n") catch {};
    return out.items;
}

fn isoNow(a: std.mem.Allocator) []const u8 {
    const c = sys.civilFromMs(sys.now());
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ @as(u32, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second }) catch "";
}

fn renderText(s: *State, r: *Run, a: std.mem.Allocator, title: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(a, "{s}\n{s}\n\n", .{ title, fmt.tf("Exported {date}", .{ .date = fmt.fullDate(a, sys.now()) }) }) catch {};
    for (r.msgs.items) |m| {
        const when = fmt.fullDate(a, m.at);
        if (m.isService()) {
            out.print(a, "[{s}] {s}\n", .{ when, text.serviceText(s, m) }) catch {};
            continue;
        }
        if (m.deleted()) {
            out.print(a, "[{s}] {s}\n", .{ when, t("Deleted message") }) catch {};
            continue;
        }
        const who = nameOf(s, m.senderId());
        if (m.decrypt != .ok) {
            out.print(a, "[{s}] {s}: ({s})\n", .{ when, who, t("Message could not be decrypted") }) catch {};
            continue;
        }
        out.print(a, "[{s}] {s}:", .{ when, who }) catch {};
        const ct = m.content;
        if (j.obj(ct, "fwd")) |f| out.print(a, " ({s})", .{fmt.tf("Forwarded from {name}", .{ .name = j.str(f, "fromName") orelse nameOf(s, j.strOr(f, "fromUserId", "")) })}) catch {};
        for (m.media(), 0..) |item, i| {
            const key = std.fmt.allocPrint(a, "{s}:{d}", .{ m.id(), i }) catch "";
            if (r.paths.get(key)) |p| out.print(a, " [{s}: {s}]", .{ fileLabel(item), p }) catch {} else out.print(a, " [{s}]", .{fileLabel(item)}) catch {};
        }
        if (j.obj(ct, "sticker")) |st| out.print(a, " [{s} {s}]", .{ t("Sticker"), j.strOr(st, "emoji", "") }) catch {};
        if (j.obj(ct, "poll")) |p| out.print(a, " [{s}: {s}]", .{ t("Poll"), j.strOr(p, "question", "") }) catch {};
        if (j.obj(ct, "location")) |l| out.print(a, " [{s}: {d}, {d}]", .{ t("Location"), j.floatOr(l, "lat", 0), j.floatOr(l, "lng", 0) }) catch {};
        if (j.obj(ct, "contact")) |cn| out.print(a, " [{s}: {s}]", .{ t("Contact"), j.strOr(cn, "name", "") }) catch {};
        if (m.text().len > 0) out.print(a, " {s}", .{m.text()}) catch {};
        out.append(a, '\n') catch {};
    }
    return out.items;
}

// ---------------------------------------------------------------------------------------------
// ZIP (stored, no compression: photos and videos are compressed already)

pub const Zip = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    central: std.ArrayList(u8) = .empty,
    count: u16 = 0,

    fn le16(list: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) void {
        list.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, v))) catch {};
    }
    fn le32(list: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) void {
        list.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, v))) catch {};
    }

    pub fn add(z: *Zip, name: []const u8, bytes: []const u8, at_ms: i64) void {
        const a = z.a;
        const crc = std.hash.Crc32.hash(bytes);
        const c = sys.local(at_ms);
        const year: u16 = @intCast(@max(1980, @min(2107, c.year)));
        const dos_time: u16 = @intCast((@as(u32, c.hour) << 11) | (@as(u32, c.minute) << 5) | (@as(u32, c.second) / 2));
        const dos_date: u16 = @intCast((@as(u32, year - 1980) << 9) | (@as(u32, c.month) << 5) | @as(u32, c.day));
        const offset: u32 = @intCast(z.out.items.len);
        const size: u32 = @intCast(bytes.len);
        // Local header.
        le32(&z.out, a, 0x04034b50);
        le16(&z.out, a, 20);
        le16(&z.out, a, 0x0800); // names in UTF-8
        le16(&z.out, a, 0); // stored
        le16(&z.out, a, dos_time);
        le16(&z.out, a, dos_date);
        le32(&z.out, a, crc);
        le32(&z.out, a, size);
        le32(&z.out, a, size);
        le16(&z.out, a, @intCast(name.len));
        le16(&z.out, a, 0);
        z.out.appendSlice(a, name) catch {};
        z.out.appendSlice(a, bytes) catch {};
        // Its central directory entry.
        le32(&z.central, a, 0x02014b50);
        le16(&z.central, a, 20);
        le16(&z.central, a, 20);
        le16(&z.central, a, 0x0800);
        le16(&z.central, a, 0);
        le16(&z.central, a, dos_time);
        le16(&z.central, a, dos_date);
        le32(&z.central, a, crc);
        le32(&z.central, a, size);
        le32(&z.central, a, size);
        le16(&z.central, a, @intCast(name.len));
        le16(&z.central, a, 0);
        le16(&z.central, a, 0);
        le16(&z.central, a, 0);
        le16(&z.central, a, 0);
        le32(&z.central, a, 0);
        le32(&z.central, a, offset);
        z.central.appendSlice(a, name) catch {};
        z.count += 1;
    }

    pub fn finish(z: *Zip) []const u8 {
        const a = z.a;
        const cd_offset: u32 = @intCast(z.out.items.len);
        const cd_size: u32 = @intCast(z.central.items.len);
        z.out.appendSlice(a, z.central.items) catch {};
        le32(&z.out, a, 0x06054b50);
        le16(&z.out, a, 0);
        le16(&z.out, a, 0);
        le16(&z.out, a, z.count);
        le16(&z.out, a, z.count);
        le32(&z.out, a, cd_size);
        le32(&z.out, a, cd_offset);
        le16(&z.out, a, 0);
        return z.out.items;
    }
};

test "zip: a stored file reads back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var z: Zip = .{ .a = arena.allocator() };
    z.add("files/a.txt", "hello", 0);
    z.add("messages.txt", "hi there", 0);
    const bytes = z.finish();
    // End of central directory: two entries.
    const eocd = bytes[bytes.len - 22 ..];
    try std.testing.expectEqual(@as(u32, 0x06054b50), std.mem.readInt(u32, eocd[0..4], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, eocd[10..12], .little));
    // The first local header holds "hello" with its CRC.
    try std.testing.expectEqual(std.hash.Crc32.hash("hello"), std.mem.readInt(u32, bytes[14..18], .little));
    try std.testing.expectEqualStrings("hello", bytes[30 + "files/a.txt".len ..][0..5]);
}

test "entities to HTML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try markdown.parse(a, "**bold** and <b>");
    var out: std.ArrayList(u8) = .empty;
    textHtml(&out, a, p.text, p.entities);
    try std.testing.expectEqualStrings("<b>bold</b> and &lt;b&gt;", out.items);
}

// ---------------------------------------------------------------------------------------------
// Views

fn msg(a: Act) Msg {
    return .{ .export_chat = a };
}

fn radio(cx: Cx, label: []const u8, on: bool, m: Msg, k: u64) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 42, .padding = .xy(12, 4), .radius = theme.radius, .pressed_background = cx.c.active }, .{ .on_press = m, .key = k });
    ui.begin(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .radius = 10, .border_width = if (on) 6 else 1.5, .border_color = if (on) cx.c.brand else cx.c.border_strong }, .{});
    ui.end();
    ui.text(label, .{ .font_size = 15, .color = cx.c.text });
    ui.end();
}

pub fn optionsSheet(cx: Cx) void {
    const s = cx.s;
    const o = s.exporter.opts;
    const key = kit.key;
    const encrypted = if (s.store.chat(s.exporter.chat.str())) |c| c.encrypted() else false;
    views.sheet(cx, t("Export chat"));
    kit.sectionNote(cx, if (encrypted) t("The export is built on this device: messages and files are decrypted here and never leave it unencrypted.") else t("Everything is saved to a file on this device."));
    kit.sectionTitle(cx, t("Format"));
    radio(cx, t("Web page (opens in any browser)"), o.format == .html, msg(.{ .format = .html }), key(.{ "fmt", 0 }));
    radio(cx, t("Data (JSON, for programs)"), o.format == .json, msg(.{ .format = .json }), key(.{ "fmt", 1 }));
    radio(cx, t("Plain text"), o.format == .txt, msg(.{ .format = .txt }), key(.{ "fmt", 2 }));
    kit.sectionTitle(cx, t("Include"));
    for (media_kinds, 0..) |g, i| kit.row(cx, t(g.label), .{ .switch_on = o.media[i], .on = msg(.{ .media = @intCast(i) }), .k = key(.{ "mk", i }) });
    kit.sectionTitle(cx, t("Skip files larger than"));
    for (size_limits, 0..) |mb, i| radio(cx, if (mb == 0) t("No limit") else std.fmt.allocPrint(cx.a(), "{d} MB", .{mb}) catch "", o.max_mb == i, msg(.{ .max_mb = @intCast(i) }), key(.{ "mb", i }));
    kit.sectionTitle(cx, t("Period"));
    radio(cx, t("All time"), o.period == .all, msg(.{ .period = .all }), key(.{ "per", 0 }));
    radio(cx, t("Last 30 days"), o.period == .days30, msg(.{ .period = .days30 }), key(.{ "per", 1 }));
    radio(cx, t("Last year"), o.period == .year, msg(.{ .period = .year }), key(.{ "per", 2 }));
    radio(cx, t("Choose dates"), o.period == .custom, msg(.{ .period = .custom }), key(.{ "per", 3 }));
    if (o.period == .custom) {
        cx.ui.begin(.{ .direction = .row, .gap = 10, .padding = .xy(12, 4) }, .{});
        const from = s.fields.get(.export_from).get();
        const to = s.fields.get(.export_to).get();
        vcompose.pickerButton(cx, icons.calendar, if (from.len > 0) from else t("From"), msg(.pick_from));
        vcompose.pickerButton(cx, icons.calendar, if (to.len > 0) to else t("To"), msg(.pick_to));
        cx.ui.end();
    }
    cx.ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .top = 8, .bottom = 8, .end = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, t("Export"), msg(.start), .{ .icon = icons.download });
    cx.ui.end();
    views.endSheet(cx);
}

pub fn progressSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const r = s.exporter.run orelse return;
    const name = if (s.store.chat(r.chat.str())) |c| s.store.title(c) else "";
    views.sheet(cx, fmt.tf("Exporting {name}", .{ .name = name }));
    ui.begin(.{ .padding = .xy(12, 8), .gap = 10 }, .{});
    const a = cx.a();
    const status, const frac: f32, const detail = switch (r.phase) {
        .loading => .{ t("Loading messages…"), 0, fmt.tn(a, @intCast(r.msgs.items.len), "{n} message", "{n} messages") },
        .decrypting => .{ t("Decrypting…"), 0.2, "" },
        .files => .{ t("Downloading files…"), if (r.items.items.len == 0) 1 else @as(f32, @floatFromInt(r.cur)) / @as(f32, @floatFromInt(r.items.items.len)), std.fmt.allocPrint(a, "{d} / {d}", .{ r.cur, r.items.items.len }) catch "" },
        .packing => .{ t("Packing…"), 1, "" },
    };
    ui.text(status, .{ .font_size = 15, .weight = 600, .color = cx.c.text });
    ui.begin(.{ .direction = .row, .height = .{ .px = 6 }, .radius = 3, .background = cx.c.surface_3, .clip = true }, .{});
    const pct: f32 = @max(0, @min(1, frac)) * 100;
    if (pct > 0) {
        ui.begin(.{ .grow = pct, .height = .{ .px = 6 }, .background = cx.c.brand }, .{});
        ui.end();
    }
    if (pct < 100) {
        ui.begin(.{ .grow = 100 - pct, .height = .{ .px = 6 } }, .{});
        ui.end();
    }
    ui.end();
    if (detail.len > 0) ui.text(detail, .{ .font_size = 13, .color = cx.c.text_2 });
    ui.begin(.{ .direction = .row, .justify = .end, .padding = .{ .top = 6 } }, .{});
    kit.button(cx, t("Cancel"), msg(.cancel), .{ .kind = .ghost });
    ui.end();
    ui.end();
    views.endSheet(cx);
}
