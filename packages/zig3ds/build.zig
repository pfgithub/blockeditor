const std = @import("std");
const anywhere = @import("anywhere");

fn addTool(b: *std.Build, dep: *std.Build.Dependency, tool_name: []const u8, files: []const []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = tool_name,
        .target = b.resolveTargetQuery(.{}), // native
        .optimize = .ReleaseSafe,
    });

    exe.linkLibC();
    exe.linkLibCpp();
    exe.addCSourceFiles(.{
        .root = dep.path("."),
        .files = files,
        .flags = &.{
            b.fmt("-DPACKAGE_STRING=\"{s}\"", .{tool_name}),
            "-D__DATE__=\"disabled\"",
            "-D__TIME__=\"disabled\"",
            // "-fno-sanitize=undefined",
        },
    });
    exe.addIncludePath(dep.path("."));

    const insa = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "3dstools" } },
    });
    b.getInstallStep().dependOn(&insa.step);

    return exe;
}

pub const CIncluder = struct {
    //! addStaticLibrary + linkLibrary() has this functionality already
    //! however, it doesn't support define_macros, which we need for libc.
    //! also, it probably doesn't support merging headers from a few
    //! different folders, which we also need for libc.
    //!
    //! zig also limits it so all headers in one build.zig need to output
    //! to the same directory, but we're exporting multiple seperate
    //! packages with seperate headers, and they need to stay seperate.

    const DefineMacro = struct { []const u8, ?[]const u8 };
    owner: *std.Build,
    define_macros: []const DefineMacro,
    add_include_paths: []const std.Build.LazyPath,

    pub const Options = struct {
        define_macros: []const DefineMacro = &.{},
        add_include_paths: []const std.Build.LazyPath = &.{},
    };

    pub fn createCIncluder(b: *std.Build, options: Options) *CIncluder {
        const ci = b.allocator.create(CIncluder) catch @panic("oom");
        ci.* = .{
            .owner = b,
            .define_macros = b.allocator.dupe(DefineMacro, options.define_macros) catch @panic("oom"),
            .add_include_paths = b.allocator.dupe(std.Build.LazyPath, options.add_include_paths) catch @panic("oom"),
        };
        return ci;
    }

    pub fn expose(self: *const CIncluder, name: []const u8) void {
        anywhere.util.build.expose(self.owner, name, *const CIncluder, self);
    }
    pub fn find(dep: *std.Build.Dependency, name: []const u8) *const CIncluder {
        return anywhere.util.build.find(dep, *const CIncluder, name);
    }

    pub fn applyTo(self: *const CIncluder, mod: *std.Build.Module) void {
        for (self.define_macros) |m| mod.addCMacro(m[0], m[1] orelse "1");
        for (self.add_include_paths) |ip| mod.addIncludePath(ip);
    }
};

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    const target_3ds = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = "arm-freestanding-gnueabihf",
        .cpu_features = "mpcore",
    }) catch @panic("bad target"));

    // 1. we need 3dstools
    const @"3dstools_dep" = b.dependency("3dstools", .{});
    const @"3dstools_cxitool_dep" = b.dependency("3dstools-cxitool", .{});
    const general_tools_dep = b.dependency("general-tools", .{});
    const picasso_dep = b.dependency("picasso", .{});
    // elf -> .3dsx
    const tool_3dsxtool = addTool(b, @"3dstools_dep", "3dsxtool", &[_][]const u8{
        "src/3dsxtool.cpp",
        "src/romfs.cpp",
    });
    // .3dsx -> .cia
    _ = addTool(b, @"3dstools_cxitool_dep", "cxitool", &[_][]const u8{
        "src/cxitool.cpp",
        "src/CxiBuilder.cpp",
        "src/CxiSettings.cpp",
        "src/CxiExeFS.cpp",
        "src/CxiRomFS.cpp",
        "src/blz.c",
        "src/3dsx_loader.cpp",
        "src/crypto.cpp",
        "src/polarssl/aes.c",
        "src/polarssl/rsa.c",
        "src/polarssl/sha1.c",
        "src/polarssl/sha2.c",
        "src/polarssl/base64.c",
        "src/polarssl/bignum.c",
        "src/YamlReader.cpp",
        "src/libyaml/api.c",
        "src/libyaml/dumper.c",
        "src/libyaml/emitter.c",
        "src/libyaml/loader.c",
        "src/libyaml/parser.c",
        "src/libyaml/reader.c",
        "src/libyaml/scanner.c",
        "src/libyaml/writer.c",
    });
    // .bin -> .s & .h
    const bin2s_tool = addTool(b, general_tools_dep, "bin2s", &[_][]const u8{
        "bin2s.c",
    });
    // .pica -> .shbin
    const tool_picasso = addTool(b, picasso_dep, "picasso", &[_][]const u8{
        "source/picasso_assembler.cpp",
        "source/picasso_frontend.cpp",
    });

    const libctru_dep = b.dependency("libctru", .{});
    const crtls_dep = b.dependency("devkitarm-crtls", .{});
    const newlib_dep = b.dependency("newlib", .{});
    const examples_dep = b.dependency("3ds-examples", .{});
    const anywhere_dep = b.dependency("anywhere", .{});

    // build_helper
    const build_helper = try b.allocator.create(T3dsBuildHelper);
    anywhere.util.build.expose(b, "build_helper", *const T3dsBuildHelper, build_helper);
    build_helper.* = .{
        .owner = b,
        .target = target_3ds,
        .tool_3dsxtool = tool_3dsxtool,
        .tool_bin2s = bin2s_tool,
        .tool_picasso = tool_picasso,
        .crtls_dep = crtls_dep,
        .cflags = b.dupeStrings(&.{
            "-mtp=soft",
            "-fno-sanitize=undefined", // :/
            "-Wno-return-type", // :/ :/ `newlib/libc/sys/arm/sys/lock.h:51:1`
        }),
    };

    // newlib
    const libc_includer = CIncluder.createCIncluder(b, .{
        .define_macros = &.{
            .{ "_LIBC", null },
            .{ "__DYNAMIC_REENT__", null },
            .{ "GETREENT_PROVIDED", null },
            .{ "REENTRANT_SYSCALLS_PROVIDED", null },
            .{ "__DEFAULT_UTF8__", null },
            .{ "_LDBL_EQ_DBL", null },
            .{ "_HAVE_INITFINI_ARRAY", null },
            .{ "_MB_CAPABLE", null },
            .{ "__3DS__", null },
        },
        .add_include_paths = &.{
            b.path("src/newlib_defines"),
            newlib_dep.path("newlib/libc/sys/arm"),
            newlib_dep.path("newlib/libc/machine/arm"),
            newlib_dep.path("newlib/libc/include"),
        },
    });
    libc_includer.expose("c");

    // libgloss_libsysbase
    const libgloss_libsysbase = b.addObject(.{
        .name = "sysbase",
        .target = target_3ds,
        .optimize = optimize,
    });
    libc_includer.applyTo(libgloss_libsysbase.root_module);
    libgloss_libsysbase.addIncludePath(b.path("src/config_fix"));
    libgloss_libsysbase.root_module.addCMacro("_BUILDING_LIBSYSBASE", "");
    libgloss_libsysbase.addCSourceFiles(.{
        .root = newlib_dep.path("libgloss/libsysbase"),
        .files = libgloss_libsysbase_files,
        .flags = build_helper.cflags,
    });

    // newlib (libc)
    const libc = b.addStaticLibrary(.{
        .name = "c",
        .target = target_3ds,
        .optimize = optimize,
    });
    libc_includer.applyTo(libc.root_module);
    libc.addCSourceFiles(.{
        .root = newlib_dep.path("newlib/libc"),
        .files = newlib_libc_files,
        .flags = build_helper.cflags,
    });
    libc.addAssemblyFile(crtls_dep.path("3dsx_crt0.s"));
    libc.addObject(libgloss_libsysbase);
    b.installArtifact(libc);

    const libc_file: std.Build.LazyPath = anywhere.util.build.genLibCFile(b, anywhere_dep, .{
        .include_dir = b.path("src/newlib_defines"),
        .sys_include_dir = b.path("src/newlib_defines"),
        .crt_dir = b.path("src/newlib_defines"),
        .msvc_lib_dir = null,
        .kernel32_lib_dir = null,
        .gcc_dir = null,
    });
    b.addNamedLazyPath("c", libc_file);

    // libm
    const libm = b.addStaticLibrary(.{
        .name = "m",
        .target = target_3ds,
        .optimize = optimize,
    });
    libc_includer.applyTo(libm.root_module);
    libm.addCSourceFiles(.{
        .root = newlib_dep.path("newlib/libm"),
        .files = newlib_libm_files,
        .flags = build_helper.cflags,
    });
    b.installArtifact(libm);

    // libctru
    const libctru_includer = CIncluder.createCIncluder(b, .{
        .add_include_paths = &.{
            b.path("src/asm_fix"),
            libctru_dep.path("libctru/include"),
        },
    });
    libctru_includer.expose("ctru");
    const libctru = b.addStaticLibrary(.{
        .name = "ctru",
        .target = target_3ds,
        .optimize = optimize,
    });
    b.installArtifact(libctru);
    {
        libc_includer.applyTo(libctru.root_module);
        libctru_includer.applyTo(libctru.root_module);

        build_helper.addDir(libctru.root_module, libctru_dep.path("libctru"));
    }

    // citro3d
    const citro3d_dep = b.dependency("citro3d", .{});
    const citro3d_includer = CIncluder.createCIncluder(b, .{
        .add_include_paths = &.{
            citro3d_dep.path("include"),
        },
    });
    citro3d_includer.expose("citro3d");
    const citro3d = b.addStaticLibrary(.{
        .name = "citro3d",
        .target = target_3ds,
        .optimize = optimize,
    });
    b.installArtifact(citro3d);
    libc_includer.applyTo(citro3d.root_module);
    libctru_includer.applyTo(citro3d.root_module);
    citro3d_includer.applyTo(citro3d.root_module);
    build_helper.addDir(citro3d.root_module, citro3d_dep.path("."));

    // citro2d
    const citro2d_dep = b.dependency("citro2d", .{});
    const citro2d_includer = CIncluder.createCIncluder(b, .{
        .add_include_paths = &.{
            citro2d_dep.path("include"),
        },
    });
    citro2d_includer.expose("citro2d");
    const citro2d = b.addStaticLibrary(.{
        .name = "citro2d",
        .target = target_3ds,
        .optimize = optimize,
    });
    b.installArtifact(citro2d);
    libc_includer.applyTo(citro2d.root_module);
    libctru_includer.applyTo(citro2d.root_module);
    citro3d_includer.applyTo(citro2d.root_module);
    citro2d_includer.applyTo(citro2d.root_module);
    build_helper.addDir(citro2d.root_module, citro2d_dep.path("."));

    // 4. build the game
    for (t3ds_examples) |example_t| {
        const example = T3dsExample.from(example_t);
        const example_name = example.name(b.allocator);

        const elf = b.addExecutable(.{
            .name = example_name,
            .target = target_3ds,
            .optimize = optimize,
        });
        build_helper.link(elf);
        build_helper.addDir(elf.root_module, examples_dep.path(example.root_dir));

        if (example.dependencies.c) {
            libc_includer.applyTo(elf.root_module);
            elf.linkLibrary(libc);
            elf.setLibCFile(libc_file);
            libc_file.addStepDependencies(&elf.step);
            elf.linkLibC();
        }
        if (example.dependencies.m) {
            elf.linkLibrary(libm);
        }
        if (example.dependencies.ctru) {
            libctru_includer.applyTo(elf.root_module);
            elf.linkLibrary(libctru);
        }
        if (example.dependencies.citro3d) {
            citro3d_includer.applyTo(elf.root_module);
            elf.linkLibrary(citro3d);
        }
        if (example.dependencies.citro2d) {
            citro2d_includer.applyTo(elf.root_module);
            elf.linkLibrary(citro2d);
        }

        // elf -> 3dsx
        const output_3dsx = build_helper.to3dsx(elf);

        const output_3dsx_install = b.addInstallFileWithDir(output_3dsx, .bin, b.fmt("{s}.3dsx", .{example_name}));
        const output_3dsx_path = b.getInstallPath(.bin, b.fmt("{s}.3dsx", .{example_name}));
        b.getInstallStep().dependOn(&output_3dsx_install.step);

        const run_step = std.Build.Step.Run.create(b, b.fmt("citra run:{s}", .{example_name}));
        run_step.addArg("citra");
        run_step.addArg(output_3dsx_path);
        run_step.step.dependOn(b.getInstallStep());
        const run_step_cmdl = b.step(b.fmt("run:{s}", .{example.root_dir}), b.fmt("Run {s}", .{example.root_dir}));
        run_step_cmdl.dependOn(&run_step.step);
    }
}

