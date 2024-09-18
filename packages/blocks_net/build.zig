const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt.step);

    const websockets_zig_dep = b.dependency("websocket_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "blocks_net",
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("websocket", websockets_zig_dep.module("websocket"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib_unit_tests);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_lib_unit_tests.step);
}
