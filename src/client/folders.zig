//! Chat folders (Reseal-js settings.js foldersPane/folderEditor, chatlist.js folderMenu): the
//! list in Settings, the editor (name, included kinds of chats, chosen chats, exclusions) and
//! "Add to folder" in a chat's menu. Folders only store rules; the list filters on the device.
//! Folder emoji chosen in the web app are kept but not shown: the app's chrome has no emoji.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const data = @import("data.zig");
const icons = @import("icons.zig");
const fmt = @import("fmt.zig");
const kit = @import("ui.zig");
const views = @import("views.zig");
const vlist = @import("view_list.zig");

const State = app.State;
const Id = app.Id;
const Cx = kit.Cx;
const Msg = app.Msg;
const t = zui.i18n.t;
const tmp = app.tmp;
const gpa = app.gpa;
const key = kit.key;

pub const kinds = [_]struct { key: []const u8, label: []const u8 }{
    .{ .key = "contacts", .label = "Contacts" },
    .{ .key = "noncontacts", .label = "Non-contacts" },
    .{ .key = "groups", .label = "Groups" },
    .{ .key = "channels", .label = "Channels" },
    .{ .key = "bots", .label = "Bots" },
};

const Suggested = struct { name: []const u8, include: u8, exclude_read: bool = false };
const suggested = [_]Suggested{
    .{ .name = "Unread", .include = 0b11111, .exclude_read = true },
    .{ .name = "Personal", .include = 0b00011 },
    .{ .name = "Groups", .include = 0b00100 },
    .{ .name = "AI", .include = 0b10000 },
};

pub const Act = union(enum) {
    edit: Id,
    create,
    add_suggested: u8,
    kind: u8,
    toggle_chat: Id,
    exclude: enum { muted, read, archived },
    save,
    delete,
    /// From a chat's menu: put it in, or take it out of, a folder.
    toggle_in: struct { folder: Id, chat: Id },
};

pub const Editor = struct {
    id: Id = .{},
    include: u8 = 0,
    chats: std.ArrayList(Id) = .empty,
    exclude_ids: std.ArrayList(Id) = .empty,
    emoji: app.Text = .{},
    exclude_muted: bool = false,
    exclude_read: bool = false,
    exclude_archived: bool = true,
};

fn folderById(s: *const State, id: []const u8) ?j.Value {
    const f = s.store.folders orelse return null;
    for (j.arr(f.v, "folders")) |x| if (j.eqlStr(x, "id", id)) return x;
    return null;
}

fn hasStr(list: []j.Value, v: []const u8) bool {
    for (list) |x| if (x == .string and std.mem.eql(u8, x.string, v)) return true;
    return false;
}

