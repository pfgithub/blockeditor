const std = @import("std");

const Beui = @import("Beui.zig");
const render_list = @import("render_list.zig");
const tracy = @import("anywhere").tracy;
const util = @import("util.zig");

fn IdMap(comptime V: type) type {
    const IDContext = struct {
        pub fn hash(_: @This(), id: ID) u64 {
            return id.hash();
        }
        pub fn eql(_: @This(), a: ID, b: ID) bool {
            return a.eql(b);
        }
    };
    return std.HashMap(ID, V, IDContext, std.hash_map.default_max_load_percentage);
}

const Beui2FrameCfg = struct {};
const Beui2Frame = struct { arena: std.mem.Allocator, frame_cfg: Beui2FrameCfg, scroll_target: ?ScrollTarget };
const ScrollTarget = struct {
    id: ID,
    scroll: @Vector(2, f32),
};
const Beui2Persistent = struct {
    gpa: std.mem.Allocator,

    arenas: [2]std.heap.ArenaAllocator,
    current_arena: u1 = 0,

    id_scopes: std.ArrayList(IDSegment),
    draw_lists: std.ArrayList(*RepositionableDrawList),
    last_frame_mouse_events: std.ArrayList(MouseEventEntry),
    prev_frame_mouse_event_to_offset: IdMap(@Vector(2, i32)),
    this_frame_ids: IdMap(void),
    click_target: ?ID = null,

    frame_num: u64 = 0,
};
pub const Beui2 = struct {
    frame: Beui2Frame,
    persistent: Beui2Persistent,

    pub fn init(self: *Beui2, gpa: std.mem.Allocator) void {
        self.* = .{
            .frame = undefined,
            .persistent = .{
                .gpa = gpa,
                .arenas = .{ .init(gpa), .init(gpa) },
                .id_scopes = .init(gpa),
                .draw_lists = .init(gpa),
                .last_frame_mouse_events = .init(gpa),
                .prev_frame_mouse_event_to_offset = .init(gpa),
                .this_frame_ids = .init(gpa),
            },
        };
    }
    pub fn deinit(self: *Beui2) void {
        self.persistent.this_frame_ids.deinit();
        self.persistent.prev_frame_mouse_event_to_offset.deinit();
        self.persistent.last_frame_mouse_events.deinit();
        for (&self.persistent.arenas) |*a| a.deinit();
        self.persistent.id_scopes.deinit();
        self.persistent.draw_lists.deinit();
    }

    pub fn newFrame(self: *Beui2, beui: *Beui, frame_cfg: Beui2FrameCfg) ID {
        // handle events
        // - scroll: if there is a scroll event, hit test to find which handler it touched
        const mousepos_int: @Vector(2, i32) = @intFromFloat(beui.persistent.mouse_pos);
        var scroll_target: ?ScrollTarget = null;
        if (@reduce(.Or, @abs(beui.frame.scroll_px) > @as(@Vector(2, f32), @splat(0.0)))) {
            for (self.persistent.last_frame_mouse_events.items) |item| {
                if (item.cfg.capture_scroll.x or item.cfg.capture_scroll.y) {
                    if (item.coversPoint(mousepos_int)) {
                        // found. its id is still valid for one more frame.
                        scroll_target = .{ .id = item.id, .scroll = beui.frame.scroll_px };
                        break;
                    }
                }
            }
        }
        // - mouse: store offsets
        self.persistent.prev_frame_mouse_event_to_offset.clearRetainingCapacity();
        for (self.persistent.last_frame_mouse_events.items) |item| {
            if (item.cfg.capture_click) {
                self.persistent.prev_frame_mouse_event_to_offset.putNoClobber(item.id, item.pos) catch @panic("oom");
            }
        }
        // - mouse: store focus
        if (beui.isKeyPressed(.mouse_left)) {
            self.persistent.click_target = null;
            // find click target
            for (self.persistent.last_frame_mouse_events.items) |item| {
                if (item.cfg.capture_click) {
                    if (item.coversPoint(mousepos_int)) {
                        // found.
                        self.persistent.click_target = item.id;
                    }
                }
            }
        } else if (beui.isKeyHeld(.mouse_left)) {
            // refresh click target to keep its id valid
            if (self.persistent.click_target) |*target| {
                target.* = target.refresh();
            }
        } else {
            // remove click target, not clicking.
            self.persistent.click_target = null;
        }

        for (self.persistent.draw_lists.items) |pdl| if (!pdl.placed) @panic("not all draw lists were placed last frame.");
        self.persistent.draw_lists.clearRetainingCapacity();
        if (self.persistent.id_scopes.items.len != 0) @panic("not all scopes were popped last frame. maybe missing popScope()?");
        self.persistent.last_frame_mouse_events.clearRetainingCapacity();

        self.persistent.this_frame_ids.clearRetainingCapacity();
        self.persistent.current_arena +%= 1;
        const next_arena = &self.persistent.arenas[self.persistent.current_arena];
        _ = next_arena.reset(.retain_capacity);
        self.persistent.frame_num += 1;
        self.frame = .{
            .arena = next_arena.allocator(),
            .frame_cfg = frame_cfg,
            .scroll_target = scroll_target,
        };

        return .{
            .b2 = self,
            .frame = self.persistent.frame_num,
            .str = &.{},
        };
    }
    pub fn endFrame(self: *Beui2, child: StandardChild, renderlist: ?*render_list.RenderList) void {
        child.rdl.placed = true;
        child.rdl.finalize(renderlist, &self.persistent.last_frame_mouse_events, .{ 0, 0 });
    }

    pub fn draw(self: *Beui2) *RepositionableDrawList {
        const res = self.frame.arena.create(RepositionableDrawList) catch @panic("oom");
        res.* = .{ .b2 = self, .content = .init(self.frame.arena) }; // not the best to use an arena for an arraylist
        self.persistent.draw_lists.append(res) catch @panic("oom");
        return res;
    }

    pub fn mouseCaptureResults(self: *Beui2, capture_id: ID) MouseCaptureResults {
        var mouse_left_held = false;
        if (self.persistent.click_target) |ct| {
            if (ct.eql(capture_id)) {
                mouse_left_held = true;
            }
        }
        return .{ .mouse_left_held = mouse_left_held };
    }
    pub fn scrollCaptureResults(self: *Beui2, capture_id: ID) @Vector(2, f32) {
        if (self.frame.scroll_target) |st| {
            if (st.id.eql(capture_id)) {
                return st.scroll;
            }
        }
        return .{ 0, 0 };
    }
    pub fn state(self: *Beui2, self_id: ID, comptime StateType: type) StateResult(StateType) {
        _ = self_id;
        const cht = self.frame.arena.create(StateType) catch @panic("oom");
        return .{ .initialized = false, .value = cht };
    }
    fn StateResult(comptime StateType: type) type {
        return struct { initialized: bool, value: *StateType };
    }

    // if we need to pass context, it's fine as long as it's arena allocated. because deinit fn will be called
    // update is called every frame the context is alive <- maybe don't do this. if we need to store IDs, we can clone them and deinit them.
    // state will be deleted if the id is not around for one frame.
    // - to preserve state, call beui2.preserveStateTree(root_id). only call this if you're not going to render the item.
    //   ie: {const showhide_state = .sub(@src()); if(show) {renderItem(showhide_state)} else {preserveStateTree(showhide_state)}
    pub fn state2(self: *Beui2, self_id: ID, comptime StateType: type, comptime initFn: fn () StateType, comptime deinitFn: fn (child: StateType) void) StateType {
        _ = self;
        _ = self_id;
        _ = deinitFn;
        return initFn();
    }

    pub fn fmt(self: *Beui2, comptime format: []const u8, args: anytype) []u8 {
        return std.fmt.allocPrint(self.frame.arena, format, args) catch @panic("oom");
    }
};

