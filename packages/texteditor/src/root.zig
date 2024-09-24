pub const Core = @import("Core.zig");

test {
    _ = Core;
    _ = @import("Highlighter.zig");
    _ = @import("highlighters/zig.zig");
}
