//! Glimpses (stories; Reseal-js ui/stories.js, data/stories.js): the row of circles above the chat
//! list, the full-screen viewer (progress bars, tap to move, pause, views, reply), posting a text,
//! photo or camera glimpse to an audience, keeping one on the profile, the archive and the
//! glimpses people pinned to their profile.
//!
//! End-to-end encrypted as in e2ee.js sealStory/openStory: a random key per glimpse, the payload
//! sealed like a chat message in the context "story:<ref>" (epoch 1), the key wrapped for me and
//! each viewer. The private keys stay in zui.keys: wraps are opened with fx.key (ECDH + AES-GCM)
//! and signatures are filled in by keys.apiSigned.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");
const crypto = @import("crypto.zig");
const media = @import("media.zig");
const icons = @import("icons.zig");
const fmt = @import("fmt.zig");
const theme = @import("theme.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");
const vlist = @import("view_list.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const Color = zui.Color;
const t = zui.i18n.t;
const tmp = app.tmp;
const gpa = app.gpa;
const key = kit.key;

const photo_ms = 6000;
const max_video_ms = 60_000;

/// Backgrounds of text glimpses (Reseal-js BACKGROUNDS; the index is stored in the message, so
/// there are still six): the first is the one gradient a screen may carry, accent to variant;
/// the rest are flat roles. Fixed light-mode roles, so a glimpse looks the same for everyone.
pub const backgrounds_len: usize = 6;

fn bgFill(bg: usize) Color {
    return switch (@min(bg, backgrounds_len - 1)) {
        0, 1 => theme.accent,
        2 => theme.variant,
        3 => theme.core,
        4 => theme.surface,
        else => theme.depth,
    };
}

fn bgGradient(bg: usize) ?zui.Gradient {
    return if (bg == 0) zui.Gradient.two(135, theme.accent, theme.variant) else null;
}

/// Text on a background: base or core, whichever reads better.
fn bgText(bg: usize) Color {
    return theme.furtherFrom(bgFill(bg), theme.base, theme.core);
}

pub const Audience = enum { contacts, chats, selected };

pub const Act = union(enum) {
    open_group: Id,
    open_list: u16,
    close,
    next,
    prev,
    pause,
    tick: u32,
    viewers,
    more,
    pin,
    delete,
    delete_confirmed,
    reply,
    like,
    // Posting
    new,
    pick_photo,
    take_photo,
    pick_video,
    text,
    bg: u8,
    audience: Audience,
    pick_people,
    person: Id,
    keep,
    share,
    // Archive and profiles
    archive,
    pinned_of: Id,
};

const Opened = struct { payload: *data.Obj };

pub const Viewer = struct {
    /// Watching the feed (by person) or a list (the archive, a profile).
    from_list: bool = false,
    user: Id = .{},
    index: usize = 0,
    started: i64 = 0,
    paused: bool = false,
    duration: i64 = photo_ms,
    player: u32 = 0,
    seq: u32 = 0,
};

pub const Draft = struct {
    kind: enum { text, photo, video } = .text,
    mime: app.Text = .{},
    bg: u8 = 0,
    photo: []u8 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    audience: Audience = .contacts,
    selected: std.ArrayList(Id) = .empty,
    keep: bool = false,
    busy: bool = false,
    // The upload of the photo.
    media: Id = .{},
    fk: crypto.FileKey = undefined,
    chunks: u32 = 0,
    chunk_size: usize = 0,
    next: u32 = 0,
};

pub const Stories = struct {
    feed: ?*data.Obj = null,
    /// The archive or someone's pinned glimpses, being watched or listed.
    list: ?*data.Obj = null,
    list_title: app.Text = .{},
    audience_users: ?*data.Obj = null,
    views: ?*data.Obj = null,
    opened: std.StringHashMapUnmanaged(*data.Obj) = .empty,
    failed: std.StringHashMapUnmanaged(void) = .empty,
    /// zui.keys request -> the glimpse whose key it opens.
    unwraps: std.AutoHashMapUnmanaged(u32, Id) = .empty,
    viewer: ?Viewer = null,
    draft: Draft = .{},
    pending_delete: Id = .{},
    reply_text: app.Text = .{},
};

fn path(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(tmp(), f, args) catch "";
}

fn replace(slot: *?*data.Obj, v: ?j.Value) void {
    if (slot.*) |o| o.destroy();
    slot.* = if (v) |x| data.Obj.create(x) catch null else null;
}

pub fn enabled(s: *const State) bool {
    if (s.mode != .app) return false;
    const me = s.store.me orelse return false;
    return !me.b("guest");
}

pub fn load(s: *State) void {
    if (!enabled(s)) return;
    app.api(s, .GET, "/stories", null, .stories_feed);
}

/// story.new / story.delete / story.view / story.pin from the socket.
pub fn onSocket(s: *State, typ: []const u8, d: j.Value) void {
    if (std.mem.eql(u8, typ, "story.view")) {
        if (findMut(s, j.strOr(d, "id", ""))) |st| setField(s.stories.feed.?, st, "viewCount", .{ .integer = j.intOr(d, "viewCount", 0) });
        return;
    }
    if (std.mem.eql(u8, typ, "story.pin")) {
        if (findMut(s, j.strOr(d, "id", ""))) |st| setField(s.stories.feed.?, st, "pinned", data.boolean(j.truthy(d, "pinned")));
        return;
    }
    load(s);
}

fn findMut(s: *State, id: []const u8) ?*j.Value {
    const f = s.stories.feed orelse return null;
    const arr = f.v.object.getPtr("stories") orelse return null;
    if (arr.* != .array) return null;
    for (arr.array.items) |*st| if (j.eqlStr(st.*, "id", id)) return st;
    return null;
}

fn setField(o: *data.Obj, v: *j.Value, k: []const u8, val: j.Value) void {
    if (v.* != .object) return;
    const a = o.alloc();
    v.object.put(a, a.dupe(u8, k) catch return, val) catch {};
}

fn expired(st: j.Value) bool {
    const e = sys.parseIso(j.strOr(st, "expiresAt", "")) orelse return false;
    return e <= sys.now();
}

pub const Group = struct { user: []const u8, stories: []j.Value, unseen: bool, latest: i64, mine: bool };

/// The feed by person: mine first, then unseen, then newest.
pub fn groups(s: *const State, a: std.mem.Allocator) []Group {
    var out: std.ArrayList(Group) = .empty;
    const f = s.stories.feed orelse return out.items;
    for (j.arr(f.v, "stories")) |st| {
        if (expired(st)) continue;
        const uid = j.strOr(st, "userId", "");
        const at = sys.parseIso(j.strOr(st, "createdAt", "")) orelse 0;
        const g = for (out.items) |*g| {
            if (std.mem.eql(u8, g.user, uid)) break g;
        } else blk: {
            out.append(a, .{ .user = uid, .stories = &.{}, .unseen = false, .latest = 0, .mine = s.store.isMe(uid) }) catch return out.items;
            break :blk &out.items[out.items.len - 1];
        };
        var list: std.ArrayList(j.Value) = .fromOwnedSlice(g.stories);
        list.append(a, st) catch {};
        g.stories = list.items;
        if (!j.truthy(st, "seen")) g.unseen = true;
        g.latest = @max(g.latest, at);
    }
    std.mem.sort(Group, out.items, {}, struct {
        fn lt(_: void, x: Group, y: Group) bool {
            if (x.mine != y.mine) return x.mine;
            if (x.unseen != y.unseen) return x.unseen;
            return x.latest > y.latest;
        }
    }.lt);
    return out.items;
}

/// The glimpse being watched.
fn current(s: *const State, a: std.mem.Allocator) ?j.Value {
    const v = s.stories.viewer orelse return null;
    if (v.from_list) {
        const l = s.stories.list orelse return null;
        const list = j.arr(l.v, "stories");
        return if (v.index < list.len) list[v.index] else null;
    }
    for (groups(s, a)) |g| if (std.mem.eql(u8, g.user, v.user.str())) {
        return if (v.index < g.stories.len) g.stories[v.index] else null;
    };
    return null;
}

fn userName(s: *const State, uid: []const u8) []const u8 {
    if (s.store.isMe(uid)) return t("Your glimpse");
    return s.store.displayName(uid);
}

pub fn act(s: *State, a: Act) void {
    const st = &s.stories;
    switch (a) {
        .open_group => |uid| {
            var index: usize = 0;
            for (groups(s, tmp())) |g| if (std.mem.eql(u8, g.user, uid.str())) {
                for (g.stories, 0..) |x, i| if (!j.truthy(x, "seen")) {
                    index = i;
                    break;
                };
            };
            st.viewer = .{ .user = uid, .index = index };
            show(s);
        },
        .open_list => |i| {
            st.viewer = .{ .from_list = true, .index = i };
            s.modal = null;
            show(s);
        },
        .close => close(s),
        .next => step(s, 1),
        .prev => step(s, -1),
        .pause => if (st.viewer) |*v| {
            v.paused = !v.paused;
            if (v.player != 0) {
                if (v.paused) app.fx.pausePlayback(v.player) else app.fx.resumePlayback(v.player);
            }
            if (!v.paused) v.started = sys.now() - elapsedOf(v);
        },
        .tick => |seq| tick(s, seq),
        .viewers => {
            const story = current(s, tmp()) orelse return;
            pauseFor(s);
            replace(&st.views, null);
            s.modal = .story_views;
            app.api(s, .GET, path("/stories/{s}/views", .{j.strOr(story, "id", "")}), null, .stories_views);
        },
        .more => {
            pauseFor(s);
            s.modal = .story_menu;
        },
        .pin => {
            s.modal = null;
            const story = current(s, tmp()) orelse return;
            const on = !j.truthy(story, "pinned");
            app.api(s, .POST, path("/stories/{s}/pin", .{j.strOr(story, "id", "")}), if (on) "{\"pinned\":true}" else "{\"pinned\":false}", .{ .stories_pinned = on });
        },
        .delete => {
            const story = current(s, tmp()) orelse return;
            st.pending_delete = Id.of(j.strOr(story, "id", ""));
            s.modal = .{ .confirm = .{ .kind = .delete_story } };
        },
        .delete_confirmed => if (st.pending_delete.isSet()) {
            app.api(s, .DELETE, path("/stories/{s}", .{st.pending_delete.str()}), null, .stories_deleted);
        },
        .reply, .like => {
            const story = current(s, tmp()) orelse return;
            const text = if (a == .like) "❤️" else std.mem.trim(u8, s.fields.get(.story_reply).get(), " \t\r\n");
            if (text.len == 0) return;
            const uid = j.strOr(story, "userId", "");
            // The reply goes into the private chat with the author.
            s.fields.getPtr(.story_reply).clear();
            st.reply_text.set(text);
            app.api(s, .POST, "/chats/private", path("{{\"userId\":\"{s}\"}}", .{uid}), .stories_reply_chat);
        },
        .new => {
            st.draft.busy = false;
            s.modal = .story_kind;
        },
        .pick_photo, .take_photo => {
            s.modal = null;
            app.fx.pickPhoto(.{ .camera = a == .take_photo, .max_size = 1920, .quality = 85 }, onPhoto);
        },
        .pick_video => {
            s.modal = null;
            app.fx.pickFile(.{ .accept = "video/*" }, onPhoto);
        },
        .text => {
            resetDraft(s);
            st.draft.kind = .text;
            openComposer(s);
        },
        .bg => |i| st.draft.bg = @min(i, backgrounds_len - 1),
        .audience => |au| {
            st.draft.audience = au;
            if (au == .selected) s.modal = .story_people;
        },
        .pick_people => s.modal = .story_people,
        .person => |uid| {
            const sel = &st.draft.selected;
            for (sel.items, 0..) |x, i| if (x.eql(uid.str())) {
                _ = sel.orderedRemove(i);
                return;
            };
            sel.append(gpa, uid) catch {};
        },
        .keep => st.draft.keep = !st.draft.keep,
        .share => share(s),
        .archive => {
            st.list_title.set(t("Glimpse archive"));
            replace(&st.list, null);
            s.modal = .story_list;
            app.api(s, .GET, "/stories/archive", null, .stories_list);
        },
        .pinned_of => |uid| {
            st.list_title.set(fmt.tf("Glimpses of {name}", .{ .name = s.store.displayName(uid.str()) }));
            replace(&st.list, null);
            s.modal = .story_list;
            app.api(s, .GET, path("/stories/pinned/{s}", .{uid.str()}), null, .stories_list);
        },
    }
}

fn onPhoto(f: zui.File) Msg {
    return .{ .story_photo = f };
}

/// A photo for a new glimpse (copied: the bytes are only valid now).
pub fn onPicked(s: *State, f: zui.File) void {
    resetDraft(s);
    const d = &s.stories.draft;
    const video = std.mem.startsWith(u8, f.mime, "video/");
    if (!video and !std.mem.startsWith(u8, f.mime, "image/") and f.mime.len > 0) return app.toastError(s, t("Choose a photo or a video."));
    if (f.data.len > 200 * 1024 * 1024) return app.toastError(s, t("Glimpse videos can be up to 200 MB."));
    d.kind = if (video) .video else .photo;
    d.mime.set(if (f.mime.len > 0) f.mime else "image/jpeg");
    d.photo = gpa.dupe(u8, f.data) catch return;
    d.w = f.width;
    d.h = f.height;
    openComposer(s);
}

fn resetDraft(s: *State) void {
    const d = &s.stories.draft;
    if (d.photo.len > 0) gpa.free(d.photo);
    d.photo = &.{};
    d.bg = 0;
    d.busy = false;
    d.media = .{};
    s.fields.getPtr(.story_text).clear();
    s.fields.getPtr(.story_caption).clear();
}

fn openComposer(s: *State) void {
    s.modal = .story_compose;
    if (s.stories.audience_users == null) app.api(s, .GET, "/stories/audience", null, .stories_audience);
}

fn pauseFor(s: *State) void {
    if (s.stories.viewer) |*v| if (!v.paused) {
        v.paused = true;
        if (v.player != 0) app.fx.pausePlayback(v.player);
    };
}

fn elapsedOf(v: *const Viewer) i64 {
    return @max(0, @min(v.duration, sys.now() - v.started));
}

fn close(s: *State) void {
    if (s.stories.viewer) |v| if (v.player != 0) app.fx.stopPlayback(v.player);
    s.stories.viewer = null;
    if (s.modal) |m| if (m == .story_menu or m == .story_views) {
        s.modal = null;
    };
}

fn step(s: *State, dir: i32) void {
    const st = &s.stories;
    var v = &(st.viewer orelse return);
    if (v.player != 0) app.fx.stopPlayback(v.player);
    v.player = 0;
    if (v.from_list) {
        const n = if (st.list) |l| j.arr(l.v, "stories").len else 0;
        if (dir > 0 and v.index + 1 < n) v.index += 1 else if (dir < 0 and v.index > 0) v.index -= 1 else if (dir > 0) return close(s) else v.index = 0;
        return show(s);
    }
    const gs = groups(s, tmp());
    const gi = for (gs, 0..) |g, i| {
        if (std.mem.eql(u8, g.user, v.user.str())) break i;
    } else return close(s);
    const len = gs[gi].stories.len;
    if (dir > 0 and v.index + 1 < len) {
        v.index += 1;
    } else if (dir < 0 and v.index > 0) {
        v.index -= 1;
    } else if (dir > 0 and gi + 1 < gs.len) {
        v.user = Id.of(gs[gi + 1].user);
        v.index = 0;
        for (gs[gi + 1].stories, 0..) |x, i| if (!j.truthy(x, "seen")) {
            v.index = i;
            break;
        };
    } else if (dir < 0 and gi > 0) {
        v.user = Id.of(gs[gi - 1].user);
        v.index = 0;
    } else if (dir > 0) return close(s) else v.index = 0;
    show(s);
}

/// Starts showing the current glimpse: open it (if not yet), mark it seen, start the clock.
fn show(s: *State) void {
    const st = &s.stories;
    var v = &(st.viewer orelse return);
    v.seq +%= 1;
    v.paused = false;
    v.started = sys.now();
    v.duration = photo_ms;
    const story = current(s, tmp()) orelse return close(s);
    const id = j.strOr(story, "id", "");
    if (st.opened.get(id) == null and !st.failed.contains(id)) open(s, story);
    if (!j.truthy(story, "seen") and !st.failed.contains(id)) {
        if (findMut(s, id)) |p| setField(st.feed.?, p, "seen", data.boolean(true));
        app.api(s, .POST, path("/stories/{s}/view", .{id}), "{}", .ignore);
    }
    prepare(s, story);
    app.fx.after(100, .{ .stories = .{ .tick = v.seq } });
}

/// Pictures and videos: fetch (and decrypt) them; a video starts playing once it is here.
fn prepare(s: *State, story: j.Value) void {
    const st = &s.stories;
    const p = st.opened.get(j.strOr(story, "id", "")) orelse return;
    const kind = j.strOr(p.v, "kind", "");
    if (std.mem.eql(u8, kind, "text")) {
        if (st.viewer) |*v| v.duration = @min(15_000, photo_ms + @as(i64, @intCast(j.strOr(p.v, "text", "").len)) * 40);
        return;
    }
    const item = j.obj(p.v, "media") orelse return;
    const f = media.file(s, item, false) orelse return;
    if (std.mem.eql(u8, kind, "video") and f.state == .ready and f.bytes.len > 0) {
        if (st.viewer) |*v| if (v.player == 0) {
            v.player = app.fx.play(.{ .data = f.bytes, .mime = j.strOr(item, "mime", "video/mp4"), .video = true }, onPlay);
        };
    }
}

fn onPlay(e: zui.PlayEvent) Msg {
    return .{ .story_play = e };
}

pub fn onPlayEvent(s: *State, e: zui.PlayEvent) void {
    var v = &(s.stories.viewer orelse return);
    if (e.player != v.player) return;
    switch (e.kind) {
        .ready => {
            v.duration = @min(max_video_ms, if (e.duration_ms > 0) @as(i64, e.duration_ms) else 15_000);
            v.started = sys.now();
        },
        .ended => step(s, 1),
        .failed => {},
        .progress => {},
    }
}

/// Is what the glimpse shows ready (so its clock runs)?
fn ready(s: *State, story: j.Value) bool {
    const st = &s.stories;
    const id = j.strOr(story, "id", "");
    if (st.failed.contains(id)) return true;
    const p = st.opened.get(id) orelse return false;
    if (std.mem.eql(u8, j.strOr(p.v, "kind", ""), "text")) return true;
    const item = j.obj(p.v, "media") orelse return true;
    const f = media.shown(s, item) orelse return false;
    if (f.state == .failed) return true;
    if (f.state != .ready) return false;
    if (std.mem.eql(u8, j.strOr(p.v, "kind", ""), "video")) return st.viewer != null and st.viewer.?.player != 0;
    return true;
}

fn tick(s: *State, seq: u32) void {
    var v = &(s.stories.viewer orelse return);
    if (v.seq != seq) return;
    app.fx.after(100, .{ .stories = .{ .tick = seq } });
    // Sheets over the viewer hold it.
    if (s.modal != null or v.paused) {
        v.started = sys.now() - elapsedOf(v);
        return;
    }
    const story = current(s, tmp()) orelse return close(s);
    if (!ready(s, story)) {
        prepare(s, story);
        v.started = sys.now();
        return;
    }
    if (sys.now() - v.started >= v.duration) step(s, 1);
}

// ---------------------------------------------------------------------------------------------
// Opening (decrypting) a glimpse

fn keyMsg(r: zui.keys.Result) Msg {
    return .{ .key = r };
}

fn keyName(s: *const State, comptime which: []const u8) []const u8 {
    return std.fmt.allocPrint(tmp(), "reseal:{s}:" ++ which, .{s.store.myId()}) catch "reseal:" ++ which;
}

fn context(a: std.mem.Allocator, ref: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "story:{s}", .{ref}) catch "story:";
}