pub const MouseCaptureResults = struct {
    mouse_left_held: bool,
};

const IDSegment = struct {
    const IDSegmentSize = 8 * 3;
    comptime {
        std.debug.assert(std.meta.hasUniqueRepresentation(IDSegment));
    }
    value: [IDSegmentSize]u8,
    tag: Tag,
    const Tag = enum { src, loop, loop_child };
    const SrcStruct = struct {
        filename: [*:0]const u8,
        fn_name: [*:0]const u8,
        line: u32,
        col: u32,
    };
    const LoopStruct = struct {
        child_t: [*:0]const u8,
    };

    pub fn fromSrc(src: std.builtin.SourceLocation) IDSegment {
        return .fromTagValue(.src, SrcStruct, .{ .filename = src.file.ptr, .fn_name = src.fn_name.ptr, .line = src.line, .col = src.column });
    }
    fn fromTagValue(tag: Tag, comptime VT: type, value: VT) IDSegment {
        comptime std.debug.assert(@sizeOf(VT) <= IDSegmentSize);
        comptime std.debug.assert(std.meta.hasUniqueRepresentation(VT));
        return .fromTagSlice(tag, std.mem.asBytes(&value));
    }
    fn fromTagSlice(tag: Tag, value_slice: []const u8) IDSegment {
        std.debug.assert(value_slice.len <= IDSegmentSize);
        var result = std.mem.zeroes([IDSegmentSize]u8);
        @memcpy(result[0..value_slice.len], value_slice);
        return .{ .value = result, .tag = tag };
    }
    pub fn readAsType(self: *const IDSegment, comptime VT: type) *align(1) const VT {
        comptime std.debug.assert(@sizeOf(VT) <= IDSegmentSize);
        comptime std.debug.assert(std.meta.hasUniqueRepresentation(VT));
        return std.mem.bytesAsValue(VT, self.value[0..@sizeOf(VT)]);
    }

    fn eql(self: IDSegment, other: IDSegment) bool {
        return std.mem.eql(u8, std.mem.asBytes(&self), std.mem.asBytes(&other));
    }
};
const ID = struct {
    b2: *Beui2,
    frame: u64,
    /// DO NOT READ POINTER WITHOUT CALLING .assertValid() FIRST.
    str: []const IDSegment,

    // duplicate id safety is slow :/
    const duplicate_id_safety = std.debug.runtime_safety;

    pub fn assertValid(self: ID) void {
        std.debug.assert(self.frame == self.b2.persistent.frame_num or self.frame + 1 == self.b2.persistent.frame_num);
    }
    pub fn hash(self: ID) u64 {
        self.assertValid();
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.sliceAsBytes(self.str));
        return hasher.final();
    }
    pub fn eql(self: ID, other: ID) bool {
        self.assertValid();
        other.assertValid();
        if (self.str.len != other.str.len) return false;
        if (self.str.ptr == other.str.ptr) return true;
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(self.str), std.mem.sliceAsBytes(other.str))) return false;
        return true;
    }
    pub fn refresh(self: ID) ID {
        self.assertValid();
        const self_cp = self.b2.frame.arena.dupe(IDSegment, self.str) catch @panic("oom");
        return .{ .b2 = self.b2, .frame = self.b2.persistent.frame_num, .str = self_cp };
    }

    fn _addInternal(self: ID, items: []const IDSegment) ID {
        self.assertValid();
        const self_cp = self.b2.frame.arena.alloc(IDSegment, self.str.len + items.len) catch @panic("oom");
        @memcpy(self_cp[0..self.str.len], self.str);
        @memcpy(self_cp[self.str.len..], items);
        const result: ID = .{ .b2 = self.b2, .frame = self.b2.persistent.frame_num, .str = self_cp };
        if (duplicate_id_safety) {
            self.b2.persistent.this_frame_ids.putNoClobber(result, {}) catch @panic("oom"); // if this fails then there is a duplicate id
        }
        return result;
    }

    pub fn pushLoop(self: ID, src: std.builtin.SourceLocation, comptime ChildT: type) ID {
        comptime {
            if (@sizeOf(ChildT) > IDSegment.IDSegmentSize) @compileError("loop ChildT size > max size");
            if (!std.meta.hasUniqueRepresentation(ChildT)) @compileError("loop ChildT must have unique representation");
        }
        return self._pushLoopTypeName(src, @typeName(ChildT));
    }
    fn _pushLoopTypeName(self: ID, src: std.builtin.SourceLocation, child_t: [*:0]const u8) ID {
        return self._addInternal(&.{ .fromSrc(src), .fromTagValue(.loop, IDSegment.LoopStruct, .{ .child_t = child_t }) });
    }
    pub fn pushLoopValue(self: ID, src: std.builtin.SourceLocation, child_t: anytype) ID {
        return self._pushLoopValueSlice(src, @typeName(@TypeOf(child_t)), std.mem.asBytes(&child_t));
    }
    fn _pushLoopValueSlice(self: ID, src: std.builtin.SourceLocation, child_t: [*:0]const u8, child_v: []const u8) ID {
        self.assertValid();
        if (self.str.len == 0) @panic("pushLoopValue called without pushLoop");
        const last = self.str[self.str.len - 1];
        if (last.tag != .loop) @panic("pushLoopValue called but last push was not pushLoop");
        const last_loop = last.readAsType(IDSegment.LoopStruct);
        if (last_loop.child_t != child_t) @panic("pushLoopValue called with different type than from pushLoop");
        std.debug.assert(child_v.len <= IDSegment.IDSegmentSize);
        return self._addInternal(&.{ .fromSrc(src), .fromTagSlice(.loop_child, child_v) });
    }

    pub fn sub(self: ID, src: std.builtin.SourceLocation) ID {
        return self._addInternal(&.{.fromSrc(src)});
    }
};

