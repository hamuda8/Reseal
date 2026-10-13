//! The developer console (Reseal-js ui/dev.js): apps that embed Reseal, with their keys and
//! allowed origins, the widget's look and features, users, teams and support agents, message
//! storage, webhooks and deliveries, the AI assistant, and the app's settings. It opens as a pane
//! from Settings (the web app has its own page at /dev). The live preview of the widget is not
//! here: zui has no embedded web views.

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
const sys = @import("sys.zig");
const data = @import("data.zig");
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
const t = zui.i18n.t;
const tmp = app.tmp;
const key = kit.key;

pub const Tab = enum { overview, customize, users, storage, webhooks, ai, settings };
const tab_labels = [_][]const u8{ "Overview", "Customize", "Users & agents", "Storage", "Webhooks", "AI assistant", "Settings" };

/// The widget settings chosen from a list (fx.pickOption).
pub const Choice = enum { mode, font, bubbles, wallpaper, layout, position, launcher, opens, language };

const Opt = struct { v: []const u8, label: []const u8 };
const ChoiceSpec = struct { path: []const u8, title: []const u8, opts: []const Opt };
const choices = std.enums.EnumArray(Choice, ChoiceSpec).init(.{
    .mode = .{ .path = "theme.mode", .title = "Theme", .opts = &.{ .{ .v = "auto", .label = "Follow the visitor's system" }, .{ .v = "light", .label = "Light" }, .{ .v = "dark", .label = "Dark" } } },
    .font = .{ .path = "theme.font", .title = "Font", .opts = &.{ .{ .v = "system", .label = "System" }, .{ .v = "inter", .label = "Inter" }, .{ .v = "roboto", .label = "Roboto" }, .{ .v = "rounded", .label = "Rounded" }, .{ .v = "serif", .label = "Serif" }, .{ .v = "mono", .label = "Monospace" }, .{ .v = "arabic", .label = "Arabic" } } },
    .bubbles = .{ .path = "theme.bubbleStyle", .title = "Message bubbles", .opts = &.{ .{ .v = "rounded", .label = "Rounded" }, .{ .v = "square", .label = "Square" }, .{ .v = "minimal", .label = "Minimal" } } },
    .wallpaper = .{ .path = "theme.wallpaper", .title = "Background", .opts = &.{ .{ .v = "pattern", .label = "Pattern" }, .{ .v = "gradient", .label = "Gradient" }, .{ .v = "none", .label = "Plain" } } },
    .layout = .{ .path = "widget.mode", .title = "Layout", .opts = &.{ .{ .v = "bubble", .label = "Floating chat bubble" }, .{ .v = "inline", .label = "Inline (inside your page)" }, .{ .v = "fullscreen", .label = "Full screen" } } },
    .position = .{ .path = "widget.position", .title = "Position", .opts = &.{ .{ .v = "right", .label = "Bottom right" }, .{ .v = "left", .label = "Bottom left" } } },
    .launcher = .{ .path = "widget.launcherIcon", .title = "Launcher icon", .opts = &.{ .{ .v = "chat", .label = "Chat" }, .{ .v = "support", .label = "Support" }, .{ .v = "bot", .label = "AI" }, .{ .v = "help", .label = "Help" } } },
    .opens = .{ .path = "widget.defaultView", .title = "Opens on", .opts = &.{ .{ .v = "chats", .label = "Conversation list" }, .{ .v = "support", .label = "Support chat" }, .{ .v = "bot", .label = "AI assistant" } } },
    .language = .{ .path = "widget.locale", .title = "Language", .opts = &.{ .{ .v = "auto", .label = "Visitor's language" }, .{ .v = "en", .label = "English" }, .{ .v = "ar", .label = "العربية" } } },
});

const feature_list = [_][2][]const u8{
    .{ "groups", "Groups" },                 .{ "channels", "Channels" },            .{ "calls", "Voice calls" },             .{ "video", "Video calls" },
    .{ "voiceMessages", "Voice messages" },  .{ "videoMessages", "Video messages" }, .{ "photos", "Photos" },                  .{ "files", "Files" },
    .{ "reactions", "Reactions" },           .{ "polls", "Polls" },                  .{ "stickers", "Stickers" },              .{ "replies", "Replies" },
    .{ "forwarding", "Forwarding" },         .{ "editing", "Editing" },              .{ "deleting", "Deleting" },              .{ "pinning", "Pinning" },
    .{ "scheduled", "Scheduled messages" },  .{ "selfDestruct", "Disappearing messages" }, .{ "location", "Location" },         .{ "userSearch", "Find other users" },
    .{ "typing", "Typing indicators" },      .{ "readReceipts", "Read receipts" },   .{ "presence", "Online status" },         .{ "stories", "Glimpses" },
    .{ "export", "Chat export" },
};

const webhook_events = [_][]const u8{ "message.created", "message.edited", "message.deleted", "message.reaction", "chat.created", "chat.updated", "chat.deleted", "member.joined", "member.left", "call.started", "call.ended", "support.handoff", "button.pressed" };

pub const Act = union(enum) {
    open,
    open_app: Id,
    tab: Tab,
    create,
    create_submit,
    roll_secret,
    save_origins,
    copy_publishable,
    choose: Choice,
    picked: u32,
    feature: u8,
    toggle: enum { e2ee, guests, branding },
    radius_down,
    radius_up,
    save_customize,
    agent_toggle: Id,
    add_agent,
    add_agent_submit,
    save_storage,
    test_storage,
    signing_secret,
    webhook_enabled,
    webhook_event: u8,
    save_webhook,
    test_webhook,
    delivery: u16,
    retry: Id,
    new_bot,
    edit_bot: Id,
    use_bot: Id,
    save_settings,
    disable,
    delete_app,
    delete_submit,
    copy_secret,
};

pub const Dev = struct {
    apps: ?*data.Obj = null,
    /// GET /dev/apps/:id: {app, stats}.
    current: ?*data.Obj = null,
    /// The settings being customized (a copy of app.settings, saved as a whole).
    draft: ?*data.Obj = null,
    users: ?*data.Obj = null,
    teams: ?*data.Obj = null,
    deliveries: ?*data.Obj = null,
    bots: ?*data.Obj = null,
    app_id: Id = .{},
    tab: Tab = .overview,
    choosing: Choice = .mode,
    webhook_enabled: bool = false,
    /// Webhook events chosen (bit per webhook_events entry).
    events: u16 = 0,
    secret: app.Text = .{},
    secret_title: app.Text = .{},
    payload: app.Text = .{},
};

fn path(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(tmp(), f, args) catch "";
}

fn replace(slot: *?*data.Obj, v: ?j.Value) void {
    if (slot.*) |o| o.destroy();
    slot.* = if (v) |x| data.Obj.create(x) catch null else null;
}

