const std = @import("std");

pub const deps = struct {
    pub const tree_sitter = @import("tree_sitter");
    pub const beui_app = @import("beui_app");
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_tracy = b.option(bool, "tracy", "Enable tracy?") orelse false;

    const fmt_all = b.addFmt(.{
        .paths = &.{
            // zig fmt: off
            "packages/anywhere/src", "packages/anywhere/build.zig",
            "packages/beui/src", "packages/beui/build.zig", "packages/beui/build.zig.zon",
            "packages/beui_app/src", "packages/beui_app/build.zig", "packages/beui_app/build.zig.zon",
            "packages/beui_impl_android/src", "packages/beui_impl_android/build.zig", "packages/beui_impl_android/build.zig.zon",
            "packages/beui_impl_glfw_wgpu/src", "packages/beui_impl_glfw_wgpu/build.zig", "packages/beui_impl_glfw_wgpu/build.zig.zon",
            "packages/beui_impl_web/src", "packages/beui_impl_web/build.zig", "packages/beui_impl_web/build.zig.zon",
            "packages/blockeditor/src", "packages/blockeditor/build.zig", "packages/blockeditor/build.zig.zon",
            "packages/blocks/src", "packages/blocks/build.zig", "packages/blocks/build.zig.zon",
            "packages/blocks_net/src", "packages/blocks_net/build.zig", "packages/blocks_net/build.zig.zon",
            "packages/loadimage/src", "packages/loadimage/build.zig", "packages/blocks_net/build.zig.zon",
            "packages/sheen_bidi/src", "packages/sheen_bidi/build.zig", "packages/blocks_net/build.zig.zon",
            "packages/texteditor/src", "packages/texteditor/build.zig", "packages/blocks_net/build.zig.zon",
            "packages/tracy/src", "packages/tracy/build.zig", "packages/blocks_net/build.zig.zon",
            "packages/tree_sitter/src", "packages/tree_sitter/build.zig", "packages/blocks_net/build.zig.zon",
            "packages/unicode_segmentation/src", "packages/unicode_segmentation/build.zig", "packages/blocks_net/build.zig.zon",
            "build.zig","build.zig.zon",
            // zig fmt: on
        },
        .check = b.option(bool, "ci", "") orelse false,
    });
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

    const blockeditor_app = deps.beui_app.app(blockeditor_dep, "blockeditor");
    const blockeditor_app_install = deps.beui_app.installApp(b, blockeditor_app);
    b.installArtifact(blocks_net_dep.artifact("server"));
    b.installArtifact(texteditor_dep.artifact("zls"));
    b.installArtifact(blocks_dep.artifact("bench"));
    if (enable_tracy) b.getInstallStep().dependOn(&b.addInstallArtifact(tracy_dep.artifact("tracy"), .{ .dest_dir = .{ .override = .{ .custom = "tool" } } }).step); // tracy exe has system dependencies and cannot be compiled for all targets

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&b.addRunArtifact(anywhere_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(beui_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(blockeditor_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(blocks_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(blocks_net_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(loadimage_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(sheen_bidi_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(texteditor_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(unicode_segmentation_dep.artifact("test")).step);

    const run_blockeditor = deps.beui_app.addRunApp(b, blockeditor_app, blockeditor_app_install);
    if (b.args) |args| run_blockeditor.addArgs(args);
    run_blockeditor.step.dependOn(b.getInstallStep());
    const run_blockeditor_step = b.step("run", "Run");
    run_blockeditor_step.dependOn(&run_blockeditor.step);

    const run_server = b.addRunArtifact(blocks_net_dep.artifact("server"));
    run_server.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_server.addArgs(args);
    const run_server_step = b.step("server", "Run server");
    run_server_step.dependOn(&run_server.step);
}
