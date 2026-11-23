// The scene every world pass shares (render/scene.odin): read by address,
// one copy per frame slot. Include after #version.

#extension GL_EXT_buffer_reference : require

// One bit per cloud cell (render/scene.odin's Cloud_Map).
layout(buffer_reference, std430) readonly buffer Cloud_Map {
	uint bits[];
};

layout(buffer_reference, std430) readonly buffer Scene {
	mat4 view_proj;     // from the camera chunk's origin
	mat4 inv_view_proj;
	vec4 camera;        // xyz from the camera chunk's origin; w: absolute y
	vec4 sun;           // xyz towards the sun; w: star visibility
	vec4 axis;          // xyz the sky turns around; w: 1 no sun or moon drawn
	vec4 zenith;        // rgb; w: fog distance (blocks)
	vec4 horizon;       // rgb; w: the fog's span (a fraction of its distance)
	vec4 glow;          // rgb sunrise/sunset glow; w: its strength
	vec4 sky_light;     // rgb: sky light level 15, now; w: brightness setting (0..1)
	vec4 cloud;         // rgb: lit cloud colour; w: 1 drawn, 0 not (the setting)
	vec4 cloud_origin;  // xz: the camera in the (wrapped) cloud pattern
	vec4 water;         // rgb: water seen from inside; w: 1 with the camera under water
	vec4 lamp;          // rgb: block light level 15; w: where the fog begins (a fraction of its distance)
	vec4 ambient;       // rgb: light added everywhere (the game's look)
	vec4 figure;        // rgb: the least light a figure is drawn in; w: 1 graded, 0 not
	vec4 grade;         // rgb: tint; w: saturation (1 as it is)
	vec4 grade_more;    // x: contrast (1 as it is); y: vignette; zw: 1 / the target's size
	vec4 gate;          // xyz: the middle of a gate's opening whose void is gathering; w: seconds since it began, < 0: none
	ivec4 camera_chunk; // xyz: the camera's chunk; w: no block at this y or above is drawn (render/scene.odin's NO_CUT: none)
	Cloud_Map cloud_map;
};

const float CLOUD_CELL = 12.0;  // render/scene.odin
const float CLOUD_PERIOD_CELLS = 256.0; // CLOUD_MAP_SIZE
const float CLOUD_BOTTOM = 192.0;
const float CLOUD_TOP = 196.0;
const float CLOUD_FAR = 2400.0; // blocks: no clouds further away

// sky_color: the sky seen in direction dir (unit). Fog fades to it too, so
// terrain melts into the sky behind it.
vec3 sky_color(Scene s, vec3 dir) {
	float up = max(dir.y, 0.0);
	float h = pow(1.0 - up, 4.0); // 1 at the horizon, 0 overhead
	vec3 c = mix(s.zenith.rgb, s.horizon.rgb, h);
	float toward = max(dot(dir, s.sun.xyz), 0.0);
	c += s.glow.rgb * s.glow.w * pow(toward, 6.0) * (0.25 + 0.75 * h);
	return c;
}

// fog_amount: 0 near .. 1 at the fog distance (horizontal distance d).
float fog_amount(Scene s, float d) {
	return clamp((d - s.lamp.w * s.zenith.w) / (s.horizon.w * s.zenith.w), 0.0, 1.0);
}

// cloud_at: whether a cloud fills cell (the map repeats).
bool cloud_at(Scene s, ivec2 cell) {
	ivec2 c = cell & ivec2(int(CLOUD_PERIOD_CELLS) - 1);
	uint word = s.cloud_map.bits[c.y * (int(CLOUD_PERIOD_CELLS) / 32) + (c.x >> 5)];
	return ((word >> uint(c.x & 31)) & 1u) != 0u;
}