fn appV(s: *const State) ?j.Value {
    const c = s.dev.current orelse return null;
    return j.obj(c.v, "app");
}

fn onPick(i: u32) Msg {
    return .{ .dev = .{ .picked = i } };
}

pub fn act(s: *State, a: Act) void {
    const d = &s.dev;
    const id = d.app_id.str();
    switch (a) {
        .open => {
            views.onUi(s, .{ .push_pane = .dev });
            app.api(s, .GET, "/dev/apps", null, .dev_apps);
        },
        .open_app => |x| {
            d.app_id = x;
            d.tab = .overview;
            replace(&d.current, null);
            views.onUi(s, .{ .push_pane = .dev_app });
            reload(s);
        },
        .tab => |tb| {
            d.tab = tb;
            loadTab(s);
        },
        .create => {
            s.fields.getPtr(.dev_app_name).clear();
            s.modal = .dev_create;
        },
        .create_submit => {
            const name = s.fields.get(.dev_app_name).trimmed();
            if (name.len == 0) return app.toastError(s, t("Give your app a name"));
            s.modal = null;
            app.api(s, .POST, "/dev/apps", path("{{\"name\":{s}}}", .{j.quote(tmp(), name) catch return}), .dev_created);
        },
        .roll_secret => s.modal = .{ .confirm = .{ .kind = .dev_roll, .target = d.app_id } },
        .save_origins => {
            var out: std.ArrayList(u8) = .empty;
            const ta = tmp();
            out.appendSlice(ta, "{\"allowedOrigins\":[") catch return;
            var it = std.mem.tokenizeAny(u8, s.fields.get(.dev_origins).get(), " \t\r\n,");
            var n: usize = 0;
            while (it.next()) |o| : (n += 1) out.print(ta, "{s}{s}", .{ if (n > 0) "," else "", j.quote(ta, o) catch continue }) catch {};
            out.appendSlice(ta, "]}") catch {};
            patchApp(s, out.items, t("Changes saved"));
        },
        .copy_publishable => if (appV(s)) |av| {
            app.fx.copy(j.strOr(av, "publishableKey", ""));
            app.toast(s, t("Copied"));
        },
        .choose => |c| {
            d.choosing = c;
            const spec = choices.get(c);
            const labels = tmp().alloc([]const u8, spec.opts.len) catch return;
            var selected: ?u32 = null;
            const cur = draftStr(s, spec.path);
            for (spec.opts, 0..) |o, i| {
                labels[i] = t(o.label);
                if (std.mem.eql(u8, o.v, cur)) selected = @intCast(i);
            }
            app.fx.pickOption(.{ .title = t(spec.title), .options = labels, .selected = selected }, onPick);
        },
        .picked => |i| {
            const spec = choices.get(d.choosing);
            if (i < spec.opts.len) setDraft(s, spec.path, data.string(spec.opts[i].v));
        },
        .feature => |i| if (i < feature_list.len) {
            const k = path("features.{s}", .{feature_list[i][0]});
            setDraft(s, k, data.boolean(!featureOn(s, i)));
        },
        .toggle => |x| switch (x) {
            .e2ee => setDraft(s, "e2ee", data.string(if (std.mem.eql(u8, draftStr(s, "e2ee"), "on")) "off" else "on")),
            .guests => setDraft(s, "guests", data.boolean(!draftBool(s, "guests"))),
            .branding => setDraft(s, "widget.showBranding", data.boolean(!draftBool(s, "widget.showBranding"))),
        },
        .radius_down => setDraft(s, "theme.radius", .{ .integer = @max(0, draftInt(s, "theme.radius") - 2) }),
        .radius_up => setDraft(s, "theme.radius", .{ .integer = @min(28, draftInt(s, "theme.radius") + 2) }),
        .save_customize => {
            // The typed fields first.
            inline for (.{ .{ .dev_primary, "theme.primary" }, .{ .dev_title, "theme.title" }, .{ .dev_subtitle, "theme.subtitle" }, .{ .dev_launcher_label, "widget.launcherLabel" }, .{ .dev_welcome, "widget.welcome" }, .{ .dev_placeholder, "widget.placeholder" } }) |kv| {
                setDraft(s, kv[1], data.string(d.draft.?.alloc().dupe(u8, s.fields.get(kv[0]).trimmed()) catch ""));
            }
            const dr = d.draft orelse return;
            patchApp(s, path("{{\"settings\":{s}}}", .{j.stringify(tmp(), dr.v) catch return}), t("Saved. Your widget is updated."));
        },
        .agent_toggle => |uid| {
            const av = appV(s) orelse return;
            var out: std.ArrayList(u8) = .empty;
            const ta = tmp();
            out.appendSlice(ta, "{\"settings\":{\"widget\":{\"agentIds\":[") catch return;
            var n: usize = 0;
            var had = false;
            for (j.arr(av, "settings.widget.agentIds")) |x| if (x == .string) {
                if (std.mem.eql(u8, x.string, uid.str())) {
                    had = true;
                    continue;
                }
                out.print(ta, "{s}\"{s}\"", .{ if (n > 0) "," else "", x.string }) catch {};
                n += 1;
            };
            if (!had) out.print(ta, "{s}\"{s}\"", .{ if (n > 0) "," else "", uid.str() }) catch {};
            out.appendSlice(ta, "]}}}") catch {};
            patchApp(s, out.items, null);
        },
        .add_agent => {
            s.fields.getPtr(.dev_agent_id).clear();
            s.fields.getPtr(.dev_agent_name).clear();
            s.modal = .dev_agent;
        },
        .add_agent_submit => {
            const ext = s.fields.get(.dev_agent_id).trimmed();
            if (ext.len == 0) return;
            const name = s.fields.get(.dev_agent_name).trimmed();
            s.modal = null;
            app.api(s, .POST, path("/dev/apps/{s}/users", .{id}), path("{{\"externalId\":{s},\"name\":{s},\"role\":\"agent\"}}", .{ j.quote(tmp(), ext) catch return, j.quote(tmp(), if (name.len > 0) name else ext) catch return }), .dev_agent_added);
        },
        .save_storage => patchApp(s, path("{{\"storage\":{{\"url\":{s}}}}}", .{j.quote(tmp(), s.fields.get(.dev_storage_url).trimmed()) catch return}), t("Storage saved")),
        .test_storage => app.api(s, .POST, path("/dev/apps/{s}/storage-test", .{id}), "{}", .dev_storage_tested),
        .signing_secret => app.api(s, .POST, path("/dev/apps/{s}/webhook-secret", .{id}), "{}", .dev_signing_secret),
        .webhook_enabled => d.webhook_enabled = !d.webhook_enabled,
        .webhook_event => |i| if (i < webhook_events.len) {
            d.events ^= @as(u16, 1) << @intCast(i);
        },
        .save_webhook => {
            var out: std.ArrayList(u8) = .empty;
            const ta = tmp();
            out.print(ta, "{{\"webhook\":{{\"url\":{s},\"enabled\":{},\"events\":[", .{ j.quote(ta, s.fields.get(.dev_webhook_url).trimmed()) catch return, d.webhook_enabled }) catch return;
            var n: usize = 0;
            for (webhook_events, 0..) |ev, i| if (d.events & (@as(u16, 1) << @intCast(i)) != 0) {
                out.print(ta, "{s}\"{s}\"", .{ if (n > 0) "," else "", ev }) catch {};
                n += 1;
            };
            out.appendSlice(ta, "]}}") catch {};
            patchApp(s, out.items, t("Webhook saved"));
        },
        .test_webhook => app.api(s, .POST, path("/dev/apps/{s}/webhook-test", .{id}), "{}", .dev_webhook_tested),
        .delivery => |i| if (d.deliveries) |dl| {
            const list = j.arr(dl.v, "deliveries");
            if (i < list.len) {
                d.payload.set(j.stringify(tmp(), j.field(list[i], "payload") orelse .null) catch "");
                d.secret_title.set(j.strOr(list[i], "event", ""));
                s.modal = .dev_payload;
            }
        },
        .retry => |x| app.api(s, .POST, path("/dev/apps/{s}/deliveries/{s}/retry", .{ id, x.str() }), "{}", .dev_tab_changed),
        .new_bot => {
            s.bots.app_id = d.app_id;
            app.bots.act(s, .new);
        },
        .edit_bot => |x| {
            s.bots.app_id = d.app_id;
            app.bots.act(s, .{ .edit = x });
        },
        .use_bot => |x| patchApp(s, path("{{\"settings\":{{\"widget\":{{\"botId\":\"{s}\"}}}}}}", .{x.str()}), null),
        .save_settings => patchApp(s, path("{{\"name\":{s},\"description\":{s}}}", .{ j.quote(tmp(), s.fields.get(.dev_name).trimmed()) catch return, j.quote(tmp(), s.fields.get(.dev_description).trimmed()) catch return }), t("Changes saved")),
        .disable => if (appV(s)) |av| patchApp(s, path("{{\"disabled\":{}}}", .{!j.truthy(av, "disabled")}), null),
        .copy_secret => {
            app.fx.copy(d.secret.get());
            app.toast(s, t("Secret key copied"));
        },
        .delete_app => {
            s.fields.getPtr(.dev_delete_confirm).clear();
            s.modal = .dev_delete;
        },
        .delete_submit => {
            const av = appV(s) orelse return;
            const typed = s.fields.get(.dev_delete_confirm).trimmed();
            if (!std.mem.eql(u8, typed, j.strOr(av, "name", ""))) return app.toastError(s, t("Type the exact app name"));
            s.modal = null;
            app.api(s, .DELETE, path("/dev/apps/{s}", .{id}), path("{{\"confirm\":{s}}}", .{j.quote(tmp(), typed) catch return}), .dev_deleted);
        },
    }
}

