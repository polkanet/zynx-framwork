const std = @import("std");
const context = @import("../core/context.zig");

const Context = context.Context;
const Handler = context.Handler;

pub const Config = struct {
    cookie_name: []const u8 = "_csrf_token",
    header_name: []const u8 = "x-csrf-token",
    form_field: []const u8 = "_csrf_token",
    cookie_path: []const u8 = "/",
    secure: bool = false,
    http_only: bool = true,
    same_site: []const u8 = "Strict",
    token_length: usize = 32,
};

pub const Protection = struct {
    config: Config,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Protection {
        return .{ .allocator = allocator, .config = cfg };
    }

    pub fn middleware(self: *Protection, ctx: *Context, next: Handler) !void {
        switch (ctx.request.method) {
            .GET, .HEAD, .OPTIONS => {
                const cookie = ctx.header("cookie") orelse "";
                const existing = extractCookie(cookie, self.config.cookie_name);
                if (existing == null) {
                    const token = try self.generateToken();
                    defer self.allocator.free(token);
                    try self.setCookie(ctx, token);
                }
                return try next(ctx);
            },
            else => {
                const cookie = ctx.header("cookie") orelse {
                    ctx.response.status_code = 403;
                    try ctx.response.contentType("text/plain; charset=utf-8");
                    try ctx.text("CSRF cookie missing");
                    return;
                };
                const csrf_cookie = extractCookie(cookie, self.config.cookie_name) orelse {
                    ctx.response.status_code = 403;
                    try ctx.response.contentType("text/plain; charset=utf-8");
                    try ctx.text("CSRF token missing in cookie");
                    return;
                };
                const csrf_header = ctx.header(self.config.header_name);
                if (csrf_header) |ch| {
                    if (!std.mem.eql(u8, csrf_cookie, ch)) {
                        ctx.response.status_code = 403;
                        try ctx.response.contentType("text/plain; charset=utf-8");
                        try ctx.text("CSRF token mismatch");
                        return;
                    }
                } else {
                    const body_field = try self.extractFormField(ctx);
                    if (body_field) |field| {
                        defer ctx.allocator.free(field);
                        if (!std.mem.eql(u8, csrf_cookie, field)) {
                            ctx.response.status_code = 403;
                            try ctx.response.contentType("text/plain; charset=utf-8");
                            try ctx.text("CSRF token mismatch");
                            return;
                        }
                    } else {
                        ctx.response.status_code = 403;
                        try ctx.response.contentType("text/plain; charset=utf-8");
                        try ctx.text("CSRF header missing");
                        return;
                    }
                }
                return try next(ctx);
            },
        }
    }

    fn extractFormField(self: *Protection, ctx: *Context) !?[]const u8 {
        const ct = ctx.header("content-type") orelse return null;
        if (std.ascii.indexOfIgnoreCase(ct, "application/x-www-form-urlencoded") == null) return null;
        if (ctx.request.body.len == 0) return null;
        var it = std.mem.splitScalar(u8, ctx.request.body, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                const key = pair[0..eq];
                if (std.mem.eql(u8, key, self.config.form_field)) {
                    const raw = pair[eq + 1 ..];
                    return try ctx.allocator.dupe(u8, raw);
                }
            }
        }
        return null;
    }

    fn generateToken(self: *Protection) ![]const u8 {
        var buf: [64]u8 = undefined;
        const len = @min(self.config.token_length, buf.len);
        std.crypto.random.bytes(buf[0..len]);
        return try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.bytesToHex(buf[0..len], .lower)});
    }

    fn setCookie(self: *Protection, ctx: *Context, token: []const u8) !void {
        var cookie = std.ArrayList(u8).init(ctx.allocator);
        defer cookie.deinit();
        try cookie.writer().print("{s}={s}; Path={s}; SameSite={s}", .{
            self.config.cookie_name, token, self.config.cookie_path, self.config.same_site,
        });
        if (self.config.secure) try cookie.appendSlice("; Secure");
        if (self.config.http_only) try cookie.appendSlice("; HttpOnly");
        _ = try ctx.response.setHeader("set-cookie", cookie.items);
    }
};

fn extractCookie(cookie_header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cookie_header, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.startsWith(u8, trimmed, name) and trimmed.len > name.len) {
            if (trimmed.len > name.len and trimmed[name.len] == '=') {
                const val = trimmed[name.len + 1 ..];
                if (val.len > 0) return val;
            }
        }
    }
    return null;
}
