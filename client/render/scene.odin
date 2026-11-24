package render

import "core:math"
import "core:math/linalg"

import "client:gpu"

// The scene: what every world pass shares this frame (camera, sun, sky
// colours, fog, clouds), written to a per-frame-slot buffer that shaders
// read by address (assets/shaders/scene.glsl declares the same layout).
//
//	address := render.scene_upload(&scenes, &g, render.scene_make(camera, sky_at(time_of_day), fog, drift))
//	render.world_draw(&pass, &g, frame, camera, address)
//	render.sky_draw(&sky, &g, frame, address)

// Scene matches scene.glsl's Scene (std430: vec4s and mat4s, then the
// cloud map's address).
Scene :: struct {
	view_proj:     matrix[4, 4]f32, // from the camera chunk's origin
	inv_view_proj: matrix[4, 4]f32,
	camera:        [4]f32, // xyz from the camera chunk's origin; w: absolute y
	sun:           [4]f32, // xyz towards the sun; w: how visible the stars are (0..1)
	axis:          [4]f32, // xyz the sky turns around (stars turn with the sun); w: how hidden the sun and moon are (1: not drawn)
	zenith:        [4]f32, // rgb (linear); w: fog distance in blocks (fully fogged)
	horizon:       [4]f32, // rgb; w: the fog's span, a fraction of its distance (it begins at lamp.w)
	glow:          [4]f32, // rgb sunrise/sunset glow towards the sun; w: its strength
	sky_light:     [4]f32, // rgb: what sky light level 15 looks like now; w: brightness (0..1)
	cloud:         [4]f32, // rgb cloud colour (lit side); w: 1 drawn, 0 not
	cloud_origin:  [4]f32, // xz: the camera in the cloud pattern (wrapped; see CLOUD_PERIOD); y: the cloud map's threshold (cloud_threshold)
	water:         [4]f32, // rgb: the colour of water seen from inside it; w: 1 with the camera under water
	lamp:          [4]f32, // rgb: what block light level 15 looks like; w: where the fog begins, a fraction of its distance
	ambient:       [4]f32, // rgb: light added everywhere (a look's); w: 0
	figure:        [4]f32, // rgb: the least light a figure is drawn in; w: 1 graded (grade, grade_more), 0 not
	grade:         [4]f32, // rgb: the picture's tint; w: its saturation (1 as it is)
	grade_more:    [4]f32, // x: contrast (1 as it is); y: vignette (0 none); zw: 1 / the target's size in pixels
	gate:          [4]f32, // xyz: the middle of a gate's opening whose void is gathering (from the camera chunk's origin); w: seconds since it began, < 0: none
	camera_chunk:  [4]i32, // xyz: the camera's chunk (what "from the camera chunk's origin" is from); w: the world is cut at this y (NO_CUT: not)
	cloud_map:     u64, // address of the Cloud_Map (set by scene_upload)
	_:             u64,
}

// NO_CUT: the scene's cut when the whole world is drawn (above anything there is).
NO_CUT :: i32(1 << 20)

// Clouds: a slab of CLOUD_CELL-block cells, cloud or clear by the
// Cloud_Map, which repeats every CLOUD_PERIOD blocks (scene.glsl uses the
// same numbers). Each cell has a density byte; a cell is cloud when its byte
// is at least the scene's threshold: CLOUD_CLEAR in fair weather, lower as
// the weather's cover grows (cloud_threshold), down to one grey sheet.
CLOUD_CELL :: 12
CLOUD_MAP_SIZE :: 256 // cells across
CLOUD_PERIOD :: CLOUD_CELL * CLOUD_MAP_SIZE
CLOUD_SPEED :: 1.2 // blocks/s, drifting +x

// Cloud_Map: one density byte per cell (row-major, x fastest; byte i & 3 of
// word i >> 2, i = y * CLOUD_MAP_SIZE + x).
Cloud_Map :: [CLOUD_MAP_SIZE * CLOUD_MAP_SIZE / 4]u32

// CLOUD_CLEAR: the threshold of fair weather: the cells whose noise is over
// CLOUD_FAIR (a byte of at least 128). CLOUD_OVERCAST: a whole cover's.
CLOUD_CLEAR :: 128
CLOUD_OVERCAST :: 4
@(private = "file")
CLOUD_FAIR :: 0.62
@(private = "file")
CLOUD_STEP :: 400 // bytes per unit of noise away from CLOUD_FAIR

// cloud_threshold: the cloud map's threshold under a cover (0 fair .. 1 overcast).
cloud_threshold :: proc(cover: f32) -> f32 {
	return math.lerp(f32(CLOUD_CLEAR), f32(CLOUD_OVERCAST), clamp(cover, 0, 1))
}

