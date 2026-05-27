const std = @import("std");
const Io = std.Io;
const net = Io.net;
const http = std.http;

const context = @import("context.zig");
const router_mod = @import("../router/router.zig");
const websocket_module = @import("../realtime/websocket.zig");

const Context = context.Context;
const Request = context.Request;
const Response = context.Response;
const Method = context.Method;
const Router = router_mod.Router;

pub const ServerConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 3000,
    max_body_size: usize = 10 * 1024 * 1024,
    reuse_port: bool = true,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    router: *Router,
    running: bool = false,
    middlewares: std.ArrayList(context.MiddlewareFn),

    pub fn init(allocator: std.mem.Allocator, router: *Router) Server {
        return .{
            .allocator = allocator,
            .config = .{},
            .router = router,
            .running = false,
            .middlewares = .empty,
        };
    }

    pub fn deinit(self: *Server) void {
        self.middlewares.deinit(self.allocator);
    }

    pub fn use(self: *Server, mw: context.MiddlewareFn) !void {
        try self.middlewares.append(self.allocator, mw);
    }

    pub fn listen(self: *Server, port: u16) !void {
        self.config.port = port;
        try self.start();
    }

    pub fn listenOn(self: *Server, host: []const u8, port: u16) !void {
        self.config.host = host;
        self.config.port = port;
        try self.start();
    }

    fn start(self: *Server) !void {
        self.running = true;

        var threaded = Io.Threaded.init(
            self.allocator,
            .{
                .stack_size = std.Thread.SpawnConfig.default_stack_size,
                .async_limit = null,
                .concurrent_limit = .unlimited,
            },
        );
        defer threaded.deinit();
        const io = threaded.io();

        const address = try net.IpAddress.resolve(io, self.config.host, self.config.port);
        var tcp_server = try net.IpAddress.listen(&address, io, .{
            .reuse_address = self.config.reuse_port,
        });
        defer tcp_server.deinit(io);

        const banner =
            \\ 
            \\  ╔══════════════════════════════════════╗
            \\  ║         Zynk v0.1.0                  ║
            \\  ║  Compile fast. Serve faster.         ║
            \\  ╠══════════════════════════════════════╣
            \\
        ;
        std.debug.print("{s}", .{banner});
        std.debug.print("  ║  Listening on http://{s}:{d}", .{ self.config.host, self.config.port });
        std.debug.print("                        ║\n", .{});
        std.debug.print("  ╚══════════════════════════════════════╝\n\n", .{});

        while (self.running) {
            const stream = tcp_server.accept(io) catch |err| {
                std.debug.print("Accept error: {}\n", .{err});
                continue;
            };

            const thread = try std.Thread.spawn(.{}, handleRequest, .{
                self, stream, self.allocator,
            });
            thread.detach();
        }
    }

    fn runMiddlewareChain(ctx: *Context) anyerror!void {
        if (ctx.mw_index < ctx.mw_list.len) {
            const mw = ctx.mw_list[ctx.mw_index];
            ctx.mw_index += 1;
            try mw(ctx, runMiddlewareChain);
        } else if (ctx.mw_handler) |h| {
            try h(ctx);
        } else {
            ctx.response.status_code = 404;
            try ctx.response.body.appendSlice(ctx.allocator, "Not Found");
        }
    }

    fn handleRequest(self: *Server, stream: net.Stream, allocator: std.mem.Allocator) void {
        var recv_buf: [65536]u8 = .{0} ** 65536;
        var send_buf: [65536]u8 = .{0} ** 65536;

        var threaded = Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var connection_reader = stream.reader(io, &recv_buf);
        var connection_writer = stream.writer(io, &send_buf);
        var http_server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);


        while (true) {
            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => {
                    std.debug.print("HTTP receive error: {}\n", .{err});
                    return;
                },
            };

            const method = Method.fromString(@tagName(request.head.method)) orelse .GET;
            var path = request.head.target;
            var query = context.Query.init(allocator);
            if (std.mem.indexOfScalar(u8, path, '?')) |qpos| {
                const qs = path[qpos + 1 ..];
                path = path[0..qpos];
                var qit = std.mem.splitScalar(u8, qs, '&');
                while (qit.next()) |pair| {
                    if (pair.len == 0) continue;
                    if (std.mem.indexOfScalar(u8, pair, '=')) |epos| {
                        const k = allocator.dupe(u8, pair[0..epos]) catch continue;
                        const v = allocator.dupe(u8, pair[epos + 1 ..]) catch continue;
                        query.put(k, v) catch {};
                    } else {
                        const k = allocator.dupe(u8, pair) catch continue;
                        query.put(k, "") catch {};
                    }
                }
            }

            var headers = context.Headers.init(allocator);
            var hit = request.iterateHeaders();
            while (hit.next()) |header| {
                const kn = allocator.dupe(u8, header.name) catch continue;
                const vn = allocator.dupe(u8, header.value) catch continue;
                headers.put(kn, vn) catch {};
            }

            var body: []const u8 = "";
            if (method.hasBody()) {
                var body_buf: [8192]u8 = undefined;
                const body_reader = request.readerExpectNone(&body_buf);
                body = body_reader.readAlloc(allocator, self.config.max_body_size) catch "";
            }

            var ctx = Context.init(allocator);
            ctx.raw_request = @constCast(&request);
            ctx.request = .{
                .method = method,
                .path = path,
                .target = request.head.target,
                .version = "HTTP/1.1",
                .headers = headers,
                .query = query,
                .params = context.Params.init(allocator),
                .body = body,
                .allocator = allocator,
            };
            ctx.response = Response.init(allocator);

            ctx.mw_list = self.middlewares.items;
            ctx.mw_index = 0;
            ctx.mw_handler = null;

            if (self.router.match(method, path)) |match| {
                ctx.request.params.deinit();
                ctx.request.params = match.params;
                ctx.mw_handler = match.handler;
            }


            runMiddlewareChain(&ctx) catch |err| {
                if (ctx.response.status_code < 400) {
                    ctx.response.status_code = 500;
                    ctx.response.body.deinit(allocator);
                    ctx.response.body = .empty;
                    ctx.response.body.appendSlice(allocator, "Internal Server Error") catch {};
                }
                std.debug.print("Handler error {s} {s}: {}\n", .{ @tagName(method), path, err });
            };

            if (ctx.ws_upgrade) {
                const ws_key = ctx.header("sec-websocket-key") orelse {
                    std.debug.print("WebSocket upgrade missing sec-websocket-key\n", .{});
                    return;
                };
                const ws = request.respondWebSocket(.{ .key = ws_key }) catch |err| {
                    std.debug.print("WebSocket upgrade error: {}\n", .{err});
                    return;
                };
                var wsw = websocket_module.WebSocket{
                    .allocator = allocator,
                    .ws = ws,
                };
                if (websocket_module.getHandler(&ctx)) |h| {
                    const thread = std.Thread.spawn(.{}, struct {
                        pub fn run(h_: *const fn (*websocket_module.WebSocket) void, wsw_: *websocket_module.WebSocket) void {
                            h_(wsw_);
                        }
                    }.run, .{ h, &wsw }) catch continue;
                    thread.detach();
                }
                continue;
            }

            const status: http.Status = @enumFromInt(ctx.response.status_code);

            var extra_headers: std.ArrayList(http.Header) = .empty;
            defer extra_headers.deinit(allocator);

            var hit2 = ctx.response.headers.iterator();
            while (hit2.next()) |entry| {
                extra_headers.append(allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* }) catch {};
            }

            request.respond(ctx.response.body.items, .{
                .status = status,
                .extra_headers = extra_headers.items,
            }) catch |err| {
                std.debug.print("Response error: {}\n", .{err});
                return;
            };
        }
    }

    pub fn stop(self: *Server) void {
        self.running = false;
    }
};