pub fn act(s: *State, a: Act) void {
    const e = &s.folder;
    switch (a) {
        .create, .edit => {
            e.* = .{ .chats = e.chats, .exclude_ids = e.exclude_ids, .emoji = e.emoji };
            e.chats.clearRetainingCapacity();
            e.exclude_ids.clearRetainingCapacity();
            e.emoji.clear();
            s.fields.getPtr(.folder_name).clear();
            if (a == .edit) if (folderById(s, a.edit.str())) |f| {
                e.id = a.edit;
                s.fields.getPtr(.folder_name).set(j.strOr(f, "name", ""));
                e.emoji.set(j.strOr(f, "emoji", ""));
                const inc = j.arr(f, "include");
                for (kinds, 0..) |k, i| if (hasStr(inc, k.key)) {
                    e.include |= @as(u8, 1) << @intCast(i);
                };
                for (j.arr(f, "chatIds")) |x| if (x == .string) e.chats.append(gpa, Id.of(x.string)) catch {};
                for (j.arr(f, "excludeChatIds")) |x| if (x == .string) e.exclude_ids.append(gpa, Id.of(x.string)) catch {};
                e.exclude_muted = j.truthy(f, "excludeMuted");
                e.exclude_read = j.truthy(f, "excludeRead");
                e.exclude_archived = if (j.field(f, "excludeArchived")) |v| !(v == .bool and !v.bool) else true;
            };
            s.modal = .folder_edit;
        },
        .add_suggested => |i| if (i < suggested.len) {
            const sg = suggested[i];
            const body = bodyFor(tmp(), t(sg.name), "", sg.include, &.{}, &.{}, false, sg.exclude_read, true);
            app.api(s, .POST, "/folders", body, .folders_changed);
        },
        .kind => |i| e.include ^= @as(u8, 1) << @intCast(i),
        .toggle_chat => |id| {
            for (e.chats.items, 0..) |x, i| if (x.eql(id.str())) {
                _ = e.chats.orderedRemove(i);
                return;
            };
            e.chats.append(gpa, id) catch {};
        },
        .exclude => |x| switch (x) {
            .muted => e.exclude_muted = !e.exclude_muted,
            .read => e.exclude_read = !e.exclude_read,
            .archived => e.exclude_archived = !e.exclude_archived,
        },
        .save => {
            const name = s.fields.get(.folder_name).trimmed();
            if (name.len == 0) return app.toastError(s, t("Enter a name"));
            const body = bodyFor(tmp(), name, e.emoji.get(), e.include, e.chats.items, e.exclude_ids.items, e.exclude_muted, e.exclude_read, e.exclude_archived);
            s.modal = null;
            if (e.id.isSet()) app.api(s, .PUT, std.fmt.allocPrint(tmp(), "/folders/{s}", .{e.id.str()}) catch return, body, .folders_changed) else app.api(s, .POST, "/folders", body, .folders_changed);
        },
        .delete => if (e.id.isSet()) {
            s.modal = null;
            if (s.filter == .folder and s.filter.folder.eql(e.id.str())) s.filter = .all;
            app.api(s, .DELETE, std.fmt.allocPrint(tmp(), "/folders/{s}", .{e.id.str()}) catch return, null, .folders_changed);
        },
        .toggle_in => |x| {
            s.modal = null;
            const f = folderById(s, x.folder.str()) orelse return;
            const ta = tmp();
            var ids: std.ArrayList(Id) = .empty;
            var was = false;
            for (j.arr(f, "chatIds")) |c| if (c == .string) {
                if (std.mem.eql(u8, c.string, x.chat.str())) was = true else ids.append(ta, Id.of(c.string)) catch {};
            };
            if (!was) ids.append(ta, x.chat) catch {};
            var inc: u8 = 0;
            for (kinds, 0..) |k, i| if (hasStr(j.arr(f, "include"), k.key)) {
                inc |= @as(u8, 1) << @intCast(i);
            };
            var ex: std.ArrayList(Id) = .empty;
            for (j.arr(f, "excludeChatIds")) |c| if (c == .string) ex.append(ta, Id.of(c.string)) catch {};
            const body = bodyFor(ta, j.strOr(f, "name", ""), j.strOr(f, "emoji", ""), inc, ids.items, ex.items, j.truthy(f, "excludeMuted"), j.truthy(f, "excludeRead"), if (j.field(f, "excludeArchived")) |v| !(v == .bool and !v.bool) else true);
            app.api(s, .PUT, std.fmt.allocPrint(ta, "/folders/{s}", .{x.folder.str()}) catch return, body, .folders_changed);
            app.toast(s, if (was) fmt.tf("Removed from {name}", .{ .name = j.strOr(f, "name", "") }) else fmt.tf("Added to {name}", .{ .name = j.strOr(f, "name", "") }));
        },
    }
}

