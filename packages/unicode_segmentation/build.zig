const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
    });
    b.getInstallStep().dependOn(&fmt_step.step);

    const test_exe = b.addTest(.{
        .root_source_file = b.path("src/grapheme_cursor.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_exe.addObjectFile(b.path("target/aarch64-apple-darwin/zig_debug/libunicode_segmentation_bindings.a"));

    b.installArtifact(test_exe);

    const test_step = b.addRunArtifact(test_exe);
    const test_step_step = b.step("test", "");
    test_step_step.dependOn(b.getInstallStep());
    test_step_step.dependOn(&test_step.step);
}
