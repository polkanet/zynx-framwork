const std = @import("std");

pub const Command = enum {
    new,
    dev,
    build,
    generate,
    help,
    version,
};

pub const Args = struct {
    command: Command,
    name: ?[]const u8 = null,
    args: [][]const u8 = &.{},
};

pub fn parseArgs(allocator: std.mem.Allocator) !Args {
    const cmd_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, cmd_args);

    if (cmd_args.len < 2) return .{ .command = .help };

    const cmd = cmd_args[1];
    const command = CommandFromString(cmd) orelse .help;

    var result = Args{ .command = command };
    if (cmd_args.len > 2) result.name = cmd_args[2];
    if (cmd_args.len > 3) result.args = cmd_args[3..];

    return result;
}

fn CommandFromString(s: []const u8) ?Command {
    if (std.mem.eql(u8, s, "new")) return .new;
    if (std.mem.eql(u8, s, "dev")) return .dev;
    if (std.mem.eql(u8, s, "build")) return .build;
    if (std.mem.eql(u8, s, "generate")) return .generate;
    if (std.mem.eql(u8, s, "g")) return .generate;
    if (std.mem.eql(u8, s, "help")) return .help;
    if (std.mem.eql(u8, s, "--help")) return .help;
    if (std.mem.eql(u8, s, "-h")) return .help;
    if (std.mem.eql(u8, s, "version")) return .version;
    if (std.mem.eql(u8, s, "--version")) return .version;
    if (std.mem.eql(u8, s, "-v")) return .version;
    return null;
}

pub fn printHelp() void {
    std.debug.print(
        \\Zynk CLI v0.1.0 - Compile fast. Serve faster.
        \\
        \\USAGE:
        \\  zynk <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\  new       <name>    Create a new Zynk project
        \\  dev                 Start development server
        \\  build               Build for production
        \\  generate  <type>    Generate code (route, controller, etc.)
        \\  help                Show this help
        \\  version             Show version
        \\
        \\EXAMPLES:
        \\  zynk new myapp
        \\  zynk dev
        \\  zynk build
        \\  zynk generate route users
        \\
    ,
    );
}

pub fn printVersion() void {
    std.debug.print("Zynk v0.1.0\n", .{});
}

pub fn createProject(allocator: std.mem.Allocator, name: []const u8) !void {
    const project_name = if (name.len > 0) name else "myapp";

    std.debug.print("Creating new Zynk project: {s}...\n", .{project_name});

    // Create directory structure
    const dirs = [_][]const u8{
        project_name,
        try std.fs.path.join(allocator, &.{ project_name, "src" }),
        try std.fs.path.join(allocator, &.{ project_name, "src", "routes" }),
        try std.fs.path.join(allocator, &.{ project_name, "src", "controllers" }),
        try std.fs.path.join(allocator, &.{ project_name, "src", "middleware" }),
        try std.fs.path.join(allocator, &.{ project_name, "src", "models" }),
        try std.fs.path.join(allocator, &.{ project_name, "src", "views" }),
        try std.fs.path.join(allocator, &.{ project_name, "src", "public" }),
        try std.fs.path.join(allocator, &.{ project_name, "migrations" }),
        try std.fs.path.join(allocator, &.{ project_name, "tests" }),
    };
    defer {
        for (dirs[1..]) |d| allocator.free(d);
    }

    const dir = std.fs.cwd();
    for (dirs) |d| {
        dir.makeDir(d) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    // Create build.zig
    const build_zig = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const zynk_mod = b.createModule(.{{
        \\        .root_source_file = b.path("path/to/zynk/src/zynk.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\
        \\    const exe = b.addExecutable(.{{
        \\        .name = "{s}",
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\            .imports = &.{{ .{{ .name = "zynk", .module = zynk_mod }} }},
        \\        }}),
        \\    }});
        \\    b.installArtifact(exe);
        \\
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    run_cmd.step.dependOn(b.getInstallStep());
        \\    if (b.args) |args| run_cmd.addArgs(args);
        \\
        \\    const run_step = b.step("run", "Run the app");
        \\    run_step.dependOn(&run_cmd.step);
        \\}}
        \\
    , .{project_name});
    defer allocator.free(build_zig);

    const build_path = try std.fs.path.join(allocator, &.{ project_name, "build.zig" });
    defer allocator.free(build_path);
    try dir.writeFile(build_path, build_zig);

    // Create main.zig
    const main_zig =
        \\const std = @import("std");
        \\const zynk = @import("zynk");
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\    const allocator = gpa.allocator();
        \\
        \\    var app = try zynk.App.init(allocator);
        \\    defer app.deinit();
        \\
        \\    app.use(zynk.logger);
        \\    app.use(zynk.cors);
        \\
        \\    app.get("/", index);
        \\    app.get("/hello/:name", hello);
        \\
        \\    try app.listen(3000);
        \\}
        \\
        \\fn index(ctx: *zynk.Context) !void {
        \\    try ctx.text("Hello from Zynk!");
        \\}
        \\
        \\fn hello(ctx: *zynk.Context) !void {
        \\    const name = ctx.param("name") orelse "World";
        \\    try ctx.html("<h1>Hello, {s}!</h1>", .{name});
        \\}
        \\
    ;
    const main_path = try std.fs.path.join(allocator, &.{ project_name, "src", "main.zig" });
    defer allocator.free(main_path);
    try dir.writeFile(main_path, main_zig);

    // Create .gitignore
    try dir.writeFile(
        try std.fs.path.join(allocator, &.{ project_name, ".gitignore" }),
        ".zig-cache\nzig-out\n",
    );

    std.debug.print("Created project '{s}' successfully!\n", .{project_name});
    std.debug.print("  cd {s}\n", .{project_name});
    std.debug.print("  zig build run\n", .{});
}

