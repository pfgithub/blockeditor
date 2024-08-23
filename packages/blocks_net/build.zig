const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize });

    const server_exe = b.addExecutable(.{
        .name = "blocks_server",
        .root_source_file = b.path("src/tcp/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_exe.root_module.addImport("xev", xev.module("xev"));
    b.installArtifact(server_exe);

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

    const run = b.addRunArtifact(server_exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run");
    run_step.dependOn(b.getInstallStep());
    run_step.dependOn(&run.step);
}
