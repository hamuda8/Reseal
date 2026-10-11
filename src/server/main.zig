//! Reseal server (placeholder until the port of Reseal-js lands).

const std = @import("std");
const http = @import("http");

fn healthz(ctx: *http.Context) !void {
    return ctx.sendJson(.ok, .{ .ok = true });
}

pub fn main(init: std.process.Init) !void {
    var router: http.Router = .init(init.gpa);
    defer router.deinit();
    try router.get("/healthz", healthz);
    try http.serve(init.io, init.gpa, .{ .address = try .parse("127.0.0.1", 0), .router = &router });
}
