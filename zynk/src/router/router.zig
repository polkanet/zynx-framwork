const std = @import("std");
const context_mod = @import("../core/context.zig");

const Method = context_mod.Method;
const Handler = context_mod.Handler;
const Context = context_mod.Context;
const MiddlewareFn = context_mod.MiddlewareFn;

pub const Match = struct {
    handler: Handler,
    params: std.StringHashMap([]const u8),
    middlewares: []const MiddlewareFn = &.{},
};

const Node = struct {
    prefix: []const u8,
    children: std.ArrayList(*Node),
    param_child: ?*Node = null,
    param_name: ?[]const u8 = null,
    wildcard_child: ?*Node = null,
    method_handlers: std.EnumMap(Method, Handler) = .{},
    middlewares: std.ArrayList(MiddlewareFn),
    is_wildcard: bool = false,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Node {
        return .{
            .prefix = "",
            .children = .empty,
            .middlewares = .empty,
            .allocator = allocator,
        };
    }

    fn getHandler(self: *const Node, method: Method) ?Handler {
        return self.method_handlers.get(method);
    }

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            if (child.param_name) |n| allocator.free(n);
            allocator.free(child.prefix);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
        if (self.param_child) |child| {
            child.deinit(allocator);
            if (child.param_name) |n| allocator.free(n);
            allocator.free(child.prefix);
            allocator.destroy(child);
        }
        if (self.wildcard_child) |child| {
            child.deinit(allocator);
            allocator.free(child.prefix);
            allocator.destroy(child);
        }
        self.middlewares.deinit(allocator);
    }
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    root: *Node,

    pub fn init(allocator: std.mem.Allocator) !Router {
        const root = try allocator.create(Node);
        root.* = Node.init(allocator);
        return .{ .allocator = allocator, .root = root };
    }

    pub fn deinit(self: *Router) void {
        self.root.deinit(self.allocator);
        self.allocator.destroy(self.root);
    }

    pub fn add(self: *Router, method: Method, path: []const u8, handler: Handler) !void {
        var node = self.root;

        if (std.mem.eql(u8, path, "/")) {
            node.method_handlers.put(method, handler);
            return;
        }

        var segments: std.ArrayList([]const u8) = .empty;
        defer segments.deinit(self.allocator);

        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (seg.len > 0) try segments.append(self.allocator, seg);
        }

        for (segments.items) |seg| {
            if (seg.len > 0 and seg[0] == ':') {
                if (node.param_child) |child| {
                    node = child;
                } else {
                    const new_node = try self.allocator.create(Node);
                    new_node.* = Node.init(self.allocator);
                    new_node.prefix = try self.allocator.dupe(u8, seg);
                    new_node.param_name = try self.allocator.dupe(u8, seg[1..]);
                    node.param_child = new_node;
                    node = new_node;
                }
            } else if (std.mem.eql(u8, seg, "*")) {
                if (node.wildcard_child) |child| {
                    node = child;
                } else {
                    const new_node = try self.allocator.create(Node);
                    new_node.* = Node.init(self.allocator);
                    new_node.prefix = try self.allocator.dupe(u8, seg);
                    new_node.is_wildcard = true;
                    node.wildcard_child = new_node;
                    node = new_node;
                }
            } else {
                node = try self.insertChild(node, seg);
            }
        }

        node.method_handlers.put(method, handler);
    }

    fn insertChild(self: *Router, parent: *Node, seg: []const u8) !*Node {
        for (parent.children.items) |child| {
            const common = commonPrefix(child.prefix, seg);
            if (common.len > 0) {
                if (common.len == child.prefix.len and common.len == seg.len) {
                    return child;
                }
                if (common.len == child.prefix.len) {
                    const remaining = seg[common.len..];
                    return self.insertChild(child, remaining);
                }
                const split = try self.allocator.create(Node);
                split.* = Node.init(self.allocator);
                split.prefix = try self.allocator.dupe(u8, child.prefix[common.len..]);
                split.children = child.children;
                split.param_child = child.param_child;
                split.wildcard_child = child.wildcard_child;
                split.method_handlers = child.method_handlers;
                split.middlewares = child.middlewares;

                child.prefix = try self.allocator.dupe(u8, child.prefix[0..common.len]);
                child.children = .empty;
                child.param_child = null;
                child.wildcard_child = null;
                child.method_handlers = .{};
                child.middlewares = .empty;

                try child.children.append(self.allocator, split);

                if (seg.len > common.len) {
                    const new_node = try self.allocator.create(Node);
                    new_node.* = Node.init(self.allocator);
                    new_node.prefix = try self.allocator.dupe(u8, seg[common.len..]);
                    try child.children.append(self.allocator, new_node);
                    return new_node;
                }
                return child;
            }
        }

        const new_node = try self.allocator.create(Node);
        new_node.* = Node.init(self.allocator);
        new_node.prefix = try self.allocator.dupe(u8, seg);
        try parent.children.append(self.allocator, new_node);
        return new_node;
    }

    pub fn match(self: *Router, method: Method, path: []const u8) ?Match {
        if (std.mem.eql(u8, path, "/")) {
            if (self.root.getHandler(method)) |handler| {
                return .{
                    .handler = handler,
                    .params = std.StringHashMap([]const u8).init(self.allocator),
                };
            }
            return null;
        }

        var params = std.StringHashMap([]const u8).init(self.allocator);

        var segments: std.ArrayList([]const u8) = .empty;
        defer segments.deinit(self.allocator);

        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (seg.len > 0) segments.append(self.allocator, seg) catch {};
        }

        // Handle root prefix matching
        if (self.root.prefix.len > 0) {
            if (segments.items.len > 0) {
                const seg = segments.items[0];
                if (std.mem.startsWith(u8, seg, self.root.prefix)) {
                    if (seg.len > self.root.prefix.len) {
                        const remaining = seg[self.root.prefix.len..];
                        const result = self.matchSubseg(self.root, method, remaining, segments.items[1..], 0, &params);
                        if (result) |handler| {
                            return .{ .handler = handler, .params = params };
                        }
                    }
                }
            }
            params.deinit();
            return null;
        }

        const result = self.matchNode(self.root, method, segments.items, 0, &params);
        if (result) |handler| {
            return .{ .handler = handler, .params = params };
        }
        params.deinit();
        return null;
    }

    fn matchNode(self: *Router, node: *Node, method: Method, segments: []const []const u8, idx: usize, params: *std.StringHashMap([]const u8)) ?Handler {
        if (idx >= segments.len) return null;

        const seg = segments[idx];
        const is_last = idx == segments.len - 1;

        for (node.children.items) |child| {
            if (std.mem.startsWith(u8, seg, child.prefix)) {
                if (std.mem.eql(u8, seg, child.prefix)) {
                    if (is_last) {
                        if (child.getHandler(method)) |h| return h;
                        return null;
                    }
                    return self.matchNode(child, method, segments, idx + 1, params);
                }
                // prefix compression: seg is longer than child.prefix
                // match remaining part of seg against child's children
                const remaining = seg[child.prefix.len..];
                return self.matchSubseg(child, method, remaining, segments, idx + 1, params);
            }
        }

        if (node.param_child) |child| {
            if (child.param_name) |name| {
                params.put(name, seg) catch {};
            }
            if (is_last) {
                if (child.getHandler(method)) |h| return h;
                return null;
            }
            return self.matchNode(child, method, segments, idx + 1, params);
        }

        if (node.wildcard_child) |child| {
            if (child.getHandler(method)) |h| return h;
            return null;
        }

        return null;
    }

    fn matchSubseg(self: *Router, node: *Node, method: Method, remaining: []const u8, segments: []const []const u8, next_idx: usize, params: *std.StringHashMap([]const u8)) ?Handler {
        for (node.children.items) |child| {
            if (std.mem.startsWith(u8, remaining, child.prefix)) {
                if (std.mem.eql(u8, remaining, child.prefix)) {
                    if (next_idx >= segments.len) {
                        if (child.getHandler(method)) |h| return h;
                        return null;
                    }
                    return self.matchNode(child, method, segments, next_idx, params);
                }
                const sub = remaining[child.prefix.len..];
                return self.matchSubseg(child, method, sub, segments, next_idx, params);
            }
        }

        if (node.param_child) |child| {
            if (child.param_name) |name| {
                params.put(name, remaining) catch {};
            }
            if (next_idx >= segments.len) {
                if (child.getHandler(method)) |h| return h;
            }
            return null;
        }

        return null;
    }
};

