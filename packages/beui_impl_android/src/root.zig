// we will be able to use tracy on android. tracy can connect over the network.

const c = @cImport({
    @cInclude("jni.h");
    @cInclude("GLES3/gl3.h");
    @cInclude("android/log.h");
});
const Beui = @import("beui").Beui;
const B2 = Beui.beui_experiment.Beui2;
const std = @import("std");
pub const std_options = std.Options{ .logFn = androidLog };
pub fn androidLog(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var res_al = std.ArrayList(u8).init(std.heap.c_allocator);
    defer res_al.deinit();

    const writer = res_al.writer();
    writer.print(format ++ "\n", args) catch return;

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    _ = c.__android_log_print(switch (message_level) {
        .debug => c.ANDROID_LOG_DEBUG,
        .info => c.ANDROID_LOG_INFO,
        .warn => c.ANDROID_LOG_WARN,
        .err => c.ANDROID_LOG_ERROR,
    }, if (scope == .default) "Zig" else @tagName(scope), "%.*s", @as(c_int, @intCast(res_al.items.len)), res_al.items.ptr);
}

const App = @import("app");

var app: App = undefined;
var beui: Beui = undefined;
var b2: Beui.beui_experiment.Beui2 = undefined;
var draw_list: Beui.draw_lists.RenderList = undefined;
var arena_state: std.heap.ArenaAllocator = undefined;

const BeuiVtable = struct {
    fn setClipboard(_: *const Beui.FrameCfg, _: [:0]const u8) void {
        std.log.info("TODO setClipboard", .{});
    }
    fn getClipboard(_: *const Beui.FrameCfg, _: *std.ArrayList(u8)) void {
        std.log.info("TODO getClipboard", .{});
    }
    pub const vtable: *const Beui.FrameCfgVtable = &.{
        .type_id = @typeName(BeuiVtable),
        .set_clipboard = &setClipboard,
        .get_clipboard = &getClipboard,
    };
};

export fn zig_resize(w: i32, h: i32) void {
    std.log.info("Frame resized to {d}/{d}", .{ w, h });
    c.glViewport(0, 0, w, h);
    screen_size = .{ w, h };
}
export fn zig_init_opengl() void {
    //_ = App;
    const gpa = std.heap.c_allocator;

    beui = .{};
    b2.init(gpa);
    app.init(std.heap.c_allocator);
    draw_list = .init(gpa);
    arena_state = .init(gpa);

    std.log.info("zig_init_opengl called", .{});
    createProgram();
}
export fn zig_opengl_renderFrame() void {
    _ = arena_state.reset(.retain_capacity);
    draw_list.clear();
    {
        var beui_vtable: BeuiVtable = .{};
        beui.newFrame(.{
            .can_capture_keyboard = true,
            .can_capture_mouse = true,
            .draw_list = &draw_list,
            .arena = arena_state.allocator(),
            .now_ms = std.time.milliTimestamp(),
            .user_data = @ptrCast(@alignCast(&beui_vtable)),
            .vtable = BeuiVtable.vtable,
        });
        defer beui.endFrame();

        applyEvents();

        const id = b2.newFrame(&beui, .{});
        const demo1_res = app.render(.{ .caller_id = id.sub(@src()), .constraints = .{ .available_size = .{ .w = screen_size[0], .h = screen_size[1] } } }, &beui);
        b2.endFrame(demo1_res, &draw_list);
    }

    const glyphs = &app.text_editor.layout_cache_2.glyphs;
    if (glyphs.modified) {
        glyphs.modified = false;
        c.glBindTexture(c.GL_TEXTURE_2D, ft_texture);
        defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RED, @intCast(glyphs.size), @intCast(glyphs.size), 0, c.GL_RED, c.GL_UNSIGNED_BYTE, glyphs.data.ptr);
    }

    c.glClear(c.GL_COLOR_BUFFER_BIT);

    c.glUseProgram(shader_program);
    c.glUniform2f(uniform_screen_size, @floatFromInt(screen_size[0]), @floatFromInt(screen_size[1]));
    c.glBindVertexArray(vao);
    c.glBindTexture(c.GL_TEXTURE_2D, ft_texture);
    c.glDrawArrays(c.GL_TRIANGLES, 0, vertices.len);
    c.glBindVertexArray(0);
}

fn applyEvents() void {}

// // Triangle vertices
const vertices = [_]Vertex{
    .{ .pos = .{ 500, 0 }, .uv = .{ -1.0, -1.0 }, .tint = .{ 255, 0, 0, 255 } },
    .{ .pos = .{ 1000, 1000 }, .uv = .{ -1.0, -1.0 }, .tint = .{ 0, 255, 0, 255 } },
    .{ .pos = .{ 0, 1000 }, .uv = .{ -1.0, -1.0 }, .tint = .{ 0, 0, 255, 255 } },
};

