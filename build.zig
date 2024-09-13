const std = @import("std");

pub const packages = struct {
    pub const beui = @import("beui");
    pub const blockeditor = @import("blockeditor");
    pub const blocks = @import("blocks");
    pub const blocks_net = @import("blocks_net");
    pub const loadimage = @import("loadimage");
    pub const texteditor = @import("texteditor");
    pub const unicode_segmentation = @import("unicode_segmentation");
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const beui_dep = b.dependency("beui", .{.target = target, .optimize = optimize});
    const blockeditor_dep = b.dependency("blockeditor", .{.target = target, .optimize = optimize});
    const blocks_dep = b.dependency("blocks", .{.target = target, .optimize = optimize});
    const blocks_net_dep = b.dependency("blocks_net", .{.target = target, .optimize = optimize});
    const loadimage_dep = b.dependency("loadimage", .{.target = target, .optimize = optimize});
    const texteditor_dep = b.dependency("texteditor", .{.target = target, .optimize = optimize});
    const unicode_segmentation_dep = b.dependency("unicode_segmentation", .{.target = target, .optimize = optimize});

    const test_step = b.step("test", "Test");
    test_step.dependOn(&b.addRunArtifact(beui_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(blocks_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(blocks_net_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(loadimage_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(texteditor_dep.artifact("test")).step);
    test_step.dependOn(&b.addRunArtifact(unicode_segmentation_dep.artifact("test")).step);

    const run_blockeditor = b.addRunArtifact(blockeditor_dep.artifact("blockeditor"));
    if(b.args) |args| run_blockeditor.addArgs(args);
    const run_blockeditor_step = b.step("run", "Run blockeditor");
    run_blockeditor_step.dependOn(&run_blockeditor.step);
}