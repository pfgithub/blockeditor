const std = @import("std");

const Beui = @import("Beui.zig");

// if we would like to be able to reposition results, we can do that just fine as long as we
// have consistent ids! to recieve mouse events, an object draws a rectangle to the
// event_draw_list, which is repositioned and next frame it recieves events
// - this introduces one frame of delay from when an item is first rendered and when
//   it can know where the mouse is. and if a node is moving every frame, there's
//   a frame of extra lag for the mouse position it knows. otherwise, it introduces
//   no delay.

// as long as we have consistent ids, we have everything
// repositioning just costs loopoing over the results after we're done with them

const Beui2 = struct {
    arena: std.mem.Allocator,
    draw_list: RepositionableDrawList,
};

pub fn demo1(b2: *Beui2) *RepositionableDrawList {
    b2.pushScope(@src());
    defer b2.popScope();

    const result = RepositionableDrawList.begin();

    result.place(demo0(b2.id(@src()), b2), .{ 25, 25 });

    return result;
}

fn demo0(self_id: ID, b2: *Beui2) *RepositionableDrawList {
    b2.pushScope(self_id, @src());
    defer b2.popScope();

    const result = RepositionableDrawList.begin();

    const capture_id = b2.id(@src());

    const capture_results = b2.mouseCaptureResults(capture_id);
    if (capture_results.mouse_held) {
        result.addRect(.{ 10, 10 }, .{ 50, 50 }, .fromHexRgb(0x00FF00));
    } else {
        result.addRect(.{ 10, 10 }, .{ 50, 50 }, .fromHexRgb(0xFF0000));
    }

    result.addMouseEventCapture(capture_id, .{ 10, 10 }, .{ 50, 50 });

    return result;
}

const ID = struct {
    str: []const u8,
};

const DrawEntry = struct {
    size: @Vector(2, i32),
};
const MouseEventEntry = struct {
    id: ID,
    size: @Vector(2, i32),
};
const RepositionableDrawList = struct {
    pub fn addRect(pos: @Vector(2, i32), size: @Vector(2, i32), color: Beui.Color) void {
        _ = pos;
        _ = size;
        _ = color;
    }
    pub fn addMouseEventCapture(id: ID, pos: @Vector(2, i32), size: @Vector(2, i32)) void {
        _ = id;
        _ = pos;
        _ = size;
    }
};