/// A confirmed roll of the secret key.
pub fn confirmed(s: *State) void {
    app.api(s, .POST, path("/dev/apps/{s}/rotate-secret", .{s.dev.app_id.str()}), "{}", .dev_secret_rolled);
}

fn reload(s: *State) void {
    app.api(s, .GET, path("/dev/apps/{s}", .{s.dev.app_id.str()}), null, .dev_app);
}

fn loadTab(s: *State) void {
    const id = s.dev.app_id.str();
    switch (s.dev.tab) {
        .users => {
            app.api(s, .GET, path("/dev/apps/{s}/users", .{id}), null, .dev_users);
            app.api(s, .GET, path("/dev/apps/{s}/teams", .{id}), null, .dev_teams);
        },
        .webhooks => app.api(s, .GET, path("/dev/apps/{s}/deliveries", .{id}), null, .dev_deliveries),
        .ai => app.api(s, .GET, path("/bots?appId={s}", .{id}), null, .dev_bots),
        else => {},
    }
}

fn patchApp(s: *State, body: []const u8, done: ?[]const u8) void {
    s.dev.secret_title.set(done orelse "");
    app.api(s, .PATCH, path("/dev/apps/{s}", .{s.dev.app_id.str()}), body, .dev_patched);
}

/// The app was (re)loaded: the forms start from it.
fn fill(s: *State) void {
    const d = &s.dev;
    const av = appV(s) orelse return;
    const f = &s.fields;
    var origins: std.ArrayList(u8) = .empty;
    for (j.arr(av, "allowedOrigins")) |o| if (o == .string) {
        if (origins.items.len > 0) origins.append(tmp(), '\n') catch {};
        origins.appendSlice(tmp(), o.string) catch {};
    };
    f.getPtr(.dev_origins).set(origins.items);
    f.getPtr(.dev_storage_url).set(j.strOr(av, "storage.url", ""));
    f.getPtr(.dev_webhook_url).set(j.strOr(av, "webhook.url", ""));
    f.getPtr(.dev_name).set(j.strOr(av, "name", ""));
    f.getPtr(.dev_description).set(j.strOr(av, "description", ""));
    f.getPtr(.dev_primary).set(j.strOr(av, "settings.theme.primary", "#6c5cff"));
    f.getPtr(.dev_title).set(j.strOr(av, "settings.theme.title", ""));
    f.getPtr(.dev_subtitle).set(j.strOr(av, "settings.theme.subtitle", ""));
    f.getPtr(.dev_launcher_label).set(j.strOr(av, "settings.widget.launcherLabel", ""));
    f.getPtr(.dev_welcome).set(j.strOr(av, "settings.widget.welcome", ""));
    f.getPtr(.dev_placeholder).set(j.strOr(av, "settings.widget.placeholder", ""));
    d.webhook_enabled = j.truthy(av, "webhook.enabled");
    const evs = j.arr(av, "webhook.events");
    d.events = 0;
    for (webhook_events, 0..) |ev, i| {
        var on = evs.len == 0;
        for (evs) |x| if (x == .string and std.mem.eql(u8, x.string, ev)) {
            on = true;
        };
        if (on) d.events |= @as(u16, 1) << @intCast(i);
    }
    replace(&d.draft, j.field(av, "settings") orelse j.parse(tmp(), "{}"));
}

// The customize draft: nested fields "a.b" in the draft object.

fn draftField(s: *const State, p: []const u8) ?j.Value {
    const dr = s.dev.draft orelse return null;
    return j.field(dr.v, p);
}

fn draftStr(s: *const State, p: []const u8) []const u8 {
    const v = draftField(s, p) orelse return "";
    return if (v == .string) v.string else "";
}

fn draftBool(s: *const State, p: []const u8) bool {
    const v = draftField(s, p) orelse return false;
    return v == .bool and v.bool;
}

