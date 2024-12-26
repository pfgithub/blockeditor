const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_tracy = b.option(bool, "tracy", "use tracy") orelse false;

    const fmt_step = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt_step.step);

    const anywhere_mod = b.dependency("anywhere", .{}).module("anywhere");

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "use_tracy", use_tracy);
    const build_options_mod = build_opts.createModule();

    const blocks_mod = b.addModule("blocks", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "anywhere", .module = anywhere_mod },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    const block_test = b.addTest(.{ .root_module = blocks_mod });
    if (optimize == .Debug and target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
        block_test.use_llvm = false;
        block_test.use_lld = false;
    }

    b.installArtifact(block_test);
    const run_block_tests = b.addRunArtifact(block_test);
    run_block_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Test");
    test_step.dependOn(&run_block_tests.step);

    const benchmark_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/text_component.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (optimize == .Debug and target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
        benchmark_exe.use_llvm = false;
        benchmark_exe.use_lld = false;
    }
    b.installArtifact(benchmark_exe);
    for (blocks_mod.import_table.keys(), blocks_mod.import_table.values()) |k, v| benchmark_exe.root_module.addImport(k, v);

    if (use_tracy) {
        if (b.lazyDependency("tracy", .{ .target = target, .optimize = optimize })) |tracy_mod| {
            benchmark_exe.root_module.addImport("tracy", tracy_mod.module("tracy"));
        }
    }
}