// cloud_map_generate: blobs of value noise, thresholded, with ragged edges;
// it tiles seamlessly.
cloud_map_generate :: proc(m: ^Cloud_Map) {
	LATTICE :: 4 // cells between noise values
	N :: CLOUD_MAP_SIZE / LATTICE
	hash01 :: proc(x, y, salt: u32) -> f32 {
		h := x * 0x8da6b343 ~ y * 0xd8163841 ~ salt * 0xcb1ab31f
		h ~= h >> 15
		h *= 0x2c1b3c6d
		h ~= h >> 12
		h *= 0x297a2d39
		h ~= h >> 15
		return f32(h & 0xffffff) / f32(0xffffff)
	}
	m^ = {}
	for y in 0 ..< CLOUD_MAP_SIZE {
		for x in 0 ..< CLOUD_MAP_SIZE {
			lx, ly := x / LATTICE, y / LATTICE
			fx := smoothstep(0, 1, f32(x % LATTICE) / LATTICE)
			fy := smoothstep(0, 1, f32(y % LATTICE) / LATTICE)
			v00 := hash01(u32(lx), u32(ly), 5)
			v10 := hash01(u32((lx + 1) % N), u32(ly), 5)
			v01 := hash01(u32(lx), u32((ly + 1) % N), 5)
			v11 := hash01(u32((lx + 1) % N), u32((ly + 1) % N), 5)
			v := math.lerp(math.lerp(v00, v10, fx), math.lerp(v01, v11, fx), fy)
			v = 0.75 * v + 0.25 * hash01(u32(x), u32(y), 9)
			// The byte is at least CLOUD_CLEAR exactly where fair weather has cloud.
			b: u32
			if v > CLOUD_FAIR {
				b = CLOUD_CLEAR + u32(min(127, int((v - CLOUD_FAIR) * CLOUD_STEP)))
			} else {
				b = CLOUD_CLEAR - 1 - u32(min(127, int((CLOUD_FAIR - v) * CLOUD_STEP)))
			}
			i := y * CLOUD_MAP_SIZE + x
			m[i >> 2] |= b << (u32(i & 3) * 8)
		}
	}
}

// cloud_map_get: whether cell (any integers: the map repeats) is cloud at a
// threshold (scene.glsl's cloud_at).
cloud_map_get :: proc(m: ^Cloud_Map, x, y: int, threshold: f32 = CLOUD_CLEAR) -> bool {
	cx, cy := x & (CLOUD_MAP_SIZE - 1), y & (CLOUD_MAP_SIZE - 1)
	i := cy * CLOUD_MAP_SIZE + cx
	return f32((m[i >> 2] >> (u32(i & 3) * 8)) & 0xff) >= threshold
}

// Sky is the look of the sky at a time of day, before any camera.
Sky :: struct {
	sun:       [3]f32, // unit, towards the sun
	axis:      [3]f32,
	stars:     f32,
	zenith:    [3]f32,
	horizon:   [3]f32,
	glow:      [3]f32,
	glow_k:    f32,
	sky_light: [3]f32,
	cloud:     [3]f32,
	cover:     f32, // the weather's cloud (sky_weathered): the cloud map's threshold, the sun and moon hidden
	haze:      f32, // mist and rain: the fog closes in (0 the view's, 1 MIST_FOG)
}

// Sky_Weather: what the weather does to the sky (client/atmosphere works it out from
// game.Weather): every field 0..1.
Sky_Weather :: struct {
	cover: f32, // cloud
	rain:  f32, // falling (as rain or snow): darker, and the distance greys
	storm: f32, // darker still
	fog:   f32, // mist where the camera is
	flash: f32, // lightning, now
}

// MIST_FOG: blocks away at which a whole mist hides everything.
MIST_FOG :: 28

// The sun's path leans this far south of overhead.
SUN_TILT :: 0.35 // radians

// Colours, linear.
@(private = "file")
DAY_ZENITH :: [3]f32{0.10, 0.27, 0.72}
@(private = "file")
DAY_HORIZON :: [3]f32{0.42, 0.60, 0.88}
@(private = "file")
NIGHT_ZENITH :: [3]f32{0.002, 0.003, 0.012}
@(private = "file")
NIGHT_HORIZON :: [3]f32{0.012, 0.016, 0.038}
@(private = "file")
GLOW :: [3]f32{1.00, 0.36, 0.08}
@(private = "file")
DAY_LIGHT :: [3]f32{1, 1, 1}
@(private = "file")
NIGHT_LIGHT :: [3]f32{0.11, 0.13, 0.22} // moonlight: dim and blue, never black

