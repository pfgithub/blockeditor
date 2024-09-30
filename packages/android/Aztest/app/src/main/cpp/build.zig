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

const BuildCache = struct {
    INCLUDE_DIR: ?[]const u8 = null,
    CRT1_PATH: ?[]const u8 = null,
    CMAKE_ANDROID_ARCH_ABI: ?[]const u8 = null,
    ANDROID_LIB: ?[]const u8 = null,
    LOG_LIB: ?[]const u8 = null,
    GLESV3_LIB: ?[]const u8 = null,
};

pub fn build(b: *std.Build) !void {
    const cache_file_path = b.path(".build-options-cache.json").getPath(b);
    var opts: BuildCache = blk: {
        const cache_text = std.fs.cwd().readFileAlloc(b.allocator, cache_file_path, 1000 * 1000) catch |e| {
            std.log.warn("no existing build-options-cache: {s} {s}", .{ @errorName(e), @src().file });
            break :blk .{};
        };
        break :blk std.json.parseFromSliceLeaky(BuildCache, b.allocator, cache_text, .{ .allocate = .alloc_if_needed }) catch |e| {
            std.log.warn("malformatted build-options-cache: {s}", .{@errorName(e)});
            break :blk .{};
        };
    };

    opts.INCLUDE_DIR = b.option([]const u8, "INCLUDE_DIR", "") orelse opts.INCLUDE_DIR orelse @panic("missing INCLUDE_DIR");
    opts.CRT1_PATH = b.option([]const u8, "CRT1_PATH", "") orelse opts.CRT1_PATH orelse @panic("missing CRT1_PATH");

    opts.CMAKE_ANDROID_ARCH_ABI = b.option([]const u8, "CMAKE_ANDROID_ARCH_ABI", "") orelse opts.CMAKE_ANDROID_ARCH_ABI orelse @panic("missing CMAKE_ANDROID_ARCH_ABI");
    opts.ANDROID_LIB = b.option([]const u8, "ANDROID_LIB", "") orelse opts.ANDROID_LIB orelse @panic("missing ANDROID_LIB");
    opts.LOG_LIB = b.option([]const u8, "LOG_LIB", "") orelse opts.LOG_LIB orelse @panic("missing LOG_LIB");
    opts.GLESV3_LIB = b.option([]const u8, "GLESV3_LIB", "") orelse opts.GLESV3_LIB orelse @panic("missing GLESV3_LIB");

    blk: {
        const printed = std.json.stringifyAlloc(b.allocator, opts, .{ .whitespace = .indent_4 }) catch |e| {
            std.log.warn("failed to stringify json: {s}", .{@errorName(e)});
            break :blk;
        };

        var atomic_file = std.fs.cwd().atomicFile(cache_file_path, .{}) catch |e| {
            std.log.warn("failed to open json output file: {s}", .{@errorName(e)});
            break :blk;
        };
        defer atomic_file.deinit();
        atomic_file.file.writeAll(printed) catch |e| {
            std.log.warn("failed to writeAll build-options-cache.json: {s}", .{@errorName(e)});
            break :blk;
        };
        atomic_file.finish() catch |e| {
            std.log.warn("failed to finish json output file: {s}", .{@errorName(e)});
            break :blk;
        };
    }

    const target_info = target_map.get(opts.CMAKE_ANDROID_ARCH_ABI.?) orelse @panic("TODO support android arch abi");
    const SYS_INCLUDE_DIR = b.fmt("{s}/{s}", .{ opts.INCLUDE_DIR.?, target_info.dir });
    const target = b.resolveTargetQuery(try std.Target.Query.parse(.{ .arch_os_abi = target_info.triple }));
    const optimize: std.builtin.OptimizeMode = .Debug;

    const libc_file_builder = b.addExecutable(.{
        .name = "libc_file_builder",
        .target = b.resolveTargetQuery(.{}), // native
        .optimize = .Debug,
        .root_source_file = b.path("libc_file_builder.zig"),
    });

    const make_libc_file = b.addRunArtifact(libc_file_builder);
    make_libc_file.addPrefixedDirectoryArg("include_dir=", .{ .cwd_relative = opts.INCLUDE_DIR.? });
    make_libc_file.addPrefixedDirectoryArg("sys_include_dir=", .{ .cwd_relative = SYS_INCLUDE_DIR });
    make_libc_file.addPrefixedDirectoryArg("crt_dir=", .{ .cwd_relative = opts.CRT1_PATH.? });
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

    const lib = b.addSharedLibrary(.{
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
    lib.addLibraryPath(.{ .cwd_relative = opts.CRT1_PATH.? });
    lib.linkSystemLibrary("android");
    lib.linkSystemLibrary("log");
    lib.linkSystemLibrary("GLESv3");
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
