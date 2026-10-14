//! The screens: what each button does (onUi), the answers of the requests screens make, and the
//! root view (gates, the shell, overlays). The screens themselves are in view_list.zig,
//! view_chat.zig, view_settings.zig and view_call.zig.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");
const sync = @import("sync.zig");
const send = @import("send.zig");
const media = @import("media.zig");
const calls = @import("calls.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const fmt = @import("fmt.zig");
const ui_kit = @import("ui.zig");
const vlist = @import("view_list.zig");
const vchat = @import("view_chat.zig");
const vset = @import("view_settings.zig");
const vcall = @import("view_call.zig");
const vcompose = @import("view_compose.zig");
const compose = @import("compose.zig");
const group = @import("group.zig");
const vgroup = @import("view_group.zig");
const markdown = @import("markdown.zig");

const State = app.State;
const Msg = app.Msg;
const Id = app.Id;
const gpa = app.gpa;
const t = zui.i18n.t;
const tmp = app.tmp;
const Cx = ui_kit.Cx;
const Color = zui.Color;

pub const quick_reactions = [_][]const u8{ "👍", "❤️", "🔥", "😂", "😮", "😢", "🙏", "👏", "🎉", "🤔", "😍", "💯" };

fn path(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(tmp(), f, args) catch "";
}

fn replaceObj(slot: *?*data.Obj, v: ?j.Value) void {
    if (slot.*) |o| o.destroy();
    slot.* = if (v) |x| data.Obj.create(x) catch null else null;
}

// ---------------------------------------------------------------------------------------------
// What buttons do

pub fn onUi(s: *State, msg: Msg) void {
    // Choices made in a sheet close it.
    switch (msg) {
        .nav, .push_pane, .open_chat, .open_info, .open_user, .open_media, .download, .start_global, .open_wufour, .embed_open, .retry_send, .cancel_send => s.modal = null,
        else => {},
    }
    switch (msg) {
        .nav => |sec| {
            s.section = sec;
            s.panes.clearRetainingCapacity();
            s.searching = false;
            if (sec == .contacts) app.api(s, .GET, "/contacts", null, .contacts);
            if (sec == .calls) app.api(s, .GET, "/calls", null, .calls_list);
            if (sec == .ai) @import("bots.zig").openRoot(s);
            if (sec == .saved and !isPhone()) if (s.store.savedChat()) |c| openChat(s, c.id());
            if (isPhone()) closeChat(s);
        },
        .open_chat => |id| openChat(s, id.str()),
        .close_chat => {
            endSelection(s);
            closeChat(s);
        },
        .push_pane => |p| pushPane(s, p),
        .pop_pane => _ = s.panes.pop(),
        .open_info => |id| {
            s.info = id;
            s.user_info = .{};
            @import("sharedmedia.zig").opened(s, id);
            if (s.store.chat(id.str())) |c| @import("infopanes.zig").opened(s, c);
            if (s.store.chat(id.str())) |c| if (!c.is("private") and !c.is("saved") and !c.is("bot")) {
                group.opened(s, c);
                if (!c.is("channel") or vchat.isAdmin(c)) loadMembers(s, id.str());
            };
        },
        .close_info => {
            s.info = .{};
            s.user_info = .{};
        },
        .open_user => |uid| {
            s.user_info = uid;
            app.api(s, .GET, path("/users/{s}", .{uid.str()}), null, .{ .user_refresh = uid });
        },
        .menu => |m| {
            s.modal = m;
            s.confirm_check = false;
            s.fields.getPtr(.passcode).clear();
            s.fields.getPtr(.passcode_2).clear();
            s.fields.getPtr(.passcode_3).clear();
            if (m == .reactions) app.api(s, .GET, path("/chats/{s}/messages/{s}/reactions", .{ s.open_chat.str(), m.reactions.str() }), null, .{ .reactions = m.reactions });
        },
        .close_modal => {
            s.modal = null;
            s.recovery_shown.clear();
            s.busy = false;
        },
        .confirm => confirm(s),
        .confirm_check => s.confirm_check = !s.confirm_check,
        .toggle_search => |on| {
            s.searching = on;
            if (!on) {
                s.fields.getPtr(.search).clear();
                replaceObj(&s.search, null);
                replaceObj(&s.msg_search, null);
            }
        },
        .filter => |f| s.filter = f,
        .open_archive => pushPane(s, .archive),
        .chat_action => |x| chatAction(s, x.what, x.chat.str()),
        .mute_for => |x| {
            s.modal = null;
            const until: i64 = if (x.hours < 0) 32503680000000 else sys.now() + x.hours * 3_600_000;
            setChatState(s, x.chat.str(), path("{{\"mutedUntil\":{d}}}", .{until}));
        },
        .load_older => if (s.open_chat.isSet()) {
            const tl = s.store.timeline(s.open_chat.str()) catch return;
            if (tl.has_older) if (tl.firstSeq()) |first| sync.loadMessages(s, s.open_chat.str(), .older, first);
            s.show_count += 60;
        },
        .reached_top => if (s.store.existingTimeline(s.open_chat.str())) |tl| {
            if (!tl.loading and (tl.has_older or tl.items.items.len > s.show_count)) onUi(s, .load_older);
        },
        .scrolled => {},
        .jump_latest => if (s.open_chat.isSet()) {
            sync.loadMessages(s, s.open_chat.str(), .latest, 0);
        },
        .send_text => compose.sendNow(s, .{}),
        .attach => s.modal = .{ .compose = .attach },
        .compose => |a| compose.act(s, a),
        .group => |a| group.act(s, a),
        .folder => |a| @import("folders.zig").act(s, a),
        .chat_lock => |a| @import("chatlock.zig").act(s, a),
        .export_chat => |a| @import("export.zig").act(s, a),
        .bots => |a| @import("bots.zig").act(s, a),
        .dev => |a| @import("dev.zig").act(s, a),
        .stories => |a| @import("stories.zig").act(s, a),
        .located => |l| compose.onLocation(s, l),
        .cancel_reply => {
            if (s.editing.isSet()) s.fields.getPtr(.composer).clear();
            s.reply_to = .{};
            s.editing = .{};
        },
        .message_tap => |id| if (s.selecting) toggleSelected(s, id) else {
            s.modal = .{ .menu = .{ .kind = .message, .target = s.open_chat, .item = id } };
        },
        .rich_link => |x| if (s.store.existingTimeline(s.open_chat.str())) |tl| if (tl.find(x.msg.str())) |m| {
            const ents = markdown.fromJson(tmp(), j.field(m.content, "entities"));
            const txt = if (s.isRevealed(m.id())) m.text() else @import("rich.zig").hideSpoilers(tmp(), m.text(), ents);
            switch (@import("rich.zig").linkAt(txt, ents, x.at)) {
                .url => |u| app.fx.openUrl(u, true),
                .username => |name| {
                    app.api(s, .GET, path("/chats/by-username/{s}", .{j.urlEncode(tmp(), name) catch return}), null, .open_username);
                },
                .hashtag => |tag| searchFor(s, tag),
                .code => |code| {
                    app.fx.copy(code);
                    app.toast(s, t("Copied"));
                },
                .none => {},
            }
        },
        .select_cancel => endSelection(s),
        .select_forward => if (s.selected.items.len > 0) @import("fwdpick.zig").open(s, .{}, false),
        .select_delete => if (s.selected.items.len > 0) {
            // "For everyone" is ticked to begin with (Reseal-js deleteFlow).
            s.confirm_check = true;
            s.modal = .{ .confirm = .{ .kind = .delete_messages, .target = s.open_chat } };
        },
        .select_copy => copySelected(s),
        .message_action => |x| messageAction(s, x.what, x.msg.str()),
        .react => |x| react(s, x.msg.str(), x.emoji),
        .vote => |x| {
            s.modal = null;
            app.api(s, .POST, path("/chats/{s}/messages/{s}/vote", .{ s.open_chat.str(), x.msg.str() }), path("{{\"options\":[{d}]}}", .{x.option}), .{ .vote = .{ .chat = s.open_chat, .msg = x.msg } });
        },
        .retry_send => |local| send.retry(s, local),
        .cancel_send => |local| send.cancel(s, local),
        .open_media => |x| {
            s.viewer = .{ .msg = x.msg, .index = x.index };
            if (mediaItem(s, x.msg.str(), x.index)) |item| _ = media.file(s, item, false);
        },
        .close_viewer => s.viewer = null,
        .download => |x| if (mediaItem(s, x.msg.str(), x.index)) |item| {
            _ = media.file(s, item, true);
        },
        .pick_user => |uid| pickUser(s, uid),
        .unpick_user => |uid| {
            for (s.picked.items, 0..) |p, i| if (p.eql(uid.str())) {
                _ = s.picked.orderedRemove(i);
                break;
            };
        },
        .picker_done => pickerDone(s),
        .create_group => createGroup(s),
        .toggle_encrypted => s.new_group_encrypted = !s.new_group_encrypted,
        .join_chat => |id| app.api(s, .POST, path("/chats/{s}/join", .{id.str()}), "{}", .{ .join = id }),
        .start_global => |uid| {
            s.searching = false;
            app.api(s, .POST, "/chats/private", path("{{\"userId\":\"{s}\"}}", .{uid.str()}), .open_private);
        },
        .open_wufour => |wid| {
            s.searching = false;
            app.api(s, .POST, "/chats/private", path("{{\"wufourId\":\"{s}\"}}", .{wid.str()}), .open_private);
        },
        .save_profile => saveProfile(s),
        .save_saved => saveSaved(s),
        .set_theme => |th| {
            s.prefs.theme = th;
            app.savePrefs(s);
        },
        .set_accent => |i| {
            s.prefs.accent = i;
            app.savePrefs(s);
        },
        .set_font => |d| {
            s.prefs.font = std.math.clamp(s.prefs.font + @as(f32, @floatFromInt(d)), 13, 20);
            app.savePrefs(s);
        },
        .set_lang => |l| {
            const changed = s.lang != l;
            app.setLang(s, l);
            zui.storage.set("lang", @tagName(l), .{});
            // As Reseal-js: the web says so and reloads in the new language; the phones switch at once.
            if (changed and zui.platform == .web and s.mode == .app) {
                app.toast(s, t("Language changed. Reloading…"));
                app.fx.after(600, .reload_page);
            }
        },
        .toggle_pref => |p| {
            switch (p) {
                .notifications => s.prefs.notifications = !s.prefs.notifications,
                .previews => {
                    s.prefs.previews = !s.prefs.previews;
                    app.api(s, .PATCH, "/me", if (s.prefs.previews) "{\"settings\":{\"notifyPreview\":true}}" else "{\"settings\":{\"notifyPreview\":false}}", .ignore);
                },
                .sounds => s.prefs.sounds = !s.prefs.sounds,
                .send_with_enter => s.prefs.send_with_enter = !s.prefs.send_with_enter,
                .link_previews => s.prefs.link_previews = !s.prefs.link_previews,
                .square_bubbles => s.prefs.square_bubbles = !s.prefs.square_bubbles,
                .animations => s.prefs.animations = !s.prefs.animations,
            }
            app.savePrefs(s);
        },
        .set_privacy => |x| {
            app.api(s, .PATCH, "/me", path("{{\"privacy\":{{\"{s}\":\"{s}\"}}}}", .{ @tagName(x.key), @tagName(x.value) }), .privacy);
        },
        .toggle_read_receipts => {
            const on = if (s.store.me) |me| j.field(me.v, "privacy.readReceipts") == null or j.truthy(me.v, "privacy.readReceipts") else true;
            app.api(s, .PATCH, "/me", if (on) "{\"privacy\":{\"readReceipts\":false}}" else "{\"privacy\":{\"readReceipts\":true}}", .privacy);
        },
        .advanced_submit => keys.advancedSubmit(s),
        .copy_text => |id| if (s.store.existingTimeline(s.open_chat.str())) |tl| if (tl.find(id.str())) |m| {
            app.fx.copy(m.text());
            app.toast(s, t("Copied"));
        },
        .copy_recovery => {
            app.fx.copy(s.recovery_shown.get());
            app.toast(s, t("Recovery key copied"));
        },
        .embed_open => |target| embedTarget(s, target),
        .forward_to => |to| forwardTo(s, to.str()),
        .join_invite => {
            s.modal = null;
            app.api(s, .POST, path("/invites/{s}/join", .{j.urlEncode(tmp(), s.invite_code.str()) catch return}), "{}", .invite_join);
        },
        else => {},
    }
}

fn isPhone() bool {
    return app.env.width <= theme.phone_max;
}

pub fn openChat(s: *State, id: []const u8) void {
    if (!@import("chatlock.zig").mayOpen(s, id)) return;
    if (s.open_chat.isSet() and !s.open_chat.eql(id)) sync.cancelTyping(s);
    if (!s.open_chat.eql(id)) {
        endSelection(s);
        s.reply_to = .{};
        s.editing = .{};
        s.fields.getPtr(.composer).clear();
        s.show_count = 60;
        @import("drafts.zig").restore(s, id);
    }
    s.open_chat = Id.of(id);
    if (s.mode == .app) app.fx.setLink(path("/c/{s}", .{id}));
    s.searching = false;
    s.info = .{};
    s.user_info = .{};
    s.modal = null;
    const c = s.store.chat(id) orelse {
        sync.ensureChat(s, id);
        return;
    };
    s.first_unread = if (c.unread() > 0) c.meInt("lastReadSeq") + 1 else 0;
    if (c.is("saved") and s.section != .saved) s.section = .saved else if (!c.is("saved") and s.section == .saved) s.section = .chats;
    sync.openTimeline(s, id);
    sync.markOpenChatRead(s);
    sync.cancelNotification(id);
    if (c.is("group") or c.is("support")) loadMembers(s, id);
    // Refresh the key in the background after someone left.
    if (c.encrypted() and c.o.b("rotationNeeded") and (std.mem.eql(u8, c.role(), "owner") or std.mem.eql(u8, c.role(), "admin"))) keys.rotate(s, id);
}

fn closeChat(s: *State) void {
    sync.cancelTyping(s);
    if (s.mode == .app and s.open_chat.isSet()) app.fx.setLink("/");
    s.open_chat = .{};
    s.info = .{};
    s.user_info = .{};
}

fn pushPane(s: *State, p: app.Pane) void {
    s.panes.append(gpa, p) catch {};
    switch (p) {
        .profile => if (s.store.me) |me| {
            s.fields.getPtr(.profile_name).set(me.s("displayName") orelse "");
            s.fields.getPtr(.profile_bio).set(me.s("bio") orelse "");
            s.fields.getPtr(.profile_username).set(me.s("username") orelse "");
        },
        .blocked => app.api(s, .GET, "/blocks", null, .blocked),
        .picker => {
            s.picked.clearRetainingCapacity();
            s.fields.getPtr(.picker).clear();
            replaceObj(&s.picker_results, null);
            app.api(s, .GET, "/contacts", null, .contacts);
        },
        .group_details => {
            s.fields.getPtr(.group_name).clear();
            s.fields.getPtr(.group_about).clear();
            s.new_group_encrypted = p.group_details == .group;
        },
        .saved_edit => |id| {
            const c = s.store.chat(id.str());
            s.fields.getPtr(.saved_title).set(if (c) |cc| cc.o.s("title") orelse "" else "");
            s.fields.getPtr(.saved_about).set(if (c) |cc| cc.o.s("about") orelse "" else "");
        },
        else => {},
    }
}

fn setChatState(s: *State, chat: []const u8, body: []const u8) void {
    // Optimistic (chats.js setState): applied now, the server's answer replaces it.
    if (s.store.chat(chat)) |c| if (j.parse(tmp(), body)) |v| {
        var it = v.object.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "pinned")) {
                c.setMe("pinnedAt", if (e.value_ptr.* == .bool and e.value_ptr.bool) data.string(isoNow()) else .null);
            } else c.setMe(e.key_ptr.*, e.value_ptr.*);
        }
    };
    app.api(s, .POST, path("/chats/{s}/state", .{chat}), body, .{ .state_set = Id.of(chat) });
}

