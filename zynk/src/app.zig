const std = @import("std");
const context = @import("core/context.zig");
const router_mod = @import("router/router.zig");
const server_mod = @import("core/server.zig");

const Context = context.Context;
const Handler = context.Handler;
const MiddlewareFn = context.MiddlewareFn;
const Method = context.Method;
const Router = router_mod.Router;

pub const App = struct {
    allocator: std.mem.Allocator,
    router: *Router,
    server: *server_mod.Server,
    middlewares: std.ArrayList(MiddlewareFn),
    config: Config,

    pub const Config = struct {
        host: []const u8 = "0.0.0.0",
        port: u16 = 3000,
        workers: usize = 1,
        name: []const u8 = "Zynk App",
    };

    pub fn init(allocator: std.mem.Allocator) !App {
        const router = try allocator.create(Router);
        router.* = try Router.init(allocator);

        const server = try allocator.create(server_mod.Server);
        server.* = server_mod.Server.init(allocator, router);

        return .{
            .allocator = allocator,
            .router = router,
            .server = server,
            .middlewares = .empty,
            .config = .{},
        };
    }

    pub fn deinit(self: *App) void {
        self.router.deinit();
        self.allocator.destroy(self.router);
        self.server.deinit();
        self.allocator.destroy(self.server);
        self.middlewares.deinit(self.allocator);
    }

    pub fn use(self: *App, mw: MiddlewareFn) !void {
        try self.middlewares.append(self.allocator, mw);
        try self.server.use(mw);
    }

    pub fn get(self: *App, path: []const u8, handler: Handler) !void {
        try self.router.add(.GET, path, handler);
    }

    pub fn post(self: *App, path: []const u8, handler: Handler) !void {
        try self.router.add(.POST, path, handler);
    }

    pub fn put(self: *App, path: []const u8, handler: Handler) !void {
        try self.router.add(.PUT, path, handler);
    }

    pub fn patch(self: *App, path: []const u8, handler: Handler) !void {
        try self.router.add(.PATCH, path, handler);
    }

    pub fn delete(self: *App, path: []const u8, handler: Handler) !void {
        try self.router.add(.DELETE, path, handler);
    }

    pub fn listen(self: *App, port: u16) !void {
        try self.server.listen(port);
    }

    pub fn listenOn(self: *App, host: []const u8, port: u16) !void {
        try self.server.listenOn(host, port);
    }

    pub fn stop(self: *App) void {
        self.server.stop();
    }

    pub fn group(self: *App, prefix: []const u8) Group {
        return Group.init(self, prefix);
    }
};

pub const Group = struct {
    app: *App,
    prefix: []const u8,

    fn init(app: *App, prefix: []const u8) Group {
        return .{ .app = app, .prefix = prefix };
    }

    pub fn get(self: Group, path: []const u8, handler: Handler) !void {
        const full = try std.fmt.allocPrint(self.app.allocator, "{s}{s}", .{ self.prefix, path });
        defer self.app.allocator.free(full);
        try self.app.get(full, handler);
    }

    pub fn post(self: Group, path: []const u8, handler: Handler) !void {
        const full = try std.fmt.allocPrint(self.app.allocator, "{s}{s}", .{ self.prefix, path });
        defer self.app.allocator.free(full);
        try self.app.post(full, handler);
    }

    pub fn put(self: Group, path: []const u8, handler: Handler) !void {
        const full = try std.fmt.allocPrint(self.app.allocator, "{s}{s}", .{ self.prefix, path });
        defer self.app.allocator.free(full);
        try self.app.put(full, handler);
    }

    pub fn delete(self: Group, path: []const u8, handler: Handler) !void {
        const full = try std.fmt.allocPrint(self.app.allocator, "{s}{s}", .{ self.prefix, path });
        defer self.app.allocator.free(full);
        try self.app.delete(full, handler);
    }
};
