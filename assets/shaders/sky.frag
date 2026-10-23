#version 460
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"

// The sky behind the world: gradient and glow (scene.glsl's sky_color),
// then the crunchy parts: a square pixel sun and moon, pixel stars that turn
// with the sky, and the blocky clouds (scene.glsl; the world shader draws
// the ones in front of terrain). It writes no depth, so the GPU runs it
// only where the world left the screen empty.

layout(push_constant) uniform Push {
	Scene scene;
} push;

layout(location = 0) in vec3 in_ray; // towards this pixel (not normalized)
layout(location = 0) out vec4 out_color;

const float SUN_SIZE = 0.085;  // half-width, in tangent units
const float MOON_SIZE = 0.06;
const float SUN_PIXELS = 16.0; // texels across the sun
const float STAR_CELLS = 360.0; // per unit of the star cube face

uint hash(uvec3 v) {
	uint h = v.x * 0x8da6b343u ^ v.y * 0xd8163841u ^ v.z * 0xcb1ab31fu;
	h ^= h >> 16u;
	h *= 0x7feb352du;
	h ^= h >> 15u;
	h *= 0x846ca68bu;
	h ^= h >> 16u;
	return h;
}

float hash01(uvec3 v) {
	return float(hash(v) & 0xffffffu) / float(0xffffff);
}

// body_texel: direction dir on the texel grid of a square body (sun or
// moon) centred on direction `at`: texels 0..SUN_PIXELS-1 cover the body,
// and the grid carries on around it (for the halo). Behind: a large value.
// The square stands upright (its up is world up, as seen from the camera);
// the bodies never pass overhead (SUN_TILT), so that is always defined.
vec2 body_texel(vec3 dir, vec3 at, float size) {
	float d = dot(dir, at);
	if (d < 0.97) return vec2(1e6); // far from it (body and halo lie within 0.975)
	vec3 up = normalize(vec3(0.0, 1.0, 0.0) - at * at.y);
	vec3 right = cross(at, up);
	vec2 p = vec2(dot(dir, right), dot(dir, up)) / d / size; // -1..1 on the body
	return floor((p * 0.5 + 0.5) * SUN_PIXELS);
}

bool on_body(vec2 t) {
	return all(greaterThanEqual(t, vec2(0.0))) && all(lessThan(t, vec2(SUN_PIXELS)));
}

// ring: how many texels outside the body t is (0 on it), square rings.
float ring(vec2 t) {
	vec2 outside = max(max(-t, t - (SUN_PIXELS - 1.0)), 0.0);
	return max(outside.x, outside.y);
}

// sun_color: a white core with stepped rims, one texel at a time; tint
// (redder near the horizon) colours the rims more than the core.
vec3 sun_color(vec2 t, vec3 tint) {
	vec2 c = abs(t - (SUN_PIXELS - 1.0) * 0.5);
	float r = max(c.x, c.y);
	if (r > 6.5) return vec3(1.0, 0.62, 0.22) * tint;
	if (r > 4.5) return vec3(1.0, 0.86, 0.52) * mix(vec3(1.0), tint, 0.5);
	return vec3(1.0, 1.0, 0.94);
}

vec3 moon_color(vec2 t) {
	vec3 base = vec3(0.55, 0.58, 0.66);
	float n = hash01(uvec3(uvec2(t), 77u));
	if (n < 0.18) base *= 0.62; // craters
	vec2 c = abs(t - (SUN_PIXELS - 1.0) * 0.5);
	if (max(c.x, c.y) > 6.5) base *= 0.8;
	return base;
}

// stars: a sparse grid of single cells on a cube around the camera, in the
// frame of the turning sky.
float stars(Scene s, vec3 dir) {
	vec3 sun = s.sun.xyz;
	vec3 axis = s.axis.xyz;
	vec3 v = vec3(dot(dir, sun), dot(dir, cross(axis, sun)), dot(dir, axis));
	vec3 a = abs(v);
	uint face;
	vec2 uv;
	if (a.x >= a.y && a.x >= a.z) { face = v.x > 0.0 ? 0u : 1u; uv = v.yz / a.x; }
	else if (a.y >= a.z) { face = v.y > 0.0 ? 2u : 3u; uv = v.xz / a.y; }
	else { face = v.z > 0.0 ? 4u : 5u; uv = v.xy / a.z; }
	uvec2 cell = uvec2(floor((uv * 0.5 + 0.5) * STAR_CELLS));
	float h = hash01(uvec3(cell, face));
	if (h > 0.0035) return 0.0;
	return 0.35 + 0.65 * hash01(uvec3(cell, face + 11u)); // brightness
}

void main() {
	Scene s = push.scene;
	vec3 dir = normalize(in_ray);
	vec3 color = sky_color(s, dir);

	// Stars, then the sun and moon over them.
	if (s.sun.w > 0.0) color += vec3(stars(s, dir) * s.sun.w * smoothstep(-0.02, 0.08, dir.y));
	// Below the horizon the ground would hide the sun and moon, loaded or not.
	if (dir.y >= 0.0) {
		vec3 tint = mix(vec3(1.0), vec3(1.0, 0.62, 0.42), s.glow.w); // redder when low
		vec2 t = body_texel(dir, s.sun.xyz, SUN_SIZE);
		if (on_body(t)) {
			color = sun_color(t, tint);
		} else {
			// A halo of square rings, fading out texel by texel.
			float r = ring(t);
			if (r <= 6.0) color += vec3(1.0, 0.85, 0.55) * tint * (0.32 - 0.05 * r);
		}
		t = body_texel(dir, -s.sun.xyz, MOON_SIZE);
		if (on_body(t)) color = mix(color, moon_color(t), 0.4 + 0.6 * s.sun.w);
	}

	color = with_clouds(s, dir, CLOUD_FAR, color);
	out_color = vec4(color, 1.0);
}
