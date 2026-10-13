//! AI assistants (Reseal-js ui/bots.js): my assistants and the public ones to discover, and the
//! editor (name, username, description, model from OpenRouter's list, instructions, greeting,
//! suggested questions, own API key, temperature, reply length, context, public, groups, images).

const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const j = @import("j.zig");
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

pub const Act = union(enum) {
    open_list,
    new,
    edit: Id,
    chat: Id,
    pick_model,
    model: u16,
    model_typed,
    temp_down,
    temp_up,
    toggle: enum { public, groups, vision },
    save,
    delete,
};

pub const Bots = struct {
    mine: ?*data.Obj = null,
    discover: ?*data.Obj = null,
    models: ?*data.Obj = null,
    /// The assistant being edited ("" for a new one).
    id: Id = .{},
    model: Id = .{},
    temperature: u8 = 7, // tenths
    public: bool = false,
    groups: bool = true,
    vision: bool = false,
    own_key: bool = false,
    stats: app.Text = .{},
    busy: bool = false,
    /// Set when editing from the developer console: the app the assistant belongs to.
    app_id: Id = .{},
};

const default_prompt = "You are a helpful, friendly assistant. Answer clearly and concisely.";

fn path(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(tmp(), f, args) catch "";
}

fn replace(slot: *?*data.Obj, v: ?j.Value) void {
    if (slot.*) |o| o.destroy();
    slot.* = if (v) |x| data.Obj.create(x) catch null else null;
}

fn findBot(s: *const State, id: []const u8) ?j.Value {
    inline for (.{ s.bots.mine, s.bots.discover }) |src| if (src) |o| for (j.arr(o.v, "bots")) |b| {
        if (j.eqlStr(b, "id", id)) return b;
    };
    return null;
}

pub fn act(s: *State, a: Act) void {
    const b = &s.bots;
    switch (a) {
        .open_list => {
            s.modal = null;
            b.app_id = .{};
            views.onUi(s, .{ .push_pane = .bots });
            load(s);
        },
        .new, .edit => {
            const bot: ?j.Value = if (a == .edit) findBot(s, a.edit.str()) else null;
            b.id = if (a == .edit) a.edit else .{};
            b.model = Id.of(j.strOr(bot, "model", "openai/gpt-4o-mini"));
            b.temperature = @intFromFloat(@round(j.floatOr(bot, "temperature", 0.7) * 10));
            b.public = j.truthy(bot, "public");
            b.groups = if (j.field(bot, "allowGroups")) |v| !(v == .bool and !v.bool) else true;
            b.vision = j.truthy(bot, "vision");
            b.own_key = j.truthy(bot, "ownKey");
            b.stats.clear();
            if (j.obj(bot, "stats")) |st| b.stats.set(fmt.tf("{replies} replies · {tokens} tokens used", .{ .replies = j.intOr(st, "replies", 0), .tokens = j.intOr(st, "promptTokens", 0) + j.intOr(st, "completionTokens", 0) }));
            const f = &s.fields;
            f.getPtr(.bot_name).set(j.strOr(bot, "name", ""));
            f.getPtr(.bot_username).set(j.strOr(bot, "username", ""));
            f.getPtr(.bot_description).set(j.strOr(bot, "description", ""));
            f.getPtr(.bot_prompt).set(j.strOr(bot, "systemPrompt", default_prompt));
            f.getPtr(.bot_greeting).set(j.strOr(bot, "greeting", ""));
            var starters: std.ArrayList(u8) = .empty;
            for (j.arr(bot, "starters")) |x| if (x == .string) {
                if (starters.items.len > 0) starters.append(tmp(), '\n') catch {};
                starters.appendSlice(tmp(), x.string) catch {};
            };
            f.getPtr(.bot_starters).set(starters.items);
            f.getPtr(.bot_key).clear();
            f.getPtr(.bot_max_tokens).set(path("{d}", .{j.intOr(bot, "maxTokens", 1024)}));
            f.getPtr(.bot_context).set(path("{d}", .{j.intOr(bot, "contextMessages", 20)}));
            views.onUi(s, .{ .push_pane = .bot_edit });
        },
        .chat => |id| {
            s.modal = null;
            app.api(s, .POST, "/chats/private", path("{{\"userId\":\"{s}\"}}", .{id.str()}), .open_private);
        },
        .pick_model => {
            s.fields.getPtr(.model_search).clear();
            s.modal = .model_picker;
            if (b.models == null) app.api(s, .GET, "/ai/models", null, .bots_models);
        },
        .model => |i| if (b.models) |m| {
            const list = j.arr(m.v, "models");
            if (i < list.len) {
                b.model = Id.of(j.strOr(list[i], "id", ""));
                if (j.truthy(list[i], "vision")) b.vision = true;
            }
            s.modal = null;
        },
        .model_typed => {
            const typed = s.fields.get(.model_search).trimmed();
            if (typed.len > 0) b.model = Id.of(typed);
            s.modal = null;
        },
        .temp_down => b.temperature -|= 1,
        .temp_up => b.temperature = @min(20, b.temperature + 1),
        .toggle => |x| switch (x) {
            .public => b.public = !b.public,
            .groups => b.groups = !b.groups,
            .vision => b.vision = !b.vision,
        },
        .save => save(s),
        .delete => if (b.id.isSet()) {
            app.api(s, .DELETE, path("/bots/{s}", .{b.id.str()}), null, .bots_deleted);
        },
    }
}

