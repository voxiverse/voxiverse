// The occlusion test against the depth pyramid (render/hiz.odin; its CPU
// twin is occlusion_reference there, written from the same rules). Include
// after #version; the includer is a compute shader on the shared pipeline
// layout, with the bindless set bound (gpu.bind_globals_compute).
//
// The rules:
// 1. Project the box's eight corners. If any has w <= HIZ_NEAR_W (at or
//    behind the eye): not occluded.
// 2. The corners' NDC rectangle, clamped to the screen, in level-0 texels.
//    Empty after clamping: not occluded (the frustum test owns that case).
// 3. The level: the smallest l with 2^l at least the rectangle's larger
//    extent in level-0 texels (at most mips - 1), where it covers at most
//    2 x 2 texels. Fetch those (clamped to the level's size): the farthest
//    depth there is their minimum.
// 4. The box's nearest depth is the largest of its corners' z / w: occluded
//    when that is below the pyramid's farthest (strictly).

#extension GL_EXT_samplerless_texture_functions : require
#extension GL_EXT_nonuniform_qualifier : require

layout(set = 0, binding = 0) uniform texture2D hiz_textures[];

const float HIZ_NEAR_W = 1e-3;

// Hiz_Info (hiz.odin): level 0's size, the levels, the pyramid's texture id.
struct Hiz_Info {
	uvec2 size;
	uint mips;
	uint texture_id;
};

float hiz_fetch(Hiz_Info hiz, ivec2 t, int level) {
	return texelFetch(hiz_textures[hiz.texture_id], t, level).r;
}

bool occluded(mat4 view_proj, vec3 lo, vec3 hi, Hiz_Info hiz) {
	vec2 rmin = vec2(1e30);
	vec2 rmax = vec2(-1e30);
	float nearest = 0.0;
	for (int i = 0; i < 8; i++) {
		vec3 p = vec3((i & 1) != 0 ? hi.x : lo.x, (i & 2) != 0 ? hi.y : lo.y, (i & 4) != 0 ? hi.z : lo.z);
		vec4 c = view_proj * vec4(p, 1.0);
		if (c.w <= HIZ_NEAR_W) {
			return false;
		}
		vec2 xy = c.xy / c.w;
		rmin = min(rmin, xy);
		rmax = max(rmax, xy);
		nearest = max(nearest, c.z / c.w);
	}
	rmin = max(rmin, vec2(-1.0));
	rmax = min(rmax, vec2(1.0));
	if (rmin.x > rmax.x || rmin.y > rmax.y) {
		return false;
	}
	vec2 size = vec2(hiz.size);
	vec2 a = (rmin * 0.5 + 0.5) * size;
	vec2 b = (rmax * 0.5 + 0.5) * size;
	float e = max(b.x - a.x, b.y - a.y);
	int level = 0;
	while (level < int(hiz.mips) - 1 && float(1 << level) < e) {
		level++;
	}
	ivec2 last = max(ivec2(hiz.size) >> level, ivec2(1)) - 1;
	float scale = float(1 << level);
	ivec2 t0 = clamp(ivec2(floor(a / scale)), ivec2(0), last);
	ivec2 t1 = clamp(ivec2(floor(b / scale)), ivec2(0), last);
	float farthest = min(
		min(hiz_fetch(hiz, t0, level), hiz_fetch(hiz, ivec2(t1.x, t0.y), level)),
		min(hiz_fetch(hiz, ivec2(t0.x, t1.y), level), hiz_fetch(hiz, t1, level))
	);
	return nearest < farthest;
}
