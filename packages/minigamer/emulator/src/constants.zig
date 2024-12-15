const std = @import("std");

pub const EMU_MEM_SIZE = 2097152; // 2MB

// we'll have to see how this feels and adjust it
pub const EMU_INSTRUCTIONS_PER_FRAME = 1024 * 128; // * 60 = ~7.8MHz, or 131k instr / frame

pub const EMU_SCREEN_W = 120;
pub const EMU_SCREEN_H = 120;
pub const EMU_SCREEN_NCHANNELS = 4;
pub const EMU_SCREEN_DATA_SIZE_U32 = EMU_SCREEN_W * EMU_SCREEN_H;
pub const EMU_SCREEN_DATA_SIZE = EMU_SCREEN_W * EMU_SCREEN_H * EMU_SCREEN_NCHANNELS;
pub const EMU_SCREEN_NLAYERS = 4;
pub const EMU_GPU_MAX_IMAGES = 128;

// arrows + zxc don't map well to wasd + space & mouse buttons.
// console controls also apparently aren't defined very well - jump
// is either primary or secondary depending on the game, whereas
// it's always space on kb/m
pub const BUTTON_UP = 1 << 0; // W | Up
pub const BUTTON_RIGHT = 1 << 1; // D | Right
pub const BUTTON_DOWN = 1 << 2; // S | Down
pub const BUTTON_LEFT = 1 << 3; // A | Left
pub const BUTTON_INTERACT = 1 << 4; // E | Z
pub const BUTTON_JUMP = 1 << 5; // Space | X
pub const BUTTON_MENU = 1 << 6; // Escape | C

pub fn color3(r: u8, g: u8, b: u8) u32 {
    return color4(r, g, b, 255);
}
pub fn color4(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | (@as(u32, r) << 0);
}
pub fn colToSplitCol(color: u32) @Vector(4, u8) {
    return @bitCast(color);
}
pub fn splitColToCol(color: @Vector(4, u8)) u32 {
    return @bitCast(color);
}
const preferred_float = switch (@import("builtin").target.cpu.model) {
    &std.Target.arm.cpu.mpcore => f32,
    else => f32,
};
pub fn splitColToFloat(color: @Vector(4, u8)) @Vector(4, preferred_float) {
    const res: @Vector(4, preferred_float) = .{ @floatFromInt(color[0]), @floatFromInt(color[1]), @floatFromInt(color[2]), @floatFromInt(color[3]) };
    return res / @Vector(4, preferred_float){ 255, 255, 255, 255 };
}
pub fn floatToSplitCol(color: @Vector(4, preferred_float)) @Vector(4, u8) {
    const res_f: @Vector(4, preferred_float) = color * @as(@Vector(4, preferred_float), @splat(255));
    return .{
        std.math.lossyCast(u8, res_f[0]),
        std.math.lossyCast(u8, res_f[1]),
        std.math.lossyCast(u8, res_f[2]),
        std.math.lossyCast(u8, res_f[3]),
    };
}
pub fn blendModeAlpha(prev_color: u32, next_color: u32) u32 {
    // doing this float math on 3ds is slow
    if (@import("builtin").target.cpu.model == &std.Target.arm.cpu.mpcore) {
        return blendModeCutout(prev_color, next_color);
    }

    const Col3 = @Vector(3, preferred_float);
    const a = splitColToFloat(colToSplitCol(prev_color));
    const b = splitColToFloat(colToSplitCol(next_color));

    const a_rgb: @Vector(3, preferred_float) = .{ a[0], a[1], a[2] };
    const b_rgb: @Vector(3, preferred_float) = .{ b[0], b[1], b[2] };

    // Calculate the output alpha
    const out_alpha = b[3] + a[3] * (1.0 - b[3]);

    // Ensure proper blending of RGB components using the alpha values
    const out_color = (b_rgb * @as(Col3, @splat(b[3])) + a_rgb * @as(Col3, @splat(a[3] * (1.0 - b[3]))));

    // Combine the RGB and alpha back into a single color
    return splitColToCol(floatToSplitCol(.{ out_color[0], out_color[1], out_color[2], out_alpha }));
}
pub fn blendModeCutout(prev_color: u32, next_color: u32) u32 {
    const b = colToSplitCol(next_color);

    if (b[3] > 128) return next_color;
    return prev_color;
}

pub const SYS = enum(usize) {
    none = 0,
    exit = 2,
    print_append = 1,
    print_flush = 3,
    wait_for_next_frame = 4,
    get_buttons = 8,
    get_mouse = 7,

    gpu_draw_image = 5,
    gpu_set_layer_offset = 9,
    gpu_set_background_color = 10,

    _,
};

pub const DrawImageCmd = extern struct {
    dest: extern struct {
        layer: u32,
        pos: [2]i32,
    },
    src: extern struct {
        stride: u32,
        size: [2]i32,
        remap_colors: [8]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7 },
    },
    flags: extern struct {
        alpha_mode: DrawImageCmdAlphaMode,
    },
};

pub const DrawImageCmdAlphaMode = enum(u8) {
    replace = 0,
    cutout = 1,
    alpha = 2,
    _,
    // src_alpha_one_minus_src_alpha = 1,
};
