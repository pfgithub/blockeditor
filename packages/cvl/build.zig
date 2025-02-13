const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_exe = b.addTest(.{
        .root_module = b.addModule("parser", .{
            .root_source_file = b.path("src/parser.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "anywhere", .module = b.dependency("anywhere", .{}).module("anywhere") },
                .{ .name = "rvemu", .module = b.dependency("rvemu", .{}).module("rvemu") },
            },
        }),
    });
    b.installArtifact(test_exe);
    const run = b.addRunArtifact(test_exe);
    run.step.dependOn(b.getInstallStep());
    b.step("test", "test").dependOn(&run.step);
}
