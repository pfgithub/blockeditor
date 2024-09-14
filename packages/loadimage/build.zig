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

    const wuffs_lib = b.dependency("wuffs", .{});
    const wuffs_bindings = b.addTranslateC(.{
        .root_source_file = wuffs_lib.path("release/c/wuffs-v0.4.c"),
        .target = target,
        .optimize = optimize,
    });
    const wuffs_mod = b.createModule(.{
        .root_source_file = wuffs_bindings.getOutput(),
    });
    wuffs_mod.addCSourceFile(.{
        .file = wuffs_lib.path("release/c/wuffs-v0.4.c"),
        .flags = &.{"-DWUFFS_IMPLEMENTATION"},
    });
    wuffs_mod.link_libc = true;
    // is this needed? wuffs uses stdbool, stdint, stdlib, string and that seems to be it
    // ^ unfortunately, both stdlib.h and string.h require libc
    // maybe we can define them ourselves and see which symbols it needs?

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
