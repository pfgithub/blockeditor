const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .abi = .musl,
    });
    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;

    const loadimage = b.dependency("loadimage", .{ .target = target, .optimize = optimize });

    // wasm
    const loadimage_wasm = b.addExecutable(.{
        .name = "loadimage_wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/loadimage_wasm.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "loadimage", .module = loadimage.module("loadimage") },
            },
        }),
    });
    loadimage_wasm.entry = .disabled;
    loadimage_wasm.rdynamic = true;
    b.installArtifact(loadimage_wasm);
}
