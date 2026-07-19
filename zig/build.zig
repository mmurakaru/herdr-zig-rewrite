const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The vendored ghostty build exposes the native Zig module
    // "ghostty-vt" (root: src/lib_vt.zig) via src/build/GhosttyZig.zig.
    const ghostty_dependency = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    });
    const ghostty_vt_module = ghostty_dependency.module("ghostty-vt");

    const smoke_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_module.addImport("ghostty-vt", ghostty_vt_module);

    const smoke_executable = b.addExecutable(.{
        .name = "herdr-vt-smoke",
        .root_module = smoke_module,
    });
    b.installArtifact(smoke_executable);

    const run_command = b.addRunArtifact(smoke_executable);
    const run_step = b.step("run", "Run the smoke program");
    run_step.dependOn(&run_command.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/ghostty_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("ghostty-vt", ghostty_vt_module);

    const smoke_tests = b.addTest(.{ .root_module = test_module });
    const run_smoke_tests = b.addRunArtifact(smoke_tests);
    const test_step = b.step("test", "Run ghostty-vt native module smoke tests");
    test_step.dependOn(&run_smoke_tests.step);
}
