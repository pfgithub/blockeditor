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
    pub const window_drop_spot: Beui.Color = .fromHexRgb(0xA5D8FF);
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

fn drawWindowFinal(man: *WM.Manager, rdl: *B2.RepositionableDrawList, window_content_id: WM.WM.FrameID, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32)) void {
    const clip = man.id_for_frame.?.b2.draw();
    rdl.addClip(clip, .{ .pos = offset_pos, .size = offset_size });
    const slot = clip.reserve();
    man.render_windows_ctx.getPtr(window_content_id).?.result = .{ .filled = .{
        .pos = offset_pos,
        .size = offset_size,
        .reservation = slot,
    } };
}
fn drawWindowTabbed_closeButtonClicked(data: *CollapseData, _: *B2.Beui2, _: void) void {
    if (!data.man.wm.existsFrame(data.frame)) return;
    data.man.wm.removeFrame(data.frame);
}
fn drawWindowTabbed_collapseButtonClicked(data: *CollapseData, _: *B2.Beui2, _: void) void {
    if (!data.man.wm.existsFrame(data.frame)) return;
    const frame = data.man.wm.getFrame(data.frame);
    frame.collapsed = !frame.collapsed;
}
fn drawWindowTabbed_closeButtonChild(_: *CollapseData, call_info: B2.StandardCallInfo, btn_state: B2.ButtonState) B2.StandardChild {
    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    rdl.addVertices(null, &.{
        // TODO x shape
        .{ .pos = .{ 8, 10 }, .uv = .{ -1, -1 }, .tint = .{ 255, 255, 255, 255 }, .circle = .{ 0.0, 0.0 } },
        .{ .pos = .{ 18, 10 }, .uv = .{ -1, -1 }, .tint = .{ 255, 255, 255, 255 }, .circle = .{ 0.0, 0.0 } },
        .{ .pos = .{ 13, 15 }, .uv = .{ -1, -1 }, .tint = .{ 255, 255, 255, 255 }, .circle = .{ 0.0, 0.0 } },
    }, &.{ 0, 1, 2 });
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
fn drawWindowTabbed_collapseButtonChild(data: *CollapseData, call_info: B2.StandardCallInfo, btn_state: B2.ButtonState) B2.StandardChild {
    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    // this is missing antialiasing, we should use an icon instead
    if (data.man.wm.getFrame(data.frame).collapsed) {
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
const CollapseData = struct {
    man: *WM.Manager,
    frame: WM.WM.FrameID,
};
fn drawWindowTabbed(man: *WM.Manager, rdl: *B2.RepositionableDrawList, top: ?TopInfo, win: WM.WM.FrameID, current_tab: WM.WM.FrameID, tabs: []const WM.WM.FrameID, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32)) void {
    // draw titlebar

    const window_id = man.idForFrame(@src(), win);
    const collapsebtn_data = &(window_id.b2.frame.arena.dupe(CollapseData, &.{
        .{ .man = man, .frame = win },
    }) catch @panic("oom"))[0];
    const closebtn_data = &(window_id.b2.frame.arena.dupe(CollapseData, &.{
        .{ .man = man, .frame = current_tab },
    }) catch @panic("oom"))[0];
    const title = man.render_windows_ctx.getPtr(current_tab).?;
    const text_line_res = B2.textLine(.{ .caller_id = window_id.sub(@src()), .constraints = .{ .available_size = .{ .w = offset_size[0], .h = null } } }, .{ .text = title.title });
    // we can replace the manual calculations with:
    // padding(border_width / 2, h(vcenter(collapseicon), space, vcenter(tab1), space, vcenter(tab2), space, vcenter(tab3)))
    rdl.place(B2.button(.{ .caller_id = window_id.sub(@src()), .constraints = .{ .available_size = .{ .w = null, .h = null } } }, .{
        .onClick = .from(collapsebtn_data, drawWindowTabbed_collapseButtonClicked),
    }, .from(collapsebtn_data, drawWindowTabbed_collapseButtonChild)).rdl, .{ .offset = offset_pos });
    const btn_height = titlebar_height - 4.0;
    rdl.place(text_line_res.rdl, .{ .offset = .{ offset_pos[0] + border_width * 5, offset_pos[1] + (titlebar_height - text_line_res.size[1]) / 2.0 } });
    rdl.place(B2.button(.{ .caller_id = window_id.sub(@src()), .constraints = .{ .available_size = .{ .w = null, .h = null } } }, .{
        .onClick = .from(closebtn_data, drawWindowTabbed_closeButtonClicked),
    }, .from(closebtn_data, drawWindowTabbed_closeButtonChild)).rdl, .{ .offset = .{ offset_pos[0] + border_width * 5 + text_line_res.size[0], offset_pos[1] } });
    const tab_pos: @Vector(2, f32) = .{ offset_pos[0] + border_width * 4, offset_pos[1] + (titlebar_height - btn_height) / 2.0 };
    const tab_size: @Vector(2, f32) = .{ text_line_res.size[0] + border_width * 2, btn_height };
    rdl.addRect(.{
        .pos = tab_pos,
        .size = tab_size,
        .tint = colors.window_active_tab,
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });
    // const user_state_id = window_id.sub(@src());
    // rdl.addUserState(user_state_id, void, &{});
    captureResize(rdl, man, window_id.sub(@src()), .{
        .grab_tab = .{ .tab = tabs[0], .offset = offset_pos },
    }, tab_pos, tab_size);
    rdl.addRect(.{
        .pos = offset_pos,
        .size = .{ offset_size[0], titlebar_height },
        .tint = colors.window_bg,
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });
    captureResize(rdl, man, window_id.sub(@src()), .{ .resize = .{ .window = man.wm.findRoot(win), .sides = .all } }, offset_pos, .{ offset_size[0], titlebar_height + border_width });
    const current_tab_node = for (tabs) |tab| {
        if (tab == current_tab) break tab;
    } else @panic("tab not found; TODO?");

    if (man.wm.getFrame(current_tab).collapsed) {
        // ...
    } else {
        return drawWindowNode(man, rdl, top, current_tab_node, offset_pos + @Vector(2, f32){ 0, titlebar_height + border_width }, offset_size - @Vector(2, f32){ 0, titlebar_height + border_width }, .{ .parent_is_tabs = true });
    }
}
fn drawDropPoint(man: *WM.Manager, id: B2.ID, node: WM.WM.FrameID, dir: B2.Direction, rdl: *B2.RepositionableDrawList, pos: @Vector(2, f32), size: @Vector(2, f32)) void {
    _ = node;
    _ = dir;
    captureResize(rdl, man, id, .ignore, pos, size);
    rdl.addRect(.{
        .pos = pos,
        .size = size,
        .tint = colors.window_drop_spot,
    });
}
fn drawWindowNode(man: *WM.Manager, rdl: *B2.RepositionableDrawList, parent_top: ?TopInfo, win: WM.WM.FrameID, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32), cfg: struct { parent_is_tabs: bool }) void {
    var child_top: ?TopInfo = null;
    if (parent_top) |top| if (top.skip != B2.Sides.all) {
        const id = man.idForFrame(@src(), win);
        if (!top.skip._top) drawDropPoint(man, id.sub(@src()), win, .top, top.rdl, .{ top.pos[0] + border_width, top.pos[1] }, .{ top.size[0] - border_width * 2, border_width });
        if (!top.skip._bottom) drawDropPoint(man, id.sub(@src()), win, .bottom, top.rdl, .{ top.pos[0] + border_width, top.pos[1] + top.size[1] - border_width }, .{ top.size[0] - border_width * 2, border_width });
        if (!top.skip._left) drawDropPoint(man, id.sub(@src()), win, .left, top.rdl, .{ top.pos[0], top.pos[1] + border_width }, .{ border_width, top.size[1] - border_width * 2 });
        if (!top.skip._right) drawDropPoint(man, id.sub(@src()), win, .right, top.rdl, .{ top.pos[0] + top.size[0] - border_width, top.pos[1] + border_width }, .{ border_width, top.size[1] - border_width * 2 });
        child_top = .{
            .rdl = top.rdl,
            .pos = .{ top.pos[0] + border_width, top.pos[1] + border_width },
            .size = .{ top.size[0] - border_width * 2, top.size[1] - border_width * 2 },
            .skip = .none,
        };
    };
    const frame = man.wm.getFrame(win);
    switch (frame.self) {
        .final => {
            if (cfg.parent_is_tabs) {
                return drawWindowFinal(man, rdl, win, offset_pos, offset_size);
            } else {
                return drawWindowTabbed(man, rdl, if (child_top) |t| .{ .rdl = t.rdl, .pos = t.pos, .size = t.size, .skip = .all } else null, win, win, &.{win}, offset_pos, offset_size);
            }
        },
        .tabbed => |t| {
            return drawWindowTabbed(man, rdl, child_top, win, t.current_tab.?, t.children.items, offset_pos, offset_size);
        },
        else => std.debug.panic("TODO: {s}", .{@tagName(frame.self)}),
    }
}
fn drawWindowDragging(man: *WM.Manager, rdl: *B2.RepositionableDrawList, win: WM.WM.FrameID, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32)) void {
    const frame = man.wm.getFrame(win);
    switch (frame.self) {
        .dragging => |d| {
            drawWindowNode(man, rdl, null, d.child, offset_pos, offset_size, .{ .parent_is_tabs = false });
        },
        else => unreachable,
    }
}

