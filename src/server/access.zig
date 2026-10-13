//! Who may do what in a chat (src/services/access.js).

const std = @import("std");
const A = @import("app.zig");
const v = @import("validate.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

/// Rights an admin can be given (owners have all of them).
pub const ADMIN_RIGHTS = [_][]const u8{ "changeInfo", "postMessages", "editMessages", "deleteMessages", "banUsers", "inviteUsers", "pinMessages", "manageCalls", "addAdmins", "remainAnonymous" };

/// What ordinary group members may do; admins set these per group.
pub const MEMBER_PERMISSIONS = [_][]const u8{ "sendMessages", "sendMedia", "sendVoice", "sendPolls", "sendLinks", "addMembers", "pinMessages", "changeInfo" };

pub fn defaultGroupPermissions(a: std.mem.Allocator) !Val {
    return val.from(a, .{ .sendMessages = true, .sendMedia = true, .sendVoice = true, .sendPolls = true, .sendLinks = true, .addMembers = true, .pinMessages = false, .changeInfo = false });
}

pub fn defaultAdminRights(a: std.mem.Allocator) !Val {
    return val.from(a, .{ .changeInfo = true, .postMessages = true, .editMessages = true, .deleteMessages = true, .banUsers = true, .inviteUsers = true, .pinMessages = true, .manageCalls = true, .addAdmins = false, .remainAnonymous = false });
}

fn defaultAdminRight(k: []const u8) bool {
    return !(std.mem.eql(u8, k, "addAdmins") or std.mem.eql(u8, k, "remainAnonymous"));
}

fn defaultGroupPermission(k: []const u8) bool {
    return !(std.mem.eql(u8, k, "pinMessages") or std.mem.eql(u8, k, "changeInfo"));
}

pub fn eq(x: Val, s: []const u8) bool {
    return x == .str and std.mem.eql(u8, x.str, s);
}

fn in(x: []const u8, list: []const []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// A chat or 404.
pub fn getChat(r: *Rq, chat_id: Val) !Val {
    const id = v.oid(.{ .str = try val.str(r.a, chat_id) });
    const chat = if (id) |x| try A.app.col.chats.findOne(r.a, .{ ._id = x, .deletedAt = .{ .@"$exists" = false } }, .{}) else null;
    return chat orelse r.fail(404, "Chat not found", "chat_not_found");
}

pub fn getMember(r: *Rq, chat_id: Val, user_id: Val) !?Val {
    return A.app.col.members.findOne(r.a, .{ .chatId = chat_id, .userId = user_id }, .{});
}

pub const ChatMember = struct { chat: Val, member: Val };

/// The chat plus the caller's active membership, or 404/403.
pub fn requireMember(r: *Rq, chat_id: Val, user: Val) !ChatMember {
    const chat = try getChat(r, chat_id);
    const member = try getMember(r, chat.get("_id"), user.get("_id"));
    if (member == null or !eq(member.?.get("status"), "active")) {
        // Public groups and channels can be previewed, but not used, by non-members.
        const public = chat.get("usernameLower").truthy();
        return r.fail(if (public) 403 else 404, if (public) "Join this chat first" else "Chat not found", "not_member");
    }
    return .{ .chat = chat, .member = member.? };
}

/// Whether a member may perform an action.
pub fn can(chat: Val, member: Val, action: []const u8) bool {
    if (member.isNullish() or !eq(member.get("status"), "active")) return false;
    const t = chat.get("type").asStr() orelse "";
    // Saved chats belong to one person, who may rename them.
    if (std.mem.eql(u8, t, "saved")) return !in(action, &.{ "addMembers", "banUsers", "addAdmins", "inviteUsers" });
    if (std.mem.eql(u8, t, "private") or std.mem.eql(u8, t, "bot")) return !in(action, &.{ "addMembers", "banUsers", "addAdmins", "changeInfo", "inviteUsers" });
    const role = member.get("role").asStr() orelse "";
    if (std.mem.eql(u8, role, "owner")) return true;
    if (std.mem.eql(u8, t, "support")) {
        // Support conversations: agents (admins) manage, the visitor can talk.
        if (std.mem.eql(u8, role, "admin")) return true;
        return in(action, &.{ "sendMessages", "sendMedia", "sendVoice", "sendLinks", "sendPolls" });
    }
    if (std.mem.eql(u8, role, "admin")) {
        const rights = member.get("rights");
        const right = struct {
            fn get(rs: Val, k: []const u8) bool {
                if (!rs.truthy()) return defaultAdminRight(k);
                return rs.get(k).truthy();
            }
        }.get;
        // Admins can always do what members can.
        if (in(action, &MEMBER_PERMISSIONS) and std.mem.eql(u8, t, "group")) return true;
        if (std.mem.eql(u8, t, "channel") and in(action, &.{ "sendMessages", "sendMedia", "sendVoice", "sendPolls", "sendLinks" })) return right(rights, "postMessages");
        return right(rights, action);
    }
    if (std.mem.eql(u8, t, "channel")) return false; // subscribers only read and react
    const mu = member.get("mutedUntil");
    if (mu == .date and mu.date > A.nowMs() and std.mem.startsWith(u8, action, "send")) return false;
    const perms = chat.get("permissions");
    if (perms.has(action)) return perms.get(action).truthy();
    return defaultGroupPermission(action) and in(action, &MEMBER_PERMISSIONS);
}

pub fn assertCan(r: *Rq, chat: Val, member: Val, action: []const u8, message: ?[]const u8) !void {
    if (!can(chat, member, action)) return r.fail(403, message orelse "You do not have permission to do that here", "no_permission");
}

/// Users from different apps (or an app and the public Reseal network) never meet.
pub fn sameScope(x: Val, y: Val) bool {
    const ax = x.get("appId");
    const ay = y.get("appId");
    const nx = !ax.truthy();
    const ny = !ay.truthy();
    if (nx or ny) return nx and ny;
    return val.same(ax, ay);
}

/// Has `user_id` blocked `other_id`?
pub fn isBlocked(r: *Rq, user_id: Val, other_id: Val) !bool {
    return (try A.app.col.blocks.findOne(r.a, .{ .userId = user_id, .blockedId = other_id }, .{ .projection = .{ ._id = 1 } })) != null;
}

pub fn isContact(r: *Rq, user_id: Val, other_id: Val) !bool {
    return (try A.app.col.contacts.findOne(r.a, .{ .userId = user_id, .contactId = other_id }, .{ .projection = .{ ._id = 1 } })) != null;
}

/// "Who can …" privacy rules ('everyone' | 'contacts' | 'nobody').
pub fn allowedByPrivacy(r: *Rq, target: Val, actor_id: Val, rule: []const u8) !bool {
    const setting = target.get("privacy").get(rule).asStr() orelse "everyone";
    if (val.same(target.get("_id"), actor_id)) return true;
    if (std.mem.eql(u8, setting, "everyone")) return true;
    if (std.mem.eql(u8, setting, "nobody")) return false;
    return isContact(r, target.get("_id"), actor_id);
}

/// For private chats: the other member's id.
pub fn peerOf(r: *Rq, chat: Val, user_id: Val) !Val {
    if (!eq(chat.get("type"), "private") and !eq(chat.get("type"), "bot")) return .null;
    const other = try A.app.col.members.findOne(r.a, .{ .chatId = chat.get("_id"), .userId = .{ .@"$ne" = user_id } }, .{ .projection = .{ .userId = 1 } });
    return if (other) |o| (if (o.get("userId").isNullish()) Val.null else o.get("userId")) else .null;
}

pub fn pairKey(a: std.mem.Allocator, x: Val, y: Val) ![]const u8 {
    const sx = try val.str(a, x);
    const sy = try val.str(a, y);
    return if (std.mem.order(u8, sx, sy) == .gt) std.fmt.allocPrint(a, "{s}:{s}", .{ sy, sx }) else std.fmt.allocPrint(a, "{s}:{s}", .{ sx, sy });
}