fn isoNow() []const u8 {
    const c = sys.civilFromMs(sys.now());
    return path("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{ @as(u32, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second });
}

fn chatAction(s: *State, what: app.ChatAction, chat: []const u8) void {
    s.modal = null;
    const c = s.store.chat(chat) orelse return;
    switch (what) {
        .pin => setChatState(s, chat, "{\"pinned\":true}"),
        .unpin => setChatState(s, chat, "{\"pinned\":false}"),
        .archive => {
            setChatState(s, chat, "{\"archived\":true}");
            @import("listextras.zig").archived(s, Id.of(chat));
        },
        .unarchive => setChatState(s, chat, "{\"archived\":false}"),
        .mute => s.modal = .{ .menu = .{ .kind = .mute, .target = Id.of(chat) } },
        .unmute => setChatState(s, chat, "{\"mutedUntil\":null}"),
        .mark_read => {
            const seq = if (c.last) |m| m.seq() orelse c.seq() else c.seq();
            sync.markRead(s, c, seq);
            sync.flushRead(s, Id.of(chat));
        },
        .mark_unread => setChatState(s, chat, "{\"markedUnread\":true}"),
        .delete => s.modal = .{ .confirm = .{ .kind = if (c.is("saved") and !c.o.b("primary")) .delete_saved else if (c.is("saved")) .clear_history else .delete_chat, .target = Id.of(chat) } },
        .leave => s.modal = .{ .confirm = .{ .kind = .leave_chat, .target = Id.of(chat) } },
        .lock => @import("chatlock.zig").act(s, .{ .lock = Id.of(chat) }),
        .export_chat => @import("export.zig").act(s, .{ .open = Id.of(chat) }),
        .unlock => @import("chatlock.zig").act(s, .{ .remove = Id.of(chat) }),
        .add_to_folder => s.modal = .{ .menu = .{ .kind = .folder_pick, .target = Id.of(chat) } },
        .clear => {
            s.confirm_check = false;
            s.modal = .{ .confirm = .{ .kind = .clear_history, .target = Id.of(chat) } };
        },
        .block => s.modal = .{ .confirm = .{ .kind = .block, .target = Id.of(chat) } },
        .unblock => if (c.peerId()) |pid| {
            app.api(s, .DELETE, path("/blocks/{s}", .{pid}), null, .unblock);
            if (s.store.user(pid)) |u| u.set("blocked", data.boolean(false)) catch {};
        },
        .add_contact => if (c.peerId()) |pid| {
            app.api(s, .POST, "/contacts", path("{{\"userId\":\"{s}\"}}", .{pid}), .contact_add);
        },
        .info => onUi(s, .{ .open_info = Id.of(chat) }),
        .call_voice => calls.act(s, .{ .start = .{ .chat = Id.of(chat), .video = false } }),
        .call_video => calls.act(s, .{ .start = .{ .chat = Id.of(chat), .video = true } }),
        .saved_edit => pushPane(s, .{ .saved_edit = Id.of(chat) }),
        .search => {
            s.fields.getPtr(.chat_search).clear();
            replaceObj(&s.msg_search, null);
            s.modal = .{ .menu = .{ .kind = .chat_header, .target = Id.of(chat), .item = Id.of("search") } };
        },
        .show_safety => if (c.peerId()) |pid| {
            s.modal = .{ .safety = Id.of(pid) };
        },
    }
}

fn confirm(s: *State) void {
    const m = s.modal orelse return;
    if (m != .confirm) return;
    const x = m.confirm;
    const chat = x.target.str();
    s.modal = null;
    switch (x.kind) {
        .logout => app.logout(s),
        .start_fresh => keys.setupAutomatic(s, true),
        .delete_chat => {
            const c = s.store.chat(chat) orelse return;
            const pair = c.is("private") or c.is("bot") or (c.isTeamChat() and !s.store.isTeamStaff(c));
            if (pair and !s.confirm_check) {
                app.api(s, .POST, path("/chats/{s}/leave", .{chat}), "{}", .{ .leave = x.target });
            } else app.api(s, .DELETE, path("/chats/{s}", .{chat}), null, .{ .delete_chat = x.target });
        },
        .delete_saved => app.api(s, .DELETE, path("/chats/{s}", .{chat}), null, .{ .delete_chat = x.target }),
        .leave_chat => app.api(s, .POST, path("/chats/{s}/leave", .{chat}), "{}", .{ .leave = x.target }),
        .clear_history => app.api(s, .POST, path("/chats/{s}/clear", .{chat}), if (s.confirm_check or (s.store.chat(chat) != null and s.store.chat(chat).?.is("saved"))) "{\"forEveryone\":true}" else "{\"forEveryone\":false}", .{ .clear = x.target }),
        .delete_messages => {
            // One message (from its menu), or the selection.
            var ids: std.ArrayList(u8) = .empty;
            const a = tmp();
            if (x.item.isSet()) {
                ids.print(a, "\"{s}\"", .{x.item.str()}) catch {};
            } else for (s.selected.items, 0..) |id, i| {
                ids.print(a, "{s}\"{s}\"", .{ if (i > 0) "," else "", id.str() }) catch {};
            }
            const all = if (s.store.chat(chat)) |c| deleteForAllAlways(c) else false;
            const everyone = all or (s.confirm_check and if (s.store.chat(chat)) |c| canDeleteForEveryone(s, c, x.item) else false);
            app.api(s, .POST, path("/chats/{s}/messages/delete", .{chat}), path("{{\"ids\":[{s}],\"forEveryone\":{}}}", .{ ids.items, everyone }), .{ .delete_messages = x.target });
            if (s.store.existingTimeline(chat)) |tl| {
                if (x.item.isSet()) tl.remove(x.item.str()) else for (s.selected.items) |id| tl.remove(id.str());
            }
            if (!x.item.isSet()) endSelection(s);
        },
        .block => if (s.store.chat(chat)) |c| if (c.peerId()) |pid| {
            app.api(s, .POST, "/blocks", path("{{\"userId\":\"{s}\"}}", .{pid}), .block);
            if (s.store.user(pid)) |u| u.set("blocked", data.boolean(true)) catch {};
        },
        .unblock => app.api(s, .DELETE, path("/blocks/{s}", .{chat}), null, .unblock),
        .remove_contact => app.api(s, .DELETE, path("/contacts/{s}", .{chat}), null, .contact_remove),
        .ban_member, .transfer_owner => group.confirmed(s, x.kind, x.target, x.item),
        .dev_roll => @import("dev.zig").confirmed(s),
        .delete_story => @import("stories.zig").confirmed(s),
    }
}

fn mediaItem(s: *State, msg: []const u8, index: u8) ?j.Value {
    const tl = s.store.existingTimeline(s.open_chat.str()) orelse return null;
    const m = tl.find(msg) orelse return null;
    const items = m.media();
    if (index >= items.len) return null;
    return items[index];
}


fn messageAction(s: *State, what: app.MessageAction, msg_id: []const u8) void {
    s.modal = null;
    const chat = s.open_chat.str();
    const tl = s.store.existingTimeline(chat) orelse return;
    const m = tl.find(msg_id) orelse return;
    switch (what) {
        .reply => {
            s.reply_to = Id.of(msg_id);
            s.editing = .{};
            app.fx.focus(zui.key("composer"));
        },
        .edit => {
            s.editing = Id.of(msg_id);
            s.reply_to = .{};
            const a = app.tmp();
            s.fields.getPtr(.composer).set(markdown.toMarkdown(a, m.text(), markdown.fromJson(a, j.field(m.content, "entities"))) catch m.text());
            app.fx.focus(zui.key("composer"));
        },
        .copy => {
            app.fx.copy(m.text());
            app.toast(s, t("Copied"));
        },
        .pin => @import("msgextras.zig").act(s, .{ .pin_ask = Id.of(msg_id) }),
        .unpin => app.api(s, .POST, path("/chats/{s}/messages/{s}/pin", .{ chat, msg_id }), "{\"unpin\":true}", .pin),
        .delete, .delete_everyone => {
            s.confirm_check = true;
            s.modal = .{ .confirm = .{ .kind = .delete_messages, .target = s.open_chat, .item = Id.of(msg_id) } };
        },
        .save => {
            // A forward into a saved chat (asking which one when there are several).
            var only: ?*data.Chat = null;
            var n: usize = 0;
            var it = s.store.chats.valueIterator();
            while (it.next()) |c| if (c.*.is("saved") and !s.open_chat.eql(c.*.id())) {
                n += 1;
                only = c.*;
            };
            if (n > 1) return @import("fwdpick.zig").open(s, Id.of(msg_id), true);
            const saved = only orelse return;
            forwardMessages(s, saved.id(), Id.of(msg_id));
            app.toast(s, if (saved.o.b("primary")) t("Saved to Saved Messages") else fmt.tf("Saved to {name}", .{ .name = s.store.title(saved) }));
        },
        .retract_vote => app.api(s, .POST, path("/chats/{s}/messages/{s}/vote", .{ chat, msg_id }), "{\"options\":[]}", .{ .vote = .{ .chat = s.open_chat, .msg = Id.of(msg_id) } }),
        .forward => @import("fwdpick.zig").open(s, Id.of(msg_id), false),
        .close_poll => app.api(s, .POST, path("/chats/{s}/messages/{s}/close-poll", .{ chat, msg_id }), "{}", .{ .vote = .{ .chat = s.open_chat, .msg = Id.of(msg_id) } }),
        .open_map => if (j.obj(m.content, "location")) |loc| {
            const base = if (s.store.config) |cfg| cfg.s("mapsUrl") orelse "https://maps.wreseal.com" else "https://maps.wreseal.com";
            const a = app.tmp();
            const title = j.str(loc, "title") orelse t("Location");
            app.fx.openUrl(std.fmt.allocPrint(a, "{s}/?q={s}&lat={d}&lng={d}", .{ std.mem.trimEnd(u8, base, "/"), j.urlEncode(a, title) catch "", j.floatOr(loc, "lat", 0), j.floatOr(loc, "lng", 0) }) catch return, true);
        },
        .open_link => if (j.str(m.content, "preview.url")) |u| app.fx.openUrl(u, true),
        .reveal => {
            for (s.revealed.items, 0..) |x, i| if (x.eql(msg_id)) {
                _ = s.revealed.orderedRemove(i);
                return;
            };
            s.revealed.append(app.gpa, Id.of(msg_id)) catch {};
        },
        .select => {
            s.selecting = true;
            s.selected.clearRetainingCapacity();
            s.selected.append(app.gpa, Id.of(msg_id)) catch {};
        },
        .details => {},
    }
}

fn forwardTo(s: *State, to: []const u8) void {
    const m_id = if (s.modal) |m| (if (m == .forward) m.forward else return) else return;
    s.modal = null;
    forwardMessages(s, to, m_id);
    if (!m_id.isSet()) endSelection(s);
    app.toast(s, t("Forwarded"));
}

/// Forwards one message of the open chat, or (`m_id` unset) the selection, oldest first.
pub fn forwardMessages(s: *State, to: []const u8, m_id: Id) void {
    if (m_id.isSet()) return forwardOne(s, to, m_id.str());
    const tl = s.store.existingTimeline(s.open_chat.str()) orelse return;
    for (tl.items.items) |m| if (s.isSelected(m.id())) forwardOne(s, to, m.id());
}

fn toggleSelected(s: *State, id: Id) void {
    for (s.selected.items, 0..) |x, i| if (x.eql(id.str())) {
        _ = s.selected.orderedRemove(i);
        if (s.selected.items.len == 0) s.selecting = false;
        return;
    };
    s.selected.append(app.gpa, id) catch {};
}

pub fn endSelection(s: *State) void {
    s.selecting = false;
    s.selected.clearRetainingCapacity();
}

fn copySelected(s: *State) void {
    const tl = s.store.existingTimeline(s.open_chat.str()) orelse return;
    var out: std.ArrayList(u8) = .empty;
    const a = tmp();
    for (tl.items.items) |m| if (s.isSelected(m.id()) and m.text().len > 0) {
        if (out.items.len > 0) out.appendSlice(a, "\n\n") catch {};
        out.appendSlice(a, m.text()) catch {};
    };
    app.fx.copy(out.items);
    app.toast(s, t("Copied"));
    endSelection(s);
}

fn forwardOne(s: *State, to: []const u8, msg_id: []const u8) void {
    const from = s.store.chat(s.open_chat.str()) orelse return;
    const target = s.store.chat(to) orelse return;
    const tl = s.store.existingTimeline(from.id()) orelse return;
    const m = tl.find(msg_id) orelse return;
    if (!from.encrypted() and !target.encrypted()) {
        // Both readable by the server: it copies the message itself.
        const body = path("{{\"fwd\":{{\"messageId\":\"{s}\",\"chatId\":\"{s}\"}},\"clientId\":\"fwd-{s}-{d}\"}}", .{ m.id(), from.id(), m.id(), sys.now() });
        app.api(s, .POST, path("/chats/{s}/messages", .{to}), body, .ignore);
    } else {
        var media_items = m.media();
        // Encrypted files cannot go into a chat the server can read (they would need a new upload).
        if (!target.encrypted()) media_items = &.{};
        const existing = j.obj(m.content, "fwd");
        const sender = m.senderId();
        const fwd = if (existing) |e| (j.stringify(tmp(), e) catch "{}") else path("{{\"fromUserId\":{s},\"fromName\":{s},\"fromChatId\":{s},\"date\":{s}}}", .{
            if (sender.len > 0) (j.quote(tmp(), sender) catch "null") else "null",
            if (sender.len > 0) (j.quote(tmp(), s.store.displayName(sender)) catch "null") else "null",
            if (from.is("channel")) (j.quote(tmp(), from.id()) catch "null") else "null",
            j.quote(tmp(), m.o.s("createdAt") orelse "") catch "null",
        });
        send.forward(s, to, m.text(), media_items, fwd);
    }
}

fn react(s: *State, msg_id: []const u8, emoji_index: u8) void {
    if (emoji_index >= quick_reactions.len) return;
    reactEmoji(s, msg_id, quick_reactions[emoji_index]);
}

/// Toggles my reaction `emoji` on a message of the open chat.
pub fn reactEmoji(s: *State, msg_id: []const u8, emoji: []const u8) void {
    s.modal = null;
    const chat = s.open_chat.str();
    const tl = s.store.existingTimeline(chat) orelse return;
    const m = tl.find(msg_id) orelse return;
    var on = true;
    for (j.arr(m.o.v, "reactions")) |r| if (j.eqlStr(r, "emoji", emoji) and j.truthy(r, "me")) {
        on = false;
    };
    app.api(s, .POST, path("/chats/{s}/messages/{s}/react", .{ chat, msg_id }), path("{{\"emoji\":{s},\"on\":{}}}", .{ j.quote(tmp(), emoji) catch "\"\"", on }), .{ .react = .{ .chat = s.open_chat, .msg = Id.of(msg_id) } });
}

fn pickUser(s: *State, uid: Id) void {
    const p = if (s.panes.items.len > 0) s.panes.items[s.panes.items.len - 1] else return;
    if (p != .picker) return;
    switch (p.picker) {
        .new_message => {
            _ = s.panes.pop();
            app.api(s, .POST, "/chats/private", path("{{\"userId\":\"{s}\"}}", .{uid.str()}), .open_private);
        },
        .add_contact => {
            _ = s.panes.pop();
            app.api(s, .POST, "/contacts", path("{{\"userId\":\"{s}\"}}", .{uid.str()}), .contact_add);
        },
        .block => {
            _ = s.panes.pop();
            app.api(s, .POST, "/blocks", path("{{\"userId\":\"{s}\"}}", .{uid.str()}), .block);
        },
        .new_group, .add_members => {
            for (s.picked.items) |x| if (x.eql(uid.str())) return;
            s.picked.append(gpa, uid) catch {};
        },
    }
}

fn pickerDone(s: *State) void {
    const p = if (s.panes.items.len > 0) s.panes.items[s.panes.items.len - 1] else return;
    if (p != .picker) return;
    switch (p.picker) {
        .new_group => pushPane(s, .{ .group_details = .group }),
        .add_members => {
            _ = s.panes.pop();
            if (s.picked.items.len == 0 or !s.info.isSet()) return;
            var ids: std.ArrayList(u8) = .empty;
            for (s.picked.items, 0..) |x, i| ids.print(tmp(), "{s}\"{s}\"", .{ if (i == 0) "" else ",", x.str() }) catch {};
            app.api(s, .POST, path("/chats/{s}/members", .{s.info.str()}), path("{{\"userIds\":[{s}]}}", .{ids.items}), .{ .members = s.info });
        },
        else => {},
    }
}

fn createGroup(s: *State) void {
    const name = s.fields.get(.group_name).trimmed();
    if (name.len == 0) return app.toastError(s, t("Group name"));
    const p = s.panes.items[s.panes.items.len - 1];
    const typ = if (p == .group_details and p.group_details == .channel) "channel" else "group";
    var ids: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, typ, "group")) for (s.picked.items, 0..) |x, i| ids.print(tmp(), "{s}\"{s}\"", .{ if (i == 0) "" else ",", x.str() }) catch {};
    const about = s.fields.get(.group_about).trimmed();
    const body = path("{{\"type\":\"{s}\",\"title\":{s},\"members\":[{s}]{s}{s}{s}}}", .{
        typ,                                                                             j.quote(tmp(), name) catch return, ids.items,
        if (about.len > 0) path(",\"about\":{s}", .{j.quote(tmp(), about) catch "\"\""}) else "", if (std.mem.eql(u8, typ, "group")) (if (s.new_group_encrypted) ",\"encrypted\":true" else ",\"encrypted\":false") else "",
        "",
    });
    s.busy = true;
    app.api(s, .POST, "/chats", body, .create_group);
}

