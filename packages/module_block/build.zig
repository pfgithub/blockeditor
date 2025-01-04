const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target_native = b.resolveTargetQuery(.{});
    const optimize_native: std.builtin.OptimizeMode = .Debug;
    const shared: Shared = .{
        .target_wasm = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }),
        .optimize_wasm = .ReleaseSmall,
        .namewithhash = b.addExecutable(.{
            .name = "namewithhash",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/namewithhash.zig"),
                .target = target_native,
                .optimize = optimize_native,
            }),
        }),
    };

    const myblock = addBlock(b, &shared, "9pilfNR3urQ3MqCrmbRAmlWuVXhaWROI-QfpihR-UXU", b.createModule(.{
        .root_source_file = b.path("src/TextureViewerBlock.zig"),
    }));
    b.getInstallStep().dependOn(&b.addInstallBinFile(myblock.file, myblock.name).step);
}

const Shared = struct {
    target_wasm: std.Build.ResolvedTarget,
    optimize_wasm: std.builtin.OptimizeMode,
    namewithhash: *std.Build.Step.Compile,
};

fn addBlock(b: *std.Build, shared: *const Shared, hash_in: []const u8, mod: *std.Build.Module) struct { name: []const u8, file: std.Build.LazyPath } {
    const hash = b.fmt("{s}", .{hash_in});
    const wasm = b.addExecutable(.{
        .name = hash,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/block.zig"),
            .target = shared.target_wasm,
            .optimize = shared.optimize_wasm,
            .imports = &.{
                .{ .name = "block", .module = mod },
            },
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.export_table = true;

    const res_lazypath = wasm.getEmittedBin();
    const outname = b.fmt("{s}.beblock", .{hash});

    const validator = b.addRunArtifact(shared.namewithhash);
    validator.addFileArg(res_lazypath);
    validator.addArg(hash);
    return .{ .name = outname, .file = validator.addOutputFileArg(outname) };
}