const MouseEventEntry = struct {
    id: ID,
    pos: @Vector(2, i32),
    size: @Vector(2, i32),
    cfg: MouseEventCaptureConfig,

    pub fn coversPoint(self: MouseEventEntry, point: @Vector(2, i32)) bool {
        return @reduce(.And, point >= self.pos) and @reduce(.And, point < self.pos + self.size);
    }
};
const MouseEventCaptureConfig = struct {
    capture_click: bool = false,
    capture_scroll: struct { x: bool = false, y: bool = false } = .{},
};
const RepositionableDrawList = struct {
    const RepositionableDrawChild = union(enum) {
        geometry: struct {
            vertices: []const render_list.RenderListVertex,
            indices: []const u16,
            image: ?render_list.RenderListImage,
        },
        mouse: struct {
            pos: @Vector(2, i32),
            size: @Vector(2, i32),
            id: ID,
            cfg: MouseEventCaptureConfig,
        },
        embed: struct {
            child: *RepositionableDrawList,
            offset: @Vector(2, i32),
        },
    };
    b2: *Beui2,
    content: std.ArrayList(RepositionableDrawChild),
    placed: bool = false,
    pub fn place(self: *RepositionableDrawList, child: *RepositionableDrawList, offset_pos: @Vector(2, i32)) void {
        std.debug.assert(!child.placed);
        self.content.append(.{ .embed = .{ .child = child, .offset = offset_pos } }) catch @panic("oom");
        child.placed = true;
    }
    pub fn addVertices(self: *RepositionableDrawList, image: ?render_list.RenderListImage, vertices: []const render_list.RenderListVertex, indices: []const render_list.RenderListIndex) void {
        self.content.append(.{
            .geometry = .{
                .vertices = self.b2.frame.arena.dupe(render_list.RenderListVertex, vertices) catch @panic("oom"),
                .indices = self.b2.frame.arena.dupe(render_list.RenderListIndex, indices) catch @panic("oom"),
                .image = image,
            },
        }) catch @panic("oom");
    }
    pub fn addRect(self: *RepositionableDrawList, opts_in: struct {
        pos: @Vector(2, f32),
        size: @Vector(2, f32),
        uv_pos: @Vector(2, f32) = .{ -1.0, -1.0 },
        uv_size: @Vector(2, f32) = .{ 0, 0 },
        image: ?render_list.RenderListImage = null,
        tint: Beui.Color = .fromHexRgb(0xFFFFFF),
    }) void {
        var opts = opts_in;
        if (opts.image == null) {
            opts.uv_pos = .{ -1.0, -1.0 };
            opts.uv_size = .{ 0, 0 };
        }
        const pos = opts.pos;
        const size = opts.size;

        const ul = pos;
        const ur = pos + @Vector(2, f32){ size[0], 0 };
        const bl = pos + @Vector(2, f32){ 0, size[1] };
        const br = pos + size;

        const uv_ul = opts.uv_pos;
        const uv_ur = opts.uv_pos + @Vector(2, f32){ opts.uv_size[0], 0 };
        const uv_bl = opts.uv_pos + @Vector(2, f32){ 0, opts.uv_size[1] };
        const uv_br = opts.uv_pos + opts.uv_size;

        self.addVertices(opts.image, &.{
            .{ .pos = ul, .uv = uv_ul, .tint = opts.tint.value },
            .{ .pos = ur, .uv = uv_ur, .tint = opts.tint.value },
            .{ .pos = bl, .uv = uv_bl, .tint = opts.tint.value },
            .{ .pos = br, .uv = uv_br, .tint = opts.tint.value },
        }, &.{
            // have to go clockwise to not get culled
            0, 1, 3,
            0, 3, 2,
        });
    }
    pub fn addChar(self: *RepositionableDrawList, char: u8, pos: @Vector(2, f32), color: Beui.Color) void {
        const conv: @Vector(2, u4) = @bitCast(char);
        const tile_id: @Vector(2, f32) = .{ @floatFromInt(conv[0]), @floatFromInt(conv[1]) };
        const tile_pos: @Vector(2, f32) = tile_id * @Vector(2, f32){ 6, 10 } + @Vector(2, f32){ 1, 1 };
        const tile_size: @Vector(2, f32) = .{ 5, 9 };
        const font_size: @Vector(2, f32) = .{ 256, 256 };
        const tile_uv_pos = tile_pos / font_size;
        const tile_uv_size = tile_size / font_size;
        self.addRect(.{
            .pos = pos,
            .size = tile_size,
            .uv_pos = tile_uv_pos,
            .uv_size = tile_uv_size,
            .image = .beui_font,
            .tint = color,
        });
    }
    pub fn addMouseEventCapture(self: *RepositionableDrawList, id: ID, pos: @Vector(2, i32), size: @Vector(2, i32), cfg: MouseEventCaptureConfig) void {
        self.content.append(.{ .mouse = .{ .pos = pos, .size = size, .id = id, .cfg = cfg } }) catch @panic("oom");
    }

    fn finalize(self: *RepositionableDrawList, out_list: ?*render_list.RenderList, out_events: ?*std.ArrayList(MouseEventEntry), offset_pos: @Vector(2, i32)) void {
        for (self.content.items) |item| {
            switch (item) {
                .geometry => |geo| {
                    if (out_list) |v| v.addVertices(geo.image, geo.vertices, geo.indices, @floatFromInt(offset_pos));
                },
                .mouse => |mev| {
                    if (out_events) |v| v.append(.{
                        .id = mev.id,
                        .pos = mev.pos + offset_pos,
                        .size = mev.size,
                        .cfg = mev.cfg,
                    }) catch @panic("oom");
                },
                .embed => |eev| {
                    eev.child.finalize(out_list, out_events, offset_pos + eev.offset);
                },
            }
        }
    }
};

