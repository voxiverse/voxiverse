#version 460
#extension GL_GOOGLE_include_directive : require
#include "scene.glsl"
#include "world.glsl"

// Chunk meshes (render/world_pass.odin, client/mesh), every layer: 8-byte
// vertices with a chunk-local position, face, AO level, light and texture
// layer. Positions are relative to the camera's chunk, so floats stay exact
// far from the origin.

layout(location = 0) in uint in_packed; // x | y << 5 | z << 10 | face << 15 | ao << 18 | sky << 20 | block << 24 | surface << 28 | drop << 29
layout(location = 1) in uint in_layer;

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

void main() {
	Scene s = push.scene;
	vec3 local = vec3(in_packed & 31u, (in_packed >> 5) & 31u, (in_packed >> 10) & 31u);
	uint face = (in_packed >> 15) & 7u;
	uint ao = (in_packed >> 18) & 3u;

	// One texture per block, aligned to the world grid; texture rows run
	// downwards, so v follows -y on the sides (and on a plant's planes).
	vec2 uv;
	if (face < 2u) uv = vec2(local.z, -local.y);
	else if (face < 4u) uv = vec2(local.x, local.z);
	else uv = vec2(local.x, -local.y);
	out_uvw = vec3(uv, float(in_layer));

	// A liquid's open top sits a little low and swells slowly. The waves'
	// lengths divide the chunk's, so they meet across chunk borders.
	if (((in_packed >> 28) & 1u) != 0u) {
		float t = push.time;
		float drop = float(in_packed >> 29) / 8.0; // eighths below the block's top
		local.y -= drop + 0.03 * sin(t * 1.3 + local.x * PI / 4.0) * cos(t * 0.9 + local.z * PI / 8.0);
	}
	vec3 pos = push.chunk_offset + local;
	gl_Position = s.view_proj * vec4(pos, 1.0);

	uint sky = (in_packed >> 20) & 15u;
	uint block = (in_packed >> 24) & 15u;
	// Sky light takes the colour of the time of day; lamps stay warm.
	vec3 light = max(s.sky_light.rgb * brightness(sky), LAMP_COLOR * brightness(block));
	out_light = FACE_LIGHT[face] * AO_LIGHT[ao] * light;
	out_pos = pos;
}
