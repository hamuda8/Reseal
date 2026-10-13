//! Files: uploading (encrypted chunk by chunk in encrypted chats) and getting them back to show
//! (decrypted here, then shown as a data: address) or save. Port of Reseal-js data/media.js.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const crypto = @import("crypto.zig");
const send = @import("send.zig");
const sys = @import("sys.zig");

const State = app.State;
const Id = app.Id;
const gpa = app.gpa;
const t = zui.i18n.t;
const tmp = app.tmp;

/// Public files (avatars) by id.
pub fn mediaUrl(a: std.mem.Allocator, id: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}/m/{s}", .{ app.server, id }) catch "";
}

// ---------------------------------------------------------------------------------------------
// Uploads

pub const Meta = struct {
    name: []const u8,
    mime: []const u8,
    thumb: ?[]const u8 = null,
    w: ?i64 = null,
    h: ?i64 = null,
    duration: ?f64 = null,
    encrypted: bool,
};

const Upload = struct {
    id: u32,
    local: u32,
    bytes: []u8,
    meta_json: []u8,
    kind: []const u8,
    encrypted: bool,
    fk: crypto.FileKey,
    media: Id = .{},
    chunks: u32 = 0,
    chunk_size: usize = 0,
    next: u32 = 0,
    done: u32 = 0,
};

pub const Cache = struct {
    uploads: std.ArrayList(Upload) = .empty,
    next_upload: u32 = 1,
    /// Files shown or saved: media id -> entry.
    files: std.StringHashMapUnmanaged(File) = .empty,
};

pub const FileState = enum { loading, ready, failed };

pub const File = struct {
    state: FileState = .loading,
    /// What to show: a signed link (plain chats) or a data: address (decrypted).
    url: []u8 = "",
    key: ?crypto.FileKey = null,
    mime: []u8 = "",
    name: []u8 = "",
    chunks: u32 = 0,
    parts: std.ArrayList(u8) = .empty,
    next: u32 = 0,
    /// Save it once ready (Download).
    save: bool = false,
};

const parallel = 3;

pub fn kindOf(mime: []const u8) []const u8 {
    const images = [_][]const u8{ "image/jpeg", "image/png", "image/webp", "image/avif" };
    for (images) |m| if (std.mem.eql(u8, mime, m)) return "photo";
    if (std.mem.eql(u8, mime, "image/gif")) return "gif";
    const videos = [_][]const u8{ "video/mp4", "video/webm", "video/quicktime", "video/ogg" };
    for (videos) |m| if (std.mem.eql(u8, mime, m)) return "video";
    if (std.mem.startsWith(u8, mime, "audio/")) return "audio";
    return "file";
}

/// Starts uploading `bytes` (owned from now on) for message `local`; returns the upload's id.
pub fn startUpload(s: *State, local: u32, bytes: []u8, meta: Meta) ?u32 {
    const a = tmp();
    const kind = kindOf(meta.mime);
    var mj: std.ArrayList(u8) = .empty;
    mj.print(a, "\"kind\":\"{s}\",\"name\":{s},\"mime\":{s},\"size\":{d}", .{ kind, j.quote(a, meta.name) catch return null, j.quote(a, meta.mime) catch return null, bytes.len }) catch return null;
    if (meta.w) |w| mj.print(a, ",\"w\":{d}", .{w}) catch {};
    if (meta.h) |h| mj.print(a, ",\"h\":{d}", .{h}) catch {};
    if (meta.duration) |d| mj.print(a, ",\"duration\":{d}", .{d}) catch {};
    if (meta.thumb) |th| mj.print(a, ",\"thumb\":{s}", .{j.quote(a, th) catch "\"\""}) catch {};
    const id = s.files.next_upload;
    s.files.next_upload += 1;
    s.files.uploads.append(gpa, .{
        .id = id,
        .local = local,
        .bytes = bytes,
        .meta_json = gpa.dupe(u8, mj.items) catch return null,
        .kind = kind,
        .encrypted = meta.encrypted,
        .fk = crypto.newFileKey(sys.random()),
    }) catch return null;
    const body = std.fmt.allocPrint(a, "{{\"size\":{d},\"encrypted\":{},\"mime\":{s},\"name\":{s},\"purpose\":\"message\"}}", .{ bytes.len, meta.encrypted, j.quote(a, meta.mime) catch return null, j.quote(a, meta.name) catch return null }) catch return null;
    app.api(s, .POST, "/media", body, .{ .upload_create = .{ .local = local, .file = id } });
    return id;
}