fn draftInt(s: *const State, p: []const u8) i64 {
    const v = draftField(s, p) orelse return 0;
    return if (v == .integer) v.integer else 0;
}

fn featureOn(s: *const State, i: usize) bool {
    const v = draftField(s, path("features.{s}", .{feature_list[i][0]})) orelse return true;
    return !(v == .bool and !v.bool);
}

fn setDraft(s: *State, p: []const u8, val: j.Value) void {
    const dr = s.dev.draft orelse return;
    const a = dr.alloc();
    if (dr.v != .object) return;
    var obj = &dr.v.object;
    var it = std.mem.splitScalar(u8, p, '.');
    var part = it.next() orelse return;
    while (it.next()) |next| {
        const gop = obj.getOrPut(a, a.dupe(u8, part) catch return) catch return;
        if (!gop.found_existing or gop.value_ptr.* != .object) gop.value_ptr.* = .{ .object = .empty };
        obj = &gop.value_ptr.object;
        part = next;
    }
    const v = switch (val) {
        .string => |x| data.string(a.dupe(u8, x) catch return),
        else => val,
    };
    obj.put(a, a.dupe(u8, part) catch return, v) catch {};
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const d = &s.dev;
    const v = j.parse(tmp(), r.body);
    const failed = !r.ok();
    switch (op) {
        .dev_apps => if (failed) app.toastError(s, app.apiError(r).message) else replace(&d.apps, v),
        .dev_app => if (failed) app.toastError(s, app.apiError(r).message) else {
            replace(&d.current, v);
            fill(s);
            loadTab(s);
        },
        .dev_created => {
            if (failed) return toastFail(s, r);
            app.api(s, .GET, "/dev/apps", null, .dev_apps);
            d.secret.set(j.strOr(v, "app.secretKey", ""));
            d.secret_title.set(t("Your app is ready. This is its secret key: copy it now, it will not be shown again. Keep it on your server only."));
            s.modal = .dev_secret;
            if (j.str(v, "app.id")) |id| act(s, .{ .open_app = Id.of(id) });
            s.modal = .dev_secret;
        },
        .dev_secret_rolled => {
            if (failed) return toastFail(s, r);
            d.secret.set(j.strOr(v, "secretKey", ""));
            d.secret_title.set(t("Your new secret key. The old one stopped working."));
            s.modal = .dev_secret;
            reload(s);
        },
        .dev_patched => {
            if (failed) return toastFail(s, r);
            if (d.secret_title.get().len > 0) app.toast(s, d.secret_title.get());
            d.secret_title.clear();
            reload(s);
            app.api(s, .GET, "/dev/apps", null, .dev_apps);
        },
        .dev_users => if (!failed) replace(&d.users, v),
        .dev_teams => if (!failed) replace(&d.teams, v),
        .dev_deliveries => if (!failed) replace(&d.deliveries, v),
        .dev_bots => if (!failed) replace(&d.bots, v),
        .dev_tab_changed => loadTab(s),
        .dev_agent_added => {
            if (failed) return toastFail(s, r);
            if (j.str(v, "user.id")) |uid| act(s, .{ .agent_toggle = Id.of(uid) }) else loadTab(s);
        },
        .dev_storage_tested => if (failed) toastFail2(s, r) else if (j.truthy(v, "ok")) app.toast(s, t("Your storage answered")) else app.toastError(s, fmt.tf("Failed: {error}", .{ .@"error" = j.strOr(v, "error", "") })),
        .dev_webhook_tested => if (failed) toastFail2(s, r) else if (j.truthy(v, "ok")) app.toast(s, fmt.tf("Delivered (HTTP {status})", .{ .status = j.intOr(v, "status", 0) })) else app.toastError(s, fmt.tf("Failed: {error}", .{ .@"error" = j.str(v, "error") orelse (path("HTTP {d}", .{j.intOr(v, "status", 0)})) })),
        .dev_signing_secret => {
            if (failed) return toastFail(s, r);
            d.secret.set(j.strOr(v, "secret", ""));
            d.secret_title.set(t("Verify the Reseal-Signature header with this secret: HMAC-SHA256 of \"<t>.<body>\"."));
            s.modal = .dev_secret;
        },
        .dev_deleted => {
            if (failed) return toastFail(s, r);
            views.onUi(s, .pop_pane);
            app.api(s, .GET, "/dev/apps", null, .dev_apps);
        },
        else => return false,
    }
    return true;
}

fn toastFail(s: *State, r: zui.Response) bool {
    app.toastError(s, app.apiError(r).message);
    return true;
}

fn toastFail2(s: *State, r: zui.Response) void {
    app.toastError(s, app.apiError(r).message);
}

/// An assistant was saved from the AI tab: the list again, and the widget uses the first one.
pub fn botSaved(s: *State, bot_id: []const u8, created: bool) void {
    if (created) if (appV(s)) |av| if (j.str(av, "settings.widget.botId") == null) act(s, .{ .use_bot = Id.of(bot_id) });
    loadTab(s);
}

// ---------------------------------------------------------------------------------------------
// Views

fn msg(a: Act) Msg {
    return .{ .dev = a };
}

fn hashColor(id: []const u8) i64 {
    var h: u32 = 0;
    for (id) |ch| h = h *% 31 +% ch;
    return @intCast(h % 8);
}

fn card(cx: Cx, title: ?[]const u8, sub: ?[]const u8) void {
    cx.ui.begin(.{ .gap = 8, .padding = .all(16), .radius = 16, .background = cx.c.surface, .border_width = 1, .border_color = cx.c.border }, .{});
    if (title) |tt| cx.ui.text(tt, .{ .font_size = 16, .weight = 700, .color = cx.c.text });
    if (sub) |sb| cx.ui.text(sb, .{ .font_size = 13.5, .color = cx.c.text_2, .line_height = 1.5 });
}

fn endCard(cx: Cx) void {
    cx.ui.end();
    cx.ui.begin(.{ .height = .{ .px = 12 } }, .{});
    cx.ui.end();
}

fn code(cx: Cx, text: []const u8) void {
    cx.ui.begin(.{ .padding = .all(12), .radius = 10, .background = cx.c.surface_2 }, .{});
    cx.ui.textWith(text, .{ .font_size = 12.5, .mono = true, .color = cx.c.text, .line_height = 1.45 }, .{ .selectable = true });
    cx.ui.end();
}

