//! Reseal client: the same code for the web, Android and iOS. A port of Reseal-js's web app
//! (public/js): sign-in, end-to-end encrypted chats and groups, the chat list, search, settings,
//! calls (signalling and screens; media through rtc.zig), and the embedded widget (/embed) that
//! other sites (Taazur) load with /sdk/reseal.js.
//!
//! The app talks to the unchanged Reseal server API (/api/...) and its WebSocket (/ws). Every
//! request carries a tag naming the operation it belongs to (`Op`); the answer comes back as
//! `Msg.http` and continues that operation, which is how the web app's async functions become
//! zui's message loop.

const std = @import("std");
const zui = @import("zui");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
const keys = @import("keys.zig");
const sync = @import("sync.zig");
const send = @import("send.zig");
const media = @import("media.zig");
const calls = @import("calls.zig");
const views = @import("views.zig");
const crypto = @import("crypto.zig");
const fmt = @import("fmt.zig");
pub const compose = @import("compose.zig");
pub const group = @import("group.zig");
pub const folders = @import("folders.zig");
pub const chatlock = @import("chatlock.zig");
pub const exporter = @import("export.zig");
pub const bots = @import("bots.zig");
pub const dev = @import("dev.zig");
pub const stories = @import("stories.zig");
pub const voice = @import("voice.zig");
pub const profile = @import("profile.zig");
pub const drafts = @import("drafts.zig");
pub const extras = @import("msgextras.zig");
pub const chatmore = @import("chatmore.zig");
pub const fwdpick = @import("fwdpick.zig");
pub const listextras = @import("listextras.zig");
pub const userinfo = @import("userinfo.zig");
pub const sharedmedia = @import("sharedmedia.zig");
const push_mod = @import("push.zig");
/// The calls engine on Android and iOS (the web uses the browser's WebRTC).
pub const rtc = @import("reseal_rtc").zui_engine;

pub const panic = zui.panic;
pub const boot: Msg = .boot;

pub const global_locale = @embedFile("locales/global.json");
pub const locales: []const zui.i18n.Locale = &.{
    .{ .lang = "ar", .json = @embedFile("locales/ar.json") },
};

comptime {
    zui.exportApp(@This());
}

pub const Id = data.Id;
pub const gpa = zui.allocator;
const t = zui.i18n.t;

/// The Reseal server: the page's own origin on the web, the build's -Dserver on phones.
pub const server = if (zui.platform == .web) "" else @import("app_config").server;
/// Wufour, where the phone apps sign in (-Dauth).
pub const auth_host = if (zui.platform == .web) "" else @import("app_config").auth;
pub const native_auth = zui.platform != .web;

// ---------------------------------------------------------------------------------------------
// Per-update context: the effects handle and scratch memory (freed after each update)

pub var fx: zui.Fx(Msg) = undefined;
pub var env: zui.Env = .{};
var tmp_state: std.heap.ArenaAllocator = .init(zui.allocator);
pub fn tmp() std.mem.Allocator {
    return tmp_state.allocator();
}

// ---------------------------------------------------------------------------------------------
// Text the person types

pub const Text = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn get(x: *const Text) []const u8 {
        return x.buf.items;
    }
    pub fn set(x: *Text, s: []const u8) void {
        x.buf.clearRetainingCapacity();
        x.buf.appendSlice(gpa, s) catch {};
    }
    pub fn clear(x: *Text) void {
        x.buf.clearRetainingCapacity();
    }
    pub fn trimmed(x: *const Text) []const u8 {
        return std.mem.trim(u8, x.buf.items, " \t\r\n");
    }
};

pub const Field = enum {
    search,
    composer,
    login_email,
    login_password,
    passcode,
    passcode_2,
    passcode_3,
    profile_name,
    profile_bio,
    profile_username,
    group_name,
    group_about,
    picker,
    contacts,
    saved_search,
    chat_search,
    saved_title,
    saved_about,
    poll_question,
    poll_explanation,
    poll_o0,
    poll_o1,
    poll_o2,
    poll_o3,
    poll_o4,
    poll_o5,
    poll_o6,
    poll_o7,
    poll_o8,
    poll_o9,
    poll_o10,
    poll_o11,
    schedule_at,
    emoji_search,
    info_title,
    info_about,
    chat_username,
    admin_title,
    invite_name,
    folder_name,
    lock_code,
    lock_code_2,
    lock_current,
    export_from,
    export_to,
    bot_name,
    bot_username,
    bot_description,
    bot_prompt,
    bot_greeting,
    bot_starters,
    bot_key,
    bot_max_tokens,
    bot_context,
    model_search,
    dev_app_name,
    forward_search,
    dev_origins,
    dev_storage_url,
    dev_webhook_url,
    dev_name,
    dev_description,
    dev_primary,
    dev_title,
    dev_subtitle,
    dev_launcher_label,
    dev_welcome,
    dev_placeholder,
    dev_agent_id,
    dev_agent_name,
    dev_delete_confirm,
    story_text,
    story_caption,
    story_reply,
    delete_confirm,
};

pub fn onField(comptime f: Field) *const fn ([]const u8) Msg {
    return struct {
        fn h(s: []const u8) Msg {
            return .{ .typed = .{ .field = f, .text = s } };
        }
    }.h;
}

// ---------------------------------------------------------------------------------------------
// Messages

pub const Section = enum { chats, calls, saved, contacts, settings };

pub const Pane = union(enum) {
    archive,
    profile,
    notifications,
    privacy,
    appearance,
    language,
    blocked,
    /// Pick people: for a new message, a new group, adding members or contacts, blocking.
    picker: Picker,
    group_details: enum { group, channel },
    saved_edit: Id,
    folders,
    chat_lock,
    bots,
    bot_edit,
    dev,
    dev_app,
};

pub const Picker = enum { new_message, new_group, add_contact, add_members, block };

pub const MenuKind = enum { compose, chat_header, chat_row, mute, message, embed, call_devices, member, slow_mode, reactions_setting, folder_pick, ttl, chip };

pub const ConfirmKind = enum { logout, delete_chat, leave_chat, clear_history, delete_messages, start_fresh, block, unblock, delete_saved, remove_contact, ban_member, transfer_owner, dev_roll, delete_story };

