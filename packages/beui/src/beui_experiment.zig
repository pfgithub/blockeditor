const std = @import("std");

const Beui = @import("Beui.zig");
const render_list = @import("render_list.zig");
const tracy = @import("anywhere").tracy;
const util = @import("anywhere").util;
const LayoutCache = @import("LayoutCache.zig");
pub const Theme = @import("Theme.zig");

pub fn IdMap(comptime V: type) type {
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
pub fn IdArrayMap(comptime V: type) type {
    const IDContext = struct {
        pub fn hash(_: @This(), id: ID) u32 {
            return @truncate(id.hash());
        }
        pub fn eql(_: @This(), a: ID, b: ID, _: usize) bool {
            return a.eql(b);
        }
    };
    // store_hash is set to false. eql is just `std.mem.eql()` but for long strings that could take longer than we want?
    return std.ArrayHashMap(ID, V, IDContext, false);
}

const Beui2FrameCfg = struct {
    size: @Vector(2, f32),
};
const Beui2Frame = struct { arena: std.mem.Allocator, frame_cfg: Beui2FrameCfg, scroll_target: ?ScrollTarget };
const ScrollTarget = struct {
    id: ID,
    scroll: @Vector(2, f32),
};
const MouseEventInfo = struct {
    offset: @Vector(2, f32),
    observed_mouse_down: bool = false,
};
const StateValue = struct {
    data: []u8,
    log2_align: u8,
    type_id: [*:0]const u8,
    fn initUndefined(gpa: std.mem.Allocator, comptime T: type) StateValue {
        const log2_align = comptime std.math.log2_int(u64, @alignOf(T));
        const result = gpa.vtable.alloc(gpa.ptr, @sizeOf(T), log2_align, @returnAddress()) orelse @panic("oom");
        return .{
            .data = result[0..@sizeOf(T)],
            .log2_align = log2_align,
            .type_id = @typeName(T),
        };
    }
    fn cast(self: StateValue, comptime T: type) *T {
        std.debug.assert(self.type_id == @typeName(T));
        std.debug.assert(self.data.len == @sizeOf(T));
        std.debug.assert(self.log2_align == comptime std.math.log2_int(u64, @alignOf(T)));
        return @alignCast(@ptrCast(self.data.ptr));
    }
    fn deinit(self: StateValue, gpa: std.mem.Allocator) void {
        gpa.vtable.free(gpa.ptr, self.data, self.log2_align, @returnAddress());
    }
};
const Beui2Persistent = struct {
    gpa: std.mem.Allocator,

    arenas: [2]std.heap.ArenaAllocator,
    current_arena: u1 = 0,

    id_scopes: std.ArrayList(IDSegment),
    draw_lists: std.ArrayList(*RepositionableDrawList),
    last_frame_mouse_events: std.ArrayList(MouseEventEntry),
    last_frame_mouse2_events: std.ArrayList(RepositionableDrawList.Mouse2),
    prev_frame_mouse_event_to_offset: IdMap(MouseEventInfo),
    prev_frame_draw_list_states: IdMap(GenericDrawListState),
    this_frame_ids: IdMap(void),
    click_target: ?ID = null,
    state2_storage: IdArrayMap(Beui2.StateInfo),

    frame_num: u64 = 0,

    verdana_ttf: ?[]const u8,
    layout_cache: LayoutCache,
    wm: WindowManager,

    beui1: *Beui,

    mouse_pos: ?@Vector(2, f32) = null,
    mouse_focus: ?ID = null,
    uncommitted_move_offset: @Vector(2, f32) = .{ 0, 0 },
};
pub const Beui2 = struct {
    frame: Beui2Frame,
    persistent: Beui2Persistent,

    pub fn init(self: *Beui2, beui1: *Beui, gpa: std.mem.Allocator) void {
        const verdana_ttf: ?[]const u8 = for (&[_][]const u8{
            // cwd
            "Verdana.ttf",
            // linux
            "/usr/share/fonts/TTF/verdana.ttf",
            // mac
            "/System/Library/Fonts/Supplemental/Verdana.ttf",
            // windows
            "c:\\WINDOWS\\Fonts\\VERDANA.TTF",
        }) |search_path| {
            break std.fs.cwd().readFileAlloc(gpa, search_path, std.math.maxInt(usize)) catch continue;
        } else null;
        if (verdana_ttf == null) std.log.info("Verdana could not be found. Falling back to Noto Sans.", .{});
        const font = LayoutCache.Font.init(verdana_ttf orelse Beui.font_experiment.NotoSansMono_wght) orelse @panic("no font");

        self.* = .{
            .frame = undefined,
            .persistent = .{
                .gpa = gpa,
                .arenas = .{ .init(gpa), .init(gpa) },
                .id_scopes = .init(gpa),
                .draw_lists = .init(gpa),
                .last_frame_mouse_events = .init(gpa),
                .last_frame_mouse2_events = .init(gpa),
                .prev_frame_mouse_event_to_offset = .init(gpa),
                .prev_frame_draw_list_states = .init(gpa),
                .this_frame_ids = .init(gpa),
                .state2_storage = .init(gpa),

                .verdana_ttf = verdana_ttf,
                .layout_cache = .init(gpa, font),
                .wm = .init(self, gpa),

                .beui1 = beui1,
            },
        };
    }
    pub fn deinit(self: *Beui2) void {
        {
            // loop in reverse so we don't invalidate a pointer early
            const a = self.persistent.state2_storage.values();
            var i = a.len;
            while (i > 0) {
                i -= 1;
                a[i].deinit(self); // only gpa is used so it's ok to pass self in here
            }
        }
        self.persistent.state2_storage.deinit();
        self.persistent.wm.deinit();
        self.persistent.prev_frame_draw_list_states.deinit();
        self.persistent.layout_cache.deinit();
        if (self.persistent.verdana_ttf) |v| self.persistent.gpa.free(v);
        self.persistent.this_frame_ids.deinit();
        self.persistent.prev_frame_mouse_event_to_offset.deinit();
        self.persistent.last_frame_mouse2_events.deinit();
        self.persistent.last_frame_mouse_events.deinit();
        for (&self.persistent.arenas) |*a| a.deinit();
        self.persistent.id_scopes.deinit();
        self.persistent.draw_lists.deinit();
    }

    // TODO: add fns for handling events here:
    // ie onMouseClick()
    // it will look through last_frame_mouse2_events

    pub fn onMouseMove(self: *Beui2, new_pos: ?@Vector(2, f32)) void {
        const prev_pos = self.persistent.mouse_pos;
        self.persistent.mouse_pos = new_pos;
        if (prev_pos != null and new_pos != null) {
            self.persistent.uncommitted_move_offset += new_pos.? - prev_pos.?;
        } else {
            self.persistent.uncommitted_move_offset = .{ 0, 0 };
        }
    }
    pub fn onMouseEvent(self: *Beui2, btn: enum(u4) { left, middle, right, _ }, ev: enum { down, up }) void {
        if (btn != .left) return; // TODO
        commitMouseMoveEvents(self);
        switch (ev) {
            .down => {
                const mpos = self.persistent.mouse_pos orelse return;
                // find who captures this event
                for (self.persistent.last_frame_mouse2_events.items) |item| {
                    if (pointInRect(mpos, item.pos, item.size)) {
                        if (item.cfg.onMouseEvent) |onMouseEventFn| {
                            if (onMouseEventFn.call(self, .{
                                .capture_pos = item.pos,
                                .capture_size = item.size,
                                .pos = mpos,
                                .action = .down,
                            })) |cursor| {
                                self.persistent.beui1.frame.cursor = cursor;
                                // it ate the event, so we set it as the mouse focus
                                self.persistent.mouse_focus = item.id;
                                break;
                            }
                        }
                    }
                }
            },
            .up => {
                // we give the event to the mouse focus
                const mfid = self.persistent.mouse_focus orelse return;
                for (self.persistent.last_frame_mouse2_events.items) |item| {
                    if (item.id.eql(mfid)) {
                        if (item.cfg.onMouseEvent) |onMouseEventFn| {
                            self.persistent.beui1.frame.cursor = onMouseEventFn.call(self, .{
                                .capture_pos = item.pos,
                                .capture_size = item.size,
                                .pos = self.persistent.mouse_pos,
                                .action = .up,
                            }).?;
                        }
                    }
                }
                self.persistent.mouse_focus = null;
            },
        }
    }
    fn commitMouseMoveEvents(self: *Beui2) void {
        defer self.persistent.uncommitted_move_offset = .{ 0, 0 };
        if (@reduce(.And, self.persistent.uncommitted_move_offset == @Vector(2, f32){ 0, 0 })) return;
        const mpos = self.persistent.mouse_pos orelse return;
        if (self.persistent.mouse_focus) |mfid| {
            // if there is a mouse focus:
            for (self.persistent.last_frame_mouse2_events.items) |item| {
                if (item.id.eql(mfid)) {
                    if (item.cfg.onMouseEvent) |onMouseEventFn| {
                        self.persistent.beui1.frame.cursor = onMouseEventFn.call(self, .{
                            .capture_pos = item.pos,
                            .capture_size = item.size,
                            .pos = mpos,
                            .action = .move_while_down,
                        }).?;
                    }
                }
            }
        } else {
            // else, give it to whoever can see it:
            // TODO and should also give the event to the item which most recently recieved a move_while_up event
            //          so that it can know the mouse moved out of its range.
            for (self.persistent.last_frame_mouse2_events.items) |item| {
                if (pointInRect(mpos, item.pos, item.size)) {
                    if (item.cfg.onMouseEvent) |onMouseEventFn| {
                        if (onMouseEventFn.call(self, .{
                            .capture_pos = item.pos,
                            .capture_size = item.size,
                            .pos = mpos,
                            .action = .move_while_up,
                        })) |cursor| {
                            self.persistent.beui1.frame.cursor = cursor;
                            break;
                        }
                    }
                }
            }
        }
    }

    pub fn newFrame(self: *Beui2, frame_cfg: Beui2FrameCfg) ID {
        const beui = self.persistent.beui1;
        self.persistent.layout_cache.tick(beui);
        self.commitMouseMoveEvents();
        self.persistent.last_frame_mouse2_events.clearRetainingCapacity();
        if (self.persistent.mouse_focus) |*mf| mf.* = mf.refresh();
        // handle events
        // - scroll: if there is a scroll event, hit test to find which handler it touched
        const mousepos_int: @Vector(2, f32) = beui.persistent.mouse_pos;
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
            if (item.cfg.capture_click != null or item.cfg.observe_mouse_down) {
                self.persistent.prev_frame_mouse_event_to_offset.putNoClobber(item.id, .{ .offset = item.pos }) catch @panic("oom");
            }
        }
        // - mouse: set cursor
        if (self.persistent.click_target == null) {
            for (self.persistent.last_frame_mouse_events.items) |item| {
                if (item.cfg.capture_click) |cursor| {
                    if (item.coversPoint(mousepos_int)) {
                        beui.frame.cursor = cursor;
                        break;
                    }
                }
            }
        } else {
            for (self.persistent.last_frame_mouse_events.items) |item| {
                if (item.id.eql(self.persistent.click_target.?)) {
                    beui.frame.cursor = item.cfg.capture_click.?;
                    break;
                }
            }
        }
        // - mouse: store focus
        if (beui.isKeyPressed(.mouse_left)) {
            self.persistent.click_target = null;
            // find click target
            for (self.persistent.last_frame_mouse_events.items) |item| {
                if (item.cfg.observe_mouse_down) {
                    if (item.coversPoint(mousepos_int)) {
                        const info = self.persistent.prev_frame_mouse_event_to_offset.getPtr(item.id).?;
                        info.observed_mouse_down = true;
                    }
                }
                if (item.cfg.capture_click != null) {
                    if (item.coversPoint(mousepos_int)) {
                        // found.
                        self.persistent.click_target = item.id;
                        break;
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

        // state2: refresh ids & delete unused
        // (we shouldn't have to refresh ids; we can make them OwnedIDs and skip that mess)
        {
            const a = self.persistent.state2_storage.keys();
            const b = self.persistent.state2_storage.values();
            var i = a.len;
            while (i > 0) {
                i -= 1;
                a[i] = a[i].refresh();
                if (b[i].referenced_frame != self.persistent.frame_num) {
                    std.log.info("discarding state", .{});
                    // looping in reverse so this is ok
                    b[i].deinit(self);
                    self.persistent.state2_storage.orderedRemoveAt(i);
                }
            }
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

        const res_id: ID = .{
            .b2 = self,
            .frame = self.persistent.frame_num,
            .str = &.{},
        };
        self.persistent.wm.beginFrame(res_id.sub(@src()));

        return res_id;
    }
    pub fn endFrame(self: *Beui2, renderlist: ?*render_list.RenderList) void {
        self.persistent.prev_frame_draw_list_states.clearRetainingCapacity();
        const result = self.persistent.wm.render();
        result.placed = true;
        result.finalize(.{
            .out_list = renderlist,
            .out_events = &self.persistent.last_frame_mouse_events,
            .out_mouse_events = &self.persistent.last_frame_mouse2_events,
            .out_rdl_states = &self.persistent.prev_frame_draw_list_states,
        }, .{});
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
        var mouse_pos: @Vector(2, f32) = .{ 0, 0 };
        var observed_mouse_down: bool = false;
        if (self.persistent.prev_frame_mouse_event_to_offset.getPtr(capture_id)) |mof| {
            const b1pos: @Vector(2, f32) = self.persistent.beui1.persistent.mouse_pos;
            mouse_pos = b1pos - mof.offset;
            observed_mouse_down = mof.observed_mouse_down;
        }
        return .{
            .mouse_left_pressed_down_this_frame = if (mouse_left_held) self.persistent.beui1.isKeyPressed(.mouse_left) else false,
            .mouse_left_held = mouse_left_held,
            .mouse_pos = mouse_pos,
            .observed_mouse_down = observed_mouse_down,
        };
    }
    pub fn scrollCaptureResults(self: *Beui2, capture_id: ID) @Vector(2, f32) {
        if (self.frame.scroll_target) |st| {
            if (st.id.eql(capture_id)) {
                return st.scroll;
            }
        }
        return .{ 0, 0 };
    }
    /// - to preserve state while not rendering a child, eg in a details element, call
    ///   beui2.preserveStateTree(root_id). must preserve identifiers! use a PersistedID
    ///   rather than a regular ID within state, otherwise if your component gets hidden for
    ///   a few frames, when it returns all its IDs will be invalid.
    /// - your state's context pointer must stay the same for the whole time the state is alive.
    /// - if you invalidate your state's context pointer, you must stop posting the state immediately
    ///   so it can be deleted.
    /// (how do we make sure state destroy()s get called in the right order so if one feeds into another
    ///  the outer ctx isn't destroyed before the inner ctx? maybe just go in reverse order and that is enough?)
    pub fn state2(self: *Beui2, self_id: ID, init_ctx: anytype, comptime StateType: type) *StateType {
        const helper = struct {
            fn destroy(value: *anyopaque, b2: *Beui2) void {
                const state_val: *StateType = @ptrCast(@alignCast(value));
                state_val.deinit();
                b2.persistent.gpa.destroy(state_val);
            }
            const fns: StateVtable = .{
                .destroy = &destroy,
            };
        };

        const gpres = self.persistent.state2_storage.getOrPut(self_id) catch @panic("oom");
        if (!gpres.found_existing) {
            const state_val = self.persistent.gpa.create(StateType) catch @panic("oom");
            state_val.init(init_ctx);
            gpres.value_ptr.* = .{
                .vtable = &helper.fns,
                .state = @ptrCast(@alignCast(state_val)),
                .referenced_frame = undefined,
            };
        }
        gpres.value_ptr.referenced_frame = self.persistent.frame_num;

        return @ptrCast(@alignCast(gpres.value_ptr.state));
    }
    const StateInfo = struct {
        vtable: *const StateVtable,
        state: *anyopaque,
        referenced_frame: u64,

        fn deinit(self: *StateInfo, b2: *Beui2) void {
            self.vtable.destroy(self.state, b2);
            self.state = undefined;
        }
    };
    const StateVtable = struct {
        destroy: *const fn (value: *anyopaque, b2: *Beui2) void,
    };
    fn StateResult(comptime StateType: type) type {
        return struct { initialized: bool, value: *StateType };
    }

    pub fn getPrevFrameDrawListState(self: *Beui2, state_id: ID) ?*const GenericDrawListState {
        if (self.persistent.prev_frame_draw_list_states.getPtr(state_id)) |prev_frame_draw_list_state| {
            return prev_frame_draw_list_state;
        } else {
            return null;
        }
    }

    pub fn fmt(self: *Beui2, comptime format: []const u8, args: anytype) []u8 {
        return std.fmt.allocPrint(self.frame.arena, format, args) catch @panic("oom");
    }
};
const GenericDrawListState = struct {
    offset_from_screen_ul: @Vector(2, f32),
    state: *const anyopaque,
    type_id: [*:0]const u8,

    pub fn cast(self: GenericDrawListState, comptime T: type) *const T {
        std.debug.assert(@typeName(T) == self.type_id);
        return @ptrCast(@alignCast(self.state));
    }
};

pub const MouseCaptureResults = struct {
    mouse_left_pressed_down_this_frame: bool,
    mouse_left_held: bool,
    mouse_pos: @Vector(2, f32),
    observed_mouse_down: bool,
};

const IDSegment = struct {
    const IDSegmentSize = 8 * 3;
    comptime {
        std.debug.assert(std.meta.hasUniqueRepresentation(IDSegment));
    }
    value: [IDSegmentSize]u8,
    tag: Tag,
    const Tag = enum { src, loop, loop_child, unique };
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
const IDSegmentNode = struct {
    segment: IDSegment,
    parent: ?*const IDSegmentNode,

    // eventually we can have an id tree in b2
    // and that way comparing ids is as simple as id_1 == id_2 because the pointers will
    // be the same if the ids are the same.
    //
    // pushing an id for the first time costs a memorypool allocation.
    // subsequent times, it finds the same one as last time.
    // id storage longer than two frames requires ref()ing the id or something
};
pub const ID = struct {
    var unique_id_idx: u64 = 0;
    b2: *Beui2,
    frame: u64,
    /// DO NOT READ POINTER WITHOUT CALLING .assertValid() FIRST.
    str: []const IDSegment,

    const duplicate_id_safety = std.debug.runtime_safety;

    pub fn format(value: ID, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("<ID:{d}>", .{value.hash()});
    }

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
        const tctx = tracy.trace(@src());
        defer tctx.end();

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

    pub fn unique(b2: *Beui2) ID {
        unique_id_idx += 1;
        const res = b2.frame.arena.alloc(IDSegment, 1) catch @panic("oom");
        res[0] = .fromTagValue(.unique, u64, unique_id_idx);
        // no need for duplicate safety; it's guaranteed not to be a duplicate
        return .{ .b2 = b2, .frame = b2.persistent.frame_num, .str = res };
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
        return self._addInternal(&.{ .fromSrc(src), self._loopValue(@typeName(@TypeOf(child_t)), std.mem.asBytes(&child_t)) });
    }
    pub fn pushLoopValueNoSrc(self: ID, child_t: anytype) ID {
        return self._addInternal(&.{self._loopValue(@typeName(@TypeOf(child_t)), std.mem.asBytes(&child_t))});
    }
    fn _loopValue(self: ID, child_t: [*:0]const u8, child_v: []const u8) IDSegment {
        self.assertValid();
        if (self.str.len == 0) @panic("pushLoopValue called without pushLoop");
        const last = self.str[self.str.len - 1];
        if (last.tag != .loop) @panic("pushLoopValue called but last push was not pushLoop");
        const last_loop = last.readAsType(IDSegment.LoopStruct);
        if (last_loop.child_t != child_t) @panic("pushLoopValue called with different type than from pushLoop");
        std.debug.assert(child_v.len <= IDSegment.IDSegmentSize);
        return .fromTagSlice(.loop_child, child_v);
    }

    pub fn sub(self: ID, src: std.builtin.SourceLocation) ID {
        return self._addInternal(&.{.fromSrc(src)});
    }
};

const MouseEventEntry = struct {
    id: ID,
    pos: @Vector(2, f32),
    size: @Vector(2, f32),
    cfg: MouseEventCaptureConfig,

    pub fn coversPoint(self: MouseEventEntry, point: @Vector(2, f32)) bool {
        return pointInRect(point, self.pos, self.size);
    }
};
pub fn pointInRect(point: ?@Vector(2, f32), rect_pos: @Vector(2, f32), rect_size: @Vector(2, f32)) bool {
    if (point == null) return false;
    return @reduce(.And, point.? >= rect_pos) and @reduce(.And, point.? < rect_pos + rect_size);
}
const MouseEventCaptureConfig = struct {
    /// if there was a click within the area of this, report it but keep processing the event until it is captured
    observe_mouse_down: bool = false,
    capture_click: ?Beui.Cursor = null,
    capture_scroll: struct { x: bool = false, y: bool = false } = .{},
};
pub const Corners = packed struct(u4) {
    top_left: bool = false,
    top_right: bool = false,
    bottom_left: bool = false,
    bottom_right: bool = false,
    pub const top: Corners = .{ .top_left = true, .top_right = true };
    pub const left: Corners = .{ .top_left = true, .bottom_left = true };
    pub const bottom: Corners = .{ .bottom_left = true, .bottom_right = true };
    pub const right: Corners = .{ .top_right = true, .bottom_right = true };
    pub const all: Corners = .{ .top_left = true, .top_right = true, .bottom_left = true, .bottom_right = true };
};
const Sides = packed struct(u4) {
    _top: bool = false,
    _left: bool = false,
    _bottom: bool = false,
    _right: bool = false,
    pub const top: Sides = .{ ._top = true };
    pub const top_right: Sides = .{ ._top = true, ._right = true };
    pub const right: Sides = .{ ._right = true };
    pub const bottom_right: Sides = .{ ._bottom = true, ._right = true };
    pub const bottom: Sides = .{ ._bottom = true };
    pub const bottom_left: Sides = .{ ._bottom = true, ._left = true };
    pub const left: Sides = .{ ._left = true };
    pub const top_left: Sides = .{ ._top = true, ._left = true };
    pub const all: Sides = .{ ._top = true, ._left = true, ._bottom = true, ._right = true };
    pub const top_bottom: Sides = .{ ._top = true, ._left = false, ._bottom = true, ._right = false };
    pub const top_bottom_right: Sides = .{ ._top = true, ._left = false, ._bottom = true, ._right = true };
    pub const top_bottom_left: Sides = .{ ._top = true, ._left = true, ._bottom = true, ._right = false };
    pub const none: Sides = .{ ._top = false, ._left = false, ._bottom = false, ._right = false };
    fn andTop(a: Sides) Sides {
        return .{ ._top = true, .left = a._left, ._bottom = a._bottom, .right = a._right };
    }
    fn andLeft(a: Sides) Sides {
        return .{ ._top = a._top, .left = true, ._bottom = a._bottom, .right = a._right };
    }
    fn andBottom(a: Sides) Sides {
        return .{ ._top = a._top, .left = a._left, ._bottom = true, .right = a._right };
    }
    fn andRight(a: Sides) Sides {
        return .{ ._top = a._top, .left = a._left, ._bottom = a._bottom, .right = true };
    }
};
pub const RepositionableDrawList = struct {
    const Reservation = struct {
        index: usize,
        frame: u64,
        for_draw_list: *RepositionableDrawList,
    };
    const Mouse2 = struct {
        pos: @Vector(2, f32),
        size: @Vector(2, f32),
        id: ID,
        cfg: MouseEventCapture2Config,
    };
    const RepositionableDrawChild = union(enum) {
        geometry: struct {
            vertices: []const render_list.RenderListVertex,
            indices: []const render_list.RenderListIndex,
            image: ?render_list.RenderListImage,
        },
        mouse: struct {
            pos: @Vector(2, f32),
            size: @Vector(2, f32),
            id: ID,
            cfg: MouseEventCaptureConfig,
        },
        mouse2: Mouse2,
        embed: struct {
            child: ?*RepositionableDrawList,
            cfg: PlaceCfg,
        },
        user_state: struct {
            id: ID,
            data: *const anyopaque,
            type_id: [*:0]const u8,
            // calling getState(id) returns your state pointer along with the offset of the item on the previous frame
        },
    };
    b2: *Beui2,
    content: std.ArrayList(RepositionableDrawChild),
    placed: bool = false,
    pub const PlaceCfg = struct {
        offset: @Vector(2, f32) = .{ 0, 0 },
        // ie: disable_mouse_events to disable mouse events for the whole tree
        // ie: transformation matrix to apply to the rendered image but not event handlers for nice animations
        pub fn add(a: PlaceCfg, b: PlaceCfg) PlaceCfg {
            return .{ .offset = a.offset + b.offset };
        }
    };
    pub fn place(self: *RepositionableDrawList, child: *RepositionableDrawList, cfg: PlaceCfg) void {
        std.debug.assert(!child.placed);
        self.content.append(.{ .embed = .{ .child = child, .cfg = cfg } }) catch @panic("oom");
        child.placed = true;
    }
    pub fn reserve(self: *RepositionableDrawList) Reservation {
        self.content.append(.{ .embed = .{ .child = null, .cfg = .{} } }) catch @panic("oom");
        return .{ .frame = self.b2.persistent.frame_num, .index = self.content.items.len - 1, .for_draw_list = self };
    }
    pub fn fill(self: *RepositionableDrawList, slot: Reservation, child: *RepositionableDrawList, cfg: PlaceCfg) void {
        std.debug.assert(self.b2.persistent.frame_num == slot.frame);
        std.debug.assert(self == slot.for_draw_list);
        self.content.items[slot.index].embed = .{ .child = child, .cfg = cfg };
        child.placed = true;
    }
    pub fn addUserState(self: *RepositionableDrawList, id: ID, comptime StateT: type, state: *const StateT) void {
        self.content.append(.{ .user_state = .{
            .id = id,
            .data = @ptrCast(state),
            .type_id = @typeName(StateT),
        } }) catch @panic("oom");
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
    pub fn addRegion(self: *RepositionableDrawList, opts: struct {
        pos: @Vector(2, f32),
        size: @Vector(2, f32),
        region: @import("Texpack.zig").Region,
        image: ?render_list.RenderListImage,
        image_size: u32,
        tint: Beui.Color = .fromHexRgb(0xFFFFFF),
    }) void {
        const uv = opts.region.calculateUV(opts.image_size);
        return self.addRect(.{
            .pos = opts.pos,
            .size = opts.size,
            .uv_pos = .{ uv.x, uv.y },
            .uv_size = .{ uv.width, uv.height },
            .image = opts.image,
            .tint = opts.tint,
        });
    }
    pub fn addRect(
        self: *RepositionableDrawList,
        opts_in: struct {
            pos: @Vector(2, f32),
            size: @Vector(2, f32),
            uv_pos: @Vector(2, f32) = .{ -1.0, -1.0 },
            uv_size: @Vector(2, f32) = .{ 0, 0 },
            image: ?render_list.RenderListImage = null,
            tint: Beui.Color = .fromHexRgb(0xFFFFFF),
            rounding: struct {
                corners: Corners = .{},
                style: enum {
                    none,
                    angle, // can be done using tris but we probably won't have smoothing. so maybe not tris.
                    round,
                } = .round,
                radius: f32,
            } = .{ .style = .none, .radius = 0 },
            circle: [4]@Vector(2, f32) = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
        },
    ) void {
        var opts = opts_in;
        if (opts.rounding.style == .round) {
            const maximum_round: f32 = @reduce(.Min, opts.size / @Vector(2, f32){ 2, 2 });
            const actual_round = @min(maximum_round, opts.rounding.radius);
            // TODO preserve UVs

            self.addRect(.{
                .pos = opts.pos,
                .size = .{ actual_round, actual_round },
                .circle = .{ .{ 1, 1 }, .{ 1, 0 }, .{ 0, 1 }, .{ 0, 0 } },
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ actual_round, 0 },
                .size = .{ opts.size[0] - actual_round * 2, actual_round },
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ opts.size[0] - actual_round, 0 },
                .size = .{ actual_round, actual_round },
                .circle = .{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 0 }, .{ 0, 1 } },
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ 0, actual_round },
                .size = .{ opts.size[0], opts.size[1] - actual_round * 2 },
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ 0, opts.size[1] - actual_round },
                .size = .{ actual_round, actual_round },
                .circle = .{ .{ 1, 0 }, .{ 0, 0 }, .{ 1, 1 }, .{ 0, 1 } },
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ actual_round, opts.size[1] - actual_round },
                .size = .{ opts.size[0] - actual_round * 2, actual_round },
                .tint = opts.tint,
            });
            self.addRect(.{
                .pos = opts.pos + @Vector(2, f32){ opts.size[0] - actual_round, opts.size[1] - actual_round },
                .size = .{ actual_round, actual_round },
                .circle = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 } },
                .tint = opts.tint,
            });
            return;
        }
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
            .{ .pos = ul, .uv = uv_ul, .tint = opts.tint.value, .circle = opts.circle[0] },
            .{ .pos = ur, .uv = uv_ur, .tint = opts.tint.value, .circle = opts.circle[1] },
            .{ .pos = bl, .uv = uv_bl, .tint = opts.tint.value, .circle = opts.circle[2] },
            .{ .pos = br, .uv = uv_br, .tint = opts.tint.value, .circle = opts.circle[3] },
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
    pub fn addMouseEventCapture(self: *RepositionableDrawList, id: ID, pos: @Vector(2, f32), size: @Vector(2, f32), cfg: MouseEventCaptureConfig) void {
        self.content.append(.{ .mouse = .{ .pos = pos, .size = size, .id = id, .cfg = cfg } }) catch @panic("oom");
    }
    pub const MouseEventCapture2Config = struct {
        // lifetimes:
        // - this is called between frames. so if something gets destroyed on frame 1,
        //   don't add a betweenframecallback for it.
        onMouseEvent: ?BetweenFrameCallback(*Beui2, MouseEvent, ?Beui.Cursor) = null,
        onScrollEvent: ?BetweenFrameCallback(*Beui2, ScrollEvent, bool) = null,
    };
    pub fn addMouseEventCapture2(self: *RepositionableDrawList, id: ID, pos: @Vector(2, f32), size: @Vector(2, f32), cfg: MouseEventCapture2Config) void {
        self.content.append(.{ .mouse2 = .{ .pos = pos, .size = size, .id = id, .cfg = cfg } }) catch @panic("oom");
    }

    const FinalizeCfg = struct {
        out_list: ?*render_list.RenderList,
        out_events: ?*std.ArrayList(MouseEventEntry),
        out_mouse_events: ?*std.ArrayList(Mouse2),
        out_rdl_states: ?*IdMap(GenericDrawListState),
    };
    fn finalize(self: *RepositionableDrawList, res: FinalizeCfg, cfg: PlaceCfg) void {
        for (self.content.items) |item| {
            switch (item) {
                .geometry => |geo| {
                    if (res.out_list) |v| v.addVertices(geo.image, geo.vertices, geo.indices, cfg.offset);
                },
                .mouse => |mev| {
                    if (res.out_events) |v| v.append(.{
                        .id = mev.id,
                        .pos = mev.pos + cfg.offset,
                        .size = mev.size,
                        .cfg = mev.cfg,
                    }) catch @panic("oom");
                },
                .mouse2 => |mev| {
                    if (res.out_mouse_events) |v| v.append(.{
                        .id = mev.id,
                        .pos = mev.pos + cfg.offset,
                        .size = mev.size,
                        .cfg = mev.cfg,
                    }) catch @panic("oom");
                },
                .embed => |eev| {
                    if (eev.child) |c| c.finalize(res, cfg.add(eev.cfg));
                },
                .user_state => |usv| {
                    if (res.out_rdl_states) |v| {
                        v.putNoClobber(usv.id, .{
                            .offset_from_screen_ul = cfg.offset,
                            .state = usv.data,
                            .type_id = usv.type_id,
                        }) catch @panic("oom");
                    }
                },
            }
        }
    }
};