pub fn load(s: *State) void {
    app.api(s, .GET, "/bots", null, .bots_mine);
    app.api(s, .GET, "/bots/discover", null, .bots_discover);
}

fn save(s: *State) void {
    const b = &s.bots;
    const a = tmp();
    const f = &s.fields;
    const name = f.get(.bot_name).trimmed();
    if (name.len == 0) return app.toastError(s, t("Enter a name"));
    var out: std.ArrayList(u8) = .empty;
    out.print(a, "{{\"name\":{s},\"description\":{s},\"model\":{s},\"systemPrompt\":{s},\"temperature\":{d:.1},\"maxTokens\":{d},\"contextMessages\":{d},\"greeting\":{s},\"public\":{},\"allowGroups\":{},\"vision\":{},\"starters\":[", .{
        j.quote(a, name) catch return,
        j.quote(a, f.get(.bot_description).trimmed()) catch return,
        j.quote(a, b.model.str()) catch return,
        j.quote(a, f.get(.bot_prompt).get()) catch return,
        @as(f32, @floatFromInt(b.temperature)) / 10,
        std.fmt.parseInt(u32, f.get(.bot_max_tokens).trimmed(), 10) catch 1024,
        std.fmt.parseInt(u32, f.get(.bot_context).trimmed(), 10) catch 20,
        j.quote(a, f.get(.bot_greeting).trimmed()) catch return,
        b.public,
        b.groups,
        b.vision,
    }) catch return;
    var it = std.mem.tokenizeAny(u8, f.get(.bot_starters).get(), "\r\n");
    var n: usize = 0;
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t");
        if (l.len == 0 or n >= 6) continue;
        out.print(a, "{s}{s}", .{ if (n > 0) "," else "", j.quote(a, l) catch continue }) catch {};
        n += 1;
    }
    out.append(a, ']') catch {};
    const un = f.get(.bot_username).trimmed();
    if (un.len > 0) out.print(a, ",\"username\":{s}", .{j.quote(a, un) catch return}) catch {};
    const k = f.get(.bot_key).trimmed();
    if (k.len > 0) out.print(a, ",\"apiKey\":{s}", .{j.quote(a, k) catch return}) catch {};
    if (b.app_id.isSet() and !b.id.isSet()) out.print(a, ",\"appId\":\"{s}\"", .{b.app_id.str()}) catch {};
    out.append(a, '}') catch {};
    b.busy = true;
    if (b.id.isSet()) app.api(s, .PATCH, path("/bots/{s}", .{b.id.str()}), out.items, .bots_saved) else app.api(s, .POST, "/bots", out.items, .bots_saved);
}

