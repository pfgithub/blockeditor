const default_image = @embedFile("font.rgba"); // 97x161, 255 = white / 0 = black
const draw_lists = @import("render_list.zig");
const blocks_mod = @import("blocks");
const bi = blocks_mod.blockinterface2;
const db = blocks_mod.blockdb;
const text_editor_view = @import("editor_view.zig");

// TODO:
// - [ ] beui needs to be able to render render_list
// - [ ] we need to make a function to render chars from default_image to render_list

const std = @import("std");
const math = std.math;
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const zm = @import("zmath");
const zstbi = @import("zstbi");

const content_dir = @import("build_options").content_dir;
const window_title = "zig-gamedev: textured quad (wgpu)";

const wgsl_common = (
    \\  @group(0) @binding(0) var<uniform> uniforms: Uniforms;
    \\
    \\  struct VertexOut {
    \\      @builtin(position) position_clip: vec4<f32>,
    \\      @location(0) uv: vec2<f32>,
    \\      @location(1) tint: vec4<f32>,
    \\  }
    \\  @vertex fn vert(in: VertexIn) -> VertexOut {
    \\      var p = (in.pos / uniforms.screen_size) * vec2(2.0) - vec2(1.0);
    \\      p = vec2(p.x, -p.y);
    \\      var output: VertexOut;
    \\      output.position_clip = vec4(p, 0.0, 1.0);
    \\      output.uv = in.uv;
    \\      output.tint = in.tint;
    \\      return output;
    \\  }
    \\
    \\  fn premultiply(tint: vec4<f32>) -> vec4<f32> {
    \\      return vec4<f32>(tint.rgb * tint.a, tint.a);
    \\  }
    \\
    \\  @group(0) @binding(1) var image: texture_2d<f32>;
    \\  @group(0) @binding(2) var image_sampler: sampler;
    \\  @fragment fn frag(
    \\      in: VertexOut,
    \\  ) -> @location(0) vec4<f32> {
    \\      if in.uv.x == -1234.0 { return premultiply(in.tint); }
    \\      // texture must be premultiplied
    \\      var color: vec4<f32> = textureSampleLevel(image, image_sampler, in.uv, uniforms.mip_level);
    \\      if true { color = vec4<f32>(color.r); }
    \\      color *= in.tint;
    \\      return premultiply(color);
    \\  }
    \\
    \\  struct VertexIn {
++ Genres.wgsl ++
    \\  }
    \\  struct Uniforms {
++ UniformsRes.wgsl ++
    \\  }
);

fn genUniforms(comptime Src: type) type {
    const ti: std.builtin.Type = @typeInfo(Src);
    if (ti.@"struct".layout != .@"extern") @compileError("Uniforms info must be extern layout");

    var result: []const u8 = "";
    for (ti.@"struct".fields) |field| {
        const sub = genSub(field.type);
        result = result ++ std.fmt.comptimePrint("{s}: {s},\n", .{
            field.name,
            sub.type_str,
        });
    }

    const result_const = result;
    return struct {
        pub const wgsl = result_const;
        pub const Uniforms = Src;
    };
}
const WgslRes = struct {
    Vertex: type,
    wgsl: []const u8,
    attrs: []const wgpu.VertexAttribute,
};
fn genSub(comptime Src: type) struct { format: wgpu.VertexFormat, type_str: []const u8 } {
    return switch (Src) {
        f32 => .{ .format = .float32, .type_str = "f32" },
        @Vector(2, f32) => .{ .format = .float32x2, .type_str = "vec2<f32>" },
        @Vector(3, f32) => .{ .format = .float32x3, .type_str = "vec3<f32>" },
        @Vector(4, f32) => .{ .format = .float32x4, .type_str = "vec4<f32>" },
        else => @compileError("TODO"),
    };
}
fn genAttributes(comptime Src: type) type {
    var result: []const wgpu.VertexAttribute = &[_]wgpu.VertexAttribute{};
    var result_wgsl: []const u8 = "";
    var shader_location: usize = 0;

    const ti: std.builtin.Type = @typeInfo(Src);
    for (ti.@"struct".fields) |field| {
        const sub = genSub(field.type);
        result = result ++ &[_]wgpu.VertexAttribute{.{
            .format = sub.format,
            .offset = @offsetOf(Src, field.name),
            .shader_location = shader_location,
        }};
        result_wgsl = result_wgsl ++ std.fmt.comptimePrint("@location({d}) {s}: {s},\n", .{
            shader_location,
            field.name,
            sub.type_str,
        });
        shader_location += 1;
    }

    const result_imm = result;
    const result_wgsl_imm = result_wgsl;

    return struct {
        pub const Vertex = Src;
        pub const attrs = result_imm;
        pub const wgsl = result_wgsl_imm;
    };
}

