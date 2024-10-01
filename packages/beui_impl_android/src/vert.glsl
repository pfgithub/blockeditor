#version 300 es

precision mediump float;

uniform vec2 screen_size;

VERT_INPUTS

out vec2 frag_uv;
out vec4 frag_tint;

void main() {
    vec2 p = (in_pos / screen_size) * vec2(2.0) - vec2(1.0);
    p = vec2(p.x, -p.y);
    frag_uv = in_uv;
    frag_tint = in_tint;
    gl_Position = vec4(p, 0.0, 1.0);
}