const std = @import("std");
const lib = @import("lib");
const assets = @import("assets");

const BLUE = lib.constants.color3(0, 0, 255);
const water_image_v = struct {
    var rgba = [1]u32{BLUE} ** (2 * 2);
    const width = 2;
    const height = 2;
    pub fn getImage() lib.ImageSub {
        return .{
            .data = @constCast(&rgba),
            .stride = width,
            .size = .{ width, height },
        };
    }
};
const white_image_v = struct {
    var rgba = [1]u32{0xFF_FFFFFF} ** lib.constants.EMU_SCREEN_DATA_SIZE_U32;
    const width = 120;
    const height = 120;
    pub fn getImage() lib.ImageSub {
        return .{
            .data = @constCast(&rgba),
            .stride = width,
            .size = .{ width, height },
        };
    }
};
const GRAY = 0xFF_AAAAAA;
const gray_image_v = struct {
    var rgba = [1]u32{GRAY} ** lib.constants.EMU_SCREEN_DATA_SIZE_U32;
    const width = 120;
    const height = 120;
    pub fn getImage() lib.ImageSub {
        return .{
            .data = @constCast(&rgba),
            .stride = width,
            .size = .{ width, height },
        };
    }
};
const water_image = water_image_v.getImage();
const gray_image = gray_image_v.getImage();
const white_image = white_image_v.getImage();

const Particle = union(enum) {
    none,
    attack_anim: ParticleAttackAnim,
    attack_anim_wide: ParticleAttackAnim,
    water: ParticleWater,
};
const ParticleAttackAnim = struct {
    pos: @Vector(2, i16),
    start: u64,
};
const ParticleWater = struct {
    pos: @Vector(2, f32),
    vel: @Vector(2, f32),
};

const Room = struct {
    movement: enum { flat, platformer, rpg },
};
const rooms = &[_]Room{
    .{ .movement = .flat },
    .{ .movement = .rpg },
};

const State = struct {
    ticks: u64 = 10_000,

    room: usize = 0,
    dialogue: usize = 0,

    dialogue_triggers: struct {
        dmg_10: bool = false,
        dmg_20: bool = false,
    } = .{},

    // the health bar will be logarithmic
    // so the more damage you do the lower it goes down
    // and then we can do idle mechanics
    sponge_damage: f64 = 0,

    particles: [32]Particle = [_]Particle{.none} ** 32,

    mouse_down_previous_frame: bool = false,
    jump_down_previous_frame: bool = false,
    interact_down_previous_frame: bool = false,

    player_pos: @Vector(2, i16) = .{ 94, 109 },

    dialogue_hold_start: u64 = 0,

    fn addParticle(state: *State, new_particle: Particle) void {
        const free_particle = for (&state.particles) |*particle| {
            if (particle.* == .none) break particle;
        } else &state.particles[0];
        free_particle.* = new_particle;
    }
};

const sponge_image = lib.ImageSub.fromAsset(assets.@"SPONGE.png");
const sponge_bg = lib.ImageSub.fromAsset(assets.@"SPONGE_BG.png");
const sponge_hit_image = lib.ImageSub.fromAsset(assets.@"SPONGE_HIT.png");
const sponge_ui_image = lib.ImageSub.fromAsset(assets.@"SPONGE_UI.png");
const sponge_particle = lib.ImageSub.fromAsset(assets.@"SPONGE_PARTICLE.png");
const player_sprite = lib.ImageSub.fromAsset(assets.@"PLAYER.png");

const Input = struct {
    mouse_down: bool,
    mouse_down_this_frame: bool,
    interact_down: bool,
    interact_down_this_frame: bool,
    jump_down: bool,
    jump_down_this_frame: bool,
};

