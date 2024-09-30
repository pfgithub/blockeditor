const std = @import("std");

const TargetInfo = struct {
    triple: []const u8,
    dir: []const u8,
};

const target_map = std.StaticStringMap(TargetInfo).initComptime(.{
    .{ "armeabi-v7a", .{ .triple = "arm-linux-android", .dir = "arm-linux-androideabi" } },
    .{ "arm64-v8a", .{ .triple = "aarch64-linux-android", .dir = "aarch64-linux-android" } },
    .{ "x86", .{ .triple = "x86-linux-android", .dir = "i686-linux-android" } },
    .{ "x86_64", .{ .triple = "x86_64-linux-android", .dir = "x86_64-linux-android" } },
});

pub fn build(b: *std.Build) !void {
    const INCLUDE_DIR = b.option([]const u8, "INCLUDE_DIR", "") orelse @panic("missing INCLUDE_DIR");
    const CRT1_PATH = b.option([]const u8, "CRT1_PATH", "") orelse @panic("missing CRT1_PATH");

    const CMAKE_ANDROID_ARCH_ABI = b.option([]const u8, "CMAKE_ANDROID_ARCH_ABI", "") orelse @panic("missing CMAKE_ANDROID_ARCH_ABI");
    const ANDROID_LIB = b.option([]const u8, "ANDROID_LIB", "") orelse @panic("missing ANDROID_LIB");
    const LOG_LIB = b.option([]const u8, "LOG_LIB", "") orelse @panic("missing LOG_LIB");
    const GLESV3_LIB = b.option([]const u8, "GLESV3_LIB", "") orelse @panic("missing GLESV3_LIB");
    _ = ANDROID_LIB;
    _ = LOG_LIB;
    _ = GLESV3_LIB;

    const target_info = target_map.get(CMAKE_ANDROID_ARCH_ABI) orelse @panic("TODO support android arch abi");
    const SYS_INCLUDE_DIR = b.fmt("{s}/{s}", .{ INCLUDE_DIR, target_info.dir });
    const target = b.resolveTargetQuery(try std.Target.Query.parse(.{ .arch_os_abi = target_info.triple }));
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
    make_libc_file.addArg("msvc_lib_dir=");
    make_libc_file.addArg("kernel32_lib_dir=");
    make_libc_file.addArg("gcc_dir=");
    const make_libc_stdout = make_libc_file.captureStdOut();

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);

    // https://github.com/ziglang/zig/issues/20327#issuecomment-2382059477 we need to specify a libc file
    // for every addStaticLibrary, addDynamicLibrary call otherwise this won't compile
    const app_dep = b.dependency("app", .{ .target = target, .optimize = optimize });

    const lib = b.addStaticLibrary(.{
        .name = "zigpart",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    b.installArtifact(lib);

    lib.setLibCFile(make_libc_stdout);
    lib.step.dependOn(&make_libc_file.step); // work around bug where setLibCFile doesn't add the step dependency
    lib.linkLibC();
    lib.root_module.addImport("app", app_dep.module("blockeditor"));

    // HACK: fish out every dependency's Compile steps and set thier libc files (& depend on the step).
    // needed until zig has an answer for libc txt in pkg trees.
    if (true) {
        var id_iter = b.initialized_deps.valueIterator();
        while (id_iter.next()) |itm| {
            for (itm.*.builder.install_tls.step.dependencies.items) |dep_step| {
                const inst = dep_step.cast(std.Build.Step.InstallArtifact) orelse continue;
                if (inst.artifact.rootModuleTarget().abi == .android) {
                    inst.artifact.setLibCFile(make_libc_stdout);
                    inst.artifact.step.dependOn(&make_libc_file.step);
                }
            }
        }
    }
}
