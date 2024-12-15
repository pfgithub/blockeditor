const std = @import("std");
const minigamer = @import("minigamer");

pub fn build(b: *std.Build) !void {
    const target = b.resolveTargetQuery(std.Target.Query{
        .cpu_arch = .riscv32,
        .cpu_model = .{
            .explicit = &std.Target.riscv.cpu.generic_rv32, // a, c, d, m
        },
        .cpu_features_add = std.Target.Cpu.Feature.FeatureSetFns(std.Target.riscv.Feature).featureSet(&.{
            .m, // multiplication
            // .d, // 64-bit float
            // .f, // 32-bit float

            // TODO: c (compressed instructions) (16 bits for common instructions)
            // TODO: a (atomics) : we don't need this yet really
        }),

        .os_tag = .freestanding,

        .abi = .none,
    });
    const optimize = b.standardOptimizeOption(.{});

    const tool_target = b.resolveTargetQuery(.{});
    const tool_optimize: std.builtin.OptimizeMode = .Debug;
    const loadimage_mod = b.dependency("loadimage", .{ .target = tool_target, .optimize = tool_optimize });
    const tools_exe = b.addExecutable(.{
        .name = "tools",
        .root_source_file = b.path("src/tools.zig"),
        .target = tool_target,
        .optimize = tool_optimize,
    });
    tools_exe.root_module.addImport("loadimage", loadimage_mod.module("loadimage"));
    b.installArtifact(tools_exe);

    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/runtime_lib/lib.zig"),
        .imports = &.{
            .{ .name = "assets", .module = try createAssets(b, tools_exe, b.path("src/runtime_lib/assets")) },
            .{ .name = "constants", .module = b.createModule(.{ .root_source_file = b.dependency("emulator", .{}).path("src/constants.zig") }) },
        },
    });

    const riscv_build = b.addExecutable(.{
        .name = "sponge.cart",
        .root_source_file = b.path("src/start.zig"),
        .target = target,
        .optimize = optimize,
    });
    riscv_build.root_module.single_threaded = true;
    riscv_build.root_module.addImport("lib", lib_mod);
    riscv_build.root_module.addImport("assets", try createAssets(b, tools_exe, b.path("assets")));

    b.installArtifact(riscv_build);
}

fn createAssets(b: *std.Build, tools_exe: *std.Build.Step.Compile, path: std.Build.LazyPath) !*std.Build.Module {
    const run_artifact = b.addRunArtifact(tools_exe);
    run_artifact.addArg("makeassets");
    const mod_root = run_artifact.addOutputFileArg("assets.zig");
    var game_assets_dir = try std.fs.cwd().openDir(path.getPath(b), .{});
    defer game_assets_dir.close();
    var walker = try game_assets_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (std.mem.startsWith(u8, entry.basename, ".")) continue;
        run_artifact.addFileArg(path.path(b, entry.path));
        run_artifact.addArg(entry.path);
    }
    return b.createModule(.{ .root_source_file = mod_root });
}