// fn harfbuzzText(call_info: StandardCallInfo, text: []const u8, color: Beui.Color) StandardChild {
//     const ui = call_info.ui(@src());

//     const draw = ui.id.b2.draw();
// }

fn textOnly(
    call_info: StandardCallInfo,
    text: []const u8,
    color: Beui.Color,
) StandardChild {
    const ui = call_info.ui(@src());
    const b2 = ui.id.b2;

    const draw = b2.draw();

    var char_pos: @Vector(2, f32) = .{ 0, 0 };
    for (text) |char| {
        draw.addChar(char, char_pos, color);
        char_pos += .{ 6, 0 };
    }

    return .{
        .size = .{ @intFromFloat(char_pos[0]), 10 },
        .rdl = draw,
    };
}

const ListIndex = struct {
    comptime {
        std.debug.assert(std.meta.hasUniqueRepresentation(ListIndex));
    }
    i: usize,
    pub fn first(_: usize) ListIndex {
        return .{ .i = 0 };
    }
    pub fn update(itm: ListIndex, len: usize) ?ListIndex {
        if (itm.i >= len) return if (len == 0) null else .{ .i = len - 1 };
        return .{ .i = itm.i };
    }
    pub fn prev(itm: ListIndex, _: usize) ?ListIndex {
        if (itm.i == 0) return null;
        return .{ .i = itm.i - 1 };
    }
    pub fn next(itm: ListIndex, len: usize) ?ListIndex {
        if (itm.i == len - 1) return null;
        return .{ .i = itm.i + 1 };
    }
};

