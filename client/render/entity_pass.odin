package render

import "core:math"
import "core:mem"
import vk "vendor:vulkan"

import "../gpu"

// Entities (for now: the other players) as boxes, rebuilt every frame on
// the CPU: few boxes, so no meshes to keep. Each box turns around a pivot
// (yaw, then pitch) and has a colour and a part (which the shader paints:
// noise per texel, eyes on a face). Lit by the scene's sky light and
// fogged like the world.
//
//	render.entity_box(&ed, pivot, yaw, pitch, lo, hi, color, .Body)
//	render.entity_upload(&pass, &g, &ed, camera)   // before begin_rendering
//	render.entity_draw(&pass, &g, frame, scene)    // after world_draw

Entity_Part :: enum u8 {
	Body,
	Legs,
	Head,
	Face, // a head's front: has eyes
}

Entity_Draw :: struct {
	boxes: [dynamic]Entity_Box,
}

Entity_Box :: struct {
	pivot:      [3]f64, // world position it turns around
	yaw, pitch: f32,
	lo, hi:     [3]f32, // the box around the pivot, before turning (-z is its front)
	color:      [4]u8, // sRGB
	part:       Entity_Part, // Head: its front face is drawn as Face
}

Entity_Pass :: struct {
	pipeline: gpu.Pipeline,
	frames:   [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
	counts:   [gpu.FRAMES_IN_FLIGHT]u32,
}

@(private)
Entity_Vertex :: struct {
	pos:   [3]f32, // from the camera chunk's origin
	uv:    [2]f32, // 0..1 across the face
	color: [4]u8,
	part:  u8,
	shade: u8, // 0..255: how much light this face gets
	_:     [2]u8,
}

@(private = "file")
Entity_Push :: struct {
	scene: u64,
}

entity_draw_init :: proc(d: ^Entity_Draw, allocator := context.allocator) {
	d.boxes = make([dynamic]Entity_Box, allocator)
}

entity_draw_destroy :: proc(d: ^Entity_Draw) {
	delete(d.boxes)
}

entity_box :: proc(
	d: ^Entity_Draw,
	pivot: [3]f64,
	yaw, pitch: f32,
	lo, hi: [3]f32,
	color: [4]u8,
	part: Entity_Part,
) {
	append(&d.boxes, Entity_Box{pivot, yaw, pitch, lo, hi, color, part})
}

entity_init :: proc(p: ^Entity_Pass, g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> bool {
	ok: bool
	p.pipeline, ok = gpu.create_pipeline(g, entity_pipeline_desc(g, vertex_spirv, fragment_spirv))
	return ok
}

@(private = "file", rodata)
ENTITY_ATTRIBUTES := [4]gpu.Vertex_Attribute {
	{.R32G32B32_SFLOAT, u32(offset_of(Entity_Vertex, pos))},
	{.R32G32_SFLOAT, u32(offset_of(Entity_Vertex, uv))},
	{.R8G8B8A8_UNORM, u32(offset_of(Entity_Vertex, color))},
	{.R8G8_UINT, u32(offset_of(Entity_Vertex, part))},
}

@(private = "file")
entity_pipeline_desc :: proc(
	g: ^gpu.Gpu,
	vertex_spirv, fragment_spirv: []byte,
) -> gpu.Pipeline_Desc {
	return {
		name = "entities",
		vertex_spirv = vertex_spirv,
		fragment_spirv = fragment_spirv,
		color_format = gpu.color_format(g),
		vertex_stride = size_of(Entity_Vertex),
		attributes = ENTITY_ATTRIBUTES[:],
		depth = .Test_Write,
	}
}

entity_reload :: proc(p: ^Entity_Pass, g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> bool {
	return gpu.replace_pipeline(
		g,
		&p.pipeline,
		entity_pipeline_desc(g, vertex_spirv, fragment_spirv),
	)
}

entity_destroy :: proc(p: ^Entity_Pass, g: ^gpu.Gpu) {
	for &b in p.frames {gpu.destroy_buffer(g, &b)}
	gpu.destroy_pipeline(g, &p.pipeline)
	p^ = {}
}

// entity_upload turns this frame's boxes into triangles (relative to the
// camera's chunk) and clears d for the next frame.
entity_upload :: proc(p: ^Entity_Pass, g: ^gpu.Gpu, d: ^Entity_Draw, camera: Camera) -> bool {
	slot := gpu.frame_slot(g)
	defer clear(&d.boxes)
	p.counts[slot] = 0
	if len(d.boxes) == 0 {return true}
	size := len(d.boxes) * 36 * size_of(Entity_Vertex)
	ensure_buffer(g, &p.frames[slot], size, {.VERTEX_BUFFER}, "entity vertices") or_return
	out := mem.slice_data_cast([]Entity_Vertex, p.frames[slot].mapped[:size])
	origin := [3]f64{f64(camera.chunk.x), f64(camera.chunk.y), f64(camera.chunk.z)} * CHUNK_EXTENT
	n := 0
	for b in d.boxes {
		pivot := b.pivot - origin
		at := [3]f32{f32(pivot.x), f32(pivot.y), f32(pivot.z)}
		for face in 0 ..< 6 {
			corners := FACE_CORNERS[face]
			part := u8(b.part)
			if b.part == .Head && face == 5 {part = u8(Entity_Part.Face)} 	// -z: the front
			v: [4]Entity_Vertex
			for c, i in corners {
				local := [3]f32 {
					b.lo.x if c.x == 0 else b.hi.x,
					b.lo.y if c.y == 0 else b.hi.y,
					b.lo.z if c.z == 0 else b.hi.z,
				}
				v[i] = {
					pos   = at + turn(local, b.yaw, b.pitch),
					uv    = FACE_UV[i],
					color = b.color,
					part  = part,
					shade = FACE_SHADE[face],
				}
			}
			for k in ([6]int{0, 1, 2, 0, 2, 3}) {
				out[n] = v[k]
				n += 1
			}
		}
	}
	p.counts[slot] = u32(n)
	return true
}

// entity_draw records the pass; pipeline: another pass's (a second pass for
// a second picture shares the first's pipeline, its own vertex buffers).
entity_draw :: proc(
	p: ^Entity_Pass,
	g: ^gpu.Gpu,
	frame: gpu.Frame,
	scene: u64,
	pipeline: ^Entity_Pass = nil,
) {
	slot := gpu.frame_slot(g)
	if p.counts[slot] == 0 {return}
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "entities")
	defer gpu.end_label(g, cmd)
	vk.CmdBindPipeline(cmd, .GRAPHICS, (pipeline if pipeline != nil else p).pipeline.handle)
	gpu.bind_globals(g, cmd)
	push := Entity_Push{scene}
	gpu.push_constants(g, cmd, &push)
	offset: vk.DeviceSize
	vk.CmdBindVertexBuffers(cmd, 0, 1, &p.frames[slot].handle, &offset)
	vk.CmdDraw(cmd, p.counts[slot], 1, 0, 0)
}

// turn rotates a point around the pivot: pitch (about x: up and down),
// then yaw (about y: left from -z), as the camera turns.
@(private = "file")
turn :: proc(p: [3]f32, yaw, pitch: f32) -> [3]f32 {
	cp, sp := math.cos(pitch), math.sin(pitch)
	q := [3]f32{p.x, p.y * cp - p.z * sp, p.y * sp + p.z * cp}
	cy, sy := math.cos(yaw), math.sin(yaw)
	return {q.x * cy + q.z * sy, q.y, -q.x * sy + q.z * cy}
}

// Faces as corners (0: lo, 1: hi per axis), counter-clockwise from outside:
// +x -x +y -y +z -z.
@(private = "file", rodata)
FACE_CORNERS := [6][4][3]u8 {
	{{1, 0, 1}, {1, 0, 0}, {1, 1, 0}, {1, 1, 1}},
	{{0, 0, 0}, {0, 0, 1}, {0, 1, 1}, {0, 1, 0}},
	{{0, 1, 1}, {1, 1, 1}, {1, 1, 0}, {0, 1, 0}},
	{{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}},
	{{0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}},
	{{1, 0, 0}, {0, 0, 0}, {0, 1, 0}, {1, 1, 0}},
}

@(private = "file", rodata)
FACE_UV := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

@(private = "file", rodata)
FACE_SHADE := [6]u8{204, 204, 255, 128, 166, 166} // as world.vert's face light
