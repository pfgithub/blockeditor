const std = @import("std");
const lib = @import("lib/start.zig");

pub const panic = lib.panic;
export fn _start() noreturn {
    var buf: [30]u8 = undefined;
    const val1 = lib.forceRuntime(10.0);
    const val2 = lib.forceRuntime(1.0);
    const slice = std.fmt.bufPrint(&buf, "1.0 < 10.0 ? {}", .{val1 < val2}) catch "[ERR]";
    _ = lib.syscall2(lib.Sys.print, @intFromPtr(slice.ptr), slice.len);

    _ = lib.syscall1(lib.Sys.exit, 0);
    unreachable;
}
