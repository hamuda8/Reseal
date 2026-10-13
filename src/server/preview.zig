//! Link previews (title, description, image) from Open Graph tags (src/services/preview.js).
//! Fetches are size- and time-limited and never reach private networks.

const std = @import("std");
const Io = std.Io;
const A = @import("app.zig");
const fetch = @import("lib/fetch.zig");
const v = @import("validate.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

const MAX_BYTES = 512 * 1024;

const Entry = struct { at: i64, json: ?[]u8 };
var lock: Io.Mutex = .init;
var cache: std.StringArrayHashMapUnmanaged(Entry) = .empty;

fn decode(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            const ents = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" }, .{ "&apos;", "'" } };
            var matched = false;
            for (ents) |e| if (std.mem.startsWith(u8, s[i..], e[0])) {
                try out.appendSlice(a, e[1]);
                i += e[0].len;
                matched = true;
                break;
            };
            if (matched) continue;
            if (std.mem.startsWith(u8, s[i..], "&#")) {
                const semi = std.mem.indexOfScalarPos(u8, s, i, ';');
                if (semi) |e| {
                    const body = s[i + 2 .. e];
                    const cp = if (body.len > 0 and (body[0] == 'x' or body[0] == 'X')) std.fmt.parseInt(u21, body[1..], 16) catch null else std.fmt.parseInt(u21, body, 10) catch null;
                    if (cp) |c| {
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(c, &buf) catch 0;
                        try out.appendSlice(a, buf[0..n]);
                        i = e + 1;
                        continue;
                    }
                }
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    // .replace(/\s+/g, ' ').trim()
    var col: std.ArrayList(u8) = .empty;
    var space = false;
    for (out.items) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = true;
        } else {
            if (space and col.items.len > 0) try col.append(a, ' ');
            space = false;
            try col.append(a, c);
        }
    }
    return col.items;
}

fn indexOfI(hay: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0 or hay.len < needle.len) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += 1) if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    return null;
}

/// The content of the first <meta property|name="…"> among `names`.
fn meta(a: std.mem.Allocator, html: []const u8, names: []const []const u8) !?[]const u8 {
    for (names) |name| {
        var pos: usize = 0;
        while (indexOfI(html, "<meta", pos)) |start| {
            const end = std.mem.indexOfScalarPos(u8, html, start, '>') orelse break;
            const tag = html[start .. end + 1];
            pos = end + 1;
            var matched = false;
            for ([_][]const u8{ "property=", "name=" }) |attr| {
                if (indexOfI(tag, attr, 0)) |ai| {
                    const q = ai + attr.len;
                    if (q < tag.len and (tag[q] == '"' or tag[q] == '\'')) {
                        const rest = tag[q + 1 ..];
                        if (rest.len > name.len and std.ascii.eqlIgnoreCase(rest[0..name.len], name) and (rest[name.len] == '"' or rest[name.len] == '\'')) matched = true;
                    }
                }
            }
            if (!matched) continue;
            const ci = indexOfI(tag, "content=", 0) orelse continue;
            const q = ci + 8;
            if (q >= tag.len or (tag[q] != '"' and tag[q] != '\'')) continue;
            const close = std.mem.indexOfAnyPos(u8, tag, q + 1, "\"'") orelse continue;
            const content = tag[q + 1 .. close];
            if (content.len > 0) return try decode(a, content);
            break;
        }
    }
    return null;
}

fn fetchLimited(r: *Rq, url_in: []const u8) !struct { url: []const u8, html: []const u8 } {
    var url = url_in;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        try fetch.assertPublicUrl(url);
        const res = try fetch.fetch(r.a, url, .{
            .timeout_ms = 6000,
            .max_bytes = 4 << 20,
            .user_agent = "Mozilla/5.0 (compatible; ResealBot/1.0; +link-preview)",
            .headers = &.{.{ .name = "Accept", .value = "text/html,application/xhtml+xml" }},
        });
        if (res.status >= 300 and res.status < 400 and res.location != null and res.location.?.len < 2048 and hops < 3) {
            const base = try std.Uri.parse(url);
            var buf: [4096]u8 = undefined;
            @memcpy(buf[0..res.location.?.len], res.location.?);
            var aux: []u8 = buf[0..];
            const next = try std.Uri.resolveInPlace(base, res.location.?.len, &aux);
            url = try std.fmt.allocPrint(r.a, "{f}", .{next});
            continue;
        }
        const ct = res.content_type;
        if (res.status < 200 or res.status >= 300 or !(std.mem.indexOf(u8, ct, "text/html") != null or std.mem.indexOf(u8, ct, "xhtml") != null)) return .{ .url = url, .html = "" };
        var html = res.body[0..@min(res.body.len, MAX_BYTES)];
        if (indexOfI(html, "</head>", 0)) |h| html = html[0 .. h + 7];
        return .{ .url = url, .html = html };
    }
}

