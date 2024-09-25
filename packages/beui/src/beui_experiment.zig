const std = @import("std");

const Beui = @import("Beui.zig");
const render_list = @import("render_list.zig");

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

const Constraints = struct {};
const Scroller = struct {
    // fn child() will call some kind of preserveIdTree fn on the id it recieves
    // same with fn virtual()
    // because we don't want to lose state when a child isn't rendered

    draw_list: *RepositionableDrawList,
    cursor: i32,

    pub fn child(scroller: *Scroller, caller_id: ID, b2: *Beui2) ?ChildFill {
        b2.pushScope(caller_id, @src());

        return .{ .scroller = scroller, .b2 = b2 };
    }
    const ChildFill = struct {
        scroller: *Scroller,
        b2: *Beui2,
        pub fn end(self: ChildFill, value: ScrollerChild) void {
            self.b2.popScope();
            self.scroller.draw_list.place(value.rdl, .{ 25, 25 });
            self.scroller.cursor += value.height;
        }
    };
    pub fn virtual(scroller: *Scroller, caller_id: ID, b2: *Beui2, ctx: anytype, comptime Anchor: type) VirtualIter(@TypeOf(ctx), Anchor) {
        b2.pushScope(caller_id, @src());
        b2.pushLoop(Anchor);

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
                self.b2.pushLoopIndex(self.pos.?);
                defer self.pos = Anchor.next(self.ctx, self.pos.?);
                return .{ .scroller = self.scroller, .b2 = self.b2 };
            }
            const VirtualFill = struct {
                scroller: *Scroller,
                b2: *Beui2,
                pub fn end(self: VirtualFill, value: ScrollerChild) void {
                    self.b2.popLoopIndex();
                    self.scroller.draw_list.place(value.rdl, .{ 25, 25 });
                    self.scroller.cursor += value.height;
                }
            };
            pub fn deinit(self: *@This()) void {
                self.b2.popLoop();
                self.b2.popScope();
            }
        };
    }

    pub fn end(self: *Scroller) *RepositionableDrawList {
        return self.draw_list;
    }
};
fn textDemo(
    caller_id: ID,
    b2: *Beui2,
    text: []const u8,
    constraints: ScrollerConstraints,
) ScrollerChild {
    b2.pushScope(caller_id, @src());
    defer b2.popScope();

    const draw = b2.draw();

    draw.addRect(.{
        .pos = .{ 0, 0 },
        .size = .{ @floatFromInt(constraints.width), 10 },
        .tint = .fromHexRgb(0x0000FF),
    });

    _ = text;

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

fn scrollDemo(caller_id: ID, b2: *Beui2, constraints: Constraints) *RepositionableDrawList {
    b2.pushScope(caller_id, @src());
    defer b2.popScope();

    var scroller = Scroller.begin(b2, constraints);

    if (scroller.child(b2.id(@src()), b2)) |c| {
        c.end(textDemo(b2.id(@src()), b2, "hello", c.constraints));
    }
    if (scroller.child(b2.id(@src()), b2)) |c| {
        c.end(textDemo(b2.id(@src()), b2, "world", c.constraints));
    }
    const my_list = &[_][]const u8{ "1", "2", "3" };

    {
        var virtual = scroller.virtual(b2.id(@src()), b2, my_list.len, ListIndex);
        defer virtual.end();
        while (virtual.next()) |c| {
            c.end(textDemo(b2.id(@src()), b2, my_list[c.v.i]), c.constraints);
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