pub const Modal = union(enum) {
    menu: struct { kind: MenuKind, target: Id = .{}, item: Id = .{} },
    confirm: struct { kind: ConfirmKind, target: Id = .{}, item: Id = .{} },
    recovery_key: Id, // unused id; the key itself is in State.recovery_shown
    enable_advanced,
    disable_advanced,
    change_passcode,
    new_recovery,
    fingerprint,
    safety: Id,
    reactions: Id,
    join: Id,
    forward: Id,
    compose: compose.Sheet,
    admin_rights: Id,
    invite_new,
    folder_edit,
    chat_unlock: struct { chat: Id, purpose: chatlock.Purpose },
    chat_lock_code: bool,
    chat_lock_off,
    export_options,
    export_progress,
    model_picker,
    dev_create,
    dev_secret,
    dev_agent,
    dev_payload,
    dev_delete,
    story_views,
    story_menu,
    story_kind,
    common_groups,
    story_compose,
    story_people,
    story_list,
    profile_photo_menu,
    delete_account,
    features_tour,
    seen_by,
    message_details,
    pin_message,
};

pub const Msg = union(enum) {
    boot,
    http: zui.Response,
    socket: zui.SocketEvent,
    host: []const u8,
    device: zui.DeviceEvent,
    picked: zui.File,
    reconnect: u32,
    tick,
    typing_check,
    read_flush: Id,
    fulfill_due,
    /// An answer from zui.keys (a signature, an unwrapped chat key).
    key: zui.keys.Result,
    toast_hide: u32,
    embed_init_timeout,
    send_typing_done,
    frame,

    typed: struct { field: Field, text: []const u8 },
    submit: Field,

    // Sign-in and keys
    sign_in_wufour,
    login,
    unlock,
    toggle_recovery,
    start_fresh,

    // Navigation
    nav: Section,
    open_chat: Id,
    close_chat,
    push_pane: Pane,
    pop_pane,
    open_info: Id,
    close_info,
    open_user: Id,
    menu: Modal,
    close_modal,
    confirm,
    confirm_check,
    toggle_search: bool,
    filter: Filter,
    open_archive,

    // Chat list and chat actions
    chat_action: struct { what: ChatAction, chat: Id },
    mute_for: struct { chat: Id, hours: i64 },
    load_older,
    reached_top,
    scrolled,
    jump_latest,
    send_text,
    attach,
    compose: compose.Act,
    group: group.Act,
    folder: folders.Act,
    chat_lock: chatlock.Act,
    export_chat: exporter.Act,
    bots: bots.Act,
    dev: dev.Act,
    stories: stories.Act,
    story_photo: zui.File,
    story_play: zui.PlayEvent,
    voice: voice.Act,
    profile: profile.Act,
    profile_photo: zui.File,
    draft_due: struct { chat: Id, seq: u32 },
    extras: extras.Act,
    chat_more: chatmore.Act,
    fwd_pick: fwdpick.Act,
    list_extras: listextras.Act,
    user_info: userinfo.Act,
    shared: sharedmedia.Act,
    scroll_end: bool,
    record_event: zui.RecordEvent,
    play_event: zui.PlayEvent,
    located: zui.Location,
    cancel_reply,
    message_tap: Id,
    /// A link in a message's text (rich.zig): the message and the byte the link starts at.
    rich_link: struct { msg: Id, at: u32 },
    select_cancel,
    select_forward,
    select_delete,
    select_copy,
    message_action: struct { what: MessageAction, msg: Id },
    react: struct { msg: Id, emoji: u8 },
    vote: struct { msg: Id, option: u8 },
    retry_send: u32,
    cancel_send: u32,
    open_media: struct { msg: Id, index: u8 },
    forward_to: Id,
    close_viewer,
    download: struct { msg: Id, index: u8 },
    pick_user: Id,
    unpick_user: Id,
    picker_done,
    create_group,
    toggle_encrypted,
    join_chat: Id,
    join_invite,
    start_global: Id,
    open_wufour: Id,

    // Settings
    save_profile,
    save_saved,
    set_theme: Theme,
    set_accent: u8,
    set_font: i8,
    set_lang: Lang,
    toggle_pref: Pref,
    set_privacy: struct { key: PrivacyKey, value: PrivacyValue },
    toggle_read_receipts,
    advanced_submit,
    copy_text: Id,
    copy_recovery,

    // Calls
    call: calls.Action,
    media: zui.MediaEvent,
    call_event: struct { kind: zui.CallEvent.Kind, id: Id },
    peer: zui.PeerEvent,

    // Embed
    embed_open: EmbedTarget,
    /// Push: a token, a push's data (push.zig).
    push: push_mod.Event,
};

pub const Filter = union(enum) { all, unread, people, groups, channels, ai, folder: Id };
pub const ChatAction = enum { export_chat, lock, unlock, add_to_folder, pin, unpin, archive, unarchive, mute, unmute, mark_read, mark_unread, delete, leave, clear, block, unblock, add_contact, info, call_voice, call_video, saved_edit, search, show_safety };
pub const MessageAction = enum { reply, edit, copy, pin, unpin, delete, delete_everyone, save, select, details, forward, retract_vote, close_poll, open_map, open_link, reveal };
pub const Theme = enum { auto, light, dark };
pub const Lang = enum { en, ar };
pub const Pref = enum { notifications, previews, sounds, send_with_enter, animations, link_previews, square_bubbles };
pub const PrivacyKey = enum { lastSeen, avatar, calls, groups, forwards };
pub const PrivacyValue = enum { everyone, contacts, nobody };
pub const EmbedTarget = enum { bot, support };

fn onHttp(r: zui.Response) Msg {
    return .{ .http = r };
}

fn onSocket(e: zui.SocketEvent) Msg {
    return .{ .socket = e };
}

/// The phone's call screen: answered, declined or hung up there (Bluetooth, the car...).
pub fn callEvent(e: zui.CallEvent) ?Msg {
    return .{ .call_event = .{ .kind = e.kind, .id = Id.of(e.id) } };
}

/// Push (push.zig): a call rings the phone at once, also when the app was not running.
pub const pushToken = push_mod.pushToken;
pub const pushMessage = push_mod.pushMessage;

/// The device came online or went offline, or the app was shown or hidden.
pub fn deviceEvent(e: zui.DeviceEvent) ?Msg {
    return .{ .device = e };
}

/// Messages from the page around the app (web shell, embedding site).
pub fn hostMessage(json: []const u8) ?Msg {
    return .{ .host = json };
}

// ---------------------------------------------------------------------------------------------
// State

pub const Phase = enum { loading, cannot_reach, sign_in, login, locked, ready, signed_out };