var _global_state: State = undefined;
pub fn initialize() !void {
    _global_state = .{};
}
pub fn frame() !void {
    const state = &_global_state;
    state.ticks += 1;

    // rather than this, we can have two movement modes:
    // - platformer
    // - rpg
    // and the sponge room would be a platformer room
    const room = &rooms[state.room];

    const buttons = lib.getButtons();
    if (buttons & lib.constants.BUTTON_LEFT != 0) {
        state.player_pos += .{ -1, 0 };
    }
    if (buttons & lib.constants.BUTTON_RIGHT != 0) {
        state.player_pos += .{ 1, 0 };
    }
    if (room.movement == .rpg and buttons & lib.constants.BUTTON_UP != 0) {
        state.player_pos += .{ 0, -1 };
    }
    if (room.movement == .rpg and buttons & lib.constants.BUTTON_DOWN != 0) {
        state.player_pos += .{ 0, 1 };
    }

    const mouse_down = lib.getMouse() != null;
    const interact_down = buttons & lib.constants.BUTTON_INTERACT != 0;
    const jump_down = buttons & lib.constants.BUTTON_JUMP != 0;
    const mouse_down_this_frame = mouse_down and !state.mouse_down_previous_frame;
    const interact_down_this_frame = interact_down and !state.interact_down_previous_frame;
    const jump_down_this_frame = jump_down and !state.jump_down_previous_frame;
    state.mouse_down_previous_frame = mouse_down;
    state.interact_down_previous_frame = interact_down;
    state.jump_down_previous_frame = jump_down;
    const input: Input = .{
        .mouse_down = mouse_down,
        .interact_down = interact_down,
        .jump_down = jump_down,
        .mouse_down_this_frame = mouse_down_this_frame,
        .interact_down_this_frame = interact_down_this_frame,
        .jump_down_this_frame = jump_down_this_frame,
    };

    if (state.dialogue == 0) checkDialogueTriggers();
    switch (state.room) {
        0 => frameSpongeRoom(input),
        1 => frame00(input),
        else => @panic("TODO room"),
    }
    if (false and state.dialogue != 0) dialogue(input);
}
pub fn dialogue(input: Input) void {
    // this doesn't feel good

    const state = &_global_state;
    switch (state.dialogue) {
        1000 => state.dialogue = 0,
        1 => {
            lib.gpu.draw(3, sponge_ui_image.subrect(.{ 0, 55 }, .{ 120, 65 }).?, .{ 0, 55 }, .replace);
            lib.text.print(3, .{ 10, 64 }, " Hey! Stop that!", .{});

            if (state.dialogue_hold_start != 0 and state.dialogue_hold_start + 30 < state.ticks) {
                state.dialogue = 1000;
            }
        },
        2 => {
            lib.gpu.draw(3, sponge_ui_image.subrect(.{ 0, 55 }, .{ 120, 65 }).?, .{ 0, 55 }, .replace);
            lib.text.print(3, .{ 10, 64 }, " You're draining\n my water!", .{});

            if (state.dialogue_hold_start != 0 and state.dialogue_hold_start + 30 < state.ticks) {
                state.dialogue = 1000;
            }
        },
        else => {},
    }

    if (input.mouse_down_this_frame or input.mouse_down_this_frame or input.jump_down_this_frame) {
        state.dialogue_hold_start = state.ticks;
    }
    if (!input.mouse_down and !input.jump_down and !input.interact_down) {
        state.dialogue_hold_start = 0;
    }
}
pub fn checkDialogueTriggers() void {
    const state = &_global_state;

    // problem in the risc v emulator with `state.sponge_damage (0.0) >= 10.0` returning true
    // maybe we can make a minimal repro? or do conformance testing and find the bug?
    if (!state.dialogue_triggers.dmg_10 and @as(i64, @intFromFloat(state.sponge_damage)) >= 10) {
        state.dialogue_triggers.dmg_10 = true;
        state.dialogue = 1;
    }
    if (!state.dialogue_triggers.dmg_20 and @as(i64, @intFromFloat(state.sponge_damage)) >= 20) {
        state.dialogue_triggers.dmg_20 = true;
        state.dialogue = 2;
    }
}
pub fn frame00(input: Input) void {
    const state = &_global_state;

    if (state.player_pos[0] < -8) {
        state.player_pos[0] += 120;
        state.player_pos[1] = 109;
        state.room = 0;
    }

    lib.gpu.draw(0, lib.ImageSub.fromAsset(assets.@"level_0_0.png"), .{ 0, 0 }, .replace);
    renderPlayer(input.mouse_down or input.interact_down);
}
pub fn frameSpongeRoom(input: Input) void {
    const state = &_global_state;

    if (state.player_pos[0] < 1) {
        state.player_pos[0] = 1;
    }
    if (state.player_pos[0] > 118) {
        state.player_pos[0] -= 120;
        state.room = 1;
    }

    const clicked = input.mouse_down or input.interact_down or input.jump_down;
    const clicked_this_frame = input.mouse_down_this_frame or input.interact_down_this_frame or input.jump_down_this_frame;

    const shift_float: f32 = @sin(@as(f32, @floatFromInt(state.ticks)) / 40) * 3.0;
    const shift_int, const shift_intrem = calcOffset(shift_float);

    if (clicked_this_frame) {
        const mpos: @Vector(2, i16) = lib.getMouse() orelse .{ 60, 60 };
        state.addParticle(.{
            .attack_anim_wide = .{
                .pos = mpos,
                .start = state.ticks,
            },
        });
        // TODO: switch to unconditionally use std.Random once we update zig versions
        const std_rand = if (@hasDecl(std, "rand")) std.rand else std.Random;
        var rand_ = std_rand.DefaultPrng.init(state.ticks);
        const rand = rand_.random();
        for (0..rand.intRangeAtMostBiased(usize, 5, 10)) |_| {
            const dir = rand.float(f32) * std.math.pi * 2;
            const speed = remap(rand.float(f32), 0, 1, 3.0, 6.0);
            const vector: @Vector(2, f32) = .{ @cos(dir) * speed, @sin(dir) * speed };
            const pos: @Vector(2, f32) = if (vector[0] < 0) (.{ 32, 64 }) else (.{ 84, 64 });
            state.addParticle(.{
                .water = .{
                    // maybe should come from the edges of the sponge
                    .pos = pos + @Vector(2, f32){ shift_float, 0 },
                    .vel = vector,
                },
            });
        }
        // consider adding water particles when you hit the sponge to show the water coming out
        state.sponge_damage += 1;
    }

    const dmg_shift_scale = 20;
    const dmg_shift_float: f32 = @as(f32, @floatFromInt(state.ticks % (120 * dmg_shift_scale))) / dmg_shift_scale;
    // maybe dmg shift should not do subpixel offsets - it won't look right in 3d
    const dmg_shift_int, const dmg_shift_intrem = calcOffset(dmg_shift_float);

    const health_log: f64 = @log10(state.sponge_damage + 2.0) - @log10(2.0);
    const health_x: i32 = @intFromFloat(remap(health_log, 20, 0, 4, 113));

    lib.gpu.setBackgroundColor(GRAY);
    // maybe draw a halo around the sponge?
    lib.gpu.draw(0, sponge_bg, .{ 0, 0 }, .replace);
    lib.gpu.draw(1, sponge_ui_image.subrect(.{ 0, 3 }, .{ 120, 11 }).?, .{ dmg_shift_int - 120, 3 }, .replace);
    lib.gpu.draw(1, sponge_ui_image.subrect(.{ 0, 3 }, .{ 120, 11 }).?, .{ dmg_shift_int, 3 }, .replace);
    lib.gpu.setLayerOffset(1, dmg_shift_intrem, 0);
    if (clicked) {
        lib.gpu.draw(0, sponge_hit_image, .{ 0, shift_int }, .cutout); // go back physically
    } else {
        lib.gpu.draw(2, sponge_image, .{ 0, shift_int }, .cutout);
    }
    lib.gpu.setLayerOffset(2, 0, shift_intrem);
    lib.gpu.draw(3, white_image.subrect(.{ health_x, 0 }, .{ 120 - health_x, 11 }).?, .{ health_x, 3 }, .replace);
    lib.gpu.draw(3, sponge_ui_image.subrect(.{ 0, 20 }, .{ 120, 20 }).?, .{ 0, 0 }, .cutout);

    // TODO: debug float printing in debug bulds
    // one of the instructions is returning something wrong, causing a crash
    // if (state.sponge_damage >= 10) {
    //     lib.text.print(3, .{ 2, 109 }, "Damage: {d}", .{@as(i64, @intFromFloat(state.sponge_damage))});
    // }

    for (&state.particles) |*particle| {
        switch (particle.*) {
            .attack_anim => |anim| {
                const diff = state.ticks - anim.start;
                const particle_frame = diff / 2;
                if (particle_frame >= 9) {
                    particle.* = .none;
                    continue;
                }
                var particle_target_pos: @Vector(2, i32) = .{ anim.pos[0], anim.pos[1] };
                particle_target_pos -= .{ 8, 8 };
                // 16x16?
                const particle_x = (particle_frame % 7) * 16;
                const particle_y = (particle_frame / 7) * 16;
                lib.gpu.draw(3, sponge_particle.subrect(.{ @intCast(particle_x), @intCast(particle_y) }, .{ 16, 16 }).?, particle_target_pos, .cutout);
            },
            .attack_anim_wide => |anim| {
                const diff = state.ticks - anim.start;
                const particle_frame = diff / 3;
                if (particle_frame >= 5) {
                    particle.* = .none;
                    continue;
                }
                var particle_target_pos: @Vector(2, i32) = .{ anim.pos[0], anim.pos[1] };
                // move to align to 60
                particle_target_pos[0] = @intFromFloat(centerAlign(@as(f32, @floatFromInt(particle_target_pos[0])) - 60) + 60);
                particle_target_pos -= .{ 60, 8 };
                // 16x16?
                const particle_x = 0;
                const particle_y = particle_frame * 16 + 32;
                lib.gpu.draw(3, sponge_particle.subrect(.{ @intCast(particle_x), @intCast(particle_y) }, .{ 120, 16 }).?, particle_target_pos, .cutout);
            },
            .water => |*water| {
                if (water.pos[1] > 120) {
                    particle.* = .none;
                    continue;
                }
                lib.gpu.draw(2, water_image, .{ @intFromFloat(water.pos[0]), @intFromFloat(water.pos[1]) }, .replace);
                water.pos += water.vel;
                water.vel *= .{ 0.9, 0.9 }; // air resistance
                water.vel += .{ 0.0, 1.0 }; // gravity
            },
            else => {},
        }
    }

    renderPlayer(clicked);
}

