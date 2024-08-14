const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("texteditor_block", .{
        .root_source_file = b.path("src/editor_block.zig"),
        .target = target,
        .optimize = optimize,
    });
}
