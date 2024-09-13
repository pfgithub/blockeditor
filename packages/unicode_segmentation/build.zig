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
    if(std.mem.endsWith(u8, zig_triple, "-none")) {
        zig_triple = zig_triple[0..zig_triple.len - "-none".len];
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
    if (std.fs.cwd().access(obj_f_path.getPath(b), .{})) {
        // ok
    } else |_| {
        std.log.err("unicode_segmentation binary not available provided for target: {s}", .{zig_triple});
        return error.MakeFailed;
    }

    const test_exe = b.addTest(.{
        .root_source_file = b.path("src/grapheme_cursor.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_exe.addObjectFile(obj_f_path);

    const grapheme_cursor_mod = b.addModule("grapheme_cursor", .{
        .root_source_file = b.path("src/grapheme_cursor.zig"),
        .target = target,
        .optimize = optimize,
    });
    grapheme_cursor_mod.addObjectFile(obj_f_path);

    b.installArtifact(test_exe);

    const test_step = b.addRunArtifact(test_exe);
    const test_step_step = b.step("test", "");
    test_step_step.dependOn(b.getInstallStep());
    test_step_step.dependOn(&test_step.step);
}