pub const Prefs = struct {
    theme: Theme = .auto,
    accent: u8 = 0,
    font: f32 = 15,
    notifications: bool = true,
    previews: bool = true,
    sounds: bool = true,
    send_with_enter: bool = true,
    link_previews: bool = true,
    square_bubbles: bool = false,
    animations: bool = true,
};

pub const Toast = struct { text: Text = .{}, id: u32 = 0, err: bool = false };

pub const Embed = struct {
    pk: Text = .{},
    app: ?*data.Obj = null,
    options: ?*data.Obj = null,
    host_ready: bool = false,
    init_done: bool = false,
    token_waiting: bool = false,
    unread_sent: i64 = -1,
};

pub const State = struct {
    store: data.Store = .{},
    phase: Phase = .loading,
    mode: enum { app, embed } = .app,
    boot_error: Text = .{},
    login_error: Text = .{},
    unlock_error: Text = .{},
    unlock_recovery: bool = false,
    busy: bool = false,
    /// Phones (and the widget): the bearer token sent on every request and the socket URL.
    bearer: Text = .{},
    ops: std.AutoHashMapUnmanaged(u32, Op) = .empty,
    next_op: u32 = 1,

    ws: Ws = .{},
    keys: keys.Keys = .{},
    out: send.Outbox = .{},
    files: media.Cache = .{},
    call: calls.CallState = .{},

    // Screens
    section: Section = .chats,
    panes: std.ArrayList(Pane) = .empty,
    open_chat: Id = .{},
    info: Id = .{},
    user_info: Id = .{},
    modal: ?Modal = null,
    confirm_check: bool = false,
    toast: Toast = .{},
    toast_seq: u32 = 0,
    fields: std.EnumArray(Field, Text) = .initFill(.{}),
    filter: Filter = .all,
    searching: bool = false,
    search_seq: u32 = 0,
    search: ?*data.Obj = null,
    msg_search: ?*data.Obj = null,
    reply_to: Id = .{},
    editing: Id = .{},
    picked: std.ArrayList(Id) = .empty,
    picker_results: ?*data.Obj = null,
    new_group_encrypted: bool = true,
    contacts: ?*data.Obj = null,
    calls_list: ?*data.Obj = null,
    blocked: ?*data.Obj = null,
    members: ?*data.Obj = null,
    members_chat: Id = .{},
    reactions_detail: ?*data.Obj = null,
    viewer: ?struct { msg: Id, index: u8 } = null,
    recovery_shown: Text = .{},
    prefs: Prefs = .{},
    lang: Lang = .en,
    /// The page is shown (web: document visible and focused).
    visible: bool = true,
    first_unread: i64 = 0,
    show_count: usize = 60,
    last_typing_sent: i64 = 0,
    read_pending: std.ArrayList(struct { chat: Id, seq: i64 }) = .empty,
    embed: Embed = .{},
    widget_sig: u64 = 0,
    /// Bumped when a scheduled message was accepted (the scheduled list reloads).
    scheduled_count: u32 = 0,
    compose: compose.Compose = .{},
    group: group.Group = .{},
    folder: folders.Editor = .{},
    lock: chatlock.Lock = .{},
    exporter: exporter.Export = .{},
    bots: bots.Bots = .{},
    dev: dev.Dev = .{},
    stories: stories.Stories = .{},
    voice: voice.Voice = .{},
    profile: profile.Profile = .{},
    drafts: drafts.Drafts = .{},
    extras: extras.Extras = .{},
    /// Selection mode in the open chat (forward or delete several).
    selecting: bool = false,
    selected: std.ArrayList(Id) = .empty,
    fwd: fwdpick.Pick = .{},
    listx: listextras.ListExtras = .{},
    common: ?*data.Obj = null,
    shared: sharedmedia.Shared = .{},
    /// Messages whose spoilers were shown.
    revealed: std.ArrayList(Id) = .empty,
    /// Opened at /c/<id> or /@name: the chat to show once the list is in.
    pending_open: Id = .{},
    pending_username: Id = .{},
    pending_join: Id = .{},
    invite_code: Id = .{},
    /// The invite being looked at (GET /invites/<code>).
    invite: ?*data.Obj = null,
    call_ticking: bool = false,
    fast_clock: bool = false,

    pub fn isSelected(s: *const State, id: []const u8) bool {
        for (s.selected.items) |x| if (x.eql(id)) return true;
        return false;
    }

    pub fn isRevealed(s: *const State, id: []const u8) bool {
        for (s.revealed.items) |x| if (x.eql(id)) return true;
        return false;
    }
};

pub fn init() State {
    return .{};
}

// ---------------------------------------------------------------------------------------------
// Operations in flight

pub const LoadMode = enum { latest, older, newer, around, catch_up };
pub const MessagesOp = struct { chat: Id, mode: LoadMode, seq: i64 = 0 };

