const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const block_test = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/text_block.zig"),
    });
    const run_block_tests = b.addRunArtifact(block_test);

    const test_step = b.step("test", "Test");
    test_step.dependOn(&run_block_tests.step);
}
