#version 460
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"

// What falls (render/weather_pass.odin): quads, positions from the camera
// chunk's origin.

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color; // sRGB, alpha
layout(location = 3) in uint in_shape;

layout(push_constant) uniform Push {
	Scene scene;
} push;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color; // linear, alpha
layout(location = 2) flat out uint out_shape;
layout(location = 3) out vec3 out_pos;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
}

void main() {
	gl_Position = push.scene.view_proj * vec4(in_pos, 1.0);
	out_uv = in_uv;
	out_color = vec4(srgb_to_linear(in_color.rgb), in_color.a);
	out_shape = in_shape;
	out_pos = in_pos;
}