/// Settings → Developers: the apps.
pub fn homePane(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, t("Reseal Platform"), true, false);
    vlist.endHeader(cx);
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 16, .end = 16, .top = 8, .bottom = 28 } }, key(.{"dev"}));
    card(cx, t("Add chat to your product in minutes"), t("Embed Reseal in any website or app: customer support, buyer-seller chat, community groups, or an AI assistant. Your users, your branding, your rules. Choose end-to-end encryption or a server-readable mode with webhooks and AI."));
    kit.button(cx, t("Create an app"), msg(.create), .{ .icon = icons.plus });
    endCard(cx);
    if (s.dev.apps) |o| {
        const list = j.arr(o.v, "apps");
        if (list.len > 0) {
            card(cx, t("Your apps"), null);
            for (list) |av| {
                const id = j.strOr(av, "id", "");
                ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 56, .padding = .xy(8, 6), .radius = 12, .pressed_background = cx.c.active, .hover_background = cx.c.hover }, .{ .on_press = msg(.{ .open_app = Id.of(id) }), .key = key(.{ "app", id }) });
                kit.avatar(cx, .{ .name = j.strOr(av, "name", "?"), .color = hashColor(id), .size = 40, .square = true }, 0);
                ui.begin(.{ .grow = 1, .width = .fill }, .{});
                ui.text(j.strOr(av, "name", ""), .{ .font_size = 15, .weight = 600, .color = cx.c.text, .max_lines = 1 });
                ui.text(j.strOr(av, "publishableKey", ""), .{ .font_size = 12.5, .mono = true, .color = cx.c.text_2, .max_lines = 1 });
                ui.end();
                ui.icon(icons.chevronRight, 18, cx.c.text_3, .{}, 0);
                ui.end();
            }
            endCard(cx);
        }
    } else kit.spinner(cx);
    ui.end();
    ui.end();
}

/// One app, with its tabs.
pub fn appPane(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const av = appV(s);
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, if (av) |x| j.strOr(x, "name", "") else t("App"), true, false);
    vlist.endHeader(cx);
    ui.beginScroll(.{ .direction = .row, .gap = 6, .padding = .{ .start = 14, .end = 14, .top = 2, .bottom = 10 }, .height = .{ .px = 46 } }, key(.{"dev-tabs"}));
    for (tab_labels, 0..) |l, i| {
        const on = @intFromEnum(s.dev.tab) == i;
        ui.begin(.{ .direction = .row, .align_items = .center, .height = .{ .px = 32 }, .padding = .xy(13, 0), .radius = 11, .background = if (on) cx.c.text else cx.c.surface_2 }, .{ .on_press = msg(.{ .tab = @enumFromInt(i) }), .key = key(.{ "devtab", i }) });
        ui.text(t(l), .{ .font_size = 13.5, .weight = 650, .color = if (on) cx.c.surface else cx.c.text_2, .max_lines = 1 });
        ui.end();
    }
    ui.end();
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 16, .end = 16, .top = 4, .bottom = 28 } }, key(.{ "dev-body", @intFromEnum(s.dev.tab) }));
    if (av) |x| switch (s.dev.tab) {
        .overview => overview(cx, x),
        .customize => customize(cx),
        .users => users(cx, x),
        .storage => storage(cx),
        .webhooks => webhooks(cx),
        .ai => aiTab(cx, x),
        .settings => settings(cx, x),
    } else kit.spinner(cx);
    ui.end();
    ui.end();
}

fn stat(cx: Cx, n: i64, label: []const u8, danger: bool) void {
    cx.ui.begin(.{ .grow = 1, .width = .fill, .gap = 2, .padding = .all(14), .radius = 14, .background = cx.c.surface_2 }, .{});
    cx.ui.text(std.fmt.allocPrint(cx.a(), "{d}", .{n}) catch "", .{ .font_size = 22, .weight = 800, .color = if (danger and n > 0) cx.c.danger else cx.c.text });
    cx.ui.text(label, .{ .font_size = 12.5, .color = cx.c.text_2, .max_lines = 1 });
    cx.ui.end();
}

fn overview(cx: Cx, av: j.Value) void {
    const s = cx.s;
    const ui = cx.ui;
    const a = cx.a();
    const stats = if (s.dev.current) |c| j.obj(c.v, "stats") else null;
    if (!j.truthy(av, "storage.connected")) {
        card(cx, t("Connect your message storage"), t("Messages in your app are kept in your own database. Set up your storage endpoint in the Storage tab before your users start chatting."));
        endCard(cx);
    }
    ui.begin(.{ .direction = .row, .gap = 8, .padding = .{ .bottom = 12 } }, .{});
    stat(cx, j.intOr(stats, "users", 0), t("Users"), false);
    stat(cx, j.intOr(stats, "chats", 0), t("Chats"), false);
    ui.end();
    ui.begin(.{ .direction = .row, .gap = 8, .padding = .{ .bottom = 12 } }, .{});
    stat(cx, j.intOr(stats, "webhooksDelivered", 0), t("Webhooks delivered"), false);
    stat(cx, j.intOr(stats, "webhooksFailed", 0), t("Webhooks failed"), true);
    ui.end();
    card(cx, t("Keys"), t("The publishable key is safe in web pages. The secret key is for your server only."));
    ui.text(t("Publishable key"), .{ .font_size = 13, .weight = 600, .color = cx.c.text_2 });
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8 }, .{});
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    code(cx, j.strOr(av, "publishableKey", ""));
    ui.end();
    kit.iconButton(cx, icons.copy, msg(.copy_publishable), .{ .size = 36 });
    ui.end();
    ui.text(t("Secret key"), .{ .font_size = 13, .weight = 600, .color = cx.c.text_2 });
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8 }, .{});
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    code(cx, std.fmt.allocPrint(a, "rsl_sk_••••••••••••••••••••{s}", .{j.strOr(av, "secretKeyHint", "")}) catch "");
    ui.end();
    kit.button(cx, t("Roll"), msg(.roll_secret), .{ .small = true, .kind = .secondary });
    ui.end();
    endCard(cx);
    card(cx, t("Allowed origins"), t("Websites allowed to show your widget, one per line. Leave empty to block embedding."));
    kit.field(cx, .dev_origins, .{ .placeholder = "https://shop.example.com", .multiline = true });
    kit.button(cx, t("Save origins"), msg(.save_origins), .{ .small = true });
    endCard(cx);
    const origin = if (s.store.config) |c| c.s("publicUrl") orelse "" else "";
    card(cx, t("1. Add the widget to your site"), t("Paste before </body>. Prefer anonymous visitors? Turn on guests in Customize and drop getToken."));
    code(cx, std.fmt.allocPrint(a,
        \\<script src="{s}/sdk/reseal.js"></script>
        \\<script>
        \\  Reseal.init({{
        \\    publishableKey: "{s}",
        \\    // Your backend creates a short-lived token for the signed-in user:
        \\    getToken: () => fetch("/api/reseal-token").then(r => r.json()).then(d => d.token),
        \\  }});
        \\</script>
    , .{ origin, j.strOr(av, "publishableKey", "") }) catch "");
    endCard(cx);
    card(cx, t("2. Issue tokens from your backend"), t("Your server tells Reseal who the user is, then hands a short-lived token to the widget."));
    code(cx, std.fmt.allocPrint(a,
        \\// Node.js (Express) — create the user and a token for the widget
        \\app.get("/api/reseal-token", async (req, res) => {{
        \\  const headers = {{ Authorization: "Bearer " + process.env.RESEAL_SECRET_KEY, "Content-Type": "application/json" }};
        \\  await fetch("{s}/api/v1/users", {{ method: "POST", headers,
        \\    body: JSON.stringify({{ externalId: req.user.id, name: req.user.name, avatarUrl: req.user.avatar }}) }});
        \\  const r = await fetch("{s}/api/v1/users/" + req.user.id + "/tokens", {{ method: "POST", headers, body: "{{}}" }});
        \\  res.json(await r.json());
        \\}});
    , .{ origin, origin }) catch "");
    endCard(cx);
    card(cx, t("3. Start conversations from your backend (optional)"), t("For example, a chat between a buyer and a seller about an order:"));
    code(cx, std.fmt.allocPrint(a,
        \\curl -X POST {s}/api/v1/chats \
        \\  -H "Authorization: Bearer $RESEAL_SECRET_KEY" -H "Content-Type: application/json" \
        \\  -d '{{"type":"private","members":["buyer-42","seller-7"],"externalId":"order-1001","metadata":{{"orderId":1001}}}}'
    , .{origin}) catch "");
    endCard(cx);
}

