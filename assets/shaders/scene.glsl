// The scene every world pass shares (render/scene.odin): read by address,
// one copy per frame slot. Include after #version.

#extension GL_EXT_buffer_reference : require

// One density byte per cloud cell (render/scene.odin's Cloud_Map).
layout(buffer_reference, std430) readonly buffer Cloud_Map {
	uint bits[];
};

// A light that moves (render/scene.odin's Light: a lamp someone carries).
struct Light {
	vec4 at;    // xyz from the camera chunk's origin; w: its level (it reaches w blocks)
	vec4 color; // rgb at full (linear)
};

const int MAX_LIGHTS = 8; // render/scene.odin

layout(buffer_reference, std430) readonly buffer Scene {
	mat4 view_proj;     // from the camera chunk's origin
	mat4 inv_view_proj;
	vec4 camera;        // xyz from the camera chunk's origin; w: absolute y
	vec4 sun;           // xyz towards the sun; w: star visibility
	vec4 axis;          // xyz the sky turns around; w: how hidden the sun and moon are (1: not drawn)
	vec4 zenith;        // rgb; w: fog distance (blocks)
	vec4 horizon;       // rgb; w: the fog's span (a fraction of its distance)
	vec4 glow;          // rgb sunrise/sunset glow; w: its strength
	vec4 sky_light;     // rgb: sky light level 15, now; w: brightness setting (0..1)
	vec4 cloud;         // rgb: lit cloud colour; w: 1 drawn, 0 not (the setting)
	vec4 cloud_origin;  // xz: the camera in the (wrapped) cloud pattern; y: the cloud map's threshold
	vec4 water;         // rgb: water seen from inside; w: 1 with the camera under water
	vec4 lamp;          // rgb: block light level 15; w: where the fog begins (a fraction of its distance)
	vec4 ambient;       // rgb: light added everywhere (the game's look)
	vec4 figure;        // rgb: the least light a figure is drawn in; w: 1 graded, 0 not
	vec4 grade;         // rgb: tint; w: saturation (1 as it is)
	vec4 grade_more;    // x: contrast (1 as it is); y: vignette; zw: 1 / the target's size
	vec4 gate;          // xyz: the middle of a gate's opening whose void is gathering; w: seconds since it began, < 0: none
	ivec4 camera_chunk; // xyz: the camera's chunk; w: no block at this y or above is drawn (render/scene.odin's NO_CUT: none)
	Cloud_Map cloud_map;
	ivec4 light_count;  // x: the lights that move in use (0: none, and nothing here is asked)
	Light lights[MAX_LIGHTS];
};

// level_brightness: the brightness of a light level l (0..15, fractional): world.vert's
// curve for block light, so a carried lamp lights as a lamp block does.
float level_brightness(float l) {
	float x = clamp(l / 15.0, 0.0, 1.0);
	return 0.03 + 0.97 * x * x * (3.0 - 2.0 * x) * x;
}

// facing_normal: the unit normal of a surface from its position's screen derivatives
// (a fragment shader's dFdx and dFdy of it), turned to the camera (to_eye: from the surface
// to it; any face drawn faces the camera).
vec3 facing_normal(vec3 dx, vec3 dy, vec3 to_eye) {
	vec3 n = normalize(cross(dx, dy));
	return dot(n, to_eye) < 0.0 ? -n : n;
}

// moving_light: what the scene's lights that move (render/scene.odin's scene_lights) give a
// surface at pos facing n, by channel the brightest of them, as block light is the brightest
// that reaches a block: each falls a level a block from its own, and lights no face turned
// away from it (so it does not shine through a wall onto its far side).
vec3 moving_light(Scene s, vec3 pos, vec3 n) {
	vec3 light = vec3(0.0);
	for (int i = 0; i < min(s.light_count.x, MAX_LIGHTS); i++) {
		vec3 to = s.lights[i].at.xyz - pos;
		float d = length(to);
		float level = s.lights[i].at.w - d;
		if (level <= 0.0) continue;
		float facing = d > 0.001 ? smoothstep(-0.15, 0.35, dot(n, to / d)) : 1.0;
		light = max(light, s.lights[i].color.rgb * level_brightness(level) * facing);
	}
	return light;
}

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

// cloud_at: whether a cloud fills cell (the map repeats): its density byte is
// at least the scene's threshold (lower under a greater cover).
bool cloud_at(Scene s, ivec2 cell) {
	ivec2 c = cell & ivec2(int(CLOUD_PERIOD_CELLS) - 1);
	int i = c.y * int(CLOUD_PERIOD_CELLS) + c.x;
	uint word = s.cloud_map.bits[i >> 2];
	return float((word >> (uint(i & 3) * 8u)) & 0xffu) >= s.cloud_origin.y;
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
