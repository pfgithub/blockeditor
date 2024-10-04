//! contains default beui-themed components.

const Beui = @import("Beui.zig");
const B2 = @import("beui_experiment.zig");

pub const window_padding: f32 = 12;

// so here's the plan:
// - can't predraw the windows at the start of the frame because that introduces frame delay for opening or closing a window
// so we will:
// 1. at the start of the frame:
//   a. handle interactions from the previous frame
//   b. update data
//       i. close any closed windows
//       ii. unrequest all windows
//       iii. refresh ids on all windows
//   c. loop over every window node and draw it using Theme.drawFloatingContainer
// 2. during the frame (fn addWindow)
//   a. get the window from the map
//     - if it is not found, add a new floating window and draw it using Theme.drawFloatingContainer
//       - oops! this will add to the back of the list! and then it will show up in front next frame. maybe each floating
//         container gets an rdl and then we order them at the end of the frame.
//   b. if it has no slot, skip it. ie its parent is collapsed
//   c. render it and put the resulting rdl in the map
// 3. at the end of the frame:
//   a. render the final windows
// frame perfect:
// - opening windows. they show up the same frame they're opened.
// - moving and resizing windows. the move/resize is applied before the window contents render
// not frame perfect:
// - closing windows. this takes two frames - one frame to find out it's gone, and the next to shift the rest of the
//   windows to accomodate.
// not accounted for:
// - how to save/load a layout? I guess we can do it in a way that will require 1 frame of delay on application launch

fn drawWindowNode(wm: *B2.WindowManager, win: *const B2.WindowTreeNode, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32), cfg: struct { parent_is_tabs: bool }) void {
    const rdl = wm.this_frame_rdl.?;
    switch (win.*) {
        .final => |id| {
            if (!cfg.parent_is_tabs) {
                // TODO draw titlebar
            }

            const slot = rdl.reserve();
            const win_data = wm.windows.getPtr(id).?;
            win_data.* = .{ .slot = slot, .position = offset_pos, .size = offset_size };
        },
        .tabs => |t| {
            _ = t;
            @panic("TODO tabs");
        },
        .list => |l| {
            _ = l;
            @panic("TODO list");
        },
    }
}

pub fn drawFloatingContainer(wm: *B2.WindowManager, win: *const B2.FloatingWindow) void {
    const id = wm.idForFloatingContainer(@src(), win.id);
    const rdl = wm.this_frame_rdl.?;

    const border_width: f32 = 6.0;
    const resize_width = border_width * 2;

    const win_pos = win.position;
    const win_size = win.size;
    const whole_pos: @Vector(2, f32) = win_pos + @Vector(2, f32){ -border_width, -border_width };
    const whole_size: @Vector(2, f32) = win_size + @Vector(2, f32){ border_width * 2, border_width * 2 };
    const whole_pos_incl_resize: @Vector(2, f32) = win_pos + @Vector(2, f32){ -resize_width, -resize_width };
    const whole_size_incl_resize: @Vector(2, f32) = win_size + @Vector(2, f32){ resize_width * 2, resize_width * 2 };

    // add the raise capture
    rdl.addMouseEventCapture(wm.addIkey(id.sub(@src()), .{ .raise = .{ .window = win.id } }), whole_pos_incl_resize, whole_size_incl_resize, .{ .observe_mouse_down = true });

    // add the resize captures
    rdl.addMouseEventCapture(wm.addIkey(id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .top } }), .{ win_pos[0], win_pos[1] + -resize_width }, .{ win_size[0], resize_width }, .{ .capture_click = .resize_ns });
    rdl.addMouseEventCapture(wm.addIkey(id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .top_right } }), .{ win_pos[0] + win_size[0], win_pos[1] - resize_width }, .{ resize_width, resize_width }, .{ .capture_click = .resize_ne_sw });
    rdl.addMouseEventCapture(wm.addIkey(id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .right } }), .{ win_pos[0] + win_size[0], win_pos[1] }, .{ resize_width, win_size[1] }, .{ .capture_click = .resize_ew });
    rdl.addMouseEventCapture(wm.addIkey(id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .bottom_right } }), .{ win_pos[0] + win_size[0], win_pos[1] + win_size[1] }, .{ resize_width, resize_width }, .{ .capture_click = .resize_nw_se });
    rdl.addMouseEventCapture(wm.addIkey(id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .bottom } }), .{ win_pos[0], win_pos[1] + win_size[1] }, .{ win_size[0], resize_width }, .{ .capture_click = .resize_ns });
    rdl.addMouseEventCapture(wm.addIkey(id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .bottom_left } }), .{ win_pos[0] - resize_width, win_pos[1] + win_size[1] }, .{ resize_width, resize_width }, .{ .capture_click = .resize_ne_sw });
    rdl.addMouseEventCapture(wm.addIkey(id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .left } }), .{ win_pos[0] - resize_width, win_pos[1] }, .{ resize_width, win_size[1] }, .{ .capture_click = .resize_ew });
    rdl.addMouseEventCapture(wm.addIkey(id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .top_left } }), .{ win_pos[0] - resize_width, win_pos[1] - resize_width }, .{ resize_width, resize_width }, .{ .capture_click = .resize_nw_se });

    // render the children
    drawWindowNode(wm, &win.contents, win_pos, win_size, .{ .parent_is_tabs = false });

    // add the black rectangle
    rdl.addRect(.{
        .pos = whole_pos,
        .size = whole_size,
        .tint = .fromHexRgb(0x000000),
        .rounding = .{ .corners = .all, .radius = 12.0 },
    });

    // add the fallthrough capture so events don't fall through the black rectangle
    rdl.addMouseEventCapture(wm.addIkey(id.sub(@src()), .ignore), whole_pos, whole_size, .{ .capture_click = .arrow, .capture_scroll = .{ .x = true, .y = true } });
}
