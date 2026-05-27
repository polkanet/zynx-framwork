const std = @import("std");
const zynk = @import("zynk");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var app = try zynk.App.init(allocator);
    defer app.deinit();

    try app.use(zynk.logger);
    try app.use(zynk.cors);

    try app.get("/", index);
    try app.get("/style.css", serveStyle);
    try app.get("/hello/:name", hello);
    try app.get("/api/json", apiJson);
    try app.get("/api/users/:id", apiUser);
    try app.get("/about", about);
    try app.get("/blog", blog);
    try app.get("/blog/:id", blogPost);

    var api = app.group("/api/v1");
    try api.get("/status", status);
    try api.get("/echo/:msg", echo);

    std.debug.print("Starting example on http://localhost:3000\n", .{});
    try app.listen(3000);
}

fn serveStyle(ctx: *zynk.Context) !void {    _ = try ctx.response.contentType("text/css; charset=utf-8");
    try ctx.response.body.appendSlice(ctx.allocator,
        \\* { margin:0; padding:0; box-sizing:border-box; }
        \\body {
        \\  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        \\  background: #0a0a1a;
        \\  color: #e0e0e0;
        \\  line-height: 1.6;
        \\  min-height: 100vh;
        \\}
        \\nav {
        \\  background: linear-gradient(135deg, #1a1a3e 0%, #2d1b69 100%);
        \\  padding: 1rem 2rem;
        \\  display: flex;
        \\  gap: 1.5rem;
        \\  border-bottom: 1px solid rgba(255,255,255,0.05);
        \\}
        \\nav a { color: #b8b8ff; text-decoration: none; font-weight: 500; }
        \\nav a:hover { color: #fff; }
        \\main { padding: 2rem; max-width: 800px; margin: 0 auto; }
        \\.card {
        \\  background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
        \\  border: 1px solid rgba(255,255,255,0.08);
        \\  border-radius: 12px;
        \\  padding: 2rem;
        \\  margin-bottom: 1.5rem;
        \\}
        \\.card h1 { font-size: 2rem; margin-bottom: 0.5rem; background: linear-gradient(90deg, #667eea, #764ba2); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
        \\.card h2 { font-size: 1.3rem; margin-bottom: 0.5rem; }
        \\.card h2 a { color: #b8b8ff; text-decoration: none; }
        \\.card h2 a:hover { color: #fff; }
        \\.card p { color: #a0a0c0; margin-bottom: 0.5rem; }
        \\.subtitle { font-size: 1.1rem; color: #8888bb; margin-bottom: 1rem; }
        \\.features { display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem; margin: 1.5rem 0; }
        \\.feature { background: rgba(102,126,234,0.1); border: 1px solid rgba(102,126,234,0.2); border-radius: 8px; padding: 0.75rem; font-size: 0.9rem; }
        \\.btn {
        \\  display: inline-block; background: linear-gradient(90deg, #667eea, #764ba2);
        \\  color: #fff; padding: 0.6rem 1.5rem; border-radius: 8px; text-decoration: none;
        \\  font-weight: 600; margin-top: 1rem; transition: transform 0.1s, box-shadow 0.2s;
        \\}
        \\.btn:hover { transform: translateY(-1px); box-shadow: 0 4px 15px rgba(102,126,234,0.4); }
        \\a { color: #667eea; }
    );
}

fn index(ctx: *zynk.Context) !void {
    try ctx.html(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>Zynk Example</title><link rel="stylesheet" href="/style.css"></head>
        \\<body>
        \\  <nav><a href="/">Home</a> <a href="/about">About</a> <a href="/blog">Blog</a> <a href="/api/json">API</a></nav>
        \\  <main>
        \\    <div class="card">
        \\      <h1>Zynk Web Framework</h1>
        \\      <p class="subtitle">Compile fast. Serve faster.</p>
        \\      <p>A high-performance web framework for the Zig programming language.</p>
        \\      <div class="features">
        \\        <div class="feature">⚡ Radix-tree router</div>
        \\        <div class="feature">🔌 Middleware pipeline</div>
        \\        <div class="feature">📝 SSR templates</div>
        \\        <div class="feature">🔐 JWT auth</div>
        \\      </div>
        \\      <a class="btn" href="/hello/Zynk">Say Hello</a>
        \\    </div>
        \\  </main>
        \\</body>
        \\</html>
    );
}

fn hello(ctx: *zynk.Context) !void {
    const name = ctx.param("name") orelse "World";
    try ctx.html(
        try std.fmt.allocPrint(ctx.allocator,
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>Hello {s}</title><link rel="stylesheet" href="/style.css"></head>
            \\<body>
            \\  <nav><a href="/">Home</a> <a href="/about">About</a> <a href="/blog">Blog</a></nav>
            \\  <main>
            \\    <div class="card">
            \\      <h1>Hello, {s}!</h1>
            \\      <p>Welcome to Zynk.</p>
            \\      <a class="btn" href="/">Back Home</a>
            \\    </div>
            \\  </main>
            \\</body>
            \\</html>
        , .{ name, name }),
    );
}

fn apiJson(ctx: *zynk.Context) !void {
    try ctx.json(.{
        .app = "Zynk",
        .version = "0.1.0",
    });
}

fn apiUser(ctx: *zynk.Context) !void {
    const id = ctx.param("id") orelse "0";
    try ctx.json(.{
        .id = id,
        .name = try std.fmt.allocPrint(ctx.allocator, "User {s}", .{id}),
    });
}

fn about(ctx: *zynk.Context) !void {
    try ctx.html(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>About Zynk</title><link rel="stylesheet" href="/style.css"></head>
        \\<body>
        \\  <nav><a href="/">Home</a> <a href="/about">About</a> <a href="/blog">Blog</a></nav>
        \\  <main>
        \\    <div class="card">
        \\      <h1>About Zynk</h1>
        \\      <p>A Next.js-inspired web framework for the Zig programming language.</p>
        \\      <p class="subtitle">Version <strong>0.1.0</strong></p>
        \\    </div>
        \\  </main>
        \\</body>
        \\</html>
    );
}

fn blog(ctx: *zynk.Context) !void {
    const items = try std.fmt.allocPrint(ctx.allocator,
        \\<div class="card"><h2><a href="/blog/1">Getting Started</a></h2><p>Introduction to Zynk and its features.</p></div>
        \\<div class="card"><h2><a href="/blog/2">Routing Deep Dive</a></h2><p>Understanding the radix-tree router.</p></div>
    , .{});
    defer ctx.allocator.free(items);

    try ctx.html(
        try std.fmt.allocPrint(ctx.allocator,
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>Blog</title><link rel="stylesheet" href="/style.css"></head>
            \\<body>
            \\  <nav><a href="/">Home</a></nav>
            \\  <main>
            \\    <h1>Blog</h1>
            \\    {s}
            \\  </main>
            \\</body>
            \\</html>
        , .{items}),
    );
}

fn blogPost(ctx: *zynk.Context) !void {
    const id = ctx.param("id") orelse "0";
    const names = [_][]const u8{ "Getting Started", "Routing Deep Dive" };
    const idx = if (std.mem.eql(u8, id, "1")) @as(usize, 0) else if (std.mem.eql(u8, id, "2")) @as(usize, 1) else @as(usize, 0);
    const title = names[idx];
    try ctx.html(
        try std.fmt.allocPrint(ctx.allocator,
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>Blog Post #{s}</title><link rel="stylesheet" href="/style.css"></head>
            \\<body>
            \\  <nav><a href="/">Home</a> <a href="/blog">Blog</a></nav>
            \\  <main>
            \\    <div class="card">
            \\      <h1>{s}</h1>
            \\      <p class="subtitle">Blog Post #{s}</p>
            \\      <p>This is the content of the blog post. Zynk makes building web apps in Zig fast and fun.</p>
            \\      <a class="btn" href="/blog">← Back to Blog</a>
            \\    </div>
            \\  </main>
            \\</body>
            \\</html>
        , .{ id, title, id }),
    );
}

fn status(ctx: *zynk.Context) !void {
    try ctx.json(.{ .status = "ok", .service = "api-v1" });
}

fn echo(ctx: *zynk.Context) !void {
    const msg = ctx.param("msg") orelse "nothing";
    try ctx.json(.{ .echo = msg });
}