pub const Op = union(enum) {
    config,
    me,
    chats,
    folders,
    login,
    keys_setup_auto: struct { id: *crypto.Identity },
    keys_restore,
    keys_backup_unlock,
    keys_enable_advanced,
    keys_protection,
    keys_backup_for: enum { disable, change, recovery },
    keys_backup_put,
    keys_requests,
    keys_lookup_fulfill: struct { batch: u32 },
    chat_keys: Id,
    key_members: struct { chat: Id, epoch: i64 },
    keys_post_rotate: struct { chat: Id, epoch: i64, raw: [32]u8 },
    keys_post_share,
    chat_refresh: Id,
    chat_refresh_conflict: Id,
    chat_ensure: Id,
    messages: MessagesOp,
    message_one: struct { chat: Id, msg: Id },
    send_message: struct { chat: Id, local: u32 },
    edit_message: struct { chat: Id, msg: Id },
    delete_messages: Id,
    react: struct { chat: Id, msg: Id },
    vote: struct { chat: Id, msg: Id },
    pin,
    read: Id,
    state_set: Id,
    users_lookup,
    user_refresh: Id,
    search: u32,
    msg_search: u32,
    picker_search: u32,
    open_private,
    open_username,
    invite,
    invite_join,
    open_wufour,
    create_group,
    contacts,
    contact_add,
    contact_remove,
    calls_list,
    blocked,
    block,
    unblock,
    members: Id,
    reactions: Id,
    profile_save,
    privacy,
    leave: Id,
    delete_chat: Id,
    clear: Id,
    join: Id,
    upload_create: struct { local: u32, file: u32 },
    upload_chunk: struct { local: u32, file: u32, index: u32 },
    upload_complete: struct { local: u32, file: u32 },
    media_info: struct { media: Id },
    media_chunk: struct { media: Id, index: u32 },
    embed_config,
    embed_guest,
    embed_target: EmbedTarget,
    embed_team,
    saved_save: Id,
    link_preview: u32,
    group_requests: Id,
    group_list: group.Page,
    group_list_reload: group.Page,
    group_changed: Id,
    chat_patch: Id,
    invite_created,
    folders_changed,
    lock_verify: struct { chat: Id, purpose: chatlock.Purpose },
    lock_code_saved: bool,
    lock_off,
    export_page: u32,
    export_info: u32,
    export_chunk: struct { seq: u32, index: u32 },
    export_plain: u32,
    bots_mine,
    bots_discover,
    bots_models,
    bots_saved,
    bots_deleted,
    dev_apps,
    dev_app,
    dev_created,
    dev_secret_rolled,
    dev_patched,
    dev_users,
    dev_teams,
    dev_deliveries,
    dev_bots,
    dev_tab_changed,
    dev_agent_added,
    dev_storage_tested,
    dev_webhook_tested,
    dev_signing_secret,
    dev_deleted,
    stories_feed,
    stories_list,
    stories_audience,
    stories_views,
    stories_upload_create,
    stories_upload_chunk: u32,
    stories_upload_complete,
    stories_posted,
    stories_pinned: bool,
    stories_deleted,
    stories_reply_chat,
    profile_upload_create,
    profile_upload_chunk: u32,
    profile_upload_complete,
    profile_saved_photo,
    username_check: u32,
    account_deleted,
    draft_saved: Id,
    seen_by,
    jump_lookup,
    handoff,
    common_groups,
    shared: u32,
    scheduled_list,
    scheduled_changed,
    ignore,
};

/// An API request (path after /api). The answer continues `op`.
pub fn api(s: *State, method: zui.Method, path: []const u8, body: ?[]const u8, op: Op) void {
    request(s, method, path, body, "application/json", op);
}

pub fn request(s: *State, method: zui.Method, path: []const u8, body: ?[]const u8, content_type: []const u8, op: Op) void {
    const tag = s.next_op;
    s.next_op +%= 1;
    if (s.next_op == 0) s.next_op = 1;
    s.ops.put(gpa, tag, op) catch return;
    const a = tmp();
    const url = std.fmt.allocPrint(a, "{s}/api{s}", .{ server, path }) catch return;
    var headers: std.ArrayList([2][]const u8) = .empty;
    headers.append(a, .{ "X-Reseal-Client", if (zui.platform == .web) "web" else "app" }) catch {};
    if (s.bearer.get().len > 0) headers.append(a, .{ "Authorization", std.fmt.allocPrint(a, "Bearer {s}", .{s.bearer.get()}) catch "" }) catch {};
    fx.fetch(.{ .url = url, .method = method, .body = body orelse "", .content_type = content_type, .headers = headers.items, .tag = tag }, onHttp);
}

/// A request for a whole address (a signed file link), not under /api.
pub fn fetchRaw(s: *State, url: []const u8, op: Op) void {
    const tag = s.next_op;
    s.next_op +%= 1;
    if (s.next_op == 0) s.next_op = 1;
    s.ops.put(gpa, tag, op) catch return;
    const a = tmp();
    var headers: std.ArrayList([2][]const u8) = .empty;
    if (s.bearer.get().len > 0) headers.append(a, .{ "Authorization", std.fmt.allocPrint(a, "Bearer {s}", .{s.bearer.get()}) catch "" }) catch {};
    fx.fetch(.{ .url = url, .method = .GET, .headers = headers.items, .tag = tag }, onHttp);
}

/// The error a failed answer carries ({error:{code,message}}).
pub const ApiError = struct { status: u16, code: []const u8, message: []const u8 };

pub fn apiError(r: zui.Response) ApiError {
    const v = j.parse(tmp(), r.body);
    const msg = j.str(v, "error.message") orelse if (r.status == 0) t("Could not reach Reseal. Check your connection.") else std.fmt.allocPrint(tmp(), "Request failed ({d})", .{r.status}) catch "";
    return .{ .status = r.status, .code = j.str(v, "error.code") orelse if (r.status == 0) "network" else "", .message = msg };
}

// ---------------------------------------------------------------------------------------------
// Update

pub fn update(s: *State, msg: Msg, e: zui.Env, f: zui.Fx(Msg)) void {
    fx = f;
    env = e;
    _ = tmp_state.reset(.retain_capacity);
    handle(s, msg);
    // Batched work collected while handling: user lookups, the home-screen widget.
    keys.flushLookups(s);
    @import("view_chat.zig").wantMedia(s);
    sharedmedia.after(s);
    // The call screen's clock: once a second while a call is on. The web's clock comes from the
    // shell, which then sends it every second.
    const calling = s.call.status == .active;
    if (zui.platform == .web) {
        if (calling != s.fast_clock) {
            s.fast_clock = calling;
            post(if (calling) "{\"t\":\"fastclock\",\"on\":true}" else "{\"t\":\"fastclock\",\"on\":false}");
        }
    } else if (calling and !s.call_ticking) {
        s.call_ticking = true;
        fx.after(1000, .frame);
    }
    updateWidget(s);
    // The page around the widget shows the unread count on its button (embed.js).
    if (s.mode == .embed and s.phase == .ready) {
        const n = s.store.totals().unread;
        if (n != s.embed.unread_sent) {
            s.embed.unread_sent = n;
            post(std.fmt.allocPrint(tmp(), "{{\"type\":\"reseal:unread\",\"count\":{d}}}", .{n}) catch return);
        }
    }
}

