//! Zynk Web Framework - Compile fast. Serve faster.
//!
//! A high-performance, batteries-included web framework for the Zig
//! programming language, inspired by Next.js and modern web frameworks.
//!
//! ## Features
//! - Radix tree router with path parameters
//! - Middleware pipeline (logger, CORS, compression, rate limit)
//! - SSR template engine with layouts
//! - JSON API support
//! - WebSocket support
//! - CLI toolkit (new, dev, build, generate)
//! - Auth system (JWT, sessions)
//! - Database layer (SQL query builder)
//! - Route groups
//!
//! ## Quick Start
//! ```zig
//! const zynk = @import("zynk");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!
//!     var app = try zynk.App.init(gpa.allocator());
//!     defer app.deinit();
//!
//!     app.get("/", index);
//!     try app.listen(3000);
//! }
//!
//! fn index(ctx: *zynk.Context) !void {
//!     try ctx.text("Hello from Zynk!");
//! }
//! ```

const std = @import("std");

pub const App = @import("app.zig").App;
pub const Group = @import("app.zig").Group;

pub const Context = @import("core/context.zig").Context;
pub const Request = @import("core/context.zig").Request;
pub const Response = @import("core/context.zig").Response;
pub const Method = @import("core/context.zig").Method;
pub const Handler = @import("core/context.zig").Handler;
pub const MiddlewareFn = @import("core/context.zig").MiddlewareFn;

pub const Router = @import("router/router.zig").Router;
pub const Match = @import("router/router.zig").Match;

pub const Server = @import("core/server.zig").Server;

pub const logger = @import("middleware/logger.zig").middleware;
pub const cors = @import("middleware/cors.zig").middleware;
pub const compression = @import("middleware/compression.zig").middleware;
pub const compressionModule = @import("middleware/compression.zig");
pub const rateLimit = @import("middleware/ratelimit.zig").middleware;
pub const rateLimitModule = @import("middleware/ratelimit.zig");
pub const metrics = @import("middleware/metrics.zig");
pub const staticFile = @import("middleware/static.zig");
pub const recovery = @import("middleware/recovery.zig");
pub const csrf = @import("middleware/csrf.zig");

pub const Template = @import("render/template.zig");

pub const Auth = @import("auth/auth.zig");
pub const JWT = Auth.JWT;
pub const requireAuth = Auth.requireAuth;

pub const Database = @import("db/db.zig").Database;
pub const QueryBuilder = @import("db/db.zig").QueryBuilder;
pub const WebSocket = @import("realtime/websocket.zig").WebSocket;

pub const cli = @import("cli/cli.zig");

test "basic imports" {
    _ = App;
    _ = Context;
    _ = Router;
    _ = Template;
    _ = Database;
}

test "method from string" {
    try std.testing.expect(Method.fromString("GET") == .GET);
    try std.testing.expect(Method.fromString("POST") == .POST);
    try std.testing.expect(Method.fromString("UNKNOWN") == null);
}
