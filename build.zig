const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_all = b.addFmt(.{ .paths = &.{ "packages", "build.zig", "build.zig.zon" }, .check = b.option(bool, "ci", "") orelse false });
    b.getInstallStep().dependOn(&fmt_all.step);

    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });
    const blockeditor_dep = b.dependency("blockeditor", .{ .target = target, .optimize = optimize });
    const blocks_dep = b.dependency("blocks", .{ .target = target, .optimize = optimize });
    const blocks_net_dep = b.dependency("blocks_net", .{ .target = target, .optimize = optimize });
    const loadimage_dep = b.dependency("loadimage", .{ .target = target, .optimize = optimize });
    const texteditor_dep = b.dependency("texteditor", .{ .target = target, .optimize = optimize });
    const unicode_segmentation_dep = b.dependency("unicode_segmentation", .{ .target = target, .optimize = optimize });

    b.installArtifact(blockeditor_dep.artifact("blockeditor"));
    b.installArtifact(blocks_net_dep.artifact("server"));

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&b.addRunArtifact(beui_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(blocks_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(blocks_net_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(loadimage_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(texteditor_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(unicode_segmentation_dep.artifact("test")).step);

    const run_blockeditor = b.addRunArtifact(blockeditor_dep.artifact("blockeditor"));
    if (b.args) |args| run_blockeditor.addArgs(args);
    const run_blockeditor_step = b.step("run", "Run blockeditor");
    run_blockeditor_step.dependOn(b.getInstallStep());
    run_blockeditor_step.dependOn(&run_blockeditor.step);

    const run_server = b.addRunArtifact(blocks_net_dep.artifact("server"));
    if (b.args) |args| run_server.addArgs(args);
    const run_server_step = b.step("server", "Run server");
    run_server_step.dependOn(b.getInstallStep());
    run_server_step.dependOn(&run_server.step);
}