fn choiceRow(cx: Cx, c: Choice) void {
    const spec = choices.get(c);
    const cur = draftStr(cx.s, spec.path);
    var label: []const u8 = cur;
    for (spec.opts) |o| if (std.mem.eql(u8, o.v, cur)) {
        label = t(o.label);
    };
    kit.row(cx, t(spec.title), .{ .value = label, .chevron = true, .on = msg(.{ .choose = c }), .k = key(.{ "choice", @intFromEnum(c) }) });
}

fn customize(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    card(cx, t("Look"), null);
    choiceRow(cx, .mode);
    kit.field(cx, .dev_primary, .{ .label = t("Brand color"), .placeholder = "#6c5cff", .mono = true });
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .padding = .xy(12, 4) }, .{});
    ui.text(t("Corner roundness"), .{ .font_size = 15, .color = cx.c.text, .grow = 1, .width = .fill });
    kit.iconButton(cx, icons.minus, msg(.radius_down), .{ .size = 34, .soft = true });
    ui.text(std.fmt.allocPrint(cx.a(), "{d}", .{draftInt(s, "theme.radius")}) catch "", .{ .font_size = 15, .weight = 650, .color = cx.c.text, .min_width = 30, .text_align = .center });
    kit.iconButton(cx, icons.plus, msg(.radius_up), .{ .size = 34, .soft = true });
    ui.end();
    choiceRow(cx, .font);
    choiceRow(cx, .bubbles);
    choiceRow(cx, .wallpaper);
    kit.field(cx, .dev_title, .{ .label = t("Header title") });
    kit.field(cx, .dev_subtitle, .{ .label = t("Header subtitle"), .placeholder = t("We usually reply in a few minutes") });
    endCard(cx);
    card(cx, t("Widget"), null);
    choiceRow(cx, .layout);
    choiceRow(cx, .position);
    choiceRow(cx, .launcher);
    kit.field(cx, .dev_launcher_label, .{ .label = t("Launcher label"), .placeholder = t("Chat with us") });
    choiceRow(cx, .opens);
    kit.field(cx, .dev_welcome, .{ .label = t("Welcome message"), .multiline = true });
    kit.field(cx, .dev_placeholder, .{ .label = t("Input placeholder"), .placeholder = t("Message") });
    choiceRow(cx, .language);
    kit.row(cx, t("Show “Powered by Reseal”"), .{ .switch_on = draftBool(s, "widget.showBranding"), .on = msg(.{ .toggle = .branding }) });
    endCard(cx);
    card(cx, t("Privacy and access"), null);
    kit.row(cx, t("End-to-end encryption"), .{ .icon = icons.lock, .switch_on = std.mem.eql(u8, draftStr(s, "e2ee"), "on"), .subtitle = t("On: only users' devices can read messages. Off: enables webhooks with content, server search and AI."), .on = msg(.{ .toggle = .e2ee }) });
    kit.row(cx, t("Allow guests"), .{ .icon = icons.user, .switch_on = draftBool(s, "guests"), .subtitle = t("Visitors can chat without signing in (no backend needed)."), .on = msg(.{ .toggle = .guests }) });
    endCard(cx);
    card(cx, t("Features"), t("Choose what your users can do."));
    for (feature_list, 0..) |f, i| kit.row(cx, t(f[1]), .{ .switch_on = featureOn(s, i), .on = msg(.{ .feature = @intCast(i) }), .k = key(.{ "feat", i }) });
    endCard(cx);
    kit.button(cx, t("Save changes"), msg(.save_customize), .{ .block = true, .large = true });
}