const Genres = genAttributes(draw_lists.RenderListVertex);

const UniformsRes = genUniforms(extern struct {
    screen_size: @Vector(2, f32),
    mip_level: f32,
});

const DemoState = struct {
    gctx: *zgpu.GraphicsContext,

    pipeline: zgpu.RenderPipelineHandle = .{},
    bind_group: zgpu.BindGroupHandle,

    vertex_buffer: ?zgpu.BufferHandle = null,
    vertex_buffer_len: usize = 0,
    index_buffer: ?zgpu.BufferHandle = null,
    index_buffer_len: usize = 0,

    texture: zgpu.TextureHandle,
    texture_view: zgpu.TextureViewHandle,
    sampler: zgpu.SamplerHandle,

    mip_level: i32 = 0,
};

fn create(gpa: std.mem.Allocator, window: *zglfw.Window) !*DemoState {
    const gctx = try zgpu.GraphicsContext.create(
        gpa,
        .{
            .window = window,
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        },
        .{},
    );
    errdefer gctx.destroy(gpa);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bind_group_layout = gctx.createBindGroupLayout(&.{
        zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, true, 0),
        zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
        zgpu.samplerEntry(2, .{ .fragment = true }, .filtering),
    });
    defer gctx.releaseResource(bind_group_layout);

    zstbi.init(arena);
    defer zstbi.deinit();

    const image = default_image;
    const imgw = 256;
    const imgh = 256;
    const imgc = 1;

    // Create a texture.
    const texture = gctx.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .size = .{
            .width = imgw,
            .height = imgh,
            .depth_or_array_layers = 1,
        },
        .format = .r8_unorm,
        // not implemented for r8_unorm
        // .mip_level_count = math.log2_int(u32, @max(imgw, imgh)) + 1,
    });
    const texture_view = gctx.createTextureView(texture, .{});

    gctx.queue.writeTexture(
        .{ .texture = gctx.lookupResource(texture).? },
        .{
            .bytes_per_row = imgw * imgc,
            .rows_per_image = imgh,
        },
        .{ .width = imgw, .height = imgh },
        u8,
        image,
    );

    // Create a sampler.
    const sampler = gctx.createSampler(.{});

    const bind_group = gctx.createBindGroup(bind_group_layout, &.{
        .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = 256 },
        .{ .binding = 1, .texture_view_handle = texture_view },
        .{ .binding = 2, .sampler_handle = sampler },
    });

    const demo = try gpa.create(DemoState);
    demo.* = .{
        .gctx = gctx,
        .bind_group = bind_group,
        .vertex_buffer = null,
        .index_buffer = null,
        .texture = texture,
        .texture_view = texture_view,
        .sampler = sampler,
    };

    // Generate mipmaps on the GPU.
    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        gctx.generateMipmaps(arena, encoder, demo.texture);

        break :commands encoder.finish(null);
    };
    defer commands.release();
    gctx.submit(&.{commands});

    // (Async) Create a render pipeline.
    {
        const pipeline_layout = gctx.createPipelineLayout(&.{
            bind_group_layout,
        });
        defer gctx.releaseResource(pipeline_layout);

        const s_module = zgpu.createWgslShaderModule(gctx.device, wgsl_common, "s.wgsl");
        defer s_module.release();

        const color_targets = [_]wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
            .blend = &.{
                .color = .{ .src_factor = .one_minus_dst_alpha, .dst_factor = .one },
                .alpha = .{ .src_factor = .one_minus_dst_alpha, .dst_factor = .one },
            },
        }};

        const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
            .array_stride = @sizeOf(Genres.Vertex),
            .attribute_count = Genres.attrs.len,
            .attributes = Genres.attrs.ptr,
        }};

        // Create a render pipeline.
        const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
            .vertex = .{
                .module = s_module,
                .entry_point = "vert",
                .buffer_count = vertex_buffers.len,
                .buffers = &vertex_buffers,
            },
            .primitive = .{
                .front_face = .cw,
                .cull_mode = .back,
                .topology = .triangle_list,
            },
            .fragment = &.{
                .module = s_module,
                .entry_point = "frag",
                .target_count = color_targets.len,
                .targets = &color_targets,
            },
        };
        gctx.createRenderPipelineAsync(gpa, pipeline_layout, pipeline_descriptor, &demo.pipeline);
    }

    return demo;
}