pub const T3dsBuildHelper = struct {
    owner: *std.Build,
    target: std.Build.ResolvedTarget,
    tool_3dsxtool: *std.Build.Step.Compile,
    tool_bin2s: *std.Build.Step.Compile,
    tool_picasso: *std.Build.Step.Compile,
    crtls_dep: *std.Build.Dependency,
    cflags: []const []const u8,

    pub fn find(dep: *std.Build.Dependency, name: []const u8) *const T3dsBuildHelper {
        return anywhere.util.build.find(dep, *const T3dsBuildHelper, name);
    }

    pub fn link(bh: *const T3dsBuildHelper, elf: *std.Build.Step.Compile) void {
        elf.linker_script = bh.crtls_dep.path("3dsx.ld"); // -T 3dsx.ld%s

        elf.link_emit_relocs = true; // --emit-relocs
        elf.root_module.strip = false; // can't combine 'strip-all' with 'emit-relocs'
        // TODO: -d: They assign space to common symbols even if a relocatable output file is specified
        // TODO: --use-blx: The ‘--use-blx’ switch enables the linker to use ARM/Thumb BLX instructions (available on ARMv5t and above) in various situations.
        // skipped gc-sections because it seems to have no effect on ReleaseSmall builds
    }

    pub fn to3dsx(bh: *const T3dsBuildHelper, elf: *std.Build.Step.Compile) std.Build.LazyPath {
        const b = elf.root_module.owner;
        const output_3dsx_name = b.fmt("{s}.3dsx", .{elf.name});
        const run_3dsxtool = b.addRunArtifact(bh.tool_3dsxtool);
        run_3dsxtool.addFileArg(elf.getEmittedBin());
        const output_3dsx = run_3dsxtool.addOutputFileArg(output_3dsx_name);
        return output_3dsx;
    }

    pub const Bin2sCfg = struct {
        sym_name: []const u8,
        file_name: []const u8,
    };
    pub fn addBin2s(bh: *const T3dsBuildHelper, mod: *std.Build.Module, file: std.Build.LazyPath, cfg: Bin2sCfg) void {
        const bin2s_run_cmd = bh.owner.addRunArtifact(bh.tool_bin2s);
        bin2s_run_cmd.addArg("-H");
        const h_file = bin2s_run_cmd.addOutputFileArg(bh.owner.fmt("{s}.h", .{cfg.file_name}));
        bin2s_run_cmd.addArg("-n");
        bin2s_run_cmd.addArg(cfg.sym_name);
        bin2s_run_cmd.addFileArg(file);
        const s_file = captureStdoutNamed(bin2s_run_cmd, bh.owner.fmt("{s}.s", .{cfg.file_name}));

        mod.addIncludePath(h_file.dirname());
        mod.addAssemblyFile(s_file);
    }
    pub fn addPica(bh: *const T3dsBuildHelper, mod: *std.Build.Module, v_pica: std.Build.LazyPath, g_pica: ?std.Build.LazyPath, name: []const u8) void {
        const picasso_run_cmd = bh.owner.addRunArtifact(bh.tool_picasso);
        picasso_run_cmd.addArg("-o");
        const out_file = picasso_run_cmd.addOutputFileArg(bh.owner.fmt("{s}.shbin", .{name}));
        picasso_run_cmd.addFileArg(v_pica);
        if (g_pica) |gp| picasso_run_cmd.addFileArg(gp);
        bh.addBin2s(mod, out_file, .{
            .sym_name = bh.owner.fmt("{s}_shbin", .{name}),
            .file_name = bh.owner.fmt("{s}_shbin", .{name}),
        });
    }

    fn dotToUnderscore(str: []const u8, alloc: std.mem.Allocator) []const u8 {
        var res = std.ArrayList(u8).init(alloc);
        defer res.deinit();
        for (str) |char| {
            switch (char) {
                '.' => res.append('_') catch @panic("oom"),
                else => res.append(char) catch @panic("oom"),
            }
        }
        return res.toOwnedSlice() catch @panic("oom");
    }

    pub fn addDir(bh: *const T3dsBuildHelper, mod: *std.Build.Module, dir: std.Build.LazyPath) void {
        std.debug.assert(dir == .dependency);

        const source_dir = dir.path(bh.owner, "source");
        const data_dir = dir.path(bh.owner, "data");
        const include_dir = dir.path(bh.owner, "include");
        const gfx_dir = dir.path(bh.owner, "gfx");
        const romfs_dir = dir.path(bh.owner, "romfs");

        const source_files = readAll(bh.owner.allocator, source_dir.getPath(bh.owner));
        const data_files = readAll(bh.owner.allocator, data_dir.getPath(bh.owner));
        const gfx_files = readAll(bh.owner.allocator, gfx_dir.getPath(bh.owner));
        const romfs_files = readAll(bh.owner.allocator, romfs_dir.getPath(bh.owner));

        if (gfx_files.len > 0) std.debug.panic("TODO gfx_files for: {s} (requires tex3ds & has options)", .{dir.getPath(bh.owner)});
        if (romfs_files.len > 0) std.debug.panic("TODO romfs files for: {s}", .{dir.getPath(bh.owner)});

        bh.addFiles(mod, source_dir, source_files);
        bh.addDataFiles(mod, data_dir, data_files);
        mod.addIncludePath(include_dir);
    }
    fn readAll(alloc: std.mem.Allocator, path: []const u8) []const []const u8 {
        var dir_target = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return &.{};
        defer dir_target.close();

        var res_paths = std.ArrayList([]const u8).init(alloc);
        defer res_paths.deinit();

        var dir_walker = dir_target.walk(alloc) catch @panic("walk error");
        defer dir_walker.deinit();
        while (dir_walker.next() catch @panic("next error")) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.basename, ".")) continue;
            res_paths.append(alloc.dupe(u8, entry.path) catch @panic("oom")) catch @panic("oom");
        }
        // TODO sort

        return res_paths.toOwnedSlice() catch @panic("oom");
    }

    // https://github.com/devkitPro/devkitarm-rules/blob/master/3ds_rules

    pub fn addDataFiles(bh: *const T3dsBuildHelper, mod: *std.Build.Module, files_root: std.Build.LazyPath, files: []const []const u8) void {
        for (files) |file| {
            bh.addBin2s(mod, files_root.path(bh.owner, file), .{
                .sym_name = dotToUnderscore(file, bh.owner.allocator),
                .file_name = dotToUnderscore(file, bh.owner.allocator),
            });
        }
    }

    /// in the future, this could add a custom step that does a directory scan to discover all the files
    pub fn addFiles(bh: *const T3dsBuildHelper, mod: *std.Build.Module, files_root: std.Build.LazyPath, files: []const []const u8) void {
        const b = bh.owner;
        var c_source_files = std.ArrayList([]const u8).init(bh.owner.allocator);
        defer c_source_files.deinit();
        var s_source_files = std.ArrayList([]const u8).init(bh.owner.allocator);
        defer s_source_files.deinit();

        for (files) |file| {
            if (std.mem.endsWith(u8, file, ".c") or std.mem.endsWith(u8, file, ".cpp")) {
                c_source_files.append(file) catch @panic("oom");
            } else if (std.mem.endsWith(u8, file, ".v.pica")) {
                // unfortunately, we have to check if there is an adjacent `.g.pica` file to
                // call picasso with both

                const v_pica = files_root.path(bh.owner, file);
                const filebasename = bh.owner.dupe(std.fs.path.basename(file));
                const fileflatname = filebasename[0 .. filebasename.len - ".v.pica".len];
                const g_pica_lazypath = v_pica.dirname().path(bh.owner, bh.owner.fmt("{s}.g.pica", .{fileflatname}));
                std.debug.assert(files_root == .dependency);
                const g_pica_file_path = g_pica_lazypath.getPath(bh.owner);
                const g_pica: ?std.Build.LazyPath = if (std.fs.accessAbsolute(g_pica_file_path, .{})) |_| blk: {
                    // @panic("has .g.pica file");
                    break :blk g_pica_lazypath;
                } else |_| null;
                bh.addPica(mod, v_pica, g_pica, fileflatname);
            } else if (std.mem.endsWith(u8, file, ".h")) {
                // nothing to do
            } else if (std.mem.endsWith(u8, file, ".s")) {
                s_source_files.append(file) catch @panic("oom");
            } else if (std.mem.endsWith(u8, file, ".g.pica")) {
                // handled in .v.pica
            } else {
                std.debug.panic("TODO ext: `{s}`", .{file});
            }
        }

        if (s_source_files.items.len > 0) {
            // '.s' files are renamed to '.S' before adding to the build
            const asm_files_dir = b.addWriteFiles();

            for (s_source_files.items) |file| {
                const src_path = files_root.path(bh.owner, file);
                const dst_name = b.fmt("{s}.S", .{file[0 .. file.len - ".s".len]});
                const asm_file_lazypath = asm_files_dir.addCopyFile(src_path, dst_name);

                mod.addAssemblyFile(asm_file_lazypath);
            }
        }
        if (c_source_files.items.len > 0) mod.addCSourceFiles(.{
            .root = files_root,
            .files = c_source_files.items,
            .flags = bh.cflags,
        });
    }
};