fn users(cx: Cx, av: j.Value) void {
    const s = cx.s;
    const ui = cx.ui;
    const a = cx.a();
    card(cx, t("Teams"), t("Stores, departments or any group of people who answer customers as one. Your backend creates them with the REST API."));
    const teams = if (s.dev.teams) |o| j.arr(o.v, "teams") else &.{};
    if (teams.len == 0) ui.text(t("No teams yet"), .{ .font_size = 14, .color = cx.c.text_3 });
    for (teams) |tm| {
        const id = j.strOr(tm, "id", "");
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 52 }, .{ .key = key(.{ "team", id }) });
        kit.avatar(cx, .{ .name = j.strOr(tm, "name", "?"), .color = hashColor(id), .image_url = j.str(tm, "avatarUrl"), .size = 40, .square = true }, 0);
        ui.begin(.{ .grow = 1, .width = .fill }, .{});
        ui.text(j.strOr(tm, "name", ""), .{ .font_size = 15, .weight = 600, .color = cx.c.text, .max_lines = 1 });
        ui.text(j.strOr(tm, "externalId", ""), .{ .font_size = 12.5, .mono = true, .color = cx.c.text_2, .max_lines = 1 });
        ui.end();
        ui.text(std.fmt.allocPrint(a, "{s} · {s}", .{ fmt.tn(a, @intCast(j.arr(tm, "members").len), "{n} member", "{n} members"), fmt.tn(a, j.intOr(tm, "chats", 0), "{n} conversation", "{n} conversations") }) catch "", .{ .font_size = 12.5, .color = cx.c.text_3 });
        ui.end();
    }
    endCard(cx);
    card(cx, t("Support agents"), t("Every visitor's support chat includes these agents."));
    kit.button(cx, t("Add agent"), msg(.add_agent), .{ .small = true, .icon = icons.plus });
    endCard(cx);
    const list = if (s.dev.users) |o| j.arr(o.v, "users") else &.{};
    const total = if (s.dev.users) |o| j.intOr(o.v, "total", 0) else 0;
    card(cx, fmt.tn(a, total, "{n} user", "{n} users"), t("Users are created by your backend with the REST API, or as guests."));
    if (s.dev.users == null) kit.spinner(cx);
    for (list) |u| {
        const id = j.strOr(u, "id", "");
        const agent = std.mem.eql(u8, j.strOr(u, "role", ""), "agent");
        ui.begin(.{ .gap = 2 }, .{ .key = key(.{ "devuser", id }) });
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 52 }, .{});
        kit.avatar(cx, .{ .name = j.strOr(u, "name", "?"), .color = hashColor(id), .image_url = j.str(u, "avatarUrl"), .size = 40 }, 0);
        ui.begin(.{ .grow = 1, .width = .fill }, .{});
        ui.text(if (agent) std.fmt.allocPrint(a, "{s} · {s}", .{ j.strOr(u, "name", ""), t("agent") }) catch "" else j.strOr(u, "name", ""), .{ .font_size = 15, .weight = 600, .color = cx.c.text, .max_lines = 1 });
        ui.text(j.strOr(u, "externalId", ""), .{ .font_size = 12.5, .mono = true, .color = cx.c.text_2, .max_lines = 1 });
        ui.end();
        if (j.str(u, "lastSeenAt")) |ls| if (sys.parseIso(ls)) |ms| ui.text(fmt.fullDate(a, ms), .{ .font_size = 12, .color = cx.c.text_3 });
        ui.end();
        if (agent) {
            var on = false;
            for (j.arr(av, "settings.widget.agentIds")) |x| if (x == .string and std.mem.eql(u8, x.string, id)) {
                on = true;
            };
            kit.row(cx, t("In support chats"), .{ .switch_on = on, .on = msg(.{ .agent_toggle = Id.of(id) }) });
        }
        ui.end();
    }
    endCard(cx);
}

const storage_ops =
    \\ping    {}                                        → { "ok": true }
    \\put     { chatId, messages: [record] }            → store each record by id (insert or replace)
    \\get     { ids, chatId? }                          → { "messages": [record] }
    \\find    { chatId, senderId, clientId }            → { "message": record | null }
    \\list    { chatId, afterSeq, beforeSeq, order, limit } → { "messages": [record] }
    \\delete  { chatId, ids }                           → delete them (ids: null deletes the whole chat)
    \\search  { chatIds, query, limit }                 → { "messages": [record] }   (optional)
    \\
    \\record = { id, chatId, seq, senderId, clientId, createdAt, message }
    \\Keep "message" exactly as received and send it back unchanged.
;

fn storage(cx: Cx) void {
    const ui = cx.ui;
    card(cx, t("Message storage"), t("Your chats' messages are kept in your own database, not in Reseal. Reseal sends every new or changed message to this endpoint and reads history back from it. Until it is connected, your users cannot send messages."));
    kit.field(cx, .dev_storage_url, .{ .label = t("URL"), .placeholder = "https://example.com/reseal-storage" });
    ui.begin(.{ .direction = .row, .gap = 8 }, .{});
    kit.button(cx, t("Save"), msg(.save_storage), .{ .small = true });
    kit.button(cx, t("Test connection"), msg(.test_storage), .{ .small = true, .kind = .secondary });
    kit.button(cx, t("Signing secret"), msg(.signing_secret), .{ .small = true, .kind = .ghost, .icon = icons.key });
    ui.end();
    endCard(cx);
    card(cx, t("What your endpoint answers"), t("Reseal POSTs one signed JSON operation per request, named in \"op\". Check the signature, then answer:"));
    code(cx, storage_ops);
    ui.text(t("A complete example to start from is examples/message-store.mjs. The guide is on the developers page, under Message storage."), .{ .font_size = 13, .color = cx.c.text_2 });
    endCard(cx);
}

fn webhooks(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const a = cx.a();
    card(cx, t("Endpoint"), t("Reseal POSTs JSON events here and retries failures for up to a day."));
    kit.field(cx, .dev_webhook_url, .{ .label = t("URL"), .placeholder = "https://example.com/reseal-webhook" });
    kit.row(cx, t("Enabled"), .{ .switch_on = s.dev.webhook_enabled, .on = msg(.webhook_enabled) });
    ui.text(t("Events"), .{ .font_size = 13, .weight = 600, .color = cx.c.text_2 });
    for (webhook_events, 0..) |ev, i| kit.row(cx, ev, .{ .switch_on = s.dev.events & (@as(u16, 1) << @intCast(i)) != 0, .on = msg(.{ .webhook_event = @intCast(i) }), .k = key(.{ "ev", i }) });
    ui.begin(.{ .direction = .row, .gap = 8 }, .{});
    kit.button(cx, t("Save"), msg(.save_webhook), .{ .small = true });
    kit.button(cx, t("Send test event"), msg(.test_webhook), .{ .small = true, .kind = .secondary });
    kit.button(cx, t("Signing secret"), msg(.signing_secret), .{ .small = true, .kind = .ghost, .icon = icons.key });
    ui.end();
    endCard(cx);
    card(cx, t("Recent deliveries"), null);
    const list = if (s.dev.deliveries) |o| j.arr(o.v, "deliveries") else &.{};
    if (s.dev.deliveries != null and list.len == 0) ui.text(t("No deliveries yet"), .{ .font_size = 14, .color = cx.c.text_3 });
    for (list, 0..) |dl, i| {
        const st = j.strOr(dl, "status", "");
        const col = if (std.mem.eql(u8, st, "delivered")) cx.c.success else if (std.mem.eql(u8, st, "failed")) cx.c.danger else cx.c.text_3;
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .min_height = 44, .padding = .xy(6, 4), .radius = 10, .pressed_background = cx.c.active }, .{ .on_press = msg(.{ .delivery = @intCast(i) }), .key = key(.{ "dl", j.strOr(dl, "id", "") }) });
        ui.begin(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = col }, .{});
        ui.end();
        ui.text(j.strOr(dl, "event", ""), .{ .font_size = 13.5, .mono = true, .color = cx.c.text, .grow = 1, .width = .fill, .max_lines = 1 });
        const status_text = if (j.intOr(dl, "lastStatus", 0) > 0) std.fmt.allocPrint(a, "HTTP {d}", .{j.intOr(dl, "lastStatus", 0)}) catch "" else j.str(dl, "lastError") orelse st;
        ui.text(status_text, .{ .font_size = 12.5, .color = cx.c.text_3, .max_lines = 1 });
        if (std.mem.eql(u8, st, "failed")) kit.button(cx, t("Retry"), msg(.{ .retry = Id.of(j.strOr(dl, "id", "")) }), .{ .small = true, .kind = .ghost });
        ui.end();
    }
    endCard(cx);
}

