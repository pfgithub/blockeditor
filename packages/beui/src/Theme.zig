//! contains default beui-themed components.

const Beui = @import("Beui.zig");
const B2 = @import("beui_experiment.zig");
const WM = @import("wm.zig");
const std = @import("std");

pub const window_padding: f32 = border_width * 2;
const border_width: f32 = 6.0;

pub const colors = struct {
    pub const window_bg: Beui.Color = .fromHexRgb(0x2e2e2e);
    pub const window_active_tab: Beui.Color = .fromHexRgb(0x4D4D4D);
};

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

const titlebar_height: f32 = border_width * 4;

fn drawWindowFinal(window_content_id: B2.ID, wm: *B2.WindowManager, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32)) void {
    const rdl = wm.this_frame_rdl.?;
    const slot = rdl.reserve();
    const win_data = wm.windows.getPtr(window_content_id).?;
    win_data.* = .{ .slot = slot, .position = offset_pos, .size = offset_size };
}
fn drawWindowTabbed_collapseButtonClicked(win: *B2.WindowTreeNode, _: *B2.Beui2, _: void) void {
    win.collapsed = !win.collapsed;
}
fn drawWindowTabbed_collapseButtonChild(win: *B2.WindowTreeNode, call_info: B2.StandardCallInfo, btn_state: B2.ButtonState) B2.StandardChild {
    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    // this is missing antialiasing, we should use an icon instead
    if (win.collapsed) {
        rdl.addVertices(null, &.{
            .{ .pos = .{ 10, 7 }, .uv = .{ -1, -1 }, .tint = .{ 255, 255, 255, 255 }, .circle = .{ 0.0, 0.0 } },
            .{ .pos = .{ 15, 13 }, .uv = .{ -1, -1 }, .tint = .{ 255, 255, 255, 255 }, .circle = .{ 0.0, 0.0 } },
            .{ .pos = .{ 10, 18 }, .uv = .{ -1, -1 }, .tint = .{ 255, 255, 255, 255 }, .circle = .{ 0.0, 0.0 } },
        }, &.{ 0, 1, 2 });
    } else {
        rdl.addVertices(null, &.{
            .{ .pos = .{ 8, 10 }, .uv = .{ -1, -1 }, .tint = .{ 255, 255, 255, 255 }, .circle = .{ 0.0, 0.0 } },
            .{ .pos = .{ 18, 10 }, .uv = .{ -1, -1 }, .tint = .{ 255, 255, 255, 255 }, .circle = .{ 0.0, 0.0 } },
            .{ .pos = .{ 13, 15 }, .uv = .{ -1, -1 }, .tint = .{ 255, 255, 255, 255 }, .circle = .{ 0.0, 0.0 } },
        }, &.{ 0, 1, 2 });
    }
    if (btn_state.active) {
        rdl.addRect(.{
            .pos = .{ 2, 2 },
            .size = .{ titlebar_height - 4, titlebar_height - 4 },
            .tint = colors.window_active_tab,
            .rounding = .{ .corners = .all, .radius = 6.0 },
        });
    }
    return .{ .rdl = rdl, .size = .{ titlebar_height, titlebar_height } };
}
fn drawWindowTabbed(root_container: B2.FloatingContainerID, wm: *B2.WindowManager, win: *B2.WindowTreeNode, current_tab: B2.WindowTreeNodeID, tabs: []B2.WindowTreeNode, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32)) void {
    // draw titlebar

    const rdl = wm.this_frame_rdl.?;
    const window_id = wm.idForWindowTreeNode(@src(), win.id);

    const text_line_res = B2.textLine(.{ .caller_id = window_id.sub(@src()), .constraints = .{ .available_size = .{ .w = offset_size[0], .h = null } } }, .{ .text = "Title" });
    // we can replace the manual calculations with:
    // padding(border_width / 2, h(vcenter(collapseicon), space, vcenter(tab1), space, vcenter(tab2), space, vcenter(tab3)))
    rdl.place(B2.button(.{ .caller_id = window_id.sub(@src()), .constraints = .{ .available_size = .{ .w = null, .h = null } } }, .{
        .onClick = .from(win, drawWindowTabbed_collapseButtonClicked),
    }, .from(win, drawWindowTabbed_collapseButtonChild)).rdl, .{ .offset = offset_pos });
    const btn_height = titlebar_height - 4.0;
    rdl.place(text_line_res.rdl, .{ .offset = .{ offset_pos[0] + border_width * 5, offset_pos[1] + (titlebar_height - text_line_res.size[1]) / 2.0 } });
    rdl.addRect(.{
        .pos = .{ offset_pos[0] + border_width * 4, offset_pos[1] + (titlebar_height - btn_height) / 2.0 },
        .size = .{ text_line_res.size[0] + border_width * 2, btn_height },
        .tint = colors.window_active_tab,
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });
    rdl.addRect(.{
        .pos = offset_pos,
        .size = .{ offset_size[0], titlebar_height },
        .tint = colors.window_bg,
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });
    rdl.addMouseEventCapture2(window_id.sub(@src()), offset_pos, .{ offset_size[0], titlebar_height + border_width }, .{
        .onMouseEvent = .from(wm.makeWindowEventInfo(.{ .resize = .{ .window = root_container, .sides = .all } }), B2.WindowManager.handleWindowEvent),
    });
    const current_tab_node = for (tabs) |*tab| {
        if (tab.id == current_tab) break tab;
    } else @panic("tab not found; TODO?");
    if (win.collapsed) {
        // ...
    } else {
        return drawWindowNode(root_container, wm, current_tab_node, offset_pos + @Vector(2, f32){ 0, titlebar_height + border_width }, offset_size - @Vector(2, f32){ 0, titlebar_height + border_width }, .{ .parent_is_tabs = true });
    }
}
fn drawWindowNode(root_container: B2.FloatingContainerID, wm: *B2.WindowManager, win: *B2.WindowTreeNode, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32), cfg: struct { parent_is_tabs: bool }) void {
    switch (win.value) {
        .final => |window_content_id| {
            if (cfg.parent_is_tabs) {
                return drawWindowFinal(window_content_id, wm, offset_pos, offset_size);
            } else {
                return drawWindowTabbed(root_container, wm, win, win.id, win[0..1], offset_pos, offset_size);
            }
        },
        .tabs => |t| {
            return drawWindowTabbed(root_container, wm, win, t.selected_tab, t.items.items, offset_pos, offset_size);
        },
        .list => |l| {
            _ = l;
            @panic("TODO list");
        },
    }
}

