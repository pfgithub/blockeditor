const std = @import("std");

const Beui = @import("Beui.zig");
const render_list = @import("render_list.zig");

fn IdMap(comptime V: type) type {
    const IDContext = struct {
        b2: *Beui2,
        pub fn hash(self: @This(), id: ID) u64 {
            id.assertValid(self.b2);
            var hasher = std.hash.Wyhash.init(0);
            for (id.str) |seg| std.hash.autoHash(&hasher, seg);
            return hasher.final();
        }
        pub fn eql(self: @This(), a: ID, b: ID) bool {
            return a.eql(self.b2, b);
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
                .prev_frame_mouse_event_to_offset = undefined,
            },
        };
        self.persistent.prev_frame_mouse_event_to_offset = .initContext(gpa, .{ .b2 = self });
    }
    pub fn deinit(self: *Beui2) void {
        self.persistent.prev_frame_mouse_event_to_offset.deinit();
        self.persistent.last_frame_mouse_events.deinit();
        for (&self.persistent.arenas) |*a| a.deinit();
        self.persistent.id_scopes.deinit();
        self.persistent.draw_lists.deinit();
    }

    pub fn newFrame(self: *Beui2, beui: *Beui, frame_cfg: Beui2FrameCfg) void {
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
                target.* = target.refresh(self);
            }
        } else {
            // remove click target, not clicking.
            self.persistent.click_target = null;
        }

        for (self.persistent.draw_lists.items) |pdl| if (!pdl.placed) @panic("not all draw lists were placed last frame.");
        self.persistent.draw_lists.clearRetainingCapacity();
        if (self.persistent.id_scopes.items.len != 0) @panic("not all scopes were popped last frame. maybe missing popScope()?");
        self.persistent.last_frame_mouse_events.clearRetainingCapacity();

        self.persistent.current_arena +%= 1;
        const next_arena = &self.persistent.arenas[self.persistent.current_arena];
        _ = next_arena.reset(.retain_capacity);
        self.persistent.frame_num += 1;
        self.frame = .{
            .arena = next_arena.allocator(),
            .frame_cfg = frame_cfg,
            .scroll_target = scroll_target,
        };
    }
    pub fn endFrame(self: *Beui2, draw_list: *RepositionableDrawList, rdl: ?*render_list.RenderList) void {
        draw_list.placed = true;
        draw_list.finalize(rdl, &self.persistent.last_frame_mouse_events, .{ 0, 0 });
    }

    pub fn draw(self: *Beui2) *RepositionableDrawList {
        const res = self.frame.arena.create(RepositionableDrawList) catch @panic("oom");
        res.* = .{ .b2 = self, .content = .init(self.frame.arena) }; // not the best to use an arena for an arraylist
        self.persistent.draw_lists.append(res) catch @panic("oom");
        return res;
    }

    pub fn mouseCaptureResults(self: *Beui2, capture_id: ID) MouseCaptureResults {
        _ = self;
        _ = capture_id;
        return .{ .mouse_left_held = false };
    }
    pub fn scrollCaptureResults(self: *Beui2, capture_id: ID) @Vector(2, f32) {
        if (self.frame.scroll_target) |st| {
            if (st.id.eql(self, capture_id)) {
                return st.scroll;
            }
        }
        return .{ 0, 0 };
    }
    pub fn pushScope(self: *Beui2, caller_id: CallerID, src: std.builtin.SourceLocation) void {
        self.persistent.id_scopes.append(.fromSrc(caller_id.src)) catch @panic("oom");
        self.persistent.id_scopes.append(.fromSrc(src)) catch @panic("oom");
    }
    pub fn popScope(self: *Beui2) void {
        const p0 = self.persistent.id_scopes.popOrNull() orelse @panic("popScope() called without matching pushScope");
        std.debug.assert(p0 == .src);
        _ = self.persistent.id_scopes.popOrNull() orelse @panic("popScope() called without matching pushScope");
    }
    pub fn pushLoop(self: *Beui2, src: std.builtin.SourceLocation, comptime ChildT: type) void {
        if (@sizeOf(ChildT) > IDSegment.LoopChildSize) @compileError("loop ChildT size > max size");
        self._pushLoopTypeName(src, @typeName(ChildT));
    }
    pub fn popLoop(self: *Beui2) void {
        const p0 = self.persistent.id_scopes.popOrNull() orelse @panic("popLoop() called without matching pushLoop()");
        std.debug.assert(p0 == .loop);
        const p1 = self.persistent.id_scopes.popOrNull() orelse @panic("popLoop() called without matching pushLoop()");
        std.debug.assert(p1 == .src);
    }
    fn _pushLoopTypeName(self: *Beui2, src: std.builtin.SourceLocation, child: [*:0]const u8) void {
        self.persistent.id_scopes.append(.fromSrc(src)) catch @panic("oom");
        self.persistent.id_scopes.append(.{ .loop = .{ .child_t = child } }) catch @panic("oom");
    }
    pub fn pushLoopValue(self: *Beui2, src: std.builtin.SourceLocation, child_t: anytype) void {
        self._pushLoopValueSlice(src, @typeName(@TypeOf(child_t)), std.mem.asBytes(&child_t));
    }
    pub fn popLoopValue(self: *Beui2) void {
        const p0 = self.persistent.id_scopes.popOrNull() orelse @panic("popLoopValue() called without matching pushLoopValue()");
        std.debug.assert(p0 == .loop_child);
        const p1 = self.persistent.id_scopes.popOrNull() orelse @panic("popLoopValue() called without matching pushLoopValue()");
        std.debug.assert(p1 == .src);
    }
    fn _pushLoopValueSlice(self: *Beui2, src: std.builtin.SourceLocation, child_t: [*:0]const u8, child_v: []const u8) void {
        const last = self.persistent.id_scopes.getLastOrNull() orelse @panic("pushLoopValue called without pushLoop");
        if (last != .loop) @panic("pushLoopValue called but last push was not pushLoop");
        if (last.loop.child_t != child_t) @panic("pushLoopValue called with different type than set in pushLoop");
        std.debug.assert(child_v.len <= IDSegment.LoopChildSize);
        self.persistent.id_scopes.append(.fromSrc(src)) catch @panic("oom");
        const added = self.persistent.id_scopes.addOne() catch @panic("oom");
        added.* = .{ .loop_child = .{} };
        @memcpy(added.loop_child.value[0..child_v.len], child_v);
    }

    pub fn callerID(self: *Beui2, src: std.builtin.SourceLocation) CallerID {
        return .{ .b2 = self, .src = src };
    }
    pub fn id(self: *Beui2, src: std.builtin.SourceLocation) ID {
        const seg: IDSegment = .fromSrc(src);

        const result_buf = self.frame.arena.alloc(IDSegment, self.persistent.id_scopes.items.len + 1) catch @panic("oom");
        @memcpy(result_buf[0..self.persistent.id_scopes.items.len], self.persistent.id_scopes.items);
        result_buf[self.persistent.id_scopes.items.len] = seg;

        return .{ .frame = self.persistent.frame_num, .str = result_buf };
    }
    pub fn state(self: *Beui2, self_id: ID, comptime StateType: type) StateResult(StateType) {
        _ = self_id;
        const cht = self.frame.arena.create(StateType) catch @panic("oom");
        return .{ .initialized = false, .value = cht };
    }
    fn StateResult(comptime StateType: type) type {
        return struct { initialized: bool, value: *StateType };
    }

    pub fn fmt(self: *Beui2, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.frame.arena, format, args) catch @panic("oom");
    }
};

