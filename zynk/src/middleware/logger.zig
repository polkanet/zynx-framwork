const std = @import("std");
const context = @import("../core/context.zig");

const Context = context.Context;
const Handler = context.Handler;

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

pub fn middleware(ctx: *Context, next: Handler) !void {
    const start = nowMs();
    try next(ctx);
    const elapsed = nowMs() - start;
    const status = ctx.response.status_code;
    const colors = true;
    const color = if (colors) colorForStatus(status) else "";
    const reset = if (colors) "\x1b[0m" else "";
    const method_padded = padRight(@tagName(ctx.request.method), 7);
    std.debug.print("  {s}{s}{s} {s}{d}{s} {d}ms\n", .{
        color, method_padded, reset,
        color, status, reset,
        elapsed,
    });
}

fn padRight(s: []const u8, len: usize) []const u8 {
    if (s.len >= len) return s[0..len];
    return s;
}

fn colorForStatus(status: u16) []const u8 {
    return if (status < 200) "\x1b[37m"
    else if (status < 300) "\x1b[32m"
    else if (status < 400) "\x1b[36m"
    else if (status < 500) "\x1b[33m"
    else "\x1b[31m";
}
