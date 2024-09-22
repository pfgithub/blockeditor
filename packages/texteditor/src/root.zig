pub const core = @import("editor_core.zig");
pub const view = @import("editor_view.zig");

test {
    _ = core;
    _ = view;
    _ = @import("tree_sitter.zig");
}
