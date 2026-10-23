#version 460

// Debug lines (render/debug_pass.odin): positions relative to the camera's
// chunk, sRGB vertex colours.

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec4 in_color;

layout(push_constant) uniform Push {
	mat4 view_proj;
} push;

layout(location = 0) out vec4 out_color;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
}

void main() {
	gl_Position = push.view_proj * vec4(in_pos, 1.0);
	out_color = vec4(srgb_to_linear(in_color.rgb), in_color.a);
}
