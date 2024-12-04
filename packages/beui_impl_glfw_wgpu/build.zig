const std = @import("std");
const zig_gamedev = @import("zig_gamedev");

pub fn createApp(name: []const u8, self_dep: *std.Build.Dependency, app_mod: *std.Build.Module) struct { []const u8, []const u8, std.Build.LazyPath } {
    const b = self_dep.builder;

    const options = findArbitrary(self_dep, Options, "options");
    const target = options.target;
    const optimize = options.optimize;
    const enable_tracy = options.enable_tracy;

    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path("src/beui_impl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("beui", beui_dep.module("beui"));

    const anywhere_dep = b.dependency("anywhere", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("anywhere", anywhere_dep.module("anywhere"));

    exe.root_module.addImport("app", app_mod);

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_tracy", enable_tracy);
    exe.root_module.addImport("build_options", build_options.createModule());

    if (enable_tracy) {
        const tracy_dep = b.dependency("tracy", .{
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("tracy__impl", tracy_dep.module("tracy"));
    }

    const zgui = b.dependency("zgui", .{
        .backend = .glfw_wgpu,
        .shared = false,
        .with_implot = false,
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

    const zpool = b.dependency("zpool", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zpool", zpool.module("root"));

    @import("zgpu").addLibraryPathsTo(exe);
    const zgpu = b.dependency("zgpu", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zgpu", zgpu.module("root"));
    exe.linkLibrary(zgpu.artifact("zdawn"));

    return .{ exe.name, exe.out_filename, exe.getEmittedBin() };
}

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enable_tracy: bool,
};

pub fn runApp(self_dep: *std.Build.Dependency, app: std.Build.LazyPath) *std.Build.Step.Run {
    const b = self_dep.builder;

    const options = findArbitrary(self_dep, Options, "options");
    const target = options.target;
    const optimize = options.optimize;
    const enable_tracy = options.enable_tracy;
    const multirun_exe = self_dep.artifact("multirun");

    const run_step = std.Build.Step.Run.create(b, b.fmt("beui_impl_glfw_wgpu_runApp: {s}", .{app.getDisplayName()}));

    if (enable_tracy) {
        if (optimize == .Debug) {
            b.getInstallStep().dependOn(&b.addFail("To use tracy, -Doptimize must be set to a release mode").step);
        }

        const tracy_dep = b.dependency("tracy", .{
            .target = target,
            .optimize = optimize,
        });

        run_step.addArtifactArg(multirun_exe);

        run_step.addArg("|-|");
        run_step.addArtifactArg(tracy_dep.artifact("tracy"));
        run_step.addArg("-a");
        run_step.addArg("127.0.0.1");

        run_step.addArg("|-|");
    }

    run_step.addFileArg(app);

    return run_step;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_tracy = b.option(bool, "tracy", "Enable tracy?") orelse false;

    const options = b.allocator.create(Options) catch @panic("oom");
    options.* = .{ .target = target, .optimize = optimize, .enable_tracy = enable_tracy };
    exposeArbitrary(b, "options", Options, options);

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);

    const multirun_exe = b.addExecutable(.{
        .name = "multirun",
        .root_source_file = b.path("multirun.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
    });
    b.installArtifact(multirun_exe);
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
