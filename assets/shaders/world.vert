#version 460

// Chunk meshes (render/world_pass.odin, client/mesh): 8-byte vertices with
// a chunk-local position, face, AO level and texture layer. Positions are
// relative to the camera's chunk, so floats stay exact far from the origin.

layout(location = 0) in uint in_packed; // x | y << 5 | z << 10 | face << 15 | ao << 18
layout(location = 1) in uint in_layer;

layout(push_constant) uniform Push {
	mat4 view_proj;     // from the camera chunk's origin
	vec3 chunk_offset;  // this chunk's origin, from the camera chunk's origin
	uint textures;      // texture id of the block texture array
	vec3 camera;        // camera position, from the camera chunk's origin
	uint sampler_id;
	vec4 fog;           // rgb: colour (linear), a: distance where fog is total
} push;

layout(location = 0) out vec3 out_uvw; // texture coordinates and layer
layout(location = 1) out float out_light;
layout(location = 2) out float out_fog;

const float FACE_LIGHT[6] = float[](0.80, 0.80, 1.00, 0.50, 0.65, 0.65); // +x -x +y -y +z -z
const float AO_LIGHT[4] = float[](0.35, 0.60, 0.80, 1.00);

void main() {
	vec3 local = vec3(in_packed & 31u, (in_packed >> 5) & 31u, (in_packed >> 10) & 31u);
	uint face = (in_packed >> 15) & 7u;
	uint ao = (in_packed >> 18) & 3u;
	vec3 pos = push.chunk_offset + local;
	gl_Position = push.view_proj * vec4(pos, 1.0);

	// One texture per block, aligned to the world grid; texture rows run
	// downwards, so v follows -y on the sides.
	vec2 uv;
	if (face < 2u) uv = vec2(local.z, -local.y);
	else if (face < 4u) uv = vec2(local.x, local.z);
	else uv = vec2(local.x, -local.y);
	out_uvw = vec3(uv, float(in_layer));
	out_light = FACE_LIGHT[face] * AO_LIGHT[ao];

	float distance = length(pos.xz - push.camera.xz);
	out_fog = clamp((distance - 0.6 * push.fog.a) / (0.4 * push.fog.a), 0.0, 1.0);
}
