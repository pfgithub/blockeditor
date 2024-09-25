const std = @import("std");

const Beui = @import("Beui.zig");
const render_list = @import("render_list.zig");

// if we would like to be able to reposition results, we can do that just fine as long as we
// have consistent ids! to recieve mouse events, an object draws a rectangle to the
// event_draw_list, which is repositioned and next frame it recieves events
// - this introduces one frame of delay from when an item is first rendered and when
//   it can know where the mouse is. and if a node is moving every frame, there's
//   a frame of extra lag for the mouse position it knows. otherwise, it introduces
//   no delay.

// as long as we have consistent ids, we have everything
// repositioning just costs loopoing over the results after we're done with them

const Beui2FrameCfg = struct {};
const Beui2Frame = struct {
    arena: std.mem.Allocator,
    frame_cfg: Beui2FrameCfg,
};
const Beui2Persistent = struct {
    gpa: std.mem.Allocator,
    arena_backing: std.heap.ArenaAllocator,
    id_scopes: std.ArrayList(IDSegment),
};
pub const Beui2 = struct {
    frame: Beui2Frame,
    persistent: Beui2Persistent,

    pub fn init(gpa: std.mem.Allocator) Beui2 {
        return .{
            .frame = undefined,
            .persistent = .{ .gpa = gpa, .arena_backing = .init(gpa), .id_scopes = .init(gpa) },
        };
    }
    pub fn deinit(self: *Beui2) void {
        self.persistent.arena_backing.deinit();
        self.persistent.id_scopes.deinit();
    }

    pub fn newFrame(self: *Beui2, frame_cfg: Beui2FrameCfg) void {
        if (self.persistent.id_scopes.items.len != 0) @panic("not all scopes were popped last frame. maybe missing popScope()?");
        _ = self.persistent.arena_backing.reset(.retain_capacity);
        self.frame = .{
            .arena = self.persistent.arena_backing.allocator(),
            .frame_cfg = frame_cfg,
        };
    }

    pub fn draw(self: *Beui2) *RepositionableDrawList {
        const res = self.frame.arena.create(RepositionableDrawList) catch @panic("oom");
        res.* = .{ .b2 = self, .content = .init(self.frame.arena) }; // not the best to use an arena for an arraylist
        return res;
    }

    pub fn mouseCaptureResults(self: *Beui2, capture_id: ID) MouseCaptureResults {
        _ = self;
        _ = capture_id;
        return .{ .mouse_left_held = false };
    }
    pub fn pushScope(self: *Beui2, caller_id: ID, src: std.builtin.SourceLocation) void {
        if (caller_id.str.len != self.persistent.id_scopes.items.len + 1) @panic("bad caller id");
        self.persistent.id_scopes.append(caller_id.str[caller_id.str.len - 1]) catch @panic("oom");
        self.persistent.id_scopes.append(.fromSrc(src)) catch @panic("oom");
    }
    pub fn popScope(self: *Beui2) void {
        _ = self.persistent.id_scopes.popOrNull() orelse @panic("popScope() called without matching pushScope");
        _ = self.persistent.id_scopes.popOrNull() orelse @panic("popScope() called without matching pushScope");
    }

    pub fn rootID(self: *Beui2, src: std.builtin.SourceLocation) ID {
        return .{ .str = self.frame.arena.dupe(IDSegment, &.{.fromSrc(src)}) catch @panic("oom") };
    }

    pub fn id(self: *Beui2, src: std.builtin.SourceLocation) ID {
        const seg: IDSegment = .fromSrc(src);
        const emsg = "pushScope has not been called for this function. last called for: {s}";
        const last_scope = self.persistent.id_scopes.getLastOrNull() orelse @panic(self.fmt(emsg, .{"never called. for first id must use .rootID()"}));
        if (last_scope.fn_name != seg.fn_name) @panic(self.fmt(emsg, .{std.mem.span(last_scope.fn_name)}));

        const result_buf = self.frame.arena.alloc(IDSegment, self.persistent.id_scopes.items.len + 1) catch @panic("oom");
        @memcpy(result_buf[0..self.persistent.id_scopes.items.len], self.persistent.id_scopes.items);
        result_buf[self.persistent.id_scopes.items.len] = seg;

        return .{ .str = result_buf };
    }

    pub fn fmt(self: *Beui2, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.frame.arena, format, args) catch @panic("oom");
    }
};

pub const MouseCaptureResults = struct {
    mouse_left_held: bool,
};

pub fn demo1(caller_id: ID, b2: *Beui2) *RepositionableDrawList {
    b2.pushScope(caller_id, @src());
    defer b2.popScope();

    const result = b2.draw();

    result.place(demo0(b2.id(@src()), b2), .{ 25, 25 });

    return result;
}

fn demo0(caller_id: ID, b2: *Beui2) *RepositionableDrawList {
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

const IDSegment = struct {
    filename: [*:0]const u8,
    fn_name: [*:0]const u8,
    line: u32,
    col: u32,

    pub fn fromSrc(src: std.builtin.SourceLocation) IDSegment {
        return .{ .filename = src.file.ptr, .fn_name = src.fn_name.ptr, .line = src.line, .col = src.column };
    }
};
const ID = struct {
    str: []const IDSegment,
};

const MouseEventEntry = struct {
    id: ID,
    pos: @Vector(2, i32),
    size: @Vector(2, i32),
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
        },
        embed: struct {
            child: *RepositionableDrawList,
            offset: @Vector(2, i32),
        },
    };
    b2: *Beui2,
    content: std.ArrayList(RepositionableDrawChild),
    pub fn place(self: *RepositionableDrawList, child: *RepositionableDrawList, offset_pos: @Vector(2, i32)) void {
        self.content.append(.{ .embed = .{ .child = child, .offset = offset_pos } }) catch @panic("oom");
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
    pub fn addMouseEventCapture(self: *RepositionableDrawList, id: ID, pos: @Vector(2, i32), size: @Vector(2, i32)) void {
        self.content.append(.{ .mouse = .{ .pos = pos, .size = size, .id = id } }) catch @panic("oom");
    }

    pub fn finalize(self: *RepositionableDrawList, out_list: ?*render_list.RenderList, out_events: ?*std.ArrayList(MouseEventEntry), offset_pos: @Vector(2, i32)) void {
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
                    }) catch @panic("oom");
                },
                .embed => |eev| {
                    eev.child.finalize(out_list, out_events, offset_pos + eev.offset);
                },
            }
        }
    }
};
