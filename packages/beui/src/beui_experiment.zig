const Beui = @import("Beui.zig");

const BeuiLayout = struct {
    beui: *Beui,
    insert_cursor: @Vector(2, i64),
    size: @Vector(2, i64),

    flow_direction: enum {
        x,
        y,

        fn v(a: @This()) u1 {
            return switch (a) {
                .x => 0,
                .y => 1,
            };
        }

        fn vec2f(a: @This(), b: f32, c: f32) @Vector(2, f32) {
            return switch (a) {
                .y => .{ b, c },
                .x => .{ c, b },
            };
        }
    },
};

// experiment:
// - fn text() : renders text given (text, cursor_positions, theme_ranges), posts its size and returns the left hovered byte

/// draws a full width rectangle
pub fn rect(layout: *BeuiLayout, flow_size: i64, color: Beui.Color) void {
    layout.beui.draw().addRect(@floatFromInt(layout.insert_cursor), layout.flow_direction.vec2f(@floatFromInt(layout.size[layout.flow_direction.v()]), @floatFromInt(flow_size)), .{ .tint = color });

    layout.insert_cursor[layout.flow_direction.v()] += flow_size;
}

pub fn runExperiment(beui: *Beui, w: u32, h: u32) void {
    var layout_value: BeuiLayout = .{
        .beui = beui,
        .insert_cursor = .{ 0, 0 },
        .size = .{ @intCast(w), @intCast(h) },
        .flow_direction = .y,
    };
    const layout = &layout_value;

    rect(layout, 25, .fromHexRgb(0xFF0000));
    rect(layout, 50, .fromHexRgb(0x00FF00));
    rect(layout, 25, .fromHexRgb(0x0000FF));
}
