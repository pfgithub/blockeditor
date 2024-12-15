const std = @import("std");
const lib = @import("lib");

const game = @import("sponge.zig");
export fn _start() noreturn {
    game.initialize() catch |e| {
        std.debug.panic("caught error in init(): {s}", .{@errorName(e)});
    };
    while (true) {
        game.frame() catch |e| {
            std.debug.panic("caught error in render(): {s}", .{@errorName(e)});
        };
        _ = lib.syscalls.syscall0(.wait_for_next_frame);
    }
    lib.exit(0);
    @trap();
}

pub const std_options = std.Options{
    .logFn = lib.logFn,
    .log_level = .info,
};
pub const panic = lib.panic;
