const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_tracy = b.option(bool, "tracy", "use tracy") orelse false;

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    const anywhere_dep = b.dependency("anywhere", .{ .target = target, .optimize = optimize });
    const anywhere_mod = anywhere_dep.module("anywhere");

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "use_tracy", use_tracy);
    const build_options_mod = build_opts.createModule();

    const blocks_mod = b.addModule("blocks", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    blocks_mod.addImport("anywhere", anywhere_mod);
    blocks_mod.addImport("build_options", build_options_mod);

    const block_test = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    block_test.root_module.addImport("anywhere", anywhere_mod);
    block_test.root_module.addImport("build_options", build_options_mod);

    b.installArtifact(block_test);
    const run_block_tests = b.addRunArtifact(block_test);
    run_block_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Test");
    test_step.dependOn(&run_block_tests.step);

    const benchmark_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("src/text_component.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(benchmark_exe);
    benchmark_exe.root_module.addImport("anywhere", anywhere_mod);
    benchmark_exe.root_module.addImport("build_options", build_options_mod);

    if (use_tracy) {
        if (b.lazyDependency("tracy", .{ .target = target, .optimize = optimize })) |tracy_mod| {
            benchmark_exe.root_module.addImport("tracy", tracy_mod.module("tracy"));
        }
    }
}
