const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    _ = b.addModule("anywhere", .{
        .root_source_file = b.path("src/anywhere.zig"),
    });

    const block_test = b.addTest(.{
        .root_source_file = b.path("src/anywhere.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(block_test);
    const run_block_tests = b.addRunArtifact(block_test);
    run_block_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Test");
    test_step.dependOn(&run_block_tests.step);

    const libc_file_builder = b.addExecutable(.{
        .name = "libc_file_builder",
        .target = b.resolveTargetQuery(.{}), // native
        .optimize = .Debug,
        .root_source_file = b.path("src/libc_file_builder.zig"),
    });
    b.installArtifact(libc_file_builder);
}

pub const lib = @import("src/anywhere.zig");
