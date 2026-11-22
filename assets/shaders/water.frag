#version 460
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"
#include "world.glsl"

// The translucent layer: water, blended over what is behind it; and a
// gate's open surface (portal), drawn here rather than from its texture.

layout(set = 0, binding = 0) uniform texture2DArray array_textures[];
layout(set = 0, binding = 1) uniform sampler samplers[3];

layout(location = 0) in vec3 in_uvw;
layout(location = 1) in vec3 in_light;
layout(location = 2) in vec3 in_pos;
layout(location = 3) flat in uint in_portal; // a gate's open surface: 1 | its rim's sides << 1 (-h, +h, -y, +y)
layout(location = 0) out vec4 out_color;

// PORTAL_LAYERS: how many sheets of motes lie behind the surface.
const int PORTAL_LAYERS = 4;

float hash12(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

vec2 hash22(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yzx + 33.33);
	return fract((q.xx + q.yz) * q.zy);
}

// portal: a gate's open surface at pos, n its normal: a dark void with depth
// behind the plane. Sheets of small motes lie at growing depths along the
// eye's ray, so they slide against each other as the eye moves; each drifts
// and turns slowly at its own rate, the void shimmers faintly, and a thin
// restless rim flickers along the sides of the cell that meet the frame
// (sides: -h, +h, -y, +y as bits, h the plane's horizontal axis). Its own
// light: neither lit nor shaded by the world's.
vec3 portal(Scene s, vec3 pos, vec3 n, uint sides) {
	vec3 view = normalize(pos - s.camera.xyz);
	if (dot(n, view) < 0.0) n = -n; // (into the depth, whichever side the eye is on)
	float facing = max(dot(n, view), 0.25);
	bool across_z = abs(n.x) > abs(n.z); // the plane spans z and y (else x and y)
	// Where pos is in the world, every 256 blocks the same (floats stay exact).
	vec3 world = pos + vec3((s.camera_chunk.xyz & 15) * 16);
	float t = push.time;
	vec3 color = vec3(0.008, 0.006, 0.024);
	for (int k = 0; k < PORTAL_LAYERS; k++) {
		float layer = float(k);
		vec3 deep = world + view * ((0.4 + 1.5 * layer) / facing);
		vec2 q = across_z ? deep.zy : deep.xy;
		float turn = t * (0.06 + 0.025 * layer);
		q += 0.3 * vec2(sin(q.y * 0.55 + turn * 2.0), cos(q.x * 0.45 - turn * 1.6));
		q += vec2(0.05, -0.03) * t * (0.4 + 0.3 * layer);
		vec2 g = q * (2.0 + layer);
		vec2 cell = floor(g);
		vec2 mote = 0.15 + 0.7 * hash22(cell + layer * 37.0);
		float here = step(0.5, hash12(cell + 91.0 + layer * 13.0));
		float twinkle = 0.65 + 0.35 * sin(t * (0.8 + 1.7 * mote.x) + mote.y * 6.283);
		float point = smoothstep(0.1, 0.0, length(fract(g) - mote));
		color += here * twinkle * point / (1.0 + 0.7 * layer) * mix(vec3(0.5, 0.7, 1.0), vec3(0.75, 0.55, 1.0), mote.x);
	}
	vec2 p = across_z ? world.zy : world.xy;
	color += vec3(0.018, 0.012, 0.045) * (0.5 + 0.5 * sin(p.x * 1.3 + p.y * 0.9 + t * 0.6) * sin(p.y * 1.1 - t * 0.45));
	vec2 f = fract(p);
	float edge = 1.0;
	if ((sides & 1u) != 0u) edge = min(edge, f.x);
	if ((sides & 2u) != 0u) edge = min(edge, 1.0 - f.x);
	if ((sides & 4u) != 0u) edge = min(edge, f.y);
	if ((sides & 8u) != 0u) edge = min(edge, 1.0 - f.y);
	float flicker = 0.5 + 0.5 * sin(t * 3.1 + (p.x + p.y) * 4.0) * sin(t * 1.9 - p.y * 7.0);
	float wobble = 0.05 * sin(t * 2.3 + (p.x + p.y) * 5.0);
	color += (1.0 - smoothstep(0.0, 0.16 + wobble, edge)) * (0.35 + 0.65 * flicker) * vec3(0.2, 0.26, 0.5);
	return color;
}

void main() {
	vec3 n = normalize(cross(dFdx(in_pos), dFdy(in_pos))); // (outside the branch: derivatives)
	if ((in_portal & 1u) != 0u) {
		vec3 color = fog_mix(push.scene, portal(push.scene, in_pos, n, in_portal >> 1), in_pos - push.scene.camera.xyz);
		out_color = vec4(graded(push.scene, color, gl_FragCoord.xy), 0.95);
		return;
	}
	vec4 texel = texture(sampler2DArray(array_textures[push.textures], samplers[push.sampler_id]), in_uvw);
	out_color = vec4(graded(push.scene, world_shade(push.scene, texel.rgb, in_light, in_pos), gl_FragCoord.xy), texel.a);
}
