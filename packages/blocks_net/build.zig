const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_step = b.addFmt(.{.paths = &.{"src", "build.zig"}});
    b.getInstallStep().dependOn(&fmt_step.step);

    _ = b.addModule("blocks_server", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const server_test = b.addTest(.{
        .target = target,
        .optimize = optimize,
        // .root_module = blocks_mod,
        .root_source_file = b.path("src/root.zig"),
    });
    const run_server_tests = b.addRunArtifact(server_test);

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_server_tests.step);
}