pub const MouseCaptureResults = struct {
    mouse_left_held: bool,
};

pub fn demo1(caller_id: CallerID, constraints: Constraints) *RepositionableDrawList {
    const b2 = caller_id.b2;
    b2.pushScope(caller_id, @src());
    defer b2.popScope();

    const result = b2.draw();

    result.place(scrollDemo(b2.callerID(@src()), constraints), .{ 0, 0 });

    return result;
}

fn demo0(caller_id: CallerID, b2: *Beui2) *RepositionableDrawList {
    b2.pushScope(caller_id, @src());
    defer b2.popScope();

    const result = b2.draw();

    const capture_id = b2.id(@src());

    const capture_results = b2.mouseCaptureResults(capture_id);

    const res_color: Beui.Color = switch (capture_results.mouse_left_held) {
        false => .fromHexRgb(0xFF0000),
        true => .fromHexRgb(0x00FF00),
    };

    result.addRect(.{
        .pos = .{ 10, 10 },
        .size = .{ 50, 50 },
        .tint = res_color,
    });

    result.addMouseEventCapture(capture_id, .{ 10, 10 }, .{ 50, 50 });

    return result;
}

const IDSegment = union(enum) {
    pub const LoopChildSize = 8 * 3;
    src: struct {
        filename: [*:0]const u8,
        fn_name: [*:0]const u8,
        line: u32,
        col: u32,
    },
    loop: struct {
        child_t: [*:0]const u8,
    },
    loop_child: struct {
        value: [LoopChildSize]u8 = [_]u8{0} ** IDSegment.LoopChildSize,
    },

    pub fn fromSrc(src: std.builtin.SourceLocation) IDSegment {
        return .{ .src = .{ .filename = src.file.ptr, .fn_name = src.fn_name.ptr, .line = src.line, .col = src.column } };
    }
};
const ID = struct {
    frame: u64,
    str: []const IDSegment,
    pub fn assertValid(self: ID, b2: *Beui2) void {
        std.debug.assert(self.frame == b2.persistent.frame_num or self.frame + 1 == b2.persistent.frame_num);
    }
    pub fn eql(self: ID, b2: *Beui2, other: ID) bool {
        self.assertValid(b2);
        other.assertValid(b2);
        if (self.str.len != other.str.len) return false;
        if (self.str.ptr == other.str.ptr) return true;
        for (self.str, other.str) |a, b| if (!std.meta.eql(a, b)) return false;
        return true;
    }
    pub fn refresh(self: ID, b2: *Beui2) ID {
        self.assertValid(b2);
        const self_cp = b2.frame.arena.dupe(IDSegment, self.str) catch @panic("oom");
        return .{ .str = self_cp, .frame = b2.persistent.frame_num };
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

const Constraints = struct {
    size: @Vector(2, i32),
};
const Scroller = struct {
    // fn child() will call some kind of preserveIdTree fn on the id it recieves
    // same with fn virtual()
    // because we don't want to lose state when a child isn't rendered

    // eventually we'll want to put scrollers inside of scrollers but we're not going to worry about that yet

    draw_list: *RepositionableDrawList,
    cursor: i32,
    constraints: Constraints,
    scroll_event_capture_id: ID,

    pub fn begin(caller_id: CallerID, constraints: Constraints) Scroller {
        const b2 = caller_id.b2;
        b2.pushScope(caller_id, @src());
        defer b2.popScope();

        const scroll_ev_capture_id = b2.id(@src());
        const scroll_by = b2.scrollCaptureResults(scroll_ev_capture_id);

        const scroll_state = b2.state(b2.id(@src()), struct { offset: f32, anchor: usize });
        if (!scroll_state.initialized) scroll_state.value.* = .{ .offset = 0, .anchor = 0 };
        scroll_state.value.offset += scroll_by[1];

        return .{
            .draw_list = b2.draw(),
            .cursor = @intFromFloat(@round(-scroll_state.value.offset)),
            .constraints = constraints,
            .scroll_event_capture_id = scroll_ev_capture_id,
        };
    }

    fn scrollerConstraints(self: *Scroller) ScrollerConstraints {
        return .{ .width = self.constraints.size[0] };
    }
    pub fn child(scroller: *Scroller, caller_id: CallerID) ?ChildFill {
        const b2 = caller_id.b2;
        b2.pushScope(caller_id, @src());

        return .{ .scroller = scroller, .b2 = b2, .constraints = scroller.scrollerConstraints() };
    }
    const ChildFill = struct {
        scroller: *Scroller,
        b2: *Beui2,
        constraints: ScrollerConstraints,
        pub fn end(self: ChildFill, value: ScrollerChild) void {
            self.b2.popScope();
            self.scroller.placeChild(value);
        }
    };
    pub fn virtual(scroller: *Scroller, caller_id: CallerID, ctx: anytype, comptime Anchor: type) VirtualIter(@TypeOf(ctx), Anchor) {
        const b2 = caller_id.b2;
        b2.pushScope(caller_id, @src());
        b2.pushLoop(@src(), Anchor);

        return .{ .ctx = ctx, .b2 = b2, .scroller = scroller, .pos = Anchor.first(ctx) };
    }
    fn VirtualIter(comptime Context: type, comptime Anchor: type) type {
        return struct {
            b2: *Beui2,
            scroller: *Scroller,
            ctx: Context,
            pos: ?Anchor,
            pub fn next(self: *@This()) ?VirtualFill {
                if (self.pos == null) return null;
                self.b2.pushLoopValue(@src(), self.pos.?);
                defer self.pos = Anchor.next(self.ctx, self.pos.?);
                return .{ .pos = self.pos.?, .scroller = self.scroller, .b2 = self.b2, .constraints = self.scroller.scrollerConstraints() };
            }
            const VirtualFill = struct {
                pos: Anchor,
                scroller: *Scroller,
                b2: *Beui2,
                constraints: ScrollerConstraints,
                pub fn end(self: VirtualFill, value: ScrollerChild) void {
                    self.b2.popLoopValue();
                    self.scroller.placeChild(value);
                }
            };
            pub fn end(self: *@This()) void {
                self.b2.popLoop();
                self.b2.popScope();
            }
        };
    }
    fn placeChild(self: *Scroller, ch: ScrollerChild) void {
        self.draw_list.place(ch.rdl, .{ 0, self.cursor });
        self.cursor += ch.height;
    }

    pub fn end(self: *Scroller) *RepositionableDrawList {
        self.draw_list.addMouseEventCapture(
            self.scroll_event_capture_id,
            .{ 0, 0 },
            .{ self.constraints.size[0], self.constraints.size[1] },
            .{ .capture_scroll = .{ .y = true } },
        );
        return self.draw_list;
    }
};
fn textDemo(
    caller_id: CallerID,
    text: []const u8,
    constraints: ScrollerConstraints,
) ScrollerChild {
    const b2 = caller_id.b2;
    b2.pushScope(caller_id, @src());
    defer b2.popScope();

    const draw = b2.draw();

    const capture_id = b2.id(@src());

    var clicked = false;
    if (b2.persistent.click_target) |ct| {
        if (ct.eql(b2, capture_id)) {
            clicked = true;
        }
    }

    var char_pos: @Vector(2, f32) = .{ 0, 0 };
    for (text) |char| {
        draw.addChar(char, char_pos, .fromHexRgb(0xFFFF00));
        char_pos += .{ 6, 0 };
    }

    draw.addRect(.{
        .pos = .{ 0, 0 },
        .size = .{ @floatFromInt(constraints.width), 10 },
        .tint = .fromHexRgb(if (clicked) 0x0000FF else 0x000099),
    });

    draw.addMouseEventCapture(capture_id, .{ 0, 0 }, .{ constraints.width, 10 }, .{ .capture_click = true });

    return .{
        .height = 10,
        .rdl = draw,
    };
}

const ScrollerConstraints = struct {
    width: i32,
};
const ScrollerChild = struct {
    height: i32,
    rdl: *RepositionableDrawList,
};

const CallerID = struct {
    b2: *Beui2,
    src: std.builtin.SourceLocation,
};

fn scrollDemo(caller_id: CallerID, constraints: Constraints) *RepositionableDrawList {
    const b2 = caller_id.b2;
    b2.pushScope(caller_id, @src());
    defer b2.popScope();

    var scroller = Scroller.begin(b2.callerID(@src()), constraints);

    if (scroller.child(b2.callerID(@src()))) |c| {
        c.end(textDemo(b2.callerID(@src()), "hello", c.constraints));
    }
    if (scroller.child(b2.callerID(@src()))) |c| {
        c.end(textDemo(b2.callerID(@src()), "world", c.constraints));
    }
    const my_list = &[_][]const u8{ "1", "2", "3" };

    {
        var virtual = scroller.virtual(b2.callerID(@src()), my_list.len, ListIndex);
        defer virtual.end();
        while (virtual.next()) |c| {
            c.end(textDemo(b2.callerID(@src()), my_list[c.pos.i], c.constraints));
        }
    }

    return scroller.end();
}
const ListIndex = struct {
    i: usize,
    pub fn first(len: usize) ?ListIndex {
        if (len == 0) return null;
        return .{ .i = 0 };
    }
    pub fn last(len: usize) ?ListIndex {
        if (len == 0) return null;
        return .{ .i = 0 };
    }
    pub fn prev(len: usize, itm: ListIndex) ?ListIndex {
        if (itm.i == 0) return null;
        if (len == 0) return null;
        return .{ .i = @min(itm.i - 1, len - 1) };
    }
    pub fn next(len: usize, itm: ListIndex) ?ListIndex {
        if (len == 0) return null;
        if (itm.i == len - 1) return null;
        return .{ .i = @min(itm.i + 1, len - 1) };
    }
};
