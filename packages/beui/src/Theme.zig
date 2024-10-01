//! contains default beui-themed components.

const B2 = @import("beui_experiment.zig");

const WindowChromeCfg = struct {}; // put a close button here for example, then pass it to the child or use an interaction token.
pub fn windowChrome(call_info: B2.StandardCallInfo, cfg: WindowChromeCfg, child: B2.Component(B2.StandardCallInfo, void, B2.StandardChild)) B2.StandardChild {
    _ = cfg;

    const ui = call_info.ui(@src());
    const size: @Vector(2, i32) = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? };

    const draw = ui.id.b2.draw();

    const titlebar_height = 20;
    const border_width = 1;

    const child_res = child.call(ui.subWithOffset(@src(), .{ border_width * 2, titlebar_height + border_width }), {});

    draw.place(child_res.rdl, .{ border_width, titlebar_height });

    draw.addRect(.{
        .pos = @floatFromInt(@Vector(2, i32){ 0, 0 }),
        .size = @floatFromInt(@Vector(2, i32){ size[0], titlebar_height }),
        .tint = .fromHexRgb(0xFF0000),
    });
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

    // renders:
    // - title bar
    // - 1px borders
    // - click handler for dragging title bar
    // - click handler for resizing window (goes outside of the borders). these should set custom cursors.

    return .{ .rdl = draw, .size = size };
}
