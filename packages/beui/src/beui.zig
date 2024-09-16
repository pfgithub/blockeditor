pub const default_image = @embedFile("font.rgba"); // 97x161, 255 = white / 0 = black
pub const draw_lists = @import("render_list.zig");
pub const texpack = @import("texpack.zig");

// TODO:
// - [ ] beui needs to be able to render render_list
// - [ ] we need to make a function to render chars from default_image to render_list

const std = @import("std");
const math = std.math;

pub const BeuiHotkeyModOption = enum {
    no,
    maybe,
    yes,

    pub fn eql(self: BeuiHotkeyModOption, v: bool) bool {
        return switch (self) {
            .no => v == false,
            .maybe => true,
            .yes => v == true,
        };
    }
};
pub const BeuiHotkeyMods = struct {
    ctrl_or_cmd: BeuiHotkeyModOption = .no,
    alt: BeuiHotkeyModOption = .no,
    shift: BeuiHotkeyModOption = .no,

    // pub fn parse(str: []const u8) BeuiHotkey {

    // }
};

fn HotkeyResult(mods: BeuiHotkeyMods, key_opts: []const BeuiKey) type {
    var fields: []const std.builtin.Type.EnumField = &.{};
    for (key_opts) |ko| {
        fields = fields ++ &[_]std.builtin.Type.EnumField{.{
            .name = @tagName(ko),
            .value = @intFromEnum(ko),
        }};
    }
    const ti: std.builtin.Type = .{ .@"enum" = .{
        .tag_type = @typeInfo(BeuiKey).@"enum".tag_type,
        .fields = fields,
        .decls = &.{},
        .is_exhaustive = true,
    } };
    return struct {
        const FilteredKey = @Type(ti);
        ctrl_or_cmd: if (mods.ctrl_or_cmd == .maybe) bool else void,
        alt: if (mods.alt == .maybe) bool else void,
        shift: if (mods.shift == .maybe) bool else void,
        key: FilteredKey,
    };
}

