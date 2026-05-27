const std = @import("std");
const builtin = @import("builtin");

pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,

    pub fn fromString(s: []const u8) ?Method {
        return std.meta.stringToEnum(Method, s);
    }

    pub fn hasBody(self: Method) bool {
        return switch (self) {
            .POST, .PUT, .PATCH => true,
            else => false,
        };
    }
};

pub const Params = std.StringHashMap([]const u8);
pub const Query = std.StringHashMap([]const u8);
pub const Headers = std.StringHashMap([]const u8);

pub const Context = struct {
    pub const Config = struct {
        max_body_size: usize = 10 * 1024 * 1024,
    };

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    request: Request,
    response: Response,
    config: Config,
    mw_index: usize = 0,
    mw_list: []const MiddlewareFn = &.{},
    mw_handler: ?Handler = null,
    raw_request: ?*anyopaque = null,
    ws_upgrade: bool = false,
    ws_state: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .request = undefined,
            .response = undefined,
            .config = .{},
        };
    }

    pub fn deinit(self: *Context) void {
        self.arena.deinit();
    }

    pub fn reset(self: *Context) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn arenaAllocator(self: *Context) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn text(self: *Context, data: []const u8) !void {
        _ = try self.response.contentType("text/plain; charset=utf-8");
        try self.response.body.appendSlice(self.allocator, data);
    }

    pub fn html(self: *Context, data: []const u8) !void {
        _ = try self.response.contentType("text/html; charset=utf-8");
        try self.response.body.appendSlice(self.allocator, data);
    }

    pub fn json(self: *Context, value: anytype) !void {
        _ = try self.response.contentType("application/json; charset=utf-8");
        const json_str = try std.fmt.allocPrint(self.allocator, "{any}", .{value});
        defer self.allocator.free(json_str);
        try self.response.body.appendSlice(self.allocator, json_str);
    }

    pub fn status(self: *Context, code: u16) *Context {
        self.response.status_code = code;
        return self;
    }

    pub fn redirect(self: *Context, location: []const u8, code: u16) !void {
        self.response.status_code = code;
        _ = try self.response.setHeader("location", location);
    }

    pub fn param(self: *Context, key: []const u8) ?[]const u8 {
        return self.request.params.get(key);
    }

    pub fn query(self: *Context, key: []const u8) ?[]const u8 {
        return self.request.query.get(key);
    }

    pub fn header(self: *Context, name: []const u8) ?[]const u8 {
        var it = self.request.headers.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }

    pub fn jsonBody(self: *Context, comptime T: type) !T {
        if (self.request.body.len == 0) return error.EmptyBody;
        var parsed = try std.json.parseFromSlice(T, self.allocator, self.request.body, .{});
        defer parsed.deinit();
        return parsed.value;
    }

    pub fn formBody(self: *Context) !std.StringHashMap([]const u8) {
        var map = std.StringHashMap([]const u8).init(self.allocator);
        if (self.request.body.len == 0) return map;
        var it = std.mem.splitScalar(u8, self.request.body, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                const raw_key = pair[0..eq];
                const raw_val = pair[eq + 1 ..];
                const key = try percentDecode(self.allocator, raw_key);
                const val = try percentDecode(self.allocator, raw_val);
                try map.put(key, val);
            } else {
                const key = try percentDecode(self.allocator, pair);
                try map.put(key, "");
            }
        }
        return map;
    }

    pub fn sendFile(self: *Context, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);
        const ext = std.fs.path.extension(path);
        _ = try self.response.contentType(mimeTypeFromExt(ext));
        try self.response.body.appendSlice(self.allocator, content);
    }

    pub fn sendFileWithMax(self: *Context, path: []const u8, max_size: usize) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const content = try file.readToEndAlloc(self.allocator, max_size);
        defer self.allocator.free(content);
        const ext = std.fs.path.extension(path);
        _ = try self.response.contentType(mimeTypeFromExt(ext));
        try self.response.body.appendSlice(self.allocator, content);
    }
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    target: []const u8,
    version: []const u8,
    headers: Headers,
    query: Query,
    params: Params,
    body: []const u8,
    allocator: std.mem.Allocator,
};

pub const Response = struct {
    status_code: u16 = 200,
    body: std.ArrayList(u8),
    headers: Headers,
    allocator: std.mem.Allocator,
    sent: bool = false,

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .body = .empty,
            .headers = Headers.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Response) void {
        var it = self.headers.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.headers.deinit();
        self.body.deinit(self.allocator);
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !*Response {
        const key = try self.allocator.dupe(u8, name);
        const val = try self.allocator.dupe(u8, value);
        self.headers.put(key, val) catch {
            self.allocator.free(key);
            self.allocator.free(val);
            return error.OutOfMemory;
        };
        return self;
    }

    pub fn contentType(self: *Response, ct: []const u8) !*Response {
        return self.setHeader("content-type", ct);
    }
};

pub const Handler = *const fn (*Context) anyerror!void;

pub const MiddlewareFn = *const fn (*Context, Handler) anyerror!void;

pub const Route = struct {
    method: Method,
    pattern: []const u8,
    handler: Handler,
    middlewares: []const MiddlewareFn = &.{},
    name: ?[]const u8 = null,
};

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    errdefer result.deinit();
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '+') {
            try result.append(' ');
        } else if (c == '%' and i + 2 < input.len) {
            const hi = try std.fmt.charToDigit(input[i + 1], 16);
            const lo = try std.fmt.charToDigit(input[i + 2], 16);
            try result.append(@as(u8, @intCast(hi * 16 + lo)));
            i += 2;
        } else {
            try result.append(c);
        }
    }
    return result.toOwnedSlice();
}

fn mimeTypeFromExt(ext: []const u8) []const u8 {
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
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".woff")) return "font/woff";
    if (std.mem.eql(u8, ext, ".ttf")) return "font/ttf";
    return "application/octet-stream";
}