fn aiTab(cx: Cx, av: j.Value) void {
    const s = cx.s;
    const ui = cx.ui;
    card(cx, t("AI assistant"), t("An assistant answers your users in the widget, powered by any OpenRouter model. Works when end-to-end encryption is off. In support chats it steps back as soon as an agent replies, or when the visitor asks for a person."));
    if (std.mem.eql(u8, j.strOr(av, "settings.e2ee", ""), "on")) {
        ui.begin(.{ .direction = .row, .gap = 8, .padding = .all(10), .radius = 12, .background = cx.c.surface_2 }, .{});
        ui.icon(icons.alert, 18, cx.c.warning, .{}, 0);
        ui.text(t("This app is end-to-end encrypted, so the server cannot read messages for an AI. Turn encryption off in Customize to use an assistant."), .{ .font_size = 13.5, .color = cx.c.text_2, .grow = 1, .width = .fill });
        ui.end();
    }
    kit.button(cx, t("Create an assistant"), msg(.new_bot), .{ .small = true, .icon = icons.plus });
    endCard(cx);
    card(cx, t("Assistants"), null);
    const current = j.strOr(av, "settings.widget.botId", "");
    const list = if (s.dev.bots) |o| j.arr(o.v, "bots") else &.{};
    if (s.dev.bots != null and list.len == 0) ui.text(t("No assistants yet"), .{ .font_size = 14, .color = cx.c.text_3 });
    for (list) |b| {
        const id = j.strOr(b, "id", "");
        ui.begin(.{ .direction = .row, .align_items = .center, .gap = 10, .min_height = 56 }, .{ .key = key(.{ "devbot", id }) });
        kit.avatar(cx, .{ .name = j.strOr(b, "name", "?"), .color = 4, .image = j.str(b, "avatar"), .icon = if (j.str(b, "avatar") == null) icons.sparkles else null, .size = 42 }, 0);
        ui.begin(.{ .grow = 1, .width = .fill }, .{});
        ui.text(j.strOr(b, "name", ""), .{ .font_size = 15, .weight = 600, .color = cx.c.text, .max_lines = 1 });
        ui.text(j.strOr(b, "model", ""), .{ .font_size = 12.5, .mono = true, .color = cx.c.text_2, .max_lines = 1 });
        ui.end();
        if (std.mem.eql(u8, id, current)) kit.badge(cx, t("in widget"), false) else kit.button(cx, t("Use in widget"), msg(.{ .use_bot = Id.of(id) }), .{ .small = true, .kind = .secondary });
        kit.iconButton(cx, icons.edit, msg(.{ .edit_bot = Id.of(id) }), .{ .size = 36 });
        ui.end();
    }
    endCard(cx);
}

fn settings(cx: Cx, av: j.Value) void {
    card(cx, null, null);
    kit.field(cx, .dev_name, .{ .label = t("Name") });
    kit.field(cx, .dev_description, .{ .label = t("Description"), .multiline = true });
    kit.button(cx, t("Save"), msg(.save_settings), .{ .small = true });
    endCard(cx);
    card(cx, t("Danger zone"), null);
    kit.row(cx, t("Disable app"), .{ .switch_on = j.truthy(av, "disabled"), .subtitle = t("Stops the widget and the API until you turn it back on"), .on = msg(.disable) });
    kit.button(cx, t("Delete app"), msg(.delete_app), .{ .small = true, .kind = .danger, .icon = icons.trash });
    endCard(cx);
}

// Sheets

pub fn createSheet(cx: Cx) void {
    views.sheet(cx, t("New app"));
    cx.ui.begin(.{ .padding = .xy(12, 4) }, .{});
    kit.field(cx, .dev_app_name, .{ .label = t("App name"), .placeholder = t("e.g. My Store"), .submit = msg(.create_submit) });
    buttons(cx, t("Create"), msg(.create_submit), false);
    cx.ui.end();
    views.endSheet(cx);
}

pub fn secretSheet(cx: Cx) void {
    const s = cx.s;
    views.sheet(cx, t("Secret key"));
    cx.ui.begin(.{ .padding = .xy(12, 4), .gap = 10 }, .{});
    cx.ui.text(s.dev.secret_title.get(), .{ .font_size = 14.5, .color = cx.c.text_2, .line_height = 1.5 });
    code(cx, s.dev.secret.get());
    cx.ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .bottom = 8 } }, .{});
    kit.button(cx, t("Copy"), msg(.copy_secret), .{ .kind = .secondary, .icon = icons.copy });
    kit.button(cx, t("Done"), .close_modal, .{});
    cx.ui.end();
    cx.ui.end();
    views.endSheet(cx);
}

pub fn agentSheet(cx: Cx) void {
    views.sheet(cx, t("Add an agent"));
    cx.ui.begin(.{ .padding = .xy(12, 4) }, .{});
    kit.sectionNote(cx, t("Agents answer support chats. They use the widget too: sign them in with their externalId, for example on your internal dashboard."));
    kit.field(cx, .dev_agent_id, .{ .label = t("External ID"), .placeholder = "agent-1" });
    kit.field(cx, .dev_agent_name, .{ .label = t("Name"), .placeholder = t("Support team") });
    buttons(cx, t("Add"), msg(.add_agent_submit), false);
    cx.ui.end();
    views.endSheet(cx);
}

pub fn payloadSheet(cx: Cx) void {
    views.sheet(cx, cx.s.dev.secret_title.get());
    cx.ui.begin(.{ .padding = .xy(12, 4) }, .{});
    code(cx, cx.s.dev.payload.get());
    cx.ui.end();
    views.endSheet(cx);
}

pub fn deleteSheet(cx: Cx) void {
    const name = if (appV(cx.s)) |av| j.strOr(av, "name", "") else "";
    views.sheet(cx, fmt.tf("Delete {name}?", .{ .name = name }));
    cx.ui.begin(.{ .padding = .xy(12, 4) }, .{});
    kit.sectionNote(cx, t("This permanently disables the app and its keys. Type the app name to confirm."));
    kit.field(cx, .dev_delete_confirm, .{ .placeholder = name, .submit = msg(.delete_submit) });
    buttons(cx, t("Delete app"), msg(.delete_submit), true);
    cx.ui.end();
    views.endSheet(cx);
}

fn buttons(cx: Cx, label: []const u8, m: Msg, danger: bool) void {
    cx.ui.begin(.{ .direction = .row, .justify = .end, .gap = 8, .padding = .{ .top = 4, .bottom = 8 } }, .{});
    kit.button(cx, t("Cancel"), .close_modal, .{ .kind = .ghost });
    kit.button(cx, label, m, .{ .kind = if (danger) .danger else .primary });
    cx.ui.end();
}