const StandardConstraints = struct {

    // so for each axis, we have:
    // target width, max available width
    // if target width is 0, that means to use intrinsic width

    // rendering a button:
    // - the child will be measured given the same constraints, minus any
    //   padding for the target width
    // - then, if the child width is less than the target width, the button
    //   will expand to fill the target width and center the child
    // but will the child width ever be less than the target width? won't
    // every child try to fill its target space?

    // so the item will be as small as possible
    // if you want it bigger, you'll need to add some kind of expander
    // ie for a button:
    // Button( BG(.blue, HLayout( Text("hello", .white), 1fr ) ) )
    // HLayout in that case uses all available space because of the '1fr'

    available_size: struct { w: ?i32, h: ?i32 },
};
const StandardChild = struct {
    size: @Vector(2, i32),
    rdl: *RepositionableDrawList,
};

const StandardCallInfo = struct {
    caller_id: ID,
    constraints: StandardConstraints,
    fn ui(self: StandardCallInfo, src: std.builtin.SourceLocation) StandardUI {
        return .{ .id = self.caller_id.sub(src), .constraints = self.constraints };
    }
};
const StandardUI = struct {
    id: ID,
    constraints: StandardConstraints,
    fn sub(self: StandardUI, src: std.builtin.SourceLocation) StandardCallInfo {
        return .{ .caller_id = self.id.sub(src), .constraints = self.constraints };
    }
};
fn Component(comptime Arg1: type, comptime Arg2: type, comptime Ret: type) type {
    return struct {
        ctx: *anyopaque,
        fn_ptr: *const fn (ctx: *anyopaque, arg1: Arg1, arg2: Arg2) Ret,
        fn from(ctx_0: anytype, comptime fn_val: fn (ctx: @TypeOf(ctx_0), arg1: Arg1, arg2: Arg2) Ret) @This() {
            return .{
                .ctx = @ptrCast(@constCast(ctx_0)),
                .fn_ptr = struct {
                    fn fn_ptr(ctx_1: *const anyopaque, arg1: Arg1, arg2: Arg2) Ret {
                        return fn_val(@ptrCast(@alignCast(@constCast(ctx_1))), arg1, arg2);
                    }
                }.fn_ptr,
            };
        }
        fn call(self: @This(), arg1: Arg1, arg2: Arg2) Ret {
            return self.fn_ptr(self.ctx, arg1, arg2);
        }
    };
}
pub const Button_Itkn = struct {
    id: ID,
    pub fn init(caller_id: ID) Button_Itkn {
        return .{ .id = caller_id.sub(@src()) };
    }

    pub fn active(self: Button_Itkn) bool {
        return self.id.b2.mouseCaptureResults(self.id).mouse_left_held;
    }
};
fn defaultTextButton(call_info: StandardCallInfo, msg: []const u8, itkn_in: ?Button_Itkn) StandardChild {
    const ui = call_info.ui(@src());
    return button(ui.sub(@src()), itkn_in, .from(&msg, defaultTextButton_1));
}
fn defaultTextButton_1(msg: *const []const u8, caller_id: StandardCallInfo, itkn: Button_Itkn) StandardChild {
    const ui = caller_id.ui(@src());
    const color: Beui.Color = if (itkn.active()) .fromHexRgb(0x0000FF) else .fromHexRgb(0x000099);
    return setBackground(ui.sub(@src()), color, .from(msg, defaultTextButton_2));
}
fn defaultTextButton_2(msg: *const []const u8, caller_id: StandardCallInfo, _: void) StandardChild {
    const ui = caller_id.ui(@src());
    return textOnly(ui.sub(@src()), msg.*, .fromHexRgb(0xFFFF00));
}