fn renderPlayer(clicked: bool) void {
    const state = &_global_state;
    lib.gpu.draw(3, player_sprite.subrect(.{ if (clicked) 11 else 0, if (state.room == 0 and state.sponge_damage < 10) 11 else 0 }, .{ 10, 10 }).?, state.player_pos, .cutout);
}

fn centerAlign(n: f32) f32 {
    // n ** 0.6 ?
    if (n > 0) return @sqrt(n);
    if (n < 0) return -@sqrt(-n);
    return 0;
}

fn calcOffset(value: f32) struct { i32, i8 } {
    const intver: i32 = @intFromFloat((value + 0.5) * 256);

    const int_part = intver >> 8;
    const offset_part: i8 = @intCast((intver & 0xFF) - 128);

    return .{ int_part, offset_part };
}

fn testOffset(a: f32, target_int: i32, target_offset: i8) !void {
    const res_int, const res_offset = calcOffset(a);
    try std.testing.expectEqual(target_int, res_int);
    try std.testing.expectEqual(target_offset, res_offset);
}
test "calcOffset" {
    try testOffset(-1, -1, 0);
    try testOffset(-0.75, -1, 64);
    try testOffset(-0.5, 0, -128);
    try testOffset(-0.25, 0, -64);
    try testOffset(0, 0, 0);
    try testOffset(0.25, 0, 64);
    try testOffset(0.5, 1, -128);
    try testOffset(0.75, 1, -64);
    try testOffset(1, 1, 0);
}

