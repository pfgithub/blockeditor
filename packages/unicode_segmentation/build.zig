const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_step = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    });
    b.getInstallStep().dependOn(&fmt_step.step);

    const path = switch (target.result.os.tag) {
        .macos => switch (target.result.cpu.arch) {
            .aarch64 => "aarch64-macos/libunicode_segmentation_bindings.a",
            .x86_64 => "x86_64-macos/libunicode_segmentation_bindings.a",
            else => @panic(b.fmt("TODO target: {s}", .{try target.query.zigTriple(b.allocator)})),
        },
        .windows => switch (target.result.cpu.arch) {
            .aarch64 => "aarch64-windows-msvc/unicode_segmentation_bindings.lib",
            .x86_64 => switch (target.result.abi) {
                .gnu => "aarch64-windows-gnu/libunicode_segmentation_bindings.a",
                .msvc => "x86_64-windows-msvc/unicode_segmentation_bindings.lib",
                else => @panic(b.fmt("TODO target: {s}", .{try target.query.zigTriple(b.allocator)})),
            },
            else => @panic(b.fmt("TODO target: {s}", .{try target.query.zigTriple(b.allocator)})),
        },
        .linux => switch (target.result.cpu.arch) {
            .aarch64 => switch (target.result.abi) {
                .gnu => "aarch64-linux-gnu/libunicode_segmentation_bindings.a",
                .musl => "aarch64-linux-musl/libunicode_segmentation_bindings.a",
                else => @panic(b.fmt("TODO target: {s}", .{try target.query.zigTriple(b.allocator)})),
            },
            .x86_64 => switch (target.result.abi) {
                .gnu => "x86_64-linux-gnu/libunicode_segmentation_bindings.a",
                .musl => "x86_64-linux-musl/libunicode_segmentation_bindings.a",
                else => @panic(b.fmt("TODO target: {s}", .{try target.query.zigTriple(b.allocator)})),
            },
            else => @panic(b.fmt("TODO target: {s}", .{try target.query.zigTriple(b.allocator)})),
        },
        else => @panic(b.fmt("TODO target: {s}", .{try target.query.zigTriple(b.allocator)})),
    };

    const obj_f_dep = b.dependency(switch (b.option(bool, "local", "use local") orelse false) {
        false => "us",
        true => "us_local",
    }, .{});
    const obj_f_path = obj_f_dep.path(path);

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