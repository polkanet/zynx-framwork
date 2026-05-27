const std = @import("std");
const context = @import("../core/context.zig");

const Context = context.Context;
const Handler = context.Handler;

pub const Config = struct {
    requests: u32 = 100,
    window_ms: u64 = 60_000,
    ip_header: []const u8 = "x-forwarded-for",
};

fn epochMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divFloor(ts.nsec, 1_000_000)));
}

var config: Config = .{};
var allocator: ?std.mem.Allocator = null;
var entries: ?std.StringHashMap(std.ArrayList(u64)) = null;

pub fn configure(cfg: Config) void {
    config = cfg;
}

pub fn init(alloc: std.mem.Allocator) void {
    allocator = alloc;
    if (entries) |*e| {
        var it = e.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(alloc);
        }
        e.deinit();
    }
    entries = std.StringHashMap(std.ArrayList(u64)).init(alloc);
}

pub fn middleware(ctx: *Context, next: Handler) !void {
    const alloc = allocator orelse {
        try next(ctx);
        return;
    };
    const entries_map = &(entries orelse {
        try next(ctx);
        return;
    });

    const ip = ctx.header(config.ip_header) orelse "unknown";
    const now = epochMs();
    const window = config.window_ms;
    const limit = config.requests;

    const gop = try entries_map.getOrPut(alloc, ip);
    if (!gop.found_existing) {
        gop.value_ptr.* = std.ArrayList(u64).init(alloc);
    }

    const timestamps = &gop.value_ptr.*;
    while (timestamps.items.len > 0 and timestamps.items[0] < now - window) {
        _ = timestamps.orderedRemove(0);
    }

    if (timestamps.items.len >= limit) {
        ctx.response.status_code = 429;
        try ctx.response.setHeader("retry-after", "1");
        try ctx.text("Rate limit exceeded");
        return;
    }

    try timestamps.append(now);
    try next(ctx);
}