// cloud_hit walks the slab's cells along the ray, up to far: distance and
// face (0 top/bottom, 1 x side, 2 z side), or distance < 0 for none. Only
// the part of the ray inside the slab is walked: a few cells, unless the
// ray grazes it.
float cloud_hit(Scene s, vec3 dir, float far, out int face) {
	face = 0;
	float y = s.camera.w;
	if (abs(dir.y) < 1e-4 && (y < CLOUD_BOTTOM || y > CLOUD_TOP)) return -1.0;
	float t0 = 0.0, t1 = far;
	if (abs(dir.y) >= 1e-4) {
		float ta = (CLOUD_BOTTOM - y) / dir.y, tb = (CLOUD_TOP - y) / dir.y;
		t0 = max(min(ta, tb), 0.0);
		t1 = min(max(ta, tb), far);
	}
	if (t0 >= t1) return -1.0;
	vec2 o = s.cloud_origin.xz / CLOUD_CELL; // in cells
	vec2 d = dir.xz / CLOUD_CELL;
	vec2 p = o + d * t0;
	ivec2 cell = ivec2(floor(p));
	ivec2 step = ivec2(sign(d));
	vec2 inv = 1.0 / max(abs(d), vec2(1e-6));
	// Ray distance (from t0) to the next x and z cell edges.
	vec2 edge = vec2(cell) + vec2(step.x > 0 ? 1.0 : 0.0, step.y > 0 ? 1.0 : 0.0);
	vec2 next = abs(edge - p) * inv;
	float t = t0;
	for (int i = 0; i < 160 && t < t1; i++) {
		if (cloud_at(s, cell)) return t;
		if (next.x < next.y) {
			t = t0 + next.x;
			next.x += inv.x;
			cell.x += step.x;
			face = 1;
		} else {
			t = t0 + next.y;
			next.y += inv.y;
			cell.y += step.y;
			face = 2;
		}
	}
	return -1.0;
}

// with_clouds: color, unless a cloud is in direction dir within far blocks.
vec3 with_clouds(Scene s, vec3 dir, float far, vec3 color) {
	if (s.cloud.w == 0.0) return color; // turned off (Options)
	int face;
	float d = cloud_hit(s, dir, far, face);
	if (d < 0.0) return color;
	float shade = face == 0 ? (dir.y < 0.0 ? 1.0 : 0.72) : (face == 1 ? 0.86 : 0.8);
	vec3 cloud = s.cloud.rgb * shade + s.horizon.rgb * 0.15;
	float near = 2.0 * s.zenith.w; // clouds fade out from twice the fog distance
	float fade = clamp((d - near) / (CLOUD_FAR - near), 0.0, 1.0);
	return mix(cloud, color, fade * fade);
}

const float UNDERWATER_FOG = 18.0; // blocks: how far you see under water

// fog_mix: color at `to` (from the camera) seen through the air's fog into
// the sky, or under water through the water.
vec3 fog_mix(Scene s, vec3 color, vec3 to) {
	if (s.water.w > 0.5) {
		float f = clamp(length(to) / UNDERWATER_FOG, 0.0, 1.0);
		return mix(color * vec3(0.55, 0.75, 1.0), s.water.rgb, f * (2.0 - f));
	}
	float fog = fog_amount(s, length(to.xz));
	return fog > 0.0 ? mix(color, sky_color(s, normalize(to)), fog) : color;
}

// graded: a finished colour in the game's look's grade (render/look.odin), at
// pixel `at` (gl_FragCoord.xy): tint, saturation, contrast about a mid grey,
// then the vignette. Untouched when the look has none.
vec3 graded(Scene s, vec3 color, vec2 at) {
	if (s.figure.w == 0.0) return color;
	vec3 c = color * s.grade.rgb;
	float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = max(mix(vec3(luma), c, s.grade.w), vec3(0.0));
	c = 0.18 * pow(c / 0.18, vec3(s.grade_more.x));
	vec2 p = at * s.grade_more.zw - 0.5; // -0.5..0.5 across the target
	float edge = smoothstep(0.25, 0.75, length(p * vec2(1.0, 0.8)) * 1.2);
	return c * (1.0 - s.grade_more.y * edge);
}