pub fn onAnswer(s: *State, op: app.Op, r: zui.Response) bool {
    const b = &s.bots;
    const v = j.parse(tmp(), r.body);
    switch (op) {
        .bots_mine => if (r.ok()) replace(&b.mine, v) else replace(&b.mine, j.parse(tmp(), "{\"bots\":[]}")),
        .bots_discover => if (r.ok()) replace(&b.discover, v) else replace(&b.discover, j.parse(tmp(), "{\"bots\":[]}")),
        .bots_models => if (r.ok()) replace(&b.models, v) else app.toastError(s, app.apiError(r).message),
        .bots_saved => {
            b.busy = false;
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            const created = !b.id.isSet();
            app.toast(s, if (created) t("Assistant created") else t("Assistant saved"));
            views.onUi(s, .pop_pane);
            if (b.app_id.isSet()) {
                app.dev.botSaved(s, j.strOr(v, "bot.id", ""), created);
                return true;
            }
            load(s);
            if (created) if (j.str(v, "bot.id")) |id| act(s, .{ .chat = Id.of(id) });
        },
        .bots_deleted => {
            if (!r.ok()) {
                app.toastError(s, app.apiError(r).message);
                return true;
            }
            views.onUi(s, .pop_pane);
            if (b.app_id.isSet()) app.dev.botSaved(s, "", false) else load(s);
        },
        else => return false,
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Views

fn msg(a: Act) Msg {
    return .{ .bots = a };
}

pub fn listPane(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, t("AI assistants"), true, false);
    vlist.endHeader(cx);
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 8, .end = 8, .bottom = 28 } }, key(.{"bots"}));
    ui.begin(.{ .align_items = .center, .gap = 10, .padding = .xy(24, 18) }, .{});
    ui.begin(.{ .width = .{ .px = 64 }, .height = .{ .px = 64 }, .radius = 22, .background = cx.c.accent_soft, .align_items = .center, .justify = .center }, .{});
    ui.icon(icons.sparkles, 30, cx.c.accent, .{}, 0);
    ui.end();
    ui.text(t("Chat with AI models, or build your own assistant with any model available on OpenRouter."), .{ .font_size = 14, .color = cx.c.text_2, .text_align = .center, .line_height = 1.5 });
    ui.end();
    kit.sectionTitle(cx, t("My assistants"));
    kit.row(cx, t("Create an assistant"), .{ .icon = icons.plus, .on = msg(.new) });
    if (s.bots.mine) |m| {
        for (j.arr(m.v, "bots")) |b| botRow(cx, b, true);
    } else kit.spinner(cx);
    if (s.bots.discover) |d| {
        const list = j.arr(d.v, "bots");
        var any = false;
        for (list) |b| {
            if (s.bots.mine) |m| if (for (j.arr(m.v, "bots")) |x| {
                if (j.eqlStr(x, "id", j.strOr(b, "id", ""))) break true;
            } else false) continue;
            if (!any) kit.sectionTitle(cx, t("Discover"));
            any = true;
            botRow(cx, b, false);
        }
    }
    ui.end();
    ui.end();
}

fn botRow(cx: Cx, b: j.Value, editable: bool) void {
    const ui = cx.ui;
    const id = j.strOr(b, "id", "");
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 12, .min_height = 60, .padding = .xy(12, 6), .radius = theme.radius, .pressed_background = cx.c.active, .hover_background = cx.c.hover }, .{ .on_press = msg(.{ .chat = Id.of(id) }), .key = key(.{ "bot", id, editable }) });
    kit.avatar(cx, .{ .name = j.strOr(b, "name", "?"), .color = 4, .image = j.str(b, "avatar"), .icon = if (j.str(b, "avatar") == null) icons.sparkles else null, .size = 46 }, 0);
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    ui.text(j.strOr(b, "name", ""), .{ .font_size = 15, .weight = 600, .color = cx.c.text, .max_lines = 1 });
    ui.text(j.str(b, "description") orelse j.strOr(b, "model", ""), .{ .font_size = 13, .color = cx.c.text_2, .max_lines = 1 });
    ui.end();
    if (editable) kit.iconButton(cx, icons.edit, msg(.{ .edit = Id.of(id) }), .{ .size = 36 });
    ui.end();
}

