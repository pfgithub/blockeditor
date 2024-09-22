pub const Core = @import("Core.zig");
pub const View = @import("View.zig");

test {
    _ = Core;
    _ = View;
    _ = @import("tree_sitter.zig");
}