// fn harfbuzzText(call_info: StandardCallInfo, text: []const u8, color: Beui.Color) StandardChild {
//     const ui = call_info.ui(@src());

//     const draw = ui.id.b2.draw();
// }

pub fn textOnly(
    call_info: StandardCallInfo,
    text_v: []const u8,
    color: Beui.Color,
) StandardChild {
    const ui = call_info.ui(@src());
    const b2 = ui.id.b2;

    const draw = b2.draw();

    var char_pos: @Vector(2, f32) = .{ 0, 0 };
    for (text_v) |char| {
        draw.addChar(char, char_pos, color);
        char_pos += .{ 6, 0 };
    }

    return .{
        .size = .{ char_pos[0], 10 },
        .rdl = draw,
    };
}

const TextLine = struct {
    text: []const u8,
};

pub fn textLine(call_info: StandardCallInfo, line: TextLine) StandardChild {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const ui = call_info.ui(@src());
    const b2 = ui.id.b2;
    const lc = &b2.persistent.layout_cache;

    const result = lc.renderLine(b2, .{ .text = line.text, .max_width = call_info.constraints.available_size.w });
    const resdraw = b2.draw();
    resdraw.addVertices(result.image, result.vertices, result.indices);

    return .{
        .size = .{ result.single_line_width, result.height },
        .rdl = resdraw,
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

    available_size: struct { w: ?f32, h: ?f32 },
};
pub const StandardChild = struct {
    size: @Vector(2, f32),
    rdl: *RepositionableDrawList,
};

pub const StandardCallInfo = struct {
    caller_id: ID,
    constraints: StandardConstraints,
    pub fn ui(self: StandardCallInfo, src: std.builtin.SourceLocation) StandardUI {
        return .{ .id = self.caller_id.sub(src), .constraints = self.constraints };
    }
};
pub const StandardUI = struct {
    id: ID,
    constraints: StandardConstraints,
    pub fn sub(self: StandardUI, src: std.builtin.SourceLocation) StandardCallInfo {
        return .{ .caller_id = self.id.sub(src), .constraints = self.constraints };
    }
    pub fn subWithOffset(self: StandardUI, src: std.builtin.SourceLocation, subtract_size: @Vector(2, f32)) StandardCallInfo {
        var res_constraints = self.constraints;
        if (res_constraints.available_size.w) |*w| w.* -= subtract_size[0];
        if (res_constraints.available_size.h) |*h| h.* -= subtract_size[1];
        return .{ .caller_id = self.id.sub(src), .constraints = res_constraints };
    }
};
pub const BetweenFrameCallback = Component;
pub fn Component(comptime Arg1: type, comptime Arg2: type, comptime Ret: type) type {
    return struct {
        ctx: *anyopaque,
        fn_ptr: *const fn (ctx: *anyopaque, arg1: Arg1, arg2: Arg2) Ret,
        pub fn from(ctx_0: anytype, comptime fn_val: fn (ctx: @TypeOf(ctx_0), arg1: Arg1, arg2: Arg2) Ret) @This() {
            return .{
                .ctx = @ptrCast(@constCast(ctx_0)),
                .fn_ptr = struct {
                    fn fn_ptr(ctx_1: *const anyopaque, arg1: Arg1, arg2: Arg2) Ret {
                        return fn_val(@ptrCast(@alignCast(@constCast(ctx_1))), arg1, arg2);
                    }
                }.fn_ptr,
            };
        }
        pub fn call(self: @This(), arg1: Arg1, arg2: Arg2) Ret {
            return self.fn_ptr(self.ctx, arg1, arg2);
        }
    };
}
fn defaultTextButton(call_info: StandardCallInfo, msg: []const u8, ehdl: ButtonEhdl) StandardChild {
    const ui = call_info.ui(@src());
    return button(ui.sub(@src()), ehdl, .from(&msg, defaultTextButton_1));
}
fn defaultTextButton_1(msg: *const []const u8, caller_id: StandardCallInfo, evres: ButtonState) StandardChild {
    const ui = caller_id.ui(@src());
    const color: Beui.Color = if (evres.active) .fromHexRgb(0x0000FF) else .fromHexRgb(0x000099);
    return setBackground(ui.sub(@src()), color, .from(msg, defaultTextButton_2));
}
fn defaultTextButton_2(msg: *const []const u8, caller_id: StandardCallInfo, _: void) StandardChild {
    const ui = caller_id.ui(@src());
    return textOnly(ui.sub(@src()), msg.*, .fromHexRgb(0xFFFF00));
}

pub const ButtonEhdl = struct {
    onClick: BetweenFrameCallback(*Beui2, void, void),
};
pub const ButtonState = struct {
    active: bool,
    ehdl: ButtonEhdl,
};
pub fn button(call_info: StandardCallInfo, ehdl: ButtonEhdl, child_component: Component(StandardCallInfo, ButtonState, StandardChild)) StandardChild {
    const tctx = tracy.trace(@src());
    defer tctx.end();

    const ui = call_info.ui(@src());

    const draw = ui.id.b2.draw();

    const draw_list_state_id = ui.id.sub(@src());
    const prev_state = ui.id.b2.getPrevFrameDrawListState(draw_list_state_id);
    const next_state = ui.id.b2.frame.arena.create(ButtonState) catch @panic("oom");
    next_state.* = .{
        .active = if (prev_state) |p| p.cast(ButtonState).active else false,
        .ehdl = ehdl,
    };
    draw.addUserState(draw_list_state_id, ButtonState, next_state);

    const child = child_component.call(ui.sub(@src()), next_state.*);
    draw.place(child.rdl, .{});
    draw.addMouseEventCapture2(ui.id.sub(@src()), .{ 0, 0 }, child.size, .{
        .onMouseEvent = .from(next_state, button__onMouseEvent),
    });
    return .{ .size = child.size, .rdl = draw };
}
pub const MouseEvent = struct {
    capture_pos: @Vector(2, f32),
    capture_size: @Vector(2, f32),
    pos: ?@Vector(2, f32),
    action: enum { down, up, move_while_down, move_while_up },
};
pub const ScrollEvent = struct {
    capture_pos: @Vector(2, f32),
    capture_size: @Vector(2, f32),
    pos: ?@Vector(2, f32),
    scroll: @Vector(2, f32),
};
fn button__onMouseEvent(st: *ButtonState, b2: *Beui2, ev: MouseEvent) ?Beui.Cursor {
    if (ev.action == .move_while_up) return .arrow;
    st.active = pointInRect(ev.pos, ev.capture_pos, ev.capture_size);
    if (ev.action == .up) {
        if (st.active) st.ehdl.onClick.call(b2, {});
        st.active = false;
    }
    return .arrow;
}

fn setBackground(call_info: StandardCallInfo, color: Beui.Color, child_component: Component(StandardCallInfo, void, StandardChild)) StandardChild {
    const ui = call_info.ui(@src());
    const child = child_component.call(ui.sub(@src()), {});

    const draw = ui.id.b2.draw();
    draw.place(child.rdl, .{});
    draw.addRect(.{ .pos = .{ 0, 0 }, .size = child.size, .tint = color });
    return .{ .size = child.size, .rdl = draw };
}
const ScrollState = struct {
    offset: f32,
    anchor: util.AnySized(IDSegment.IDSegmentSize, 8),
    pub fn init(self: *ScrollState, ctx: util.AnySized(IDSegment.IDSegmentSize, 8)) void {
        self.* = .{ .offset = 0, .anchor = ctx };
    }
    pub fn deinit(_: *ScrollState) void {}
};

var _scroll_state: ?ScrollState = null;

pub fn virtualScroller(call_info: StandardCallInfo, context: anytype, comptime Index: type, child_component: Component(StandardCallInfo, Index, StandardChild)) StandardChild {
    // TODO sticky lines:
    // - sticky items stick to the top
    // - Index.parentSticky(current_node) -> sticky item to render
    // how it works:
    // - after finishing rendering children, get the parentSticky of the current first line
    // - then, render it at the top
    // - add an overlay click handler over it that says: if mouse down within bounds, jump to line
    //   (next frame, at the beginning, if there was mouse down within its bounds, we set the scroll target to its index and the scroll offset to 0)
    //   it also clicks through and does any regular click events because it's just a capturing handler.
    // TODO: scrollbar
    // - can't render a scrollbar without a height. so we'll need to set up height estimation.

    const ui = call_info.ui(@src());
    if (ui.constraints.available_size.w == null or ui.constraints.available_size.h == null) @panic("scroller2 requires known available size");

    const rdl = ui.id.b2.draw();
    const capture_sticky_click_rdl = ui.id.b2.draw();
    const capture_sticky_reservation = rdl.reserve();
    const height = ui.constraints.available_size.h.?;

    const scroll_ev_capture_id = ui.id.sub(@src());
    const scroll_by = ui.id.b2.scrollCaptureResults(scroll_ev_capture_id);

    const scroll_state = ui.id.b2.state2(ui.id.sub(@src()), util.AnySized(IDSegment.IDSegmentSize, 8).from(Index, .first(context)), ScrollState);

    scroll_state.offset += scroll_by[1];

    var cursor: f32 = scroll_state.offset;

    const idx_initial = scroll_state.anchor.as(Index);
    var idx = idx_initial.update(context);
    if (idx) |val| scroll_state.anchor = .from(Index, val);

    const loop_index = ui.id.pushLoop(@src(), Index);
    if (cursor > 0 and idx != null) {
        // seek backwards
        var backwards_cursor = cursor;
        var backwards_index = idx.?;
        while (backwards_cursor > 0) {
            backwards_index = backwards_index.prev(context) orelse break;

            const child = child_component.call(.{ .caller_id = loop_index.pushLoopValueNoSrc(backwards_index), .constraints = .{
                .available_size = .{ .w = ui.constraints.available_size.w.?, .h = null },
            } }, backwards_index);

            backwards_cursor -= child.size[1];
            scroll_state.anchor = .from(Index, backwards_index);
            scroll_state.offset -= child.size[1];
            rdl.place(child.rdl, .{ .offset = .{ 0, backwards_cursor } });
        }
    }
    while (idx != null) {
        if (cursor > height) break;

        const child = child_component.call(.{ .caller_id = loop_index.pushLoopValueNoSrc(idx.?), .constraints = .{
            .available_size = .{ .w = ui.constraints.available_size.w.?, .h = null },
        } }, idx.?);

        if (cursor < -child.size[1]) blk: {
            scroll_state.anchor = .from(Index, idx.?.next(context) orelse break :blk);
            scroll_state.offset += child.size[1];
        }
        rdl.place(child.rdl, .{ .offset = .{ 0, cursor } });
        cursor += child.size[1];

        idx = idx.?.next(context);
    }

    var capture_sticky_offset: f32 = 0;
    // disabled for now because it doesn't work right and I'm not sure how to make it work.
    // some kind of you have to look at where items rendered on screen or something
    if (@hasDecl(Index, "parentSticky") and false) blk: {
        var sticky = scroll_state.anchor.as(Index);
        if (scroll_state.offset > 0) break :blk; // we're off the top of the page! no need for stickies
        if (scroll_state.offset < 0) sticky = sticky.next(context) orelse break :blk;
        var i: usize = 0;
        const STICKY_LIMIT = 1;
        while (true) : (i += 1) {
            if (i >= STICKY_LIMIT) break;
            sticky = sticky.parentSticky(context) orelse break;

            // ideally we would call pushLoopValueNoSrc() but to do that first we need to see if we've already rendered
            // this item, and if we have, use it and take it out of the render list instead of rerendering it.
            const child = child_component.call(.{ .caller_id = loop_index.pushLoopValue(@src(), sticky), .constraints = .{
                .available_size = .{ .w = ui.constraints.available_size.w.?, .h = null },
            } }, sticky);

            capture_sticky_offset += child.size[1];
            // TODO: place click observer
            capture_sticky_click_rdl.place(child.rdl, .{ .offset = .{ 0, -capture_sticky_offset } });
        }
    }

    rdl.fill(capture_sticky_reservation, capture_sticky_click_rdl, .{ .offset = .{ 0, capture_sticky_offset } });

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

    var i = index.i;
    for (my_list.*, 0..) |items, j| {
        const sub_i = i % items.len;
        res_str = ui.id.b2.fmt("{s}{s}{s}", .{ res_str, if (j == 0) "" else " ", items[sub_i] });
        i = @divFloor(i, items.len);
    }

    return defaultTextButton(ui.sub(@src()), res_str, null);
}

const FinalWindowInfo = struct {
    slot: RepositionableDrawList.Reservation,
    is_filled: bool = false,
    position: @Vector(2, f32),
    size: @Vector(2, f32),
};

// windows:
// - let's allow their resize to be delayed by one frame. that's kind of required unfortunately.
//   - unless what if we could in this order:
//     - at the beginning of the frame, handle window movement from last frame
//       - we can do this by passing in ikeys to Theme.windowChrome, and handling window movement
//         in a `tick()` fn or on the first `addWindow` call
//     - then, add windows. they have accurate positions already and will be rendered the right size
//     - I think that makes sense

const WindowListInfo = struct {
    start_percent: f32, // first in the list is 0. next is 33%. next is 66%. end.
    child_node: WindowTreeNode,
};
pub const WindowTreeNodeUnion = union(enum) {
    tabs: struct {
        selected_tab: WindowTreeNodeID,
        items: std.ArrayList(WindowTreeNode),
    },
    list: struct {
        direction: enum { x, y },
        items: std.ArrayList(WindowListInfo),
    },
    final: ID,
};
pub const WindowTreeNode = struct {
    id: WindowTreeNodeID,
    value: WindowTreeNodeUnion,
    collapsed: bool,
    fn deinit(self: *WindowTreeNode) void {
        switch (self.value) {
            .final => {},
            .tabs => |*t| {
                for (t.items.items) |*it| it.deinit();
                t.items.deinit();
            },
            .list => |*l| {
                for (l.items.items) |*it| it.child_node.deinit();
                l.items.deinit();
            },
        }
    }
};
pub const WindowTreeNodeID = enum(u64) {
    _,
    var current: u64 = 0;
    pub fn next() WindowTreeNodeID {
        current += 1;
        return @enumFromInt(current);
    }
};
pub const FloatingContainerID = enum(u64) {
    _,
    var current: u64 = 0;
    pub fn next() FloatingContainerID {
        current += 1;
        return @enumFromInt(current);
    }
};
pub const FullscreenOverlayID = enum(u64) {
    _,
    var current: u64 = 0;
    pub fn next() FullscreenOverlayID {
        current += 1;
        return @enumFromInt(current);
    }
};
pub const FloatingWindow = struct {
    id: FloatingContainerID,
    position: @Vector(2, f32),
    size: @Vector(2, f32),
    contents: WindowTreeNode,
};
pub const FullscreenOverlay = struct {
    id: FullscreenOverlayID,
    contents: ID,
};
const WindowIkey = struct {
    ikey: ID, // recommended ID.unique()
    interaction_model: WindowIkeyInteractionModel,
};
pub const WindowIkeyInteractionModel = union(enum) {
    raise: struct { window: FloatingContainerID },
    resize: struct { window: FloatingContainerID, sides: Sides, cursor: Beui.Cursor = .arrow },
    ignore,
};
pub const WindowManager = struct {
    // TARGET:
    // - windows have titles and collapse buttons / close buttons
    // - window chrome is provided by a child component, not default to addWindow
    // - windows support docking. you can dock a window to another window to make it tabbed,
    //   and you can dock a tabbed window to another window to have two layers of tabs

    // currently, WindowManager styles the windows. Ideally, the user would be able to style the
    // windows however they want, maybe with a special WindowCallInfo arg and WindowChild return
    // type. The theme window then has to handle all the styling stuff about the window:
    // - tabs, borders, resizing, ... . Or maybe that isn't possible. And even more ideally,
    //   beui2 exports an unstyled component for the window so it can be styled however you
    //   want without having to reimplement the whole interaction model.

    // future:
    // - eventually this will manage overlay windows too, like context menus
    //   - fn addContextMenu(anchor_pos: RdlPoint, .bottom_right, child: Component())
    //     - child recieves max_width and max_height as the size of the viewport
    //     - then, when rendering, we place it near anchor_pos in the specified direction
    // - if we want the ability to hover over a window to see a preview:
    //   - while hovering, ask for the window to render this frame
    //   - rather than posting the draw list for the hovered window, instead render it
    //     to a small image and save it in the image cache. then render that as the preview.
    //   - that's fun

    b2: *Beui2,
    /// 'dependency injection' so child components can see if they're focused
    current_window: ?ID,

    /// holds pointers so we can store a pointer for <1 frame in WindowIkeyInteractionModel
    floating_containers: std.ArrayList(FloatingWindow),
    fullscreen_overlays: std.ArrayList(FullscreenOverlay),
    windows: IdArrayMap(?FinalWindowInfo),
    this_frame_rdl: ?*RepositionableDrawList,

    ikeys: std.ArrayList(WindowIkey),
    floating_container_ids: ?ID,
    fullscreen_overlay_ids: ?ID,
    window_tree_node_ids: ?ID,

    pub fn init(b2: *Beui2, gpa: std.mem.Allocator) WindowManager {
        // b2 is not initialized yet, so b2.persistent.gpa is undefined
        return .{
            .b2 = b2,
            .windows = .init(gpa),
            .current_window = null,
            .fullscreen_overlays = .init(gpa),
            .floating_containers = .init(gpa),
            .ikeys = .init(gpa),
            .this_frame_rdl = null,
            .floating_container_ids = null,
            .fullscreen_overlay_ids = null,
            .window_tree_node_ids = null,
        };
    }
    pub fn deinit(self: *WindowManager) void {
        self.ikeys.deinit();
        self.fullscreen_overlays.deinit();
        for (self.floating_containers.items) |*item| item.contents.deinit();
        self.floating_containers.deinit();
        self.windows.deinit();
    }

    pub fn idForFloatingContainer(self: *WindowManager, src: std.builtin.SourceLocation, fc: FloatingContainerID) ID {
        return self.floating_container_ids.?.pushLoopValue(src, fc);
    }
    pub fn idForFullscreenOverlay(self: *WindowManager, src: std.builtin.SourceLocation, fc: FullscreenOverlayID) ID {
        return self.fullscreen_overlay_ids.?.pushLoopValue(src, fc);
    }
    pub fn idForWindowTreeNode(self: *WindowManager, src: std.builtin.SourceLocation, fc: WindowTreeNodeID) ID {
        return self.window_tree_node_ids.?.pushLoopValue(src, fc);
    }
    pub fn addIkey(self: *WindowManager, id: ID, model: WindowIkeyInteractionModel) ID {
        self.ikeys.append(.{ .ikey = id, .interaction_model = model }) catch @panic("oom");
        return id;
    }

    fn dealWithItem(self: *WindowManager, item: *WindowTreeNode) void {
        _ = self;
        switch (item.value) {
            .final => |*id| id.* = id.refresh(),
            else => @panic("TODO dealWithItem"),
        }
    }

    // 1. at the start of the frame:
    fn beginFrame(self: *WindowManager, root_id: ID) void {
        self.this_frame_rdl = self.b2.draw();
        self.floating_container_ids = root_id.pushLoop(@src(), FloatingContainerID);
        self.fullscreen_overlay_ids = root_id.pushLoop(@src(), FullscreenOverlayID);
        self.window_tree_node_ids = root_id.pushLoop(@src(), WindowTreeNodeID);

        // 1a. handle interactions from the previous frame
        const b2 = self.b2;
        for (self.ikeys.items) |ikey| {
            switch (ikey.interaction_model) {
                .raise => |im| {
                    if (b2.mouseCaptureResults(ikey.ikey).observed_mouse_down) {
                        self.bringToFrontWindow(im.window);
                    }
                },
                .resize => |im| {
                    if (b2.mouseCaptureResults(ikey.ikey).mouse_left_held) {
                        self.dragWindow(im.window, b2.persistent.beui1.frame.mouse_offset, im.sides);
                    }
                },
                .ignore => {},
            }
        }
        self.ikeys.clearRetainingCapacity();

        // 1b.
        // 1b.i: close windows
        for (self.windows.values()) |*win| {
            if (win.* == null) continue;
            if (win.*.?.is_filled) continue;
            @panic("TODO close window");
        }
        // 1b.ii: unrequest all windows
        for (self.windows.values()) |*win| win.* = null;
        // 1b.iii: refresh ids on all windows
        for (self.windows.keys()) |*k| k.* = k.refresh();
        for (self.fullscreen_overlays.items) |*fc| fc.contents = fc.contents.refresh();
        for (self.floating_containers.items) |*fc| self.dealWithItem(&fc.contents);

        // 1d. fullscreen overlats
        var fsoverlay_i: usize = self.fullscreen_overlays.items.len;
        while (fsoverlay_i > 0) {
            fsoverlay_i -= 1;
            const fc = &self.fullscreen_overlays.items[fsoverlay_i];
            Theme.drawFullscreenOverlay(self, fc);
        }

        // 1c. loop over every window node and draw it using Theme.drawFloatingContainer
        //      (loops in reverse because the last item in floating_containers is the topmost window)
        var container_i: usize = self.floating_containers.items.len;
        while (container_i > 0) {
            container_i -= 1;
            const fc = &self.floating_containers.items[container_i];
            Theme.drawFloatingContainer(self, fc);
        }
    }

    pub fn addFullscreenOverlay(self: *WindowManager, window_id: ID, child: Component(StandardCallInfo, void, *RepositionableDrawList)) void {
        const gpres = self.windows.getOrPut(window_id) catch @panic("oom");
        if (!gpres.found_existing) {
            gpres.value_ptr.* = null;
            self.fullscreen_overlays.append(.{ .id = .next(), .contents = window_id }) catch @panic("oom");
            Theme.drawFullscreenOverlay(self, &self.fullscreen_overlays.items[self.fullscreen_overlays.items.len - 1]);
        }
        if (gpres.value_ptr.* == null) return; // window isn't wanted this frame

        if (gpres.value_ptr.*.?.is_filled) @panic("trying to fill the same window id twice");
        gpres.value_ptr.*.?.is_filled = true;

        const slot: RepositionableDrawList.Reservation = gpres.value_ptr.*.?.slot;

        const prev_window = self.current_window;
        self.current_window = window_id;
        defer self.current_window = prev_window;

        const child_res = child.call(.{
            .caller_id = window_id.sub(@src()),
            .constraints = .{ .available_size = .{ .w = window_id.b2.frame.frame_cfg.size[0], .h = window_id.b2.frame.frame_cfg.size[1] } },
        }, {});
        // child.call() invalidates gpres
        self.this_frame_rdl.?.fill(slot, child_res, .{ .offset = .{ 0, 0 } });
    }

    // 2. during the frame (fn addWindow)
    pub fn addWindow(self: *WindowManager, window_id: ID, title: []const u8, child: Component(StandardCallInfo, void, StandardChild)) void {
        _ = title;
        // 2a. get the window from the map
        const gpres = self.windows.getOrPut(window_id) catch @panic("oom");
        if (!gpres.found_existing) {
            // - oops! this will add to the back of the list! and then it will show up in front next frame. maybe each floating
            //   container gets an rdl and then we order them at the end of the frame.
            gpres.value_ptr.* = null;
            self.floating_containers.append(.{
                .id = .next(),
                .position = .{ 50, 50 },
                .size = .{ 400, 300 },
                .contents = .{
                    .id = .next(),
                    .value = .{ .final = window_id },
                    .collapsed = false,
                },
            }) catch @panic("oom");
            Theme.drawFloatingContainer(self, &self.floating_containers.items[self.floating_containers.items.len - 1]);
        }

        // 2b. if it has no slot, skip it. ie its parent is collapsed
        if (gpres.value_ptr.* == null) return; // window isn't wanted this frame

        // 2c. render it and put the resulting rdl in the map
        if (gpres.value_ptr.*.?.is_filled) @panic("trying to fill the same window id twice");
        gpres.value_ptr.*.?.is_filled = true;

        const slot: RepositionableDrawList.Reservation = gpres.value_ptr.*.?.slot;
        const pos = gpres.value_ptr.*.?.position;
        const size = gpres.value_ptr.*.?.size;

        const prev_window = self.current_window;
        self.current_window = window_id;
        defer self.current_window = prev_window;

        const child_res = child.call(.{
            .caller_id = window_id.sub(@src()),
            .constraints = .{ .available_size = .{ .w = size[0], .h = size[1] } },
        }, {});
        // child.call() invalidates gpres
        self.this_frame_rdl.?.fill(slot, child_res.rdl, .{ .offset = pos });
    }
    fn dragWindow(self: *WindowManager, window_id: FloatingContainerID, offset: @Vector(2, f32), anchors: Sides) void {
        if (@reduce(.And, offset == @Vector(2, f32){ 0, 0 })) return;
        const idx = self.floatingContainerIndex(window_id);
        const window = &self.floating_containers.items[idx];

        var top = window.position[1]; // var left, var top = window.position;
        var left = window.position[0];
        var bottom = window.position[1] + window.size[1]; // var right, var bottom = window.position + window.size;
        var right = window.position[0] + window.size[0];

        if (anchors._top) top += offset[1];
        if (anchors._left) left += offset[0];
        if (anchors._bottom) bottom += offset[1];
        if (anchors._right) right += offset[0];

        window.position = .{ left, top };
        window.size = .{ right - left, bottom - top };
    }
    pub const MEI = struct {
        wm: *WindowManager,
        value: WindowIkeyInteractionModel,
    };
    pub fn makeWindowEventInfo(self: *WindowManager, val: WindowIkeyInteractionModel) *MEI {
        const res = self.b2.frame.arena.create(MEI) catch @panic("oom");
        res.* = .{ .wm = self, .value = val };
        return res;
    }
    pub fn handleWindowEvent(info: *MEI, b2: *Beui2, mev: MouseEvent) ?Beui.Cursor {
        const self = info.wm;
        switch (info.value) {
            .raise => |raise| {
                if (mev.action == .down) {
                    self.bringToFrontWindow(raise.window);
                }
                return null; // allow event to pass through
            },
            .resize => |resize| {
                if (mev.action == .move_while_down or mev.action == .up) {
                    self.dragWindow(resize.window, b2.persistent.beui1.frame.mouse_offset, resize.sides);
                }
                return resize.cursor; // capture
            },
            .ignore => {
                return .arrow; // capture
            },
        }
    }
    fn isInFront(self: *WindowManager, window_id: FloatingContainerID) bool {
        return self.floating_containers.items[self.floating_containers.items.len - 1].id == window_id;
    }
    fn bringToFrontWindow(self: *WindowManager, window_id: FloatingContainerID) void {
        if (self.isInFront(window_id)) return;
        const idx = self.floatingContainerIndex(window_id);
        const floating_container = self.floating_containers.orderedRemove(idx);
        self.floating_containers.appendAssumeCapacity(floating_container);
    }

    fn floatingContainerIndex(self: *WindowManager, id: FloatingContainerID) usize {
        for (self.floating_containers.items, 0..) |itm, i| {
            if (itm.id == id) return i;
        }
        unreachable;
    }

    fn render(self: *WindowManager) *RepositionableDrawList {
        defer self.floating_container_ids = null;
        defer self.fullscreen_overlay_ids = null;
        defer self.this_frame_rdl = null;
        self.this_frame_rdl.?.addRect(.{
            .pos = .{ 0, 0 },
            .size = self.b2.frame.frame_cfg.size,
            .tint = .fromHexRgb(0x2e2e2e),
        });
        return self.this_frame_rdl.?;
    }
};

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

test "state2" {
    const gpa = std.testing.allocator;

    const BeuiVtable = struct {
        fn setClipboard(_: *const Beui.FrameCfg, _: [:0]const u8) void {
            std.log.info("TODO setClipboard", .{});
        }
        fn getClipboard(_: *const Beui.FrameCfg, _: *std.ArrayList(u8)) void {
            std.log.info("TODO getClipboard", .{});
        }
        pub const vtable: *const Beui.FrameCfgVtable = &.{
            .type_id = @typeName(@This()),
            .set_clipboard = &setClipboard,
            .get_clipboard = &getClipboard,
        };
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var b1: Beui = .{};

    var b2: Beui2 = undefined;
    b2.init(&b1, gpa);
    defer b2.deinit();

    var draw_list: Beui.draw_lists.RenderList = .init(gpa);
    defer draw_list.deinit();

    {
        draw_list.clear();
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();

        var beui_vtable: BeuiVtable = .{};
        b1.newFrame(.{
            .arena = arena,
            .now_ms = std.time.milliTimestamp(),
            .user_data = @ptrCast(@alignCast(&beui_vtable)),
            .vtable = BeuiVtable.vtable,
        });
        defer b1.endFrame();

        const id = b2.newFrame(.{ .size = .{ 1000, 500 } });
        {
            const root_id = id.sub(@src());
            _ = root_id;
        }
        b2.endFrame(&draw_list);
    }

    // TODO: test state2
    // TODO: clean up beui setup, what a mess!
}
