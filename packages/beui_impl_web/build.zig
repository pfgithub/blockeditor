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
    // how to implement setjmp/longjmp: https://stackoverflow.com/questions/44263019/how-would-setjmp-longjmp-be-implemented-in-webassembly
    exe.rdynamic = true;

    const beui_dep = b.dependency("beui", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("beui", beui_dep.module("beui"));

    exe.root_module.addImport("app", app_mod);

    const bundler = b.addRunArtifact(self_dep.artifact("bundle"));
    bundler.addFileArg(exe.getEmittedBin());
    bundler.addFileArg(b.path("src/index.html"));
    return bundler.addOutputFileArg(b.fmt("{s}", .{name}));
}

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    port: u16,
};

pub fn runApp(self_dep: *std.Build.Dependency, app: std.Build.LazyPath) *std.Build.Step.Run {
    const b = self_dep.builder;

    const options = findArbitrary(self_dep, Options, "options");

    const run_step = b.addRunArtifact(self_dep.artifact("server"));
    run_step.addFileArg(app);
    run_step.addArg(b.fmt("{d}", .{options.port}));

    return run_step;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const port = b.option(u16, "port", "port") orelse @panic("missing port option");

    const options = b.allocator.create(Options) catch @panic("oom");
    options.* = .{ .target = target, .optimize = optimize, .port = port };
    exposeArbitrary(b, "options", Options, options);

    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);

    const server_exe = b.addExecutable(.{
        .name = "server",
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        .root_source_file = b.path("src/server.zig"),
    });
    // waiting on https://github.com/ziglang/zig/issues/21525 : for now, it will always fetch the dependency
    // even if server_exe is never compiled
    if (b.lazyDependency("mime", .{
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
    })) |mime_dep| {
        server_exe.root_module.addImport("mime", mime_dep.module("mime"));
    }
    b.installArtifact(server_exe);

    const bundle_exe = b.addExecutable(.{
        .name = "bundle",
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        .root_source_file = b.path("src/bundle.zig"),
    });
    b.installArtifact(bundle_exe);
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
