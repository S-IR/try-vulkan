#version 460 core
// #extension GL_EXT_nonuniform_qualifie    r : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

struct ShaderData {
    mat4 projection;
    mat4 view;
    mat4 model[3];
    vec4 lightPos;
    uint selected;
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ShaderDataRef {
    ShaderData data;
};

layout(push_constant) uniform PushConstants {
    uint64_t shaderDataAddr;
} pc;

#define MAX_TEXTURES 8   

layout(set = 0, binding = 0) uniform sampler2D textures[MAX_TEXTURES];

#ifdef VERTEX
layout(location = 0) in vec3 inPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inUV;
layout(location = 0) out vec3 vNormal;
layout(location = 1) out vec2 vUV;
layout(location = 2) out vec3 vFactor;
layout(location = 3) out vec3 vLightVec;
layout(location = 4) out vec3 vViewVec;
layout(location = 5) flat out uint vInstanceIndex;


void main()
{
    ShaderDataRef ref = ShaderDataRef(pc.shaderDataAddr);
    ShaderData data = ref.data;

    mat4 modelMat = data.model[gl_InstanceIndex];
    vec3 worldNormal = mat3(modelMat) * inNormal;
    vNormal = mat3(data.view) * worldNormal;
    vUV = inUV;
    vInstanceIndex = gl_InstanceIndex;

    vec4 worldPos = modelMat * vec4(inPos, 1.0);
    vec4 viewPos = data.view * worldPos;
    gl_Position = data.projection * viewPos;

    vLightVec = data.lightPos.xyz - viewPos.xyz;
    vViewVec = -viewPos.xyz;
    vFactor = (data.selected == gl_InstanceIndex) ? vec3(3.0) : vec3(1.0);
}
#endif

#ifdef FRAGMENT
layout(location = 0) in vec3 vNormal;
layout(location = 1) in vec2 vUV;
layout(location = 2) in vec3 vFactor;
layout(location = 3) in vec3 vLightVec;
layout(location = 4) in vec3 vViewVec;
layout(location = 5) flat in uint vInstanceIndex;
layout(location = 0) out vec4 outColor;


void main()
{
    vec3 N = normalize(vNormal);
    vec3 L = normalize(vLightVec);
    vec3 V = normalize(vViewVec);
    vec3 R = reflect(-L, N);
    float diffuse = max(dot(N, L), 0.0025);
    float specular = pow(max(dot(R, V), 0.0), 16.0) * 0.75;
    vec3 texColor = texture(textures[vInstanceIndex], vUV).rgb;
    vec3 finalColor = (diffuse * texColor + specular) * vFactor;
    outColor = vec4(finalColor, 1.0);
}
#endif
