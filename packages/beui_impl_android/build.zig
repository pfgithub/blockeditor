const std = @import("std");

const TargetInfo = struct {
    triple: []const u8,
    dir: []const u8,
};

const target_map = std.StaticStringMap(TargetInfo).initComptime(.{
    .{ "armeabi-v7a", TargetInfo{ .triple = "arm-linux-androideabi", .dir = "arm-linux-androideabi" } },
    .{ "arm64-v8a", TargetInfo{ .triple = "aarch64-linux-android", .dir = "aarch64-linux-android" } },
    .{ "x86", TargetInfo{ .triple = "x86-linux-android", .dir = "i686-linux-android" } },
    .{ "x86_64", TargetInfo{ .triple = "x86_64-linux-android", .dir = "x86_64-linux-android" } },
});

pub const BuildCache = struct {
    INCLUDE_DIR: ?[]const u8 = null,
    CRT1_PATH: ?[]const u8 = null,
    CMAKE_ANDROID_ARCH_ABI: ?[]const u8 = null,
    ANDROID_LIB: ?[]const u8 = null,
    ANDROID_PLATFORM: ?[]const u8 = null,
    LOG_LIB: ?[]const u8 = null,
    GLESV3_LIB: ?[]const u8 = null,

    pub fn toJson(opts: BuildCache, arena: std.mem.Allocator) []const u8 {
        const printed = std.json.stringifyAlloc(arena, opts, .{ .whitespace = .indent_4 }) catch |e| {
            std.log.warn("failed to stringify json: {s}", .{@errorName(e)});
            @panic("failure");
        };
        return printed;
    }
    pub fn fromJsonAllocIfNeeded(arena: std.mem.Allocator, cache_text: []const u8) ?BuildCache {
        return std.json.parseFromSliceLeaky(BuildCache, arena, cache_text, .{ .allocate = .alloc_if_needed }) catch |e| {
            std.log.warn("malformatted build-options-cache: {s}", .{@errorName(e)});
            return null;
        };
    }

    pub fn getTargetOptimize(opts: BuildCache, b: *std.Build) struct { std.Build.ResolvedTarget, std.builtin.OptimizeMode } {
        if (!std.mem.startsWith(u8, opts.ANDROID_PLATFORM.?, "android-")) std.debug.panic("ANDROID_PLATFORM={s}", .{opts.ANDROID_PLATFORM.?});
        const target_info = target_map.get(opts.CMAKE_ANDROID_ARCH_ABI.?) orelse @panic("TODO support android arch abi");
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = b.fmt("{s}.{s}", .{ target_info.triple, opts.ANDROID_PLATFORM.?["android-".len..] }),
        }) catch @panic("bad target query"));
        const optimize: std.builtin.OptimizeMode = .Debug;
        return .{ target, optimize };
    }
};

