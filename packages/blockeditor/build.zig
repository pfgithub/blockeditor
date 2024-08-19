const std = @import("std");
const zig_gamedev = @import("zig_gamedev");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

        const zstbi = zig_gamedev_dep.builder.dependency("zstbi", .{
            .target = target,
        });
        blockeditor_exe.root_module.addImport("zstbi", zstbi.module("root"));
        blockeditor_exe.linkLibrary(zstbi.artifact("zstbi"));
    }

    b.installArtifact(blockeditor_exe);

    const run_step = b.addRunArtifact(blockeditor_exe);
    const run = b.step("run", "Run");
    run.dependOn(b.getInstallStep());
    run.dependOn(&run_step.step);
}