fn handle(s: *State, msg: Msg) void {
    switch (msg) {
        .boot => start(s),
        .http => |r| onAnswer(s, r),
        .picked => |f| send.onPicked(s, f),
        .device => |e| switch (e) {
            .visible => setVisible(s, true),
            .hidden => setVisible(s, false),
            .online => if (s.ws.socket == 0 and !s.ws.stopped and s.phase == .ready) connect(s),
            .offline => {},
        },
        .socket => |ev| onSocketEvent(s, ev),
        .host => |json| onHost(s, json),
        .push => |e| push_mod.update(s, e),
        .reconnect => |attempt| if (attempt == s.ws.attempt and s.ws.socket == 0 and !s.ws.stopped) connect(s),
        .tick => {
            fx.after(30_000, .tick);
            sync.expireTyping(s);
        },
        .typing_check => sync.expireTyping(s),
        .read_flush => |chat| sync.flushRead(s, chat),
        .fulfill_due => keys.fulfillDue(s),
        .key => |r| if (!stories.onKey(s, r)) keys.onKey(s, r),
        .story_photo => |f| stories.onPicked(s, f),
        .story_play => |e| stories.onPlayEvent(s, e),
        .voice => |a| voice.act(s, a),
        .profile => |a| profile.act(s, a),
        .profile_photo => |f| profile.onPicked(s, f),
        .draft_due => |x| drafts.due(s, x.chat, x.seq),
        .extras => |a| extras.act(s, a),
        .chat_more => |a| chatmore.act(s, a),
        .fwd_pick => |a| fwdpick.act(s, a),
        .list_extras => |a| listextras.act(s, a),
        .user_info => |a| userinfo.act(s, a),
        .shared => |a| sharedmedia.act(s, a),
        .scroll_end => |at| extras.onScroll(s, at),
        .record_event => |e| voice.onRecordEvent(s, e),
        .play_event => |e| voice.onPlayEvent(s, e),
        .toast_hide => |id| if (id == s.toast.id) s.toast.text.clear(),
        .embed_init_timeout => embedInitDone(s, null),
        .send_typing_done => {},
        // The call screen's clock: a redraw every second while a call is on.
        .frame => s.call_ticking = false,
        .typed => |ty| onTyped(s, ty.field, ty.text),
        .submit => |field| onSubmit(s, field),
        .sign_in_wufour => signInWufour(s),
        .login => login(s),
        .unlock => keys.unlockSubmit(s),
        .toggle_recovery => {
            s.unlock_recovery = !s.unlock_recovery;
            s.fields.getPtr(.passcode).clear();
            s.unlock_error.clear();
        },
        .start_fresh => s.modal = .{ .confirm = .{ .kind = .start_fresh } },
        .call => |a| {
            if (a != .mute and a != .camera and a != .screen and a != .switch_camera) s.modal = null;
            calls.act(s, a);
        },
        .media => |ev| calls.onMediaEvent(s, ev),
        .call_event => |ev| calls.onSystem(s, ev.kind, ev.id),
        .peer => |ev| calls.onPeerEvent(s, ev),
        else => views.onUi(s, msg),
    }
}

pub fn toast(s: *State, text: []const u8) void {
    s.toast.text.set(text);
    s.toast.err = false;
    s.toast_seq += 1;
    s.toast.id = s.toast_seq;
    fx.after(4000, .{ .toast_hide = s.toast.id });
}

pub fn toastError(s: *State, text: []const u8) void {
    toast(s, text);
    s.toast.err = true;
}

fn onTyped(s: *State, field: Field, text: []const u8) void {
    s.fields.getPtr(field).set(text);
    switch (field) {
        .search => views.runSearch(s),
        .picker => views.runPickerSearch(s),
        .profile_username => profile.usernameTyped(s),
        .composer => {
            sync.typing(s);
            compose.typed(s);
            drafts.typed(s);
        },
        .chat_search => views.runChatSearch(s),
        else => {},
    }
}

fn onSubmit(s: *State, field: Field) void {
    switch (field) {
        .composer => if (s.prefs.send_with_enter) views.onUi(s, .send_text),
        .login_email, .login_password => login(s),
        .passcode => if (s.phase == .locked) keys.unlockSubmit(s),
        else => {},
    }
}

// ---------------------------------------------------------------------------------------------
// Start: settings, the signed-in account, encryption keys

fn start(s: *State) void {
    loadPrefs(s);
    fx.after(30_000, .tick);
    const link = env.link;
    if (std.mem.startsWith(u8, link, "/embed")) {
        s.mode = .embed;
        const q = if (std.mem.indexOfScalar(u8, link, '?')) |i| link[i + 1 ..] else "";
        s.embed.pk.set(j.queryParam(tmp(), q, "pk") orelse "");
        api(s, .GET, std.fmt.allocPrint(tmp(), "/embed/config?pk={s}", .{j.urlEncode(tmp(), s.embed.pk.get()) catch ""}) catch return, null, .embed_config);
        return;
    }
    // Addresses: /c/<chat id>, /@username (router.js).
    const path_only = link[0 .. std.mem.indexOfAny(u8, link, "?#") orelse link.len];
    if (std.mem.startsWith(u8, path_only, "/c/") and path_only.len >= 27) s.pending_open = Id.of(path_only[3..27]);
    if (std.mem.startsWith(u8, path_only, "/join/") and path_only.len > 6) s.pending_join = Id.of(std.mem.trimEnd(u8, path_only[6..], "/"));
    if (std.mem.startsWith(u8, path_only, "/@") and path_only.len > 2) s.pending_username = Id.of(std.mem.trimEnd(u8, path_only[2..], "/"));
    if (native_auth) {
        const token = zui.storage.get(tmp(), "token", .{ .secure = true }) orelse {
            s.phase = .login;
            return;
        };
        s.bearer.set(token);
    }
    api(s, .GET, "/config", null, .config);
}

pub fn loadPrefs(s: *State) void {
    const raw = zui.storage.get(tmp(), "prefs", .{}) orelse "";
    if (raw.len > 0) {
        if (std.json.parseFromSliceLeaky(Prefs, tmp(), raw, .{ .ignore_unknown_fields = true })) |p| s.prefs = p else |_| {}
    }
    const lang = zui.storage.get(tmp(), "lang", .{}) orelse zui.i18n.language();
    setLang(s, if (std.mem.startsWith(u8, lang, "ar")) .ar else .en);
}

pub fn savePrefs(s: *State) void {
    const text = j.stringify(tmp(), s.prefs) catch return;
    zui.storage.set("prefs", text, .{});
}

pub fn setLang(s: *State, lang: Lang) void {
    s.lang = lang;
    zui.i18n.setLanguage(@tagName(lang));
}

fn signInWufour(_: *State) void {
    // The server's /login sends people to Wufour and back with the cookie set.
    const next = if (env.link.len > 0) env.link else "/";
    fx.openUrl(std.fmt.allocPrint(tmp(), "/login?next={s}", .{j.urlEncode(tmp(), next) catch "/"}) catch "/login", false);
}

