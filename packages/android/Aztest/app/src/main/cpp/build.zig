const std = @import("std");

const target_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "armeabi-v7a", "arm-linux-android" },
    .{ "arm64-v8a", "aarch64-linux-android" },
    .{ "x86", "x86-linux-android" },
    .{ "x86_64", "x86_64-linux-android" },
});

pub fn build(b: *std.Build) !void {
    const CMAKE_ANDROID_ARCH_ABI = b.option([]const u8, "CMAKE_ANDROID_ARCH_ABI", "") orelse @panic("missing CMAKE_ANDROID_ARCH_ABI");
    const ANDROID_LIB = b.option([]const u8, "ANDROID_LIB", "") orelse @panic("missing ANDROID_LIB");
    const LOG_LIB = b.option([]const u8, "LOG_LIB", "") orelse @panic("missing LOG_LIB");
    const GLESV3_LIB = b.option([]const u8, "GLESV3_LIB", "") orelse @panic("missing GLESV3_LIB");
    std.log.err("ANDROID_LIB: {s}", .{ANDROID_LIB});
    std.log.err("LOG_LIB: {s}", .{LOG_LIB});
    std.log.err("GLESV3_LIB: {s}", .{GLESV3_LIB});

    const target_triple = target_map.get(CMAKE_ANDROID_ARCH_ABI) orelse @panic("TODO support android arch abi");
    const target = b.resolveTargetQuery(try std.Target.Query.parse(.{ .arch_os_abi = target_triple }));
    const optimize: std.builtin.OptimizeMode = .Debug;

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
    });
    b.getInstallStep().dependOn(&format_step.step);

    const lib = b.addStaticLibrary(.{
        .name = "zigpart",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    b.installArtifact(lib);
}
