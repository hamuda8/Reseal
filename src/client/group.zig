//! Group and channel administration (Reseal-js ui/info.js): editing the name and description,
//! the public link, what members can do, slow mode and the other settings, members' roles and
//! admin rights, removing and banning, join requests, and invite links.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const vchat = @import("view_chat.zig");

const State = app.State;
const Id = app.Id;
const t = zui.i18n.t;
const tmp = app.tmp;

/// The pages of the info panel for a group or channel.
pub const Page = enum { main, edit, admins, banned, requests, invites };

pub const Setting = enum { history, sign, approval, protected };

pub const ReactionsSetting = enum { all, quick, none };

pub const Act = union(enum) {
    page: Page,
    save_info,
    save_username,
    /// Index into view_chat.default_perms.
    perm: u8,
    setting: Setting,
    slow_mode: u16,
    reactions: ReactionsSetting,
    member_menu: Id,
    admin_rights: Id,
    /// Index into `rights`.
    right: u8,
    save_admin,
    dismiss_admin: Id,
    transfer: Id,
    remove: Id,
    ban: Id,
    unban: Id,
    approve: Id,
    dismiss_request: Id,
    invite_new,
    invite_expires: u8,
    invite_limit: u8,
    invite_approval,
    invite_create,
    invite_copy: Id,
    copy_link,
    invite_revoke: Id,
};

/// Admin rights (info.js RIGHTS); `channel_only` ones are hidden in groups.
pub const rights = [_]struct { key: []const u8, label: []const u8, channel_only: bool = false, default: bool = true }{
    .{ .key = "changeInfo", .label = "Change info" },
    .{ .key = "postMessages", .label = "Post messages", .channel_only = true },
    .{ .key = "editMessages", .label = "Edit messages of others", .channel_only = true },
    .{ .key = "deleteMessages", .label = "Delete messages" },
    .{ .key = "banUsers", .label = "Ban users" },
    .{ .key = "inviteUsers", .label = "Invite users" },
    .{ .key = "pinMessages", .label = "Pin messages" },
    .{ .key = "manageCalls", .label = "Manage voice chats" },
    .{ .key = "addAdmins", .label = "Add new admins", .default = false },
};

pub const perm_labels = [_][]const u8{ "Send messages", "Send media", "Send voice messages", "Send polls", "Send links", "Add members", "Pin messages", "Change group info" };

pub const slow_modes = [_]u16{ 0, 10, 30, 60, 300, 900, 3600 };

pub const invite_expiry = [_]struct { ms: i64, label: []const u8 }{
    .{ .ms = 0, .label = "Never" },
    .{ .ms = 3_600_000, .label = "In 1 hour" },
    .{ .ms = 86_400_000, .label = "In 1 day" },
    .{ .ms = 7 * 86_400_000, .label = "In 1 week" },
};
pub const invite_limits = [_]u32{ 0, 1, 10, 100 };

pub const Group = struct {
    page: Page = .main,
    /// The page's list (admins, banned, requests or invites) and which page it is for.
    list: ?*data.Obj = null,
    list_page: Page = .main,
    /// Pending join requests (shown to admins above the members).
    requests: i64 = 0,
    /// The admin being edited: their rights, one bit per `rights` entry.
    admin_user: Id = .{},
    admin_rights: u16 = 0,
    invite_expires: u8 = 0,
    invite_limit: u8 = 0,
    invite_approval: bool = false,
};

fn path(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(tmp(), f, args) catch "";
}

fn chatId(s: *State) []const u8 {
    return s.info.str();
}

fn chat(s: *State) ?*data.Chat {
    return s.store.chat(s.info.str());
}

/// The info panel opened (or showed another chat): back to its first page.
pub fn opened(s: *State, c: *const data.Chat) void {
    s.group.page = .main;
    s.group.requests = 0;
    if (vchat.isAdmin(c) and !c.is("private") and !c.is("saved") and !c.is("bot"))
        app.api(s, .GET, path("/chats/{s}/members?filter=requests", .{c.id()}), null, .{ .group_requests = Id.of(c.id()) });
}