fn authorSig(s: *State, uid: []const u8) ?[]const u8 {
    if (s.store.isMe(uid)) return if (keys.myPublic(s)) |p| p.sig else null;
    return keys.senderSig(s, uid);
}

fn open(s: *State, story: j.Value) void {
    const a = tmp();
    const id = j.strOr(story, "id", "");
    const uid = j.strOr(story, "userId", "");
    const wv = j.obj(story, "key") orelse return markFailed(s, id);
    const sig = authorSig(s, uid) orelse {
        keys.want(s, uid);
        return;
    };
    const w = std.json.parseFromValueLeaky(crypto.Wrap, a, wv, .{ .ignore_unknown_fields = true }) catch return markFailed(s, id);
    const ctx = context(a, j.strOr(story, "ref", ""));
    const text = crypto.wrapSigned(a, ctx, 1, s.store.myId(), w) catch return markFailed(s, id);
    if (!crypto.verify(a, sig, w.sig, text)) return markFailed(s, id);
    const info = crypto.wrapInfo(a, ctx, 1, s.store.myId()) catch return;
    const eph = crypto.fromB64(a, w.eph) catch return markFailed(s, id);
    const iv = crypto.fromB64(a, w.iv) catch return markFailed(s, id);
    const ct = crypto.fromB64(a, w.ct) catch return markFailed(s, id);
    var uit = s.stories.unwraps.valueIterator();
    while (uit.next()) |x| if (x.eql(id)) return; // already asked
    _ = app.fx.key(.{ .op = .ecdh, .name = keyName(s, "enc"), .peer = eph, .salt = eph, .info = info, .into = "reseal:story" }, keyMsg);
    const rid = app.fx.key(.{ .op = .decrypt, .name = "reseal:story", .iv = iv, .aad = info, .data = ct }, keyMsg);
    s.stories.unwraps.put(gpa, rid, Id.of(id)) catch {};
}

