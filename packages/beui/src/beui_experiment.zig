const Beui = @import("Beui.zig");

const BeuiLayout = struct {
    beui: *Beui,
    insert_cursor: @Vector(2, i64),

    flow_direction: enum { y, x },
};

// experiment:
// - fn text() : renders text given (text, cursor_positions, theme_ranges), posts its size and returns the left hovered byte

/// draws a full width rectangle
pub fn rect(layout: *BeuiLayout, flow_size: i64, color: Beui.Color) void {
    _ = layout;
    _ = flow_size;
    _ = color;
}

pub fn runExperiment(beui: *Beui) void {
    var layout_value: BeuiLayout = .{
        .beui = beui,
        .insert_cursor = .{ 0, 0 },
        .flow_direction = .y,
    };
    const layout = &layout_value;

    rect(layout);
}
