package client

import "client:mesh"
import "client:render"
import "common:game"

// What a hand holds, as meshes (docs/milestones/M48k.md). Pure: no GPU, no
// session. Every mesh is a triangle list of render.Held_Vertex with the
// grip at the origin, in blocks: +x right, +y up, -z front (the way a gun
// points). The pose (viewmodel.odin) puts the grip where the hand is.
//
//	a block         the block's own mesh (mesh.mesh_chunk over a one-block
//	                snapshot), HELD_BLOCK_SCALE of a block across
//	a model         the voxels of its model (data/models), HELD_VOXEL each
//	a flat item     its 16 x 16 sprite, each pixel a voxel, HELD_THICKNESS deep
//	the arm         the avatar's own right arm in its shirt and skin

HELD_VOXEL :: 0.04 // blocks: one voxel of a model
HELD_PIXEL :: 0.025 // blocks: one pixel of a flat item's sprite
HELD_THICKNESS :: 2 // pixels deep
HELD_BLOCK_SCALE :: 0.24 // a held block's cell, in blocks
HELD_ICON_GRIP :: [3]f32{4, 4, HELD_THICKNESS / 2} // in sprite pixels: the lower left, where a handle is

Held_Kind :: enum u8 {
	None, // an empty hand
	Block, // an item that places a block
	Model, // an item with a voxel model
	Flat, // anything else with a sprite
}

Held_Mesh :: struct {
	vertices: [dynamic]render.Held_Vertex, // triangles
}

held_mesh_destroy :: proc(m: ^Held_Mesh) {
	delete(m.vertices)
	m^ = {}
}

// held_quads: how many quads a mesh has (each is two triangles).
held_quads :: proc(m: ^Held_Mesh) -> int {
	return len(m.vertices) / 6
}

// The light each face gets: the world's own (assets/shaders/world.vert).
@(private = "file", rodata)
FACE_LIGHT := [8]f32{0.80, 0.80, 1.00, 0.50, 0.65, 0.65, 0.90, 0.90}
@(private = "file", rodata)
AO_LIGHT := [4]f32{0.35, 0.60, 0.80, 1.00}

@(private = "file")
shade_byte :: proc(light: f32) -> u8 {
	return u8(clamp(light, 0, 1) * 255 + 0.5)
}

// held_quad appends a quad (corners in order round it) as two triangles.
@(private = "file")
held_quad :: proc(m: ^Held_Mesh, c: [4]render.Held_Vertex) {
	for k in ([6]int{0, 1, 2, 0, 2, 3}) {append(&m.vertices, c[k])}
}