fn markFailed(s: *State, id: []const u8) void {
    s.stories.failed.put(gpa, gpa.dupe(u8, id) catch return, {}) catch {};
}

fn storyById(s: *const State, id: []const u8) ?j.Value {
    inline for (.{ s.stories.feed, s.stories.list }) |src| if (src) |o| for (j.arr(o.v, "stories")) |x| {
        if (j.eqlStr(x, "id", id)) return x;
    };
    return null;
}

/// An answer from zui.keys: a glimpse's key (true), or not one of ours (false).
pub fn onKey(s: *State, r: zui.keys.Result) bool {
    const kv = s.stories.unwraps.fetchRemove(r.id) orelse return false;
    const id = kv.value.str();
    if (!r.ok() or r.data.len != 32) {
        markFailed(s, id);
        return true;
    }
    const story = storyById(s, id) orelse return true;
    const a = tmp();
    const uid = j.strOr(story, "userId", "");
    const env = std.json.parseFromValueLeaky(crypto.Envelope, a, j.field(story, "enc") orelse return true, .{ .ignore_unknown_fields = true }) catch return failed(s, id);
    const d = crypto.decryptMessage(a, r.data[0..32].*, env, context(a, j.strOr(story, "ref", "")), uid, authorSig(s, uid)) catch return failed(s, id);
    if (!d.verified) return failed(s, id);
    const v = j.parse(a, d.payload) orelse return failed(s, id);
    const o = data.Obj.create(v) catch return true;
    s.stories.opened.put(gpa, gpa.dupe(u8, id) catch return true, o) catch {};
    if (current(s, a)) |cur| if (j.eqlStr(cur, "id", id)) prepare(s, cur);
    return true;
}