/// Phones: email and password to Wufour's /api/auth/login, which answers {success, token}.
fn login(s: *State) void {
    const email = s.fields.get(.login_email).trimmed();
    const password = s.fields.get(.login_password).get();
    if (email.len == 0 or password.len == 0) {
        s.login_error.set(t("All fields are required"));
        return;
    }
    s.login_error.clear();
    s.busy = true;
    const body = std.fmt.allocPrint(tmp(), "{{\"email\":{s},\"password\":{s}}}", .{ j.quote(tmp(), email) catch return, j.quote(tmp(), password) catch return }) catch return;
    const tag = s.next_op;
    s.next_op +%= 1;
    s.ops.put(gpa, tag, .login) catch return;
    fx.fetch(.{ .url = std.fmt.allocPrint(tmp(), "{s}/api/auth/login", .{auth_host}) catch return, .method = .POST, .body = body, .tag = tag }, onHttp);
}

fn onLogin(s: *State, r: zui.Response) void {
    s.busy = false;
    const v = j.parse(tmp(), r.body);
    const token = j.str(v, "token");
    if (r.ok() and j.truthy(v, "success") and token != null) {
        zui.storage.set("token", token.?, .{ .secure = true });
        s.bearer.set(token.?);
        s.fields.getPtr(.login_password).clear();
        s.phase = .loading;
        api(s, .GET, "/config", null, .config);
        return;
    }
    s.login_error.set(j.str(v, "message") orelse j.str(v, "error.message") orelse j.str(v, "error") orelse if (r.status == 0) t("Could not reach Wufour. Check your connection.") else t("Invalid credentials"));
}

/// Signed out (401): the web goes through Wufour's sign-in; phones show the sign-in form.
pub fn signedOut(s: *State) void {
    if (s.mode == .embed) {
        embedTokenRequest(s);
        return;
    }
    stopSocket(s);
    if (native_auth) {
        zui.storage.remove("token", .{ .secure = true });
        s.bearer.clear();
        s.phase = .login;
    } else s.phase = .sign_in;
}

/// Log out of this device: forget the keys here and the session.
pub fn logout(s: *State) void {
    keys.forgetDevice(s);
    stopSocket(s);
    s.store.reset();
    s.open_chat = .{};
    s.panes.clearRetainingCapacity();
    s.modal = null;
    if (native_auth) {
        zui.storage.remove("token", .{ .secure = true });
        s.bearer.clear();
        s.phase = .login;
    } else fx.openUrl("/logout", false);
}

fn onMe(s: *State, r: zui.Response) void {
    if (r.status == 401) return signedOut(s);
    if (!r.ok()) {
        s.phase = .cannot_reach;
        s.boot_error.set(apiError(r).message);
        return;
    }
    const v = j.parse(tmp(), r.body) orelse return;
    const me = j.obj(v, "user") orelse return;
    setMe(s, me);
    keys.ensureKeys(s);
}

pub fn setMe(s: *State, me: j.Value) void {
    if (s.store.me) |m| {
        m.merge(me) catch {};
    } else s.store.me = data.Obj.create(me) catch null;
    _ = s.store.putUser(me) catch null;
}

/// Keys are ready (or the person unlocked them): show the app and start syncing.
pub fn keysReady(s: *State) void {
    if (s.phase == .ready) return;
    s.phase = .ready;
    api(s, .GET, "/chats", null, .chats);
    api(s, .GET, "/folders", null, .folders);
    stories.load(s);
    connect(s);
    push_mod.register();
    // Web Push (the shell subscribes this browser once notifications are allowed).
    if (zui.platform == .web and s.mode == .app) if (s.store.config) |cfg| if (cfg.s("push.vapidPublicKey")) |k|
        post(std.fmt.allocPrint(tmp(), "{{\"t\":\"push\",\"key\":{s}}}", .{j.quote(tmp(), k) catch return}) catch return);
}

// ---------------------------------------------------------------------------------------------
// Answers

fn onAnswer(s: *State, r: zui.Response) void {
    const kv = s.ops.fetchRemove(r.tag) orelse return;
    const op = kv.value;
    switch (op) {
        .config => {
            if (!r.ok()) {
                if (r.status == 401) return signedOut(s);
                s.phase = .cannot_reach;
                s.boot_error.set(apiError(r).message);
                return;
            }
            if (j.parse(tmp(), r.body)) |v| {
                if (s.store.config) |c| c.destroy();
                s.store.config = data.Obj.create(v) catch null;
            }
            if (s.mode == .embed) {
                api(s, .GET, "/me", null, .me);
            } else api(s, .GET, "/me", null, .me);
        },
        .me => onMe(s, r),
        .login => onLogin(s, r),
        .chats => sync.onChats(s, r),
        .folders => if (r.ok()) {
            if (j.parse(tmp(), r.body)) |v| {
                if (s.store.folders) |f| f.destroy();
                s.store.folders = data.Obj.create(v) catch null;
            }
        },
        .embed_config => onEmbedConfig(s, r),
        .embed_guest => if (r.ok()) {
            if (j.str(j.parse(tmp(), r.body), "token")) |tok| useBearer(s, tok);
            api(s, .GET, "/config", null, .config);
        } else {
            s.phase = .signed_out;
            s.boot_error.set(apiError(r).message);
        },
        .ignore => {},
        else => {
            if (r.status == 401 and s.phase == .ready) return signedOut(s);
            if (keys.onAnswer(s, op, r)) return;
            if (sync.onAnswer(s, op, r)) return;
            if (send.onAnswer(s, op, r)) return;
            if (media.onAnswer(s, op, r)) return;
            if (compose.onAnswer(s, op, r)) return;
            if (group.onAnswer(s, op, r)) return;
            if (folders.onAnswer(s, op, r)) return;
            if (chatlock.onAnswer(s, op, r)) return;
            if (exporter.onAnswer(s, op, r)) return;
            if (bots.onAnswer(s, op, r)) return;
            if (dev.onAnswer(s, op, r)) return;
            if (stories.onAnswer(s, op, r)) return;
            if (profile.onAnswer(s, op, r)) return;
            if (drafts.onAnswer(s, op, r)) return;
            if (extras.onAnswer(s, op, r)) return;
            if (chatmore.onAnswer(s, op, r)) return;
            if (userinfo.onAnswer(s, op, r)) return;
            if (sharedmedia.onAnswer(s, op, r)) return;
            views.onAnswer(s, op, r);
        },
    }
}

// ---------------------------------------------------------------------------------------------
// The realtime connection (core/socket.js): reconnects with backoff, requests with ack.

