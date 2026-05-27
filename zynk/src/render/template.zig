const std = @import("std");
const context = @import("../core/context.zig");

const Context = context.Context;

allocator: std.mem.Allocator,
templates: std.StringHashMap([]const u8),
dir: []const u8,

pub const Engine = @This();

pub fn init(allocator: std.mem.Allocator, dir: []const u8) Engine {
    return .{
        .allocator = allocator,
        .templates = std.StringHashMap([]const u8).init(allocator),
        .dir = dir,
    };
}

pub fn deinit(self: *Engine) void {
    var it = self.templates.valueIterator();
    while (it.next()) |val| self.allocator.free(val.*);
    self.templates.deinit();
}

pub fn load(self: *Engine, name: []const u8) ![]const u8 {
    if (self.templates.get(name)) |cached| return cached;
    const path = try std.fs.path.join(self.allocator, &.{ self.dir, name });
    defer self.allocator.free(path);
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Template not found: {s} ({})\n", .{ path, err });
        return error.TemplateNotFound;
    };
    defer file.close();
    const content = try file.readToEndAlloc(self.allocator, 1_000_000);
    try self.templates.put(name, content);
    return content;
}

pub fn render(self: *Engine, ctx: *Context, name: []const u8) !void {
    const source = try self.load(name);
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(self.allocator);
    try self.renderTemplate(&result, source, ctx);
    try ctx.response.body.appendSlice(self.allocator, result.items);
    _ = try ctx.response.contentType("text/html; charset=utf-8");
}

fn renderTemplate(self: *Engine, dest: *std.ArrayList(u8), source: []const u8, ctx: *Context) !void {
    var pos: usize = 0;
    while (pos < source.len) {
        const var_start = std.mem.indexOfPos(u8, source, pos, "{{");
        const block_start = std.mem.indexOfPos(u8, source, pos, "{%");
        const next = if (var_start) |vs| if (block_start) |bs| @min(vs, bs) else vs else if (block_start) |bs| bs else source.len;
        try dest.appendSlice(self.allocator, source[pos..next]);
        if (next >= source.len) break;
        if (var_start != null and var_start.? == next) {
            const close = std.mem.indexOfPos(u8, source, next + 2, "}}") orelse {
                try dest.appendSlice(self.allocator, source[next..]);
                break;
            };
            const expr = std.mem.trim(u8, source[next + 2 .. close], " \t");
            try self.renderExpr(dest, expr, ctx);
            pos = close + 2;
        } else if (block_start != null and block_start.? == next) {
            const close = std.mem.indexOfPos(u8, source, next + 2, "%}") orelse {
                try dest.appendSlice(self.allocator, source[next..]);
                break;
            };
            const tag = std.mem.trim(u8, source[next + 2 .. close], " \t");
            pos = close + 2;
            if (std.mem.startsWith(u8, tag, "if ")) {
                const cond = tag["if ".len..];
                const endif = findBlockEnd(source, pos, "if ") orelse {
                    try dest.appendSlice(self.allocator, source[next..]);
                    break;
                };
                const else_pos = std.mem.indexOf(u8, source[pos..endif], "{% else %}");
                const cond_true = self.evalCondition(cond, ctx);
                if (cond_true) {
                    const src = source[pos .. pos + (else_pos orelse (endif - pos))];
                    try self.renderTemplate(dest, src, ctx);
                } else if (else_pos) |ep| {
                    const src = source[pos + ep + "{% else %}".len .. endif];
                    try self.renderTemplate(dest, src, ctx);
                }
                pos = endif + "{% endif %}".len;
            } else if (std.mem.startsWith(u8, tag, "include ")) {
                const inc = std.mem.trim(u8, tag["include ".len..], "\" \t'");
                const src = try self.load(inc);
                try self.renderTemplate(dest, src, ctx);
            } else if (std.mem.startsWith(u8, tag, "block ")) {
                const end = findBlockEnd(source, pos, "block") orelse {
                    try dest.appendSlice(self.allocator, source[next..]);
                    break;
                };
                const src = source[pos..end];
                try self.renderTemplate(dest, src, ctx);
                pos = end + "{% endblock %}".len;
            } else if (std.mem.startsWith(u8, tag, "for ")) {
                const end = findBlockEnd(source, pos, "for") orelse {
                    try dest.appendSlice(self.allocator, source[next..]);
                    break;
                };
                const inner = source[pos..end];
                try self.renderFor(dest, tag["for ".len..], inner, ctx);
                pos = end + "{% endfor %}".len;
            }
        }
    }
}

fn renderExpr(self: *Engine, dest: *std.ArrayList(u8), expr: []const u8, ctx: *Context) !void {
    _ = self;
    if (ctx.request.params.get(expr)) |v| { try dest.appendSlice(ctx.allocator, v); return; }
    if (ctx.request.query.get(expr)) |v| { try dest.appendSlice(ctx.allocator, v); return; }
    try dest.appendSlice(ctx.allocator, expr);
}

fn evalCondition(self: *Engine, expr: []const u8, ctx: *Context) bool {
    _ = self;
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (std.mem.eql(u8, trimmed, "true")) return true;
    if (std.mem.eql(u8, trimmed, "false")) return false;
    if (ctx.request.params.get(trimmed) != null) return true;
    if (ctx.request.query.get(trimmed) != null) return true;
    return false;
}

fn findBlockEnd(source: []const u8, start: usize, tag: []const u8) ?usize {
    const end_tag = if (std.mem.eql(u8, tag, "if ")) "{% endif %}"
    else if (std.mem.eql(u8, tag, "for ")) "{% endfor %}"
    else "{% endblock %}";
    var depth: usize = 1;
    var pos = start;
    while (pos < source.len) {
        const end_pos = std.mem.indexOfPos(u8, source, pos, end_tag) orelse return null;
        const start_tag = if (std.mem.eql(u8, tag, "if ")) std.mem.indexOfPos(u8, source, pos, "{% if ")
        else null;
        if (start_tag != null and start_tag.? < end_pos) {
            depth += 1;
            pos = start_tag.? + 5;
        } else {
            depth -= 1;
            if (depth == 0) return end_pos;
            pos = end_pos + end_tag.len;
        }
    }
    return null;
}

fn renderFor(self: *Engine, dest: *std.ArrayList(u8), tag: []const u8, inner: []const u8, ctx: *Context) !void {
    const in_pos = std.mem.indexOf(u8, tag, " in ") orelse return;
    const var_name = std.mem.trim(u8, tag[0..in_pos], " \t");
    const collection_expr = std.mem.trim(u8, tag[in_pos + 4 ..], " \t");

    const else_pos = std.mem.indexOf(u8, inner, "{% else %}");

    const raw = ctx.request.params.get(collection_expr) orelse
        ctx.request.query.get(collection_expr) orelse {
        if (else_pos) |ep| {
            const else_src = inner[ep + "{% else %}".len ..];
            try self.renderTemplate(dest, else_src, ctx);
        }
        return;
    };

    if (raw.len == 0) {
        if (else_pos) |ep| {
            const else_src = inner[ep + "{% else %}".len ..];
            try self.renderTemplate(dest, else_src, ctx);
        }
        return;
    }

    const loop_src = if (else_pos) |ep| inner[0..ep] else inner;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t");
        const prev = try ctx.request.params.get(var_name);
        try ctx.request.params.put(var_name, trimmed);
        try self.renderTemplate(dest, loop_src, ctx);
        if (prev) |p| {
            try ctx.request.params.put(var_name, p);
        } else {
            _ = ctx.request.params.remove(var_name);
        }
    }
}