fn failed(s: *State, id: []const u8) bool {
    markFailed(s, id);
    return true;
}

// ---------------------------------------------------------------------------------------------
// Posting

fn share(s: *State) void {
    const st = &s.stories;
    const d = &st.draft;
    if (d.busy) return;
    if (d.kind == .text and s.fields.get(.story_text).trimmed().len == 0) return app.toastError(s, t("Type something"));
    if (keys.myPublic(s) == null) return app.toastError(s, t("Unlock encryption first"));
    d.busy = true;
    if (d.kind != .text) {
        // The photo or video goes up first (encrypted), then the glimpse.
        d.fk = crypto.newFileKey(sys.random());
        d.next = 0;
        const body = path("{{\"size\":{d},\"encrypted\":true,\"mime\":\"{s}\",\"name\":\"glimpse\",\"purpose\":\"story\"}}", .{ d.photo.len, d.mime.get() });
        app.api(s, .POST, "/media", body, .stories_upload_create);
        return;
    }
    seal(s, null);
}

fn sendChunk(s: *State) void {
    const d = &s.stories.draft;
    if (d.next >= d.chunks) return;
    const n = d.next;
    d.next += 1;
    const start = n * d.chunk_size;
    const end = @min(d.photo.len, start + d.chunk_size);
    const chunk = crypto.encryptChunk(tmp(), d.fk, n, n == d.chunks - 1, d.photo[start..end]) catch return;
    app.request(s, .PUT, path("/media/{s}/chunks/{d}", .{ d.media.str(), n }), chunk, "application/octet-stream", .{ .stories_upload_chunk = n });
}

/// Seals the payload for me and the audience and posts it (signatures are filled in by keys).
fn seal(s: *State, media_json: ?[]const u8) void {
    const st = &s.stories;
    const d = &st.draft;
    const a = tmp();
    const me = keys.myPublic(s) orelse return;
    var payload: std.ArrayList(u8) = .empty;
    if (d.kind == .text) {
        payload.print(a, "{{\"v\":1,\"kind\":\"text\",\"text\":{s},\"bg\":{d}", .{ j.quote(a, s.fields.get(.story_text).trimmed()) catch return, d.bg }) catch return;
    } else {
        payload.print(a, "{{\"v\":1,\"kind\":\"{s}\",\"media\":{s}", .{ @tagName(d.kind), media_json orelse return }) catch return;
    }
    const caption = s.fields.get(.story_caption).trimmed();
    if (caption.len > 0 and d.kind != .text) payload.print(a, ",\"caption\":{s}", .{j.quote(a, caption) catch ""}) catch {};
    payload.append(a, '}') catch return;
    var ref_raw: [16]u8 = undefined;
    sys.random().bytes(&ref_raw);
    var ref_buf: [24]u8 = undefined;
    const ref = std.base64.url_safe_no_pad.Encoder.encode(&ref_buf, &ref_raw);
    const ctx = context(a, ref);
    var raw: [32]u8 = undefined;
    sys.random().bytes(&raw);
    const u = crypto.encryptMessageUnsigned(a, sys.random(), raw, payload.items, ctx, 1, s.store.myId()) catch return;
    var env = u.env;
    env.sig = sign(s, u.signed) orelse return;
    var wraps: std.ArrayList(u8) = .empty;
    wraps.append(a, '[') catch return;
    var n: usize = 0;
    // Me, then the audience.
    if (wrapFor(s, a, raw, ctx, s.store.myId(), me.enc)) |w| {
        wraps.appendSlice(a, w) catch {};
        n += 1;
    }
    for (viewers(s)) |vw| {
        const w = wrapFor(s, a, raw, ctx, vw.id, vw.enc) orelse continue;
        wraps.print(a, "{s}{s}", .{ if (n > 0) "," else "", w }) catch {};
        n += 1;
    }
    wraps.append(a, ']') catch return;
    const media_ids = if (d.media.isSet()) path("[\"{s}\"]", .{d.media.str()}) else "[]";
    const body = std.fmt.allocPrint(a, "{{\"ref\":\"{s}\",\"enc\":{s},\"keys\":{s},\"mediaIds\":{s},\"audience\":\"{s}\",\"pinned\":{}}}", .{ ref, crypto.envelopeJson(a, env) catch return, wraps.items, media_ids, @tagName(d.audience), d.keep }) catch return;
    keys.apiSigned(s, .POST, "/stories", body, .stories_posted);
}

