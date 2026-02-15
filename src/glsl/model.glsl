#version 460 core

struct ShaderData {
    mat4 projection;
    mat4 view;
    vec4 lightPos;
};

layout(set = 0, binding = 1) uniform ShaderUniform {
    ShaderData data;
};
layout(push_constant) uniform PushModel {
    mat4 model;
};

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

void main()
{
    mat4 modelMat = model;

    vec3 worldNormal = mat3(modelMat) * inNormal;
    vNormal = mat3(data.view) * worldNormal;

    vUV = inUV;
    vFactor = vec3(1.0);

    vec4 worldPos = modelMat * vec4(inPos, 1.0);
    vec4 viewPos = data.view * worldPos;

    gl_Position = data.projection * viewPos;

    vLightVec = data.lightPos.xyz - viewPos.xyz;
    vViewVec = -viewPos.xyz;
}
#endif

#ifdef FRAGMENT
layout(location = 0) in vec3 vNormal;
layout(location = 1) in vec2 vUV;
layout(location = 2) in vec3 vFactor;
layout(location = 3) in vec3 vLightVec;
layout(location = 4) in vec3 vViewVec;

layout(location = 0) out vec4 outColor;

void main()
{
    vec3 N = normalize(vNormal);
    vec3 L = normalize(vLightVec);
    vec3 V = normalize(vViewVec);
    vec3 R = reflect(-L, N);
    float diffuse = max(dot(N, L), 0.0025);
    float specular = pow(max(dot(R, V), 0.0), 16.0) * 0.75;
    vec3 texColor = texture(textures[0], vUV).rgb; // Use index 0; all are same
    vec3 finalColor = (diffuse * texColor + specular) * vFactor;
    outColor = vec4(finalColor, 1.0);
}
#endif