fn button(call_info: StandardCallInfo, itkn_in: ?Button_Itkn, child_component: Component(StandardCallInfo, Button_Itkn, StandardChild)) StandardChild {
    const ui = call_info.ui(@src());
    const itkn = itkn_in orelse Button_Itkn.init(ui.id.sub(@src()));
    const child = child_component.call(ui.sub(@src()), itkn);
    const draw = ui.id.b2.draw();
    draw.place(child.rdl, .{ 0, 0 });
    draw.addMouseEventCapture(itkn.id, .{ 0, 0 }, child.size, .{ .capture_click = true });
    return .{ .size = child.size, .rdl = draw };
}
fn setBackground(call_info: StandardCallInfo, color: Beui.Color, child_component: Component(StandardCallInfo, void, StandardChild)) StandardChild {
    const ui = call_info.ui(@src());
    const child = child_component.call(ui.sub(@src()), {});

    const draw = ui.id.b2.draw();
    draw.place(child.rdl, .{ 0, 0 });
    draw.addRect(.{ .pos = .{ 0, 0 }, .size = @floatFromInt(child.size), .tint = color });
    return .{ .size = child.size, .rdl = draw };
}
const ScrollState = struct {
    offset: f32,
    anchor: [IDSegment.IDSegmentSize]u8,
};
fn indexToBytes(index: anytype) [IDSegment.IDSegmentSize]u8 {
    return util.anyToAny([IDSegment.IDSegmentSize]u8, @TypeOf(index), index);
}
fn bytesToIndex(bytes: *const [IDSegment.IDSegmentSize]u8, comptime T: type) T {
    return std.mem.bytesAsValue(T, bytes[0..@sizeOf(T)]).*;
}

