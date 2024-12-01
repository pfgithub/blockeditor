const std = @import("std");
const zig_gamedev = @import("zig_gamedev");

pub fn createApp(name: []const u8, self_dep: *std.Build.Dependency, app_mod: *std.Build.Module) std.Build.LazyPath {
    const b = self_dep.builder;

    const options = findArbitrary(self_dep, Options, "options");
    const target = options.target;
    const optimize = options.optimize;

    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path("src/web_impl.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.import_symbols = true; // freetype uses setjmp/longjmp :/ uh oh. also "undefined symbol: main"
    exe.rdynamic = true;

    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("beui", beui_dep.module("beui"));

    exe.root_module.addImport("app", app_mod);

    return exe.getEmittedBin();
}

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn runApp(self_dep: *std.Build.Dependency, app: std.Build.LazyPath) *std.Build.Step.Run {
    const b = self_dep.builder;

    const run_step = std.Build.Step.Run.create(b, b.fmt("beui_impl_glfw_wgpu_runApp: {s}", .{app.getDisplayName()}));

    run_step.addFileArg(app);

    return run_step;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.allocator.create(Options) catch @panic("oom");
    options.* = .{ .target = target, .optimize = optimize };
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
