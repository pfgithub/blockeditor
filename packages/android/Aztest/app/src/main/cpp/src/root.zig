const c = @cImport({
    @cInclude("jni.h");
    @cInclude("GLES3/gl3.h");
    @cInclude("android/log.h");
});
const std = @import("std");
pub const std_options = std.Options{ .logFn = androidLog };
pub fn androidLog(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    var res_al = std.ArrayList(u8).init(std.heap.c_allocator);
    defer res_al.deinit();

    const writer = res_al.writer();
    writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    _ = c.__android_log_print(switch (message_level) {
        .debug => c.ANDROID_LOG_DEBUG,
        .info => c.ANDROID_LOG_INFO,
        .warn => c.ANDROID_LOG_WARN,
        .err => c.ANDROID_LOG_ERROR,
    }, "NativeTriangle", "%.*s", @as(c_int, @intCast(res_al.items.len)), res_al.items.ptr);
}

const App = @import("app");

export fn zig_init_opengl() void {
    //_ = App;

    std.log.info("zig_init_opengl called", .{});
    createProgram();
}
export fn zig_opengl_renderFrame() void {
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    c.glUseProgram(shader_program);
    c.glBindVertexArray(vao);
    c.glDrawArrays(c.GL_TRIANGLES, 0, @divExact(vertices.len, 3));
    c.glBindVertexArray(0);
}

// // Simple vertex and fragment shader to render a triangle
const vertex_shader_source =
    \\#version 300 es
    \\layout (location = 0) in vec4 aPosition;
    \\void main() {
    \\    gl_Position = aPosition;
    \\}
;

const fragment_shader_source =
    \\#version 300 es
    \\precision mediump float;
    \\out vec4 fragColor;
    \\void main() {
    \\    fragColor = vec4(1.0, 0.0, 0.0, 1.0); // Red color
    \\}
;

// // Triangle vertices
const vertices = [_]c.GLfloat{
    0,    0.5,  0,
    -0.5, -0.5, 0,
    0.5,  -0.5, 0,
};

var shader_program: c.GLuint = 0;
var vao: c.GLuint = 0;

// // Function to compile a shader
fn compileShader(ty: c.GLenum, source: [*:0]const u8) c.GLuint {
    const shader: c.GLuint = c.glCreateShader(ty);
    c.glShaderSource(shader, 1, &source, null);
    c.glCompileShader(shader);

    // Check for compilation errors
    var success: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        var info_log_len: c.GLsizei = 0;
        c.glGetShaderInfoLog(shader, 512, &info_log_len, &info_log);
        std.log.err("Shader compilation failed: {s}", .{info_log[0..@intCast(info_log_len)]});
    }
    return shader;
}

// Function to create the OpenGL program

fn createProgram() void {
    const vertex_shader: c.GLuint = compileShader(c.GL_VERTEX_SHADER, vertex_shader_source);
    const fragment_shader: c.GLuint = compileShader(c.GL_FRAGMENT_SHADER, fragment_shader_source);

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
    }

    c.glDeleteShader(vertex_shader);
    c.glDeleteShader(fragment_shader);

    // Create a Vertex Array Object (VAO)
    c.glGenVertexArrays(1, &vao);
    var vbo: c.GLuint = 0;
    c.glGenBuffers(1, &vbo);

    c.glBindVertexArray(vao);

    // Bind and set vertex buffer data
    c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(c.GLfloat) * vertices.len, &vertices, c.GL_STATIC_DRAW);

    // Set the vertex attribute pointer
    c.glVertexAttribPointer(0, 3, c.GL_FLOAT, c.GL_FALSE, 3 * @sizeOf(f32), null);
    c.glEnableVertexAttribArray(0);

    c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
    c.glBindVertexArray(0);
}