pub const Ws = struct {
    socket: u32 = 0,
    online: bool = false,
    ever: bool = false,
    stopped: bool = false,
    attempt: u32 = 0,
    conn_id: Text = .{},
    req_id: u32 = 0,
    pending: std.AutoHashMapUnmanaged(u32, calls.SocketReq) = .empty,
    outbox: std.ArrayList([]u8) = .empty,
};

pub fn connect(s: *State) void {
    if (s.ws.socket != 0) return;
    s.ws.stopped = false;
    const a = tmp();
    var url: []const u8 = "/ws";
    if (zui.platform != .web) {
        const base = if (std.mem.startsWith(u8, server, "https://"))
            std.fmt.allocPrint(a, "wss://{s}", .{server["https://".len..]}) catch return
        else if (std.mem.startsWith(u8, server, "http://"))
            std.fmt.allocPrint(a, "ws://{s}", .{server["http://".len..]}) catch return
        else
            server;
        url = std.fmt.allocPrint(a, "{s}/ws", .{base}) catch return;
    }
    if (s.bearer.get().len > 0) url = std.fmt.allocPrint(a, "{s}?token={s}", .{ url, j.urlEncode(a, s.bearer.get()) catch "" }) catch return;
    s.ws.socket = fx.openSocket(url, onSocket);
}

pub fn stopSocket(s: *State) void {
    s.ws.stopped = true;
    if (s.ws.socket != 0) fx.closeSocket(s.ws.socket);
    s.ws.socket = 0;
    s.ws.online = false;
}

/// A message to the server; queued (except typing) while offline.
pub fn wsSend(s: *State, typ: []const u8, d: []const u8) void {
    const text = std.fmt.allocPrint(gpa, "{{\"t\":\"{s}\",\"d\":{s}}}", .{ typ, d }) catch return;
    if (s.ws.online and s.ws.socket != 0) {
        fx.sendSocket(s.ws.socket, text);
        gpa.free(text);
    } else if (!std.mem.eql(u8, typ, "typing") and s.ws.outbox.items.len < 50) {
        s.ws.outbox.append(gpa, text) catch gpa.free(text);
    } else gpa.free(text);
}

/// A request that the server acknowledges ({t:"ack",d:{id,ok,result,error}}); false when offline.
pub fn wsRequest(s: *State, typ: []const u8, d: []const u8, req: calls.SocketReq) bool {
    if (!s.ws.online or s.ws.socket == 0) return false;
    s.ws.req_id += 1;
    const id = s.ws.req_id;
    const text = std.fmt.allocPrint(tmp(), "{{\"t\":\"{s}\",\"d\":{s},\"id\":{d}}}", .{ typ, d, id }) catch return false;
    s.ws.pending.put(gpa, id, req) catch return false;
    fx.sendSocket(s.ws.socket, text);
    return true;
}

fn onSocketEvent(s: *State, ev: zui.SocketEvent) void {
    if (ev.socket != s.ws.socket) return;
    switch (ev.kind) {
        .open => {},
        .message => {
            const v = j.parse(tmp(), ev.data) orelse return;
            const typ = j.str(v, "t") orelse return;
            const d = j.field(v, "d") orelse j.emptyObject();
            if (std.mem.eql(u8, typ, "ack")) {
                const id: u32 = @intCast(@max(0, j.intOr(d, "id", 0)));
                const kv = s.ws.pending.fetchRemove(id) orelse return;
                calls.onAck(s, kv.value, j.truthy(d, "ok"), j.field(d, "result"), j.str(d, "error") orelse "");
                return;
            }
            if (std.mem.eql(u8, typ, "ready")) {
                const was = s.ws.attempt > 0 or s.ws.ever;
                s.ws.attempt = 0;
                s.ws.ever = true;
                s.ws.online = true;
                s.ws.conn_id.set(j.str(d, "connId") orelse "");
                if (j.int(d, "serverTime")) |st| if (zui.platform == .web or zui.platform == .headless) sys.setClock(st, sys.tzOffsetMin(st));
                sendPresence(s);
                for (s.ws.outbox.items) |text| {
                    fx.sendSocket(s.ws.socket, text);
                    gpa.free(text);
                }
                s.ws.outbox.clearRetainingCapacity();
                sync.onConnected(s, was);
                return;
            }
            sync.onEvent(s, typ, d);
        },
        .closed => {
            s.ws.socket = 0;
            s.ws.online = false;
            s.ws.conn_id.clear();
            var it = s.ws.pending.valueIterator();
            while (it.next()) |req| calls.onAck(s, req.*, false, null, t("Connection lost"));
            s.ws.pending.clearRetainingCapacity();
            if (s.ws.stopped) return;
            s.ws.attempt += 1;
            // Exponential backoff with jitter, capped at 15 s.
            const base: f64 = @min(15_000.0, 400.0 * std.math.pow(f64, 2, @floatFromInt(@min(s.ws.attempt, 6))));
            const jitter = 0.6 + @as(f64, @floatFromInt(sys.random().int(u16))) / 65535.0 * 0.6;
            const delay: u32 = if (s.ws.attempt == 1) 300 else @intFromFloat(base * jitter);
            fx.after(delay, .{ .reconnect = s.ws.attempt });
        },
    }
}

pub fn sendPresence(s: *State) void {
    wsSend(s, "presence", if (s.visible) "{\"visible\":true}" else "{\"visible\":false}");
}

// ---------------------------------------------------------------------------------------------
// The page around the app: the web shell's clock and entropy, the embedding site's messages

fn onHost(s: *State, json: []const u8) void {
    const v = j.parse(tmp(), json) orelse return;
    if (j.str(v, "t")) |typ| {
        if (std.mem.eql(u8, typ, "env") or std.mem.eql(u8, typ, "clock")) {
            if (j.str(v, "seed")) |seed| sys.addEntropy(crypto.fromB64(tmp(), seed) catch seed);
            if (j.int(v, "now")) |now| sys.setClock(now, @intCast(j.intOr(v, "tz", 0)));
            if (j.field(v, "visible")) |vis| if (vis == .bool) setVisible(s, vis.bool);
            calls.onClock(s);
            return;
        }
        if (std.mem.eql(u8, typ, "visible")) {
            setVisible(s, j.truthy(v, "visible"));
            return;
        }
        if (std.mem.eql(u8, typ, "file")) {
            send.onPickedFile(s, v);
            return;
        }
        if (std.mem.eql(u8, typ, "rtc")) {
            calls.onRtc(s, v);
            return;
        }
        return;
    }
    if (s.mode == .embed) onEmbedMessage(s, v);
}

