// What the world shaders share (render/world_pass.odin). Include after
// scene.glsl.

layout(push_constant) uniform Push {
	Scene scene;
	layout(offset = 16) vec3 chunk_offset; // this chunk's origin, from the camera chunk's origin
	uint textures;                         // texture id of the block texture array
	uint sampler_id;
	float time;                            // seconds (wrapped): moving water
} push;

// world_shade: a surface's colour at pos (from the camera chunk's origin):
// lit, fogged into the sky with distance, and behind any cloud between.
vec3 world_shade(Scene s, vec3 albedo, vec3 light, vec3 pos) {
	vec3 to = pos - s.camera.xyz;
	vec3 color = fog_mix(s, albedo * light, to);
	// A cloud between us: only when the way here crosses the cloud slab
	// (never, on the ground below them).
	float y0 = s.camera.w, y1 = s.camera.w + to.y;
	if (max(y0, y1) > CLOUD_BOTTOM && min(y0, y1) < CLOUD_TOP) {
		float d = length(to);
		color = with_clouds(s, to / d, d, color);
	}
	return color;
}
