const std = @import("std");
const context = @import("../core/context.zig");

const Context = context.Context;
const Handler = context.Handler;

pub const Config = struct {
    origins: []const []const u8 = &.{"*"},
    methods: []const []const u8 = &.{ "GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS" },
    headers: []const []const u8 = &.{ "Content-Type", "Authorization", "X-Requested-With" },
    credentials: bool = false,
    max_age: u64 = 86400,
};

var config: Config = .{};

pub fn configure(cfg: Config) void {
    config = cfg;
}

pub fn middleware(ctx: *Context, next: Handler) !void {
    const origin = ctx.header("origin") orelse "*";
    _ = try ctx.response.setHeader("access-control-allow-origin", origin);
    _ = try ctx.response.setHeader("access-control-allow-methods", joinStrings(config.methods));
    _ = try ctx.response.setHeader("access-control-allow-headers", joinStrings(config.headers));
    if (config.credentials) {
        _ = try ctx.response.setHeader("access-control-allow-credentials", "true");
    }
    if (ctx.request.method == .OPTIONS) {
        ctx.response.status_code = 204;
        return;
    }
    try next(ctx);
}

fn joinStrings(strings: []const []const u8) []const u8 {
    _ = strings;
    return "*";
}
