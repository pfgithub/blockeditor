const std = @import("std");
const beui_impl_glfw_wgpu = @import("beui_impl_glfw_wgpu");
const beui_impl_web = @import("beui_impl_web");

const AppKind = enum { android, web, glfw_wgpu };
pub const App = struct {
    name: []const u8,
    kind: AppKind,
    emitted_file: std.Build.LazyPath,

    dep: ?*std.Build.Dependency,
};

pub const AppCfg = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tracy: bool,

    module: *std.Build.Module,
    name: []const u8,
};

pub fn createApp(b: *std.Build, cfg: AppCfg) *App {
    // choose
    // TODO -Dplatform=<AppKind>
    const app_res = b.allocator.create(App) catch @panic("oom");
    if (cfg.target.result.abi.isAndroid()) {
        const fail_step = b.addFail("TODO android setup & build instructions");
        const fail_genf = b.allocator.create(std.Build.GeneratedFile) catch @panic("oom");
        fail_genf.* = .{ .step = &fail_step.step };
        app_res.* = .{
            .name = b.fmt("android: {s}", .{cfg.name}),
            .emitted_file = .{ .generated = .{ .file = fail_genf } },
            .kind = .android,
            .dep = null,
        };
    } else if (cfg.target.result.cpu.arch.isWasm()) {
        const fail_step = b.addFail("TODO web");
        const fail_genf = b.allocator.create(std.Build.GeneratedFile) catch @panic("oom");
        fail_genf.* = .{ .step = &fail_step.step };
        app_res.* = .{
            .name = b.fmt("web: {s}", .{cfg.name}),
            .emitted_file = .{ .generated = .{ .file = fail_genf } },
            .kind = .web,
            .dep = null,
        };
    } else {
        const beui_impl_glfw_wgpu_dep = b.dependencyFromBuildZig(@This(), .{}).builder.dependencyFromBuildZig(beui_impl_glfw_wgpu, .{ .target = cfg.target, .optimize = cfg.optimize, .tracy = cfg.tracy });

        app_res.* = .{
            .name = b.fmt("glfw_wgpu: {s}", .{cfg.name}),
            .emitted_file = beui_impl_glfw_wgpu.createApp(cfg.name, beui_impl_glfw_wgpu_dep, cfg.module),
            .kind = .glfw_wgpu,
            .dep = beui_impl_glfw_wgpu_dep,
        };
    }
    return app_res;
}
pub fn addApp(b: *std.Build, name: []const u8, opts: AppCfg) *App {
    const app_res = createApp(b, opts);
    exposeArbitrary(b, name, App, app_res);
    return app_res;
}
pub fn app(dep: *std.Build.Dependency, name: []const u8) *App {
    return findArbitrary(dep, App, name);
}

pub fn addInstallApp(b: *std.Build, the_app: *App, dir: std.Build.InstallDir, new_name: ?[]const u8) *InstallApp {
    return InstallApp.create(b, the_app, dir, new_name);
}
/// unlinke b.installArtifact(), this one returns *InstallApp instead of void because it is
/// needed to be passed into addRunApp
pub fn installApp(b: *std.Build, the_app: *App) *InstallApp {
    const step = addInstallApp(b, the_app, .bin, null);
    b.getInstallStep().dependOn(&step.step);
    return step;
}
pub fn addRunApp(b: *std.Build, the_app: *App, install_step: ?*InstallApp) *std.Build.Step.Run {
    switch (the_app.kind) {
        .glfw_wgpu => return beui_impl_glfw_wgpu.runApp(the_app.dep.?, if (install_step) |s| s.getInstalledFile() else the_app.emitted_file),
        else => {
            const res = std.Build.Step.Run.create(b, "fail");
            const fail_step = b.addFail(b.fmt("TODO addRunApp: {s}", .{@tagName(the_app.kind)}));
            const fail_genf = b.allocator.create(std.Build.GeneratedFile) catch @panic("oom");
            fail_genf.* = .{ .step = &fail_step.step };
            res.addFileArg(.{ .generated = .{ .file = fail_genf } });
            return res;
        },
    }
}

pub fn build(b: *std.Build) !void {
    const format_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&format_step.step);
}

pub const InstallApp = struct {
    const Step = std.Build.Step;
    const LazyPath = std.Build.LazyPath;
    const InstallDir = std.Build.InstallDir;
    const InstallFile = @This();
    const assert = std.debug.assert;

    pub const base_id: Step.Id = .custom;

    step: Step,
    app: *App,
    dir: InstallDir,
    result: std.Build.GeneratedFile,
    new_name: ?[]const u8,

    pub fn create(
        owner: *std.Build,
        the_app: *App,
        dir: InstallDir,
        new_name: ?[]const u8,
    ) *InstallApp {
        const install_file = owner.allocator.create(InstallApp) catch @panic("OOM");
        install_file.* = .{
            .step = Step.init(.{
                .id = base_id,
                .name = owner.fmt("install {s}", .{the_app.name}),
                .owner = owner,
                .makeFn = make,
            }),
            .app = the_app,
            .dir = dir.dupe(owner),
            .result = .{ .step = &install_file.step },
            .new_name = if (new_name) |n| owner.dupe(n) else null,
        };
        install_file.app.emitted_file.addStepDependencies(&install_file.step);
        return install_file;
    }

    pub fn getInstalledFile(self: *InstallApp) std.Build.LazyPath {
        return .{ .generated = .{ .file = &self.result } };
    }

    fn make(step: *Step, options: Step.MakeOptions) !void {
        _ = options;
        const b = step.owner;
        const install_app: *InstallApp = @fieldParentPtr("step", step);
        try step.singleUnchangingWatchInput(install_app.app.emitted_file);

        const full_src_path = install_app.app.emitted_file.getPath2(b, step);
        const full_dest_path = b.getInstallPath(install_app.dir, install_app.new_name orelse std.fs.path.basename(full_src_path));
        const cwd = std.fs.cwd();
        const prev = std.fs.Dir.updateFile(cwd, full_src_path, cwd, full_dest_path, .{}) catch |err| {
            return step.fail("unable to update file from '{s}' to '{s}': {s}", .{
                full_src_path, full_dest_path, @errorName(err),
            });
        };
        install_app.result.path = full_dest_path;
        step.result_cached = prev == .fresh;
    }
};

const AnyPtr = struct {
    id: [*]const u8,
    val: *anyopaque,
};
fn exposeArbitrary(b: *std.Build, name: []const u8, comptime ty: type, val: *ty) void {
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
fn findArbitrary(dep: *std.Build.Dependency, comptime ty: type, name: []const u8) *ty {
    const name_fmt = dep.builder.fmt("__exposearbitrary_{s}", .{name});
    const modv = dep.module(name_fmt);
    // HACKHACKHACK
    const anyptr: *const AnyPtr = @ptrCast(@alignCast(modv.owner));
    std.debug.assert(anyptr.id == @typeName(ty));
    return @ptrCast(@alignCast(anyptr.val));
}
