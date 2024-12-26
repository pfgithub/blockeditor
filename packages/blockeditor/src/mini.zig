const std = @import("std");
const Beui = @import("beui").Beui;
const B2 = Beui.beui_experiment;

const emu = @import("minigamer");
const sponge_cart = @embedFile("sponge.cart");
const util = @import("anywhere").util;

const OffsetsOut = [emu.constants.EMU_SCREEN_NLAYERS]@Vector(2, i8);
const State = struct {
    gpa: std.mem.Allocator,
    val: emu.Emu,
    frame_out: *B2.ImageCache.Image,
    offsets_out: *OffsetsOut,
    bg_color_out: u32,

    pub fn init(self: *State, gpa: std.mem.Allocator) void {
        self.* = .{
            .gpa = gpa,
            .val = .init(),
            .frame_out = B2.ImageCache.Image.create(gpa, .{ emu.constants.EMU_SCREEN_W, emu.constants.EMU_SCREEN_H * emu.constants.EMU_SCREEN_NLAYERS }, .rgba),
            .offsets_out = gpa.create(OffsetsOut) catch @panic("oom"),
            .bg_color_out = 0,
        };
        self.val.loadProgram(gpa, sponge_cart) catch |e| {
            std.log.err("progarm failed to load: {s}", .{@errorName(e)});
        };
    }
    pub fn deinit(self: *State) void {
        self.gpa.destroy(self.offsets_out);
        self.frame_out.destroy(self.gpa);
        if (self.val.program != null) self.val.unloadProgram(self.gpa);
        self.val.deinit(); // this doesn't even do anything?
    }
};

pub fn render(_: *const void, call_info: B2.StandardCallInfo, _: void) *B2.RepositionableDrawList {
    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    const size: @Vector(2, f32) = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? };

    const state = ui.id.b2.state2(ui.id.sub(@src()), ui.id.b2.persistent.gpa, State);

    if (state.val.program == null) return rdl;

    state.val.simulate(.{
        .time_ms = @bitCast(ui.id.b2.persistent.beui1.frame.frame_cfg.?.now_ms),
        .buttons = .{
            .up = ui.id.b2.persistent.beui1.isKeyHeld(.up),
            .left = ui.id.b2.persistent.beui1.isKeyHeld(.left),
            .down = ui.id.b2.persistent.beui1.isKeyHeld(.down),
            .right = ui.id.b2.persistent.beui1.isKeyHeld(.right),
            .interact = ui.id.b2.persistent.beui1.isKeyHeld(.z),
            .jump = ui.id.b2.persistent.beui1.isKeyHeld(.x),
            .menu = ui.id.b2.persistent.beui1.isKeyHeld(.c),
        },
        .mouse = null, // TODO
    }, .{
        .frame = std.mem.bytesAsSlice(u32, state.frame_out.mutate())[0 .. emu.constants.EMU_SCREEN_DATA_SIZE_U32 * emu.constants.EMU_SCREEN_NLAYERS],
        .layer_offsets = state.offsets_out,
        .background_color = &state.bg_color_out,
    });

    const allow_non_integer = false; // if we want this we need to use pixel art scaling in the shader (only interpolates at the edges between pixels)
    const min_axis = @min(size[0], size[1]);
    var max_scale: f32 = min_axis / @as(f32, emu.constants.EMU_SCREEN_W);
    if (!allow_non_integer and max_scale >= 1.0) max_scale = @floor(max_scale);
    const scale: @Vector(2, f32) = @splat(max_scale * emu.constants.EMU_SCREEN_W);
    const center = (size - scale) / @as(@Vector(2, f32), @splat(2));

    // TODO clip a full pixel in from every edge

    const clipped = ui.id.b2.draw();

    const uv = ui.id.b2.persistent.image_cache.getImageUVOnRenderFromRdl(state.frame_out);
    for (&[_]f32{ 3.0, 2.0, 1.0, 0.0 }, &[_]usize{ 3, 2, 1, 0 }) |offset, i| {
        // offset is i8 from -128 to 127. convert to [-0.5, 0.5)
        var offset_vec: @Vector(2, f32) = @floatFromInt(state.offsets_out[i]);
        offset_vec /= @splat(256);

        clipped.addRect(.{
            .pos = center + offset_vec * @as(@Vector(2, f32), @splat(max_scale)),
            .size = scale,
            .uv_pos = uv.pos + uv.size * @Vector(2, f32){ 0.0, offset / 4.0 },
            .uv_size = uv.size * @Vector(2, f32){ 1.0, 1.0 / 4.0 },
            .image = .rgba,
        });
    }
    const V2 = @Vector(2, f32);
    rdl.addClip(clipped, .{
        .pos = center + @as(V2, @splat(1)) * @as(V2, @splat(max_scale)),
        .size = scale - @as(V2, @splat(2)) * @as(V2, @splat(max_scale)),
    });

    rdl.addRect(.{
        .pos = .{ 0, 0 },
        .size = size,
        .tint = .fromHexArgb(state.bg_color_out),
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });

    return rdl;
}
