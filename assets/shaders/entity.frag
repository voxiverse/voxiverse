#version 460
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"

// Entities: crunchy texels (8 across a face, each a little lighter or
// darker), two pixel eyes on a face, the sky's light and the world's fog.

layout(push_constant) uniform Push {
	Scene scene;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec3 in_color;
layout(location = 2) flat in uint in_part;
layout(location = 3) in float in_shade;
layout(location = 4) in vec3 in_pos;
layout(location = 0) out vec4 out_color;

const uint FACE = 3u; // render/entity_pass.odin: Entity_Part.Face

float texel_noise(uvec2 t, uint part) {
	uint h = t.x * 0x8da6b343u ^ t.y * 0xd8163841u ^ part * 0xcb1ab31fu;
	h ^= h >> 15u;
	h *= 0x2c1b3c6du;
	h ^= h >> 12u;
	return float(h & 0xffu) / 255.0;
}

void main() {
	Scene s = push.scene;
	uvec2 t = uvec2(clamp(in_uv * 8.0, vec2(0.0), vec2(7.0)));
	vec3 albedo = in_color * (0.82 + 0.18 * texel_noise(t, in_part));
	if (in_part == FACE && t.y == 3u && (t.x == 2u || t.x == 5u)) albedo = vec3(0.02);
	vec3 light = max(s.sky_light.rgb, vec3(0.06)) * in_shade;
	vec3 color = albedo * light;
	color = fog_mix(s, color, in_pos - s.camera.xyz);
	out_color = vec4(color, 1.0);
}