pub fn editPane(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    const b = &s.bots;
    ui.begin(.{ .width = .fill, .height = .fill }, .{});
    vlist.paneHeader(cx, if (b.id.isSet()) t("Edit assistant") else t("New assistant"), true, false);
    vlist.endHeader(cx);
    ui.beginScroll(.{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .start = 16, .end = 16, .top = 8, .bottom = 28 } }, key(.{"bot-edit"}));
    kit.field(cx, .bot_name, .{ .label = t("Name"), .placeholder = t("e.g. Travel Planner") });
    kit.field(cx, .bot_username, .{ .label = t("Username"), .placeholder = "travel_planner_bot", .hint = t("Must end in “bot”. Lets people find it and mention it in groups.") });
    kit.field(cx, .bot_description, .{ .label = t("Description"), .placeholder = t("What does it help with?"), .multiline = true });
    ui.begin(.{ .gap = 7, .padding = .{ .bottom = 16 } }, .{});
    ui.text(t("Model"), .{ .font_size = 13, .weight = 600, .color = cx.c.text_2 });
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .height = .{ .px = 46 }, .padding = .xy(14, 0), .radius = theme.radius, .border_width = 1, .border_color = cx.c.border_strong, .background = cx.c.surface_2, .pressed_background = cx.c.active }, .{ .on_press = msg(.pick_model) });
    ui.text(b.model.str(), .{ .font_size = 14, .mono = true, .color = cx.c.text, .grow = 1, .width = .fill, .max_lines = 1 });
    ui.icon(icons.chevronDown, 18, cx.c.text_3, .{}, 0);
    ui.end();
    ui.text(t("Any model on OpenRouter. Free models are marked."), .{ .font_size = 12.5, .color = cx.c.text_3 });
    ui.end();
    kit.field(cx, .bot_prompt, .{ .label = t("Instructions (system prompt)"), .hint = t("Tell the assistant who it is, what it knows and how to answer."), .multiline = true });
    kit.field(cx, .bot_greeting, .{ .label = t("Greeting"), .placeholder = t("First message when someone starts a chat (optional)"), .multiline = true });
    kit.field(cx, .bot_starters, .{ .label = t("Suggested questions"), .placeholder = t("One suggested question per line (up to 6)"), .multiline = true });
    const has_platform = if (s.store.config) |c| c.b("ai.platformKey") else false;
    kit.field(cx, .bot_key, .{ .label = t("OpenRouter API key"), .placeholder = if (b.own_key) t("Key saved") else "sk-or-v1-…", .hint = if (has_platform) t("Optional: this server provides a default key. Your key is encrypted at rest.") else t("Get a key at openrouter.ai/keys. It is encrypted at rest and never shown again.") });
    kit.sectionTitle(cx, t("Advanced"));
    ui.begin(.{ .direction = .row, .align_items = .center, .gap = 8, .padding = .xy(12, 6) }, .{});
    ui.text(t("Creativity (temperature)"), .{ .font_size = 15, .color = cx.c.text, .grow = 1, .width = .fill });
    kit.iconButton(cx, icons.minus, msg(.temp_down), .{ .size = 34, .soft = true });
    ui.text(std.fmt.allocPrint(cx.a(), "{d:.1}", .{@as(f32, @floatFromInt(b.temperature)) / 10}) catch "", .{ .font_size = 15, .weight = 650, .color = cx.c.text, .min_width = 34, .text_align = .center });
    kit.iconButton(cx, icons.plus, msg(.temp_up), .{ .size = 34, .soft = true });
    ui.end();
    ui.begin(.{ .direction = .row, .gap = 10 }, .{});
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    kit.field(cx, .bot_max_tokens, .{ .label = t("Max reply length (tokens)") });
    ui.end();
    ui.begin(.{ .grow = 1, .width = .fill }, .{});
    kit.field(cx, .bot_context, .{ .label = t("Messages of context") });
    ui.end();
    ui.end();
    kit.row(cx, t("Public"), .{ .switch_on = b.public, .subtitle = t("Anyone can find and chat with it"), .on = msg(.{ .toggle = .public }) });
    kit.row(cx, t("Works in groups"), .{ .switch_on = b.groups, .subtitle = t("Answers when mentioned or replied to"), .on = msg(.{ .toggle = .groups }) });
    kit.row(cx, t("Understands images"), .{ .switch_on = b.vision, .subtitle = t("Needs a vision-capable model"), .on = msg(.{ .toggle = .vision }) });
    ui.begin(.{ .padding = .{ .top = 12 }, .gap = 10 }, .{});
    kit.button(cx, if (b.id.isSet()) t("Save") else t("Create assistant"), msg(.save), .{ .block = true, .large = true, .busy = b.busy });
    if (b.id.isSet()) {
        ui.begin(.{ .direction = .row, .gap = 10 }, .{});
        kit.button(cx, t("Open chat"), msg(.{ .chat = b.id }), .{ .kind = .secondary, .icon = icons.chat });
        kit.button(cx, t("Delete"), msg(.delete), .{ .kind = .danger_ghost, .icon = icons.trash });
        ui.end();
    }
    if (b.stats.get().len > 0) ui.text(b.stats.get(), .{ .font_size = 13, .color = cx.c.text_3 });
    ui.end();
    ui.end();
    ui.end();
}

