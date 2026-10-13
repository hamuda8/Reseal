//! Chat lock (Reseal-js ui/chatlock.js): a locked chat opens only with the chat lock code, one
//! code for all locked chats on every device (the server keeps a slow hash and allows a few
//! guesses). Locked chats lock again after a minute in the background, and their previews and
//! notifications never show who wrote or what.
//!
//! Not here yet: unlocking with the device's fingerprint, face or PIN (the web app uses WebAuthn;
//! zui has no platform authenticator API), and masked code fields (zui inputs have no password
//! mode yet).

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
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

pub const relock_after_ms = 60_000;

pub const Purpose = enum { open, remove };

pub const Act = union(enum) {
    lock: Id,
    remove: Id,
    submit_unlock,
    set_code,
    change_code,
    save_code,
    turn_off,
    submit_off,
};

pub const Lock = struct {
    unlocked: std.ArrayList(Id) = .empty,
    hidden_at: i64 = 0,
    /// Lock this chat once the new code is saved.
    lock_after: Id = .{},
    err: app.Text = .{},
    busy: bool = false,
};

pub fn isLocked(s: *const State, c: *const data.Chat) bool {
    if (!c.meBool("locked")) return false;
    for (s.lock.unlocked.items) |x| if (x.eql(c.id())) return false;
    return true;
}

fn hasCode(s: *const State) bool {
    const me = s.store.me orelse return false;
    return me.b("chatLock");
}

/// Opening a chat: false when it has to be unlocked first (the unlock sheet is shown).
pub fn mayOpen(s: *State, id: []const u8) bool {
    const c = s.store.chat(id) orelse return true;
    if (s.mode != .app or !isLocked(s, c)) return true;
    ask(s, Id.of(id), .open);
    return false;
}

fn ask(s: *State, chat: Id, purpose: Purpose) void {
    s.lock.err.clear();
    s.fields.getPtr(.lock_code).clear();
    s.modal = .{ .chat_unlock = .{ .chat = chat, .purpose = purpose } };
    app.fx.focus(zui.key("lock_code"));
}

/// Reseal went to the background or came back.
pub fn onVisible(s: *State, visible: bool) void {
    if (!visible) {
        s.lock.hidden_at = sys.now();
        return;
    }
    if (s.lock.hidden_at == 0 or sys.now() - s.lock.hidden_at < relock_after_ms or s.lock.unlocked.items.len == 0) return;
    s.lock.unlocked.clearRetainingCapacity();
    if (s.store.chat(s.open_chat.str())) |c| if (c.meBool("locked")) views.onUi(s, .close_chat);
}

pub fn act(s: *State, a: Act) void {
    const l = &s.lock;
    switch (a) {
        .lock => |id| {
            s.modal = null;
            if (!hasCode(s)) {
                l.lock_after = id;
                return openCodeForm(s, false);
            }
            setLocked(s, id, true);
        },
        .remove => |id| ask(s, id, .remove),
        .submit_unlock => {
            const code = s.fields.get(.lock_code).get();
            if (code.len == 0) return;
            const m = s.modal orelse return;
            if (m != .chat_unlock) return;
            l.busy = true;
            app.api(s, .POST, "/me/chat-lock/verify", std.fmt.allocPrint(tmp(), "{{\"code\":{s}}}", .{j.quote(tmp(), code) catch return}) catch return, .{ .lock_verify = .{ .chat = m.chat_unlock.chat, .purpose = m.chat_unlock.purpose } });
        },
        .set_code => openCodeForm(s, false),
        .change_code => openCodeForm(s, true),
        .save_code => {
            const code = s.fields.get(.lock_code).get();
            if (code.len < 4) return l.err.set(t("Use at least 4 characters."));
            if (!std.mem.eql(u8, code, s.fields.get(.lock_code_2).get())) return l.err.set(t("The codes do not match."));
            const ta = tmp();
            const body = if (hasCode(s))
                std.fmt.allocPrint(ta, "{{\"code\":{s},\"current\":{s}}}", .{ j.quote(ta, code) catch return, j.quote(ta, s.fields.get(.lock_current).get()) catch return }) catch return
            else
                std.fmt.allocPrint(ta, "{{\"code\":{s}}}", .{j.quote(ta, code) catch return}) catch return;
            l.busy = true;
            app.api(s, .PUT, "/me/chat-lock", body, .{ .lock_code_saved = hasCode(s) });
        },
        .turn_off => {
            l.err.clear();
            s.fields.getPtr(.lock_code).clear();
            s.modal = .chat_lock_off;
        },
        .submit_off => {
            l.busy = true;
            app.api(s, .DELETE, "/me/chat-lock", std.fmt.allocPrint(tmp(), "{{\"code\":{s}}}", .{j.quote(tmp(), s.fields.get(.lock_code).get()) catch return}) catch return, .lock_off);
        },
    }
}

