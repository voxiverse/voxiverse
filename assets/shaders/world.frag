#version 460
#extension GL_EXT_nonuniform_qualifier : require

layout(set = 0, binding = 0) uniform texture2DArray array_textures[];
layout(set = 0, binding = 1) uniform sampler samplers[3];

layout(push_constant) uniform Push {
	mat4 view_proj;
	vec3 chunk_offset;
	uint textures;
	vec3 camera;
	uint sampler_id;
	vec4 fog;
} push;

layout(location = 0) in vec3 in_uvw;
layout(location = 1) in float in_light;
layout(location = 2) in float in_fog;
layout(location = 0) out vec4 out_color;

void main() {
	vec3 albedo = texture(sampler2DArray(array_textures[push.textures], samplers[push.sampler_id]), in_uvw).rgb;
	out_color = vec4(mix(albedo * in_light, push.fog.rgb, in_fog), 1.0);
}
