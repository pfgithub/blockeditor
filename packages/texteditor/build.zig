const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    const blocks_dep = b.dependency("blocks", .{
        .target = target,
        .optimize = optimize,
    });

    const blocks_mod = b.addModule("texteditor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    blocks_mod.addImport("blocks", blocks_dep.module("blocks"));

    const block_test = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    block_test.root_module.addImport("blocks", blocks_dep.module("blocks"));

    b.installArtifact(block_test);
    const run_block_tests = b.addRunArtifact(block_test);

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_block_tests.step);
}
