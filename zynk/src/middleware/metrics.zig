const std = @import("std");
const context = @import("../core/context.zig");

const Context = context.Context;
const Handler = context.Handler;

pub const Metrics = struct {
    request_count: u64 = 0,
    active_requests: u64 = 0,
    status_counts: [600]u64 = [_]u64{0} ** 600,
    total_response_bytes: u64 = 0,
    start_time: i64 = 0,

    pub fn init() Metrics {
        return .{
            .start_time = epochSec(),
        };
    }

    pub fn snapshot(self: *const Metrics) MetricsSnapshot {
        return .{
            .request_count = self.request_count,
            .active_requests = self.active_requests,
            .uptime_sec = epochSec() - self.start_time,
        };
    }

    pub fn middleware(self: *Metrics, ctx: *Context, next: Handler) !void {
        self.request_count += 1;
        self.active_requests += 1;

        try next(ctx);

        self.active_requests -= 1;
        self.total_response_bytes += ctx.response.body.items.len;
        const sc = ctx.response.status_code;
        if (sc < 600) self.status_counts[sc] += 1;
    }

    fn epochSec() i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return @intCast(ts.sec);
    }
};

pub const MetricsSnapshot = struct {
    request_count: u64,
    active_requests: u64,
    uptime_sec: i64,
};