pub fn linkPreview(r: *Rq, raw_url: []const u8) !Val {
    const a = r.a;
    const key = v.sliceUtf16(raw_url, 2048);
    const gpa = A.app.gpa;
    {
        lock.lockUncancelable(A.app.io);
        defer lock.unlock(A.app.io);
        if (cache.get(key)) |hit| if (A.nowMs() - hit.at < 3600_000) return if (hit.json) |j| try val.parseJson(a, j) else .null;
    }
    var value: Val = .null;
    if (fetchLimited(r, key)) |res| { if (res.html.len > 0) {
        const html = res.html;
        var title = try meta(a, html, &.{ "og:title", "twitter:title" });
        if (title == null) if (indexOfI(html, "<title", 0)) |t| {
            const gt = std.mem.indexOfScalarPos(u8, html, t, '>') orelse t;
            const end = std.mem.indexOfScalarPos(u8, html, gt, '<') orelse gt;
            const d = try decode(a, html[@min(gt + 1, end)..end]);
            if (d.len > 0) title = d;
        };
        const description = try meta(a, html, &.{ "og:description", "twitter:description", "description" });
        var image = try meta(a, html, &.{ "og:image", "og:image:url", "twitter:image" });
        if (image) |img| {
            const base = std.Uri.parse(res.url) catch null;
            if (base) |b| {
                var buf: [4096]u8 = undefined;
                if (img.len <= buf.len) {
                    @memcpy(buf[0..img.len], img);
                    var aux: []u8 = buf[0..];
                    image = if (std.Uri.resolveInPlace(b, img.len, &aux)) |u| try std.fmt.allocPrint(a, "{f}", .{u}) else |_| null;
                } else image = null;
            }
        }
        var site = try meta(a, html, &.{"og:site_name"});
        if (site == null) if (std.Uri.parse(res.url) catch null) |u| if (u.host) |h| {
            var hb: [256]u8 = undefined;
            const host = h.toRaw(&hb) catch "";
            site = try a.dupe(u8, if (std.mem.startsWith(u8, host, "www.")) host[4..] else host);
        };
        if (title != null or description != null) {
            const img_ok = if (image) |i| std.mem.startsWith(u8, i, "http://") or std.mem.startsWith(u8, i, "https://") else false;
            value = try val.from(a, .{
                .url = key,
                .title = if (title) |t| (if (t.len > 0) Val{ .str = v.sliceUtf16(t, 300) } else Val.null) else Val.null,
                .description = if (description) |d| (if (d.len > 0) Val{ .str = v.sliceUtf16(d, 600) } else Val.null) else Val.null,
                .siteName = if (site) |s| (if (s.len > 0) Val{ .str = v.sliceUtf16(s, 120) } else Val.null) else Val.null,
                .image = if (img_ok) Val{ .str = v.sliceUtf16(image.?, 2048) } else Val.null,
            });
        }
    } } else |_| {}
    lock.lockUncancelable(A.app.io);
    defer lock.unlock(A.app.io);
    if (cache.count() > 1000) {
        const k = cache.keys()[0];
        const e = cache.values()[0];
        cache.orderedRemoveAt(0);
        gpa.free(k);
        if (e.json) |j| gpa.free(j);
    }
    if (cache.fetchOrderedRemove(key)) |old| {
        gpa.free(old.key);
        if (old.value.json) |j| gpa.free(j);
    }
    const json: ?[]u8 = if (value == .null) null else try gpa.dupe(u8, try val.stringify(a, value));
    try cache.put(gpa, try gpa.dupe(u8, key), .{ .at = A.nowMs(), .json = json });
    return value;
}