fn captureResize(rdl: *B2.RepositionableDrawList, wm: *B2.WindowManager, id: B2.ID, ikey: B2.WindowIkeyInteractionModel, pos: @Vector(2, f32), size: @Vector(2, f32)) void {
    rdl.addMouseEventCapture2(id, pos, size, .{
        .onMouseEvent = .from(wm.makeWindowEventInfo(ikey), B2.WindowManager.handleWindowEvent),
    });
}
pub fn drawFullscreenOverlay(wm: *B2.WindowManager, win: *B2.FullscreenOverlay) void {
    const rdl = wm.this_frame_rdl.?;

    const slot = rdl.reserve();
    const win_data = wm.windows.getPtr(win.contents).?;
    win_data.* = .{ .slot = slot, .position = .{ 0, 0 }, .size = .{ 0, 0 } };
}
pub fn drawFloatingContainer(wm: *B2.WindowManager, win: *B2.FloatingWindow) void {
    const id = wm.idForFloatingContainer(@src(), win.id);
    const rdl = wm.this_frame_rdl.?;

    const resize_width = border_width * 2;

    const win_pos = @floor(win.position);
    var win_size = @floor(win.size);
    if (win.contents.collapsed) win_size[1] = titlebar_height;
    const whole_pos: @Vector(2, f32) = win_pos + @Vector(2, f32){ -border_width, -border_width };
    const whole_size: @Vector(2, f32) = win_size + @Vector(2, f32){ border_width * 2, border_width * 2 };
    const whole_pos_incl_resize: @Vector(2, f32) = win_pos + @Vector(2, f32){ -resize_width, -resize_width };
    const whole_size_incl_resize: @Vector(2, f32) = win_size + @Vector(2, f32){ resize_width * 2, resize_width * 2 };

    // add the raise capture
    captureResize(rdl, wm, id.sub(@src()), .{ .raise = .{ .window = win.id } }, whole_pos_incl_resize, whole_size_incl_resize);

    // add the resize captures
    if (!win.contents.collapsed) captureResize(rdl, wm, id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .top, .cursor = .resize_ns } }, .{ win_pos[0], win_pos[1] + -resize_width }, .{ win_size[0], resize_width });
    if (!win.contents.collapsed) captureResize(rdl, wm, id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .top_right, .cursor = .resize_ne_sw } }, .{ win_pos[0] + win_size[0], win_pos[1] - resize_width }, .{ resize_width, resize_width });
    captureResize(rdl, wm, id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .right, .cursor = .resize_ew } }, .{ win_pos[0] + win_size[0], win_pos[1] }, .{ resize_width, win_size[1] });
    if (!win.contents.collapsed) captureResize(rdl, wm, id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .bottom_right, .cursor = .resize_nw_se } }, .{ win_pos[0] + win_size[0], win_pos[1] + win_size[1] }, .{ resize_width, resize_width });
    if (!win.contents.collapsed) captureResize(rdl, wm, id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .bottom, .cursor = .resize_ns } }, .{ win_pos[0], win_pos[1] + win_size[1] }, .{ win_size[0], resize_width });
    if (!win.contents.collapsed) captureResize(rdl, wm, id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .bottom_left, .cursor = .resize_ne_sw } }, .{ win_pos[0] - resize_width, win_pos[1] + win_size[1] }, .{ resize_width, resize_width });
    captureResize(rdl, wm, id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .left, .cursor = .resize_ew } }, .{ win_pos[0] - resize_width, win_pos[1] }, .{ resize_width, win_size[1] });
    if (!win.contents.collapsed) captureResize(rdl, wm, id.sub(@src()), .{ .resize = .{ .window = win.id, .sides = .top_left, .cursor = .resize_nw_se } }, .{ win_pos[0] - resize_width, win_pos[1] - resize_width }, .{ resize_width, resize_width });

    // render the children
    drawWindowNode(win.id, wm, &win.contents, win_pos, win_size, .{ .parent_is_tabs = false });

    // add the black rectangle
    rdl.addRect(.{
        .pos = whole_pos,
        .size = whole_size,
        .tint = .fromHexRgb(0x000000),
        .rounding = .{ .corners = .all, .radius = 12.0 },
    });

    // add the fallthrough capture so events don't fall through the black rectangle
    captureResize(rdl, wm, id.sub(@src()), .ignore, whole_pos_incl_resize, whole_size_incl_resize);
    // TODO need to capture scroll events so they don't fall through. specifically, using a capture mode no_scroll so
    // it won't try to lock a touch event into scrolling when it could tap.
}

pub fn renderWindows(id_in: B2.ID, size: @Vector(2, f32), wm: *WM.WM, result: *WM.Manager.RenderWindowResult) *B2.RepositionableDrawList {
    const id = id_in.sub(@src());
    _ = size;
    const res = id.b2.draw();
    // loop in reverse because first item = backmost
    var i: usize = wm.top_level_windows.items.len;
    while (i > 0) {
        i -= 1;
        const win = wm.top_level_windows.items[i];

        _ = win;
        _ = result;
    }

    return res;
}
