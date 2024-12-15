const std = @import("std");
const constants = @import("constants.zig");

// rather than writing to layers, the gpu could write to regular memory
// and layers could just be in regular memory

pub const GPULayer = struct {
    offset: @Vector(2, i8),
    image: [constants.EMU_SCREEN_DATA_SIZE_U32]u32,
    colors: [16]u32, // 16 or 8? 16 is a lot. we could even go down to 4?
    // note that the colors can have alpha - between layers the image is alpha blended
};
pub const GPU = struct {
    image_count: usize = 0,
    layers: [constants.EMU_SCREEN_NLAYERS]GPULayer = std.mem.zeroes([constants.EMU_SCREEN_NLAYERS]GPULayer),
    background_color: u32 = 0xFF_000000,

    pub fn clear(self: *GPU) void {
        self.* = .{};
    }

    pub fn postImage(self: *GPU, layer: u32, image: []u32, stride: u32) void {
        const buf = &self.layers[layer].image;
        for (0..constants.EMU_SCREEN_H) |y| {
            const base_out = y * constants.EMU_SCREEN_W;
            const base_in = y * stride;
            for (0..constants.EMU_SCREEN_W) |x| {
                buf[base_out + x] = image[base_in + x];
            }
        }
    }

    pub fn drawImage(self: *GPU, cmd: *const constants.DrawImageCmd, img: []const u32) void {
        switch (cmd.flags.alpha_mode) {
            .replace => return self.drawImageWithMode(cmd, img, .replace),
            .cutout => return self.drawImageWithMode(cmd, img, .cutout),
            .alpha => return self.drawImageWithMode(cmd, img, .alpha),
            else => {
                // bad draw mode
            },
        }
        // switch {inline else => |mode| drawImageMode(self, cmd, img, mode)}
        // comptime alpha_mode: AlphaMode
    }
    fn drawImageWithMode(self: *GPU, cmd: *const constants.DrawImageCmd, img: []const u32, comptime mode: constants.DrawImageCmdAlphaMode) void {
        const dest_pos_in = @Vector(2, i32){ cmd.dest.pos[0], cmd.dest.pos[1] };
        const src_size_in = @Vector(2, i32){ cmd.src.size[0], cmd.src.size[1] };

        const dest_pos_ul = @min(@max(dest_pos_in, @Vector(2, i32){ 0, 0 }), @Vector(2, i32){ constants.EMU_SCREEN_W, constants.EMU_SCREEN_H });
        const dest_pos_br = @max(@min(@max(dest_pos_in + src_size_in, @Vector(2, i32){ 0, 0 }), @Vector(2, i32){ constants.EMU_SCREEN_W, constants.EMU_SCREEN_H }), dest_pos_ul);
        const src_pos_ul = dest_pos_ul - dest_pos_in;

        const dest_size = dest_pos_br - dest_pos_ul;
        var idx_dest: usize = std.math.cast(usize, dest_pos_ul[1] * @as(i32, constants.EMU_SCREEN_W) + dest_pos_ul[0]) orelse return; // @as(i32) works around a miscompilation
        var idx_src: usize = std.math.cast(usize, src_pos_ul[1] * @as(i32, @intCast(cmd.src.stride)) + src_pos_ul[0]) orelse return;

        const out_layer = &self.layers[cmd.dest.layer].image;

        for (0..@intCast(dest_size[1])) |_| {
            var dsub = idx_dest;
            var ssub = idx_src;
            for (0..@intCast(dest_size[0])) |_| {
                const res_col = switch (mode) {
                    .replace => img[ssub],
                    .alpha => constants.blendModeAlpha(out_layer[dsub], img[ssub]),
                    .cutout => constants.blendModeCutout(out_layer[dsub], img[ssub]),
                    else => @compileError("?"),
                };
                out_layer[dsub] = res_col;
                dsub += 1;
                ssub += 1;
            }

            idx_dest += constants.EMU_SCREEN_W;
            idx_src += @intCast(cmd.src.stride);
        }
    }

    // offset range is [-0.5 .. 0.5], default is 0
    // -128 = 0.5, 128 = 0.5 (127 is the max, so that equals like 0.499 or something)
    pub fn setLayerOffset(self: *GPU, layer_i: u32, offset_x: i8, offset_y: i8) void {
        const layer = &self.layers[layer_i];
        layer.offset = .{ offset_x, offset_y };
    }
    pub fn setLayerColors(self: *GPU, layer_i: u32, colors: *const [16]u32) void {
        self.layers[layer_i].colors = colors.*;
    }
};

const ImageFormat = enum {
    img_1bpp,
    img_2bpp,
};