fn captureStdoutNamed(run: *std.Build.Step.Run, name: []const u8) std.Build.LazyPath {
    std.debug.assert(run.stdio != .inherit);

    std.debug.assert(run.captured_stdout == null);

    const output = run.step.owner.allocator.create(std.Build.Step.Run.Output) catch @panic("OOM");
    output.* = .{
        .prefix = "",
        .basename = name,
        .generated_file = .{ .step = &run.step },
    };
    run.captured_stdout = output;
    return .{ .generated = .{ .file = &output.generated_file } };
}

pub const T3dsDep = struct {
    c: bool = false,
    m: bool = false,
    ctru: bool = false,
    citro3d: bool = false,
    citro2d: bool = false,
};
pub const T3dsExample = struct {
    root_dir: []const u8,
    dependencies: T3dsDep,

    pub fn name(self: *const T3dsExample, alloc: std.mem.Allocator) []const u8 {
        var res_al = std.ArrayList(u8).init(alloc);
        defer res_al.deinit();

        for (self.root_dir) |char| {
            switch (char) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => res_al.append(char) catch @panic("oom"),
                '/' => res_al.appendSlice("__") catch @panic("oom"),
                else => res_al.append('_') catch @panic("oom"),
            }
        }

        return res_al.toOwnedSlice() catch @panic("oom");
    }

    pub fn from(v: ExampleT) T3dsExample {
        var res_dependencies = T3dsDep{};
        for (v[1]) |dep| {
            inline for (std.meta.fields(T3dsDep)) |field| {
                if (dep == @field(T3dsDepEnum, field.name)) {
                    @field(res_dependencies, field.name) = true;
                }
            }
        }
        return .{
            .root_dir = v[0],
            .dependencies = res_dependencies,
        };
    }
};
const T3dsDepEnum = std.meta.FieldEnum(T3dsDep);
const ExampleTOpts = struct { gfx_mode: enum { not_set, embed, romfs } = .not_set };
const ExampleT = struct { []const u8, []const T3dsDepEnum, ExampleTOpts };
const t3ds_examples = &[_]ExampleT{
    .{ "app_launch", &.{ .c, .m, .ctru }, .{} },

    .{ "audio/filters", &.{ .c, .m, .ctru }, .{} },
    .{ "audio/mic", &.{ .c, .m, .ctru }, .{} },
    // .{ "audio/modplug-decoding", &.{ .c, .m, .ctru }, .{} }, // romfs
    // .{ "audio/ogg-vorbis-decoding", &.{ .c, .m, .ctru }, .{} }, // romfs & -lvorbisidec
    // .{ "audio/opus-decoding", &.{ .c, .m, .ctru }, .{} }, // romfs & -lopusfile
    .{ "audio/streaming", &.{ .c, .m, .ctru }, .{} },

    // .{ "camera/image", &.{ .c, .m, .ctru }, .{} }, // have xml files?
    // .{ "camera/video", &.{ .c, .m, .ctru }, .{} }, // also missing setjmp/longjmp & 'clearScreen'
    .{ "get_system_language", &.{ .c, .m, .ctru }, .{} },

    // .{ "graphics/bitmap/24bit-color", &.{ .c, .m, .ctru, .citro3d, .citro2d }, .{ .gfx_include_png = true } },
    .{ "graphics/gpu/2d_shapes", &.{ .c, .m, .ctru, .citro3d, .citro2d }, .{} },
    .{ "graphics/gpu/both_screens", &.{ .c, .m, .ctru, .citro3d }, .{} },
    .{ "graphics/gpu/composite_scene", &.{ .c, .m, .ctru, .citro3d, .citro2d }, .{} },
    // .{ "graphics/gpu/cubemap", &.{ .c, .m, .ctru, .citro3d }, .{} }, // requires tex3ds
    .{ "graphics/gpu/fragment_light", &.{ .c, .m, .ctru, .citro3d }, .{} },
    .{ "graphics/gpu/geoshader", &.{ .c, .m, .ctru, .citro3d }, .{} },
    // .{ "graphics/gpu/gpusprites", &.{ .c, .m, .ctru, .citro3d }, .{} }, // requires tex3ds
    .{ "graphics/gpu/immediate", &.{ .c, .m, .ctru, .citro3d }, .{} },
    .{ "graphics/gpu/lenny", &.{ .c, .m, .ctru, .citro3d }, .{} },
    .{ "graphics/gpu/loop_subdivision", &.{ .c, .m, .ctru, .citro3d }, .{} },
    // .{ "graphics/gpu/mipmap_fog", &.{ .c, .m, .ctru, .citro3d }, .{} }, // requires tex3ds
    .{ "graphics/gpu/multiple_buf", &.{ .c, .m, .ctru, .citro3d }, .{} },
    // .{ "graphics/gpu/normal_mapping", &.{ .c, .m, .ctru, .citro3d }, .{} }, // requires tex3ds
    .{ "graphics/gpu/particles", &.{ .c, .m, .ctru, .citro3d }, .{} },
    .{ "graphics/gpu/proctex", &.{ .c, .m, .ctru, .citro3d }, .{} },
    .{ "graphics/gpu/simple_tri", &.{ .c, .m, .ctru, .citro3d }, .{} },
    // .{ "graphics/gpu/stereoscopic_2d", &.{ .c, .m, .ctru, .citro3d, .citro2d }, .{} }, // requires tex3ds
    // .{ "graphics/gpu/textured_cube", &.{ .c, .m, .ctru, .citro3d }, .{} }, // requires tex3ds
    .{ "graphics/gpu/toon_shading", &.{ .c, .m, .ctru, .citro3d }, .{} },
    .{ "graphics/gpu/wide_mode_3d", &.{ .c, .m, .ctru, .citro3d }, .{} },
    .{ "graphics/printing/both-screen-text", &.{ .c, .m, .ctru }, .{} },
    .{ "graphics/printing/colored-text", &.{ .c, .m, .ctru }, .{} },
    // .{ "graphics/printing/custom-font", &.{ .c, .m, .ctru, .citro3d, .citro2d }, .{ .gfx_mode = .romfs } }, // requires tex3ds
    .{ "graphics/printing/hello-world", &.{ .c, .m, .ctru }, .{} },
    .{ "graphics/printing/multiple-windows-text", &.{ .c, .m, .ctru }, .{} },
    .{ "graphics/printing/system-font", &.{ .c, .m, .ctru, .citro3d, .citro2d }, .{} },
    .{ "graphics/printing/wide-console", &.{ .c, .m, .ctru }, .{} },

    .{ "input/read-controls", &.{ .c, .m, .ctru }, .{} },
    .{ "input/software-keyboard", &.{ .c, .m, .ctru }, .{} },
    .{ "input/touch-screen", &.{ .c, .m, .ctru }, .{} },

    .{ "libapplet_launch", &.{ .c, .m, .ctru }, .{} },
    .{ "mii_selector", &.{ .c, .m, .ctru }, .{} },
    // .{ "mvd", &.{ .c, .m, .ctru }, .{} }, // new 3ds only & needs special build stuff

    .{ "network/3dslink-demo", &.{ .c, .m, .ctru }, .{} },
    .{ "network/boss", &.{ .c, .m, .ctru }, .{} },
    .{ "network/http", &.{ .c, .m, .ctru }, .{} },
    .{ "network/http_post", &.{ .c, .m, .ctru }, .{} },
    .{ "network/sockets", &.{ .c, .m, .ctru }, .{} },
    .{ "network/sslc", &.{ .c, .m, .ctru }, .{} },
    .{ "network/uds", &.{ .c, .m, .ctru }, .{} },

    .{ "nfc", &.{ .c, .m, .ctru }, .{} },
    // .{ "physics/box2d", &.{ .c, .m, .ctru, .box2d }, .{} }, // needs box2d
    .{ "qtm", &.{ .c, .m, .ctru }, .{} },
    // .{ "romfs", &.{ .c, .m, .ctru }, .{} }, // needs build romfs support
    .{ "sdmc", &.{ .c, .m, .ctru }, .{} },

    .{ "templates/application", &.{ .c, .m, .ctru }, .{} },
    // .{ "templates/library", &.{ .c, .m, .ctru }, .{} }, // this is a template for building a library

    .{ "threads/event", &.{ .c, .m, .ctru }, .{} },
    .{ "threads/thread-basic", &.{ .c, .m, .ctru }, .{} },

    .{ "time/rtc", &.{ .c, .m, .ctru }, .{} },
};

