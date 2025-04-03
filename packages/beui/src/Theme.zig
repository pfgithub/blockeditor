//! contains default beui-themed components.

const Beui = @import("Beui.zig");
const B2 = @import("beui_experiment.zig");
const WM = @import("wm.zig");
const std = @import("std");

pub const window_padding: f32 = border_width * 2;
pub const border_width: f32 = 6.0;

pub const colors = struct {
    pub const window_border: Beui.Color = .fromHexRgb(0x000000);
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

fn drawWindowFinal(ctx: RenderWindowCtx, rdl: *B2.RepositionableDrawList, window_content_id: WM.WM.FrameID, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32)) void {
    const clip = ctx.man.id_for_frame.?.b2.draw();
    rdl.addClip(clip, .{ .pos = offset_pos, .size = offset_size });
    clip.place(ctx.cb.call(.{ .block = ctx.man.wm.getFrame(window_content_id).self.final.ref, .call_info = .{
        .caller_id = ctx.man.idForFrame(@src(), window_content_id),
        .constraints = .{ .available_size = .{ .w = offset_size[0], .h = offset_size[1] } },
    } }), .{ .offset = offset_pos });
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
            .rounding = .{ .corners = .all, .radius = border_width },
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
            .rounding = .{ .corners = .all, .radius = border_width },
        });
    }
    return .{ .rdl = rdl, .size = .{ titlebar_height, titlebar_height } };
}
const CollapseData = struct {
    man: *WM.Manager,
    frame: WM.WM.FrameID,
};
fn drawWindowTabbed(ctx: RenderWindowCtx, rdl: *B2.RepositionableDrawList, top: ?TopInfo, win: WM.WM.FrameID, current_tab: WM.WM.FrameID, tabs: []const WM.WM.FrameID, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32)) void {
    const man = ctx.man;
    // draw titlebar

    const window_id = man.idForFrame(@src(), win);

    if (top) |_| {
        drawDropPoint(man, window_id.sub(@src()), current_tab, .tab_right, rdl, offset_pos, .{ offset_size[0], titlebar_height });
    }

    const collapsebtn_data = &(window_id.b2.frame.arena.dupe(CollapseData, &.{
        .{ .man = man, .frame = win },
    }) catch @panic("oom"))[0];
    const closebtn_data = &(window_id.b2.frame.arena.dupe(CollapseData, &.{
        .{ .man = man, .frame = current_tab },
    }) catch @panic("oom"))[0];
    const title: []const u8 = "Untitled";
    const text_line_res = B2.textLine(.{ .caller_id = window_id.sub(@src()), .constraints = .{ .available_size = .{ .w = offset_size[0], .h = null } } }, .{ .text = title });
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
        .rounding = .{ .corners = .all, .radius = border_width },
    });
    // const user_state_id = window_id.sub(@src());
    // rdl.addUserState(user_state_id, void, &{});
    captureResize(rdl, man, man.idForFrame(@src(), tabs[0]), .{
        .grab_tab = .{ .tab = tabs[0], .offset = offset_pos },
    }, tab_pos, tab_size);
    rdl.addRect(.{
        .pos = offset_pos,
        .size = .{ offset_size[0], titlebar_height },
        .tint = colors.window_bg,
        .rounding = .{ .corners = .all, .radius = border_width },
    });
    captureResize(rdl, man, window_id.sub(@src()), .{ .resize = .{ .window = man.wm.findRoot(win), .sides = .all } }, offset_pos, .{ offset_size[0], titlebar_height + border_width });
    const current_tab_node = for (tabs) |tab| {
        if (tab == current_tab) break tab;
    } else @panic("tab not found; TODO?");

    if (man.wm.getFrame(current_tab).collapsed) {
        // ...
    } else {
        return drawWindowNode(ctx, rdl, top, current_tab_node, offset_pos + @Vector(2, f32){ 0, titlebar_height + border_width }, offset_size - @Vector(2, f32){ 0, titlebar_height + border_width }, .{ .parent_is_tabs = true });
    }
}
fn drawDropPoint(man: *WM.Manager, id: B2.ID, node: WM.WM.FrameID, tdp: DropPos, rdl: *B2.RepositionableDrawList, pos: @Vector(2, f32), size: @Vector(2, f32)) void {
    captureResize(rdl, man, id, .{ .insert = .{ .window = node, .pos = tdp } }, pos, size);
    rdl.addRect(.{
        .pos = pos,
        .size = size,
        .tint = colors.window_drop_spot,
    });
}
fn drawWindowNode(ctx: RenderWindowCtx, rdl: *B2.RepositionableDrawList, parent_top: ?TopInfo, win: WM.WM.FrameID, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32), cfg: struct { parent_is_tabs: bool }) void {
    const man = ctx.man;
    var child_top: ?TopInfo = null;
    if (parent_top) |top| if (top.skip != B2.Sides.all) {
        const id = man.idForFrame(@src(), win);
        const left_offset: f32 = if (top.skip._left) 0 else border_width;
        const right_offset: f32 = if (top.skip._right) 0 else border_width;
        const top_offset: f32 = if (top.skip._top) 0 else border_width;
        const bottom_offset: f32 = if (top.skip._bottom) 0 else border_width;
        if (!top.skip._top) drawDropPoint(man, id.sub(@src()), win, .split_top, top.rdl, .{ top.pos[0] + left_offset, top.pos[1] }, .{ top.size[0] - left_offset - right_offset, border_width });
        if (!top.skip._bottom) drawDropPoint(man, id.sub(@src()), win, .split_bottom, top.rdl, .{ top.pos[0] + left_offset, top.pos[1] + top.size[1] - border_width }, .{ top.size[0] - left_offset - right_offset, border_width });
        if (!top.skip._left) drawDropPoint(man, id.sub(@src()), win, .split_left, top.rdl, .{ top.pos[0], top.pos[1] + top_offset }, .{ border_width, top.size[1] - top_offset - bottom_offset });
        if (!top.skip._right) drawDropPoint(man, id.sub(@src()), win, .split_right, top.rdl, .{ top.pos[0] + top.size[0] - border_width, top.pos[1] + top_offset }, .{ border_width, top.size[1] - top_offset - bottom_offset });
        child_top = .{
            .rdl = top.rdl,
            .pos = .{ top.pos[0] + left_offset, top.pos[1] + top_offset },
            .size = .{ top.size[0] - left_offset - right_offset, top.size[1] - top_offset - bottom_offset },
            .skip = .none,
        };
    };
    const frame = man.wm.getFrame(win);
    switch (frame.self) {
        .final => |f| {
            if (cfg.parent_is_tabs) {
                if (f.ref == null and false) {
                    rdl.addRect(.{
                        .pos = offset_pos,
                        .size = offset_size,
                        .tint = colors.window_bg,
                    });
                } else {
                    return drawWindowFinal(ctx, rdl, win, offset_pos, offset_size);
                }
            } else {
                return drawWindowTabbed(ctx, rdl, if (child_top) |t| .{ .rdl = t.rdl, .pos = t.pos, .size = t.size, .skip = .all } else null, win, win, &.{win}, offset_pos, offset_size);
            }
        },
        .tabbed => |t| {
            return drawWindowTabbed(ctx, rdl, child_top, win, t.current_tab, t.children.items, offset_pos, offset_size);
        },
        .split => |s| {
            const len_f: f32 = @floatFromInt(s.children.items.len);
            const w = border_width * 2;
            const rem_space: f32 = s.axis.flip(offset_size)[0] - (len_f - 1.0) * w;
            const per_child_space: f32 = @floor(rem_space / len_f);
            var child_size = s.axis.flip(offset_size);
            child_size[0] = per_child_space;
            var pos = s.axis.flip(offset_pos);
            const skip: B2.Sides = switch (s.axis) {
                .x => .left_right,
                .y => .top_bottom,
            };
            for (s.children.items, 0..) |ch, i| {
                if (i != 0) {
                    if (child_top) |t| {
                        drawDropPoint(man, man.idForFrame(@src(), ch), ch, .tab_left, t.rdl, s.axis.flip(@Vector(2, f32){ pos[0] - w, pos[1] }), s.axis.flip(@Vector(2, f32){ w, child_size[1] }));
                    }
                    captureResize(rdl, man, man.idForFrame(@src(), ch), .{ .resize = .{ .window = man.wm.findRoot(win), .sides = .all, .cursor = switch (s.axis) {
                        .x => .resize_ew,
                        .y => .resize_ns,
                    } } }, s.axis.flip(@Vector(2, f32){ pos[0] - w, pos[1] }), s.axis.flip(@Vector(2, f32){ w, child_size[1] }));
                }
                drawWindowNode(
                    ctx,
                    rdl,
                    if (child_top) |t| t.within(s.axis.flip(pos), s.axis.flip(child_size), skip) else null,
                    ch,
                    s.axis.flip(pos),
                    s.axis.flip(child_size),
                    .{ .parent_is_tabs = false },
                );
                pos[0] += per_child_space + w;
            }
        },
        else => std.debug.panic("TODO: {s}", .{@tagName(frame.self)}),
    }
}
fn drawWindowDragging(ctx: RenderWindowCtx, rdl: *B2.RepositionableDrawList, win: WM.WM.FrameID, offset_pos: @Vector(2, f32), offset_size: @Vector(2, f32)) void {
    const frame = ctx.man.wm.getFrame(win);
    switch (frame.self) {
        .dragging => |d| {
            drawWindowNode(ctx, rdl, null, d.child, offset_pos, offset_size, .{ .parent_is_tabs = false });
        },
        else => unreachable,
    }
}

