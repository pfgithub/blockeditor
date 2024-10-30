const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&fmt_step.step);

    //
    // Wuffs module (for image loading)
    //

    const wuffs_dep = b.dependency("wuffs", .{ .target = target, .optimize = optimize });
    const wuffs_mod = wuffs_dep.module("wuffs");

    //
    // Loadimage Module
    //

    const loadimage_mod = b.addModule("loadimage", .{
        .root_source_file = b.path("src/loadimage.zig"),
        .target = target,
        .optimize = optimize,
    });
    loadimage_mod.addImport("wuffs", wuffs_mod);

    // tests

    const tests = b.addTest(.{
        .root_source_file = b.path("src/loadimage.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("wuffs", wuffs_mod);
    b.installArtifact(tests);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.getInstallStep().dependOn(&install_docs.step);

    const test_run = b.addRunArtifact(tests);
    test_run.step.dependOn(b.getInstallStep());
    const run_tests = b.step("test", "run tests");
    run_tests.dependOn(&test_run.step);
}
