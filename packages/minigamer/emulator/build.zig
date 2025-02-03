const std = @import("std");

pub fn build(b: *std.Build) void {
    const anywhere_dep = b.dependency("anywhere", .{});
    const rvemu_dep = b.dependency("rvemu", .{});
    _ = b.addModule("emu", .{
        .root_source_file = b.path("src/emu.zig"),
        .imports = &.{
            .{ .name = "anywhere", .module = anywhere_dep.module("anywhere") },
            .{ .name = "rvemu", .module = rvemu_dep.module("rvemu") },
        },
    });
}
