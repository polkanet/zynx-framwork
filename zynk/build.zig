const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the main library module
    const zynk_mod = b.createModule(.{
        .root_source_file = b.path("src/zynk.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library
    const lib = b.addLibrary(.{
        .name = "zynk",
        .root_module = zynk_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zynk.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run framework tests");
    test_step.dependOn(&run_tests.step);

    // Router tests (uses the full module so relative imports resolve correctly)
    const router_tests = b.addTest(.{
        .root_module = zynk_mod,
    });
    const run_router_tests = b.addRunArtifact(router_tests);
    const router_test_step = b.step("test-router", "Run router tests");
    router_test_step.dependOn(&run_router_tests.step);

    // Example
    const exe = b.addExecutable(.{
        .name = "zynk-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zynk", .module = zynk_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the example app");
    run_step.dependOn(&run_cmd.step);
}
