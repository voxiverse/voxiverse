#version 460
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"

// Entities (render/entity_pass.odin): boxes, positions from the camera
// chunk's origin.

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color; // sRGB
layout(location = 3) in uvec2 in_part_shade;

layout(push_constant) uniform Push {
	Scene scene;
} push;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec3 out_color; // linear
layout(location = 2) flat out uint out_part;
layout(location = 3) out float out_shade;
layout(location = 4) out vec3 out_pos;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
}

void main() {
	gl_Position = push.scene.view_proj * vec4(in_pos, 1.0);
	out_uv = in_uv;
	out_color = srgb_to_linear(in_color.rgb);
	out_part = in_part_shade.x;
	out_shade = float(in_part_shade.y) / 255.0;
	out_pos = in_pos;
}