// sky_at gives the sky at time of day f (0 midnight .. 0.5 noon .. 1).
sky_at :: proc(f: f64) -> (s: Sky) {
	angle := f32((f - 0.25) * math.TAU) // 0 at sunrise, in the east (+x)
	c, sn := math.cos(angle), math.sin(angle)
	s.sun = {c, sn * math.cos(f32(SUN_TILT)), sn * math.sin(f32(SUN_TILT))}
	s.axis = {0, -math.sin(f32(SUN_TILT)), math.cos(f32(SUN_TILT))}
	e := s.sun.y // the sun's height: -1..1

	day := smoothstep(-0.12, 0.25, e) // 0 at night, 1 by mid-morning
	s.zenith = linalg.lerp(NIGHT_ZENITH, DAY_ZENITH, day)
	s.horizon = linalg.lerp(NIGHT_HORIZON, DAY_HORIZON, day)
	// Sunrise and sunset: strongest with the sun on the horizon.
	s.glow_k = math.exp(-(e / 0.16) * (e / 0.16)) * smoothstep(-0.3, -0.05, e)
	s.glow = GLOW
	s.horizon = linalg.lerp(s.horizon, GLOW * 0.8, s.glow_k * 0.45)
	s.stars = 1 - smoothstep(-0.25, 0.02, e)
	s.sky_light = linalg.lerp(NIGHT_LIGHT, DAY_LIGHT, day)
	s.sky_light = linalg.lerp(s.sky_light, [3]f32{1.0, 0.70, 0.50}, s.glow_k * 0.5)
	s.cloud = linalg.lerp([3]f32{0.035, 0.04, 0.06}, [3]f32{0.97, 0.97, 1.0}, day)
	s.cloud = linalg.lerp(s.cloud, [3]f32{1.0, 0.62, 0.46}, s.glow_k * 0.7)
	return
}

// sky_weathered: the sky under the weather. Overcast greys and flattens it (the sky's
// light dims, the glow and the stars go behind the cloud), rain and storm darken it,
// mist pales it towards a lit grey, lightning lights it all at once. No weather is the
// sky as it was.
sky_weathered :: proc(sky: Sky, w: Sky_Weather) -> Sky {
	s := sky
	if w == {} {return s}
	luma :: proc(c: [3]f32) -> f32 {return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b}
	cover := clamp(w.cover, 0, 1)
	dark := 1 - 0.45 * clamp(w.rain, 0, 1) - 0.3 * clamp(w.storm, 0, 1)
	grey := [3]f32{1, 1, 1.04} * luma(s.horizon) * 0.75 * dark
	s.zenith = linalg.lerp(s.zenith, grey * 0.9, cover * 0.9)
	s.horizon = linalg.lerp(s.horizon, grey, cover * 0.9)
	s.glow_k *= 1 - 0.85 * cover
	s.stars *= 1 - cover
	light := luma(s.sky_light)
	s.sky_light = linalg.lerp(s.sky_light, [3]f32{light, light, light * 1.05}, cover * 0.5)
	s.sky_light *= 1 - 0.3 * cover * (2.2 - 1.2 * dark)
	// The cloud a little darker than the grey it hangs in, darker in a storm.
	s.cloud = linalg.lerp(s.cloud, grey * (0.95 - 0.3 * w.storm), cover)
	fog := clamp(w.fog, 0, 1)
	if fog > 0 {
		pale := [3]f32{0.82, 0.85, 0.9} * max(luma(s.sky_light), 0.03)
		s.horizon = linalg.lerp(s.horizon, pale, fog * 0.8)
		s.zenith = linalg.lerp(s.zenith, pale * 0.9, fog * 0.6)
	}
	if w.flash > 0 {
		f := clamp(w.flash, 0, 1)
		s.sky_light += [3]f32{0.75, 0.8, 1.0} * f
		s.zenith += [3]f32{0.3, 0.32, 0.4} * f
		s.horizon += [3]f32{0.4, 0.42, 0.5} * f
		s.cloud += [3]f32{0.5, 0.52, 0.6} * f
	}
	s.cover = cover
	s.haze = max(fog, 0.45 * clamp(w.rain, 0, 1))
	return s
}

// UNDERWATER: the colour of deep water around a camera in it, in daylight
// (dimmed with the sky's light).
UNDERWATER :: [3]f32{0.05, 0.14, 0.30}

// scene_make puts a camera, the sky and the fog together. drift: how far
// the clouds have moved (blocks). look: the game's (its sky is look_sky's,
// given as sky); pixels: the target's size (the look's vignette).

