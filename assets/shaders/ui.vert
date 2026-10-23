#version 460

// UI: pixel-space vertices from the ui package; sRGB vertex colours decoded
// to linear here (the swapchain encodes back to sRGB on write).

layout(location = 0) in vec2 in_pos; // pixels
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color; // sRGB, unorm8

layout(push_constant) uniform Push {
	vec2 screen_size; // pixels
	uint atlas;       // texture id
	uint sampler_id;
} push;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
}

void main() {
	gl_Position = vec4(in_pos / push.screen_size * 2.0 - 1.0, 0.0, 1.0);
	out_uv = in_uv;
	out_color = vec4(srgb_to_linear(in_color.rgb), in_color.a);
}