fn saveSaved(s: *State) void {
    const p = if (s.panes.items.len > 0) s.panes.items[s.panes.items.len - 1] else return;
    if (p != .saved_edit) return;
    const id = p.saved_edit;
    const c = if (id.isSet()) s.store.chat(id.str()) else null;
    const primary = if (c) |cc| cc.o.b("primary") else false;
    const title = s.fields.get(.saved_title).trimmed();
    if (!primary and title.len == 0) return app.toastError(s, t("Name"));
    const about = j.quote(tmp(), s.fields.get(.saved_about).trimmed()) catch return;
    const body = if (primary) path("{{\"about\":{s}}}", .{about}) else path("{{\"title\":{s},\"about\":{s}}}", .{ j.quote(tmp(), title) catch return, about });
    if (id.isSet()) {
        app.api(s, .PATCH, path("/chats/{s}", .{id.str()}), body, .{ .saved_save = id });
    } else app.api(s, .POST, "/chats/saved", body, .{ .saved_save = .{} });
}

fn saveProfile(s: *State) void {
    const name = s.fields.get(.profile_name).trimmed();
    if (name.len == 0) return app.toastError(s, t("Name"));
    const username = s.fields.get(.profile_username).trimmed();
    const body = path("{{\"displayName\":{s},\"bio\":{s}{s}}}", .{
        j.quote(tmp(), name) catch return,
        j.quote(tmp(), s.fields.get(.profile_bio).trimmed()) catch return,
        if (username.len > 0) path(",\"username\":{s}", .{j.quote(tmp(), username) catch "\"\""}) else "",
    });
    s.busy = true;
    app.api(s, .PATCH, "/me", body, .profile_save);
}

