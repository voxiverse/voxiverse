#version 460
#extension GL_EXT_nonuniform_qualifier : require

layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[3];

layout(push_constant) uniform Push {
	vec2 screen_size;
	uint atlas;
	uint sampler_id;
} push;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 0) out vec4 out_color;

void main() {
	// The atlas is coverage (R8): glyph shapes, and a white texel for rects.
	float coverage = texture(sampler2D(textures[push.atlas], samplers[push.sampler_id]), in_uv).r;
	out_color = vec4(in_color.rgb, in_color.a * coverage);
}
