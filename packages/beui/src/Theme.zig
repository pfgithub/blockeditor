//! contains default beui-themed components.

const Beui = @import("Beui.zig");
const B2 = @import("beui_experiment.zig");

const WindowChromeCfg = struct {}; // put a close button here for example, then pass it to the child or use an interaction token.
pub fn windowChrome(call_info: B2.StandardCallInfo, cfg: WindowChromeCfg, child: B2.Component(B2.StandardCallInfo, void, B2.StandardChild)) B2.StandardChild {
    _ = cfg;

    const ui = call_info.ui(@src());

    const draw = ui.id.b2.draw();
    const wm = &ui.id.b2.persistent.wm;

    const activate_window_ikey = ui.id.sub(@src());
    const activate_window_ires = ui.id.b2.mouseCaptureResults(activate_window_ikey);

    const in_front = wm.isInFront(wm.current_window.?);
    const border_color: Beui.Color = switch (in_front) {
        true => .fromHexRgb(0xFF0000),
        false => .fromHexRgb(0x770000),
    };

    if (activate_window_ires.observed_mouse_down) {
        wm.bringToFrontWindow(wm.current_window.?);
    }

    const drag_all_ikey = ui.id.sub(@src());
    const drag_top_ikey = ui.id.sub(@src());
    const drag_top_right_ikey = ui.id.sub(@src());
    const drag_right_ikey = ui.id.sub(@src());
    const drag_bottom_right_ikey = ui.id.sub(@src());
    const drag_bottom_ikey = ui.id.sub(@src());
    const drag_bottom_left_ikey = ui.id.sub(@src());
    const drag_left_ikey = ui.id.sub(@src());
    const drag_top_left_ikey = ui.id.sub(@src());
    if (ui.id.b2.mouseCaptureResults(drag_all_ikey).mouse_left_held) {
        wm.dragWindow(wm.current_window.?, @intFromFloat(ui.id.b2.persistent.beui1.frame.mouse_offset), .{ .top = true, .left = true, .bottom = true, .right = true });
    }
    if (ui.id.b2.mouseCaptureResults(drag_top_ikey).mouse_left_held) {
        wm.dragWindow(wm.current_window.?, @intFromFloat(ui.id.b2.persistent.beui1.frame.mouse_offset), .{ .top = true, .left = false, .bottom = false, .right = false });
    }
    if (ui.id.b2.mouseCaptureResults(drag_top_right_ikey).mouse_left_held) {
        wm.dragWindow(wm.current_window.?, @intFromFloat(ui.id.b2.persistent.beui1.frame.mouse_offset), .{ .top = true, .left = false, .bottom = false, .right = true });
    }
    if (ui.id.b2.mouseCaptureResults(drag_right_ikey).mouse_left_held) {
        wm.dragWindow(wm.current_window.?, @intFromFloat(ui.id.b2.persistent.beui1.frame.mouse_offset), .{ .top = false, .left = false, .bottom = false, .right = true });
    }
    if (ui.id.b2.mouseCaptureResults(drag_bottom_right_ikey).mouse_left_held) {
        wm.dragWindow(wm.current_window.?, @intFromFloat(ui.id.b2.persistent.beui1.frame.mouse_offset), .{ .top = false, .left = false, .bottom = true, .right = true });
    }
    if (ui.id.b2.mouseCaptureResults(drag_bottom_ikey).mouse_left_held) {
        wm.dragWindow(wm.current_window.?, @intFromFloat(ui.id.b2.persistent.beui1.frame.mouse_offset), .{ .top = false, .left = false, .bottom = true, .right = false });
    }
    if (ui.id.b2.mouseCaptureResults(drag_bottom_left_ikey).mouse_left_held) {
        wm.dragWindow(wm.current_window.?, @intFromFloat(ui.id.b2.persistent.beui1.frame.mouse_offset), .{ .top = false, .left = true, .bottom = true, .right = false });
    }
    if (ui.id.b2.mouseCaptureResults(drag_left_ikey).mouse_left_held) {
        wm.dragWindow(wm.current_window.?, @intFromFloat(ui.id.b2.persistent.beui1.frame.mouse_offset), .{ .top = false, .left = true, .bottom = false, .right = false });
    }
    if (ui.id.b2.mouseCaptureResults(drag_top_left_ikey).mouse_left_held) {
        wm.dragWindow(wm.current_window.?, @intFromFloat(ui.id.b2.persistent.beui1.frame.mouse_offset), .{ .top = true, .left = true, .bottom = false, .right = false });
    }

    const size = wm.windows.get(wm.current_window.?).?.size;

    const titlebar_height = 20;
    const border_width = 1;
    const resize_width = 10;

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
        .tint = border_color,
    });
    draw.addMouseEventCapture(
        drag_all_ikey,
        .{ 0, 0 },
        .{ size[0], titlebar_height },
        .{ .capture_click = .arrow },
    );
    draw.addRect(.{
        .pos = @floatFromInt(@Vector(2, i32){ 0, titlebar_height }),
        .size = @floatFromInt(@Vector(2, i32){ border_width, size[1] - titlebar_height }),
        .tint = border_color,
    });
    draw.addRect(.{
        .pos = @floatFromInt(@Vector(2, i32){ size[0] - border_width, titlebar_height }),
        .size = @floatFromInt(@Vector(2, i32){ border_width, size[1] - titlebar_height }),
        .tint = border_color,
    });
    draw.addRect(.{
        .pos = @floatFromInt(@Vector(2, i32){ border_width, size[1] - border_width }),
        .size = @floatFromInt(@Vector(2, i32){ size[0] - border_width * 2, border_width }),
        .tint = border_color,
    });

    // resize handlers
    {
        draw.addMouseEventCapture(drag_top_ikey, .{ 0, -resize_width }, .{ size[0], resize_width }, .{ .capture_click = .resize_ns });
        draw.addMouseEventCapture(drag_top_right_ikey, .{ size[0], -resize_width }, .{ resize_width, resize_width }, .{ .capture_click = .resize_ne_sw });
        draw.addMouseEventCapture(drag_right_ikey, .{ size[0], 0 }, .{ resize_width, size[1] }, .{ .capture_click = .resize_ew });
        draw.addMouseEventCapture(drag_bottom_right_ikey, .{ size[0], size[1] }, .{ resize_width, resize_width }, .{ .capture_click = .resize_nw_se });
        draw.addMouseEventCapture(drag_bottom_ikey, .{ 0, size[1] }, .{ size[0], resize_width }, .{ .capture_click = .resize_ns });
        draw.addMouseEventCapture(drag_bottom_left_ikey, .{ -resize_width, size[1] }, .{ resize_width, resize_width }, .{ .capture_click = .resize_ne_sw });
        draw.addMouseEventCapture(drag_left_ikey, .{ -resize_width, 0 }, .{ resize_width, size[1] }, .{ .capture_click = .resize_ew });
        draw.addMouseEventCapture(drag_top_left_ikey, .{ -resize_width, -resize_width }, .{ resize_width, resize_width }, .{ .capture_click = .resize_nw_se });
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
