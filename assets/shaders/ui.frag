#version 460
#extension GL_EXT_nonuniform_qualifier : require

layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[3];

layout(push_constant) uniform Push {
	vec2 screen_size;
	uint atlas;
	uint sampler_id;
	uint linear; // 1: the texels are already linear (a rendered picture)
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 0) out vec4 out_color;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
}

void main() {
	// The atlas is RGBA8 (sRGB): glyphs are white with their coverage as alpha,
	// a white texel serves rects, icons are coloured; times the vertex colour.
	vec4 texel = texture(sampler2D(textures[push.atlas], samplers[push.sampler_id]), in_uv);
	vec3 rgb = push.linear == 1u ? texel.rgb : srgb_to_linear(texel.rgb);
	out_color = vec4(in_color.rgb * rgb, in_color.a * texel.a);
}
