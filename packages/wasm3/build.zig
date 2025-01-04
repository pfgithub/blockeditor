const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const w3_dep = b.dependency("wasm3", .{ .target = target, .optimize = optimize });
    b.installArtifact(w3_dep.artifact("m3"));
    if (!target.result.isWasm() and !target.result.isAndroid()) b.installArtifact(w3_dep.artifact("wasm3"));
}

// wasm3 includes gas metering, so we can limit execution for minigamer & blockeditor
// it might not include full serialization, so we may decide not to use it. but full serialization
// probably isn't necessary, it's just nice to have.
