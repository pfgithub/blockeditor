const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi, .abi = .musl });
    const optimize = b.standardOptimizeOption(.{});

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);

    _ = target;
    _ = optimize;
}