fn bodyFor(a: std.mem.Allocator, name: []const u8, emoji: []const u8, include: u8, chats: []const Id, exclude: []const Id, muted: bool, read: bool, archived: bool) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(a, "{{\"name\":{s},\"emoji\":{s},\"include\":[", .{ j.quote(a, name) catch "\"\"", if (emoji.len > 0) (j.quote(a, emoji) catch "null") else "null" }) catch return "{}";
    var first = true;
    for (kinds, 0..) |k, i| if (include & (@as(u8, 1) << @intCast(i)) != 0) {
        out.print(a, "{s}\"{s}\"", .{ if (first) "" else ",", k.key }) catch {};
        first = false;
    };
    out.appendSlice(a, "],\"chatIds\":[") catch {};
    for (chats, 0..) |c, i| out.print(a, "{s}\"{s}\"", .{ if (i > 0) "," else "", c.str() }) catch {};
    out.appendSlice(a, "],\"excludeChatIds\":[") catch {};
    for (exclude, 0..) |c, i| out.print(a, "{s}\"{s}\"", .{ if (i > 0) "," else "", c.str() }) catch {};
    out.print(a, "],\"excludeMuted\":{},\"excludeRead\":{},\"excludeArchived\":{}}}", .{ muted, read, archived }) catch {};
    return out.items;
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    switch (op) {
        .folders_changed => {
            if (!r.ok()) app.toastError(s, app.apiError(r).message);
            app.api(s, .GET, "/folders", null, .folders);
        },
        else => return false,
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Views

fn msg(a: Act) Msg {
    return .{ .folder = a };
}

fn describe(cx: Cx, f: j.Value) []const u8 {
    const a = cx.a();
    var out: std.ArrayList(u8) = .empty;
    const inc = j.arr(f, "include");
    for (kinds) |k| if (hasStr(inc, k.key)) {
        if (out.items.len > 0) out.appendSlice(a, ", ") catch {};
        out.appendSlice(a, t(k.label)) catch {};
    };
    const n = j.arr(f, "chatIds").len;
    if (n > 0) {
        if (out.items.len > 0) out.appendSlice(a, ", ") catch {};
        out.appendSlice(a, fmt.tn(a, @intCast(n), "{n} chat", "{n} chats")) catch {};
    }
    return if (out.items.len > 0) out.items else t("No chats");
}

/// Settings → Chat folders.
pub fn pane(cx: Cx) void {
    const s = cx.s;
    kit.sectionNote(cx, t("Create folders for different groups of chats and switch between them quickly."));
    kit.row(cx, t("Create a folder"), .{ .icon = icons.plus, .on = msg(.create) });
    const list = if (s.store.folders) |f| j.arr(f.v, "folders") else &.{};
    for (list) |f| {
        const id = j.strOr(f, "id", "");
        kit.row(cx, j.strOr(f, "name", ""), .{ .icon = icons.folder, .subtitle = describe(cx, f), .chevron = true, .on = msg(.{ .edit = Id.of(id) }), .k = key(.{ "folder", id }) });
    }
    if (list.len == 0) {
        kit.sectionTitle(cx, t("Suggested"));
        for (suggested, 0..) |sg, i| {
            cx.ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .end = 8 } }, .{ .key = key(.{ "sugg", i }) });
            cx.ui.begin(.{ .grow = 1, .width = .fill }, .{});
            kit.row(cx, t(sg.name), .{ .icon = icons.folder });
            cx.ui.end();
            kit.button(cx, t("Add"), msg(.{ .add_suggested = @intCast(i) }), .{ .small = true, .kind = .secondary });
            cx.ui.end();
        }
    }
}