/// Choosing a model (searchable; "free" and "vision" match those tags).
pub fn modelSheet(cx: Cx) void {
    const s = cx.s;
    const ui = cx.ui;
    views.sheet(cx, t("Choose a model"));
    ui.begin(.{ .padding = .{ .start = 4, .end = 4, .bottom = 8 } }, .{});
    kit.searchBox(cx, .model_search, t("Search models (e.g. claude, gpt, llama, free)"));
    ui.end();
    const m = s.bots.models orelse {
        kit.spinner(cx);
        views.endSheet(cx);
        return;
    };
    const q = s.fields.get(.model_search).trimmed();
    var shown: usize = 0;
    for (j.arr(m.v, "models"), 0..) |mv, i| {
        const id = j.strOr(mv, "id", "");
        const name = j.strOr(mv, "name", id);
        const free = j.truthy(mv, "free");
        const vision = j.truthy(mv, "vision");
        if (q.len > 0 and !(std.ascii.findIgnoreCase(id, q) != null or std.ascii.findIgnoreCase(name, q) != null or (std.ascii.eqlIgnoreCase(q, "free") and free) or (std.ascii.eqlIgnoreCase(q, "vision") and vision))) continue;
        shown += 1;
        if (shown > 120) break;
        const on = std.mem.eql(u8, id, s.bots.model.str());
        ui.begin(.{ .gap = 3, .padding = .xy(12, 8), .radius = 12, .background = if (on) cx.c.accent_soft else null, .pressed_background = cx.c.hover }, .{ .on_press = msg(.{ .model = @intCast(i) }), .key = key(.{ "model", id }) });
        ui.text(name, .{ .font_size = 14.5, .weight = 600, .color = cx.c.text, .max_lines = 1 });
        ui.text(id, .{ .font_size = 12.5, .mono = true, .color = cx.c.text_2, .max_lines = 1 });
        var tags: std.ArrayList(u8) = .empty;
        if (free) tags.appendSlice(cx.a(), t("free")) catch {};
        if (vision) tags.print(cx.a(), "{s}{s}", .{ if (tags.items.len > 0) " · " else "", t("vision") }) catch {};
        if (j.intOr(mv, "context", 0) > 0) tags.print(cx.a(), "{s}{d}k", .{ if (tags.items.len > 0) " · " else "", @divTrunc(j.intOr(mv, "context", 0), 1000) }) catch {};
        if (tags.items.len > 0) ui.text(tags.items, .{ .font_size = 12, .color = cx.c.accent });
        ui.end();
    }
    if (q.len > 0 and shown == 0) views.menuItem(cx, icons.check, fmt.tf("Use “{id}”", .{ .id = q }), msg(.model_typed), false);
    views.endSheet(cx);
}
