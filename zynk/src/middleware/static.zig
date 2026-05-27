const std = @import("std");
const context = @import("../core/context.zig");

const Context = context.Context;
const Handler = context.Handler;

pub const Config = struct {
    root: []const u8 = "public",
    prefix: []const u8 = "/static",
    index_files: []const []const u8 = &.{"index.html"},
    cache_control: []const u8 = "public, max-age=3600",
    max_body: usize = 10 * 1024 * 1024,
};

pub fn middleware(cfg: Config) context.MiddlewareFn {
    const Wrapper = struct {
        cfg: Config,
        pub fn handle(w: *@This(), ctx: *Context, next: Handler) !void {
            if (!std.mem.startsWith(u8, ctx.request.path, w.cfg.prefix)) {
                return try next(ctx);
            }

            const relative = ctx.request.path[w.cfg.prefix.len..];
            if (relative.len == 0 or std.mem.eql(u8, relative, "/")) {
                for (w.cfg.index_files) |index| {
                    if (serveFile(ctx, w.cfg.root, index, w.cfg.max_body)) return;
                }
                ctx.response.status_code = 404;
                return;
            }

            const sanitized = sanitizePath(ctx.allocator, relative) catch {
                ctx.response.status_code = 400;
                return;
            };
            defer ctx.allocator.free(sanitized);

            if (sanitized.len == 0 or std.mem.eql(u8, sanitized, "/")) {
                for (w.cfg.index_files) |index| {
                    if (serveFile(ctx, w.cfg.root, index, w.cfg.max_body)) return;
                }
                ctx.response.status_code = 404;
                return;
            }

            if (serveFile(ctx, w.cfg.root, sanitized, w.cfg.max_body)) {
                _ = try ctx.response.setHeader("cache-control", w.cfg.cache_control);
            } else {
                return try next(ctx);
            }
        }
    };
    const wrapper = Wrapper{ .cfg = cfg };
    return struct {
        pub fn call(c: *Context, n: Handler) anyerror!void {
            return wrapper.handle(@constCast(&wrapper), c, n);
        }
    }.call;
}

fn serveFile(ctx: *Context, root: []const u8, rel: []const u8, max_body: usize) bool {
    const path = std.fs.path.join(ctx.allocator, &.{ root, rel }) catch return false;
    defer ctx.allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();

    const stat = file.stat() catch return false;
    if (stat.kind != .file) return false;
    if (stat.size > max_body) return false;

    const content = file.readToEndAlloc(ctx.allocator, max_body) catch return false;
    const ext = std.fs.path.extension(path);
    const mime = mimeType(ext);
    ctx.response.contentType(mime) catch {};
    ctx.response.body.appendSlice(ctx.allocator, content) catch {};
    ctx.allocator.free(content);
    return true;
}

fn sanitizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var it = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (result.items.len > 0) {
                const last = std.mem.lastIndexOfScalar(u8, result.items, '/') orelse 0;
                result.shrinkRetainingCapacity(last);
            }
            continue;
        }
        if (!first) try result.append('/');
        try result.appendSlice(seg);
        first = false;
    }
    return result.toOwnedSlice();
}

fn mimeType(ext: []const u8) []const u8 {
    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".mjs")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff")) return "font/woff";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".ttf")) return "font/ttf";
    if (std.mem.eql(u8, ext, ".otf")) return "font/otf";
    if (std.mem.eql(u8, ext, ".eot")) return "application/vnd.ms-fontobject";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, ext, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, ext, ".xml")) return "application/xml";
    if (std.mem.eql(u8, ext, ".webp")) return "image/webp";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, ".map")) return "application/json";
    return "application/octet-stream";
}