var _scroll_state: ?ScrollState = null;

fn virtualScroller(call_info: StandardCallInfo, context: anytype, comptime Index: type, child_component: Component(StandardCallInfo, Index, StandardChild)) StandardChild {
    const ui = call_info.ui(@src());
    if (ui.constraints.available_size.w == null or ui.constraints.available_size.h == null) @panic("scroller2 requires known available size");

    var rdl = ui.id.b2.draw();
    const height = ui.constraints.available_size.h.?;

    const scroll_ev_capture_id = ui.id.sub(@src());
    const scroll_by = ui.id.b2.scrollCaptureResults(scroll_ev_capture_id);

    const scroll_state = if (true) blk: {
        if (_scroll_state == null) _scroll_state = .{ .offset = 0, .anchor = indexToBytes(Index.first(context)) };
        break :blk &_scroll_state.?;
    } else blk: {
        const scroll_state = ui.id.b2.state(ui.id.sub(@src()), ScrollState);
        if (!scroll_state.initialized) scroll_state.value.* = .{ .offset = 0, .anchor = indexToBytes(Index.first(context)) };
        break :blk scroll_state.value;
    };

    scroll_state.offset += scroll_by[1];

    var cursor: i32 = @intFromFloat(scroll_state.offset);

    const idx_initial = bytesToIndex(&scroll_state.anchor, Index);
    var idx = idx_initial.update(context);
    if (idx) |val| scroll_state.anchor = indexToBytes(val);

    const loop_index = ui.id.pushLoop(@src(), Index);
    if (cursor > 0 and idx != null) {
        // seek backwards
        var backwards_cursor = cursor;
        var backwards_index = idx.?;
        while (backwards_cursor > 0) {
            backwards_index = backwards_index.prev(context) orelse break;

            const child = child_component.call(.{ .caller_id = loop_index.pushLoopValue(@src(), backwards_index), .constraints = .{
                .available_size = .{ .w = ui.constraints.available_size.w.?, .h = null },
            } }, backwards_index);

            backwards_cursor -= child.size[1];
            scroll_state.anchor = indexToBytes(backwards_index);
            scroll_state.offset -= @floatFromInt(child.size[1]);
            rdl.place(child.rdl, .{ 0, backwards_cursor });
        }
    }
    while (idx != null) {
        if (cursor > height) break;

        const child = child_component.call(.{ .caller_id = loop_index.pushLoopValue(@src(), idx.?), .constraints = .{
            .available_size = .{ .w = ui.constraints.available_size.w.?, .h = null },
        } }, idx.?);

        if (cursor < 0) blk: {
            scroll_state.anchor = indexToBytes(idx.?.next(context) orelse break :blk);
            scroll_state.offset += @floatFromInt(child.size[1]);
        }
        rdl.place(child.rdl, .{ 0, cursor });
        cursor += child.size[1];

        idx = idx.?.next(context);
    }

    rdl.addMouseEventCapture(
        scroll_ev_capture_id,
        .{ 0, 0 },
        .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? },
        .{ .capture_scroll = .{ .y = true } },
    );

    return .{ .size = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? }, .rdl = rdl };
}

