pub const core = @import("editor_core.zig");

test {
    _ = core;
    _ = @import("tree_sitter.zig");
}
