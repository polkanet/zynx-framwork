const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const polka_mod = b.createModule(.{
        .root_source_file = b.path("zynk/src/zynk.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "polka",
        .root_module = polka_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const test_lib = b.addTest(.{
        .root_module = polka_mod,
    });

    const run_tests = b.addRunArtifact(test_lib);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