// ---------------------------------------------------------------------------------------------
// Searching

pub fn runSearch(s: *State) void {
    const q = s.fields.get(.search).trimmed();
    s.searching = true;
    s.search_seq += 1;
    if (q.len == 0) {
        replaceObj(&s.search, null);
        replaceObj(&s.msg_search, null);
        return;
    }
    const enc = j.urlEncode(tmp(), q) catch return;
    app.api(s, .GET, path("/search?q={s}", .{enc}), null, .{ .search = s.search_seq });
    if (q.len >= 2) app.api(s, .GET, path("/search/messages?q={s}", .{enc}), null, .{ .msg_search = s.search_seq });
}

pub fn runPickerSearch(s: *State) void {
    const q = s.fields.get(.picker).trimmed();
    s.search_seq += 1;
    if (q.len < 2) return replaceObj(&s.picker_results, null);
    app.api(s, .GET, path("/search?q={s}", .{j.urlEncode(tmp(), q) catch return}), null, .{ .picker_search = s.search_seq });
}

pub fn runChatSearch(s: *State) void {
    const q = s.fields.get(.chat_search).trimmed();
    s.search_seq += 1;
    if (q.len < 2 or !s.open_chat.isSet()) return replaceObj(&s.msg_search, null);
    const c = s.store.chat(s.open_chat.str()) orelse return;
    // Encrypted chats are searched on this device (the loaded history); others on the server.
    if (!c.encrypted()) app.api(s, .GET, path("/search/messages?q={s}&chatId={s}", .{ j.urlEncode(tmp(), q) catch return, c.id() }), null, .{ .msg_search = s.search_seq });
}