fn openCodeForm(s: *State, change: bool) void {
    s.lock.err.clear();
    for ([_]app.Field{ .lock_code, .lock_code_2, .lock_current }) |f| s.fields.getPtr(f).clear();
    s.modal = .{ .chat_lock_code = change };
}

fn setLocked(s: *State, id: Id, on: bool) void {
    if (s.store.chat(id.str())) |c| c.setMe("locked", data.boolean(on));
    app.api(s, .POST, std.fmt.allocPrint(tmp(), "/chats/{s}/state", .{id.str()}) catch return, if (on) "{\"locked\":true}" else "{\"locked\":false}", .{ .state_set = id });
    if (on) {
        // It stays open for now.
        s.lock.unlocked.append(gpa, id) catch {};
        app.toast(s, t("Chat locked. It opens with your code."));
    } else app.toast(s, t("Lock removed"));
}

fn wrongCode(s: *State, r: zui.Response, current: bool) void {
    const e = app.apiError(r);
    s.lock.err.set(if (std.mem.eql(u8, e.code, "wrong_code")) (if (current) t("Your current code is not right.") else t("That code is not right.")) else if (std.mem.eql(u8, e.code, "rate_limited") or r.status == 429) t("Too many tries. Wait a few minutes and try again.") else e.message);
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const l = &s.lock;
    switch (op) {
        .lock_verify => |x| {
            l.busy = false;
            if (!r.ok()) {
                wrongCode(s, r, false);
                return true;
            }
            s.modal = null;
            s.fields.getPtr(.lock_code).clear();
            l.unlocked.append(gpa, x.chat) catch {};
            switch (x.purpose) {
                .open => views.openChat(s, x.chat.str()),
                .remove => setLocked(s, x.chat, false),
            }
        },
        .lock_code_saved => |changed| {
            l.busy = false;
            if (!r.ok()) {
                wrongCode(s, r, true);
                return true;
            }
            if (j.obj(j.parse(tmp(), r.body), "user")) |u| app.setMe(s, u);
            s.modal = null;
            if (changed) app.toast(s, t("Chat lock code changed"));
            if (l.lock_after.isSet()) {
                const id = l.lock_after;
                l.lock_after = .{};
                setLocked(s, id, true);
            }
        },
        .lock_off => {
            l.busy = false;
            if (!r.ok()) {
                wrongCode(s, r, false);
                return true;
            }
            if (j.obj(j.parse(tmp(), r.body), "user")) |u| app.setMe(s, u);
            var it = s.store.chats.valueIterator();
            while (it.next()) |c| if (c.*.meBool("locked")) c.*.setMe("locked", data.boolean(false));
            s.modal = null;
        },
        else => return false,
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Views

fn msg(a: Act) Msg {
    return .{ .chat_lock = a };
}

fn codeField(cx: Cx, comptime f: app.Field, label: ?[]const u8, placeholder: []const u8, submit: Msg) void {
    kit.field(cx, f, .{ .label = label, .placeholder = placeholder, .submit = submit, .k = zui.key(@tagName(f)) });
}

pub fn unlockSheet(cx: Cx, chat: Id, purpose: Purpose) void {
    const s = cx.s;
    const ui = cx.ui;
    const name = if (s.store.chat(chat.str())) |c| s.store.title(c) else "";
    views.sheet(cx, t("Unlock chat"));
    ui.begin(.{ .padding = .xy(12, 4), .gap = 10 }, .{});
    ui.begin(.{ .align_items = .center, .padding = .{ .bottom = 6 } }, .{});
    ui.begin(.{ .width = .{ .px = 64 }, .height = .{ .px = 64 }, .radius = 22, .background = cx.c.accent_soft, .align_items = .center, .justify = .center }, .{});
    ui.icon(icons.lock, 30, cx.c.accent, .{}, 0);
    ui.end();
    ui.end();
    ui.text(if (purpose == .remove) fmt.tf("Confirm it is you to remove the lock from {name}.", .{ .name = name }) else fmt.tf("{name} is locked.", .{ .name = name }), .{ .font_size = 15, .color = cx.c.text_2, .text_align = .center, .line_height = 1.5 });
    codeField(cx, .lock_code, null, t("Chat lock code"), msg(.submit_unlock));
    if (s.lock.err.get().len > 0) ui.text(s.lock.err.get(), .{ .font_size = 13, .color = cx.c.danger });
    kit.button(cx, t("Unlock"), msg(.submit_unlock), .{ .block = true, .busy = s.lock.busy });
    ui.end();
    views.endSheet(cx);
}

pub fn codeSheet(cx: Cx, change: bool) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, if (change) t("Change chat lock code") else t("Set a chat lock code"));
    ui.begin(.{ .padding = .xy(12, 4) }, .{});
    if (!change) kit.sectionNote(cx, t("Choose a code to open locked chats. It works on all your devices, including ones without a fingerprint or PIN. Reseal cannot recover it, but you can always remove the lock with it."));
    if (change) codeField(cx, .lock_current, t("Current code"), t("Current code"), msg(.save_code));
    codeField(cx, .lock_code, if (change) t("New code") else t("Chat lock code"), t("At least 4 characters"), msg(.save_code));
    codeField(cx, .lock_code_2, null, t("Repeat the code"), msg(.save_code));
    if (s.lock.err.get().len > 0) ui.text(s.lock.err.get(), .{ .font_size = 13, .color = cx.c.danger });
    ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .top = 8, .bottom = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, t("Save"), msg(.save_code), .{ .busy = s.lock.busy });
    ui.end();
    ui.end();
    views.endSheet(cx);
}

