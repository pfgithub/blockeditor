const std = @import("std");

pub const RenderListImage = enum(u64) {_};
pub const RenderListItem = struct {
    pos1: @Vector(2, f32),
    pos2: @Vector(2, f32),
    uv1: @Vector(2, f32),
    uv2: @Vector(2, f32),
    img: RenderListImage,
    tint: @Vector(4, f32),
    // TODO: rounding, shadow
};

// render lists are collapsed into groups of MAX_ITEMS of only one image
// later, we can implement tiling

pub const RenderList = struct {
    list: std.ArrayList(RenderListItem),
};