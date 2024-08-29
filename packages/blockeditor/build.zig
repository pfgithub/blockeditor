const std = @import("std");
const zig_gamedev = @import("zig_gamedev");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const treesitter_optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    const enable_tracy = b.option(bool, "enable_tracy", "Enable tracy?") orelse false;

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });

    const zig_gamedev_dep = b.dependency("zig_gamedev", .{});

    const blockeditor_exe = b.addExecutable(.{
        .name = "blockeditor",
        .root_source_file = b.path("src/entrypoint.zig"),
        .target = target,
        .optimize = optimize,
    });
    blockeditor_exe.step.dependOn(&format_step.step);

    const blocks_dep = b.dependency("blocks", .{
        .target = target,
        .optimize = optimize,
    });
    blockeditor_exe.root_module.addImport("blocks", blocks_dep.module("blocks"));

    // tree sitter stuff
    {
        const tree_sitter_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = treesitter_optimize });
        const tree_sitter_root = b.addTranslateC(std.Build.Step.TranslateC.Options{
            .root_source_file = tree_sitter_dep.path("lib/include/tree_sitter/api.h"),
            .target = target,
            .optimize = treesitter_optimize,
        });
        const tree_sitter_module = b.createModule(.{
            .root_source_file = tree_sitter_root.getOutput(),
        });
        tree_sitter_module.linkLibrary(tree_sitter_dep.artifact("tree-sitter"));

        const tree_sitter_zig_dep = b.dependency("tree_sitter_zig", .{});
        const tree_sitter_zig_obj = b.addStaticLibrary(.{
            .name = "tree_sitter_zig",
            .target = target,
            .optimize = treesitter_optimize,
        });
        tree_sitter_zig_obj.linkLibC();
        tree_sitter_zig_obj.addCSourceFile(.{ .file = tree_sitter_zig_dep.path("src/parser.c") });
        tree_sitter_zig_obj.addIncludePath(tree_sitter_zig_dep.path("src"));

        blockeditor_exe.root_module.addImport("tree-sitter", tree_sitter_module);
        blockeditor_exe.linkLibrary(tree_sitter_zig_obj);
    }

    if (enable_tracy) {
        const tracy_dep = b.dependency("tracy", .{
            .target = target,
            .optimize = optimize,
        });

        blockeditor_exe.linkLibrary(tracy_dep.artifact("tracy_client"));

        b.installArtifact(tracy_dep.artifact("tracy_profiler"));
    }

    {
        // hack
        blockeditor_exe.step.owner = zig_gamedev_dep.builder;
        defer blockeditor_exe.step.owner = b;

        zig_gamedev.pkgs.system_sdk.addLibraryPathsTo(blockeditor_exe);

        const zglfw = zig_gamedev_dep.builder.dependency("zglfw", .{
            .target = target,
        });
        blockeditor_exe.root_module.addImport("zglfw", zglfw.module("root"));
        blockeditor_exe.linkLibrary(zglfw.artifact("glfw"));

        zig_gamedev.pkgs.zgpu.addLibraryPathsTo(blockeditor_exe);
        const zgpu = zig_gamedev_dep.builder.dependency("zgpu", .{
            .target = target,
        });
        blockeditor_exe.root_module.addImport("zgpu", zgpu.module("root"));
        blockeditor_exe.linkLibrary(zgpu.artifact("zdawn"));

        const zgui = zig_gamedev_dep.builder.dependency("zgui", .{
            .target = target,
            .backend = .glfw_wgpu,
            .with_te = true,
        });
        blockeditor_exe.root_module.addImport("zgui", zgui.module("root"));
        blockeditor_exe.linkLibrary(zgui.artifact("imgui"));

        const zmath = zig_gamedev_dep.builder.dependency("zmath", .{
            .target = target,
        });
        blockeditor_exe.root_module.addImport("zmath", zmath.module("root"));

        // we don't need this, we'll use wuffs for images
        const zstbi = zig_gamedev_dep.builder.dependency("zstbi", .{
            .target = target,
        });
        blockeditor_exe.root_module.addImport("zstbi", zstbi.module("root"));
        blockeditor_exe.linkLibrary(zstbi.artifact("zstbi"));
    }

    b.installArtifact(blockeditor_exe);

    const run_step = b.addRunArtifact(blockeditor_exe);
    run_step.step.dependOn(b.getInstallStep());
    const run = b.step("run", "Run");
    run.dependOn(b.getInstallStep());
    run.dependOn(&run_step.step);
}