pub fn loadMembers(s: *State, chat: []const u8) void {
    s.members_chat = Id.of(chat);
    app.api(s, .GET, path("/chats/{s}/members?limit=200", .{chat}), null, .{ .members = Id.of(chat) });
}

// ---------------------------------------------------------------------------------------------
// The widget's targets (embed.js openTarget)

pub fn embedOpen(s: *State, target: ?j.Value) void {
    const tg = target orelse return;
    if (j.str(tg, "chatId")) |id| return openChat(s, id);
    if (j.truthy(tg, "bot")) return embedTarget(s, .bot);
    if (j.truthy(tg, "support")) return embedTarget(s, .support);
    if (j.field(tg, "team")) |team| {
        const body = path("{{\"team\":{s},\"externalChatId\":{s},\"metadata\":{s}}}", .{
            j.stringify(tmp(), team) catch return,
            j.stringify(tmp(), j.field(tg, "externalChatId") orelse .null) catch "null",
            j.stringify(tmp(), j.field(tg, "metadata") orelse .null) catch "null",
        });
        app.api(s, .POST, "/embed/team", body, .embed_team);
        return;
    }
    if (j.str(tg, "withUser")) |u| {
        app.api(s, .GET, path("/embed/resolve?user={s}", .{j.urlEncode(tmp(), u) catch return}), null, .open_wufour);
        return;
    }
    if (j.str(tg, "externalChatId")) |x| app.api(s, .GET, path("/embed/resolve?chat={s}", .{j.urlEncode(tmp(), x) catch return}), null, .open_wufour);
}

fn embedTarget(s: *State, target: app.EmbedTarget) void {
    app.api(s, .POST, if (target == .bot) "/embed/bot" else "/embed/support", "{}", .{ .embed_target = target });
}

pub fn embedAfterChats(s: *State) void {
    const opts = if (s.embed.options) |o| o.v else null;
    if (j.obj(opts, "open")) |o| return embedOpen(s, o);
    const app_v = if (s.embed.app) |a| a.v else null;
    const def = j.strOr(app_v, "widget.defaultView", "");
    if (std.mem.eql(u8, def, "bot") and j.field(app_v, "widget.bot") != null) embedTarget(s, .bot);
    if (std.mem.eql(u8, def, "support")) embedTarget(s, .support);
}

// ---------------------------------------------------------------------------------------------
// Answers to what the screens asked

