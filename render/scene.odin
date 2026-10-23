package render

import "core:math"
import "core:math/linalg"

import "../gpu"

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
	axis:          [4]f32, // xyz the sky turns around (stars turn with the sun)
	zenith:        [4]f32, // rgb (linear); w: fog distance in blocks (fully fogged)
	horizon:       [4]f32, // rgb
	glow:          [4]f32, // rgb sunrise/sunset glow towards the sun; w: its strength
	sky_light:     [4]f32, // rgb: what sky light level 15 looks like now
	cloud:         [4]f32, // rgb cloud colour (lit side)
	cloud_origin:  [4]f32, // xz: the camera in the cloud pattern (wrapped; see CLOUD_PERIOD)
	cloud_map:     u64, // address of the Cloud_Map (set by scene_upload)
	_:             u64,
}

// Clouds: a slab of CLOUD_CELL-block cells, cloud or clear by the
// Cloud_Map, which repeats every CLOUD_PERIOD blocks (scene.glsl uses the
// same numbers).
CLOUD_CELL :: 12
CLOUD_MAP_SIZE :: 256 // cells across
CLOUD_PERIOD :: CLOUD_CELL * CLOUD_MAP_SIZE
CLOUD_SPEED :: 1.2 // blocks/s, drifting +x

// Cloud_Map: one bit per cell (row-major, x fastest; bit x & 31 of word
// y * 8 + x >> 5).
Cloud_Map :: [CLOUD_MAP_SIZE * CLOUD_MAP_SIZE / 32]u32

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
			if v > 0.62 {
				i := y * CLOUD_MAP_SIZE + x
				m[i >> 5] |= 1 << u32(i & 31)
			}
		}
	}
}

// cloud_map_get: whether cell (any integers: the map repeats) is cloud.
cloud_map_get :: proc(m: ^Cloud_Map, x, y: int) -> bool {
	cx, cy := x & (CLOUD_MAP_SIZE - 1), y & (CLOUD_MAP_SIZE - 1)
	i := cy * CLOUD_MAP_SIZE + cx
	return m[i >> 5] & (1 << u32(i & 31)) != 0
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
}

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

// scene_make puts a camera, the sky and the fog together. drift: how far
// the clouds have moved (blocks).
scene_make :: proc(camera: Camera, sky: Sky, fog_distance: f32, drift: f64) -> Scene {
	absolute := [3]f64 {
		f64(camera.chunk.x) * CHUNK_EXTENT + f64(camera.position.x),
		f64(camera.chunk.y) * CHUNK_EXTENT + f64(camera.position.y),
		f64(camera.chunk.z) * CHUNK_EXTENT + f64(camera.position.z),
	}
	wrap :: proc(v: f64) -> f32 {
		return f32(v - math.floor(v / CLOUD_PERIOD) * CLOUD_PERIOD)
	}
	return {
		view_proj = camera.view_proj,
		inv_view_proj = linalg.inverse(camera.view_proj),
		camera = {camera.position.x, camera.position.y, camera.position.z, f32(absolute.y)},
		sun = {sky.sun.x, sky.sun.y, sky.sun.z, sky.stars},
		axis = {sky.axis.x, sky.axis.y, sky.axis.z, 0},
		zenith = {sky.zenith.r, sky.zenith.g, sky.zenith.b, fog_distance},
		horizon = {sky.horizon.r, sky.horizon.g, sky.horizon.b, 0},
		glow = {sky.glow.r, sky.glow.g, sky.glow.b, sky.glow_k},
		sky_light = {sky.sky_light.r, sky.sky_light.g, sky.sky_light.b, 0},
		cloud = {sky.cloud.r, sky.cloud.g, sky.cloud.b, 0},
		cloud_origin = {wrap(absolute.x + drift), 0, wrap(absolute.z), 0},
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
