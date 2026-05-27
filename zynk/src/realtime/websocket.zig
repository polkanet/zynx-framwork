const std = @import("std");
const context = @import("../core/context.zig");
const http = std.http;

const Context = context.Context;

pub const WebSocket = struct {
    allocator: std.mem.Allocator,
    ws: http.Server.WebSocket,

    pub fn send(self: *WebSocket, data: []const u8) !void {
        try self.ws.writeMessage(data, .text);
    }

    pub fn sendBinary(self: *WebSocket, data: []const u8) !void {
        try self.ws.writeMessage(data, .binary);
    }

    pub fn close(self: *WebSocket) !void {
        try self.ws.writeMessage("", .connection_close);
    }

    pub fn readMessage(self: *WebSocket) !http.Server.WebSocket.SmallMessage {
        return try self.ws.readSmallMessage();
    }
};

const UpgradeState = struct {
    handler: *const fn (*WebSocket) void,
};

pub fn upgrade(ctx: *Context, handler: *const fn (*WebSocket) void) !void {
    const state = try ctx.allocator.create(UpgradeState);
    state.* = .{ .handler = handler };
    ctx.ws_upgrade = true;
    ctx.ws_state = @ptrCast(state);
}

pub fn getHandler(ctx: *Context) ?*const fn (*WebSocket) void {
    if (ctx.ws_state) |ptr| {
        const state: *UpgradeState = @ptrCast(@alignCast(ptr));
        return state.handler;
    }
    return null;
}
