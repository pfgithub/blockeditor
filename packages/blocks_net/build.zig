const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt.step);

    const websocket_zig_dep = b.dependency("websocket_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const blocks_dep = b.dependency("blocks", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("websocket", websocket_zig_dep.module("websocket"));
    b.installArtifact(exe);

    const client_mod = b.addModule("client", .{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_mod.addImport("websocket", websocket_zig_dep.module("websocket"));
    client_mod.addImport("blocks", blocks_dep.module("blocks"));

    const tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("websocket", websocket_zig_dep.module("websocket"));
    tests.root_module.addImport("blocks", blocks_dep.module("blocks"));
    b.installArtifact(tests);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_tests.step);

    const client_exe = b.addExecutable(.{
        .name = "wsnc",
        .root_source_file = b.path("src/wsnc.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_exe.root_module.addImport("websocket", websocket_zig_dep.module("websocket"));

    b.installArtifact(client_exe);
    const run_client = b.addRunArtifact(client_exe);
    run_client.step.dependOn(b.getInstallStep());
    const run_client_step = b.step("wsnc", "Run wsnc");
    run_client_step.dependOn(&run_client.step);
}