const WindowEventInfo = struct {
    im: WindowIkeyInteractionModel,
    man: *WM.Manager,
};

pub const WindowIkeyInteractionModel = union(enum) {
    raise: struct { window: WM.WM.FrameID },
    resize: struct { window: WM.WM.FrameID, sides: B2.Sides, cursor: Beui.Cursor = .arrow },
    ignore,
    grab_tab: struct { tab: WM.WM.FrameID, offset: @Vector(2, f32) },
};
fn captureResize__handleWindowEvent(wid: *WindowEventInfo, b2: *B2.Beui2, ev: B2.MouseEvent) ?Beui.Cursor {
    _ = b2;
    switch (wid.im) {
        .ignore => return .arrow,
        .raise => |r| {
            if (ev.action == .down) wid.man.wm.bringToFront(r.window);
            return null;
        },
        .resize => |resize| {
            if (ev.action == .down) {
                if (ev.pos) |pos| wid.man.beginResize(resize.window, pos);
            }
            if (ev.action == .move_while_down or ev.action == .up) {
                if (ev.pos) |pos| wid.man.updateResize(resize.window, resize.sides, pos);
            }
            if (ev.action == .up) {
                wid.man.endResize(resize.window);
            }
            return resize.cursor;
        },
        .grab_tab => |grab_tab| {
            if (ev.action == .move_while_down and wid.man.wm.dragging == WM.WM.FrameID.not_set) {
                const offset = ev.pos.? - ev.drag_start_pos.?;
                const dist = std.math.sqrt(offset[0] * offset[0] + offset[1] * offset[1]);
                if (dist > 3.0) {
                    wid.man.wm.grabFrame(grab_tab.tab);
                    wid.man.dragging.anim_start = grab_tab.offset;
                    wid.man.dragging.anim_start_ms = std.time.milliTimestamp();
                    // if (b2.getPrevFrameDrawListState(grab_tab.user_state_id)) |si| {
                    //     wid.man.dragging.anim_start = si.offset_from_screen_ul;
                    //     wid.man.dragging.anim_start_ms = std.time.milliTimestamp();
                    // } else {
                    //     wid.man.dragging.anim_start_ms = 0;
                    // }

                    // starting now, we would like to treat this as a drag
                    // - if man.dragging:
                    //   - add a drop handler in the tab bar (per tab?)
                    //   - add a drop handler for top, left, bottom, right
                    // - how do we handle the drag?
                    //   - currently, if there is a mouse focus, mouse events are only sent to that mouse focus
                    //   - we need to mark the mouse event as a drag. like `b2.convertToDrag(scope: wid, data: frameid, handler: captureResize__handleDragEvent)`
                    //     - and then use regular drop handlers as B2.dropHandler(scope: wid, pos, size, dropHandler__renderChild)
                    //   - only drop handlers of the same scope are used. and this drag/drop event is for copy not for move
                }
            }
            if (ev.action == .move_while_down and wid.man.wm.dragging != WM.WM.FrameID.not_set) {
                wid.man.dragging.pos = ev.pos.?;
            }
            if (ev.action == .up) {
                wid.man.wm.dropFrameNewWindow();
                const wi = wid.man.getWindowInfo(grab_tab.tab);
                wid.man.setWindowInfo(grab_tab.tab, .{
                    .pos = ev.pos.?,
                    .size = wi.size,
                    ._minitial = null,
                });
            }
            return .arrow;
        },
    }
}
fn captureResize(rdl: *B2.RepositionableDrawList, man: *WM.Manager, id: B2.ID, ikey: WindowIkeyInteractionModel, pos: @Vector(2, f32), size: @Vector(2, f32)) void {
    const wid = id.b2.frame.arena.create(WindowEventInfo) catch @panic("oom");
    wid.* = .{ .im = ikey, .man = man };
    rdl.addMouseEventCapture2(id, pos, size, .{
        .onMouseEvent = .from(wid, captureResize__handleWindowEvent),
    });
}
pub fn drawFullscreenOverlay(wm: *B2.WindowManager, win: *B2.FullscreenOverlay) void {
    const rdl = wm.this_frame_rdl.?;

    const slot = rdl.reserve();
    const win_data = wm.windows.getPtr(win.contents).?;
    win_data.* = .{ .slot = slot, .position = .{ 0, 0 }, .size = .{ 0, 0 } };
}
pub fn drawFloatingContainer(man: *WM.Manager, frame: WM.WM.FrameID, rdl: *B2.RepositionableDrawList, top: ?TopInfo, win_position_in: @Vector(2, f32), win_size_in: @Vector(2, f32)) void {
    const id = man.idForFrame(@src(), frame);
    const wm = &man.wm;

    const resize_width = border_width * 2;
    const collapsed = wm.getFrame(wm.getFrame(frame).self.window.child).collapsed;

    const win_pos = @floor(win_position_in);
    var win_size = @floor(win_size_in);
    if (collapsed) win_size[1] = titlebar_height;
    const whole_pos: @Vector(2, f32) = win_pos + @Vector(2, f32){ -border_width, -border_width };
    const whole_size: @Vector(2, f32) = win_size + @Vector(2, f32){ border_width * 2, border_width * 2 };
    const whole_pos_incl_resize: @Vector(2, f32) = win_pos + @Vector(2, f32){ -resize_width, -resize_width };
    const whole_size_incl_resize: @Vector(2, f32) = win_size + @Vector(2, f32){ resize_width * 2, resize_width * 2 };

    // add the raise capture
    captureResize(rdl, man, id.sub(@src()), .{ .raise = .{ .window = frame } }, whole_pos_incl_resize, whole_size_incl_resize);

    // add the resize captures
    if (!collapsed) captureResize(rdl, man, id.sub(@src()), .{ .resize = .{ .window = frame, .sides = .top, .cursor = .resize_ns } }, .{ win_pos[0], win_pos[1] + -resize_width }, .{ win_size[0], resize_width });
    if (!collapsed) captureResize(rdl, man, id.sub(@src()), .{ .resize = .{ .window = frame, .sides = .top_right, .cursor = .resize_ne_sw } }, .{ win_pos[0] + win_size[0], win_pos[1] - resize_width }, .{ resize_width, resize_width });
    captureResize(rdl, man, id.sub(@src()), .{ .resize = .{ .window = frame, .sides = .right, .cursor = .resize_ew } }, .{ win_pos[0] + win_size[0], win_pos[1] }, .{ resize_width, win_size[1] });
    if (!collapsed) captureResize(rdl, man, id.sub(@src()), .{ .resize = .{ .window = frame, .sides = .bottom_right, .cursor = .resize_nw_se } }, .{ win_pos[0] + win_size[0], win_pos[1] + win_size[1] }, .{ resize_width, resize_width });
    if (!collapsed) captureResize(rdl, man, id.sub(@src()), .{ .resize = .{ .window = frame, .sides = .bottom, .cursor = .resize_ns } }, .{ win_pos[0], win_pos[1] + win_size[1] }, .{ win_size[0], resize_width });
    if (!collapsed) captureResize(rdl, man, id.sub(@src()), .{ .resize = .{ .window = frame, .sides = .bottom_left, .cursor = .resize_ne_sw } }, .{ win_pos[0] - resize_width, win_pos[1] + win_size[1] }, .{ resize_width, resize_width });
    captureResize(rdl, man, id.sub(@src()), .{ .resize = .{ .window = frame, .sides = .left, .cursor = .resize_ew } }, .{ win_pos[0] - resize_width, win_pos[1] }, .{ resize_width, win_size[1] });
    if (!collapsed) captureResize(rdl, man, id.sub(@src()), .{ .resize = .{ .window = frame, .sides = .top_left, .cursor = .resize_nw_se } }, .{ win_pos[0] - resize_width, win_pos[1] - resize_width }, .{ resize_width, resize_width });

    // render the children
    drawWindowNode(man, rdl, if (top) |t| .{
        .rdl = t.rdl,
        .pos = win_pos,
        .size = win_size,
        .skip = .none,
    } else null, wm.getFrame(frame).self.window.child, win_pos, win_size, .{ .parent_is_tabs = false });

    // add the black rectangle
    rdl.addRect(.{
        .pos = whole_pos,
        .size = whole_size,
        .tint = .fromHexRgb(0x000000),
        .rounding = .{ .corners = .all, .radius = 12.0 },
    });

    // add the fallthrough capture so events don't fall through the black rectangle
    captureResize(rdl, man, id.sub(@src()), .ignore, whole_pos_incl_resize, whole_size_incl_resize);
    // TODO need to capture scroll events so they don't fall through. specifically, using a capture mode no_scroll so
    // it won't try to lock a touch event into scrolling when it could tap.
}