var shader_program: c.GLuint = 0;
var vao: c.GLuint = 0;
var uniform_screen_size: c.GLint = 0;
var screen_size: @Vector(2, i32) = .{ 100, 100 };
var ft_texture: c.GLuint = 0;

// // Function to compile a shader
fn compileShader(ty: c.GLenum, source: []const u8) c.GLuint {
    const shader: c.GLuint = c.glCreateShader(ty);
    const source_arr: [1][*c]const c.GLchar = .{source.ptr};
    const len_arr: [1]c.GLint = .{@intCast(source.len)};
    c.glShaderSource(shader, 1, &source_arr, &len_arr);
    c.glCompileShader(shader);

    // Check for compilation errors
    var success: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        var info_log_len: c.GLsizei = 0;
        c.glGetShaderInfoLog(shader, 512, &info_log_len, &info_log);
        std.log.err("Shader compilation failed: {s}", .{info_log[0..@intCast(info_log_len)]});
        @panic("compile failed");
    }
    return shader;
}

const Vertex = Beui.draw_lists.RenderListVertex;

fn setupAttribs(comptime V: type) void {
    comptime var index: c.GLuint = 0;
    const stride: c.GLint = @intCast(std.mem.alignForward(usize, @sizeOf(V), @alignOf(V)));
    inline for (@typeInfo(V).@"struct".fields) |field| {
        const offset: ?*const anyopaque = @ptrFromInt(@offsetOf(V, field.name));
        c.glEnableVertexAttribArray(index);
        switch (field.type) {
            @Vector(2, f32) => c.glVertexAttribPointer(index, 2, c.GL_FLOAT, c.GL_FALSE, stride, offset),
            @Vector(4, u8) => c.glVertexAttribPointer(index, 4, c.GL_UNSIGNED_BYTE, c.GL_TRUE, stride, offset),
            else => @compileError("TODO support vertex type: " ++ @typeName(field.type)),
        }
        index += 1;
    }
}
fn genInputs(comptime V: type) []const u8 {
    var result: []const u8 = "";
    var index: c.GLuint = 0;
    for (@typeInfo(V).@"struct".fields) |field| {
        const ty = switch (field.type) {
            @Vector(2, f32) => "vec2",
            @Vector(4, u8) => "vec4",
            else => @compileError("TODO support vertex type: " ++ @typeName(field.type)),
        };
        result = result ++ std.fmt.comptimePrint("layout(location = {d}) in {s} in_{s};\n", .{ index, ty, field.name });
        index += 1;
    }
    return result;
}

fn comptimeReplace(src: []const u8, replace_str: []const u8, replace_with: []const u8) []const u8 {
    const offset = std.mem.indexOf(u8, src, replace_str) orelse @compileError("missing");
    return src[0..offset] ++ replace_with ++ src[offset + replace_str.len ..];
}

const vert_shader: []const u8 = comptimeReplace(@embedFile("vert.glsl"), "VERT_INPUTS\n", genInputs(Vertex));
fn createProgram() void {
    const vertex_shader: c.GLuint = compileShader(c.GL_VERTEX_SHADER, vert_shader);
    const fragment_shader: c.GLuint = compileShader(c.GL_FRAGMENT_SHADER, @embedFile("frag.glsl"));

    shader_program = c.glCreateProgram();
    c.glAttachShader(shader_program, vertex_shader);
    c.glAttachShader(shader_program, fragment_shader);
    c.glLinkProgram(shader_program);

    // Check for linking errors
    var success: c.GLint = 0;
    c.glGetProgramiv(shader_program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        var info_log_len: c.GLsizei = 0;
        c.glGetProgramInfoLog(shader_program, info_log.len, &info_log_len, &info_log);
        std.log.err("Program linking failed: {s}", .{info_log[0..@intCast(info_log_len)]});
        @panic("link failed");
    }

    c.glDeleteShader(vertex_shader);
    c.glDeleteShader(fragment_shader);

    uniform_screen_size = c.glGetUniformLocation(shader_program, "screen_size");

    // Create a Vertex Array Object (VAO)
    {
        c.glGenVertexArrays(1, &vao);
        var vbo: c.GLuint = 0;
        c.glGenBuffers(1, &vbo);
        c.glBindVertexArray(vao);
        defer c.glBindVertexArray(0);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
        defer c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
        c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(std.mem.alignForward(usize, @sizeOf(Vertex), @alignOf(Vertex)) * vertices.len), &vertices, c.GL_STATIC_DRAW);
        setupAttribs(Vertex);
    }

    // create textures
    {
        c.glGenTextures(1, &ft_texture);
        c.glBindTexture(c.GL_TEXTURE_2D, ft_texture);
        defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    }
}