fn sign(s: *State, text: []const u8) ?[]const u8 {
    const id = app.fx.key(.{ .op = .sign, .name = keyName(s, "sig"), .data = text }, keyMsg);
    return std.fmt.allocPrint(tmp(), "zui-sig-{d}", .{id}) catch null;
}

fn wrapFor(s: *State, a: std.mem.Allocator, raw: [32]u8, ctx: []const u8, uid: []const u8, enc: []const u8) ?[]const u8 {
    const u = crypto.wrapChatKeyUnsigned(a, sys.random(), raw, ctx, 1, uid, enc) catch return null;
    var w = u.wrap;
    w.sig = sign(s, u.signed) orelse return null;
    return j.stringify(a, w) catch null;
}

const Viewer2 = struct { id: []const u8, enc: []const u8 };

/// The people who will be able to open it.
fn viewers(s: *const State) []Viewer2 {
    var out: std.ArrayList(Viewer2) = .empty;
    const o = s.stories.audience_users orelse return out.items;
    for (j.arr(o.v, "users")) |u| {
        const id = j.strOr(u, "id", "");
        const enc = j.str(u, "keys.enc") orelse continue;
        const ok = switch (s.stories.draft.audience) {
            .contacts => j.truthy(u, "contact"),
            .chats => true,
            .selected => for (s.stories.draft.selected.items) |x| {
                if (x.eql(id)) break true;
            } else false,
        };
        if (ok) out.append(tmp(), .{ .id = id, .enc = enc }) catch {};
    }
    return out.items;
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const st = &s.stories;
    const v = j.parse(tmp(), r.body);
    switch (op) {
        .stories_feed => if (r.ok()) {
            if (v) |x| for (j.arr(x, "users")) |u| {
                _ = s.store.putUser(u) catch null;
            };
            replace(&st.feed, v);
        },
        .stories_list => {
            if (!r.ok()) return toastFail(s, r);
            if (v) |x| for (j.arr(x, "users")) |u| {
                _ = s.store.putUser(u) catch null;
            };
            replace(&st.list, v);
        },
        .stories_audience => if (r.ok()) replace(&st.audience_users, v),
        .stories_views => if (r.ok()) replace(&st.views, v),
        .stories_upload_create => {
            if (!r.ok()) return uploadFailed(s, r);
            st.draft.media = Id.of(j.strOr(v, "id", ""));
            st.draft.chunks = @intCast(@max(1, j.intOr(v, "chunks", 1)));
            st.draft.chunk_size = @intCast(@max(1, j.intOr(v, "chunkSize", 1 << 20)));
            sendChunk(s);
        },
        .stories_upload_chunk => |n| {
            if (!r.ok()) return uploadFailed(s, r);
            if (n + 1 < st.draft.chunks) return sendRest(s);
            app.api(s, .POST, path("/media/{s}/complete", .{st.draft.media.str()}), "{}", .stories_upload_complete);
        },
        .stories_upload_complete => {
            if (!r.ok()) return uploadFailed(s, r);
            const d = &st.draft;
            const a = tmp();
            const mj = std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"key\":\"{s}\",\"iv\":\"{s}\",\"mime\":\"{s}\",\"size\":{d},\"w\":{d},\"h\":{d}}}", .{ d.media.str(), crypto.toB64(a, &d.fk.key) catch return true, crypto.toB64(a, &d.fk.iv) catch return true, d.mime.get(), d.photo.len, d.w, d.h }) catch return true;
            seal(s, mj);
        },
        .stories_posted => {
            st.draft.busy = false;
            if (!r.ok()) return toastFail(s, r);
            s.modal = null;
            app.toast(s, if (st.draft.keep) t("Glimpse shared and kept on your profile.") else t("Glimpse shared. It leaves the feed in 24 hours."));
            resetDraft(s);
            load(s);
        },
        .stories_pinned => |on| {
            if (!r.ok()) return toastFail(s, r);
            if (j.str(v, "story.id")) |id| if (findMut(s, id)) |p| setField(st.feed.?, p, "pinned", data.boolean(on));
            app.toast(s, if (on) t("Pinned to your profile. It stays after 24 hours.") else t("Removed from your profile."));
            if (st.viewer) |*vw| vw.paused = false;
        },
        .stories_deleted => {
            if (!r.ok()) return toastFail(s, r);
            st.pending_delete = .{};
            close(s);
            load(s);
        },
        .stories_reply_chat => {
            if (!r.ok()) return toastFail(s, r);
            const raw = j.obj(v, "chat") orelse return true;
            const c = s.store.putChat(raw) catch return true;
            // A message in that chat that points at the glimpse (messages.js draft.story).
            const story = current(s, tmp());
            const sj = if (story) |x| std.fmt.allocPrint(tmp(), "{{\"id\":\"{s}\",\"thumb\":null,\"at\":{s}}}", .{ j.strOr(x, "id", ""), j.quote(tmp(), j.strOr(x, "createdAt", "")) catch "null" }) catch null else null;
            if (@import("send.zig").queueDraft(s, c.id(), .{ .text = st.reply_text.get(), .story_json = sj }) != null) @import("send.zig").pump(s, c.id());
            app.toast(s, t("Reply sent"));
            if (st.viewer) |*vw| vw.paused = false;
        },
        else => return false,
    }
    return true;
}

fn sendRest(s: *State) bool {
    sendChunk(s);
    return true;
}

fn uploadFailed(s: *State, r: zui.Response) bool {
    s.stories.draft.busy = false;
    return toastFail(s, r);
}

fn toastFail(s: *State, r: zui.Response) bool {
    app.toastError(s, app.apiError(r).message);
    return true;
}

/// A confirmed delete.
pub fn confirmed(s: *State) void {
    act(s, .delete_confirmed);
}

// ---------------------------------------------------------------------------------------------
// Views

fn msg(a: Act) Msg {
    return .{ .stories = a };
}

/// The row of circles above the chat list.
pub fn strip(cx: Cx) void {
    const s = cx.s;
    if (!enabled(s) or s.stories.feed == null) return;
    const gs = groups(s, cx.a());
    const ui = cx.ui;
    ui.beginScroll(.{ .direction = .row, .gap = 4, .padding = .{ .start = 10, .end = 10, .bottom = 6 }, .height = .{ .px = 92 } }, key(.{"stories"}));
    const me = s.store.me;
    var mine = false;
    for (gs) |g| if (g.mine) {
        mine = true;
    };
    if (!mine) circle(cx, if (me) |m| s.store.userName(m) else "?", if (me) |m| m.i("color") orelse 0 else 0, if (me) |m| m.s("avatar") else null, t("Your glimpse"), false, true, msg(.new), key(.{"story-add"}));
    for (gs) |g| {
        const u = s.store.user(g.user);
        const name = if (u) |x| s.store.userName(x) else "…";
        const label = if (g.mine) t("Your glimpse") else fmt.firstName(name);
        circle(cx, name, if (u) |x| x.i("color") orelse 0 else 0, if (u) |x| x.s("avatar") else null, label, g.unseen, g.mine, msg(.{ .open_group = Id.of(g.user) }), key(.{ "story", g.user }));
    }
    ui.end();
}