fn remap(a: anytype, prev_min: @TypeOf(a), prev_max: @TypeOf(a), next_min: @TypeOf(a), next_max: @TypeOf(a)) @TypeOf(a) {
    const unscaled = (a - prev_min) / (prev_max - prev_min);
    const rescaled = unscaled * (next_max - next_min) + next_min;
    return rescaled;
}

// TODO:
// - [x] draw sponge
// - [x] offset sponge by sin(time) to make it sway up/down
// - [x] render health bar
// - [x] show particle below click of dealing damage
// - [x] show sponge damage frame when it gets damaged
// - [x] click to attack sponge
// - [x] decrease health after click

// NEXT!
// time for idle game mechanics. because you need to get to
//   one hundred quintillion damage to kill it. so we need some
//   idle game mechanics.

// below the sponge room is level_1_1 where all the sponge bits fall
// every few times you hit the sponge, one spawns and falls down.
// you have to then go down and collect the sponge bits so you
// can sell them at the shop.
// they're all jumping around in there like slimes and you have to
// kill them individually. we could limit to displaying a certain
// number and past that a new one spawns in the back when
// you kill one
//
// also that room will fill up with water and you'll have to manage that somehow
// - maybe you can fill up a watering can and bring it to some plants

// we can start with the player in shadow & no shop sign
// then after 10 clicks, play a fullscreen cutscene where you slice the sponge
// and when you come back the player is visible and the shop sign is
// visible. and then after like 20 we can add indicators for movement.

// execution problem
// state.sponge_damage < 10 : returns false always
// ie 1.0 < 10.0 : failure
