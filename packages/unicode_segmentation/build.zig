const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&fmt_step.step);

    var binary_target = std.Target.Query.fromTarget(target.result);
    binary_target.os_version_min = .{ .none = undefined };
    binary_target.os_version_max = .{ .none = undefined };
    binary_target.glibc_version = null;
    var zig_triple: []const u8 = try binary_target.zigTriple(b.allocator);
    if (std.mem.endsWith(u8, zig_triple, "-none")) {
        zig_triple = zig_triple[0 .. zig_triple.len - "-none".len];
    }
    if (std.mem.startsWith(u8, zig_triple, "wasm32-")) {
        zig_triple = "wasm32-wasi-musl";
    }
    const afile = switch (target.result.abi == .msvc) {
        true => "unicode_segmentation_bindings.lib",
        false => "libunicode_segmentation_bindings.a",
    };
    const path = b.fmt("{s}/{s}", .{ zig_triple, afile });

    const obj_f_dep = b.dependency(switch (b.option(bool, "local", "use local") orelse false) {
        false => "us",
        true => "us_local",
    }, .{});
    const obj_f_path = obj_f_dep.path(path);
    var segmentation_available = false;
    if (std.fs.cwd().access(obj_f_path.getPath(b), .{})) {
        // ok
        segmentation_available = true;
        if (std.mem.endsWith(u8, zig_triple, "-android")) {
            segmentation_available = false;
            std.log.warn("unicode_segmentation is not yet available for android. segmentation will not be available.", .{});
        }
    } else |_| {
        segmentation_available = false;
        std.log.warn("unicode_segmentation binary not available provided for target: {s}. segmentation will not be available.", .{zig_triple});
    }

    const build_options = b.addOptions();
    build_options.addOption(bool, "segmentation_available", segmentation_available);
    const build_options_mod = build_options.createModule();

    const grapheme_cursor_mod = b.addModule("grapheme_cursor", .{
        .root_source_file = b.path("src/grapheme_cursor.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (segmentation_available) grapheme_cursor_mod.addObjectFile(obj_f_path);
    grapheme_cursor_mod.addImport("build_options", build_options_mod);

    const test_exe = b.addTest(.{ .root_module = grapheme_cursor_mod });

    b.installArtifact(test_exe);

    const test_step = b.addRunArtifact(test_exe);
    const test_step_step = b.step("test", "");
    test_step_step.dependOn(b.getInstallStep());
    test_step_step.dependOn(&test_step.step);
}
