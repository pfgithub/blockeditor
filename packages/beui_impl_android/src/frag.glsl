#version 300 es

precision mediump float;

//layout(set = 0, binding = 1) uniform sampler2D image;

in vec2 frag_uv;
in vec4 frag_tint;

out vec4 out_color;

vec4 premultiply(vec4 tint) {
    return vec4(tint.rgb * tint.a, tint.a);
}

void main() {
    //vec4 color = texture(image, frag_uv);
    vec4 color = vec4(1.0, 1.0, 1.0, 1.0);

    if (frag_uv.x < 0.0) {
        out_color = premultiply(frag_tint);
        return;
    }

    if (true) {
        color = vec4(1.0, 1.0, 1.0, color.r);
    }
    
    color *= frag_tint;
    out_color = premultiply(color);
}