pub fn runDev(allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.debug.print("Starting development server...\n", .{});
    std.debug.print("(Not yet implemented - use 'zig build run' instead)\n", .{});
}

pub fn runBuild(allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.debug.print("Building for production...\n", .{});
    std.debug.print("(Not yet implemented - use 'zig build' instead)\n", .{});
}

pub fn generate(allocator: std.mem.Allocator, gen_type: []const u8, name: []const u8) !void {
    if (std.mem.eql(u8, gen_type, "route") or std.mem.eql(u8, gen_type, "r")) {
        try generateRoute(allocator, name);
    } else if (std.mem.eql(u8, gen_type, "controller") or std.mem.eql(u8, gen_type, "c")) {
        try generateController(allocator, name);
    } else if (std.mem.eql(u8, gen_type, "model") or std.mem.eql(u8, gen_type, "m")) {
        try generateModel(allocator, name);
    } else {
        std.debug.print("Unknown generate type: {s}\n", .{gen_type});
        std.debug.print("Available: route, controller, model\n", .{});
    }
}

fn generateRoute(allocator: std.mem.Allocator, name: []const u8) !void {
    const content = try std.fmt.allocPrint(allocator,
        \\const zynk = @import("zynk");
        \\
        \\pub fn {s}(ctx: *zynk.Context) !void {{
        \\    try ctx.text("Hello from {s} route");
        \\}}
        \\
    , .{name, name});
    defer allocator.free(content);

    const cwd = std.fs.cwd();
    const path = try std.fs.path.join(allocator, &.{ "src", "routes", name });
    defer allocator.free(path);
    const full_path = try std.fmt.allocPrint(allocator, "{s}.zig", .{path});
    defer allocator.free(full_path);
    try cwd.writeFile(full_path, content);
    std.debug.print("Created route: {s}\n", .{full_path});
}

fn generateController(allocator: std.mem.Allocator, name: []const u8) !void {
    const content = try std.fmt.allocPrint(allocator,
        \\const zynk = @import("zynk");
        \\
        \\pub const {s}Controller = struct {{
        \\    allocator: std.mem.Allocator,
        \\
        \\    pub fn init(allocator: std.mem.Allocator) {s}Controller {{
        \\        return .{{ .allocator = allocator }};
        \\    }}
        \\
        \\    pub fn index(ctx: *zynk.Context) !void {{
        \\        try ctx.text("Index");
        \\    }}
        \\}};
        \\
    , .{ name, name, name });
    defer allocator.free(content);

    const cwd = std.fs.cwd();
    const full_path = try std.fs.path.join(allocator, &.{ "src", "controllers", name });
    defer allocator.free(full_path);
    const path_with_ext = try std.fmt.allocPrint(allocator, "{s}.zig", .{full_path});
    defer allocator.free(path_with_ext);
    try cwd.writeFile(path_with_ext, content);
    std.debug.print("Created controller: {s}\n", .{path_with_ext});
}

fn generateModel(allocator: std.mem.Allocator, name: []const u8) !void {
    const content = try std.fmt.allocPrint(allocator,
        \\const zynk = @import("zynk");
        \\
        \\pub const {s} = struct {{
        \\    id: u64,
        \\    allocator: std.mem.Allocator,
        \\
        \\    pub fn init(allocator: std.mem.Allocator) {s} {{
        \\        return .{{ .id = 0, .allocator = allocator }};
        \\    }}
        \\}};
        \\
    , .{ name, name });
    defer allocator.free(content);

    const cwd = std.fs.cwd();
    const full_path = try std.fs.path.join(allocator, &.{ "src", "models", name });
    defer allocator.free(full_path);
    const path_with_ext = try std.fmt.allocPrint(allocator, "{s}.zig", .{full_path});
    defer allocator.free(path_with_ext);
    try cwd.writeFile(path_with_ext, content);
    std.debug.print("Created model: {s}\n", .{path_with_ext});
}