pub fn offSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, t("Turn off chat lock?"));
    ui.begin(.{ .padding = .xy(12, 4) }, .{});
    kit.sectionNote(cx, t("All your locked chats will be unlocked on every device."));
    codeField(cx, .lock_code, null, t("Chat lock code"), msg(.submit_off));
    if (s.lock.err.get().len > 0) ui.text(s.lock.err.get(), .{ .font_size = 13, .color = cx.c.danger });
    ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .top = 8, .bottom = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, t("Turn off"), msg(.submit_off), .{ .kind = .danger, .busy = s.lock.busy });
    ui.end();
    ui.end();
    views.endSheet(cx);
}

/// Settings → Privacy and security → Chat lock.
pub fn pane(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const on = hasCode(s);
    ui.begin(.{ .direction = .row, .gap = 12, .padding = .all(14), .radius = 16, .background = cx.c.accent_soft }, .{});
    ui.icon(icons.lock, 26, cx.c.accent, .{}, 0);
    ui.begin(.{ .grow = 1, .width = .fill, .gap = 4 }, .{});
    ui.text(t("Lock the chats you want to keep to yourself"), .{ .font_size = 15, .weight = 700, .color = cx.c.text });
    ui.text(t("A locked chat opens only with your chat lock code. The chat list and notifications do not show who wrote or what."), .{ .font_size = 13.5, .color = cx.c.text_2, .line_height = 1.5 });
    ui.end();
    ui.end();
    kit.sectionTitle(cx, t("Unlock with"));
    if (on) kit.row(cx, t("Change chat lock code"), .{ .icon = icons.key, .on = msg(.change_code) }) else kit.row(cx, t("Set a chat lock code"), .{ .icon = icons.key, .subtitle = t("Needed before you lock a chat"), .on = msg(.set_code) });
    kit.sectionTitle(cx, t("Locked chats"));
    var any = false;
    var it = s.store.chats.valueIterator();
    while (it.next()) |cp| {
        const c = cp.*;
        if (!c.meBool("locked")) continue;
        any = true;
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 52, .padding = .xy(12, 6) }, .{ .key = kit.key(.{ "locked", c.id() }) });
        vlist.chatAvatar(cx, c, 38);
        ui.text(s.store.title(c), .{ .font_size = 15, .color = cx.c.text, .max_lines = 1, .grow = 1, .width = .fill });
        kit.button(cx, t("Remove lock"), msg(.{ .remove = Id.of(c.id()) }), .{ .small = true, .kind = .ghost });
        ui.end();
    }
    if (!any) kit.sectionNote(cx, t("Lock a chat from its menu: Lock chat."));
    if (on) {
        ui.begin(.{ .padding = .{ .top = 12 } }, .{});
        kit.row(cx, t("Turn off chat lock"), .{ .icon = icons.unlock, .danger = true, .on = msg(.turn_off) });
        ui.end();
    }
}
