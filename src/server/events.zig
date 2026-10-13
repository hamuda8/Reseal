//! In-process events (src/events.js). Services (webhooks, push, AI bots) react to what happens in
//! chats without the messaging code knowing about them. As in Node, subscribers run after the
//! caller has moved on and a failing subscriber never breaks the caller: each event is copied
//! into its own memory and handled by a background task.

const std = @import("std");
const A = @import("app.zig");
const webhooks = @import("webhooks.zig");
const push = @import("push.zig");
const ai = @import("ai.zig");
const val = A.val;
const Val = A.Val;
const Rq = A.Rq;

pub const Kind = enum {
    message_created,
    message_edited,
    message_deleted,
    message_reaction,
    chat_created,
    chat_updated,
    chat_deleted,
    chat_read,
    member_joined,
    member_left,
    call_started,
    call_ended,
    call_incoming,
    support_handoff,
    button_pressed,
    bot_chat_started,
};

const Job = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    payload: Val,
};

pub fn emit(a: std.mem.Allocator, kind: Kind, payload: Val) !void {
    _ = a;
    const gpa = A.app.gpa;
    const job = try gpa.create(Job);
    job.* = .{ .arena = .init(gpa), .kind = kind, .payload = undefined };
    job.payload = val.deepClone(job.arena.allocator(), payload) catch |e| {
        job.arena.deinit();
        gpa.destroy(job);
        return e;
    };
    A.spawn(run, .{job});
}

fn run(job: *Job) void {
    defer {
        job.arena.deinit();
        A.app.gpa.destroy(job);
    }
    const p = job.payload;
    // Each subscriber gets its own scope, so one failing does not stop the others.
    inline for (.{ webhooks.onEvent, push.onEvent, ai.onEvent }) |f| {
        var arena = std.heap.ArenaAllocator.init(A.app.gpa);
        defer arena.deinit();
        var r: Rq = .{ .a = arena.allocator() };
        f(&r, job.kind, p) catch |e| std.log.err("Event \"{t}\" subscriber failed: {t}", .{ job.kind, e });
    }
}
