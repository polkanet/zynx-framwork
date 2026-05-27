const std = @import("std");
const context = @import("../core/context.zig");

const Context = context.Context;
const Handler = context.Handler;

pub const Algorithm = enum {
    gzip,
    brotli,
    zstd,
    none,
};

pub const Config = struct {
    algorithms: []const Algorithm = &.{.gzip},
    level: u8 = 6,
    min_size: usize = 256,
};

pub const Compressor = struct {
    config: Config,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Compressor {
        return .{ .allocator = allocator, .config = cfg };
    }

    pub fn middleware(self: *Compressor, ctx: *Context, next: Handler) !void {
        try next(ctx);

        const accept = ctx.header("accept-encoding") orelse return;
        const algo = negotiateAlgorithm(accept);
        if (algo == .none) return;
        if (ctx.response.body.items.len < self.config.min_size) return;

        const body = ctx.response.body.items;
        switch (algo) {
            .gzip => {
                const compressed = try self.compressGzip(body);
                defer self.allocator.free(compressed);
                ctx.response.body.deinit(self.allocator);
                ctx.response.body = .empty;
                try ctx.response.body.appendSlice(self.allocator, compressed);
                _ = try ctx.response.setHeader("content-encoding", "gzip");
            },
            .brotli => {},
            .zstd => {
                return error.ZstdNotImplemented;
            },
            .none => {},
        }
    }

    fn compressGzip(self: *Compressor, data: []const u8) ![]const u8 {
        const buf = try self.allocator.alloc(u8, data.len + data.len / 4 + 128);
        var io_writer = std.Io.Writer.fixed(buf);
        const buffer = try self.allocator.alloc(u8, std.compress.flate.max_window_len);
        defer self.allocator.free(buffer);
        var comp = std.compress.flate.Compress.init(&io_writer, buffer, .gzip, .{}) catch return data;
        try comp.writer.writeAll(data);
        try comp.finish();
        const written = io_writer.buffered();
        const compressed = try self.allocator.alloc(u8, written.len);
        @memcpy(compressed, written);
        self.allocator.free(buf);
        return compressed;
    }
};

var global_compressor: ?Compressor = null;

pub fn configure(cfg: Config) void {
    if (global_compressor) |*c| {
        c.config = cfg;
    }
}

pub fn initGlobal(allocator: std.mem.Allocator, cfg: Config) void {
    global_compressor = Compressor.init(allocator, cfg);
}

pub fn middleware(ctx: *Context, next: Handler) !void {
    if (global_compressor) |*c| {
        try c.middleware(ctx, next);
    } else {
        try next(ctx);
    }
}

fn negotiateAlgorithm(accept: []const u8) Algorithm {
    if (std.mem.indexOf(u8, accept, "gzip") != null) return .gzip;
    if (std.mem.indexOf(u8, accept, "br") != null) return .brotli;
    if (std.mem.indexOf(u8, accept, "zstd") != null) return .zstd;
    return .none;
}
