const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tool_target = b.resolveTargetQuery(.{});
    const tool_optimize: std.builtin.OptimizeMode = .Debug;

    const run_zigx_fmt = b.addRunArtifact(b.dependency("zigx", .{}).artifact("zigx_fmt"));
    run_zigx_fmt.setCwd(b.path("."));
    run_zigx_fmt.addArgs(&.{ "src", "build.zig", "build.zig.zon" });
    const beforeall = &run_zigx_fmt.step;
    const beforeall_genf = b.allocator.create(std.Build.GeneratedFile) catch @panic("oom");
    beforeall_genf.* = .{
        .step = beforeall,
        .path = b.path("build.zig").getPath(b),
    };
    const beforeall_lazypath: std.Build.LazyPath = .{ .generated = .{ .file = beforeall_genf } };
    const beforeall_mod = b.createModule(.{ .root_source_file = beforeall_lazypath });

    const loadimage_mod = b.dependency("loadimage", .{ .target = tool_target, .optimize = tool_optimize });
    const genfont_tool = b.addExecutable(.{
        .name = "genfont_tool",
        .root_source_file = b.path("src/genfont.zig"),
        .target = tool_target,
        .optimize = tool_optimize,
    });
    genfont_tool.root_module.addImport("__ensure_run_zigx", beforeall_mod);
    genfont_tool.root_module.addImport("loadimage", loadimage_mod.module("loadimage"));
    const genfont_run = b.addRunArtifact(genfont_tool);
    genfont_run.addFileArg(b.path("src/base_texture.png"));
    const font_rgba = genfont_run.addOutputFileArg("font.rgba");
    const font_rgba_mod = b.createModule(.{
        .root_source_file = font_rgba,
    });

    const sheen_bidi_dep = b.dependency("sheen_bidi", .{ .target = target, .optimize = optimize });
    const sheen_bidi_mod = sheen_bidi_dep.module("sheen_bidi");

    const anywhere_dep = b.dependency("anywhere", .{ .target = target, .optimize = optimize });
    const anywhere_mod = anywhere_dep.module("anywhere");

    const texteditor_dep = b.dependency("texteditor", .{ .target = target, .optimize = optimize });
    const texteditor_mod = texteditor_dep.module("texteditor");

    const blocks_dep = b.dependency("blocks", .{ .target = target, .optimize = optimize });
    const blocks_mod = blocks_dep.module("blocks");

    const fonts_mod = b.dependency("fonts", .{});
    const notosans_wght_mod = b.createModule(.{
        .root_source_file = fonts_mod.path("NotoSans[wght].ttf"),
    });
    const notosansmono_wght_mod = b.createModule(.{
        .root_source_file = fonts_mod.path("NotoSansMono[wght].ttf"),
    });

    const mach_freetype_dep = b.dependency("mach_freetype", .{
        .target = target,
        .optimize = optimize,
    });
    const freetype_mod = mach_freetype_dep.module("mach-freetype");
    const harfbuzz_mod = mach_freetype_dep.module("mach-harfbuzz");

    const beui_mod = b.addModule("beui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    beui_mod.addImport("__ensure_run_zigx", beforeall_mod);
    beui_mod.addImport("font.rgba", font_rgba_mod);
    beui_mod.addImport("freetype", freetype_mod);
    beui_mod.addImport("harfbuzz", harfbuzz_mod);
    beui_mod.addImport("sheen_bidi", sheen_bidi_mod);
    beui_mod.addImport("anywhere", anywhere_mod);
    beui_mod.addImport("texteditor", texteditor_mod);
    beui_mod.addImport("blocks", blocks_mod);
    beui_mod.addImport("NotoSans[wght].ttf", notosans_wght_mod);
    beui_mod.addImport("NotoSansMono[wght].ttf", notosansmono_wght_mod);

    const beui_test = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    beui_test.root_module.addImport("__ensure_run_zigx", beforeall_mod);
    beui_test.root_module.addImport("font.rgba", font_rgba_mod);
    beui_test.root_module.addImport("freetype", freetype_mod);
    beui_test.root_module.addImport("harfbuzz", harfbuzz_mod);
    beui_test.root_module.addImport("sheen_bidi", sheen_bidi_mod);
    beui_test.root_module.addImport("anywhere", anywhere_mod);
    beui_test.root_module.addImport("texteditor", texteditor_mod);
    beui_test.root_module.addImport("blocks", blocks_mod);
    beui_test.root_module.addImport("NotoSans[wght].ttf", notosans_wght_mod);
    beui_test.root_module.addImport("NotoSansMono[wght].ttf", notosansmono_wght_mod);

    b.installArtifact(beui_test);
    const run_beui_tests = b.addRunArtifact(beui_test);

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_beui_tests.step);
}
