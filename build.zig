const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_tracy = b.option(bool, "tracy", "Enable tracy?") orelse false;

    const fmt_all = b.addFmt(.{ .paths = &.{ "packages", "build.zig", "build.zig.zon" }, .check = b.option(bool, "ci", "") orelse false });
    b.getInstallStep().dependOn(&fmt_all.step);

    const anywhere_dep = b.dependency("anywhere", .{ .target = target, .optimize = optimize });
    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });
    const blockeditor_dep = b.dependency("blockeditor", .{ .target = target, .optimize = optimize, .tracy = enable_tracy });
    const blocks_dep = b.dependency("blocks", .{ .target = target, .optimize = optimize, .tracy = enable_tracy });
    const blocks_net_dep = b.dependency("blocks_net", .{ .target = target, .optimize = optimize });
    const loadimage_dep = b.dependency("loadimage", .{ .target = target, .optimize = optimize });
    const sheen_bidi_dep = b.dependency("sheen_bidi", .{ .target = target, .optimize = optimize });
    const texteditor_dep = b.dependency("texteditor", .{ .target = target, .optimize = optimize });
    const tracy_dep = b.dependency("tracy", .{ .target = target, .optimize = optimize });
    const unicode_segmentation_dep = b.dependency("unicode_segmentation", .{ .target = target, .optimize = optimize });

    b.installArtifact(blockeditor_dep.artifact("blockeditor"));
    b.installArtifact(blocks_net_dep.artifact("server"));
    b.installArtifact(texteditor_dep.artifact("zls"));
    b.installArtifact(blocks_dep.artifact("bench"));
    if (enable_tracy) b.getInstallStep().dependOn(&b.addInstallArtifact(tracy_dep.artifact("tracy"), .{ .dest_dir = .{ .override = .{ .custom = "tool" } } }).step); // tracy exe has system dependencies and cannot be compiled for all targets

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&b.addRunArtifact(anywhere_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(beui_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(blocks_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(blocks_net_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(loadimage_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(sheen_bidi_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(texteditor_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(unicode_segmentation_dep.artifact("test")).step);

    const multirun_exe = b.addExecutable(.{
        .name = "multirun",
        .root_source_file = b.path("multirun.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
    });
    b.getInstallStep().dependOn(&b.addInstallArtifact(multirun_exe, .{ .dest_dir = .{ .override = .{ .custom = "tool" } } }).step);

    const run_blockeditor = runWithTracy(b, enable_tracy, optimize, multirun_exe, tracy_dep, blockeditor_dep.artifact("blockeditor"));
    if (b.args) |args| run_blockeditor.addArgs(args);
    const run_blockeditor_step = b.step("run", "Run blockeditor");
    run_blockeditor_step.dependOn(&run_blockeditor.step);

    const run_server = b.addRunArtifact(blocks_net_dep.artifact("server"));
    run_server.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_server.addArgs(args);
    const run_server_step = b.step("server", "Run server");
    run_server_step.dependOn(&run_server.step);

    const run_bench = runWithTracy(b, enable_tracy, optimize, multirun_exe, tracy_dep, blocks_dep.artifact("bench"));
    if (b.args) |args| run_blockeditor.addArgs(args);
    const run_bench_step = b.step("bench", "Run blocks bench");
    run_bench_step.dependOn(&run_bench.step);
}

fn runWithTracy(b: *std.Build, enable_tracy: bool, optimize: std.builtin.OptimizeMode, multirun_exe: *std.Build.Step.Compile, tracy_dep: *std.Build.Dependency, target_exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    if (enable_tracy) {
        if (optimize == .Debug) {
            b.getInstallStep().dependOn(&b.addFail("To use tracy, -Doptimize must be set to a release mode").step);
        }

        const run_multirun = b.addRunArtifact(multirun_exe);
        run_multirun.step.dependOn(b.getInstallStep());

        run_multirun.addArg("|-|");
        run_multirun.addArtifactArg(tracy_dep.artifact("tracy"));

        run_multirun.addArg("|-|");
        run_multirun.addArtifactArg(target_exe);

        return run_multirun;
    } else {
        const run_blockeditor = b.addRunArtifact(target_exe);
        run_blockeditor.step.dependOn(b.getInstallStep());
        return run_blockeditor;
    }
}
