const std = @import("std");

// this contains:
// - docs & build script for the whole repo
// then,
// - the root build.zig just depends on this package

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    const docs = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/docs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // has to go on top otherwise the name gets rewritten when it's depended on by a different module and it breaks the zig docs viewer
    // the :build ones also just don't work at all for a similar reason it seems
    docs.root_module.addImport("unicode_segmentation", b.dependency("unicode_segmentation", .{ .target = target, .optimize = optimize }).module("grapheme_cursor"));

    docs.root_module.addImport("anywhere", b.dependency("anywhere", .{}).module("anywhere"));
    docs.root_module.addImport("beui", b.dependency("beui", .{ .target = target, .optimize = optimize }).module("beui"));
    docs.root_module.addImport("beui_app:build", b.createModule(.{ .root_source_file = b.dependency("beui_app", .{}).path("build.zig") }));
    docs.root_module.addImport("blocks", b.dependency("blocks", .{ .target = target, .optimize = optimize }).module("blocks"));
    docs.root_module.addImport("blocks_net:client", b.dependency("blocks_net", .{ .target = target, .optimize = optimize }).module("client"));
    docs.root_module.addImport("loadimage", b.dependency("loadimage", .{ .target = target, .optimize = optimize }).module("loadimage"));
    docs.root_module.addImport("sheen_bidi", b.dependency("sheen_bidi", .{ .target = target, .optimize = optimize }).module("sheen_bidi"));
    docs.root_module.addImport("texteditor", b.dependency("texteditor", .{ .target = target, .optimize = optimize }).module("texteditor"));
    docs.root_module.addImport("tracy", b.dependency("tracy", .{ .target = target, .optimize = optimize }).module("tracy"));
    docs.root_module.addImport("tree_sitter", b.dependency("tree_sitter", .{ .target = target, .optimize = .ReleaseFast }).module("tree_sitter"));
    docs.root_module.addImport("tree_sitter:build", b.createModule(.{ .root_source_file = b.dependency("tree_sitter", .{ .target = target, .optimize = .ReleaseFast }).path("build.zig") }));

    b.addNamedLazyPath("docs", docs.getEmittedDocs());
    b.installDirectory(.{
        .install_dir = .lib,
        .install_subdir = "blockeditor-docs",
        .source_dir = docs.getEmittedDocs(),
    });
}
