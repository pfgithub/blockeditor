const std = @import("std");
const zig_gamedev = @import("zig_gamedev");
const beui_impl_glfw_wgpu = @import("beui_impl_glfw_wgpu");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);

    const anywhere_dep = b.dependency("anywhere", .{ .target = target, .optimize = optimize });
    const blocks_dep = b.dependency("blocks", .{ .target = target, .optimize = optimize });
    const blocks_net_dep = b.dependency("blocks_net", .{ .target = target, .optimize = optimize });
    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });

    const app_mod = b.addModule("blockeditor", .{
        .root_source_file = b.path("src/App.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "anywhere", .module = anywhere_dep.module("anywhere") },
            .{ .name = "blocks", .module = blocks_dep.module("blocks") },
            .{ .name = "blocks_net", .module = blocks_net_dep.module("client") },
            .{ .name = "beui", .module = beui_dep.module("beui") },
        },
    });

    const app_test = b.addTest(.{
        .root_source_file = b.path("src/App.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_test.root_module.addImport("anywhere", anywhere_dep.module("anywhere"));
    app_test.root_module.addImport("blocks", blocks_dep.module("blocks"));
    app_test.root_module.addImport("blocks_net", blocks_net_dep.module("client"));
    app_test.root_module.addImport("beui", beui_dep.module("beui"));
    b.installArtifact(app_test);

    const app_test_run = b.addRunArtifact(app_test);
    app_test_run.step.dependOn(b.getInstallStep());
    const test_run = b.step("test", "Test");
    test_run.dependOn(&app_test_run.step);

    const beui_impl_glfw_wgpu_dep = b.dependency("beui_impl_glfw_wgpu", .{ .target = target, .optimize = optimize, .tracy = b.option(bool, "tracy", "") orelse false });
    const exe_path = beui_impl_glfw_wgpu.createApp("blockeditor", beui_impl_glfw_wgpu_dep, app_mod);
    b.addNamedLazyPath("blockeditor", exe_path);

    const installed_exe = beui_impl_glfw_wgpu.InstallFile2.create(b, exe_path, .bin, null);
    const run_step = beui_impl_glfw_wgpu.runApp(beui_impl_glfw_wgpu_dep, installed_exe.getInstalledFile());
    if (b.args) |args| run_step.addArgs(args);
    run_step.step.dependOn(b.getInstallStep());
    const run = b.step("run", "Run");
    run.dependOn(&run_step.step);
}