fn setVisible(s: *State, visible: bool) void {
    if (s.visible == visible) return;
    s.visible = visible;
    chatlock.onVisible(s, visible);
    sendPresence(s);
    if (visible) {
        if (s.ws.socket == 0 and !s.ws.stopped and s.phase == .ready) connect(s);
        sync.markOpenChatRead(s);
    }
}

// ---------------------------------------------------------------------------------------------
// Embedded widget (embed.js): handshake with the host page, token, target chats

pub fn post(json: []const u8) void {
    fx.post(json);
}

fn onEmbedConfig(s: *State, r: zui.Response) void {
    if (!r.ok()) {
        s.phase = .signed_out;
        s.boot_error.set(t("This chat is not available right now."));
        return;
    }
    const v = j.parse(tmp(), r.body) orelse return;
    const app = j.obj(v, "app") orelse return;
    s.embed.app = data.Obj.create(app) catch null;
    // The widget's language: the app's setting, or the browser's.
    const locale = j.strOr(app, "widget.locale", "auto");
    if (!std.mem.eql(u8, locale, "auto")) setLang(s, if (std.mem.eql(u8, locale, "ar")) .ar else .en);
    // Tell the shell which origins may talk to the widget, then say hello to the host page.
    const origins = j.stringify(tmp(), j.field(app, "allowedOrigins") orelse j.Value{ .array = std.json.Array.init(tmp()) }) catch "[]";
    post(std.fmt.allocPrint(tmp(), "{{\"t\":\"origins\",\"origins\":{s}}}", .{origins}) catch return);
    post("{\"type\":\"reseal:ready\"}");
    fx.after(4000, .embed_init_timeout);
}

fn onEmbedMessage(s: *State, v: j.Value) void {
    const typ = j.str(v, "type") orelse return;
    if (std.mem.eql(u8, typ, "reseal:init")) return embedInitDone(s, v);
    if (std.mem.eql(u8, typ, "reseal:token")) {
        if (j.str(v, "token")) |tok| useBearer(s, tok);
        s.embed.token_waiting = false;
        if (s.phase == .loading) api(s, .GET, "/me", null, .me);
        return;
    }
    if (std.mem.eql(u8, typ, "reseal:open")) return views.embedOpen(s, j.obj(v, "target"));
    if (std.mem.eql(u8, typ, "reseal:logout")) {
        keys.forgetDevice(s);
        s.phase = .signed_out;
        return;
    }
    if (std.mem.eql(u8, typ, "reseal:theme")) {
        if (s.embed.app) |app| if (j.obj(v, "theme")) |th| {
            var it = th.object.iterator();
            while (it.next()) |e| app.setIn("theme", e.key_ptr.*, e.value_ptr.*) catch {};
        };
    }
}

fn embedInitDone(s: *State, init_msg: ?j.Value) void {
    if (s.embed.init_done) return;
    s.embed.init_done = true;
    if (init_msg) |m| if (j.obj(m, "options")) |o| {
        s.embed.options = data.Obj.create(o) catch null;
    };
    const token = if (init_msg) |m| j.str(m, "token") else null;
    if (token) |tok| {
        useBearer(s, tok);
        api(s, .GET, "/config", null, .config);
        return;
    }
    const app = if (s.embed.app) |a| a.v else null;
    if (j.truthy(app, "guests")) {
        var guest = zui.storage.get(tmp(), std.fmt.allocPrint(tmp(), "guest:{s}", .{s.embed.pk.get()}) catch "guest", .{}) orelse "";
        if (guest.len == 0) {
            const b = sys.randomBytes(18);
            var hex = std.fmt.bytesToHex(b, .lower);
            guest = hex[0..24];
            zui.storage.set(std.fmt.allocPrint(tmp(), "guest:{s}", .{s.embed.pk.get()}) catch "guest", guest, .{});
        }
        const name = if (s.embed.options) |o| o.s("guestName") else null;
        const body = std.fmt.allocPrint(tmp(), "{{\"pk\":{s},\"guestId\":{s}{s}{s}}}", .{
            j.quote(tmp(), s.embed.pk.get()) catch return, j.quote(tmp(), guest) catch return,
            if (name != null) ",\"name\":" else "",                                             if (name) |n| j.quote(tmp(), n) catch "" else "",
        }) catch return;
        api(s, .POST, "/embed/guest", body, .embed_guest);
        return;
    }
    s.phase = .signed_out;
}

fn embedTokenRequest(s: *State) void {
    if (s.embed.token_waiting) return;
    s.embed.token_waiting = true;
    post("{\"type\":\"reseal:token-request\"}");
}

pub fn useBearer(s: *State, token: []const u8) void {
    s.bearer.set(token);
}

// ---------------------------------------------------------------------------------------------
// Home-screen widget (Android, iOS): who has unread messages, names only

fn updateWidget(s: *State) void {
    if ((zui.platform != .android and zui.platform != .ios) or s.phase != .ready) return;
    const a = tmp();
    var lines: std.ArrayList([]const u8) = .empty;
    var h = std.hash.Wyhash.init(0);
    const list = s.store.sorted(a, false);
    for (list) |c| {
        if (c.unread() == 0 or c.isMuted() or c.meBool("locked")) continue;
        const line = std.fmt.allocPrint(a, "{s} · {s}", .{ s.store.title(c), fmt.number(a, c.unread()) }) catch continue;
        lines.append(a, line) catch break;
        h.update(line);
        if (lines.items.len == 3) break;
    }
    const total = s.store.totals().unread;
    const title = if (total > 0) fmt.tn(a, total, "{n} unread message", "{n} unread messages") else t("No new messages");
    h.update(title);
    const sig = h.final();
    if (sig == s.widget_sig) return;
    s.widget_sig = sig;
    zui.widget.update(title, lines.items);
}

// ---------------------------------------------------------------------------------------------
// View

pub fn view(s: *const State, ui: *zui.Ui(Msg)) void {
    views.root(s, ui);
}

// ---------------------------------------------------------------------------------------------
// Tests

test {
    _ = crypto;
    _ = sys;
    _ = j;
    _ = data;
    _ = fmt;
    _ = @import("tests.zig");
    _ = @import("markdown.zig");
    _ = @import("rich.zig");
    _ = @import("compose.zig");
    _ = @import("export.zig");
    _ = @import("voice.zig");
}
