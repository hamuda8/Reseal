//! Profile pictures and the account (Reseal-js settings.js editProfilePane, deleteAccount,
//! featuresTour; info.js editPane's photo; bots.js botEditor's photo): a photo from the camera
//! or the gallery, uploaded as a public picture (purpose "avatar") and set on my profile, a group
//! or channel, or an assistant; removing it; whether a username is free while it is typed;
//! deleting the account; Wufour's devices page; and the tour of Reseal's features.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");
const icons = @import("icons.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const t = zui.i18n.t;
const tmp = app.tmp;
const gpa = app.gpa;

/// Whose picture is being changed.
pub const Target = union(enum) { me, chat: Id, bot };

pub const Act = union(enum) {
    photo_menu: Target,
    pick: struct { target: Target, camera: bool },
    remove: Target,
    username_check: u32,
    delete_account,
    delete_submit,
    devices,
    tour,
};

pub const Profile = struct {
    target: Target = .me,
    /// The picture being uploaded.
    bytes: []u8 = &.{},
    media: Id = .{},
    chunks: u32 = 0,
    chunk_size: usize = 0,
    busy: bool = false,
    /// A bot's new picture (sent with its other fields on Save).
    bot_avatar: Id = .{},
    username_seq: u32 = 0,
    username_hint: app.Text = .{},
    username_ok: bool = true,
};

fn path(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(tmp(), f, args) catch "";
}

fn onPhoto(f: zui.File) Msg {
    return .{ .profile_photo = f };
}

pub fn act(s: *State, a: Act) void {
    const p = &s.profile;
    switch (a) {
        .photo_menu => |tg| {
            p.target = tg;
            s.modal = .profile_photo_menu;
        },
        .pick => |x| {
            s.modal = null;
            p.target = x.target;
            app.fx.pickPhoto(.{ .camera = x.camera, .max_size = 800, .quality = 90 }, onPhoto);
        },
        .remove => |tg| {
            s.modal = null;
            switch (tg) {
                .me => app.api(s, .PATCH, "/me", "{\"avatar\":null}", .profile_saved_photo),
                .chat => |id| app.api(s, .PATCH, path("/chats/{s}", .{id.str()}), "{\"avatar\":null}", .{ .chat_patch = id }),
                .bot => p.bot_avatar = Id.of("none"),
            }
        },
        .username_check => |seq| if (seq == p.username_seq) {
            const name = s.fields.get(.profile_username).trimmed();
            const mine = if (s.store.me) |me| me.s("username") orelse "" else "";
            if (name.len == 0 or std.mem.eql(u8, name, mine)) {
                p.username_hint.clear();
                p.username_ok = true;
                return;
            }
            app.api(s, .GET, path("/username/{s}", .{j.urlEncode(tmp(), name) catch return}), null, .{ .username_check = seq });
        },
        .delete_account => {
            s.fields.getPtr(.delete_confirm).clear();
            s.modal = .delete_account;
        },
        .delete_submit => {
            if (!std.mem.eql(u8, s.fields.get(.delete_confirm).trimmed(), "DELETE")) return app.toastError(s, t("Type DELETE in capital letters."));
            s.modal = null;
            app.api(s, .DELETE, "/me", "{\"confirm\":\"DELETE\"}", .account_deleted);
        },
        .devices => {
            const host = if (s.store.config) |c| c.s("authHost") orelse app.auth_host else app.auth_host;
            app.fx.openUrl(path("{s}/auth/devices", .{std.mem.trimEnd(u8, host, "/")}), true);
        },
        .tour => s.modal = .features_tour,
    }
}

/// The username field changed: check it a moment later.
pub fn usernameTyped(s: *State) void {
    s.profile.username_seq += 1;
    app.fx.after(350, .{ .profile = .{ .username_check = s.profile.username_seq } });
}

/// A photo was taken or chosen: upload it (public, not encrypted).
pub fn onPicked(s: *State, f: zui.File) void {
    const p = &s.profile;
    if (p.bytes.len > 0) gpa.free(p.bytes);
    p.bytes = gpa.dupe(u8, f.data) catch return;
    p.busy = true;
    const mime = if (f.mime.len > 0) f.mime else "image/jpeg";
    app.api(s, .POST, "/media", path("{{\"size\":{d},\"encrypted\":false,\"mime\":\"{s}\",\"name\":\"avatar.jpg\",\"purpose\":\"avatar\"}}", .{ p.bytes.len, mime }), .profile_upload_create);
}

fn sendChunk(s: *State, n: u32) void {
    const p = &s.profile;
    const start = n * p.chunk_size;
    const end = @min(p.bytes.len, start + p.chunk_size);
    app.request(s, .PUT, path("/media/{s}/chunks/{d}", .{ p.media.str(), n }), p.bytes[start..end], "application/octet-stream", .{ .profile_upload_chunk = n });
}

fn failed(s: *State, r: zui.Response) bool {
    s.profile.busy = false;
    app.toastError(s, app.apiError(r).message);
    return true;
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const p = &s.profile;
    const v = j.parse(tmp(), r.body);
    switch (op) {
        .profile_upload_create => {
            if (!r.ok()) return failed(s, r);
            p.media = Id.of(j.strOr(v, "id", ""));
            p.chunks = @intCast(@max(1, j.intOr(v, "chunks", 1)));
            p.chunk_size = @intCast(@max(1, j.intOr(v, "chunkSize", 1 << 20)));
            sendChunk(s, 0);
        },
        .profile_upload_chunk => |n| {
            if (!r.ok()) return failed(s, r);
            if (n + 1 < p.chunks) sendChunk(s, n + 1) else app.api(s, .POST, path("/media/{s}/complete", .{p.media.str()}), "{}", .profile_upload_complete);
        },
        .profile_upload_complete => {
            if (!r.ok()) return failed(s, r);
            p.busy = false;
            gpa.free(p.bytes);
            p.bytes = &.{};
            const id = p.media.str();
            switch (p.target) {
                .me => app.api(s, .PATCH, "/me", path("{{\"avatar\":\"{s}\"}}", .{id}), .profile_saved_photo),
                .chat => |cid| app.api(s, .PATCH, path("/chats/{s}", .{cid.str()}), path("{{\"avatar\":\"{s}\"}}", .{id}), .{ .chat_patch = cid }),
                .bot => p.bot_avatar = p.media,
            }
        },
        .profile_saved_photo => {
            if (!r.ok()) return failed(s, r);
            if (j.obj(v, "user")) |u| app.setMe(s, u);
            app.toast(s, t("Profile saved"));
        },
        .username_check => |seq| if (seq == p.username_seq and r.ok()) {
            p.username_ok = j.truthy(v, "available");
            const name = s.fields.get(.profile_username).trimmed();
            if (p.username_ok) {
                p.username_hint.set(@import("fmt.zig").tf("{name} is available.", .{ .name = path("@{s}", .{name}) }));
            } else p.username_hint.set(j.strOr(v, "reason", t("That username is taken.")));
        },
        .account_deleted => {
            if (!r.ok()) return failed(s, r);
            keys.forgetDevice(s);
            app.signedOut(s);
        },
        else => return false,
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Views

fn msg(a: Act) Msg {
    return .{ .profile = a };
}

/// A big avatar that opens the photo menu (Upload a photo, Remove photo).
pub fn editableAvatar(cx: Cx, o: kit.AvatarOpts, target: Target, has_photo: bool) void {
    _ = has_photo;
    const ui = cx.ui;
    ui.begin(.{ .align_items = .center, .padding = .{ .top = 8, .bottom = 20 } }, .{});
    ui.begin(.{ .width = .{ .px = o.size }, .height = .{ .px = o.size }, .pressed_opacity = 0.85 }, .{ .on_press = msg(.{ .photo_menu = target }) });
    kit.avatar(cx, o, kit.key(.{ "edit-av", @tagName(target) }));
    ui.begin(.{ .position = .absolute, .inset = .{ .bottom = 0, .end = 0 }, .width = .{ .px = 36 }, .height = .{ .px = 36 }, .radius = 18, .background = cx.c.brand, .border_width = 3, .border_color = cx.c.surface, .align_items = .center, .justify = .center }, .{});
    if (cx.s.profile.busy) ui.spinner(16, cx.c.on_accent, .{}, 0) else ui.icon(icons.camera, 17, cx.c.on_accent, .{}, 0);
    ui.end();
    ui.end();
    ui.end();
}

pub fn photoMenu(cx: Cx) void {
    const tg = cx.s.profile.target;
    views.sheet(cx, null);
    if (zui.platform != .web) views.menuItem(cx, icons.camera, t("Take a photo"), msg(.{ .pick = .{ .target = tg, .camera = true } }), false);
    views.menuItem(cx, icons.image, t("Upload a photo"), msg(.{ .pick = .{ .target = tg, .camera = false } }), false);
    views.menuItem(cx, icons.trash, t("Remove photo"), msg(.{ .remove = tg }), true);
    views.endSheet(cx);
}

/// Under the username field: free or taken.
pub fn usernameHint(cx: Cx) void {
    const p = cx.s.profile;
    const hint = if (p.username_hint.get().len > 0) p.username_hint.get() else t("People can find you by this name. Use a-z, 0-9 and underscores.");
    cx.ui.begin(.{ .padding = .{ .top = 0, .bottom = 12 } }, .{});
    cx.ui.text(hint, .{ .font_size = 12, .color = if (p.username_hint.get().len == 0) cx.c.text_3 else if (p.username_ok) cx.c.accent else cx.c.danger, .line_height = 1.45 });
    cx.ui.end();
}

pub fn deleteSheet(cx: Cx) void {
    views.sheet(cx, t("Delete account?"));
    cx.ui.begin(.{ .padding = .xy(12, 4) }, .{});
    kit.sectionNote(cx, t("This deletes your Reseal profile, removes you from all chats and erases your encryption keys. Type DELETE to confirm."));
    kit.field(cx, .delete_confirm, .{ .placeholder = "DELETE", .submit = msg(.delete_submit) });
    cx.ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .bottom = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, t("Delete account"), msg(.delete_submit), .{ .kind = .danger });
    cx.ui.end();
    cx.ui.end();
    views.endSheet(cx);
}

/// Reseal features (featuresTour).
pub fn tourSheet(cx: Cx) void {
    const ui = cx.ui;
    views.sheet(cx, t("Reseal features"));
    const items = [_]struct { ic: zui.Icon, title: []const u8, text: []const u8 }{
        .{ .ic = icons.lock, .title = "End-to-end encryption", .text = "Private chats and groups are encrypted on your device. Verify safety numbers in a contact's profile." },
        .{ .ic = icons.video, .title = "Calls", .text = "Voice and video calls, group voice chats, screen sharing. Calls are encrypted and signed." },
        .{ .ic = icons.sparkles, .title = "AI assistants", .text = "Create assistants with any model on OpenRouter, chat with them, or add them to groups and mention them." },
        .{ .ic = icons.mic, .title = "Voice & video messages", .text = "Tap the microphone to record. Right-click it to switch to round video messages." },
        .{ .ic = icons.calendar, .title = "Scheduled & silent", .text = "Right-click the send button to schedule a message, send silently, or make it disappear." },
        .{ .ic = icons.folder, .title = "Folders", .text = "Organize chats into folders in Settings → Chat folders." },
        .{ .ic = icons.code, .title = "For developers", .text = "Embed Reseal chat in your own app, with your branding, users and AI. Open Menu → Developers." },
    };
    for (items, 0..) |it, i| {
        ui.begin(.{ .direction = .row, .gap = 14, .padding = .xy(12, 10) }, .{ .key = kit.key(.{ "tour", i }) });
        ui.icon(it.ic, 22, cx.c.accent, .{}, 0);
        ui.begin(.{ .grow = 1, .width = .fill, .gap = 2 }, .{});
        ui.text(t(it.title), .{ .font_size = 16, .weight = 500, .color = cx.c.text });
        ui.text(t(it.text), .{ .font_size = 14, .color = cx.c.text_2, .line_height = 1.5 });
        ui.end();
        ui.end();
    }
    views.endSheet(cx);
}
