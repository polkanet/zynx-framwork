const std = @import("std");
const context = @import("../core/context.zig");

const Context = context.Context;
const Handler = context.Handler;

pub const Config = struct {
    print_stack: bool = true,
    response_body: []const u8 = "Internal Server Error",
    content_type: []const u8 = "text/plain; charset=utf-8",
};

pub fn middleware(cfg: Config) context.MiddlewareFn {
    const Wrapper = struct {
        cfg: Config,
        pub fn handle(w: *@This(), ctx: *Context, next: Handler) !void {
            next(ctx) catch |err| {
                if (w.cfg.print_stack) {
                    std.debug.print("\n\x1b[31mRecovery caught error:\x1b[0m {}\n", .{err});
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpStackTrace(trace.*);
                    }
                }
                if (ctx.response.status_code < 400) {
                    ctx.response.status_code = 500;
                }
                ctx.response.body.deinit(ctx.allocator);
                ctx.response.body = std.ArrayList(u8).init(ctx.allocator);
                try ctx.response.body.appendSlice(ctx.allocator, w.cfg.response_body);
                _ = try ctx.response.contentType(w.cfg.content_type);
            };
        }
    };
    const wrapper = Wrapper{ .cfg = cfg };
    return struct {
        pub fn call(c: *Context, n: Handler) anyerror!void {
            return wrapper.handle(@constCast(&wrapper), c, n);
        }
    }.call;
}

pub fn defaultMiddleware() context.MiddlewareFn {
    return middleware(.{});
}
