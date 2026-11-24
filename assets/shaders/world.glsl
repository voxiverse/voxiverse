// What the world shaders share (render/world_pass.odin). Include after
// scene.glsl.

// The same for every world draw.
layout(push_constant) uniform Push {
	Scene scene;
	uint textures;   // texture id of the block texture array
	uint sampler_id;
	float time;      // seconds (wrapped): moving water
} push;

// lifted: light bent up by the brightness setting (lift, 0..1), most where it is darkest
// (as Minecraft's: a cave or a night is dim, not black).
vec3 lifted(vec3 light, float lift) {
	return mix(light, 1.0 - pow(1.0 - min(light, vec3(1.0)), vec3(4.0)), lift);
}

// lit: the light a surface at pos facing n takes: its mesh's (light), or where a light that
// moves (scene.glsl's moving_light) reaches it brighter, that light, shaded by face and corner
// as the mesh's is (shade) and lifted by the brightness setting. With no light that moves
// (the scene's light_count, the same for the whole draw) it is the mesh's, unchanged.
vec3 lit(Scene s, vec3 light, float shade, vec3 pos, vec3 n) {
	if (s.light_count.x == 0) return light;
	vec3 moving = moving_light(s, pos, n);
	return max(light, lifted(moving + s.ambient.rgb, s.sky_light.w) * shade);
}

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
