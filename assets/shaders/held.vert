#version 460
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"

// What the hands hold (render/held_pass.odin): voxels, an arm and a block's
// own mesh. Positions are in the scene's space already (view space for the
// view model, from the camera chunk's origin for a held item in the world).

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color; // sRGB
layout(location = 3) in uint in_layer_shade; // layer | shade << 16

layout(push_constant) uniform Push {
	Scene scene;
	uint textures;
	uint sampler_id;
} push;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec3 out_color; // linear
layout(location = 2) flat out uint out_layer;
layout(location = 3) out float out_shade;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
}

void main() {
	gl_Position = push.scene.view_proj * vec4(in_pos, 1.0);
	out_uv = in_uv;
	out_color = srgb_to_linear(in_color.rgb);
	out_layer = in_layer_shade & 0xffffu;
	out_shade = float(in_layer_shade >> 16) / 255.0;
}