/// The open chat's search, filled in (a tapped #hashtag).
pub fn searchFor(s: *State, q: []const u8) void {
    if (!s.open_chat.isSet()) return;
    s.modal = .{ .menu = .{ .kind = .chat_header, .target = s.open_chat, .item = Id.of("search") } };
    s.fields.getPtr(.chat_search).set(q);
    runChatSearch(s);
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) void {
    const v = j.parse(tmp(), r.body);
    if (!r.ok()) {
        s.busy = false;
        switch (op) {
            .search, .msg_search, .picker_search, .members, .reactions => {},
            .open_username => app.toastError(s, if (r.status == 404) t("Nobody has that username.") else app.apiError(r).message),
            else => app.toastError(s, app.apiError(r).message),
        }
        return;
    }
    switch (op) {
        .search => |seq| if (seq == s.search_seq) {
            if (v) |x| for (j.arr(x, "users")) |u| {
                _ = s.store.putUser(u) catch null;
            };
            replaceObj(&s.search, v);
        },
        .msg_search => |seq| if (seq == s.search_seq) replaceObj(&s.msg_search, v),
        .picker_search => |seq| if (seq == s.search_seq) {
            if (v) |x| for (j.arr(x, "users")) |u| {
                _ = s.store.putUser(u) catch null;
            };
            replaceObj(&s.picker_results, v);
        },
        .open_private, .embed_team => {
            const raw = j.obj(v, "chat") orelse return;
            const c = s.store.putChat(raw) catch return;
            if (c.last) |m| keys.hydrate(s, c.id(), m);
            s.panes.clearRetainingCapacity();
            openChat(s, c.id());
        },
        .invite => {
            if (j.truthy(v, "member")) {
                if (j.str(v, "chat.id")) |id| openChat(s, id);
                return;
            }
            replaceObj(&s.invite, v);
            app.fx.setLink("/");
            s.modal = .{ .join = .{} };
        },
        .invite_join => {
            if (j.truthy(v, "requested")) return app.toast(s, t("Request sent. An admin will review it."));
            if (j.obj(v, "chat")) |raw| {
                const c = s.store.putChat(raw) catch return;
                openChat(s, c.id());
            }
        },
        .open_username => {
            if (j.obj(v, "user")) |u| {
                app.api(s, .POST, "/chats/private", path("{{\"userId\":\"{s}\"}}", .{j.strOr(u, "id", "")}), .open_private);
            } else if (j.obj(v, "chat")) |raw| {
                const c = s.store.putChat(raw) catch return;
                openChat(s, c.id());
            }
        },
        .open_wufour => {
            // /embed/resolve: {userId} or {chatId}
            if (j.str(v, "chatId")) |id| return openChat(s, id);
            if (j.str(v, "userId")) |uid| app.api(s, .POST, "/chats/private", path("{{\"userId\":\"{s}\"}}", .{uid}), .open_private);
        },
        .embed_target => {
            const raw = j.obj(v, "chat") orelse return;
            const c = s.store.putChat(raw) catch return;
            openChat(s, c.id());
        },
        .create_group => {
            s.busy = false;
            const raw = j.obj(v, "chat") orelse return;
            const c = s.store.putChat(raw) catch return;
            s.panes.clearRetainingCapacity();
            s.picked.clearRetainingCapacity();
            if (j.arr(v, "skipped").len > 0) app.toast(s, t("Some people could not be added because of their privacy settings."));
            openChat(s, c.id());
        },
        .contacts => {
            if (v) |x| for (j.arr(x, "contacts")) |u| {
                _ = s.store.putUser(u) catch null;
            };
            replaceObj(&s.contacts, v);
        },
        .contact_add => {
            app.toast(s, t("Added to contacts"));
            app.api(s, .GET, "/contacts", null, .contacts);
        },
        .contact_remove => app.api(s, .GET, "/contacts", null, .contacts),
        .calls_list => {
            replaceObj(&s.calls_list, v);
            if (v) |x| for (j.arr(x, "calls")) |cl| sync.ensureChat(s, j.strOr(cl, "chatId", ""));
        },
        .blocked => replaceObj(&s.blocked, v),
        .block, .unblock => {
            app.toast(s, if (op == .block) t("User blocked") else t("User unblocked"));
            app.api(s, .GET, "/blocks", null, .blocked);
        },
        .members => |chat| {
            if (v) |x| for (j.arr(x, "members")) |m| if (j.obj(m, "user")) |u| {
                _ = s.store.putUser(u) catch null;
            };
            if (s.members_chat.eql(chat.str())) replaceObj(&s.members, v);
        },
        .reactions => replaceObj(&s.reactions_detail, v),
        // Deleted for me only: the list's last message comes from the server again.
        .delete_messages => |chat| app.api(s, .GET, path("/chats/{s}", .{chat.str()}), null, .{ .chat_refresh = chat }),
        .profile_save => {
            s.busy = false;
            if (j.obj(v, "user")) |u| app.setMe(s, u);
            _ = s.panes.pop();
        },
        .privacy => if (j.obj(v, "user")) |u| app.setMe(s, u),
        .leave, .delete_chat => |chat| {
            s.store.removeChat(chat.str());
            if (s.open_chat.eql(chat.str())) closeChat(s);
        },
        .clear => {},
        .join => |chat| {
            if (j.truthy(v, "requested")) return app.toast(s, t("Join request sent. An admin will review it."));
            if (j.obj(v, "chat")) |raw| {
                _ = s.store.putChat(raw) catch null;
                openChat(s, chat.str());
            }
        },
        .react => |x| if (s.store.existingTimeline(x.chat.str())) |tl| if (tl.find(x.msg.str())) |m| {
            m.o.set("reactions", j.field(v, "reactions") orelse .null) catch {};
        },
        .vote => |x| if (s.store.existingTimeline(x.chat.str())) |tl| if (tl.find(x.msg.str())) |m| {
            m.o.set("poll", j.field(v, "poll") orelse .null) catch {};
        },
        .saved_save => |id| {
            _ = s.panes.pop();
            if (j.obj(v, "chat")) |raw| {
                const c = s.store.putChat(raw) catch return;
                if (!id.isSet()) openChat(s, c.id());
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------------------------
// Root view

pub fn colorsFor(s: *const State, env_dark: bool) theme.Colors {
    const dark = switch (s.prefs.theme) {
        .auto => env_dark,
        .light => false,
        .dark => true,
    };
    var accent = theme.accents[@min(s.prefs.accent, theme.accents.len - 1)];
    if (s.mode == .embed) if (s.embed.app) |a| {
        if (a.s("theme.primary")) |p| if (Color.parseHex(p)) |col| {
            accent = .{ col, col.mix(0.7, Color.white) };
        } else |_| {};
    };
    return theme.colors(dark, accent[0], accent[1]);
}

/// What Back (Android's button, the iOS edge swipe, the browser's) closes first; null lets the
/// system have it (leaving the app).
fn backMsg(s: *const State, phone: bool) ?Msg {
    if (s.phase != .ready) return null;
    if (s.modal != null) return .close_modal;
    if (s.stories.viewer != null) return .{ .stories = .close };
    if (s.viewer != null) return .close_viewer;
    if (s.selecting) return .select_cancel;
    if (s.info.isSet() or s.user_info.isSet()) {
        if (s.group.page != .main and !s.user_info.isSet()) return .{ .group = .{ .page = if (s.group.page == .admins or s.group.page == .banned) .edit else .main } };
        return .close_info;
    }
    if (s.panes.items.len > 0) return .pop_pane;
    if (s.searching) return .{ .toggle_search = false };
    if (phone and s.open_chat.isSet()) return .close_chat;
    if (s.section != .chats) return .{ .nav = .chats };
    return null;
}

pub fn root(s: *const State, ui: *ui_kit.Ui) void {
    const env = ui.env;
    const c = colorsFor(s, env.dark);
    const cx: Cx = .{ .ui = ui, .s = s, .c = c, .phone = env.width <= theme.phone_max, .w = env.width, .h = env.height, .fs = s.prefs.font };
    ui.setBackground(if (cx.phone or s.phase != .ready) c.surface else c.canvas);
    if (backMsg(s, cx.phone)) |m| ui.onBack(m);
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    switch (s.phase) {
        .loading => splash(cx),
        .cannot_reach => notice(cx, icons.wifiOff, t("Cannot reach Reseal"), s.boot_error.get(), true),
        .signed_out => notice(cx, icons.user, t("Sign in to chat"), if (s.boot_error.get().len > 0) s.boot_error.get() else t("Sign in on this website to start chatting."), false),
        .sign_in => signInGate(cx),
        .locked => unlockGate(cx),
        .ready => vlist.shell(cx),
    }
    if (s.phase == .ready) {
        vcall.overlay(cx);
        if (s.viewer != null) @import("viewerx.zig").view(cx);
        if (s.stories.viewer != null) @import("stories.zig").viewer(cx);
    }
    if (s.modal != null) modal(cx);
    if (s.toast.text.get().len > 0) toastView(cx);
    // The connection dropped after it had worked (shell.js connection pill).
    if (s.phase == .ready and s.ws.ever and !s.ws.online and !s.ws.stopped) connectionPill(cx);
    ui.end();
}

pub fn logo(cx: Cx, size: f32) void {
    cx.ui.image(std.fmt.allocPrint(cx.a(), "{s}/icon.svg", .{app.server}) catch "/icon.svg", .{ .width = .{ .px = size }, .height = .{ .px = size } }, zui.key("logo"));
}

fn splash(cx: Cx) void {
    cx.ui.begin(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center }, .{});
    logo(cx, 72);
    cx.ui.end();
}

fn notice(cx: Cx, ic: zui.Icon, title: []const u8, text: []const u8, retry: bool) void {
    const ui = cx.ui;
    ui.begin(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .padding = .xy(24, 28), .background = cx.c.canvas }, .{});
    ui.begin(.{ .max_width = 360, .align_items = .center, .gap = 12 }, .{});
    lockArt(cx, ic);
    ui.text(title, .{ .font_size = 26, .weight = 800, .color = cx.c.text, .text_align = .center });
    ui.text(text, .{ .font_size = 15, .color = cx.c.text_2, .text_align = .center, .line_height = 1.6 });
    if (retry) ui_kit.button(cx, t("Try again"), .boot, .{ .large = true, .block = true });
    ui.end();
    ui.end();
}

fn lockArt(cx: Cx, ic: zui.Icon) void {
    cx.ui.begin(.{ .width = .{ .px = 76 }, .height = .{ .px = 76 }, .radius = 26, .background = cx.c.brand, .align_items = .center, .justify = .center, .align_self = .center }, .{});
    cx.ui.icon(ic, 36, Color.white, .{}, 0);
    cx.ui.end();
}

fn point(cx: Cx, ic: zui.Icon, title: []const u8, text: []const u8) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .gap = 12, .align_items = .start }, .{});
    ui.begin(.{ .width = .{ .px = 36 }, .height = .{ .px = 36 }, .radius = 12, .background = cx.c.accent_soft, .align_items = .center, .justify = .center }, .{});
    ui.icon(ic, 19, cx.c.accent, .{}, 0);
    ui.end();
    ui.begin(.{ .grow = 1, .width = .fill, .gap = 2 }, .{});
    ui.text(title, .{ .font_size = 14, .weight = 650, .color = cx.c.text });
    ui.text(text, .{ .font_size = 14, .color = cx.c.text_2, .line_height = 1.5 });
    ui.end();
    ui.end();
}

/// The art half of the sign-in screen (wide screens): floating bubbles on the brand colours.
fn gateArt(cx: Cx) void {
    const ui = cx.ui;
    ui.begin(.{ .grow = 1.1, .width = .fill, .height = .fill, .background = Color.hex("#1a1640"), .align_items = .center, .justify = .center, .padding = .all(40), .clip = true }, .{});
    ui.begin(.{ .position = .absolute, .inset = .{ .top = -120, .start = -120 }, .width = .{ .px = 520 }, .height = .{ .px = 520 }, .radius = 260, .background = Color.hex("#6c5cff99") }, .{});
    ui.end();
    ui.begin(.{ .position = .absolute, .inset = .{ .bottom = -160, .end = -120 }, .width = .{ .px = 480 }, .height = .{ .px = 480 }, .radius = 240, .background = Color.hex("#4f8cff80") }, .{});
    ui.end();
    ui.begin(.{ .width = .fill, .max_width = 420, .gap = 14 }, .{});
    const bubble = struct {
        fn f(c2: Cx, text: []const u8, small: []const u8, ic: zui.Icon, out: bool) void {
            c2.ui.begin(.{ .align_self = if (out) .end else .start, .max_width = 330, .padding = .xy(16, 12), .radius = 20, .background = if (out) Color.hex("#ffffffeb") else Color.hex("#ffffff29"), .gap = 4 }, .{});
            c2.ui.text(text, .{ .font_size = 15, .color = if (out) Color.hex("#2b2470") else Color.white });
            c2.ui.begin(.{ .direction = .row, .gap = 5, .align_items = .center, .opacity = 0.7 }, .{});
            c2.ui.icon(ic, 13, if (out) Color.hex("#2b2470") else Color.white, .{}, 0);
            c2.ui.text(small, .{ .font_size = 11.5, .color = if (out) Color.hex("#2b2470") else Color.white });
            c2.ui.end();
            c2.ui.end();
        }
    }.f;
    bubble(cx, t("Are we still on for tonight? 🌙"), t("end-to-end encrypted"), icons.lock, false);
    bubble(cx, t("Yes! I booked the table 🎉"), "9:41", icons.checks, true);
    bubble(cx, t("✨ Ask our AI assistant anything"), t("AI built in"), icons.sparkles, false);
    ui.end();
    ui.begin(.{ .position = .absolute, .inset = .{ .start = 40, .end = 40, .bottom = 36 }, .gap = 8 }, .{});
    ui.text(t("Talk freely."), .{ .font_size = 34, .weight = 800, .color = Color.white });
    ui.text(t("Messages, calls and AI in one calm, private place."), .{ .font_size = 15, .color = Color.hex("#ffffffcc"), .max_width = 420 });
    ui.end();
    ui.end();
}

