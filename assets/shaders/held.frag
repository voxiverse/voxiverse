#version 460
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"

// What the hands hold: a flat colour (a voxel, with a little crunch: each
// voxel face a touch lighter or darker: the uv is one value a face) or a block's texture, lit by the sky
// and the brightness setting.

layout(set = 0, binding = 0) uniform texture2DArray array_textures[];
layout(set = 0, binding = 1) uniform sampler samplers[3];

layout(push_constant) uniform Push {
	Scene scene;
	uint textures;
	uint sampler_id;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec3 in_color;
layout(location = 2) flat in uint in_layer;
layout(location = 3) in float in_shade;
layout(location = 0) out vec4 out_color;

const uint FLAT = 0xffffu; // render/held_pass.odin: HELD_FLAT

float texel_noise(uvec2 t) {
	uint h = t.x * 0x8da6b343u ^ t.y * 0xd8163841u;
	h ^= h >> 15u;
	h *= 0x2c1b3c6du;
	h ^= h >> 12u;
	return float(h & 0xffu) / 255.0;
}

void main() {
	Scene s = push.scene;
	vec3 albedo;
	if (in_layer == FLAT) {
		albedo = in_color * (0.9 + 0.1 * texel_noise(uvec2(floor(in_uv))));
	} else {
		vec4 texel = texture(sampler2DArray(array_textures[push.textures], samplers[push.sampler_id]), vec3(in_uv, float(in_layer)));
		if (texel.a < 0.5) discard;
		albedo = texel.rgb;
	}
	vec3 light = max(s.sky_light.rgb, vec3(0.06)) * in_shade;
	light = mix(light, 1.0 - pow(1.0 - min(light, vec3(1.0)), vec3(4.0)), s.sky_light.w);
	out_color = vec4(albedo * light, 1.0);
}
