#version 450

#define SOLID_MODE 0
#define TEXT_MODE 1
layout(push_constant) uniform PushConstants {
    vec4 color;
    float pxRange;
    u32 mode;
} pc;

#ifdef VERTEX
layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 0) out vec2 out_uv;
void main() {
    gl_Position = vec4(in_pos, 0.0, 1.0);
    out_uv = in_uv;
}
#endif

#ifdef FRAGMENT
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D fontAtlas;

float median(vec3 v) {
    return max(min(v.r, v.g), min(max(v.r, v.g), v.b));
}

void main() {
    if (pc.mode == SOLID_MODE) {
        out_color = pc.color;
        return;
    }

    // SDF TEXT (original)
    vec3 textureSampler = texture(fontAtlas, uv).rgb;
    float sigDist = median(textureSampler) - 0.5;
    float opacity = clamp(sigDist * pc.pxRange + 0.5, 0.0, 1.0);
    if (opacity < 0.01) discard;
    out_color = vec4(pc.color.rgb, pc.color.a * opacity);
}
#endif
