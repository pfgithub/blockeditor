//! contains default beui-themed components.

const Beui = @import("Beui.zig");
const B2 = @import("beui_experiment.zig");

const WindowChromeCfg = struct {}; // put a close button here for example, then pass it to the child or use an interaction token.
pub fn windowChrome(call_info: B2.StandardCallInfo, cfg: WindowChromeCfg, ikeys: B2.WindowIkeys, child: B2.Component(B2.StandardCallInfo, void, B2.StandardChild)) B2.StandardChild {
    _ = cfg;

    var ui = call_info.ui(@src());

    const draw = ui.id.b2.draw();
    const wm = &ui.id.b2.persistent.wm;
    const size: @Vector(2, f32) = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? };

    const in_front = wm.isInFront(wm.current_window.?);
    const border_color: Beui.Color = switch (in_front) {
        true => .fromHexRgb(0xFF0000),
        false => .fromHexRgb(0x770000),
    };

    const titlebar_height = 20;
    const border_width = 1;
    const resize_width = 10;

    // detect any mouse down event over the window that hasn't been captured by someone else
    draw.addMouseEventCapture(
        ikeys.activate_window_ikey,
        .{ 0, 0 },
        .{ size[0], size[1] },
        .{ .observe_mouse_down = true },
    );

    const child_res = child.call(ui.subWithOffset(@src(), .{ border_width * 2, titlebar_height + border_width }), {});

    // TODO: clip result
    draw.place(child_res.rdl, .{ border_width, titlebar_height });

    draw.addRect(.{
        .pos = .{ 0, 0 },
        .size = .{ size[0], titlebar_height },
        .tint = border_color,
    });
    draw.addMouseEventCapture(
        ikeys.drag_all_ikey,
        .{ 0, 0 },
        .{ size[0], titlebar_height },
        .{ .capture_click = .arrow },
    );
    draw.addRect(.{
        .pos = .{ 0, titlebar_height },
        .size = .{ border_width, size[1] - titlebar_height },
        .tint = border_color,
    });
    draw.addRect(.{
        .pos = .{ size[0] - border_width, titlebar_height },
        .size = .{ border_width, size[1] - titlebar_height },
        .tint = border_color,
    });
    draw.addRect(.{
        .pos = .{ border_width, size[1] - border_width },
        .size = .{ size[0] - border_width * 2, border_width },
        .tint = border_color,
    });

    // resize handlers
    {
        draw.addMouseEventCapture(ikeys.drag_top_ikey, .{ 0, -resize_width }, .{ size[0], resize_width }, .{ .capture_click = .resize_ns });
        draw.addMouseEventCapture(ikeys.drag_top_right_ikey, .{ size[0], -resize_width }, .{ resize_width, resize_width }, .{ .capture_click = .resize_ne_sw });
        draw.addMouseEventCapture(ikeys.drag_right_ikey, .{ size[0], 0 }, .{ resize_width, size[1] }, .{ .capture_click = .resize_ew });
        draw.addMouseEventCapture(ikeys.drag_bottom_right_ikey, .{ size[0], size[1] }, .{ resize_width, resize_width }, .{ .capture_click = .resize_nw_se });
        draw.addMouseEventCapture(ikeys.drag_bottom_ikey, .{ 0, size[1] }, .{ size[0], resize_width }, .{ .capture_click = .resize_ns });
        draw.addMouseEventCapture(ikeys.drag_bottom_left_ikey, .{ -resize_width, size[1] }, .{ resize_width, resize_width }, .{ .capture_click = .resize_ne_sw });
        draw.addMouseEventCapture(ikeys.drag_left_ikey, .{ -resize_width, 0 }, .{ resize_width, size[1] }, .{ .capture_click = .resize_ew });
        draw.addMouseEventCapture(ikeys.drag_top_left_ikey, .{ -resize_width, -resize_width }, .{ resize_width, resize_width }, .{ .capture_click = .resize_nw_se });
    }

    // catch any straggling clicks or scrolls over the window so they don't fall to a window behind us
    draw.addMouseEventCapture(
        ui.id.sub(@src()),
        .{ 0, 0 },
        .{ size[0], size[1] },
        .{ .capture_click = .arrow, .capture_scroll = .{ .x = true, .y = true } },
    );
    // draw a final background for the window
    draw.addRect(.{
        .pos = .{ 0, 0 },
        .size = .{ size[0], size[1] },
        .tint = .fromHexRgb(0xFFFFFF),
    });

    // renders:
    // - title bar
    // - 1px borders
    // - click handler for dragging title bar
    // - click handler for resizing window (goes outside of the borders). these should set custom cursors.

    return .{ .rdl = draw, .size = size };
}
