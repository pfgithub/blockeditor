const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tool_target = b.resolveTargetQuery(.{});
    const tool_optimize: std.builtin.OptimizeMode = .Debug;

    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
    });
    b.getInstallStep().dependOn(&fmt.step);

    const loadimage_mod = b.dependency("loadimage", .{ .target = tool_target, .optimize = tool_optimize });
    const genfont_tool = b.addExecutable(.{
        .name = "genfont_tool",
        .root_source_file = b.path("src/genfont.zig"),
        .target = tool_target,
        .optimize = tool_optimize,
    });
    genfont_tool.root_module.addImport("loadimage", loadimage_mod.module("loadimage"));
    const genfont_run = b.addRunArtifact(genfont_tool);
    genfont_run.addFileArg(b.path("src/base_texture.png"));
    const font_rgba = genfont_run.addOutputFileArg("font.rgba");
    const font_rgba_mod = b.createModule(.{
        .root_source_file = font_rgba,
    });

    const beui_mod = b.addModule("beui", .{
        .root_source_file = b.path("src/beui.zig"),
        .target = target,
        .optimize = optimize,
    });

    beui_mod.addImport("font.rgba", font_rgba_mod);

    const beui_test = b.addTest(.{
        .root_source_file = b.path("src/beui.zig"),
        .target = target,
        .optimize = optimize,
    });
    beui_test.root_module.addImport("font.rgba", font_rgba_mod);

    b.installArtifact(beui_test);
    const run_beui_tests = b.addRunArtifact(beui_test);

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_beui_tests.step);
}
