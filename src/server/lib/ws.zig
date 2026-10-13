//! A WebSocket connection after zig-core's handshake (RFC 6455), as Reseal-js's own
//! ws/websocket.js behaved: messages up to 512 KiB, fragmented messages, ping/pong keep-alive,
//! and clean closing. zig-core's ws.Socket reads one unfragmented frame that fits its read
//! buffer; call signalling (SDP offers) can be larger, so reading is done here.
//!
//! Sends never block the caller: frames go into a queue that the connection's own writer task
//! drains, so fan-out to many sockets under a lock stays cheap, and a client that stops reading
//! is dropped once 16 MiB are waiting (as Node's version did).

const std = @import("std");
const Io = std.Io;

pub const Op = enum(u4) { continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10, _ };

pub const Message = struct { op: Op, data: []const u8 };

const Out = struct { op: Op, data: []u8 };

pub const Peer = struct {
    io: Io,
    gpa: std.mem.Allocator,
    in: *Io.Reader,
    out: *Io.Writer,
    stream: Io.net.Stream,
    max_payload: usize = 512 * 1024,
    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList(Out) = .empty,
    queued_bytes: usize = 0,
    closing: bool = false,
    closed: std.atomic.Value(bool) = .init(false),
    /// Last time any control frame arrived (ms); proves the peer is alive.
    last_pong: std.atomic.Value(i64) = .init(0),

    /// Queues a frame. False when the connection is closed (or was just dropped for not reading).
    pub fn send(p: *Peer, op: Op, data: []const u8) bool {
        p.lock.lockUncancelable(p.io);
        defer p.lock.unlock(p.io);
        if (p.closing) return false;
        if (p.queued_bytes > 16 * 1024 * 1024) {
            p.terminateLocked();
            return false;
        }
        const copy = p.gpa.dupe(u8, data) catch return false;
        p.queue.append(p.gpa, .{ .op = op, .data = copy }) catch {
            p.gpa.free(copy);
            return false;
        };
        p.queued_bytes += copy.len;
        p.cond.signal(p.io);
        return true;
    }

    pub fn sendText(p: *Peer, data: []const u8) bool {
        return p.send(.text, data);
    }

    /// Sends a close frame, then hangs up.
    pub fn close(p: *Peer, code: u16) void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, code, .big);
        _ = p.send(.close, &payload);
        p.lock.lockUncancelable(p.io);
        defer p.lock.unlock(p.io);
        p.closing = true;
        p.cond.signal(p.io);
    }

    /// Drops the connection at once (dead or flooding peers).
    pub fn terminate(p: *Peer) void {
        p.lock.lockUncancelable(p.io);
        defer p.lock.unlock(p.io);
        p.terminateLocked();
    }

    fn terminateLocked(p: *Peer) void {
        p.closing = true;
        p.closed.store(true, .release);
        p.stream.shutdown(p.io, .both) catch {};
        p.cond.signal(p.io);
    }

    /// The writer task: writes queued frames until the connection closes.
    pub fn writerLoop(p: *Peer) void {
        var batch: std.ArrayList(Out) = .empty;
        defer batch.deinit(p.gpa);
        while (true) {
            p.lock.lockUncancelable(p.io);
            while (p.queue.items.len == 0 and !p.closing) p.cond.waitUncancelable(p.io, &p.lock);
            const done = p.closing;
            std.mem.swap(std.ArrayList(Out), &batch, &p.queue);
            p.queued_bytes = 0;
            p.lock.unlock(p.io);
            var failed = p.closed.load(.acquire);
            for (batch.items) |f| {
                if (!failed) writeFrame(p.out, f.op, f.data) catch {
                    failed = true;
                };
                p.gpa.free(f.data);
            }
            batch.clearRetainingCapacity();
            if (!failed) p.out.flush() catch {
                failed = true;
            };
            if (failed or done) {
                p.lock.lockUncancelable(p.io);
                // Anything queued meanwhile is freed by `deinit`.
                p.closing = true;
                p.lock.unlock(p.io);
                if (done or failed) {
                    p.closed.store(true, .release);
                    p.stream.shutdown(p.io, .both) catch {};
                }
                return;
            }
        }
    }

    /// Frees anything still queued; call after the writer task finished.
    pub fn deinit(p: *Peer) void {
        for (p.queue.items) |f| p.gpa.free(f.data);
        p.queue.deinit(p.gpa);
    }

    /// The next whole message (text or binary). Control frames are handled here. `buf` holds
    /// the payload; it is reused by the next call.
    pub fn read(p: *Peer, buf: *std.ArrayList(u8), now_ms: i64) !Message {
        buf.clearRetainingCapacity();
        var first: ?Op = null;
        while (true) {
            const h = p.in.takeArray(2) catch return error.Closed;
            const fin = h[0] & 0x80 != 0;
            const rsv = h[0] & 0x70;
            const op: Op = @fromBackingInt(@intCast(@as(u4, @truncate(h[0]))));
            const masked = h[1] & 0x80 != 0;
            var len: u64 = h[1] & 0x7f;
            if (rsv != 0) return p.protocolError(1002);
            if (!masked) return p.protocolError(1002);
            if (len == 126) len = p.in.takeInt(u16, .big) catch return error.Closed;
            if (len == 127) len = p.in.takeInt(u64, .big) catch return error.Closed;
            if (len > p.max_payload) return p.protocolError(1009);
            const mask = (p.in.takeArray(4) catch return error.Closed).*;
            const n: usize = @intCast(len);

            if (@backingInt(op) >= 8) {
                if (!fin or n > 125) return p.protocolError(1002);
                var ctl: [125]u8 = undefined;
                p.in.readSliceAll(ctl[0..n]) catch return error.Closed;
                for (ctl[0..n], 0..) |*b, i| b.* ^= mask[i % 4];
                p.last_pong.store(now_ms, .release);
                switch (op) {
                    .ping => _ = p.send(.pong, ctl[0..n]),
                    .pong => {},
                    .close => {
                        // Answer with the same code, then hang up.
                        _ = p.send(.close, if (n >= 2) ctl[0..2] else &.{});
                        p.lock.lockUncancelable(p.io);
                        p.closing = true;
                        p.cond.signal(p.io);
                        p.lock.unlock(p.io);
                        return error.Closed;
                    },
                    else => return p.protocolError(1002),
                }
                continue;
            }

            const start = buf.items.len;
            if (start + n > p.max_payload) return p.protocolError(1009);
            try buf.resize(p.gpa, start + n);
            p.in.readSliceAll(buf.items[start..]) catch return error.Closed;
            for (buf.items[start..], 0..) |*b, i| b.* ^= mask[i % 4];

            switch (op) {
                .continuation => if (first == null) return p.protocolError(1002),
                .text, .binary => {
                    if (first != null) return p.protocolError(1002);
                    first = op;
                },
                else => return p.protocolError(1002),
            }
            if (fin) {
                const kind = first.?;
                if (kind == .text and !std.unicode.utf8ValidateSlice(buf.items)) return p.protocolError(1007);
                return .{ .op = kind, .data = buf.items };
            }
        }
    }

    fn protocolError(p: *Peer, code: u16) error{Closed} {
        p.close(code);
        return error.Closed;
    }
};

fn writeFrame(w: *Io.Writer, op: Op, data: []const u8) !void {
    var hdr: [10]u8 = undefined;
    hdr[0] = 0x80 | @as(u8, @backingInt(op));
    var n: usize = 2;
    if (data.len < 126) {
        hdr[1] = @intCast(data.len);
    } else if (data.len <= 0xffff) {
        hdr[1] = 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(data.len), .big);
        n = 4;
    } else {
        hdr[1] = 127;
        std.mem.writeInt(u64, hdr[2..10], data.len, .big);
        n = 10;
    }
    try w.writeAll(hdr[0..n]);
    try w.writeAll(data);
}
