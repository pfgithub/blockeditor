const std = @import("std");
const Beui = @import("beui").Beui;
const B2 = Beui.beui_experiment;

const emu = @import("minigamer");
const sponge_cart = @embedFile("sponge.cart");
const util = @import("anywhere").util;

const FrameOut = [emu.constants.EMU_SCREEN_DATA_SIZE_U32 * emu.constants.EMU_SCREEN_NLAYERS]u32;
const OffsetsOut = [emu.constants.EMU_SCREEN_NLAYERS]@Vector(2, i8);
const State = struct {
    gpa: std.mem.Allocator,
    val: emu.Emu,
    frame_out: *FrameOut,
    offsets_out: *OffsetsOut,
    bg_color_out: u32,

    pub fn init(self: *State, gpa: std.mem.Allocator) void {
        self.* = .{
            .gpa = gpa,
            .val = .init(),
            .frame_out = gpa.create(FrameOut) catch @panic("oom"),
            .offsets_out = gpa.create(OffsetsOut) catch @panic("oom"),
            .bg_color_out = 0,
        };
        self.val.loadProgram(gpa, sponge_cart) catch |e| {
            std.log.err("progarm failed to load: {s}", .{@errorName(e)});
        };
    }
    pub fn deinit(self: *State) void {
        self.gpa.destroy(self.offsets_out);
        self.gpa.destroy(self.frame_out);
        if (self.val.program != null) self.val.unloadProgram(self.gpa);
        self.val.deinit(); // this doesn't even do anything?
    }
};

pub fn render(_: *const void, call_info: B2.StandardCallInfo, _: void) *B2.RepositionableDrawList {
    const ui = call_info.ui(@src());
    const rdl = ui.id.b2.draw();
    const size: @Vector(2, f32) = .{ ui.constraints.available_size.w.?, ui.constraints.available_size.h.? };

    const state = ui.id.b2.state2(ui.id.sub(@src()), ui.id.b2.persistent.gpa, State);

    if (state.val.program != null) {
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
            .frame = state.frame_out,
            .layer_offsets = state.offsets_out,
            .background_color = &state.bg_color_out,
        });
    }

    rdl.addRect(.{
        .pos = .{ 0, 0 },
        .size = size,
        .tint = .fromHexArgb(state.bg_color_out),
        .rounding = .{ .corners = .all, .radius = 6.0 },
    });

    return rdl;
}