scene_make :: proc(
	camera: Camera,
	sky: Sky,
	fog_distance: f32,
	drift: f64,
	underwater := false,
	brightness: f32 = 0,
	clouds := true,
	look := Look{},
	pixels := [2]i32{},
) -> Scene {
	absolute := [3]f64 {
		f64(camera.chunk.x) * CHUNK_EXTENT + f64(camera.position.x),
		f64(camera.chunk.y) * CHUNK_EXTENT + f64(camera.position.y),
		f64(camera.chunk.z) * CHUNK_EXTENT + f64(camera.position.z),
	}
	wrap :: proc(v: f64) -> f32 {
		return f32(v - math.floor(v / CLOUD_PERIOD) * CLOUD_PERIOD)
	}
	fog := min(fog_distance, look.fog) if look.fog > 0 else fog_distance
	fog_near, fog_span := f32(FOG_NEAR), f32(1 - FOG_NEAR)
	if look.fog_near > 0 {
		fog_near = clamp(look.fog_near, 0, 0.95)
		fog_span = 1 - fog_near
	}
	if sky.haze > 0 { 	// mist and rain: the fog comes in, and begins nearer
		fog = math.lerp(fog, min(fog, f32(MIST_FOG)), sky.haze)
		fog_near *= 1 - 0.8 * sky.haze
		fog_span = 1 - fog_near
	}
	hidden := smoothstep(0.35, 0.85, sky.cover) // the sun and moon behind the cloud
	lamp := look.lamp_light if look.lamp_light != {} else LAMP_LIGHT
	figure := look.figure_light if look.figure_light != {} else FIGURE_LIGHT
	g := look.grade
	tint := g.tint if g.tint != {} else 1
	inverse := [2]f32{1 / f32(max(pixels.x, 1)), 1 / f32(max(pixels.y, 1))}
	return {
		view_proj = camera.view_proj,
		inv_view_proj = linalg.inverse(camera.view_proj),
		camera = {camera.position.x, camera.position.y, camera.position.z, f32(absolute.y)},
		sun = {sky.sun.x, sky.sun.y, sky.sun.z, sky.stars},
		axis = {sky.axis.x, sky.axis.y, sky.axis.z, 1 if look.no_sun else hidden},
		zenith = {sky.zenith.r, sky.zenith.g, sky.zenith.b, fog},
		horizon = {sky.horizon.r, sky.horizon.g, sky.horizon.b, fog_span},
		glow = {sky.glow.r, sky.glow.g, sky.glow.b, sky.glow_k},
		sky_light = {sky.sky_light.r, sky.sky_light.g, sky.sky_light.b, brightness},
		cloud = {sky.cloud.r, sky.cloud.g, sky.cloud.b, 1 if clouds && !look.no_clouds else 0},
		cloud_origin = {wrap(absolute.x + drift), cloud_threshold(sky.cover), wrap(absolute.z), 0},
		water = {
			UNDERWATER.r * sky.sky_light.r,
			UNDERWATER.g * sky.sky_light.g,
			UNDERWATER.b * sky.sky_light.b,
			1 if underwater else 0,
		},
		lamp = {lamp.r, lamp.g, lamp.b, fog_near},
		ambient = {look.ambient.r, look.ambient.g, look.ambient.b, 0},
		figure = {figure.r, figure.g, figure.b, 1 if look_graded(look) else 0},
		grade = {tint.r, tint.g, tint.b, 1 + g.saturation},
		grade_more = {1 + g.contrast, g.vignette, inverse.x, inverse.y},
		gate = {0, 0, 0, -1},
		camera_chunk = {
			camera.chunk.x,
			camera.chunk.y,
			camera.chunk.z,
			camera.cut.? or_else NO_CUT,
		},
	}
}

// Scene_Buffers: one host-visible copy of the scene per frame slot, and
// the cloud map (written once).
Scene_Buffers :: struct {
	frames: [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
	clouds: gpu.Buffer,
}

scene_init :: proc(b: ^Scene_Buffers, g: ^gpu.Gpu) -> bool {
	b.clouds = gpu.create_buffer(
		g,
		size_of(Cloud_Map),
		{.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
		true,
		"cloud map",
	) or_return
	cloud_map_generate((^Cloud_Map)(b.clouds.mapped))
	for &f in b.frames {
		f = gpu.create_buffer(
			g,
			size_of(Scene),
			{.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
			true,
			"scene",
		) or_return
	}
	return true
}

scene_destroy :: proc(b: ^Scene_Buffers, g: ^gpu.Gpu) {
	for &f in b.frames {gpu.destroy_buffer(g, &f)}
	gpu.destroy_buffer(g, &b.clouds)
}

// scene_upload writes this frame slot's scene and returns its address.
scene_upload :: proc(b: ^Scene_Buffers, g: ^gpu.Gpu, scene: Scene) -> u64 {
	f := b.frames[gpu.frame_slot(g)]
	(^Scene)(f.mapped)^ = scene
	(^Scene)(f.mapped).cloud_map = gpu.buffer_address(g, b.clouds)
	return gpu.buffer_address(g, f)
}

@(private = "file")
smoothstep :: proc(lo, hi, x: f32) -> f32 {
	t := clamp((x - lo) / (hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
}
