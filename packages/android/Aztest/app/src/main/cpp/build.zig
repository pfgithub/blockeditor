const std = @import("std");

const target_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "armeabi-v7a", "arm-linux-android" },
    .{ "arm64-v8a", "aarch64-linux-android" },
    .{ "x86", "x86-linux-android" },
    .{ "x86_64", "x86_64-linux-android" },
});

pub fn build(b: *std.Build) !void {
    const INCLUDE_DIR = b.option([]const u8, "INCLUDE_DIR", "") orelse @panic("missing INCLUDE_DIR");
    const SYS_INCLUDE_DIR = b.option([]const u8, "SYS_INCLUDE_DIR", "") orelse @panic("missing SYS_INCLUDE_DIR");
    const CRT1_PATH = b.option([]const u8, "CRT1_PATH", "") orelse @panic("missing CRT1_PATH");

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

    const libc_file_builder = b.addExecutable(.{
        .name = "libc_file_builder",
        .target = b.resolveTargetQuery(.{}), // native
        .optimize = .Debug,
        .root_source_file = b.path("libc_file_builder.zig"),
    });

    const make_libc_file = b.addRunArtifact(libc_file_builder);
    make_libc_file.addPrefixedDirectoryArg("include_dir=", .{ .cwd_relative = INCLUDE_DIR });
    make_libc_file.addPrefixedDirectoryArg("sys_include_dir=", .{ .cwd_relative = SYS_INCLUDE_DIR });
    make_libc_file.addPrefixedDirectoryArg("crt_dir=", .{ .cwd_relative = CRT1_PATH });

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);

    const app_dep = b.dependency("app", .{ .target = target, .optimize = optimize });

    const lib = b.addStaticLibrary(.{
        .name = "zigpart",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    b.installArtifact(lib);

    lib.setLibCFile(make_libc_file.captureStdOut());
    lib.linkLibC();
    lib.root_module.addImport("app", app_dep.module("blockeditor"));
}
