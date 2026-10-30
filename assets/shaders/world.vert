#version 460
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"
#include "world.glsl"

// Chunk meshes (render/world_pass.odin, client/mesh), every layer: 8-byte
// vertices with a chunk-local position (in sixteenths of a block), face, AO
// level, light and texture layer. Positions are relative to the camera's
// chunk, so floats stay exact far from the origin.

layout(location = 0) in uint in_packed; // x | y << 9 | z << 18 | face << 27 | ao << 30
layout(location = 1) in uint in_layer; // texture layer (12 bits) | sky << 12 | block << 16 | surface << 20 | drop << 21
// The chunk draw table's record (Chunk_Draw), per instance: each indirect
// command's firstInstance is its mesh's slot. xyz the chunk, w its mesh's
// first vertex.
layout(location = 2) in ivec4 in_chunk;

layout(location = 0) out vec3 out_uvw; // texture coordinates and layer
layout(location = 1) out vec3 out_light;
layout(location = 2) out vec3 out_pos; // from the camera chunk's origin

// +x -x +y -y +z -z, then a plant's two diagonal planes.
const float FACE_LIGHT[8] = float[](0.80, 0.80, 1.00, 0.50, 0.65, 0.65, 0.90, 0.90);
const float AO_LIGHT[4] = float[](0.35, 0.60, 0.80, 1.00);
const vec3 LAMP_COLOR = vec3(1.00, 0.82, 0.58); // warm, like the lamp texture
const float PI = 3.14159265;

// brightness of light level l (0..15): a curve, so a few levels from a
// source still read as lit and darkness is dark (with a faint floor).
float brightness(uint l) {
	float x = float(l) / 15.0;
	return 0.03 + 0.97 * x * x * (3.0 - 2.0 * x) * x;
}

// lifted: light bent up by the brightness setting (lift, 0..1), most where it
// is darkest (as Minecraft's: a cave or a night is dim, not black).
vec3 lifted(vec3 light, float lift) {
	return mix(light, 1.0 - pow(1.0 - min(light, vec3(1.0)), vec3(4.0)), lift);
}

void main() {
	Scene s = push.scene;
	// This chunk's origin from the camera chunk's: whole blocks, exact.
	vec3 chunk_offset = vec3((in_chunk.xyz - s.camera_chunk.xyz) * 16);
	vec3 local = vec3(in_packed & 511u, (in_packed >> 9) & 511u, (in_packed >> 18) & 511u) / 16.0;
	uint face = (in_packed >> 27) & 7u;
	uint ao = (in_packed >> 30) & 3u;

	// One texture per block, aligned to the world grid; texture rows run
	// downwards, so v follows -y on the sides (and on a plant's planes).
	vec2 uv;
	if (face < 2u) uv = vec2(local.z, -local.y);
	else if (face < 4u) uv = vec2(local.x, local.z);
	else uv = vec2(local.x, -local.y);
	out_uvw = vec3(uv, float(in_layer & 0xfffu));

	// A liquid's open top sits a little low and swells slowly. The waves'
	// lengths divide the chunk's, so they meet across chunk borders.
	if (((in_layer >> 20) & 1u) != 0u) {
		float t = push.time;
		float drop = float((in_layer >> 21) & 7u) / 8.0; // eighths below the block's top
		local.y -= drop + 0.03 * sin(t * 1.3 + local.x * PI / 4.0) * cos(t * 0.9 + local.z * PI / 8.0);
	}
	vec3 pos = chunk_offset + local;
	gl_Position = s.view_proj * vec4(pos, 1.0);

	uint sky = (in_layer >> 12) & 15u;
	uint block = (in_layer >> 16) & 15u;
	// Sky light takes the colour of the time of day; lamps stay warm.
	vec3 light = max(s.sky_light.rgb * brightness(sky), LAMP_COLOR * brightness(block));
	light = lifted(light, s.sky_light.w);
	out_light = FACE_LIGHT[face] * AO_LIGHT[ao] * light;
	out_pos = pos;
}