fn gateFrame(cx: Cx, comptime body: fn (Cx) void) void {
    const ui = cx.ui;
    ui.begin(.{ .direction = .row, .width = .fill, .height = .fill, .background = cx.c.canvas }, .{});
    if (!cx.phone) gateArt(cx);
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .background = cx.c.surface }, zui.key("gate"));
    ui.begin(.{ .width = .fill, .min_height = cx.h, .align_items = .center, .justify = .center, .padding = .xy(28, 40) }, .{});
    ui.begin(.{ .width = .fill, .max_width = 400, .gap = 0 }, .{});
    body(cx);
    ui.end();
    ui.end();
    ui.end();
    ui.end();
}

fn signInGate(cx: Cx) void {
    gateFrame(cx, struct {
        fn f(c2: Cx) void {
            const ui = c2.ui;
            ui.begin(.{ .padding = .{ .bottom = 22 } }, .{});
            logo(c2, 64);
            ui.end();
            ui.text(t("Welcome to Reseal"), .{ .font_size = 32, .weight = 800, .color = c2.c.text });
            ui.begin(.{ .padding = .{ .top = 10, .bottom = 26 } }, .{});
            ui.text(t("Sign in with your Wufour account and you're in. Your chats are encrypted on your devices automatically."), .{ .font_size = 15, .color = c2.c.text_2, .line_height = 1.6 });
            ui.end();
            ui.begin(.{ .gap = 14, .padding = .{ .bottom = 28 } }, .{});
            point(c2, icons.lock, t("Private by default"), t("Messages are encrypted on your devices before they leave."));
            point(c2, icons.video, t("Calls that just work"), t("Voice, video and group calls."));
            point(c2, icons.sparkles, t("AI when you want it"), t("Chat with assistants, or build your own."));
            ui.end();
            // Phones: Wufour's sign-in opens inside the app (fx.webAuth); the web goes to /login.
            ui_kit.button(c2, if (app.native_auth) t("Sign in with Wufour") else t("Continue with Wufour"), .sign_in_wufour, .{ .large = true, .block = true });
            ui.begin(.{ .padding = .{ .top = 18 } }, .{});
            ui.text(t("Reseal never sees your password. Signing in happens on Wufour."), .{ .font_size = 12.5, .color = c2.c.text_3, .line_height = 1.5 });
            ui.end();
        }
    }.f);
}

/// Advanced protection on a new device: the passcode or the recovery key.
fn unlockGate(cx: Cx) void {
    const ui = cx.ui;
    const s = cx.s;
    const c = cx.c;
    ui.begin(.{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .padding = .all(24), .background = c.canvas }, .{});
    ui.begin(.{ .width = .fill, .max_width = 420, .padding = .xy(32, 36), .radius = 28, .background = c.surface, .align_items = .center, .gap = 0 }, .{});
    lockArt(cx, icons.shieldCheck);
    ui.begin(.{ .padding = .{ .top = 20, .bottom = 10 } }, .{});
    ui.text(t("Unlock your chats"), .{ .font_size = 32, .weight = 800, .color = c.text, .text_align = .center });
    ui.end();
    ui.begin(.{ .padding = .{ .bottom = 26 } }, .{});
    ui.text(t("You turned on advanced protection, so only your passcode can unlock your messages on a new device."), .{ .font_size = 15, .color = c.text_2, .text_align = .center, .line_height = 1.6 });
    ui.end();
    ui_kit.field(cx, .passcode, .{
        .label = if (s.unlock_recovery) t("Recovery key") else t("Passcode"),
        .placeholder = if (s.unlock_recovery) "XXXX-XXXX-XXXX-…" else t("Your passcode"),
        .mono = s.unlock_recovery,
        .err = if (s.unlock_error.get().len > 0) s.unlock_error.get() else null,
    });
    ui_kit.button(cx, t("Unlock"), .unlock, .{ .large = true, .block = true, .icon = icons.unlock, .busy = s.busy });
    ui.begin(.{ .padding = .{ .top = 14 } }, .{ .on_press = .toggle_recovery });
    ui.text(if (s.unlock_recovery) t("Use my passcode instead") else t("Use my recovery key instead"), .{ .font_size = 14, .weight = 650, .color = c.accent });
    ui.end();
    ui.begin(.{ .padding = .{ .top = 14 } }, .{ .on_press = .start_fresh });
    ui.text(t("Forgot both? Start fresh"), .{ .font_size = 14, .weight = 500, .color = c.text_3 });
    ui.end();
    ui.end();
    ui.end();
}

fn connectionPill(cx: Cx) void {
    const ui = cx.ui;
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 10, .start = 0, .end = 0 }, .align_items = .center }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .padding = .xy(14, 7), .radius = 16, .background = cx.c.toast }, .{});
    ui.spinner(14, Color.white, .{}, zui.key("conn-spin"));
    ui.text(if (app.env.online) t("Connecting…") else t("Waiting for network…"), .{ .font_size = 13.5, .weight = 600, .color = Color.white });
    ui.end();
    ui.end();
}

fn toastView(cx: Cx) void {
    const ui = cx.ui;
    ui.begin(.{ .position = .absolute, .inset = .{ .start = 16, .end = 16, .bottom = if (cx.phone) 96 else 112 }, .align_items = .center }, .{});
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .padding = .xy(18, 12), .min_height = 50, .radius = 16, .background = cx.c.toast, .max_width = 560 }, .{ .on_press = .{ .toast_hide = cx.s.toast.id } });
    ui.icon(if (cx.s.toast.err) icons.alertCircle else icons.info, 20, if (cx.s.toast.err) Color.hex("#ff8a9b") else Color.hex("#a9a0ff"), .{}, 0);
    ui.text(cx.s.toast.text.get(), .{ .font_size = 14.5, .weight = 500, .color = Color.white });
    if (@import("listextras.zig").toastAction(cx.s)) |x| {
        ui.begin(.{ .padding = .xy(10, 6), .radius = 10, .pressed_opacity = 0.7 }, .{ .on_press = x.msg, .key = zui.key("toast-action") });
        ui.text(x.label, .{ .font_size = 14.5, .weight = 750, .color = Color.hex("#a9a0ff") });
        ui.end();
    }
    ui.end();
    ui.end();
}

// ---------------------------------------------------------------------------------------------
// Modals: menus (as sheets), confirmations, passcode forms, recovery key

pub fn sheet(cx: Cx, title: ?[]const u8) void {
    const ui = cx.ui;
    // The backdrop is a sibling of the sheet: nested pressable views would take each other's taps.
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 }, .align_items = .center, .justify = if (cx.phone) .end else .center, .padding = if (cx.phone) .{} else .all(20) }, .{});
    ui.begin(.{ .position = .absolute, .inset = .{ .top = 0, .bottom = 0, .start = 0, .end = 0 }, .background = cx.c.overlay }, .{ .on_press = .close_modal });
    ui.end();
    ui.begin(.{ .width = .fill, .max_width = 440, .max_height = cx.h * 0.88, .background = cx.c.surface, .radius = 24, .padding = .{ .bottom = if (cx.phone) 18 else 8 } }, .{});
    if (title) |tt| {
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .top = 18, .bottom = 6, .start = 24, .end = 14 }, .min_height = 62 }, .{});
        ui.text(tt, .{ .font_size = 20, .weight = 750, .color = cx.c.text, .grow = 1, .width = .fill });
        ui_kit.iconButton(cx, icons.close, .close_modal, .{});
        ui.end();
    }
    ui.beginScroll(.{ .padding = .{ .start = 12, .end = 12, .bottom = 6 } }, zui.key("sheet"));
}

pub fn endSheet(cx: Cx) void {
    cx.ui.end();
    cx.ui.end();
    cx.ui.end();
}

pub fn menuItem(cx: Cx, ic: zui.Icon, label: []const u8, msg: Msg, danger: bool) void {
    const ui = cx.ui;
    const c = cx.c;
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 44, .padding = .xy(12, 6), .radius = 12, .pressed_background = c.hover }, .{ .on_press = msg });
    ui.icon(ic, 19, if (danger) c.danger else c.text_2, .{}, 0);
    ui.text(label, .{ .font_size = 14.5, .weight = 550, .color = if (danger) c.danger else c.text, .grow = 1, .width = .fill });
    ui.end();
}

