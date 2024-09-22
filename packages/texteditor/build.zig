const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const treesitter_target: std.builtin.OptimizeMode = .ReleaseFast;

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    const zls_dep = b.dependency("zls", .{
        .target = target,
        .optimize = .ReleaseSafe,
    });
    b.installArtifact(zls_dep.artifact("zls"));

    const blocks_dep = b.dependency("blocks", .{
        .target = target,
        .optimize = optimize,
    });
    const seg_dep = b.dependency("unicode_segmentation", .{
        .target = target,
        .optimize = optimize,
    });
    const anywhere_dep = b.dependency("anywhere", .{
        .target = target,
        .optimize = optimize,
    });

    const tree_sitter_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = treesitter_target });
    const tree_sitter_root = b.addTranslateC(std.Build.Step.TranslateC.Options{
        .root_source_file = tree_sitter_dep.path("lib/include/tree_sitter/api.h"),
        .target = target,
        .optimize = treesitter_target,
    });
    const tree_sitter_module = b.createModule(.{
        .root_source_file = tree_sitter_root.getOutput(),
    });
    tree_sitter_module.linkLibrary(tree_sitter_dep.artifact("tree-sitter"));

    const tree_sitter_zig_dep = b.dependency("tree_sitter_zig", .{});
    const tree_sitter_zig_obj = b.addStaticLibrary(.{
        .name = "tree_sitter_zig",
        .target = target,
        .optimize = treesitter_target,
    });
    tree_sitter_zig_obj.linkLibC();
    tree_sitter_zig_obj.addCSourceFile(.{ .file = tree_sitter_zig_dep.path("src/parser.c") });
    tree_sitter_zig_obj.addIncludePath(tree_sitter_zig_dep.path("src"));

    const texteditor_mod = b.addModule("texteditor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    texteditor_mod.addImport("blocks", blocks_dep.module("blocks"));
    texteditor_mod.addImport("grapheme_cursor", seg_dep.module("grapheme_cursor"));
    texteditor_mod.addImport("anywhere", anywhere_dep.module("anywhere"));
    texteditor_mod.addImport("tree-sitter", tree_sitter_module);
    texteditor_mod.linkLibrary(tree_sitter_zig_obj);

    const texteditor_test = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .filter = b.option([]const u8, "filter", ""),
    });
    texteditor_test.root_module.addImport("blocks", blocks_dep.module("blocks"));
    texteditor_test.root_module.addImport("grapheme_cursor", seg_dep.module("grapheme_cursor"));
    texteditor_test.root_module.addImport("anywhere", anywhere_dep.module("anywhere"));
    texteditor_test.root_module.addImport("tree-sitter", tree_sitter_module);
    texteditor_test.root_module.linkLibrary(tree_sitter_zig_obj);

    b.installArtifact(texteditor_test);
    const run_texteditor_tests = b.addRunArtifact(texteditor_test);

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_texteditor_tests.step);
}
