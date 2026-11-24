#version 460
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"

// What falls: a rain streak fades at its sides and its ends; a snowflake is
// a soft round dot. Lit by the sky (and the lightning, which is in its
// light), fogged like the world.

layout(push_constant) uniform Push {
	Scene scene;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 2) flat in uint in_shape;
layout(location = 3) in vec3 in_pos;
layout(location = 0) out vec4 out_color;

const uint FLAKE = 1u; // render/weather_pass.odin: Drop_Shape.Flake

void main() {
	Scene s = push.scene;
	float a;
	if (in_shape == FLAKE) {
		float r = length(vec2(in_uv.x, in_uv.y * 2.0 - 1.0));
		a = 1.0 - smoothstep(0.35, 1.0, r);
	} else {
		a = (1.0 - in_uv.x * in_uv.x) * smoothstep(0.0, 0.25, in_uv.y) * smoothstep(1.0, 0.6, in_uv.y);
	}
	vec3 light = max(s.sky_light.rgb + s.ambient.rgb, s.figure.rgb);
	vec3 color = fog_mix(s, in_color.rgb * light, in_pos - s.camera.xyz);
	out_color = vec4(graded(s, color, gl_FragCoord.xy), in_color.a * a);
}