pub fn scrollDemo(call_info: StandardCallInfo) StandardChild {
    const ui = call_info.ui(@src());

    const my_list: []const []const []const u8 = &[_][]const []const u8{
        &[_][]const u8{ "flying", "searing", "lesser", "greater", "weak", "durable", "enchanted", "magic" },
        &[_][]const u8{ "apple", "banana", "cherry", "durian", "etobicoke", "fig", "grape" },
        &[_][]const u8{ "goblin", "blaster", "cannon", "cook", "castle" },
    };
    var my_list_len: usize = 1;
    for (my_list) |item| {
        my_list_len *= item.len;
    }

    return virtualScroller(ui.sub(@src()), my_list_len, ListIndex, .from(&my_list, scrollDemo_0_3));
}
fn scrollDemo_0_3(my_list: *const []const []const []const u8, caller_id: StandardCallInfo, index: ListIndex) StandardChild {
    const ui = caller_id.ui(@src());

    var res_str: []const u8 = "";

    var list_len: usize = 1;
    for (my_list.*) |m| list_len *= m.len;

    var i = permute(list_len, index.i);
    for (my_list.*, 0..) |items, j| {
        const sub_i = i % items.len;
        res_str = ui.id.b2.fmt("{s}{s}{s}", .{ res_str, if (j == 0) "" else " ", items[sub_i] });
        i = @divFloor(i, items.len);
    }

    return defaultTextButton(ui.sub(@src()), res_str, null);
}

fn permute(len: usize, index: usize) usize {
    const a = 6364136223846793005;
    const b = 1442695040888963407;
    comptime std.debug.assert(std.math.gcd(a, b) == 1);

    return @intCast((a * @as(u128, index) + b) % len);
}

// so for a button:
// - we want to render the button as small as possible in the

// and then here's the question: do we want to allow interaction tokens above the button itself
// like var itkn = Button.InteractionToken.init(b2.id(@src()));
// then Button.begin(itkn)
// that way we can see if the button is clicked before even calling .begin()
// - do we care?
//   - a component wrapping Button() needs to see if the button is clicked so it can return
//     the clicked state. so yes we care :/

// for rendering a button, we would like to support:
// oh eew

// you know a hack? Button(.begin(b2.callerID(@src()))), null, constraints, child);

// btn: {
//     const btn = Button.begin(b2.callerID(@src()), null, constraints);
//     break :btn btn.end( bg: {
//         const bg = BG.begin(b2.callerID(@src()), .fromHexRgb(0x0000FF));
//         break :bg bg.end(Text( b2.callerID(@src()), btn.constraints, "hello", .fromHexRgb(0xFFFF00) ))
//     } );
// }
// might as well put id in there too. BG.begin(btn.id.sub(@src())), bg.end(Text(bg.id.sub(@src())))
// we need stack capturing macro so badly

// if(Button.begin( b2.callerID(@src()) )) |btn| {
//     btn.end( Text("hello world") );
// }

// so a problem is. yeah that if. eew.
// we would like to say Button(Text("hello"))
// but what needs to happen is pushButton() Text() popButton()
// stack-capturing macros are the solution :/ but they're dead
