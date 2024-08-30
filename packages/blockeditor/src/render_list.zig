const std = @import("std");

// TODO:
// - the whole result should end up in one vertex and index buffer.
// - we should have three arrays:
// - vertices, indices, segments. segments contains subarrays of
//   (vertices[start, end], indices[start, end], and ?RenderListImage)
// - that way we copy one vertex array and then draw repeatedly from
//   different parts of the vertex array

pub const RenderListImage = enum(u64) { _ };
pub const RenderListIndex = u16;
pub const RenderListVertex = struct {
    pos: @Vector(2, f32),
    uv: @Vector(2, f32),
    tint: @Vector(4, f32),
    // TODO: rounding, shadow
};

pub const RenderList = struct {
    gpa: std.mem.Allocator,
    sub_lists: std.ArrayList(RenderListSegment),
    pub fn init(gpa: std.mem.Allocator) RenderList {
        return .{
            .gpa = gpa,
            .sub_lists = std.ArrayList(RenderListSegment).init(gpa),
        };
    }
    pub fn deinit(self: *RenderList) void {
        for (self.sub_lists.items) |*item| item.deinit();
        self.sub_lists.deinit();
    }
    pub fn clear(self: *RenderList) void {
        for (self.sub_lists.items) |*item| item.deinit();
        self.sub_lists.clearRetainingCapacity();
    }

    fn getSub(self: *RenderList, image: ?RenderListImage, min_remaining_vertices: usize) *RenderListSegment {
        // empty case: create new sublist
        if (self.sub_lists.items.len == 0) {
            return self.addSub(image);
        }
        const last = &self.sub_lists.items[self.sub_lists.items.len - 1];
        // last item does not have enough remaining indices to hold new vertices case: create new sublist
        if (last.vertices.items.len + min_remaining_vertices > std.math.maxInt(RenderListIndex)) {
            return self.addSub(image);
        }
        // last item does not have an image assigned yet: assign image
        if (last.image == null) {
            last.image = image;
            return last;
        }
        // last item has an image assigned, but it is not the right image: create new sublist
        if (image != null and last.image.? != image.?) {
            return self.addSub(image);
        }
        // last image has an image assigned and it is the right image
        return last;
    }
    fn addSub(self: *RenderList, image: ?RenderListImage) *RenderListSegment {
        self.sub_lists.append(RenderListSegment.init(self.gpa, image)) catch @panic("oom");
        return &self.sub_lists.items[self.sub_lists.items.len - 1];
    }
    fn addVertices(self: *RenderList, image: ?RenderListImage, vertices: []const RenderListVertex, indices: []const RenderListIndex) void {
        var sub = self.getSub(image, vertices.len);

        const prev_vertices_len: u16 = @intCast(sub.vertices.items.len); // vertices len can never be larger than (maxInt(u16) - vertices.len)
        sub.vertices.appendSlice(vertices) catch @panic("oom");
        sub.indices.ensureUnusedCapacity(indices.len) catch @panic("oom");
        for (indices) |index| {
            std.debug.assert(index < vertices.len);
            sub.indices.appendAssumeCapacity(prev_vertices_len + index);
        }
    }

    pub fn addRect(self: *RenderList, pos: @Vector(2, f32), size: @Vector(2, f32), opts: struct {
        uv_pos: @Vector(2, f32) = .{ 0, 0 },
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
};
pub const RenderListSegment = struct {
    vertices: std.ArrayList(RenderListVertex),
    indices: std.ArrayList(RenderListIndex),
    image: ?RenderListImage,

    pub fn init(gpa: std.mem.Allocator, image: ?RenderListImage) RenderListSegment {
        return .{
            .vertices = std.ArrayList(RenderListVertex).init(gpa),
            .indices = std.ArrayList(RenderListIndex).init(gpa),
            .image = image,
        };
    }
    pub fn deinit(self: *RenderListSegment) void {
        self.vertices.deinit();
        self.indices.deinit();
    }
};
