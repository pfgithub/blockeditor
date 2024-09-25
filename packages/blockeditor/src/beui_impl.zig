const default_image = Beui.default_image; // 97x161, 255 = white / 0 = black
const draw_lists = Beui.draw_lists;
const blocks_mod = @import("blocks");
const bi = blocks_mod.blockinterface2;
const db = blocks_mod.blockdb;
const Beui = @import("beui").Beui;
const blocks_net = @import("blocks_net");
const anywhere = @import("anywhere");
const tracy = anywhere.tracy;
const build_options = @import("build_options");
const zgui_anywhere = anywhere.zgui;

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

const window_title = "zig-gamedev: textured quad (wgpu)";

pub const anywhere_cfg: anywhere.AnywhereCfg = .{
    .tracy = if (build_options.enable_tracy) @import("tracy__impl") else null,
    .zgui = zgui,
};

const wgsl_common = (
    \\  @group(0) @binding(0) var<uniform> uniforms: Uniforms;
    \\
    \\  struct VertexOut {
    \\      @builtin(position) position_clip: vec4<f32>,
    \\      @location(0) uv: vec2<f32>,
    \\      @location(1) tint: vec4<f32>,
    \\  }
    \\  fn unpack_color(color: vec4<u32>) -> vec4<f32> {
    \\      return vec4<f32>(
    \\          f32(color.r) / 255.0,
    \\          f32(color.g) / 255.0,
    \\          f32(color.b) / 255.0,
    \\          f32(color.a) / 255.0
    \\      );
    \\  }
    \\  @vertex fn vert(in: VertexIn) -> VertexOut {
    \\      var p = (in.pos / uniforms.screen_size) * vec2(2.0) - vec2(1.0);
    \\      p = vec2(p.x, -p.y);
    \\      var output: VertexOut;
    \\      output.position_clip = vec4(p, 0.0, 1.0);
    \\      output.uv = in.uv;
    \\      output.tint = unpack_color(in.tint);
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
    \\      if in.uv.x < 0.0 { return premultiply(in.tint); }
    \\      var color: vec4<f32> = textureSampleLevel(image, image_sampler, in.uv, uniforms.mip_level);
    \\      if true { color = vec4<f32>(1.0, 1.0, 1.0, color.r); }
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
        @Vector(4, u8) => .{ .format = .uint8x4, .type_str = "vec4<u32>" },
        else => @compileError("TODO: " ++ @typeName(Src)),
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

    vertex_buffer: ?zgpu.BufferHandle = null,
    vertex_buffer_len: usize = 0,
    index_buffer: ?zgpu.BufferHandle = null,
    index_buffer_len: usize = 0,

    bind_group_layout: zgpu.BindGroupLayoutHandle,

    texture_2: ?zgpu.TextureHandle = null,
    texture_view_2: ?zgpu.TextureViewHandle = null,

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
    errdefer gctx.releaseResource(bind_group_layout);

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

    const demo = try gpa.create(DemoState);
    demo.* = .{
        .gctx = gctx,
        .vertex_buffer = null,
        .index_buffer = null,
        .texture = texture,
        .texture_view = texture_view,
        .bind_group_layout = bind_group_layout,
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
    demo.gctx.releaseResource(demo.bind_group_layout);
    demo.gctx.destroy(allocator);
    allocator.destroy(demo);
}

fn update(demo: *DemoState) void {
    zgui.backend.newFrame(
        demo.gctx.swapchain_descriptor.width,
        demo.gctx.swapchain_descriptor.height,
    );

    _ = zgui.DockSpaceOverViewport(0, zgui.getMainViewport(), .{ .passthru_central_node = true });
}

fn draw(demo: *DemoState, draw_list: *draw_lists.RenderList, texture_2_src: *Beui.Texpack) void {
    const gctx = demo.gctx;
    const fb_width = gctx.swapchain_descriptor.width;
    const fb_height = gctx.swapchain_descriptor.height;

    if (demo.texture_2 == null) {
        texture_2_src.modified = true;

        demo.texture_2 = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{
                .width = texture_2_src.size,
                .height = texture_2_src.size,
                .depth_or_array_layers = texture_2_src.format.depth(),
            },
            .format = switch (texture_2_src.format) {
                .greyscale => .r8_unorm,
                .rgb => @panic("TODO rgb"),
                .rgba => .rgba8_unorm,
            },
        });
    }
    if (demo.texture_view_2 == null) {
        demo.texture_view_2 = gctx.createTextureView(demo.texture_2.?, .{});
    }
    if (texture_2_src.modified) {
        gctx.queue.writeTexture(
            .{ .texture = gctx.lookupResource(demo.texture_2.?).? },
            .{
                .bytes_per_row = texture_2_src.size * texture_2_src.format.depth(),
                .rows_per_image = texture_2_src.size,
            },
            .{ .width = texture_2_src.size, .height = texture_2_src.size },
            u8,
            texture_2_src.data,
        );
        texture_2_src.modified = false;
    }

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
            for (draw_list.commands.items) |command| {
                const bind_group_handle = gctx.createBindGroup(demo.bind_group_layout, &.{
                    .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = 256 },
                    .{ .binding = 1, .texture_view_handle = switch (command.image orelse .beui_font) {
                        .beui_font => demo.texture_view,
                        .editor_view_glyphs => demo.texture_view_2.?,
                        else => demo.texture_view,
                    } },
                    .{ .binding = 2, .sampler_handle = demo.sampler },
                });
                defer demo.gctx.releaseResource(bind_group_handle);

                const bind_group = gctx.lookupResource(bind_group_handle) orelse break :pass;

                pass.setBindGroup(0, bind_group, &.{mem.offset});

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

pub fn renderCounter(counter: db.TypedComponentRef(bi.CounterComponent)) void {
    zgui.text("Count: {d}", .{counter.value.count});
    if (zgui.button("Increment!", .{})) {
        counter.applySimpleOperation(.{ .add = 1 }, null);
    }
    if (zgui.button("Zero!", .{})) {
        counter.applySimpleOperation(.{ .set = 0 }, null);
    }
    if (zgui.button("Undo!", .{})) {
        @panic("TODO: someone needs to keep an undo list");
    }
    if (zgui.button("Redo!", .{})) {
        @panic("TODO: someone needs to keep a redo list");
    }
}

fn zglfwKeyToBeuiKey(key: zglfw.Key) ?Beui.Key {
    const val: i32 = @intFromEnum(key);
    switch (val) {
        -1 => return null, // 'unknown'
        0...Beui.Key.count => {
            return @enumFromInt(@as(u32, @intCast(val)));
        },
        else => {
            std.log.warn("TODO key: {s}", .{@tagName(key)});
            return null;
        },
    }
}
fn zglfwButtonToBeuiKey(button: zglfw.MouseButton) ?Beui.Key {
    return switch (button) {
        .left => .mouse_left,
        .right => .mouse_right,
        .middle => .mouse_middle,
        .four => .mouse_four,
        .five => .mouse_five,
        .six => .mouse_six,
        .seven => .mouse_seven,
        .eight => .mouse_eight,
    };
}

const callbacks = struct {
    fn handleKeyWithAction(beui: *Beui, key: Beui.Key, action: zglfw.Action) void {
        switch (action) {
            .press => {
                beui.persistent.held_keys.set(key, true);
                beui.frame.pressed_keys.set(key, true);
            },
            .repeat => {
                beui.persistent.held_keys.set(key, true);
                beui.frame.repeated_keys.set(key, true);
            },
            .release => {
                beui.persistent.held_keys.set(key, false);
                beui.frame.released_keys.set(key, true);
            },
        }
    }

    fn keyCallback(window: *zglfw.Window, key: zglfw.Key, scancode: i32, action: zglfw.Action, mods: zglfw.Mods) callconv(.C) void {
        const beui = window.getUserPointer(Beui).?;

        if (action != .release) {
            if (beui.frame.frame_cfg == null) return;
            if (!beui.frame.frame_cfg.?.can_capture_keyboard) return;
        }

        const beui_key = zglfwKeyToBeuiKey(key) orelse return;
        _ = scancode;
        _ = mods;
        handleKeyWithAction(beui, beui_key, action);
    }
    fn charCallback(window: *zglfw.Window, codepoint: u32) callconv(.C) void {
        const beui = window.getUserPointer(Beui).?;
        const codepoint_u21 = std.math.cast(u21, codepoint) orelse {
            std.log.warn("charCallback codepoint out of range: {d}", .{codepoint});
            return;
        };
        const printed = std.fmt.allocPrint(beui.frame.frame_cfg.?.arena, "{s}{u}", .{ beui.frame.text_input, codepoint_u21 }) catch @panic("oom");
        beui.frame.text_input = printed;
    }

    fn scrollCallback(window: *zglfw.Window, xoffset: f64, yoffset: f64) callconv(.C) void {
        const beui = window.getUserPointer(Beui).?;
        if (!beui.frame.frame_cfg.?.can_capture_mouse) return;
        beui.frame.scroll_px += @floatCast(@Vector(2, f64){ xoffset, yoffset } * @Vector(2, f64){ 48, 48 });
    }
    fn cursorPosCallback(window: *zglfw.Window, xpos: f64, ypos: f64) callconv(.C) void {
        const beui = window.getUserPointer(Beui).?;
        if (!beui.frame.frame_cfg.?.can_capture_mouse) {
            // TODO: mouse_pos = null
            // TODO: if can_capture_mouse becomes false but no new cursorPosCallback is
            // received, set mouse_pos to the last known one from cursorPosCallback
            beui.persistent.mouse_pos = .{ 0, 0 };
            return;
        }
        beui.persistent.mouse_pos = @floatCast(@Vector(2, f64){ xpos, ypos });
    }
    fn cursorEnterCallback(window: *zglfw.Window, entered: i32) callconv(.C) void {
        _ = window;
        if (entered != 0) {
            // entered
        } else {
            // left
        }
    }
    fn mouseButtonCallback(window: *zglfw.Window, button: zglfw.MouseButton, action: zglfw.Action, mods: zglfw.Mods) callconv(.C) void {
        const beui = window.getUserPointer(Beui).?;

        if (action != .release) {
            if (!beui.frame.frame_cfg.?.can_capture_mouse) return;
        }

        const beui_key = zglfwButtonToBeuiKey(button) orelse {
            std.log.warn("not supported glfw button: {}", .{button});
            return;
        };
        _ = mods;
        handleKeyWithAction(beui, beui_key, action);
        if (button == .left and action == .press) {
            beui._leftClickNow();
        }
    }
};

const BeuiVtable = struct {
    window: *zglfw.Window,
    fn setClipboard(cfg: *const Beui.FrameCfg, text_utf8: [:0]const u8) void {
        const self = cfg.castUserData(BeuiVtable);
        self.window.setClipboardString(text_utf8);
    }
    fn getClipboard(cfg: *const Beui.FrameCfg, clipboard_contents: *std.ArrayList(u8)) void {
        const self = cfg.castUserData(BeuiVtable);
        clipboard_contents.appendSlice(self.window.getClipboardString() orelse "") catch @panic("oom");
    }
    pub const vtable: *const Beui.FrameCfgVtable = &.{
        .type_id = @typeName(BeuiVtable),
        .set_clipboard = &setClipboard,
        .get_clipboard = &getClipboard,
    };
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    var tracy_wrapped = tracy.tracyAllocator(gpa_state.allocator());

    const gpa = tracy_wrapped.allocator();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try zglfw.init();
    defer zglfw.terminate();

    var interface = db.BlockDB.init(gpa);
    defer interface.deinit();

    var interface_thread: blocks_net.TcpSync = undefined;
    interface_thread.init(gpa, &interface);
    defer interface_thread.deinit();

    const my_counter = interface.createBlock(bi.CounterBlock.deserialize(gpa, bi.CounterBlock.default) catch unreachable);
    defer my_counter.unref();

    const my_counter_component = my_counter.typedComponent(bi.CounterBlock).?; // .? asserts it's loaded, which is always true for a newly created block
    defer my_counter_component.unref();

    const my_text = interface.createBlock(bi.TextDocumentBlock.deserialize(gpa, bi.TextDocumentBlock.default) catch unreachable);
    defer my_text.unref();

    const my_text_component = my_text.typedComponent(bi.TextDocumentBlock).?; // .? asserts it's loaded which isn't what we want. we want to wait to init until it's loaded.
    defer my_text_component.unref();

    var zig_language = Beui.EditorView.Core.highlighters_zig.HlZig.init(gpa);
    defer zig_language.deinit();

    var markdown_language = Beui.EditorView.Core.highlighters_markdown.HlMd.init();
    defer markdown_language.deinit();

    var my_text_editor: Beui.EditorView = undefined;
    my_text_editor.initFromDoc(gpa, my_text_component);
    defer my_text_editor.deinit();
    my_text_editor.core.setSynHl(zig_language.language());

    my_text_editor.core.document.applySimpleOperation(.{
        .position = my_text_editor.core.document.value.positionFromDocbyte(0),
        .delete_len = 0,
        .insert_text = @embedFile("beui_impl.zig"),
    }, null);
    my_text_editor.core.executeCommand(.{ .set_cursor_pos = .{ .position = my_text_editor.core.document.value.positionFromDocbyte(0) } });

    // Change current working directory to where the executable is located.
    {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        std.posix.chdir(path) catch {};
    }

    zglfw.windowHintTyped(.client_api, .no_api);

    const window = try zglfw.Window.create(800, 400, window_title, null);
    defer window.destroy();
    window.setSizeLimits(-1, -1, -1, -1);

    var beui: Beui = .{};
    window.setUserPointer(@ptrCast(@alignCast(&beui)));

    var b2: Beui.beui_experiment.Beui2 = undefined;
    b2.init(gpa);
    defer b2.deinit();

    _ = window.setPosCallback(null);
    _ = window.setKeyCallback(&callbacks.keyCallback);
    _ = window.setSizeCallback(null);
    _ = window.setCharCallback(&callbacks.charCallback);
    _ = window.setDropCallback(null);
    _ = window.setScrollCallback(&callbacks.scrollCallback);
    _ = window.setCursorPosCallback(&callbacks.cursorPosCallback);
    _ = window.setCursorEnterCallback(&callbacks.cursorEnterCallback);
    _ = window.setMouseButtonCallback(&callbacks.mouseButtonCallback);
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

    var draw_list = draw_lists.RenderList.init(gpa);
    defer draw_list.deinit();

    var timer = try std.time.Timer.start();

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        tracy.frameMark();
        timer.reset();

        _ = arena_state.reset(.retain_capacity);
        draw_list.clear();

        interface.tickBegin();
        defer interface.tickEnd();

        var beui_vtable: BeuiVtable = .{ .window = window };
        beui.newFrame(.{
            .can_capture_keyboard = !zgui.io.getWantCaptureKeyboard(),
            .can_capture_mouse = !zgui.io.getWantCaptureMouse(),
            .draw_list = &draw_list,
            .arena = arena,
            .now_ms = std.time.milliTimestamp(),
            .user_data = @ptrCast(@alignCast(&beui_vtable)),
            .vtable = BeuiVtable.vtable,
        });
        defer beui.endFrame();

        zglfw.pollEvents();

        update(demo);

        // transparency test rainbows
        if (false) {
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
        }

        zgui.setNextWindowPos(.{ .x = 20.0, .y = 80.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });
        if (zgui.begin("My counter (editor 1)", .{})) {
            renderCounter(my_counter_component);
        }
        zgui.end();

        const gctx = demo.gctx;
        const fb_width = gctx.swapchain_descriptor.width;
        const fb_height = gctx.swapchain_descriptor.height;

        {
            const b2ft = tracy.traceNamed(@src(), "b2 frame");
            defer b2ft.end();

            const id = b2.newFrame(&beui, .{});
            const demo1_res = Beui.beui_experiment.scrollDemo(id.sub(@src()), .{ .available_size = .{ .w = @intCast(fb_width), .h = @intCast(fb_height) } });
            b2.endFrame(demo1_res, &draw_list);
        }

        my_text_editor.gui(&beui, .{ @floatFromInt(fb_width), @floatFromInt(fb_height) });

        zgui.showDemoWindow(null);

        zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });

        if (zgui_anywhere.beginWindow("Editor Settings", .{})) {
            defer zgui_anywhere.endWindow();

            zgui.text("Set syn hl:", .{});
            if (zgui.button("zig", .{})) {
                my_text_editor.core.setSynHl(zig_language.language());
            }
            if (zgui.button("markdown", .{})) {
                my_text_editor.core.setSynHl(markdown_language.language());
            }
            if (zgui.button("plaintext", .{})) {
                my_text_editor.core.setSynHl(null);
            }
        }

        if (zgui.begin("Demo Settings", .{})) {
            zgui.text(
                "Average : {d:.3} ms/frame ({d:.1} fps)",
                .{ demo.gctx.stats.average_cpu_time, demo.gctx.stats.fps },
            );
            zgui.text("draw_list items: {d} / {d}", .{ draw_list.vertices.items.len, draw_list.indices.items.len });
            zgui.text("click_count: {d}", .{beui.leftMouseClickedCount()});
            zgui.text("frame prepare time: {d}", .{std.fmt.fmtDuration(timer.read())});
        }
        zgui.end();

        draw(demo, &draw_list, &my_text_editor.glyphs);
    }
}
