const std = @import("std");
const lib = @import("lib");

const game = @import("game");
var initialized: bool = false;
export fn minigamer_frame() void {
    if (!initialized) {
        game.initialize() catch |e| {
            std.debug.panic("caught error in init(): {s}", .{@errorName(e)});
        };
        initialized = true;
    }
    game.frame() catch |e| {
        std.debug.panic("caught error in render(): {s}", .{@errorName(e)});
    };
}