/// The folder editor sheet.
pub fn editor(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const e = &s.folder;
    views.sheet(cx, if (e.id.isSet()) t("Edit folder") else t("New folder"));
    ui.begin(.{ .padding = .{ .start = 12, .end = 12, .top = 4 } }, .{});
    kit.field(cx, .folder_name, .{ .label = t("Name"), .placeholder = t("Folder name") });
    ui.end();
    kit.sectionTitle(cx, t("Included chats"));
    for (kinds, 0..) |k, i| check(cx, t(k.label), e.include & (@as(u8, 1) << @intCast(i)) != 0, msg(.{ .kind = @intCast(i) }), key(.{ "kind", i }));
    kit.sectionTitle(cx, t("Chats"));
    // Every chat, ticked when it is in the folder.
    const shown = s.store.sorted(cx.a(), false);
    for (shown) |c| {
        if (c.is("saved") and !c.o.b("primary")) continue;
        var on = false;
        for (e.chats.items) |x| if (x.eql(c.id())) {
            on = true;
        };
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 48, .padding = .xy(12, 4), .radius = 12, .pressed_background = cx.c.active }, .{ .on_press = msg(.{ .toggle_chat = Id.of(c.id()) }), .key = key(.{ "fchat", c.id() }) });
        box(cx, on);
        vlist.chatAvatar(cx, c, 34);
        ui.text(s.store.title(c), .{ .font_size = 16, .color = cx.c.text, .max_lines = 1, .grow = 1, .width = .fill });
        ui.end();
    }
    kit.sectionTitle(cx, t("Exclude"));
    kit.row(cx, t("Exclude muted"), .{ .switch_on = e.exclude_muted, .on = msg(.{ .exclude = .muted }) });
    kit.row(cx, t("Exclude read"), .{ .switch_on = e.exclude_read, .on = msg(.{ .exclude = .read }) });
    kit.row(cx, t("Exclude archived"), .{ .switch_on = e.exclude_archived, .on = msg(.{ .exclude = .archived }) });
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .top = 8, .bottom = 8, .start = 8, .end = 8 } }, .{});
    if (e.id.isSet()) kit.button(cx, t("Delete"), msg(.delete), .{ .kind = .danger_ghost });
    ui.begin(.{ .grow = 1 }, .{});
    ui.end();
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, t("Save"), msg(.save), .{});
    ui.end();
    views.endSheet(cx);
}

/// "Add to folder" from a chat's menu.
pub fn pickSheet(cx: Cx, chat: Id) void {
    const s = cx.s;
    views.sheet(cx, t("Add to folder"));
    const list = if (s.store.folders) |f| j.arr(f.v, "folders") else &.{};
    for (list) |f| {
        const id = j.strOr(f, "id", "");
        const in = hasStr(j.arr(f, "chatIds"), chat.str());
        cx.ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 44, .padding = .xy(12, 6), .radius = 12, .pressed_background = cx.c.hover }, .{ .on_press = msg(.{ .toggle_in = .{ .folder = Id.of(id), .chat = chat } }), .key = key(.{ "fp", id }) });
        cx.ui.icon(icons.folder, 19, cx.c.text_2, .{}, 0);
        cx.ui.text(j.strOr(f, "name", ""), .{ .font_size = 14, .weight = 500, .color = cx.c.text, .grow = 1, .width = .fill });
        if (in) cx.ui.icon(icons.check, 18, cx.c.accent, .{}, 0);
        cx.ui.end();
    }
    views.menuItem(cx, icons.plus, t("Create a folder"), msg(.create), false);
    views.endSheet(cx);
}

fn box(cx: Cx, on: bool) void {
    cx.ui.begin(.{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 7, .border_width = if (on) 0 else 1.5, .border_color = cx.c.border_strong, .background = if (on) cx.c.brand else null, .align_items = .center, .justify = .center }, .{});
    if (on) cx.ui.icon(icons.check, 14, cx.c.on_accent, .{}, 0);
    cx.ui.end();
}

fn check(cx: Cx, label: []const u8, on: bool, m: Msg, k: u64) void {
    cx.ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 44, .padding = .xy(12, 4), .radius = 12, .pressed_background = cx.c.active }, .{ .on_press = m, .key = k });
    box(cx, on);
    cx.ui.text(label, .{ .font_size = 16, .color = cx.c.text });
    cx.ui.end();
}
