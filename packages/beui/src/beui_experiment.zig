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
        .size = .{ w, h },
        .flow_direction = .y,
    };
    const layout = &layout_value;

    rect(layout, 25, .fromHexRgb(0xFF0000));
    rect(layout, 50, .fromHexRgb(0x00FF00));
    rect(layout, 25, .fromHexRgb(0x0000FF));
}

pub const Scroller = struct {
    // without being able to shift items after they are rendered, how do we measure the size of a child?
    // either we have to be able to shift items, or we have to take two frames. frame one render the
    // child but disable interaction on it and don't let it actually draw anything. frame two now we know
    // its height, draw it like normal.
    pub const State = struct {
        offset: f32,
        target_id: ID,
        target_data: ?u128,
    };
};
const ID = enum(u128) {};

fn targetScrollApi(layout: *BeuiLayout, scroll_state: *Scroller.State) void {
    const scroller = layout.beginScroll(scroll_state);
    defer scroller.end();

    if (scroller.child(@src())) rect(layout, 25, .fromHexRgb(0xFF0000));
    if (scroller.child(@src())) rect(layout, 50, .fromHexRgb(0x00FF00));
    if (scroller.child(@src())) rect(layout, 25, .fromHexRgb(0x0000FF));

    // SizeOf(SampleVirtual) must be less than say 16 bytes and alignment must be 16 or less
    while (scroller.virtual(@src(), SampleVirtual, {})) |value| {
        const height: i64 = switch (value.v % 4) {
            0 => 100,
            1 => 80,
            2 => 60,
            3 => 30,
            else => unreachable,
        };
        switch (value.v % 3) {
            0 => rect(layout, height, .fromHexRgb(0xFFFF00)),
            1 => rect(layout, height, .fromHexRgb(0x00FFFF)),
            2 => rect(layout, height, .fromHexRgb(0xFF00FF)),
            else => unreachable,
        }
    }
}

const SampleVirtual = struct {
    v: u32,

    pub fn first(_: void) SampleVirtual {
        return .{ .v = 0 };
    }
    pub fn last(_: void) SampleVirtual {
        return .{ .v = 100 };
    }
    pub fn prev(_: void, v: SampleVirtual) ?SampleVirtual {
        if (v.v > 0) return .{ .v = v.v - 1 };
        return null;
    }
    pub fn next(_: void, v: SampleVirtual) ?SampleVirtual {
        if (v.v < 100) return .{ .v = v.v + 1 };
        return null;
    }
};

// if we choose not to allow moving children after rendering, then:
// - we need in beui a toggle to say "disable rendering and events" so we can measure something
//   without actually drawing it to the screen
// - lots of stuff will have to be frame-delayed for no good reason. center aligning something
//   requires: the first frame, don't render anything and just measure the thing to align. the
//   second frame, render it and track its width. the third frame, render it and update based
//   on the second frame. and any size changes will cause broken weird stuff.

// if we choose to allow moving children after rendering, then:
// - how? nested render lists that get unnested in a step after?
// - have to deal with events. possibly even with event handlers

// moving after rendering is easy:
// - in render lists, store an extra array that has offsets
// - before sending buffers to the gpu, loop over that array and apply the offsets
// handling events with items that have been moved after rendering is not easy.
// - items know where they were last frame, so they can pretend they're still there?
