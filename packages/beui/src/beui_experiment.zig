const Beui = @import("beui.zig").Beui;

const BeuiLayout = struct {
    beui: *Beui,
    insert_cursor: @Vector(2, i64),

    flow_direction: enum { y, x },
};

// experiment:
// - fn text() : renders text given (text, cursor_positions, theme_ranges), posts its size and returns the left hovered byte

/// draws a full width rectangle
pub fn rect(bl: *BeuiLayout, flow_size: i64, color: Beui.Color) void {
    _ = bl;
    _ = flow_size;
    _ = color;
}