fn easeInOutQuint(x: f32) f32 {
    // https://easings.net/ EaseInOutQuint
    return 1 - std.math.pow(f32, 1 - x, 5);
}
fn step(comptime T: type, a: T, b: T, t: T) T {
    return a + t * (b - a);
}

pub fn renderWindows(b2: *B2.Beui2, size: @Vector(2, f32), man: *WM.Manager) *B2.RepositionableDrawList {
    const rdl = b2.draw();

    if (man.wm.dragging != WM.WM.FrameID.not_set) {
        const start_ms: f64 = @floatFromInt(man.dragging.anim_start_ms);
        const now_ms: f64 = @floatFromInt(b2.persistent.beui1.frame.frame_cfg.?.now_ms);
        const diff: f32 = @floatCast(now_ms - start_ms);
        const diff_scaled: f32 = @max(@min(diff / 200.0, 1.0), 0.0); // 200ms anim
        const diff_functioned: f32 = easeInOutQuint(diff_scaled);
        const rescaled = step(@Vector(2, f32), man.dragging.anim_start, man.dragging.pos, @splat(diff_functioned));
        drawWindowDragging(man, rdl, man.wm.dragging, rescaled, .{ 300, 300 });
    }

    // loop in reverse because [0] = backmost, [len - 1] = frontmost
    var i: usize = man.wm.top_level_windows.items.len;
    while (i > 0) {
        i -= 1;
        const win = man.wm.top_level_windows.items[i];
        const win_info = man.getWindowInfo(win);
        const top_rdl = b2.draw();
        rdl.place(top_rdl, .{});
        drawFloatingContainer(man, win, rdl, .{
            .rdl = top_rdl,
            .pos = win_info.pos,
            .size = win_info.size,
            .skip = .none,
        }, win_info.pos, win_info.size);
    }

    // background
    rdl.addRect(.{ .pos = .{ 0, 0 }, .size = size, .tint = colors.window_bg });

    return rdl;
}

const TopInfo = struct {
    rdl: *B2.RepositionableDrawList,
    pos: @Vector(2, f32),
    size: @Vector(2, f32),
    skip: B2.Sides,
};