pub fn act(s: *State, a: Act) void {
    const g = &s.group;
    const id = chatId(s);
    switch (a) {
        .page => |p| {
            g.page = p;
            switch (p) {
                .main => {},
                .edit => if (chat(s)) |c| {
                    s.fields.getPtr(.info_title).set(s.store.title(c));
                    s.fields.getPtr(.info_about).set(c.o.s("about") orelse "");
                    s.fields.getPtr(.chat_username).set(c.o.s("username") orelse "");
                },
                .admins => loadList(s, p, "admins"),
                .banned => loadList(s, p, "banned"),
                .requests => loadList(s, p, "requests"),
                .invites => {
                    replaceList(s, p, null);
                    app.api(s, .GET, path("/chats/{s}/invites", .{id}), null, .{ .group_list = p });
                },
            }
        },
        .save_info => {
            const c = chat(s) orelse return;
            var body: std.ArrayList(u8) = .empty;
            const ta = tmp();
            const title = s.fields.get(.info_title).trimmed();
            const about = s.fields.get(.info_about).trimmed();
            if (title.len == 0) return app.toastError(s, t("Enter a name"));
            body.append(ta, '{') catch return;
            if (!std.mem.eql(u8, title, s.store.title(c))) body.print(ta, "\"title\":{s}", .{j.quote(ta, title) catch return}) catch {};
            if (!std.mem.eql(u8, about, c.o.s("about") orelse "")) body.print(ta, "{s}\"about\":{s}", .{ if (body.items.len > 1) "," else "", j.quote(ta, about) catch return }) catch {};
            body.append(ta, '}') catch return;
            g.page = .main;
            if (body.items.len > 2) patchChat(s, body.items);
        },
        .save_username => {
            const name = s.fields.get(.chat_username).trimmed();
            if (name.len > 0 and !validUsername(name)) return app.toastError(s, t("Use 4-32 letters, numbers and underscores."));
            patchChat(s, if (name.len == 0) "{\"username\":null}" else path("{{\"username\":\"{s}\"}}", .{name}));
        },
        .perm => |i| {
            const c = chat(s) orelse return;
            if (i >= vchat.default_perms.len) return;
            const p = vchat.default_perms[i];
            const on = if (j.field(c.o.v, "permissions")) |pv| (if (j.field(pv, p.key)) |v| (v == .bool and v.bool) else p.on) else p.on;
            // Shown at once; the answer brings the chat back.
            setPerm(c, p.key, !on);
            patchChat(s, path("{{\"permissions\":{{\"{s}\":{}}}}}", .{ p.key, !on }));
        },
        .setting => |x| {
            const c = chat(s) orelse return;
            const key = switch (x) {
                .history => "historyVisible",
                .sign => "signMessages",
                .approval => "joinApproval",
                .protected => "protectedContent",
            };
            // historyVisible is on unless set to false; the others are off unless set.
            const now = if (x == .history) (if (c.o.get(key)) |v| !(v == .bool and !v.bool) else true) else c.o.b(key);
            c.o.set(key, data.boolean(!now)) catch {};
            patchChat(s, path("{{\"{s}\":{}}}", .{ key, !now }));
        },
        .slow_mode => |secs| {
            s.modal = null;
            patchChat(s, path("{{\"slowMode\":{d}}}", .{secs}));
        },
        .reactions => |r| {
            s.modal = null;
            patchChat(s, switch (r) {
                .all => "{\"reactions\":null}",
                .quick => "{\"reactions\":[\"👍\",\"❤️\",\"🔥\",\"😂\",\"😮\",\"😢\"]}",
                .none => "{\"reactions\":[]}",
            });
        },
        .member_menu => |uid| s.modal = .{ .menu = .{ .kind = .member, .target = s.info, .item = uid } },
        .admin_rights => |uid| {
            g.admin_user = uid;
            g.admin_rights = 0;
            const m = member(s, uid.str());
            for (rights, 0..) |r, i| {
                const on = if (m) |mv| (if (j.field(mv, "rights")) |rv| (if (j.field(rv, r.key)) |v| v == .bool and v.bool else r.default) else r.default) else r.default;
                if (on) g.admin_rights |= @as(u16, 1) << @intCast(i);
            }
            s.fields.getPtr(.admin_title).set(if (m) |mv| j.strOr(mv, "title", "") else "");
            s.modal = .{ .admin_rights = uid };
        },
        .right => |i| if (i < rights.len) {
            g.admin_rights ^= @as(u16, 1) << @intCast(i);
        },
        .save_admin => {
            s.modal = null;
            var body: std.ArrayList(u8) = .empty;
            const ta = tmp();
            body.appendSlice(ta, "{\"rights\":{") catch return;
            for (rights, 0..) |r, i| body.print(ta, "{s}\"{s}\":{}", .{ if (i > 0) "," else "", r.key, g.admin_rights & (@as(u16, 1) << @intCast(i)) != 0 }) catch {};
            body.print(ta, "}},\"title\":{s}}}", .{j.quote(ta, s.fields.get(.admin_title).trimmed()) catch "\"\""}) catch {};
            app.api(s, .POST, path("/chats/{s}/members/{s}/admin", .{ id, g.admin_user.str() }), body.items, .{ .group_changed = s.info });
        },
        .dismiss_admin => |uid| {
            s.modal = null;
            app.api(s, .POST, path("/chats/{s}/members/{s}/admin", .{ id, uid.str() }), "{\"demote\":true}", .{ .group_changed = s.info });
        },
        .transfer => |uid| s.modal = .{ .confirm = .{ .kind = .transfer_owner, .target = s.info, .item = uid } },
        .remove => |uid| {
            s.modal = null;
            app.api(s, .DELETE, path("/chats/{s}/members/{s}", .{ id, uid.str() }), null, .{ .group_changed = s.info });
        },
        .ban => |uid| s.modal = .{ .confirm = .{ .kind = .ban_member, .target = s.info, .item = uid } },
        .unban => |uid| app.api(s, .POST, path("/chats/{s}/members/{s}/unban", .{ id, uid.str() }), "{}", .{ .group_changed = s.info }),
        .approve, .dismiss_request => |uid| app.api(s, .POST, path("/chats/{s}/requests/{s}", .{ id, uid.str() }), if (a == .approve) "{\"approve\":true}" else "{\"approve\":false}", .{ .group_changed = s.info }),
        .invite_new => {
            g.invite_expires = 0;
            g.invite_limit = 0;
            g.invite_approval = false;
            s.fields.getPtr(.invite_name).clear();
            s.modal = .invite_new;
        },
        .invite_expires => |i| g.invite_expires = @min(i, invite_expiry.len - 1),
        .invite_limit => |i| g.invite_limit = @min(i, invite_limits.len - 1),
        .invite_approval => g.invite_approval = !g.invite_approval,
        .invite_create => {
            s.modal = null;
            var body: std.ArrayList(u8) = .empty;
            const ta = tmp();
            body.print(ta, "{{\"requestApproval\":{}", .{g.invite_approval}) catch return;
            const name = s.fields.get(.invite_name).trimmed();
            if (name.len > 0) body.print(ta, ",\"name\":{s}", .{j.quote(ta, name) catch "\"\""}) catch {};
            const exp = invite_expiry[g.invite_expires].ms;
            if (exp > 0) body.print(ta, ",\"expiresAt\":{d}", .{sys.now() + exp}) catch {};
            const lim = invite_limits[g.invite_limit];
            if (lim > 0) body.print(ta, ",\"usageLimit\":{d}", .{lim}) catch {};
            body.append(ta, '}') catch {};
            app.api(s, .POST, path("/chats/{s}/invites", .{id}), body.items, .invite_created);
        },
        .invite_copy => |code| if (g.list) |l| for (j.arr(l.v, "invites")) |inv| {
            if (std.mem.eql(u8, j.strOr(inv, "code", ""), code.str())) {
                app.fx.copy(j.strOr(inv, "link", ""));
                app.toast(s, t("Link copied"));
            }
        },
        .copy_link => if (chat(s)) |c| if (c.o.s("username")) |un| {
            const base = if (s.store.config) |cfg| cfg.s("publicUrl") orelse "" else "";
            app.fx.copy(path("{s}/@{s}", .{ std.mem.trimEnd(u8, base, "/"), un }));
            app.toast(s, t("Link copied"));
        },
        .invite_revoke => |code| app.api(s, .DELETE, path("/chats/{s}/invites/{s}", .{ id, code.str() }), null, .{ .group_list_reload = .invites }),
    }
}

