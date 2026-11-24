package render

import "core:math"
import "core:mem"
import vk "vendor:vulkan"

import "client:gpu"

// What falls from the sky: rain as thin streaks standing towards the camera,
// snow as soft flakes facing it, built on the CPU every frame from the drops
// the client's atmosphere chose (client/atmosphere, which keeps them out from
// under roofs), blended over everything solid, lit by the sky and fogged like
// the world. MAX_DROPS bounds a frame's.
//
//	render.weather_drop(&wd, {at = p, height = 0.7, width = 0.03, color = c})
//	render.weather_upload(&pass, &g, &wd, camera)  // before begin_rendering
//	render.weather_draw(&pass, &g, frame, scene)   // after the water

MAX_DROPS :: 2400

Drop_Shape :: enum u8 {
	Streak, // stands up, turned about the vertical towards the camera (rain)
	Flake, // faces the camera (snow)
}

Drop :: struct {
	at:     [3]f64, // world position of its bottom middle (a flake's middle)
	lean:   [2]f32, // how far its top is blown sideways (x, z), blocks
	height: f32,
	width:  f32,
	color:  [4]u8, // sRGB, alpha
	shape:  Drop_Shape,
}

Weather_Draw :: struct {
	drops: [dynamic]Drop,
}

Weather_Pass :: struct {
	pipeline: gpu.Pipeline,
	frames:   [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
	counts:   [gpu.FRAMES_IN_FLIGHT]u32,
}

@(private)
Weather_Vertex :: struct {
	pos:   [3]f32, // from the camera chunk's origin
	uv:    [2]f32, // -1..1 across, 0..1 up
	color: [4]u8,
	shape: u8,
	_:     [3]u8,
}

@(private = "file")
Weather_Push :: struct {
	scene: u64,
}

weather_draw_init :: proc(d: ^Weather_Draw, allocator := context.allocator) {
	d.drops = make([dynamic]Drop, 0, MAX_DROPS, allocator)
}

weather_draw_destroy :: proc(d: ^Weather_Draw) {
	delete(d.drops)
}

// weather_drop adds a drop to this frame's, false past MAX_DROPS (it is left out).
weather_drop :: proc(d: ^Weather_Draw, drop: Drop) -> bool {
	if len(d.drops) >= MAX_DROPS {return false}
	append(&d.drops, drop)
	return true
}

weather_init :: proc(p: ^Weather_Pass, g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> bool {
	ok: bool
	p.pipeline, ok = gpu.create_pipeline(g, weather_pipeline_desc(g, vertex_spirv, fragment_spirv))
	return ok
}

@(private = "file", rodata)
WEATHER_ATTRIBUTES := [4]gpu.Vertex_Attribute {
	{.R32G32B32_SFLOAT, u32(offset_of(Weather_Vertex, pos))},
	{.R32G32_SFLOAT, u32(offset_of(Weather_Vertex, uv))},
	{.R8G8B8A8_UNORM, u32(offset_of(Weather_Vertex, color))},
	{.R8_UINT, u32(offset_of(Weather_Vertex, shape))},
}

@(private = "file")
weather_pipeline_desc :: proc(
	g: ^gpu.Gpu,
	vertex_spirv, fragment_spirv: []byte,
) -> gpu.Pipeline_Desc {
	return {
		name = "weather",
		vertex_spirv = vertex_spirv,
		fragment_spirv = fragment_spirv,
		color_format = gpu.color_format(g),
		vertex_stride = size_of(Weather_Vertex),
		attributes = WEATHER_ATTRIBUTES[:],
		alpha_blend = true,
		depth = .Test,
	}
}

weather_reload :: proc(
	p: ^Weather_Pass,
	g: ^gpu.Gpu,
	vertex_spirv, fragment_spirv: []byte,
) -> bool {
	return gpu.replace_pipeline(
		g,
		&p.pipeline,
		weather_pipeline_desc(g, vertex_spirv, fragment_spirv),
	)
}

weather_destroy :: proc(p: ^Weather_Pass, g: ^gpu.Gpu) {
	for &b in p.frames {gpu.destroy_buffer(g, &b)}
	gpu.destroy_pipeline(g, &p.pipeline)
	p^ = {}
}

// weather_upload turns this frame's drops into quads (relative to the camera's
// chunk) and clears d for the next frame.
weather_upload :: proc(p: ^Weather_Pass, g: ^gpu.Gpu, d: ^Weather_Draw, camera: Camera) -> bool {
	slot := gpu.frame_slot(g)
	defer clear(&d.drops)
	p.counts[slot] = 0
	if len(d.drops) == 0 {return true}
	size := len(d.drops) * 6 * size_of(Weather_Vertex)
	ensure_buffer(g, &p.frames[slot], size, {.VERTEX_BUFFER}, "weather vertices") or_return
	out := mem.slice_data_cast([]Weather_Vertex, p.frames[slot].mapped[:size])
	origin := [3]f64{f64(camera.chunk.x), f64(camera.chunk.y), f64(camera.chunk.z)} * CHUNK_EXTENT
	n := 0
	for drop in d.drops {
		rel := drop.at - origin
		at := [3]f32{f32(rel.x), f32(rel.y), f32(rel.z)}
		to := at - camera.position
		right: [3]f32
		up: [3]f32
		switch drop.shape {
		case .Streak:
			// Turned about the vertical to face the camera; the top blown by the wind.
			h := math.sqrt(to.x * to.x + to.z * to.z)
			right = {-to.z, 0, to.x} / max(h, 1e-3) * (drop.width / 2)
			up = {drop.lean.x, drop.height, drop.lean.y}
		case .Flake:
			// Facing the camera: right is across the line of sight, up across both.
			l := math.sqrt(to.x * to.x + to.y * to.y + to.z * to.z)
			f := to / max(l, 1e-3)
			r := [3]f32{-f.z, 0, f.x}
			rl := math.sqrt(r.x * r.x + r.z * r.z)
			r = r / max(rl, 1e-3) if rl > 1e-3 else [3]f32{1, 0, 0}
			u := [3]f32{r.y * f.z - r.z * f.y, r.z * f.x - r.x * f.z, r.x * f.y - r.y * f.x}
			right = r * (drop.width / 2)
			up = u * drop.height
			at -= up / 2
		}
		corners := [4]Weather_Vertex {
			{pos = at - right, uv = {-1, 0}},
			{pos = at + right, uv = {1, 0}},
			{pos = at + right + up, uv = {1, 1}},
			{pos = at - right + up, uv = {-1, 1}},
		}
		for &c in corners {c.color, c.shape = drop.color, u8(drop.shape)}
		for k in ([6]int{0, 1, 2, 0, 2, 3}) {
			out[n] = corners[k]
			n += 1
		}
	}
	p.counts[slot] = u32(n)
	return true
}

// weather_draw records the pass, after the world's water.
weather_draw :: proc(p: ^Weather_Pass, g: ^gpu.Gpu, frame: gpu.Frame, scene: u64) {
	slot := gpu.frame_slot(g)
	if p.counts[slot] == 0 {return}
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "weather")
	defer gpu.end_label(g, cmd)
	vk.CmdBindPipeline(cmd, .GRAPHICS, p.pipeline.handle)
	gpu.bind_globals(g, cmd)
	push := Weather_Push{scene}
	gpu.push_constants(g, cmd, &push)
	offset: vk.DeviceSize
	vk.CmdBindVertexBuffers(cmd, 0, 1, &p.frames[slot].handle, &offset)
	gpu.draw(g, cmd, p.counts[slot])
}