fn upload(s: *State, id: u32) ?*Upload {
    for (s.files.uploads.items) |*u| if (u.id == id) return u;
    return null;
}

fn dropUpload(s: *State, id: u32) void {
    for (s.files.uploads.items, 0..) |u, i| if (u.id == id) {
        gpa.free(u.bytes);
        gpa.free(u.meta_json);
        _ = s.files.uploads.orderedRemove(i);
        return;
    };
}

pub fn cancelUploads(s: *State, local: u32) void {
    var i: usize = 0;
    while (i < s.files.uploads.items.len) {
        const u = s.files.uploads.items[i];
        if (u.local == local) dropUpload(s, u.id) else i += 1;
    }
}

fn sendChunk(s: *State, u: *Upload) void {
    if (u.next >= u.chunks) return;
    const n = u.next;
    u.next += 1;
    const start = n * u.chunk_size;
    const end = @min(u.bytes.len, start + u.chunk_size);
    var chunk: []const u8 = u.bytes[start..end];
    if (u.encrypted) chunk = crypto.encryptChunk(tmp(), u.fk, n, n == u.chunks - 1, chunk) catch return;
    app.request(s, .PUT, std.fmt.allocPrint(tmp(), "/media/{s}/chunks/{d}", .{ u.media.str(), n }) catch return, chunk, "application/octet-stream", .{ .upload_chunk = .{ .local = u.local, .file = u.id, .index = n } });
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    switch (op) {
        .upload_create => |x| {
            const u = upload(s, x.file) orelse return true;
            if (!r.ok()) {
                send.fileFailed(s, x.local, app.apiError(r).message);
                dropUpload(s, x.file);
                return true;
            }
            const v = j.parse(tmp(), r.body);
            u.media = Id.of(j.strOr(v, "id", ""));
            u.chunks = @intCast(@max(1, j.intOr(v, "chunks", 1)));
            u.chunk_size = @intCast(@max(1, j.intOr(v, "chunkSize", 1 << 20)));
            for (0..parallel) |_| sendChunk(s, u);
        },
        .upload_chunk => |x| {
            const u = upload(s, x.file) orelse return true;
            if (!r.ok()) {
                send.fileFailed(s, x.local, app.apiError(r).message);
                dropUpload(s, x.file);
                return true;
            }
            u.done += 1;
            send.progress(s, x.local, @as(f32, @floatFromInt(u.done)) / @as(f32, @floatFromInt(u.chunks)));
            if (u.done == u.chunks) {
                app.api(s, .POST, std.fmt.allocPrint(tmp(), "/media/{s}/complete", .{u.media.str()}) catch return true, "{}", .{ .upload_complete = .{ .local = x.local, .file = x.file } });
            } else sendChunk(s, u);
        },
        .upload_complete => |x| {
            const u = upload(s, x.file) orelse return true;
            if (!r.ok()) {
                send.fileFailed(s, x.local, app.apiError(r).message);
                dropUpload(s, x.file);
                return true;
            }
            const a = tmp();
            const key_part = if (u.encrypted)
                std.fmt.allocPrint(a, ",\"key\":\"{s}\",\"iv\":\"{s}\"", .{ crypto.toB64(a, &u.fk.key) catch "", crypto.toB64(a, &u.fk.iv) catch "" }) catch ""
            else
                "";
            const item = std.fmt.allocPrint(a, "{{\"id\":\"{s}\",{s}{s}}}", .{ u.media.str(), u.meta_json, key_part }) catch return true;
            const local = u.local;
            const id = u.id;
            dropUpload(s, id);
            send.fileReady(s, local, id, item);
        },
        .media_info => |x| onInfo(s, x.media.str(), r),
        .media_chunk => |x| onChunk(s, x.media.str(), x.index, r),
        else => return false,
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Downloads

/// The file of a message's media item, starting to fetch it if needed. `item` is the media
/// object ({id, key?, iv?, mime, name, ...}).
pub fn file(s: *State, item: j.Value, save: bool) ?*File {
    const id = j.str(item, "id") orelse return null;
    if (s.files.files.getPtr(id)) |f| {
        if (save and f.state == .ready) saveFile(f) else if (save) f.save = true;
        return f;
    }
    const k = gpa.dupe(u8, id) catch return null;
    const gop = s.files.files.getOrPut(gpa, k) catch return null;
    gop.value_ptr.* = .{ .save = save };
    const f = gop.value_ptr;
    f.mime = gpa.dupe(u8, j.strOr(item, "mime", "application/octet-stream")) catch "";
    f.name = gpa.dupe(u8, j.strOr(item, "name", "file")) catch "";
    if (j.str(item, "key")) |kb| {
        f.key = crypto.fileKeyFromB64(tmp(), kb, j.strOr(item, "iv", "")) catch null;
        if (f.key == null) f.state = .failed;
    }
    app.api(s, .GET, std.fmt.allocPrint(tmp(), "/media/{s}", .{id}) catch return f, null, .{ .media_info = .{ .media = Id.of(id) } });
    return f;
}

/// What a media item shows right now, without fetching (views are read-only).
pub fn shown(s: *const State, item: j.Value) ?*const File {
    const id = j.str(item, "id") orelse return null;
    return s.files.files.getPtr(id);
}

fn onInfo(s: *State, id: []const u8, r: zui.Response) void {
    const f = s.files.files.getPtr(id) orelse return;
    if (!r.ok()) {
        f.state = .failed;
        return;
    }
    const v = j.parse(tmp(), r.body);
    if (f.key == null) {
        // A plain file plays straight from its signed link.
        f.url = gpa.dupe(u8, j.strOr(v, "media.url", "")) catch "";
        f.state = .ready;
        if (f.save) saveFile(f);
        return;
    }
    f.chunks = @intCast(@max(1, j.intOr(v, "media.chunks", 1)));
    // One at a time keeps the parts in order.
    fetchChunk(s, id, f);
}

fn fetchChunk(s: *State, id: []const u8, f: *File) void {
    const n = f.next;
    f.next += 1;
    app.api(s, .GET, std.fmt.allocPrint(tmp(), "/media/{s}/chunks/{d}", .{ id, n }) catch return, null, .{ .media_chunk = .{ .media = Id.of(id), .index = n } });
}

fn onChunk(s: *State, id: []const u8, index: u32, r: zui.Response) void {
    const f = s.files.files.getPtr(id) orelse return;
    if (!r.ok() or f.key == null) {
        f.state = .failed;
        return;
    }
    const plain = crypto.decryptChunk(tmp(), f.key.?, index, index == f.chunks - 1, r.body) catch {
        f.state = .failed;
        return;
    };
    f.parts.appendSlice(gpa, plain) catch return;
    if (index + 1 < f.chunks) return fetchChunk(s, id, f);
    // Done: a data: address the image views (and the web shell's save) take.
    const enc = std.base64.standard.Encoder;
    const prefix = std.fmt.allocPrint(tmp(), "data:{s};base64,", .{f.mime}) catch return;
    const url = gpa.alloc(u8, prefix.len + enc.calcSize(f.parts.items.len)) catch return;
    @memcpy(url[0..prefix.len], prefix);
    _ = enc.encode(url[prefix.len..], f.parts.items);
    f.parts.clearAndFree(gpa);
    f.url = url;
    f.state = .ready;
    if (f.save) saveFile(f);
}

/// Saves a file on the device. The web shell downloads it; phones have no way yet (zui has no
/// "save file" effect), so they open plain links in the browser.
fn saveFile(f: *File) void {
    f.save = false;
    if (zui.platform == .web) {
        const a = tmp();
        app.post(std.fmt.allocPrint(a, "{{\"t\":\"save\",\"name\":{s},\"url\":{s}}}", .{ j.quote(a, f.name) catch "\"file\"", j.quote(a, f.url) catch "\"\"" }) catch return);
    } else if (!std.mem.startsWith(u8, f.url, "data:")) app.fx.openUrl(f.url, true);
}
