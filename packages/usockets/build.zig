const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    b.getInstallStep().dependOn(&fmt.step);

    const usockets = b.dependency("usockets", .{});
    const lib_usockets = b.addStaticLibrary(.{
        .name = "usockets",
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib_usockets);

    lib_usockets.addIncludePath(usockets.path("src"));
    lib_usockets.addCSourceFiles(.{
        .root = usockets.path("."),
        .flags = &[_][]const u8{
            // ssl
            "-DLIBUS_NO_SSL",
            // "-DWITH_OPENSSL",
            // "-DWITH_WOLFSSL",
            // "-DWITH_BORINGSSL",
            // event loop
            // "-DWITH_IO_URING",
            // "-DWITH_LIBUV",
            // "-DWITH_ASIO",
            // "-DWITH_GCD",
            // sanitizer
            // "-DWITH_ASAN",
            // quic
            // "-DWITH_QUIC",

            // TODO:
            // - support ssl & quic
        },
        .files = &.{
            "src/bsd.c",
            "src/context.c",
            "src/crypto/openssl.c",
            "src/eventing/epoll_kqueue.c",
            "src/eventing/gcd.c",
            "src/eventing/libuv.c",
            "src/io_uring/io_context.c",
            "src/io_uring/io_loop.c",
            "src/io_uring/io_socket.c",
            "src/loop.c",
            "src/quic.c",
            "src/socket.c",
            "src/udp.c",
        },
    });
    lib_usockets.linkLibC();
    lib_usockets.installHeadersDirectory(usockets.path("src"), "", .{});

    const exe = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(lib_usockets);
    b.installArtifact(exe);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.linkLibrary(lib_usockets);
    b.installArtifact(lib_unit_tests);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);

    const run_step = b.step("run", "Run");
    run_step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_exe.step);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_lib_unit_tests.step);
}