const WindowEventInfo = struct {
    im: WindowIkeyInteractionModel,
    man: *WM.Manager,
};

pub const DropPos = enum {
    split_left,
    split_right,
    split_top,
    split_bottom,
    tab_left,
    tab_right,
};
pub const WindowIkeyInteractionModel = union(enum) {
    raise: struct { window: WM.WM.FrameID },
    resize: struct { window: WM.WM.FrameID, sides: B2.Sides, cursor: Beui.Cursor = .arrow },
    ignore,
    grab_tab: struct { tab: WM.WM.FrameID, offset: @Vector(2, f32) },
    insert: struct { window: WM.WM.FrameID, pos: DropPos },
};
fn captureResize__handleWindowEvent(wid: *WindowEventInfo, b2: *B2.Beui2, ev: B2.MouseEvent) ?Beui.Cursor {
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
        .insert => |insert| {
            if (ev.action == .up and wid.man.wm.dragging != WM.WM.FrameID.not_set) {
                if (B2.pointInRect(ev.pos.?, ev.capture_pos, ev.capture_size)) {
                    switch (insert.pos) {
                        .split_top => wid.man.wm.moveFrameToSplit(wid.man.wm.getFrame(wid.man.wm.dragging).self.dragging.child, insert.window, .top),
                        .split_bottom => wid.man.wm.moveFrameToSplit(wid.man.wm.getFrame(wid.man.wm.dragging).self.dragging.child, insert.window, .bottom),
                        .split_left => wid.man.wm.moveFrameToSplit(wid.man.wm.getFrame(wid.man.wm.dragging).self.dragging.child, insert.window, .left),
                        .split_right => wid.man.wm.moveFrameToSplit(wid.man.wm.getFrame(wid.man.wm.dragging).self.dragging.child, insert.window, .right),
                        .tab_left => wid.man.wm.moveFrameToTab(wid.man.wm.getFrame(wid.man.wm.dragging).self.dragging.child, insert.window, .left),
                        .tab_right => wid.man.wm.moveFrameToTab(wid.man.wm.getFrame(wid.man.wm.dragging).self.dragging.child, insert.window, .right),
                    }
                }
            }
            return .pointer;
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
            if (ev.action == .up and !(b2.persistent.beui1.isKeyHeld(.left_shift) or b2.persistent.beui1.isKeyHeld(.right_shift))) {
                wid.man.wm.dropFrameToNewWindow();
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
pub fn drawFloatingContainer(ctx: RenderWindowCtx, frame: WM.WM.FrameID, rdl: *B2.RepositionableDrawList, top: ?TopInfo, win_position_in: @Vector(2, f32), win_size_in: @Vector(2, f32)) void {
    const man = ctx.man;
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
    drawWindowNode(ctx, rdl, if (top) |t| .{
        .rdl = t.rdl,
        .pos = win_pos,
        .size = win_size,
        .skip = .none,
    } else null, wm.getFrame(frame).self.window.child, win_pos, win_size, .{ .parent_is_tabs = false });

    // add the black rectangle
    rdl.addRect(.{
        .pos = whole_pos,
        .size = whole_size,
        .tint = colors.window_border,
        .rounding = .{ .corners = .all, .radius = border_width * 2 },
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

pub const RenderWindowCtx = struct {
    b2: *B2.Beui2,
    cb: WM.Manager.RenderBlockCB,
    man: *WM.Manager,
};
pub fn renderWindows(ctx: RenderWindowCtx, size: @Vector(2, f32)) *B2.RepositionableDrawList {
    const rdl = ctx.b2.draw();
    _ = size;

    const incl_top = ctx.man.wm.dragging != WM.WM.FrameID.not_set;

    if (ctx.man.wm.dragging != WM.WM.FrameID.not_set) {
        const start_ms: f64 = @floatFromInt(ctx.man.dragging.anim_start_ms);
        const now_ms: f64 = @floatFromInt(ctx.b2.persistent.beui1.frame.frame_cfg.?.now_ms);
        const diff: f32 = @floatCast(now_ms - start_ms);
        const diff_scaled: f32 = @max(@min(diff / 200.0, 1.0), 0.0); // 200ms anim
        const diff_functioned: f32 = easeInOutQuint(diff_scaled);
        const rescaled = step(@Vector(2, f32), ctx.man.dragging.anim_start, ctx.man.dragging.pos, @splat(diff_functioned));
        drawWindowDragging(ctx, rdl, ctx.man.wm.dragging, rescaled, .{ 300, 300 });
    }

    // loop in reverse because [0] = backmost, [len - 1] = frontmost
    var i: usize = ctx.man.wm.top_level_windows.items.len;
    while (i > 0) {
        i -= 1;
        const win = ctx.man.wm.top_level_windows.items[i];
        const win_info = ctx.man.getWindowInfo(win);
        const top_rdl = ctx.b2.draw();
        rdl.place(top_rdl, .{});
        drawFloatingContainer(ctx, win, rdl, if (incl_top) .{
            .rdl = top_rdl,
            .pos = win_info.pos,
            .size = win_info.size,
            .skip = .none,
        } else null, win_info.pos, win_info.size);
    }

    return rdl;
}

const TopInfo = struct {
    rdl: *B2.RepositionableDrawList,
    pos: @Vector(2, f32),
    size: @Vector(2, f32),
    skip: B2.Sides,

    fn within(self: TopInfo, pos: @Vector(2, f32), size: @Vector(2, f32), skip: B2.Sides) TopInfo {
        const out_pos: @Vector(2, f32) = @max(self.pos, pos);
        return .{
            .rdl = self.rdl,
            .pos = out_pos,
            .size = @min(pos + size, self.pos + self.size) - out_pos,
            .skip = skip,
        };
    }
};
