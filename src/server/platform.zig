//! Platform settings managed from Control (settings collection, _id "platform";
//! src/services/platform.js). They override PUBLIC_APP and EARLY_ACCESS_USERS and set the
//! developer console limits, re-read every 15 seconds. On a database error the last values stay.

const std = @import("std");
const Io = std.Io;
const A = @import("app.zig");
const val = A.val;
const Val = A.Val;

pub const Settings = struct {
    public_app: bool,
    /// Lowercased; owned by the cache (copied per caller).
    early_access_users: []const []const u8,
    dev_console: bool,
    max_apps_per_owner: i64,
};

var lock: Io.Mutex = .init;
var cache_arena: ?std.heap.ArenaAllocator = null;
var cache: ?Settings = null;
var fetched_at: i64 = 0;

fn defaults() Settings {
    return .{ .public_app = A.app.config.public_app, .early_access_users = A.app.config.early_access_users, .dev_console = true, .max_apps_per_owner = 50 };
}

pub fn get() Settings {
    const io = A.app.io;
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    if (cache) |c| if (A.nowMs() - fetched_at < 15_000) return c;
    var tmp = std.heap.ArenaAllocator.init(A.app.gpa);
    defer tmp.deinit();
    const doc = A.app.col.settings.findOne(tmp.allocator(), .{ ._id = "platform" }, .{}) catch |e| {
        if (cache == null) cache = defaults();
        std.log.warn("Platform settings unavailable, keeping the last value: {t}", .{e});
        fetched_at = A.nowMs();
        return cache.?;
    };
    var next_arena = std.heap.ArenaAllocator.init(A.app.gpa);
    const na = next_arena.allocator();
    const base = defaults();
    var s = base;
    if (doc) |d| {
        if (d.get("publicApp") == .bool) s.public_app = d.get("publicApp").bool;
        if (d.get("earlyAccessUsers") == .arr) {
            var list: std.ArrayList([]const u8) = .empty;
            for (d.get("earlyAccessUsers").items()) |u| {
                const t = val.str(na, u) catch continue;
                list.append(na, std.ascii.allocLowerString(na, t) catch continue) catch {};
            }
            s.early_access_users = list.items;
        }
        if (d.get("devConsole") == .bool) s.dev_console = d.get("devConsole").bool;
        if (d.get("maxAppsPerOwner").asInt()) |n| if (n > 0) {
            s.max_apps_per_owner = n;
        };
    }
    if (cache_arena) |*old| old.deinit();
    cache_arena = next_arena;
    cache = s;
    fetched_at = A.nowMs();
    return s;
}

/// Whether this Reseal account may open the messenger before the public launch.
pub fn canOpenApp(a: std.mem.Allocator, user: ?Val) !bool {
    const s = get();
    if (s.public_app) return true;
    const u = user orelse return false;
    if (u.get("appId").truthy()) return false;
    if (u.get("isAdmin").truthy()) return true;
    const name = try std.ascii.allocLowerString(a, if (u.get("username").truthy()) try val.str(a, u.get("username")) else "");
    const wid = try std.ascii.allocLowerString(a, if (u.get("wufourId").truthy()) try val.str(a, u.get("wufourId")) else "");
    lock.lockUncancelable(A.app.io);
    defer lock.unlock(A.app.io);
    // The cached list, read under the lock (a refresh may replace it meanwhile).
    const list = if (cache) |c| c.early_access_users else s.early_access_users;
    for (list) |e| if (std.mem.eql(u8, e, name) or std.mem.eql(u8, e, wid)) return true;
    return false;
}
