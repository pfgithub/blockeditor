const std = @import("std");

// TODO:
// - the whole result should end up in one vertex and index buffer.
// - we should have three arrays:
// - vertices, indices, segments. segments contains subarrays of
//   (vertices[start, end], indices[start, end], and ?RenderListImage)
// - that way we copy one vertex array and then draw repeatedly from
//   different parts of the vertex array

// we could, if everything is a rectangle, just have 6 vertices
// and do everything with instanced draw calls
// probably saves on some bytes, who knows if it's faster though.

pub const RenderListImage = enum(u64) {
    beui_font,
    _,
};
pub const RenderListIndex = u16;
pub const RenderListVertex = struct {
    pos: @Vector(2, f32),
    uv: @Vector(2, f32),
    tint: @Vector(4, f32),
    // TODO: rounding, shadow
};
pub const RenderListCommand = struct {
    vertex_count: usize, // internal only, wgpu doesn't care
    index_count: u32,
    first_index: u32,
    base_vertex: i32, // not sure if this is what I think it is
    image: ?RenderListImage,
};

pub const RenderList = struct {
    gpa: std.mem.Allocator,
    vertices: std.ArrayList(RenderListVertex),
    indices: std.ArrayList(RenderListIndex),
    commands: std.ArrayList(RenderListCommand),

    pub fn init(gpa: std.mem.Allocator) RenderList {
        return .{
            .gpa = gpa,
            .vertices = .init(gpa),
            .indices = .init(gpa),
            .commands = .init(gpa),
        };
    }
    pub fn deinit(self: *RenderList) void {
        self.vertices.deinit();
        self.indices.deinit();
        self.commands.deinit();
    }
    pub fn clear(self: *RenderList) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.commands.clearRetainingCapacity();
    }

    fn getCmd(self: *RenderList, image: ?RenderListImage, min_remaining_vertices: usize) *RenderListCommand {
        // empty case: create a new command
        if (self.commands.items.len == 0) {
            return self.addCmd(image);
        }
        const last = &self.commands.items[self.commands.items.len - 1];
        // last item does not have enough remaining indices to hold new vertices case: create new sublist
        if (last.vertex_count + min_remaining_vertices > std.math.maxInt(RenderListIndex)) {
            return self.addCmd(image);
        }
        // last item does not have an image assigned yet: assign image
        if (last.image == null) {
            last.image = image;
            return last;
        }
        // last item has an image assigned, but it is not the right image: create new sublist
        if (image != null and last.image.? != image.?) {
            return self.addCmd(image);
        }
        // last image has an image assigned and it is the right image
        return last;
    }
    fn addCmd(self: *RenderList, image: ?RenderListImage) *RenderListCommand {
        self.commands.append(.{
            .vertex_count = 0,
            .index_count = 0,
            .first_index = @intCast(self.indices.items.len),
            .base_vertex = @intCast(self.vertices.items.len), // not sure if this usage is right?
            .image = image,
        }) catch @panic("oom");
        return &self.commands.items[self.commands.items.len - 1];
    }

    fn addVertices(self: *RenderList, image: ?RenderListImage, vertices: []const RenderListVertex, indices: []const RenderListIndex) void {
        var cmd = self.getCmd(image, vertices.len);

        const prev_vertices_len: u16 = @intCast(cmd.vertex_count); // vertices len can never be larger than (maxInt(u16) - vertices.len)
        self.vertices.appendSlice(vertices) catch @panic("oom");
        self.indices.ensureUnusedCapacity(indices.len) catch @panic("oom");
        for (indices) |index| {
            std.debug.assert(index < vertices.len);
            self.indices.appendAssumeCapacity(prev_vertices_len + index);
        }
        cmd.vertex_count += vertices.len;
        cmd.index_count += @intCast(indices.len);
    }

    pub fn addRect(self: *RenderList, pos: @Vector(2, f32), size: @Vector(2, f32), opts: struct {
        uv_pos: @Vector(2, f32) = .{ -1234.0, -1234.0 },
        uv_size: @Vector(2, f32) = .{ 0, 0 },
        image: ?RenderListImage = null,
        tint: @Vector(4, f32) = .{ 1, 1, 1, 1 },
    }) void {
        // have to go clockwise to not get culled
        const ul = pos;
        const ur = pos + @Vector(2, f32){ size[0], 0 };
        const bl = pos + @Vector(2, f32){ 0, size[1] };
        const br = pos + size;

        const uv_ul = opts.uv_pos;
        const uv_ur = opts.uv_pos + @Vector(2, f32){ opts.uv_size[0], 0 };
        const uv_bl = opts.uv_pos + @Vector(2, f32){ 0, opts.uv_size[1] };
        const uv_br = opts.uv_pos + opts.uv_size;

        self.addVertices(null, &.{
            .{ .pos = ul, .uv = uv_ul, .tint = opts.tint },
            .{ .pos = ur, .uv = uv_ur, .tint = opts.tint },
            .{ .pos = bl, .uv = uv_bl, .tint = opts.tint },
            .{ .pos = br, .uv = uv_br, .tint = opts.tint },
        }, &.{
            0, 1, 3,
            0, 3, 2,
        });
    }

    pub fn addChar(self: *RenderList, char: u8, pos: @Vector(2, f32), color: @Vector(4, f32)) void {
        const conv: @Vector(2, u4) = @bitCast(char);
        const tile_id: @Vector(2, f32) = .{ @floatFromInt(conv[0]), @floatFromInt(conv[1]) };
        const tile_pos: @Vector(2, f32) = tile_id * @Vector(2, f32){ 6, 10 } + @Vector(2, f32){ 1, 1 };
        const tile_size: @Vector(2, f32) = .{ 5, 9 };
        const font_size: @Vector(2, f32) = .{ 256, 256 };
        const tile_uv_pos = tile_pos / font_size;
        const tile_uv_size = tile_size / font_size;
        self.addRect(pos, tile_size, .{
            .uv_pos = tile_uv_pos,
            .uv_size = tile_uv_size,
            .image = .beui_font,
            .tint = color,
        });
    }
    pub fn getCharAdvance(self: *RenderList, char: u8) f32 {
        _ = self;
        _ = char;
        return 6;
    }
    pub fn getCharHeight(self: *RenderList) f32 {
        _ = self;
        return 10;
    }
};