fn destroy(allocator: std.mem.Allocator, demo: *DemoState) void {
    demo.gctx.destroy(allocator);
    allocator.destroy(demo);
}

fn update(demo: *DemoState) void {
    zgui.backend.newFrame(
        demo.gctx.swapchain_descriptor.width,
        demo.gctx.swapchain_descriptor.height,
    );

    _ = zgui.DockSpaceOverViewport(0, zgui.getMainViewport(), .{ .passthru_central_node = true });

    zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });

    if (zgui.begin("Demo Settings", .{})) {
        zgui.bulletText(
            "Average : {d:.3} ms/frame ({d:.1} fps)",
            .{ demo.gctx.stats.average_cpu_time, demo.gctx.stats.fps },
        );
        zgui.spacing();
        _ = zgui.sliderInt("Mipmap Level", .{
            .v = &demo.mip_level,
            .min = 0,
            .max = @as(i32, @intCast(demo.gctx.lookupResourceInfo(demo.texture).?.mip_level_count - 1)),
        });
    }
    zgui.end();
}

fn draw(demo: *DemoState, draw_list: *draw_lists.RenderList) void {
    const gctx = demo.gctx;
    const fb_width = gctx.swapchain_descriptor.width;
    const fb_height = gctx.swapchain_descriptor.height;

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    // TODO: load draw_list vertices and indices into vertex and index buffers
    // TODO: draw them
    // TODO: size them to array_list.capacity, remake if array_list.capacity changes

    if (demo.vertex_buffer_len != draw_list.vertices.capacity) {
        if (demo.vertex_buffer != null) gctx.releaseResource(demo.vertex_buffer.?);
        demo.vertex_buffer = null;
        demo.vertex_buffer_len = 0;
    }
    if (demo.index_buffer_len != draw_list.indices.capacity) {
        if (demo.index_buffer != null) gctx.releaseResource(demo.index_buffer.?);
        demo.index_buffer = null;
        demo.index_buffer_len = 0;
    }

    if (demo.vertex_buffer == null) {
        // Create a vertex buffer.
        const vertex_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = draw_list.vertices.capacity * @sizeOf(Genres.Vertex),
        });

        demo.vertex_buffer = vertex_buffer;
        demo.vertex_buffer_len = draw_list.vertices.capacity;
    }

    if (demo.index_buffer == null) {
        // Create an index buffer.
        const index_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .index = true },
            .size = draw_list.indices.capacity * @sizeOf(draw_lists.RenderListIndex),
        });

        demo.index_buffer = index_buffer;
    }

    gctx.queue.writeBuffer(gctx.lookupResource(demo.vertex_buffer.?).?, 0, Genres.Vertex, draw_list.vertices.items);
    gctx.queue.writeBuffer(gctx.lookupResource(demo.index_buffer.?).?, 0, draw_lists.RenderListIndex, draw_list.indices.items);

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // Main pass.
        pass: {
            const vb_info = gctx.lookupResourceInfo(demo.vertex_buffer.?) orelse break :pass;
            const ib_info = gctx.lookupResourceInfo(demo.index_buffer.?) orelse break :pass;
            const pipeline = gctx.lookupResource(demo.pipeline) orelse break :pass;
            const bind_group = gctx.lookupResource(demo.bind_group) orelse break :pass;

            const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                .view = back_buffer_view,
                .load_op = .clear,
                .store_op = .store,
            }};
            const render_pass_info = wgpu.RenderPassDescriptor{
                .color_attachment_count = color_attachments.len,
                .color_attachments = &color_attachments,
            };
            const pass = encoder.beginRenderPass(render_pass_info);
            defer {
                pass.end();
                pass.release();
            }

            pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
            pass.setIndexBuffer(ib_info.gpuobj.?, switch (draw_lists.RenderListIndex) {
                u16 => .uint16,
                u32 => .uint32,
                else => @compileError("not supported: " ++ @typeName(draw_lists.RenderListIndex)),
            }, 0, ib_info.size);

            pass.setPipeline(pipeline);

            const mem = gctx.uniformsAllocate(UniformsRes.Uniforms, 1);
            mem.slice[0] = .{
                .screen_size = .{ @floatFromInt(fb_width), @floatFromInt(fb_height) },
                .mip_level = @as(f32, @floatFromInt(demo.mip_level)),
            };
            pass.setBindGroup(0, bind_group, &.{mem.offset});
            for (draw_list.commands.items) |command| {
                pass.drawIndexed(command.index_count, 1, command.first_index, command.base_vertex, 0);
            }
        }

        // Gui pass.
        {
            const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                .view = back_buffer_view,
                .load_op = .load,
                .store_op = .store,
            }};
            const render_pass_info = wgpu.RenderPassDescriptor{
                .color_attachment_count = color_attachments.len,
                .color_attachments = &color_attachments,
            };
            const pass = encoder.beginRenderPass(render_pass_info);
            defer {
                pass.end();
                pass.release();
            }

            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});
    _ = gctx.present();
}

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

    fn newFrame(self: *Beui, cfg: BeuiFrameCfg) void {
        self.frame = .{ .frame_cfg = cfg };
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

    pub fn arena(self: *Beui) std.mem.Allocator {
        return self.frame.frame_cfg.?.arena;
    }
    pub fn draw(self: *Beui) *draw_lists.RenderList {
        return self.frame.frame_cfg.?.draw_list;
    }
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
};
const BeuiPersistentEv = struct {
    held_keys: EnumArray(BeuiKey, bool) = .init(false),
};
const BeuiFrameEv = struct {
    pressed_keys: EnumArray(BeuiKey, bool) = .init(false),
    repeated_keys: EnumArray(BeuiKey, bool) = .init(false),
    released_keys: EnumArray(BeuiKey, bool) = .init(false),
    text_input: []const u8 = "",
    frame_cfg: ?BeuiFrameCfg = null,
};
const BeuiKey = enum(u32) {
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

fn zglfwKeyToBeuiKey(key: zglfw.Key) ?BeuiKey {
    const val: i32 = @intFromEnum(key);
    switch (val) {
        0...BeuiKey.count => {
            return @enumFromInt(@as(u32, @intCast(val)));
        },
        else => {
            std.log.warn("TODO key: {s}", .{@tagName(key)});
            return null;
        },
    }
}

const callbacks = struct {
    fn keyCallback(window: *zglfw.Window, key: zglfw.Key, scancode: i32, action: zglfw.Action, mods: zglfw.Mods) callconv(.C) void {
        const beui = window.getUserPointer(Beui).?;

        if (action != .release) {
            if (beui.frame.frame_cfg == null) return;
            if (!beui.frame.frame_cfg.?.can_capture_keyboard) return;
        }

        const beui_key = zglfwKeyToBeuiKey(key) orelse return;
        _ = scancode;
        _ = mods;
        switch (action) {
            .press => {
                beui.persistent.held_keys.set(beui_key, true);
                beui.frame.pressed_keys.set(beui_key, true);
            },
            .repeat => {
                beui.persistent.held_keys.set(beui_key, true);
                beui.frame.repeated_keys.set(beui_key, true);
            },
            .release => {
                beui.persistent.held_keys.set(beui_key, false);
                beui.frame.released_keys.set(beui_key, true);
            },
        }
    }
    fn charCallback(window: *zglfw.Window, codepoint: u32) callconv(.C) void {
        const beui = window.getUserPointer(Beui).?;
        _ = beui;
        _ = codepoint;
        // beui.frame.text_input.appendSlice( std.unicode.codepoint to thing(codepoint) )
    }
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();

    const gpa = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try zglfw.init();
    defer zglfw.terminate();

    var interface = db.BlockDB.init(gpa);
    defer interface.deinit();
    var interface_thread = db.TcpSync.create(gpa, &interface);
    defer interface_thread.destroy();

    const my_counter = interface.createBlock(bi.CounterBlock.deserialize(gpa, bi.CounterBlock.default) catch unreachable);
    defer my_counter.unref();

    const my_text = interface.createBlock(bi.TextDocumentBlock.deserialize(gpa, bi.TextDocumentBlock.default) catch unreachable);
    defer my_text.unref();

    var my_text_editor: text_editor_view.EditorView = undefined;
    my_text_editor.initFromDoc(gpa, my_text.typedComponent(bi.TextDocumentBlock).?); // .? asserts it's loaded which isn't what we want. we want to wait to init until it's loaded.
    defer my_text_editor.deinit();

    my_text_editor.core.document.applySimpleOperation(.{
        .position = my_text_editor.core.document.value.positionFromDocbyte(0),
        .delete_len = 0,
        .insert_text = "hello!", //@embedFile("beui.zig"),
    }, null);
    my_text_editor.core.executeCommand(.{ .set_cursor_pos = .{ .position = my_text_editor.core.document.value.positionFromDocbyte(0) } });

    // Change current working directory to where the executable is located.
    {
        var buffer: [1024]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        std.posix.chdir(path) catch {};
    }

    zglfw.windowHintTyped(.client_api, .no_api);

    const window = try zglfw.Window.create(800, 400, window_title, null);
    defer window.destroy();
    window.setSizeLimits(-1, -1, -1, -1);

    var beui: Beui = .{};
    window.setUserPointer(@ptrCast(@alignCast(&beui)));

    _ = window.setPosCallback(null);
    _ = window.setKeyCallback(&callbacks.keyCallback);
    _ = window.setSizeCallback(null);
    _ = window.setCharCallback(&callbacks.charCallback);
    _ = window.setDropCallback(null);
    _ = window.setScrollCallback(null);
    _ = window.setCursorPosCallback(null);
    _ = window.setCursorEnterCallback(null);
    _ = window.setMouseButtonCallback(null);
    _ = window.setContentScaleCallback(null);
    _ = window.setFramebufferSizeCallback(null);

    const demo = try create(gpa, window);
    defer destroy(gpa, demo);

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    zgui.init(gpa);
    defer zgui.deinit();

    zgui.backend.init(
        window,
        demo.gctx.device,
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );
    defer zgui.backend.deinit();

    zgui.io.setConfigFlags(.{
        .nav_enable_keyboard = true,
        .dock_enable = true,
        .dpi_enable_scale_fonts = true,
    });

    zgui.getStyle().scaleAllSizes(scale_factor);

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        _ = arena_state.reset(.retain_capacity);

        var draw_list = draw_lists.RenderList.init(gpa);
        defer draw_list.deinit();

        beui.newFrame(.{
            .can_capture_keyboard = !zgui.io.getWantCaptureKeyboard(),
            .can_capture_mouse = !zgui.io.getWantCaptureMouse(),
            .draw_list = &draw_list,
            .arena = arena,
        });
        zglfw.pollEvents();

        update(demo);

        for (0..11) |i| {
            const im: f32 = @floatFromInt(i);
            draw_list.addRect(.{ 50 * im + 50, 50 }, .{ 50, 50 }, .{ .tint = .{ 1.0, 0.0, 0.0, im / 10.0 } });
        }
        for (0..11) |i| {
            const im: f32 = @floatFromInt(i);
            draw_list.addRect(.{ 50 * im + 50, 83 }, .{ 50, 50 }, .{ .tint = .{ 0.0, 1.0, 0.0, im / 10.0 } });
        }
        for (0..11) |i| {
            const im: f32 = @floatFromInt(i);
            draw_list.addRect(.{ 50 * im + 50, 116 }, .{ 50, 50 }, .{ .tint = .{ 0.0, 0.0, 1.0, im / 10.0 } });
        }

        zgui.setNextWindowPos(.{ .x = 20.0, .y = 80.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });
        if (zgui.begin("My counter (editor 1)", .{})) {
            @import("entrypoint.zig").renderCounter(arena, my_counter);
        }
        zgui.end();

        zgui.setNextWindowPos(.{ .x = 250.0, .y = 80.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 250, .h = 250, .cond = .first_use_ever });
        if (zgui.begin("My Text Editor", .{})) {
            const gctx = demo.gctx;
            const fb_width = gctx.swapchain_descriptor.width;
            const fb_height = gctx.swapchain_descriptor.height;
            my_text_editor.gui(&beui, .{ @floatFromInt(fb_width), @floatFromInt(fb_height) });
        }
        zgui.end();

        zgui.showDemoWindow(null);

        draw(demo, &draw_list);
    }
}