pub fn buildCacheOptions(b: *std.Build) BuildCache {
    // consider moving into .zig-cache/ of the root
    const cache_file_path = ".build-options-cache.json";
    var opts: BuildCache = blk: {
        const cache_text = b.cache_root.handle.readFileAlloc(b.allocator, cache_file_path, 1000 * 1000) catch |e| {
            std.log.warn("no existing build-options-cache: {s}", .{@errorName(e)});
            break :blk .{};
        };
        break :blk BuildCache.fromJsonAllocIfNeeded(b.allocator, cache_text) orelse .{};
    };

    opts.INCLUDE_DIR = b.option([]const u8, "INCLUDE_DIR", "") orelse opts.INCLUDE_DIR orelse {
        std.log.err(
            \\Android-specific build options have not been provided (missing INCLUDE_DIR).\n
            \\
            \\  - The first build from Android Studio will cache these build options.
            \\  - After this, `zig build` may be used for error checking.
            \\
        , .{});
        std.process.exit(1);
    };
    opts.CRT1_PATH = b.option([]const u8, "CRT1_PATH", "") orelse opts.CRT1_PATH orelse @panic("missing CRT1_PATH");

    opts.CMAKE_ANDROID_ARCH_ABI = b.option([]const u8, "CMAKE_ANDROID_ARCH_ABI", "") orelse opts.CMAKE_ANDROID_ARCH_ABI orelse @panic("missing CMAKE_ANDROID_ARCH_ABI");
    opts.ANDROID_LIB = b.option([]const u8, "ANDROID_LIB", "") orelse opts.ANDROID_LIB orelse @panic("missing ANDROID_LIB");
    opts.ANDROID_PLATFORM = b.option([]const u8, "ANDROID_PLATFORM", "") orelse opts.ANDROID_PLATFORM orelse @panic("missing ANDROID_PLATFORM");
    opts.LOG_LIB = b.option([]const u8, "LOG_LIB", "") orelse opts.LOG_LIB orelse @panic("missing LOG_LIB");
    opts.GLESV3_LIB = b.option([]const u8, "GLESV3_LIB", "") orelse opts.GLESV3_LIB orelse @panic("missing GLESV3_LIB");

    blk: {
        const printed = opts.toJson(b.allocator);

        var atomic_file = b.cache_root.handle.atomicFile(cache_file_path, .{}) catch |e| {
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

    return opts;
}

pub fn createApp(self_dep: *std.Build.Dependency, app_mod: *std.Build.Module) struct { []const u8, []const u8, std.Build.LazyPath } {
    const b = self_dep.builder;
    const pass_info = findArbitrary(self_dep, PassInfo, "pass_info");

    const target = pass_info.target;
    const optimize = pass_info.optimize;
    const opts = pass_info.opts;

    // https://github.com/ziglang/zig/issues/20327#issuecomment-2382059477 we need to specify a libc file
    // for every addStaticLibrary, addDynamicLibrary call otherwise this won't compile
    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });

    const lib = b.addSharedLibrary(.{
        .name = "zigpart",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    b.installArtifact(lib);

    fixAndroidLibcForCompile(lib);
    lib.linkLibC();
    if (target.result.cpu.arch == .x86) lib.link_z_notext = true; // https://github.com/ziglang/zig/issues/7935
    lib.addLibraryPath(.{ .cwd_relative = opts.CRT1_PATH.? });
    lib.linkSystemLibrary("android");
    lib.linkSystemLibrary("log");
    lib.linkSystemLibrary("GLESv3");
    lib.root_module.addImport("app", app_mod);
    lib.root_module.addImport("beui", beui_dep.module("beui"));

    return .{ lib.name, lib.out_filename, lib.getEmittedBin() };
}
var _fix_android_libc: ?std.Build.LazyPath = null;
pub fn fixAndroidLibc(b: *std.Build) void {
    if (_fix_android_libc) |_| {
        // HACK: fish out every dependency's Compile steps and set thier libc files (& depend on the step).
        // needed until zig has an answer for libc txt in pkg trees.
        var id_iter = b.graph.dependency_cache.valueIterator();
        while (id_iter.next()) |itm| {
            fixAndroidLibcForBuilder(itm.*.builder);
        }
        fixAndroidLibcForBuilder(b);
    }
}
fn fixAndroidLibcForBuilder(b: *std.Build) void {
    for (b.install_tls.step.dependencies.items) |dep_step| {
        const inst = dep_step.cast(std.Build.Step.InstallArtifact) orelse continue;
        fixAndroidLibcForCompile(inst.artifact);
    }
}
fn fixAndroidLibcForCompile(lib: *std.Build.Step.Compile) void {
    if (lib.libc_file != null) return; // already handled
    if (_fix_android_libc == null) return;
    if (lib.rootModuleTarget().isAndroid()) {
        lib.setLibCFile(_fix_android_libc.?);
        _fix_android_libc.?.addStepDependencies(&lib.step); // work around bug where setLibCFile doesn't add the step dependency

        // fixPicForModule(b, &lib.root_module);
    }
}

var workaround_applied: bool = false;
fn applyWorkaround(b: *std.Build) void {
    _ = b;
    // defer std.log.warn("Patch applied to lib/libcxx/include/__support/xlocale/__posix_l_fallback.h", .{});
    // if(workaround_applied) return;
    // workaround_applied = true;
    // const zig_lib_dir = b.graph.zig_lib_directory;
    // const fpath = "libcxx/include/__support/xlocale/__posix_l_fallback.h";
    // const current_content = zig_lib_dir.handle.readFileAlloc(b.allocator, fpath, 64000) catch |e| {
    //     std.debug.panic("could not find __posix_l_fallback to apply patch: {s}", .{@errorName(e)});
    // };
    // const prepend = "#define _LIBCPP___SUPPORT_XLOCALE_POSIX_L_FALLBACK_H\n";
    // if(std.mem.startsWith(u8, current_content, prepend)) return; // no patch needed
    // const final_content = std.mem.concat(b.allocator, u8, &.{prepend, current_content}) catch @panic("oom");
    // zig_lib_dir.handle.writeFile(.{.sub_path = fpath, .data = final_content}) catch |e| {
    //     std.debug.panic("failed to apply patch to __posix_l_fallback: {s}", .{@errorName(e)});
    // };
}

const PassInfo = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: BuildCache,
};

pub fn build(b: *std.Build) !void {
    applyWorkaround(b);

    const opts = BuildCache.fromJsonAllocIfNeeded(b.allocator, b.option([]const u8, "android", "android value").?).?;
    const target, const optimize = opts.getTargetOptimize(b);
    const target_info = target_map.get(opts.CMAKE_ANDROID_ARCH_ABI.?) orelse @panic("TODO support android arch abi");
    const SYS_INCLUDE_DIR = b.fmt("{s}/{s}", .{ opts.INCLUDE_DIR.?, target_info.dir });

    const libc_file_builder = b.addExecutable(.{
        .name = "libc_file_builder",
        .target = b.resolveTargetQuery(.{}), // native
        .optimize = .Debug,
        .root_source_file = b.path("src/libc_file_builder.zig"),
    });

    const make_libc_file = b.addRunArtifact(libc_file_builder);
    make_libc_file.addPrefixedDirectoryArg("include_dir=", .{ .cwd_relative = opts.INCLUDE_DIR.? });
    make_libc_file.addPrefixedDirectoryArg("sys_include_dir=", .{ .cwd_relative = SYS_INCLUDE_DIR });
    make_libc_file.addPrefixedDirectoryArg("crt_dir=", .{ .cwd_relative = opts.CRT1_PATH.? });
    make_libc_file.addArg("msvc_lib_dir=");
    make_libc_file.addArg("kernel32_lib_dir=");
    make_libc_file.addArg("gcc_dir=");
    const make_libc_stdout = make_libc_file.captureStdOut();

    if (_fix_android_libc != null) @panic("android libc twice!!! uh oh  oh oh");
    _fix_android_libc = make_libc_stdout;

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);

    const pass_info = try b.allocator.create(PassInfo);
    pass_info.* = .{
        .target = target,
        .optimize = optimize,
        .opts = opts,
    };
    exposeArbitrary(b, "pass_info", PassInfo, pass_info);
}

const AnyPtr = struct {
    id: [*]const u8,
    val: *const anyopaque,
};
fn exposeArbitrary(b: *std.Build, name: []const u8, comptime ty: type, val: *const ty) void {
    const valv = b.allocator.create(AnyPtr) catch @panic("oom");
    valv.* = .{
        .id = @typeName(ty),
        .val = val,
    };
    const name_fmt = b.fmt("__exposearbitrary_{s}", .{name});
    const mod = b.addModule(name_fmt, .{});
    // HACKHACKHACK
    mod.* = undefined;
    mod.owner = @ptrCast(@alignCast(@constCast(valv)));
}
fn findArbitrary(dep: *std.Build.Dependency, comptime ty: type, name: []const u8) *const ty {
    const name_fmt = dep.builder.fmt("__exposearbitrary_{s}", .{name});
    const modv = dep.module(name_fmt);
    // HACKHACKHACK
    const anyptr: *const AnyPtr = @ptrCast(@alignCast(modv.owner));
    std.debug.assert(anyptr.id == @typeName(ty));
    return @ptrCast(@alignCast(anyptr.val));
}