fn circle(cx: Cx, name: []const u8, color: i64, image: ?[]const u8, label: []const u8, unseen: bool, plus: bool, m: Msg, k: u64) void {
    const ui = cx.ui;
    ui.begin(.{ .width = .{ .px = 70 }, .align_items = .center, .gap = 4, .padding = .xy(0, 4), .radius = 12, .pressed_background = cx.c.hover }, .{ .on_press = m, .on_long_press = if (plus) msg(.archive) else null, .on_context = if (plus) msg(.archive) else null, .key = k });
    ui.begin(.{ .width = .{ .px = 60 }, .height = .{ .px = 60 }, .radius = 20, .border_width = 2.5, .border_color = if (unseen) cx.c.brand else cx.c.border_strong, .align_items = .center, .justify = .center }, .{});
    kit.avatar(cx, .{ .name = name, .color = color, .image = image, .size = 52 }, 0);
    if (plus) {
        ui.begin(.{ .position = .absolute, .inset = .{ .bottom = -2, .end = -2 }, .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 11, .background = cx.c.brand, .border_width = 2, .border_color = cx.c.surface, .align_items = .center, .justify = .center }, .{});
        ui.icon(icons.plus, 13, cx.c.on_accent, .{}, 0);
        ui.end();
    }
    ui.end();
    ui.text(label, .{ .font_size = 12, .color = cx.c.text_2, .max_lines = 1, .text_align = .center });
    ui.end();
}

fn ago(a: std.mem.Allocator, iso: []const u8) []const u8 {
    const at = sys.parseIso(iso) orelse return "";
    const secs = @divTrunc(@max(0, sys.now() - at), 1000);
    if (secs < 60) return t("just now");
    if (secs < 3600) return fmt.tf("{n} min ago", .{ .n = @divTrunc(secs, 60) });
    if (secs < 86400) return fmt.tf("{n} h ago", .{ .n = @divTrunc(secs, 3600) });
    return fmt.shortDate(a, at);
}

/// The full-screen viewer.
pub fn viewer(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const v = s.stories.viewer orelse return;
    const a = cx.a();
    const story = current(s, a) orelse return;
    const id = j.strOr(story, "id", "");
    const uid = j.strOr(story, "userId", "");
    const mine = s.store.isMe(uid);
    const fg = cx.c.on_shade;
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 }, .background = cx.c.shade, .align_items = .center, .justify = .center }, .{ .key = key(.{"story-viewer"}) });
    ui.begin(.{ .width = .fill, .max_width = 480, .height = .fill, .max_height = 860, .radius = if (cx.phone) 0 else 18, .clip = true, .background = cx.c.on_shade.withAlpha(0.04) }, .{});
    // What it shows, behind everything.
    const p = s.stories.opened.get(id);
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 }, .align_items = .center, .justify = .center }, .{});
    if (s.stories.failed.contains(id)) {
        ui.icon(icons.lock, 40, fg, .{}, 0);
        ui.text(t("This glimpse could not be opened"), .{ .font_size = 16, .weight = 700, .color = fg, .text_align = .center });
        ui.text(t("It may have been shared before you set up this device."), .{ .font_size = 13, .color = fg, .opacity = 0.7, .text_align = .center, .max_width = 300 });
    } else if (p) |pl| {
        const kind = j.strOr(pl.v, "kind", "");
        if (std.mem.eql(u8, kind, "text")) {
            const bg: usize = @intCast(@max(0, j.intOr(pl.v, "bg", 0)));
            ui.begin(.{ .width = .fill, .height = .fill, .background = bgFill(bg), .gradient = bgGradient(bg), .align_items = .center, .justify = .center, .padding = .all(28) }, .{});
            ui.text(j.strOr(pl.v, "text", ""), .{ .font_size = 26, .weight = 700, .color = bgText(bg), .text_align = .center, .line_height = 1.35 });
            ui.end();
        } else if (j.obj(pl.v, "media")) |item| {
            if (media.shown(s, item)) |f| {
                if (f.state == .ready and std.mem.eql(u8, kind, "video") and v.player != 0) {
                    ui.video(v.player, .{ .cover = false }, .{ .width = .fill, .height = .fill }, key(.{ "sv", id }));
                } else if (f.state == .ready and !std.mem.eql(u8, kind, "video")) {
                    media.draw(ui, f, j.strOr(item, "id", ""), .{ .width = .fill, .height = .fill, .fit = .contain }, key(.{ "sp", id }));
                } else ui.spinner(32, fg, .{}, 0);
            } else ui.spinner(32, fg, .{}, 0);
        }
    } else ui.spinner(32, fg, .{}, 0);
    ui.end();
    // Tap the start to go back, the rest to go on; press-and-hold pauses.
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 80, .bottom = 90, .start = 0 }, .width = .{ .px = 130 } }, .{ .on_press = msg(.prev), .on_long_press = msg(.pause) });
    ui.end();
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 80, .bottom = 90, .start = 130, .end = 0 } }, .{ .on_press = msg(.next), .on_long_press = msg(.pause) });
    ui.end();
    // Bars.
    const count: usize = if (v.from_list) (if (s.stories.list) |l| j.arr(l.v, "stories").len else 1) else blk: {
        for (groups(s, a)) |g| if (std.mem.eql(u8, g.user, v.user.str())) break :blk g.stories.len;
        break :blk 1;
    };
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 10, .start = 10, .end = 10 }, .direction = .row, .gap = 4 }, .{});
    const frac: f32 = if (v.duration > 0) @as(f32, @floatFromInt(@max(0, @min(v.duration, if (v.paused) v.duration else sys.now() - v.started)))) / @as(f32, @floatFromInt(v.duration)) else 0;
    for (0..@min(count, 30)) |n| {
        const fill: f32 = if (n < v.index) 1 else if (n == v.index) frac else 0;
        ui.begin(.{ .grow = 1, .direction = .row, .height = .{ .px = 3 }, .radius = 2, .background = fg.withAlpha(0.3), .clip = true }, .{ .key = key(.{ "bar", n }) });
        if (fill > 0) {
            ui.begin(.{ .grow = fill * 100, .height = .{ .px = 3 }, .background = fg }, .{});
            ui.end();
        }
        if (fill < 1) {
            ui.begin(.{ .grow = (1 - fill) * 100, .height = .{ .px = 3 } }, .{});
            ui.end();
        }
        ui.end();
    }
    ui.end();
    // Who and when.
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 20, .start = 10, .end = 6 }, .direction = .row, .align_items = .center, .gap = 10 }, .{});
    const u = s.store.user(uid);
    kit.avatar(cx, .{ .name = if (u) |x| s.store.userName(x) else "?", .color = if (u) |x| x.i("color") orelse 0 else 0, .image = if (u) |x| x.s("avatar") else null, .size = 36 }, 0);
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    ui.text(userName(s, uid), .{ .font_size = 14, .weight = 700, .color = fg, .max_lines = 1 });
    var when: std.ArrayList(u8) = .empty;
    when.appendSlice(a, ago(a, j.strOr(story, "createdAt", ""))) catch {};
    if (j.truthy(story, "pinned")) when.print(a, " · {s}", .{t("On the profile")}) catch {};
    if (mine and expired(story)) when.print(a, " · {s}", .{t("Archived")}) catch {};
    ui.text(when.items, .{ .font_size = 12, .color = fg, .opacity = 0.75, .max_lines = 1 });
    ui.end();
    if (mine) kit.iconButton(cx, icons.moreH, msg(.more), .{ .color = fg });
    kit.iconButton(cx, icons.close, msg(.close), .{ .color = fg });
    ui.end();
    // Caption and the foot.
    ui.begin(.{ .position = .absolute, .inset = .{ .bottom = 12, .start = 12, .end = 12 }, .gap = 10 }, .{});
    if (p) |pl| if (j.str(pl.v, "caption")) |cap| if (cap.len > 0) {
        ui.begin(.{ .padding = .xy(12, 8), .radius = 12, .background = cx.c.shade.withAlpha(0.5) }, .{});
        ui.text(cap, .{ .font_size = 14, .color = fg, .line_height = 1.45 });
        ui.end();
    };
    if (mine) {
        const n = j.intOr(story, "viewCount", 0);
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .align_self = .start, .padding = .xy(12, 8), .radius = 12, .background = fg.withAlpha(0.13), .pressed_opacity = 0.8 }, .{ .on_press = msg(.viewers) });
        ui.icon(icons.eye, 18, fg, .{}, 0);
        ui.text(if (n > 0) fmt.tn(a, n, "{n} view", "{n} views") else t("No views yet"), .{ .font_size = 14, .weight = 500, .color = fg });
        ui.end();
    } else {
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8 }, .{});
        ui.begin(.{ .grow = 1, .width = .fill, .height = .{ .px = 44 }, .padding = .xy(14, 0), .radius = 22, .border_width = 1, .border_color = fg.withAlpha(0.4), .justify = .center }, .{});
        ui.input(.{ .key = zui.key("story_reply"), .value = s.fields.get(.story_reply).get(), .placeholder = t("Reply…"), .on_change = app.onField(.story_reply), .on_focus = msg(.pause), .on_submit = msg(.reply), .return_key = .send, .style = .{ .width = .fill, .font_size = 16, .color = fg } });
        ui.end();
        ui.begin(.{ .width = .{ .px = 44 }, .height = .{ .px = 44 }, .radius = 22, .align_items = .center, .justify = .center, .pressed_opacity = 0.7 }, .{ .on_press = msg(.like) });
        // The reaction itself (content the person sends), not chrome.
        ui.text("❤️", .{ .font_size = 24 });
        ui.end();
        ui.end();
    }
    ui.end();
    ui.end();
    ui.end();
}

