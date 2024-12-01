const std = @import("std");
const beui_impl_glfw_wgpu = @import("beui_impl_glfw_wgpu");
const beui_impl_web = @import("beui_impl_web");

const Platform = enum { android, web, glfw_wgpu };
pub const App = struct {
    name: []const u8,
    bin_name: []const u8,
    kind: Platform,
    emitted_file: std.Build.LazyPath,

    dep: ?*std.Build.Dependency,
};

pub const AppCfg = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: AppOpts,

    module: *std.Build.Module,
    name: []const u8,
};
pub const AppOpts = struct {
    platform: Platform,

    // glfw_wgpu
    tracy: bool,

    // web
    port: u16,

    pub fn passIn(self: *const AppOpts, b: *std.Build) []const u8 {
        return std.json.stringifyAlloc(b.allocator, self, .{}) catch @panic("oom");
    }
};

pub fn standardAppOptions(b: *std.Build) AppOpts {
    if (b.option([]const u8, "opts", "")) |opts_val| {
        return std.json.parseFromSliceLeaky(AppOpts, b.allocator, opts_val, .{}) catch @panic("bad opts arg");
    } else {
        return .{
            .platform = b.option(Platform, "platform", "Platform to build app for") orelse .glfw_wgpu,
            .tracy = b.option(bool, "tracy", "[glfw-wgpu] Use tracy?") orelse false,
            .port = b.option(u16, "port", "[web] Port to serve from?") orelse 3556,
        };
    }
}

pub fn createApp(b: *std.Build, cfg: AppCfg) *App {
    // choose
    const app_res = b.allocator.create(App) catch @panic("oom");
    switch (cfg.opts.platform) {
        .android => {
            // `zig build -Dplatform=android` -> error ("TODO setup & build instructions")
            // `zig build -Dplatform=android -D_android_options=....` (called from cmake) -> builds (that way we can eliminate
            //   beui_impl_android depending on blockeditor and instead have android build blockeditor for android)
            const fail_step = b.addFail("TODO android setup & build instructions");
            const fail_genf = b.allocator.create(std.Build.GeneratedFile) catch @panic("oom");
            fail_genf.* = .{ .step = &fail_step.step };
            app_res.* = .{
                .name = b.dupe(cfg.name),
                .bin_name = b.dupe(cfg.name),
                .emitted_file = .{ .generated = .{ .file = fail_genf } },
                .kind = .android,
                .dep = null,
            };
        },
        .web => {
            const beui_impl_web_dep = b.dependencyFromBuildZig(@This(), .{}).builder.dependencyFromBuildZig(beui_impl_web, .{ .target = cfg.target, .optimize = cfg.optimize, .port = cfg.opts.port });

            app_res.* = .{
                .name = b.dupe(cfg.name),
                .bin_name = b.fmt("{s}.site", .{cfg.name}),
                .emitted_file = beui_impl_web.createApp(cfg.name, beui_impl_web_dep, cfg.module),
                .kind = .web,
                .dep = beui_impl_web_dep,
            };
        },
        .glfw_wgpu => {
            const beui_impl_glfw_wgpu_dep = b.dependencyFromBuildZig(@This(), .{}).builder.dependencyFromBuildZig(beui_impl_glfw_wgpu, .{ .target = cfg.target, .optimize = cfg.optimize, .tracy = cfg.opts.tracy });

            app_res.* = .{
                .name = b.dupe(cfg.name),
                .bin_name = std.zig.binNameAlloc(b.allocator, .{
                    .root_name = cfg.name,
                    .target = cfg.target.result,
                    .output_mode = .Exe,
                }) catch @panic("oom"),
                .emitted_file = beui_impl_glfw_wgpu.createApp(cfg.name, beui_impl_glfw_wgpu_dep, cfg.module),
                .kind = .glfw_wgpu,
                .dep = beui_impl_glfw_wgpu_dep,
            };
        },
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

pub fn addInstallApp(b: *std.Build, the_app: *App, dir: std.Build.InstallDir) std.Build.LazyPath {
    const genf = b.allocator.create(std.Build.GeneratedFile) catch @panic("oom");
    if (the_app.kind == .web) {
        const id_step = b.addInstallDirectory(.{
            .source_dir = the_app.emitted_file,
            .install_dir = dir,
            .install_subdir = the_app.bin_name,
        });
        genf.* = .{ .step = &id_step.step, .path = b.getInstallPath(dir, the_app.bin_name) };
    } else {
        const if_step = b.addInstallFileWithDir(the_app.emitted_file, dir, the_app.bin_name);
        genf.* = .{ .step = &if_step.step, .path = b.getInstallPath(dir, the_app.bin_name) };
    }
    return .{ .generated = .{ .file = genf } };
}
/// unlinke b.installArtifact(), this one returns *InstallApp instead of void because it is
/// needed to be passed into addRunApp
pub fn installApp(b: *std.Build, the_app: *App) std.Build.LazyPath {
    const lp = addInstallApp(b, the_app, .bin);
    lp.addStepDependencies(b.getInstallStep());
    return lp;
}
pub fn addRunApp(b: *std.Build, the_app: *App, install_step: ?std.Build.LazyPath) *std.Build.Step.Run {
    switch (the_app.kind) {
        .glfw_wgpu => return beui_impl_glfw_wgpu.runApp(the_app.dep.?, if (install_step) |s| s else the_app.emitted_file),
        .web => return beui_impl_web.runApp(the_app.dep.?, if (install_step) |s| s else the_app.emitted_file),
        else => {
            const res = std.Build.Step.Run.create(b, "fail");
            const fail_step = b.addFail(b.fmt("TODO addRunApp: {s}", .{@tagName(the_app.kind)}));
            the_app.emitted_file.addStepDependencies(&fail_step.step);
            if (install_step) |is| is.addStepDependencies(&fail_step.step);
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
