#version 460
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"

layout(set = 0, binding = 0) uniform texture2DArray array_textures[];
layout(set = 0, binding = 1) uniform sampler samplers[3];

layout(push_constant) uniform Push {
	Scene scene;
	layout(offset = 16) vec3 chunk_offset;
	uint textures;
	uint sampler_id;
} push;

layout(location = 0) in vec3 in_uvw;
layout(location = 1) in vec3 in_light;
layout(location = 2) in vec3 in_pos;
layout(location = 0) out vec4 out_color;

void main() {
	Scene s = push.scene;
	vec3 albedo = texture(sampler2DArray(array_textures[push.textures], samplers[push.sampler_id]), in_uvw).rgb;
	vec3 to = in_pos - s.camera.xyz;
	float fog = fog_amount(s, length(to.xz));
	vec3 color = albedo * in_light;
	if (fog > 0.0) color = mix(color, sky_color(s, normalize(to)), fog);
	// A cloud between us: only when the way here crosses the cloud slab
	// (never, on the ground below them).
	float y0 = s.camera.w, y1 = s.camera.w + to.y;
	if (max(y0, y1) > CLOUD_BOTTOM && min(y0, y1) < CLOUD_TOP) {
		float d = length(to);
		color = with_clouds(s, to / d, d, color);
	}
	out_color = vec4(color, 1.0);
}