fn commonPrefix(a: []const u8, b: []const u8) []const u8 {
    const len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < len and a[i] == b[i]) : (i += 1) {}
    return a[0..i];
}

test "router basic" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    try router.add(.GET, "/hello", struct {
        fn h(_: *Context) !void {}
    }.h);

    try std.testing.expect(router.match(.GET, "/hello") != null);
    try std.testing.expect(router.match(.GET, "/world") == null);
}

test "router example multi" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    try router.add(.GET, "/api/json", struct { fn h(_: *Context) !void {} }.h);
    try router.add(.GET, "/api/users/:id", struct { fn h(_: *Context) !void {} }.h);
    try router.add(.GET, "/about", struct { fn h(_: *Context) !void {} }.h);
    try router.add(.GET, "/blog", struct { fn h(_: *Context) !void {} }.h);
    try router.add(.GET, "/blog/:id", struct { fn h(_: *Context) !void {} }.h);

    try std.testing.expect(router.match(.GET, "/api/json") != null);
    try std.testing.expect(router.match(.GET, "/api/users/42") != null);
    try std.testing.expect(router.match(.GET, "/about") != null);
    try std.testing.expect(router.match(.GET, "/blog") != null);
    try std.testing.expect(router.match(.GET, "/blog/1") != null);
}

test "router params" {
    const allocator = std.testing.allocator;
    var router = try Router.init(allocator);
    defer router.deinit();

    try router.add(.GET, "/users/:id", struct {
        fn h(_: *Context) !void {}
    }.h);

    const match = router.match(.GET, "/users/42");
    try std.testing.expect(match != null);
    if (match) |m| {
        const id = m.params.get("id");
        try std.testing.expect(id != null);
        try std.testing.expect(std.mem.eql(u8, id.?, "42"));
    }
}
