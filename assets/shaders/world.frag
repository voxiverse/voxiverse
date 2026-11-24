#version 460
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"
#include "world.glsl"

// The opaque layer: blocks.

layout(set = 0, binding = 0) uniform texture2DArray array_textures[];
layout(set = 0, binding = 1) uniform sampler samplers[3];

layout(location = 0) in vec3 in_uvw;
layout(location = 1) in vec3 in_light;
layout(location = 2) in vec3 in_pos;
layout(location = 3) flat in uint in_portal; // (world.vert's for water.frag: never on this layer)
layout(location = 4) in float in_shade;
layout(location = 0) out vec4 out_color;

void main() {
	vec4 texel = texture(sampler2DArray(array_textures[push.textures], samplers[push.sampler_id]), in_uvw);
	vec3 light = lit(push.scene, in_light, in_shade, in_pos, facing_normal(dFdx(in_pos), dFdy(in_pos), push.scene.camera.xyz - in_pos));
	out_color = vec4(graded(push.scene, world_shade(push.scene, texel.rgb, light, in_pos), gl_FragCoord.xy), 1.0);
}