// held_mesh_grid makes the faces of a grid of voxels that face an empty
// cell: cells[x + z * size.x + y * size.x * size.z] is the colour (alpha 0:
// empty). `grip` (in voxels) is the point that sits at the origin.
held_mesh_grid :: proc(
	size: [3]int,
	cells: [][4]u8,
	grip: [3]f32,
	pitch: f32,
	allocator := context.allocator,
) -> (
	m: Held_Mesh,
) {
	m.vertices = make([dynamic]render.Held_Vertex, allocator)
	at :: proc(size: [3]int, cells: [][4]u8, p: [3]int) -> [4]u8 {
		if p.x < 0 || p.y < 0 || p.z < 0 || p.x >= size.x || p.y >= size.y || p.z >= size.z {
			return {}
		}
		return cells[p.x + p.z * size.x + p.y * size.x * size.z]
	}
	NORMALS :: [6][3]int{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	for y in 0 ..< size.y {
		for z in 0 ..< size.z {
			for x in 0 ..< size.x {
				c := at(size, cells, {x, y, z})
				if c.a == 0 {continue}
				for n, face in NORMALS {
					if at(size, cells, [3]int{x, y, z} + n).a != 0 {continue}
					// The face's plane and its two axes.
					axis := 0 if n.x != 0 else 1 if n.y != 0 else 2
					u_axis, v_axis := (axis + 1) % 3, (axis + 2) % 3
					plane := [3]f32{f32(x), f32(y), f32(z)}
					if n[axis] > 0 {plane[axis] += 1}
					corners: [4]render.Held_Vertex
					for k, i in ([4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}) {
						p := plane
						p[u_axis] += k[0]
						p[v_axis] += k[1]
						corners[i] = {
							pos   = (p - grip) * pitch,
							// One value a face: the shader's crunch is per voxel face.
							uv    = {f32(x + z * 17 + face * 31) + 0.5, f32(y) + 0.5},
							color = {c.r, c.g, c.b, 255},
							layer = render.HELD_FLAT,
							shade = shade_byte(FACE_LIGHT[face]),
						}
					}
					held_quad(&m, corners)
				}
			}
		}
	}
	// The grid's z grows to the back, the model's front is -z: nothing to flip
	// (a model's column 0 is z 0, and z 0 is the smallest z).
	return
}

// held_mesh_model: a voxel model's mesh, its grip at the origin.
held_mesh_model :: proc(model: ^game.Model_Def, allocator := context.allocator) -> Held_Mesh {
	cells := make([][4]u8, len(model.voxels), context.temp_allocator)
	for v, i in model.voxels {
		if v != 0 {cells[i] = model.palette[v - 1]}
	}
	grip := [3]f32{f32(model.grip.x) + 0.5, f32(model.grip.y) + 0.5, f32(model.grip.z) + 0.5}
	return held_mesh_grid(
		{int(model.size[2]), int(model.size[1]), int(model.size[0])},
		cells,
		grip,
		HELD_VOXEL,
		allocator,
	)
}

// held_mesh_icon: a flat item's sprite (16 x 16 pixels, ICON_SIZE across: the
// art item_sprite draws) as voxels HELD_THICKNESS deep. false: the item has no
// sprite of its own.
held_mesh_icon :: proc(
	item: game.Item,
	info: game.Item_Info,
	allocator := context.allocator,
) -> (
	m: Held_Mesh,
	ok: bool,
) {
	sprite := new([ICON_SIZE * ICON_SIZE][4]u8, context.temp_allocator)
	item_sprite(item, info, sprite) or_return
	N :: 16
	cells := make([][4]u8, N * HELD_THICKNESS * N, context.temp_allocator)
	for y in 0 ..< N {
		for x in 0 ..< N {
			// The middle of the sprite's pixel (it is a flat patch).
			c :=
				sprite[(y * ICON_SIZE / N + ICON_SIZE / N / 2) * ICON_SIZE + x * ICON_SIZE / N + ICON_SIZE / N / 2]
			if c.a == 0 {continue}
			for z in 0 ..< HELD_THICKNESS {
				cells[x + z * N + (N - 1 - y) * N * HELD_THICKNESS] = c
			}
		}
	}
	m = held_mesh_grid({N, N, HELD_THICKNESS}, cells, HELD_ICON_GRIP, HELD_PIXEL, allocator)
	return m, true
}

// held_mesh_block: the mesh of one block (a state) as the world meshes it:
// mesh_chunk over a snapshot with the block alone in it, so its shape, its
// textures and its corners' shading are the world's. HELD_BLOCK_SCALE of a
// block across, the middle of the cell at the origin.
held_mesh_block :: proc(
	reg: ^game.Registry,
	block: game.Block,
	allocator := context.allocator,
) -> (
	m: Held_Mesh,
) {
	m.vertices = make([dynamic]render.Held_Vertex, allocator)
	snapshot := new(mesh.Snapshot, context.temp_allocator)
	snapshot[mesh.snapshot_index(0, 0, 0)] = block
	quads := make([dynamic]mesh.Vertex, context.temp_allocator)
	mesh.mesh_chunk(reg, snapshot, nil, &quads, merge = false)
	for q := 0; q + 4 <= len(quads); q += 4 {
		corners: [4]render.Held_Vertex
		for i in 0 ..< 4 {
			v := quads[q + i]
			local := mesh.vertex_position(v)
			face := int(v.packed >> 27 & 7)
			p := [3]f32{f32(local.x), f32(local.y), f32(local.z)} / mesh.SIXTEENTHS
			// The world shader's texture coordinates, from position and face.
			uv: [2]f32
			switch {
			case face < 2:
				uv = {p.z, -p.y}
			case face < 4:
				uv = {p.x, p.z}
			case:
				uv = {p.x, -p.y}
			}
			corners[i] = {
				pos   = (p - 0.5) * HELD_BLOCK_SCALE,
				uv    = uv,
				color = {255, 255, 255, 255},
				layer = u16(v.layer & mesh.LAYER_BITS),
				shade = shade_byte(FACE_LIGHT[face] * AO_LIGHT[mesh.vertex_ao(v)]),
			}
		}
		held_quad(&m, corners)
	}
	return
}

// held_box appends the six faces of a box (flat colour).
@(private = "file")
held_box :: proc(m: ^Held_Mesh, lo, hi: [3]f32, color: [4]u8) {
	for face in 0 ..< 6 {
		axis := face / 2
		u_axis, v_axis := (axis + 1) % 3, (axis + 2) % 3
		plane := lo if face % 2 == 1 else hi
		corners: [4]render.Held_Vertex
		for k, i in ([4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}) {
			p := [3]f32{}
			p[axis] = plane[axis]
			p[u_axis] = lo[u_axis] if k[0] == 0 else hi[u_axis]
			p[v_axis] = lo[v_axis] if k[1] == 0 else hi[v_axis]
			corners[i] = {
				pos   = p,
				uv    = {f32(face) + 0.5, f32(i / 2) + 0.5},
				color = color,
				layer = render.HELD_FLAT,
				shade = shade_byte(FACE_LIGHT[face]),
			}
		}
		held_quad(m, corners)
	}
}

// held_mesh_arm: the avatar's right arm (avatar_draw's boxes: a sleeve in the
// shirt's colour, a hand in skin), the shoulder at the origin and the arm
// along -y.
held_mesh_arm :: proc(shirt: [4]u8, allocator := context.allocator) -> (m: Held_Mesh) {
	m.vertices = make([dynamic]render.Held_Vertex, allocator)
	held_box(&m, ARM_SLEEVE_LO, ARM_SLEEVE_HI, shirt)
	held_box(&m, ARM_HAND_LO, ARM_HAND_HI, AVATAR_SKIN)
	return
}

// The avatar's arm, as avatar_draw draws it (a sleeve over a hand).
ARM_SLEEVE_LO :: [3]f32{-0.075, -0.4, -0.075}
ARM_SLEEVE_HI :: [3]f32{0.075, 0.1, 0.075}
ARM_HAND_LO :: [3]f32{-0.075, -0.65, -0.075}
ARM_HAND_HI :: [3]f32{0.075, -0.4, 0.075}

// Held_Entry: what an item looks like in a hand, made once.
Held_Entry :: struct {
	kind: Held_Kind,
	mesh: Held_Mesh,
}

// Held_Cache: the entries by item; a registry that changed (hot reload, a new
// universe) empties it.
Held_Cache :: struct {
	registry: u64, // the registry's hash the entries were made for
	entries:  map[game.Item]Held_Entry,
}

held_cache_destroy :: proc(c: ^Held_Cache) {
	for _, &e in c.entries {held_mesh_destroy(&e.mesh)}
	delete(c.entries)
	c^ = {}
}

// held_entry: what `item` looks like in a hand (an empty hand, the no-item or
// an item without art: kind None).
held_entry :: proc(c: ^Held_Cache, reg: ^game.Registry, item: game.Item) -> ^Held_Entry {
	if c.registry != reg.hash {
		held_cache_destroy(c)
		c.registry = reg.hash
	}
	if e, found := &c.entries[item]; found {return e}
	e: Held_Entry
	info, known := game.item_info(reg, item)
	if known && item != game.NO_ITEM {
		if at, has := info.model.?; has {
			e.kind, e.mesh = .Model, held_mesh_model(&reg.models[at])
		} else if info.block != .Air {
			e.kind, e.mesh = .Block, held_mesh_block(reg, info.block)
		} else if m, ok := held_mesh_icon(item, info); ok {
			e.kind, e.mesh = .Flat, m
		}
	}
	if c.entries == nil {c.entries = make(map[game.Item]Held_Entry)}
	c.entries[item] = e
	return &c.entries[item]
}