/// Mine: keep on the profile, the archive, delete.
pub fn menuSheet(cx: Cx) void {
    const s = cx.s;
    const story = current(s, cx.a());
    views.sheet(cx, null);
    views.menuItem(cx, icons.plus, t("Add a glimpse"), msg(.new), false);
    if (story) |st| views.menuItem(cx, icons.pin, if (j.truthy(st, "pinned")) t("Remove from profile") else t("Keep on profile"), msg(.pin), false);
    views.menuItem(cx, icons.archive, t("Glimpse archive"), msg(.archive), false);
    views.menuItem(cx, icons.trash, t("Delete glimpse"), msg(.delete), true);
    views.endSheet(cx);
}

pub fn viewsSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, t("Viewers"));
    const o = s.stories.views orelse {
        kit.spinner(cx);
        views.endSheet(cx);
        return;
    };
    const list = j.arr(o.v, "views");
    if (list.len == 0) kit.emptyState(cx, icons.eye, t("No views yet"), null);
    for (list) |vw| {
        const u = j.obj(vw, "user");
        const id = j.strOr(u, "id", "");
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 52, .padding = .xy(12, 6) }, .{ .key = key(.{ "viewer", id }) });
        kit.avatar(cx, .{ .name = j.strOr(u, "displayName", "?"), .color = j.intOr(u, "color", 0), .image = j.str(u, "avatar"), .size = 42 }, 0);
        ui.begin(.{ .grow = 1, .width = .fill }, .{});
        ui.text(j.strOr(u, "displayName", ""), .{ .font_size = 16, .weight = 500, .color = cx.c.text, .max_lines = 1 });
        ui.text(ago(cx.a(), j.strOr(vw, "at", "")), .{ .font_size = 13, .color = cx.c.text_2 });
        ui.end();
        ui.end();
    }
    kit.sectionNote(cx, fmt.tn(cx.a(), j.intOr(o.v, "viewerCount", 0), "Shared with {n} person. People who turned off read receipts are not listed.", "Shared with {n} people. People who turned off read receipts are not listed."));
    views.endSheet(cx);
}

/// What kind of glimpse.
pub fn kindSheet(cx: Cx) void {
    views.sheet(cx, t("New glimpse"));
    views.menuItem(cx, icons.image, if (zui.platform == .web) t("Photo") else t("Photo"), msg(.pick_photo), false);
    if (zui.platform != .web) views.menuItem(cx, icons.camera, t("Camera"), msg(.take_photo), false);
    views.menuItem(cx, icons.video, t("Video"), msg(.pick_video), false);
    views.menuItem(cx, icons.edit, t("Text"), msg(.text), false);
    views.menuItem(cx, icons.archive, t("Glimpse archive"), msg(.archive), false);
    views.endSheet(cx);
}