const libgloss_libsysbase_files = &[_][]const u8{
    "_exit.c",
    // "abort.c", // prefer newlib abort
    // "assert.c", // prefer newlib assert
    "build_argv.c",
    "chdir.c",
    "chmod.c",
    "clocks.c",
    "concatenate.c",
    "dirent.c",
    // "environ.c", // prefer newlib environ
    "execve.c",
    "fchmod.c",
    "flock.c",
    "fnmatch.c",
    "fork.c",
    "fpathconf.c",
    "fstat.c",
    "fsync.c",
    "ftruncate.c",
    "getpid.c",
    "getreent.c",
    "gettod.c",
    "handle_manager.c",
    "iosupport.c",
    "isatty.c",
    "kill.c",
    "link.c",
    "lseek.c",
    "lstat.c",
    "malloc_vars.c",
    "mkdir.c",
    "pthread.c",
    "nanosleep.c",
    "open.c",
    "pathconf.c",
    "read.c",
    "readlink.c",
    "realpath.c",
    "rename.c",
    "rmdir.c",
    "sbrk.c",
    "scandir.c",
    "sleep.c",
    "stat.c",
    "statvfs.c",
    "symlink.c",
    "syscall_support.c",
    "times.c",
    "truncate.c",
    "unlink.c",
    "usleep.c",
    "utime.c",
    "wait.c",
    "write.c",
};
const newlib_libm_files = &[_][]const u8{
    "common/acoshl.c",
    "common/acosl.c",
    "common/asinhl.c",
    "common/asinl.c",
    "common/atan2l.c",
    "common/atanhl.c",
    "common/atanl.c",
    "common/cbrtl.c",
    "common/ceill.c",
    "common/copysignl.c",
    "common/cosf.c",
    "common/coshl.c",
    "common/cosl.c",
    "common/erfcl.c",
    "common/erfl.c",
    "common/exp.c",
    "common/exp2.c",
    "common/exp2l.c",
    "common/exp_data.c",
    "common/expl.c",
    "common/expm1l.c",
    "common/fabsl.c",
    "common/fdiml.c",
    "common/floorl.c",
    "common/fmal.c",
    "common/fmaxl.c",
    "common/fminl.c",
    "common/fmodl.c",
    "common/frexpl.c",
    "common/hypotl.c",
    "common/ilogbl.c",
    "common/isgreater.c",
    "common/ldexpl.c",
    "common/lgammal.c",
    "common/llrintl.c",
    "common/llroundl.c",
    "common/log.c",
    "common/log10l.c",
    "common/log1pl.c",
    "common/log2.c",
    "common/log2_data.c",
    "common/log2l.c",
    "common/log_data.c",
    "common/logbl.c",
    "common/logl.c",
    "common/lrintl.c",
    "common/lroundl.c",
    "common/math_err.c",
    "common/math_errf.c",
    "common/modfl.c",
    "common/nanl.c",
    "common/nearbyintl.c",
    "common/nextafterl.c",
    "common/nexttoward.c",
    "common/nexttowardf.c",
    "common/nexttowardl.c",
    "common/pow.c",
    "common/pow_log_data.c",
    "common/powl.c",
    "common/remainderl.c",
    "common/remquol.c",
    "common/rintl.c",
    "common/roundl.c",
    "common/s_cbrt.c",
    "common/s_copysign.c",
    "common/s_exp10.c",
    "common/s_expm1.c",
    "common/s_fdim.c",
    "common/s_finite.c",
    "common/s_fma.c",
    "common/s_fmax.c",
    "common/s_fmin.c",
    "common/s_fpclassify.c",
    "common/s_ilogb.c",
    "common/s_infinity.c",
    "common/s_isinf.c",
    "common/s_isinfd.c",
    "common/s_isnan.c",
    "common/s_isnand.c",
    "common/s_llrint.c",
    "common/s_llround.c",
    "common/s_log1p.c",
    "common/s_log2.c",
    "common/s_logb.c",
    "common/s_lrint.c",
    "common/s_lround.c",
    "common/s_modf.c",
    "common/s_nan.c",
    "common/s_nearbyint.c",
    "common/s_nextafter.c",
    "common/s_pow10.c",
    "common/s_remquo.c",
    "common/s_rint.c",
    "common/s_round.c",
    "common/s_scalbln.c",
    "common/s_scalbn.c",
    "common/s_signbit.c",
    "common/s_trunc.c",
    "common/scalblnl.c",
    "common/scalbnl.c",
    "common/sf_cbrt.c",
    "common/sf_copysign.c",
    "common/sf_exp.c",
    "common/sf_exp10.c",
    "common/sf_exp2.c",
    "common/sf_exp2_data.c",
    "common/sf_expm1.c",
    "common/sf_fdim.c",
    "common/sf_finite.c",
    "common/sf_fma.c",
    "common/sf_fmax.c",
    "common/sf_fmin.c",
    "common/sf_fpclassify.c",
    "common/sf_ilogb.c",
    "common/sf_infinity.c",
    "common/sf_isinf.c",
    "common/sf_isinff.c",
    "common/sf_isnan.c",
    "common/sf_isnanf.c",
    "common/sf_llrint.c",
    "common/sf_llround.c",
    "common/sf_log.c",
    "common/sf_log1p.c",
    "common/sf_log2.c",
    "common/sf_log2_data.c",
    "common/sf_log_data.c",
    "common/sf_logb.c",
    "common/sf_lrint.c",
    "common/sf_lround.c",
    "common/sf_modf.c",
    "common/sf_nan.c",
    "common/sf_nearbyint.c",
    "common/sf_nextafter.c",
    "common/sf_pow.c",
    "common/sf_pow10.c",
    "common/sf_pow_log2_data.c",
    "common/sf_remquo.c",
    "common/sf_rint.c",
    "common/sf_round.c",
    "common/sf_scalbln.c",
    "common/sf_scalbn.c",
    "common/sf_trunc.c",
    "common/sincosf.c",
    "common/sincosf_data.c",
    "common/sinf.c",
    "common/sinhl.c",
    "common/sinl.c",
    "common/sl_finite.c",
    "common/sqrtl.c",
    "common/tanhl.c",
    "common/tanl.c",
    "common/tgammal.c",
    "common/truncl.c",
};
const newlib_libc_files = &[_][]const u8{
    "reent/closer.c",
    "reent/execr.c",
    "reent/fcntlr.c",
    // "reent/fstat64r.c",
    "reent/fstatr.c",
    "reent/getentropyr.c",
    "reent/getreent.c",
    "reent/gettimeofdayr.c",
    "reent/impure.c",
    "reent/isattyr.c",
    // "reent/linkr.c", // defines _dummy_link_syscalls when REENTRANT_SYSCALLS_PROVIDED
    // "reent/lseek64r.c",
    "reent/lseekr.c",
    "reent/mkdirr.c",
    // "reent/open64r.c",
    "reent/openr.c",
    "reent/readr.c",
    "reent/reent.c",
    "reent/renamer.c",
    "reent/sbrkr.c",
    // "reent/signalr.c", // defines _dummy_link_syscalls when REENTRANT_SYSCALLS_PROVIDED
    // "reent/stat64r.c",
    "reent/statr.c",
    "reent/timesr.c",
    "reent/unlinkr.c",
    "reent/writer.c",
    "string/bcmp.c",
    "string/bcopy.c",
    "string/bzero.c",
    "string/explicit_bzero.c",
    "string/ffsl.c",
    "string/ffsll.c",
    "string/fls.c",
    "string/flsl.c",
    "string/flsll.c",
    "string/gnu_basename.c",
    "string/index.c",
    "string/memccpy.c",
    "string/memchr.c",
    "string/memcmp.c",
    "string/memcpy.c",
    "string/memmem.c",
    "string/memmove.c",
    "string/mempcpy.c",
    "string/memrchr.c",
    "string/memset.c",
    "string/rawmemchr.c",
    "string/rindex.c",
    "string/stpcpy.c",
    "string/stpncpy.c",
    "string/strcasecmp.c",
    "string/strcasecmp_l.c",
    "string/strcasestr.c",
    "string/strcat.c",
    "string/strchr.c",
    "string/strchrnul.c",
    "string/strcmp.c",
    "string/strcoll.c",
    "string/strcoll_l.c",
    "string/strcpy.c",
    "string/strcspn.c",
    "string/strdup.c",
    "string/strdup_r.c",
    "string/strerror.c",
    "string/strerror_r.c",
    "string/strlcat.c",
    "string/strlcpy.c",
    "string/strlen.c",
    "string/strlwr.c",
    "string/strncasecmp.c",
    // "string/strncasecmp_l.c",
    "string/strncat.c",
    "string/strncmp.c",
    "string/strncpy.c",
    "string/strndup.c",
    "string/strndup_r.c",
    "string/strnlen.c",
    "string/strnstr.c",
    "string/strpbrk.c",
    "string/strrchr.c",
    "string/strsep.c",
    "string/strsignal.c",
    "string/strspn.c",
    "string/strstr.c",
    "string/strtok.c",
    "string/strtok_r.c",
    "string/strupr.c",
    "string/strverscmp.c",
    "string/strxfrm.c",
    "string/strxfrm_l.c",
    "string/swab.c",
    "string/timingsafe_bcmp.c",
    "string/timingsafe_memcmp.c",
    "string/u_strerr.c",
    "string/wcpcpy.c",
    "string/wcpncpy.c",
    // "string/wcscasecmp.c",
    // "string/wcscasecmp_l.c",
    "string/wcscat.c",
    "string/wcschr.c",
    "string/wcscmp.c",
    "string/wcscoll.c",
    "string/wcscoll_l.c",
    "string/wcscpy.c",
    "string/wcscspn.c",
    "string/wcsdup.c",
    "string/wcslcat.c",
    "string/wcslcpy.c",
    "string/wcslen.c",
    // "string/wcsncasecmp.c",
    // "string/wcsncasecmp_l.c",
    "string/wcsncat.c",
    "string/wcsncmp.c",
    "string/wcsncpy.c",
    "string/wcsnlen.c",
    "string/wcspbrk.c",
    "string/wcsrchr.c",
    "string/wcsspn.c",
    "string/wcsstr.c",
    "string/wcstok.c",
    "string/wcswidth.c",
    "string/wcsxfrm.c",
    "string/wcsxfrm_l.c",
    "string/wcwidth.c",
    "string/wmemchr.c",
    "string/wmemcmp.c",
    "string/wmemcpy.c",
    "string/wmemmove.c",
    "string/wmempcpy.c",
    "string/wmemset.c",
    "string/xpg_strerror_r.c",
    "stdlib/_Exit.c",
    "stdlib/__adjust.c",
    "stdlib/__atexit.c",
    "stdlib/__call_atexit.c",
    "stdlib/__exp10.c",
    "stdlib/__ten_mu.c",
    "stdlib/_mallocr.c",
    "stdlib/a64l.c",
    "stdlib/abort.c",
    "stdlib/abs.c",
    "stdlib/aligned_alloc.c",
    // "stdlib/arc4random.c",
    // "stdlib/arc4random_uniform.c",
    "stdlib/assert.c",
    "stdlib/atexit.c",
    "stdlib/atof.c",
    "stdlib/atoff.c",
    "stdlib/atoi.c",
    "stdlib/atol.c",
    "stdlib/atoll.c",
    "stdlib/btowc.c",
    "stdlib/calloc.c",
    "stdlib/callocr.c",
    "stdlib/cfreer.c",
    "stdlib/cxa_atexit.c",
    "stdlib/cxa_finalize.c",
    "stdlib/div.c",
    // "stdlib/drand48.c",
    "stdlib/dtoa.c",
    "stdlib/dtoastub.c",
    "stdlib/ecvtbuf.c",
    "stdlib/efgcvt.c",
    "stdlib/environ.c",
    "stdlib/envlock.c",
    "stdlib/eprintf.c",
    // "stdlib/erand48.c",
    "stdlib/exit.c",
    "stdlib/freer.c",
    "stdlib/gdtoa-dmisc.c",
    "stdlib/gdtoa-gdtoa.c",
    "stdlib/gdtoa-gethex.c",
    "stdlib/gdtoa-gmisc.c",
    "stdlib/gdtoa-hexnan.c",
    "stdlib/gdtoa-ldtoa.c",
    "stdlib/getenv.c",
    "stdlib/getenv_r.c",
    "stdlib/getopt.c",
    "stdlib/getsubopt.c",
    "stdlib/imaxabs.c",
    "stdlib/imaxdiv.c",
    "stdlib/itoa.c",
    "stdlib/jrand48.c",
    "stdlib/l64a.c",
    "stdlib/labs.c",
    "stdlib/lcong48.c",
    "stdlib/ldiv.c",
    "stdlib/ldtoa.c",
    "stdlib/llabs.c",
    "stdlib/lldiv.c",
    "stdlib/lrand48.c",
    "stdlib/malign.c",
    "stdlib/malignr.c",
    "stdlib/mallinfor.c",
    "stdlib/malloc.c",
    "stdlib/mallocr.c",
    "stdlib/malloptr.c",
    "stdlib/mallstatsr.c",
    "stdlib/mblen.c",
    "stdlib/mblen_r.c",
    "stdlib/mbrlen.c",
    "stdlib/mbrtowc.c",
    "stdlib/mbsinit.c",
    "stdlib/mbsnrtowcs.c",
    "stdlib/mbsrtowcs.c",
    "stdlib/mbstowcs.c",
    "stdlib/mbstowcs_r.c",
    "stdlib/mbtowc.c",
    "stdlib/mbtowc_r.c",
    "stdlib/mlock.c",
    "stdlib/mprec.c",
    "stdlib/mrand48.c",
    "stdlib/msize.c",
    "stdlib/msizer.c",
    "stdlib/mstats.c",
    "stdlib/mtrim.c",
    // "stdlib/nano-mallocr.c", // newlib_nano_formatted_io
    "stdlib/nrand48.c",
    "stdlib/on_exit.c",
    "stdlib/on_exit_args.c",
    "stdlib/putenv.c",
    "stdlib/putenv_r.c",
    "stdlib/pvallocr.c",
    "stdlib/quick_exit.c",
    "stdlib/rand.c",
    "stdlib/rand48.c",
    "stdlib/rand_r.c",
    "stdlib/random.c",
    "stdlib/realloc.c",
    "stdlib/reallocarray.c",
    "stdlib/reallocf.c",
    "stdlib/reallocr.c",
    // "stdlib/rpmatch.c",
    "stdlib/sb_charsets.c",
    "stdlib/seed48.c",
    "stdlib/setenv.c",
    "stdlib/setenv_r.c",
    "stdlib/srand48.c",
    "stdlib/strtod.c",
    "stdlib/strtodg.c",
    "stdlib/strtoimax.c",
    "stdlib/strtol.c",
    "stdlib/strtold.c",
    "stdlib/strtoll.c",
    "stdlib/strtoll_r.c",
    "stdlib/strtorx.c",
    "stdlib/strtoul.c",
    "stdlib/strtoull.c",
    "stdlib/strtoull_r.c",
    "stdlib/strtoumax.c",
    "stdlib/system.c",
    "stdlib/threads.c",
    "stdlib/utoa.c",
    "stdlib/valloc.c",
    "stdlib/vallocr.c",
    "stdlib/wcrtomb.c",
    "stdlib/wcsnrtombs.c",
    "stdlib/wcsrtombs.c",
    // "stdlib/wcstod.c",
    // "stdlib/wcstoimax.c",
    // "stdlib/wcstol.c",
    // "stdlib/wcstold.c", // call to undeclared function 'strtold_l'
    // "stdlib/wcstoll.c",
    "stdlib/wcstoll_r.c",
    "stdlib/wcstombs.c",
    "stdlib/wcstombs_r.c",
    // "stdlib/wcstoul.c",
    // "stdlib/wcstoull.c",
    "stdlib/wcstoull_r.c",
    // "stdlib/wcstoumax.c",
    "stdlib/wctob.c",
    "stdlib/wctomb.c",
    "stdlib/wctomb_r.c",
    "errno/errno.c",
    "stdio/asiprintf.c",
    "stdio/asniprintf.c",
    "stdio/asnprintf.c",
    "stdio/asprintf.c",
    "stdio/clearerr.c",
    "stdio/clearerr_u.c",
    "stdio/diprintf.c",
    "stdio/dprintf.c",
    "stdio/fclose.c",
    "stdio/fcloseall.c",
    "stdio/fdopen.c",
    "stdio/feof.c",
    "stdio/feof_u.c",
    "stdio/ferror.c",
    "stdio/ferror_u.c",
    "stdio/fflush.c",
    "stdio/fflush_u.c",
    "stdio/fgetc.c",
    "stdio/fgetc_u.c",
    "stdio/fgetpos.c",
    "stdio/fgets.c",
    "stdio/fgets_u.c",
    "stdio/fgetwc.c",
    "stdio/fgetwc_u.c",
    "stdio/fgetws.c",
    "stdio/fgetws_u.c",
    "stdio/fileno.c",
    "stdio/fileno_u.c",
    "stdio/findfp.c",
    "stdio/fiprintf.c",
    // "stdio/fiscanf.c",
    "stdio/flags.c",
    "stdio/fmemopen.c",
    "stdio/fopen.c",
    "stdio/fopencookie.c",
    "stdio/fprintf.c",
    "stdio/fpurge.c",
    "stdio/fputc.c",
    "stdio/fputc_u.c",
    "stdio/fputs.c",
    "stdio/fputs_u.c",
    "stdio/fputwc.c",
    "stdio/fputwc_u.c",
    "stdio/fputws.c",
    "stdio/fputws_u.c",
    "stdio/fread.c",
    "stdio/fread_u.c",
    "stdio/freopen.c",
    // "stdio/fscanf.c",
    "stdio/fseek.c",
    "stdio/fseeko.c",
    "stdio/fsetlocking.c",
    "stdio/fsetpos.c",
    "stdio/ftell.c",
    "stdio/ftello.c",
    "stdio/funopen.c",
    "stdio/fvwrite.c",
    "stdio/fwalk.c",
    "stdio/fwide.c",
    "stdio/fwprintf.c",
    "stdio/fwrite.c",
    "stdio/fwrite_u.c",
    "stdio/fwscanf.c",
    "stdio/getc.c",
    "stdio/getc_u.c",
    "stdio/getchar.c",
    "stdio/getchar_u.c",
    "stdio/getdelim.c",
    "stdio/getline.c",
    "stdio/gets.c",
    "stdio/getw.c",
    "stdio/getwc.c",
    "stdio/getwc_u.c",
    "stdio/getwchar.c",
    "stdio/getwchar_u.c",
    "stdio/iprintf.c",
    // "stdio/iscanf.c",
    "stdio/makebuf.c",
    "stdio/mktemp.c",
    // "stdio/nano-svfprintf.c", // newlib-nano-formatted-io
    // "stdio/nano-svfscanf.c",
    // "stdio/nano-vfprintf.c",
    // "stdio/nano-vfprintf_float.c",
    // "stdio/nano-vfprintf_i.c",
    // "stdio/nano-vfscanf.c",
    // "stdio/nano-vfscanf_float.c",
    // "stdio/nano-vfscanf_i.c",
    "stdio/open_memstream.c",
    "stdio/perror.c",
    "stdio/printf.c",
    "stdio/putc.c",
    "stdio/putc_u.c",
    "stdio/putchar.c",
    "stdio/putchar_u.c",
    "stdio/puts.c",
    "stdio/putw.c",
    "stdio/putwc.c",
    "stdio/putwc_u.c",
    "stdio/putwchar.c",
    "stdio/putwchar_u.c",
    "stdio/refill.c",
    "stdio/remove.c",
    "stdio/rename.c",
    "stdio/rewind.c",
    "stdio/rget.c",
    // "stdio/scanf.c",
    "stdio/sccl.c",
    "stdio/setbuf.c",
    "stdio/setbuffer.c",
    "stdio/setlinebuf.c",
    "stdio/setvbuf.c",
    "stdio/sfputs_r.c",
    "stdio/sfputws_r.c",
    "stdio/siprintf.c",
    // "stdio/siscanf.c",
    "stdio/sniprintf.c",
    "stdio/snprintf.c",
    "stdio/sprint_r.c",
    "stdio/sprintf.c",
    // "stdio/sscanf.c",
    "stdio/ssprint_r.c",
    "stdio/ssputs_r.c",
    "stdio/ssputws_r.c",
    "stdio/sswprint_r.c",
    "stdio/stdio.c",
    "stdio/stdio_ext.c",
    "stdio/svfiprintf.c",
    // "stdio/svfiscanf.c",
    "stdio/svfiwprintf.c",
    "stdio/svfiwscanf.c",
    "stdio/svfprintf.c",
    // "stdio/svfscanf.c",
    "stdio/svfwprintf.c",
    "stdio/svfwscanf.c",
    "stdio/swprint_r.c",
    "stdio/swprintf.c",
    "stdio/swscanf.c",
    "stdio/tmpfile.c",
    "stdio/tmpnam.c",
    "stdio/ungetc.c",
    "stdio/ungetwc.c",
    "stdio/vasiprintf.c",
    "stdio/vasniprintf.c",
    "stdio/vasnprintf.c",
    "stdio/vasprintf.c",
    "stdio/vdiprintf.c",
    "stdio/vdprintf.c",
    "stdio/vfiprintf.c",
    // "stdio/vfiscanf.c",
    "stdio/vfiwprintf.c",
    "stdio/vfiwscanf.c",
    "stdio/vfprintf.c",
    // "stdio/vfscanf.c",
    "stdio/vfwprintf.c",
    // "stdio/vfwscanf.c",
    "stdio/viprintf.c",
    // "stdio/viscanf.c",
    "stdio/vprintf.c",
    // "stdio/vscanf.c",
    "stdio/vsiprintf.c",
    // "stdio/vsiscanf.c",
    "stdio/vsniprintf.c",
    "stdio/vsnprintf.c",
    "stdio/vsprintf.c",
    // "stdio/vsscanf.c",
    "stdio/vswprintf.c",
    "stdio/vswscanf.c",
    "stdio/vwprintf.c",
    "stdio/vwscanf.c",
    "stdio/wbuf.c",
    "stdio/wbufw.c",
    "stdio/wprintf.c",
    "stdio/wscanf.c",
    "stdio/wsetup.c",
    "misc/__dprintf.c",
    "misc/ffs.c",
    "misc/fini.c",
    "misc/init.c",
    "misc/lock.c",
    "misc/unctrl.c",
    "signal/psignal.c",
    "signal/raise.c",
    "signal/signal.c",
    "signal/sig2str.c",
    "locale/locale.c",
    "locale/localeconv.c",
    "locale/timelocal.c",
    "ctype/ctype_.c",
    "ctype/isalnum.c",
    "ctype/isalpha.c",
    "ctype/iscntrl.c",
    "ctype/isdigit.c",
    "ctype/islower.c",
    "ctype/isupper.c",
    "ctype/isprint.c",
    "ctype/ispunct.c",
    "ctype/isspace.c",
    "ctype/isxdigit.c",
    "ctype/tolower.c",
    "ctype/toupper.c",
    "ctype/tolower_l.c",
    "ctype/iswspace.c",
    "ctype/iswspace_l.c",
    "ctype/categories.c",
    "search/bsearch.c",
    // "search/ndbm.c",
    "search/qsort.c",
    "syscalls/sysclose.c",
    "syscalls/sysexecve.c",
    "syscalls/sysfcntl.c",
    "syscalls/sysfork.c",
    "syscalls/sysfstat.c",
    // "syscalls/sysgetentropy.c",
    "syscalls/sysgetpid.c",
    "syscalls/sysgettod.c",
    "syscalls/sysisatty.c",
    "syscalls/syskill.c",
    "syscalls/syslink.c",
    "syscalls/syslseek.c",
    "syscalls/sysopen.c",
    "syscalls/sysread.c",
    "syscalls/syssbrk.c",
    "syscalls/sysstat.c",
    "syscalls/systimes.c",
    "syscalls/sysunlink.c",
    "syscalls/syswait.c",
    "syscalls/syswrite.c",
    "time/asctime.c",
    "time/asctime_r.c",
    "time/clock.c",
    // "time/ctime.c",
    // "time/ctime_r.c",
    "time/difftime.c",
    "time/gettzinfo.c",
    "time/gmtime.c",
    "time/gmtime_r.c",
    // "time/lcltime.c",
    // "time/lcltime_r.c",
    // "time/mktime.c",
    "time/month_lengths.c",
    // "time/strftime.c",
    // "time/strptime.c",
    "time/time.c",
    "time/tzcalc_limits.c",
    "time/tzlock.c",
    // "time/tzset.c",
    // "time/tzset_r.c",
    "time/tzvars.c",
    // "time/wcsftime.c",
};
