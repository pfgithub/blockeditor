const std = @import("std");

pub fn build(b: *std.Build) void {
    const tool_target = b.resolveTargetQuery(.{});
    const tool_optimize: std.builtin.Mode = .Debug;

    const zigx_fmt_exe = b.addExecutable(.{
        .name = "zigx_fmt",
        .root_source_file = b.path("src/zig/fmt.zig"),
        .target = tool_target,
        .optimize = tool_optimize,
    });
    b.installArtifact(zigx_fmt_exe);

    const run_zigx_fmt = b.addRunArtifact(zigx_fmt_exe);
    run_zigx_fmt.setCwd(b.path("."));
    run_zigx_fmt.addArgs(&.{ "src", "build.zig" });
    const beforeall = &run_zigx_fmt.step;

    b.getInstallStep().dependOn(beforeall);

    {
        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});

        const tests = b.addTest(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        });
        tests.step.dependOn(beforeall);
        b.installArtifact(tests);
        const run_tests = b.addRunArtifact(tests);
        run_tests.step.dependOn(b.getInstallStep());
        const run_step = b.step("test", "run tests");
        run_step.dependOn(&run_tests.step);
    }
}