pub fn composer(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const d = &s.stories.draft;
    const a = cx.a();
    views.sheet(cx, t("New glimpse"));
    ui.begin(.{ .padding = .xy(12, 4), .gap = 10 }, .{});
    if (d.kind == .text) {
        ui.begin(.{ .width = .fill, .min_height = 220, .radius = 18, .background = bgFill(d.bg), .gradient = bgGradient(d.bg), .padding = .all(18), .justify = .center }, .{});
        ui.input(.{ .key = zui.key("story_text"), .value = s.fields.get(.story_text).get(), .placeholder = t("Type something"), .on_change = app.onField(.story_text), .multiline = true, .style = .{ .width = .fill, .font_size = 22, .weight = 700, .color = bgText(d.bg), .text_align = .center, .max_height = 300 } });
        ui.end();
        ui.begin(.{ .direction = .row, .gap = 8 }, .{});
        for (0..backgrounds_len) |i| {
            ui.begin(.{ .width = .{ .px = 34 }, .height = .{ .px = 34 }, .radius = 17, .background = bgFill(i), .gradient = bgGradient(i), .border_width = if (d.bg == i) 3 else 0, .border_color = cx.c.text }, .{ .on_press = msg(.{ .bg = @intCast(i) }), .key = key(.{ "bg", i }) });
            ui.end();
        }
        ui.end();
    } else {
        ui.begin(.{ .width = .fill, .height = .{ .px = 260 }, .radius = 18, .clip = true, .background = cx.c.surface_2, .align_items = .center, .justify = .center }, .{});
        if (d.kind == .video) {
            ui.icon(icons.video, 40, cx.c.text_2, .{}, 0);
            ui.text(fmt.fileSize(a, @intCast(d.photo.len)), .{ .font_size = 13, .color = cx.c.text_2 });
        } else if (d.photo.len > 0) ui.imageBytes(d.photo, "story-draft", .{ .width = .fill, .height = .fill, .fit = .contain }, key(.{"story-draft"}));
        ui.end();
        kit.field(cx, .story_caption, .{ .placeholder = t("Add a caption…") });
    }
    kit.sectionTitle(cx, t("Who can see it"));
    const people = if (s.stories.audience_users) |o| j.arr(o.v, "users") else &.{};
    var contacts: i64 = 0;
    for (people) |u| if (j.truthy(u, "contact")) {
        contacts += 1;
    };
    audienceRow(cx, .contacts, t("My contacts"), fmt.tn(a, contacts, "{n} person", "{n} people"));
    audienceRow(cx, .chats, t("Contacts and people I chat with"), fmt.tn(a, @intCast(people.len), "{n} person", "{n} people"));
    audienceRow(cx, .selected, t("Only share with…"), if (d.selected.items.len > 0) fmt.tn(a, @intCast(d.selected.items.len), "{n} person", "{n} people") else t("Choose people"));
    kit.row(cx, t("Keep on my profile"), .{ .icon = icons.pin, .switch_on = d.keep, .subtitle = t("Stays watchable after 24 hours"), .on = msg(.keep) });
    ui.begin(.{ .direction = .row, .gap = 6, .align_items = .center }, .{});
    ui.icon(icons.lockSmall, 14, cx.c.text_3, .{}, 0);
    ui.text(t("End-to-end encrypted. Leaves the feed after 24 hours; you keep it in your archive."), .{ .font_size = 12, .color = cx.c.text_3, .grow = 1, .width = .fill });
    ui.end();
    ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .bottom = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, t("Share glimpse"), msg(.share), .{ .busy = d.busy });
    ui.end();
    ui.end();
    views.endSheet(cx);
}

fn audienceRow(cx: Cx, au: Audience, label: []const u8, sub: []const u8) void {
    const ui = cx.ui;
    const on = cx.s.stories.draft.audience == au;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 52, .padding = .xy(12, 6), .radius = theme.radius, .pressed_background = cx.c.active }, .{ .on_press = msg(.{ .audience = au }), .key = key(.{ "aud", @intFromEnum(au) }) });
    ui.begin(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .radius = 10, .border_width = if (on) 6 else 1.5, .border_color = if (on) cx.c.brand else cx.c.border_strong }, .{});
    ui.end();
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    ui.text(label, .{ .font_size = 16, .color = cx.c.text });
    ui.text(sub, .{ .font_size = 13, .color = cx.c.text_2 });
    ui.end();
    ui.end();
}

pub fn peopleSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, t("Share with"));
    const people = if (s.stories.audience_users) |o| j.arr(o.v, "users") else &.{};
    if (people.len == 0) kit.emptyState(cx, icons.users, t("Nobody to share with yet"), t("Add contacts or start chats first."));
    for (people) |u| {
        const id = j.strOr(u, "id", "");
        const on = for (s.stories.draft.selected.items) |x| {
            if (x.eql(id)) break true;
        } else false;
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 52, .padding = .xy(12, 6), .radius = 12, .pressed_background = cx.c.active }, .{ .on_press = msg(.{ .person = Id.of(id) }), .key = key(.{ "sp", id }) });
        ui.begin(.{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 7, .border_width = if (on) 0 else 1.5, .border_color = cx.c.border_strong, .background = if (on) cx.c.brand else null, .align_items = .center, .justify = .center }, .{});
        if (on) ui.icon(icons.check, 14, cx.c.on_accent, .{}, 0);
        ui.end();
        kit.avatar(cx, .{ .name = j.strOr(u, "displayName", "?"), .color = j.intOr(u, "color", 0), .image = j.str(u, "avatar"), .size = 40 }, 0);
        ui.begin(.{ .grow = 1, .width = .fill }, .{});
        ui.text(j.strOr(u, "displayName", ""), .{ .font_size = 16, .color = cx.c.text, .max_lines = 1 });
        ui.text(if (j.truthy(u, "contact")) t("Contact") else t("You chat"), .{ .font_size = 13, .color = cx.c.text_2 });
        ui.end();
        ui.end();
    }
    ui.begin(.{ .direction = .row, .justify = .end, .padding = .{ .top = 8, .bottom = 8, .end = 8 } }, .{});
    kit.button(cx, t("Done"), .{ .stories = .{ .audience = .selected } }, .{});
    ui.end();
    views.endSheet(cx);
}

/// The archive, or someone's pinned glimpses: by date, opening the viewer from there.
pub fn listSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, s.stories.list_title.get());
    const o = s.stories.list orelse {
        kit.spinner(cx);
        views.endSheet(cx);
        return;
    };
    const list = j.arr(o.v, "stories");
    if (list.len == 0) kit.emptyState(cx, icons.archive, t("No glimpses yet"), t("Glimpses you share stay here after they leave the feed."));
    for (list, 0..) |st, i| {
        const id = j.strOr(st, "id", "");
        const at = sys.parseIso(j.strOr(st, "createdAt", "")) orelse 0;
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 52, .padding = .xy(12, 6), .radius = 12, .pressed_background = cx.c.active }, .{ .on_press = msg(.{ .open_list = @intCast(i) }), .key = key(.{ "sl", id }) });
        ui.begin(.{ .width = .{ .px = 42 }, .height = .{ .px = 42 }, .radius = 12, .background = bgFill(i % backgrounds_len), .align_items = .center, .justify = .center }, .{});
        ui.icon(icons.image, 20, bgText(i % backgrounds_len), .{}, 0);
        ui.end();
        ui.begin(.{ .grow = 1, .width = .fill }, .{});
        ui.text(fmt.fullDate(cx.a(), at), .{ .font_size = 16, .color = cx.c.text, .max_lines = 1 });
        var sub: std.ArrayList(u8) = .empty;
        if (j.truthy(st, "pinned")) sub.appendSlice(cx.a(), t("On the profile")) catch {};
        if (!expired(st)) sub.print(cx.a(), "{s}{s}", .{ if (sub.items.len > 0) " · " else "", t("In the feed now") }) catch {};
        if (sub.items.len > 0) ui.text(sub.items, .{ .font_size = 13, .color = cx.c.text_2 });
        ui.end();
        ui.end();
    }
    views.endSheet(cx);
}