fn modal(cx: Cx) void {
    const m = cx.s.modal.?;
    switch (m) {
        .menu => |x| vchat.menu(cx, x.kind, x.target, x.item),
        .confirm => |x| confirmView(cx, x.kind, x.target, x.item),
        .recovery_key => vset.recoveryKey(cx),
        .enable_advanced, .disable_advanced, .change_passcode, .new_recovery => vset.passcodeForm(cx, m),
        .fingerprint => vset.fingerprint(cx),
        .safety => |uid| vset.safety(cx, uid.str()),
        .reactions => vchat.reactionsSheet(cx),
        .forward => @import("fwdpick.zig").sheet(cx),
        .join => vchat.joinSheet(cx),
        .compose => |which| vcompose.sheet(cx, which),
        .admin_rights => vgroup.adminRights(cx),
        .invite_new => vgroup.inviteNew(cx),
        .folder_edit => @import("folders.zig").editor(cx),
        .chat_unlock => |x| @import("chatlock.zig").unlockSheet(cx, x.chat, x.purpose),
        .chat_lock_code => |change| @import("chatlock.zig").codeSheet(cx, change),
        .chat_lock_off => @import("chatlock.zig").offSheet(cx),
        .export_options => @import("export.zig").optionsSheet(cx),
        .export_progress => @import("export.zig").progressSheet(cx),
        .model_picker => @import("bots.zig").modelSheet(cx),
        .dev_create => @import("dev.zig").createSheet(cx),
        .dev_secret => @import("dev.zig").secretSheet(cx),
        .dev_agent => @import("dev.zig").agentSheet(cx),
        .dev_payload => @import("dev.zig").payloadSheet(cx),
        .dev_delete => @import("dev.zig").deleteSheet(cx),
        .story_views => @import("stories.zig").viewsSheet(cx),
        .story_menu => @import("stories.zig").menuSheet(cx),
        .story_kind => @import("stories.zig").kindSheet(cx),
        .common_groups => @import("userinfo.zig").commonSheet(cx),
        .poll_voters => @import("pollx.zig").votersSheet(cx),
        .attach_preview => @import("attachx.zig").sheet(cx),
        .story_compose => @import("stories.zig").composer(cx),
        .story_people => @import("stories.zig").peopleSheet(cx),
        .story_list => @import("stories.zig").listSheet(cx),
        .profile_photo_menu => @import("profile.zig").photoMenu(cx),
        .delete_account => @import("profile.zig").deleteSheet(cx),
        .features_tour => @import("profile.zig").tourSheet(cx),
        .seen_by => @import("msgextras.zig").seenBySheet(cx),
        .message_details => @import("msgextras.zig").detailsSheet(cx),
        .pin_message => @import("msgextras.zig").pinSheet(cx),
    }
}

/// Channels and Saved delete messages for everyone, without asking (Reseal-js deleteFlow).
fn deleteForAllAlways(c: *const data.Chat) bool {
    return c.is("channel") or c.is("saved");
}

/// Whether "for everyone" is offered: my own messages, a pair chat, or the right to delete others'.
fn canDeleteForEveryone(s: *const State, c: *const data.Chat, one: Id) bool {
    if (c.is("saved")) return false;
    if (c.is("private") or c.is("bot") or @import("view_chat.zig").can(c, "deleteMessages")) return true;
    const me = s.store.myId();
    const tl = s.store.existingTimeline(c.id()) orelse return false;
    if (one.isSet()) return if (tl.find(one.str())) |m| std.mem.eql(u8, m.authorId(), me) else false;
    for (s.selected.items) |id| {
        const m = tl.find(id.str()) orelse return false;
        if (!std.mem.eql(u8, m.authorId(), me)) return false;
    }
    return true;
}

fn confirmView(cx: Cx, kind: app.ConfirmKind, target: Id, target_item: Id) void {
    const s = cx.s;
    const c = s.store.chat(target.str());
    const name = if (c) |cc| s.store.title(cc) else "";
    var title: []const u8 = "";
    var text: []const u8 = "";
    var action: []const u8 = t("Delete");
    var check: ?[]const u8 = null;
    switch (kind) {
        .logout => {
            title = t("Log out?");
            text = t("Your encryption keys will be removed from this device. You will need your passcode to read your messages when you sign in again.");
            action = t("Log out");
        },
        .start_fresh => {
            title = t("Start fresh?");
            text = t("New keys are created and backed up automatically. People in your chats share them with you again when they come online. Older notes in Saved can no longer be opened.");
            action = t("Start fresh");
        },
        .delete_chat => {
            const pair = if (c) |cc| cc.is("private") or cc.is("bot") else false;
            title = if (pair) t("Delete chat?") else if (c != null and c.?.is("channel")) t("Delete channel?") else t("Delete group?");
            text = if (pair) fmt.tf("Delete the chat with {name}?", .{ .name = name }) else t("This will delete it for all members. This cannot be undone.");
            if (c != null and c.?.is("private")) check = fmt.tf("Also delete for {name}", .{ .name = name });
        },
        .delete_saved => {
            title = fmt.tf("Delete {name}?", .{ .name = name });
            text = t("This saved chat and everything in it will be deleted. This cannot be undone.");
        },
        .leave_chat => {
            title = if (c != null and c.?.is("channel")) t("Leave channel?") else t("Leave group?");
            text = fmt.tf("Are you sure you want to leave {name}?", .{ .name = name });
            action = t("Leave");
        },
        .clear_history => {
            action = t("Clear");
            if (c != null and c.?.is("saved")) {
                title = if (c.?.o.b("primary")) t("Clear Saved Messages?") else fmt.tf("Clear {name}?", .{ .name = name });
                text = t("All messages here will be deleted.");
            } else {
                title = t("Clear history?");
                text = t("Messages will be removed from this chat.");
                if (c) |cc| {
                    if (cc.is("private")) check = fmt.tf("Also clear for {name}", .{ .name = name }) else if (cc.is("bot") or std.mem.eql(u8, cc.role(), "owner")) check = t("Clear for everyone");
                }
            }
        },
        .delete_messages => {
            const n = if (target_item.isSet()) 1 else s.selected.items.len;
            title = fmt.tn(tmp(), @intCast(n), "Delete message?", "Delete {n} messages?");
            const all = if (c) |cc| deleteForAllAlways(cc) else true;
            text = if (all) t("This cannot be undone.") else t("Delete for yourself, or for everyone in the chat.");
            if (c) |cc| if (!all and canDeleteForEveryone(s, cc, target_item)) {
                check = if (cc.is("private")) fmt.tf("Also delete for {name}", .{ .name = name }) else t("Delete for everyone");
            };
        },
        .block => {
            title = fmt.tf("Block {name}?", .{ .name = name });
            text = t("They will not be able to message or call you.");
            action = t("Block");
        },
        .unblock => {
            title = t("Unblock");
            action = t("Unblock");
        },
        .remove_contact => {
            title = t("Remove contact");
            action = t("Remove");
        },
        .ban_member => {
            const who = if (s.store.user(target_item.str())) |u| s.store.userName(u) else "";
            title = fmt.tf("Ban {name}?", .{ .name = who });
            text = t("They will be removed and cannot rejoin.");
            action = t("Ban");
        },
        .delete_story => {
            title = t("Delete this glimpse?");
        },
        .dev_roll => {
            title = t("Roll the secret key?");
            text = t("The current key stops working immediately.");
            action = t("Roll key");
        },
        .transfer_owner => {
            const who = if (s.store.user(target_item.str())) |u| s.store.userName(u) else "";
            title = t("Transfer ownership?");
            text = fmt.tf("{name} will become the owner. You will stay an admin.", .{ .name = who });
            action = t("Transfer");
        },
    }
    const ui = cx.ui;
    sheet(cx, title);
    ui.begin(.{ .padding = .xy(12, 6), .gap = 12 }, .{});
    if (text.len > 0) ui.text(text, .{ .font_size = 15, .color = cx.c.text_2, .line_height = 1.6 });
    if (check) |label| {
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 44 }, .{ .on_press = .confirm_check });
        ui.begin(.{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 8, .border_width = if (s.confirm_check) 0 else 1.5, .border_color = cx.c.border_strong, .background = if (s.confirm_check) cx.c.brand else null, .align_items = .center, .justify = .center }, .{});
        if (s.confirm_check) ui.icon(icons.check, 14, Color.white, .{}, 0);
        ui.end();
        ui.text(label, .{ .font_size = 15, .color = cx.c.text });
        ui.end();
    }
    ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .top = 8, .bottom = 8 } }, .{});
    ui_kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    ui_kit.button(cx, action, .confirm, .{ .kind = .danger });
    ui.end();
    ui.end();
    endSheet(cx);
}