// BeUI:
// - if we make draw lists go front to back, then draw order is in the
//   same order as events. the first thing to see and capture an event
//   can take it - items behind it are also visually behind it
// - front to back is unusual but seems fine
// - we will still need ids for state
//   - if a button is active, it needs to store that and be the only
//     one to capture mouse events
//   - if an input is active, it needs to store that and be the only
//     reciever for text_input events
//   - need to support tab, shift+tab for inputs
// - ids are :/
pub const Beui = struct {
    frame: BeuiFrameEv = .{},
    persistent: BeuiPersistentEv = .{},

    pub fn newFrame(self: *Beui, cfg: BeuiFrameCfg) void {
        self.frame = .{ .frame_cfg = cfg };
    }

    pub fn textInput(self: *Beui) ?[]const u8 {
        const res = self.frame.text_input;
        if (res.len == 0) return null;
        self.frame.text_input = "";
        return res;
    }
    pub fn hotkey(self: *Beui, comptime mods: BeuiHotkeyMods, comptime key_opts: []const BeuiKey) ?HotkeyResult(mods, key_opts) {
        const ctrl_down = self.persistent.held_keys.get(.left_control) or self.persistent.held_keys.get(.right_control);
        const cmd_down = self.persistent.held_keys.get(.left_super) or self.persistent.held_keys.get(.right_super);
        const shift_down = self.persistent.held_keys.get(.left_shift) or self.persistent.held_keys.get(.right_shift);
        const alt_down = self.persistent.held_keys.get(.left_alt) or self.persistent.held_keys.get(.right_alt);
        const mods_eql = mods.shift.eql(shift_down) and mods.ctrl_or_cmd.eql(ctrl_down or cmd_down) and mods.alt.eql(alt_down);

        if (!mods_eql) return null;
        const key = for (key_opts) |key| {
            if (self.isKeyPressed(key)) break key;
        } else return null;

        return .{
            .ctrl_or_cmd = if (mods.ctrl_or_cmd == .maybe) ctrl_down or cmd_down else {},
            .alt = if (mods.alt == .maybe) alt_down else {},
            .shift = if (mods.shift == .maybe) shift_down else {},
            .key = @enumFromInt(@intFromEnum(key)),
        };
    }

    pub fn isKeyPressed(self: *Beui, key: BeuiKey) bool {
        return self.frame.pressed_keys.get(key) or self.frame.repeated_keys.get(key);
    }
    pub fn isKeyHeld(self: *Beui, key: BeuiKey) bool {
        return self.persistent.held_keys.get(key);
    }
    pub fn leftMouseClickedCount(self: *Beui) usize {
        self._maybeResetLeftClick(self.frame.frame_cfg.?.now_ms);
        return self.persistent.left_mouse_dblclick_info.count;
    }

    pub fn arena(self: *Beui) std.mem.Allocator {
        return self.frame.frame_cfg.?.arena;
    }
    pub fn draw(self: *Beui) *draw_lists.RenderList {
        return self.frame.frame_cfg.?.draw_list;
    }

    fn _maybeResetLeftClick(self: *Beui, now: i64) void {
        const dist_vec = self.persistent.mouse_pos - self.persistent.left_mouse_dblclick_info.last_click_pos;
        const dist_sca = std.math.hypot(dist_vec[0], dist_vec[1]);
        if ((self.persistent.left_mouse_dblclick_info.last_click_time <= now - self.persistent.config.dbl_click_time) //
        or dist_sca > self.persistent.config.dbl_click_dist) {
            self.persistent.left_mouse_dblclick_info = .{};
        }
    }
    pub fn _leftClickNow(self: *Beui) void {
        const now = std.time.milliTimestamp();
        self._maybeResetLeftClick(now);
        self.persistent.left_mouse_dblclick_info.count += 1;
        self.persistent.left_mouse_dblclick_info.last_click_time = now;
        self.persistent.left_mouse_dblclick_info.last_click_pos = self.persistent.mouse_pos;
    }

    pub fn nextID(self: *Beui) Beui.ID {
        defer self.persistent.id += 1;
        return @enumFromInt(self.persistent.id);
    }

    /// returns {needs_write, image_id, region} or null if the image cannot be drawn this frame
    pub fn getOrPutImage(self: *Beui, target: texpack.Format, size: @Vector(2, u32), id: Beui.ID) ?struct { bool, draw_lists.RenderListImage, texpack.Region } {
        // // getOrPutImage(nchannels, size, todo a unique id)
        // const needs_write, const image_id, const region = beui.getOrPutImage( .r, .{25, 50}, beui.id() ) orelse return;
        // if(needs_write) {
        //     beui.putImageData(image_id, region, loadImage("somefile.png"));
        // }
        // beui.persistent.draw_list.addRect();

        // if the region exists:
        // - return .{true, image, region}
        // if the region does not exist, reserve it:
        // - return .{false, image, region}
        // if a region cannot be reserved:
        // - return null
        //   - alternatively: start a new texture and add the image to it
        // - at the start of next frame, either grow or clear the texture
        //   - grow if most of the images in it were used last frame
        //   - clear if not too many of the images in it were used last frame

        _ = self;
        _ = target;
        _ = size;
        _ = id;
        return null;
    }

    pub const ID = enum(u64) { _ };
};
pub fn EnumArray(comptime Enum: type, comptime Value: type) type {
    const count = blk: {
        const enum_ti = @typeInfo(Enum);
        if (!enum_ti.@"enum".is_exhaustive) {
            break :blk Enum.count;
        }
        var count_v: usize = 0;
        for (enum_ti.@"enum".fields) |field| {
            const field_v: std.builtin.Type.EnumField = field;
            count_v = @max(count_v, field_v.value);
        }
        break :blk count_v;
    };
    if (count > 1000) @panic("count large");
    return struct {
        const Self = @This();
        values: [count]Value, // for ints we can use PackedIntArray
        pub fn init(default_value: Value) Self {
            return .{ .values = [_]Value{default_value} ** count };
        }
        fn toIdx(key: Enum) usize {
            const res = @intFromEnum(key);
            if (res >= count) @panic("enum too big");
            return res;
        }
        pub fn get(self: *const Self, key: Enum) Value {
            return self.values[toIdx(key)];
        }
        pub fn set(self: *Self, key: Enum, value: Value) void {
            self.values[toIdx(key)] = value;
        }
    };
}
const BeuiFrameCfg = struct {
    can_capture_keyboard: bool,
    can_capture_mouse: bool,
    arena: std.mem.Allocator,
    draw_list: *draw_lists.RenderList,
    now_ms: i64,
};
const BeuiPersistentEv = struct {
    config: struct {
        dbl_click_time: i64 = 500,
        dbl_click_dist: f32 = 10.0,
    } = .{},
    held_keys: EnumArray(BeuiKey, bool) = .init(false),
    mouse_pos: @Vector(2, f32) = .{ 0, 0 },
    left_mouse_dblclick_info: struct {
        count: usize = 0,
        last_click_time: i64 = 0,
        last_click_pos: @Vector(2, f32) = .{ 0.0, 0.0 },
    } = .{},
    id: u64 = 0,
};
const BeuiFrameEv = struct {
    pressed_keys: EnumArray(BeuiKey, bool) = .init(false),
    repeated_keys: EnumArray(BeuiKey, bool) = .init(false),
    released_keys: EnumArray(BeuiKey, bool) = .init(false),
    text_input: []const u8 = "",
    frame_cfg: ?BeuiFrameCfg = null,
    scroll: @Vector(2, f32) = .{ 0, 0 },
};
pub const BeuiKey = enum(u32) {
    mouse_left = 1,
    mouse_right = 2,
    mouse_middle = 3,
    mouse_four = 4,
    mouse_five = 5,
    mouse_six = 6,
    mouse_seven = 7,
    mouse_eight = 8,

    space = 32,
    apostrophe = 39,
    comma = 44,
    minus = 45,
    period = 46,
    slash = 47,
    zero = 48,
    one = 49,
    two = 50,
    three = 51,
    four = 52,
    five = 53,
    six = 54,
    seven = 55,
    eight = 56,
    nine = 57,
    semicolon = 59,
    equal = 61,
    a = 65,
    b = 66,
    c = 67,
    d = 68,
    e = 69,
    f = 70,
    g = 71,
    h = 72,
    i = 73,
    j = 74,
    k = 75,
    l = 76,
    m = 77,
    n = 78,
    o = 79,
    p = 80,
    q = 81,
    r = 82,
    s = 83,
    t = 84,
    u = 85,
    v = 86,
    w = 87,
    x = 88,
    y = 89,
    z = 90,
    left_bracket = 91,
    backslash = 92,
    right_bracket = 93,
    grave_accent = 96,
    world_1 = 161,
    world_2 = 162,

    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    insert = 260,
    delete = 261,
    right = 262,
    left = 263,
    down = 264,
    up = 265,
    page_up = 266,
    page_down = 267,
    home = 268,
    end = 269,
    caps_lock = 280,
    scroll_lock = 281,
    num_lock = 282,
    print_screen = 283,
    pause = 284,
    F1 = 290,
    F2 = 291,
    F3 = 292,
    F4 = 293,
    F5 = 294,
    F6 = 295,
    F7 = 296,
    F8 = 297,
    F9 = 298,
    F10 = 299,
    F11 = 300,
    F12 = 301,
    F13 = 302,
    F14 = 303,
    F15 = 304,
    F16 = 305,
    F17 = 306,
    F18 = 307,
    F19 = 308,
    F20 = 309,
    F21 = 310,
    F22 = 311,
    F23 = 312,
    F24 = 313,
    F25 = 314,
    kp_0 = 320,
    kp_1 = 321,
    kp_2 = 322,
    kp_3 = 323,
    kp_4 = 324,
    kp_5 = 325,
    kp_6 = 326,
    kp_7 = 327,
    kp_8 = 328,
    kp_9 = 329,
    kp_decimal = 330,
    kp_divide = 331,
    kp_multiply = 332,
    kp_subtract = 333,
    kp_add = 334,
    kp_enter = 335,
    kp_equal = 336,
    left_shift = 340,
    left_control = 341,
    left_alt = 342,
    left_super = 343,
    right_shift = 344,
    right_control = 345,
    right_alt = 346,
    right_super = 347,
    menu = 348,
    _,
    pub const count = 400;
};

test {
    _ = @import("font_experiment.zig");
    _ = @import("render_list.zig");
    _ = @import("texpack.zig");
}
