const std = @import("std");
const lib = @import("lib/start.zig");

// TODO: force debug build
// in releasesafe it prints 25

pub const panic = lib.panic;
export fn _start() noreturn {
    var buf: [30]u8 = undefined;
    var val: f32 = 25.0;
    _ = &val;
    var slice = std.fmt.bufPrint(&buf, "Print 25.0 ? {d}", .{val}) catch "[ERR]";
    _ = lib.syscall2(lib.Sys.print, @intFromPtr(slice.ptr), slice.len);

    var val2: f32 = 10.0;
    val = 1.0;
    _ = &val2;
    slice = std.fmt.bufPrint(&buf, "1.0 < 10.0 ? {}", .{val < val2}) catch "[ERR]";
    _ = lib.syscall2(lib.Sys.print, @intFromPtr(slice.ptr), slice.len);

    _ = lib.syscall1(lib.Sys.exit, 0);
    unreachable;
}