/// A confirmed ban or ownership transfer.
pub fn confirmed(s: *State, kind: app.ConfirmKind, target: Id, item: Id) void {
    switch (kind) {
        .ban_member => app.api(s, .DELETE, path("/chats/{s}/members/{s}?ban=true", .{ target.str(), item.str() }), null, .{ .group_changed = target }),
        .transfer_owner => app.api(s, .POST, path("/chats/{s}/members/{s}/owner", .{ target.str(), item.str() }), "{}", .{ .group_changed = target }),
        else => {},
    }
}

fn validUsername(name: []const u8) bool {
    if (name.len < 4 or name.len > 32 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

fn setPerm(c: *data.Chat, key: []const u8, on: bool) void {
    const a = c.o.alloc();
    var perms: j.ObjectMap = .empty;
    if (j.field(c.o.v, "permissions")) |p| if (p == .object) {
        var it = p.object.iterator();
        while (it.next()) |e| perms.put(a, e.key_ptr.*, e.value_ptr.*) catch {};
    };
    perms.put(a, a.dupe(u8, key) catch return, data.boolean(on)) catch {};
    c.o.set("permissions", .{ .object = perms }) catch {};
}

fn patchChat(s: *State, body: []const u8) void {
    app.api(s, .PATCH, path("/chats/{s}", .{chatId(s)}), body, .{ .chat_patch = s.info });
}

fn loadList(s: *State, p: Page, filter: []const u8) void {
    replaceList(s, p, null);
    app.api(s, .GET, path("/chats/{s}/members?filter={s}&limit=200", .{ chatId(s), filter }), null, .{ .group_list = p });
}

fn replaceList(s: *State, p: Page, v: ?j.Value) void {
    if (s.group.list) |old| old.destroy();
    s.group.list = if (v) |x| data.Obj.create(x) catch null else null;
    s.group.list_page = p;
}

/// A member (from the members list or the page's list) by user id.
pub fn member(s: *const State, uid: []const u8) ?j.Value {
    inline for (.{ s.members, s.group.list }) |src| if (src) |o| for (j.arr(o.v, "members")) |m| {
        if (std.mem.eql(u8, j.strOr(m, "userId", j.strOr(m, "user.id", "")), uid)) return m;
    };
    return null;
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const v = j.parse(tmp(), r.body);
    switch (op) {
        .group_requests => |cid| if (r.ok() and cid.eql(chatId(s))) {
            s.group.requests = @intCast(j.arr(v, "members").len);
        },
        .group_list => |p| {
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            if (v) |x| for (j.arr(x, "members")) |m| if (j.obj(m, "user")) |u| {
                _ = s.store.putUser(u) catch null;
            };
            replaceList(s, p, v);
            if (p == .requests) s.group.requests = @intCast(j.arr(v, "members").len);
        },
        .group_list_reload => |p| {
            if (!r.ok()) app.toastError(s, app.apiError(r).message);
            act(s, .{ .page = p });
        },
        .group_changed => |cid| {
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
            } else if (j.obj(v, "added") != null or j.field(v, "added") != null) {
                const added = j.arr(v, "added").len;
                if (j.arr(v, "skipped").len > 0) app.toast(s, t("Some people could not be added because of their privacy settings. Send them an invite link instead.")) else app.toast(s, @import("fmt.zig").tn(tmp(), @intCast(added), "{n} member added", "{n} members added"));
            }
            refresh(s, cid.str());
        },
        .chat_patch => |cid| {
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
                refresh(s, cid.str());
                return true;
            }
            if (j.obj(v, "chat")) |raw| _ = s.store.putChat(raw) catch null;
        },
        .invite_created => {
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            app.fx.copy(j.strOr(v, "invite.link", ""));
            app.toast(s, t("Invite link created and copied"));
            act(s, .{ .page = .invites });
        },
        else => return false,
    }
    return true;
}

/// After a change to members: the members, the open page's list and the chat itself again.
fn refresh(s: *State, cid: []const u8) void {
    if (!s.info.eql(cid)) return;
    app.api(s, .GET, path("/chats/{s}/members?limit=200", .{cid}), null, .{ .members = Id.of(cid) });
    if (s.group.page != .main and s.group.page != .edit) act(s, .{ .page = s.group.page });
    if (s.store.chat(cid)) |c| if (vchat.isAdmin(c)) app.api(s, .GET, path("/chats/{s}/members?filter=requests", .{cid}), null, .{ .group_requests = Id.of(cid) });
    app.api(s, .GET, path("/chats/{s}", .{cid}), null, .{ .chat_refresh = Id.of(cid) });
}
