//! contains default beui-themed components.

const B2 = @import("beui_experiment.zig");

const WindowChromeCfg = struct {}; // put a close button here for example, then pass it to the child or use an interaction token.
pub fn windowChrome(call_info: B2.StandardCallInfo, cfg: WindowChromeCfg, child: B2.Component(B2.StandardCallInfo, void, B2.StandardChild)) B2.StandardChild {
    _ = cfg;

    const ui = call_info.ui(@src());
    const size: @Vector(2, i32) = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? };

    const draw = ui.id.b2.draw();
    const wm = &ui.id.b2.persistent.wm;

    const activate_window_ikey = ui.id.sub(@src());
    const activate_window_ires = ui.id.b2.mouseCaptureResults(activate_window_ikey);

    if (activate_window_ires.observed_mouse_down) {
        wm.bringToFrontWindow(wm.current_window.?);
    }

    const titlebar_ikey = ui.id.sub(@src());
    const titlebar_ires = ui.id.b2.mouseCaptureResults(titlebar_ikey);

    if (titlebar_ires.mouse_left_held) {
        wm.dragWindow(wm.current_window.?, @intFromFloat(ui.id.b2.persistent.beui1.frame.mouse_offset), .{ .top = true, .left = true, .bottom = true, .right = true });
    }

    const titlebar_height = 20;
    const border_width = 1;

    // detect any mouse down event over the window that hasn't been captured by someone else
    draw.addMouseEventCapture(
        activate_window_ikey,
        .{ 0, 0 },
        .{ size[0], size[1] },
        .{ .observe_mouse_down = true },
    );

    const child_res = child.call(ui.subWithOffset(@src(), .{ border_width * 2, titlebar_height + border_width }), {});

    // TODO: clip result
    draw.place(child_res.rdl, .{ border_width, titlebar_height });

    draw.addRect(.{
        .pos = @floatFromInt(@Vector(2, i32){ 0, 0 }),
        .size = @floatFromInt(@Vector(2, i32){ size[0], titlebar_height }),
        .tint = .fromHexRgb(0xFF0000),
    });
    draw.addMouseEventCapture(
        titlebar_ikey,
        .{ 0, 0 },
        .{ size[0], titlebar_height },
        .{ .capture_click = true },
    );
    draw.addRect(.{
        .pos = @floatFromInt(@Vector(2, i32){ 0, titlebar_height }),
        .size = @floatFromInt(@Vector(2, i32){ border_width, size[1] - titlebar_height }),
        .tint = .fromHexRgb(0xFF0000),
    });
    draw.addRect(.{
        .pos = @floatFromInt(@Vector(2, i32){ size[0] - border_width, titlebar_height }),
        .size = @floatFromInt(@Vector(2, i32){ border_width, size[1] - titlebar_height }),
        .tint = .fromHexRgb(0xFF0000),
    });
    draw.addRect(.{
        .pos = @floatFromInt(@Vector(2, i32){ border_width, size[1] - border_width }),
        .size = @floatFromInt(@Vector(2, i32){ size[0] - border_width * 2, border_width }),
        .tint = .fromHexRgb(0xFF0000),
    });

    // catch any straggling clicks or scrolls over the window so they don't fall to a window behind us
    draw.addMouseEventCapture(
        ui.id.sub(@src()),
        .{ 0, 0 },
        .{ size[0], size[1] },
        .{ .capture_click = true, .capture_scroll = .{ .x = true, .y = true } },
    );
    // draw a final background for the window
    draw.addRect(.{
        .pos = @floatFromInt(@Vector(2, i32){ 0, 0 }),
        .size = @floatFromInt(@Vector(2, i32){ size[0], size[1] }),
        .tint = .fromHexRgb(0xFFFFFF),
    });

    // renders:
    // - title bar
    // - 1px borders
    // - click handler for dragging title bar
    // - click handler for resizing window (goes outside of the borders). these should set custom cursors.

    return .{ .rdl = draw, .size = size };
}
