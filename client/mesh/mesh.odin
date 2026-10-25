package mesh

import "core:slice"

import "../../game"

// Chunk meshing: visible block faces with per-vertex ambient occlusion and
// smooth light, from an immutable padded snapshot (the chunk plus a 1-block
// border from its 26 neighbours, and its light from game.light_chunk), so it
// runs on worker threads while the world changes.
//
// Vertices are 8 bytes: chunk-local position (0..16), face, AO level, sky
// and block light (0..15 each, averaged over the open cells around the
// corner) and texture layer. Texture coordinates follow from position and face in the
// shader. Every quad is 4 vertices drawn with the shared index pattern
// 0 1 2 0 2 3; quads whose AO is brighter along the 1-3 diagonal are rotated
// so it splits them along that diagonal instead (avoids AO's classic
// diamond artifact).

PADDED :: game.CHUNK_SIZE + 2
PADDED_VOLUME :: PADDED * PADDED * PADDED

// Snapshot holds blocks at local positions -1..16 on each axis.
Snapshot :: [PADDED_VOLUME]game.Block

// Light_Snapshot: the same cells' light (sky << 4 | block), as
// game.light_chunk computes it (LIGHT_OUT is PADDED).
Light_Snapshot :: [PADDED_VOLUME]u8

#assert(game.LIGHT_OUT == PADDED)

Vertex :: struct {
	// x | y << 5 | z << 10 | face << 15 | ao << 18 | sky << 20 | block << 24
	// (ao: 0 darkest .. 3 open; sky and block light 0..15)
	packed: u32,
	layer:  u32, // texture array layer
}

Face :: enum u8 {
	Pos_X,
	Neg_X,
	Pos_Y,
	Neg_Y,
	Pos_Z,
	Neg_Z,
}

// snapshot_index of a local position, each axis in -1..16.
snapshot_index :: #force_inline proc(x, y, z: i32) -> int {
	return int(x + 1) + int(z + 1) * PADDED + int(y + 1) * PADDED * PADDED
}

// Neighbourhood lists the chunk and its 26 neighbours, by offset:
// n[(dx + 1) + (dy + 1) * 3 + (dz + 1) * 9].
Neighbourhood :: [27]^game.Chunk_Blocks

neighbour_index :: #force_inline proc(d: [3]i32) -> int {
	return int(d.x + 1) + int(d.y + 1) * 3 + int(d.z + 1) * 9
}

// snapshot_fill copies the chunk at the centre of n and its border.
snapshot_fill :: proc(s: ^Snapshot, n: ^Neighbourhood) {
	for y in i32(-1) ..= game.CHUNK_SIZE {
		cy := (y + game.CHUNK_SIZE) / game.CHUNK_SIZE - 1 // -1, 0 or 1
		for z in i32(-1) ..= game.CHUNK_SIZE {
			cz := (z + game.CHUNK_SIZE) / game.CHUNK_SIZE - 1
			for x in i32(-1) ..= game.CHUNK_SIZE {
				cx := (x + game.CHUNK_SIZE) / game.CHUNK_SIZE - 1
				c := n[neighbour_index({cx, cy, cz})]
				s[snapshot_index(x, y, z)] = game.chunk_get(c, game.local_of({x, y, z}))
			}
		}
	}
}

// Per face: the normal and two in-plane axes u, v with u × v = normal, so
// corners (0,0) (1,0) (1,1) (0,1) wind counter-clockwise seen from outside.
@(private = "file")
Face_Axes :: struct {
	normal, u, v: [3]i32,
}

@(private = "file", rodata)
FACE_AXES := [Face]Face_Axes {
	.Pos_X = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}},
	.Neg_X = {{-1, 0, 0}, {0, 0, 1}, {0, 1, 0}},
	.Pos_Y = {{0, 1, 0}, {0, 0, 1}, {1, 0, 0}},
	.Neg_Y = {{0, -1, 0}, {1, 0, 0}, {0, 0, 1}},
	.Pos_Z = {{0, 0, 1}, {1, 0, 0}, {0, 1, 0}},
	.Neg_Z = {{0, 0, -1}, {0, 1, 0}, {1, 0, 0}},
}

@(private = "file", rodata)
CORNERS := [4][2]i32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}

// Layer: how a block's faces are drawn. Each chunk's mesh holds the three
// in this order: opaque (depth-written), cutout (alpha-tested: leaves,
// plants) and translucent (blended, after everything else: water).
Layer :: enum u8 {
	Opaque,
	Cutout,
	Translucent,
}

// Shape: a full cube's faces, or a plant's two crossed quads.
Shape :: enum u8 {
	None,
	Cube,
	Cross,
}

// block_shape: how a block is drawn (a switch, so a new block does not
// compile until it says).
block_shape :: proc(b: game.Block) -> (Shape, Layer) {
	switch b {
	case .Air:
		return .None, .Opaque
	case .Stone,
	     .Dirt,
	     .Grass,
	     .Sand,
	     .Gravel,
	     .Bedrock,
	     .Lamp,
	     .Snow,
	     .Ice,
	     .Clay,
	     .Sandstone,
	     .Log,
	     .Spruce_Log,
	     .Coal_Ore,
	     .Iron_Ore,
	     .Copper_Ore,
	     .Cactus,
	     .Cobblestone,
	     .Stone_Bricks,
	     .Planks,
	     .Wool,
	     .Farmland,
	     .Farmland_Moist,
	     .Gate_Ring,
	     .Gate_Chevron,
	     .Gate_Chevron_Lit:
		return .Cube, .Opaque
	case .Leaves, .Spruce_Leaves, .Glass:
		return .Cube, .Cutout
	case .Tall_Grass, .Poppy, .Dandelion, .Wheat_0 ..= .Wheat_7:
		return .Cross, .Cutout
	case .Water, .Water_1 ..= .Water_7, .Water_Falling, .Gate_Horizon:
		return .Cube, .Translucent
	}
	return .None, .Opaque
}

// The two diagonal planes of a Cross, as face codes after the six cube
// faces (the shader shades and textures them).
CROSS_A :: 6
CROSS_B :: 7

// SURFACE: a vertex on a liquid's open top (the shader lowers and moves
// it), DROP_SHIFT: how far below the block's top it sits, in eighths (3
// bits: the levels of the water around that corner).
SURFACE :: u32(1) << 28
DROP_SHIFT :: 29

// Face groups: within a layer, quads come grouped by the way they face
// (Face order), then the plants' crossed quads (seen from both sides), so
// the renderer can leave out the directions that face away from the
// camera (a chunk wholly on one side of it shows at most three).
FACE_GROUPS :: 7
CROSS_GROUP :: 6

// Counts: vertices of each layer's face groups, in order.
Counts :: [Layer][FACE_GROUPS]int

// counts_layer: all of a layer's vertices.
counts_layer :: proc(c: Counts, layer: Layer) -> (n: int) {
	for g in c[layer] {n += g}
	return
}

// mesh_chunk writes the snapshot's visible faces to out (cleared first),
// layer by layer, each layer's quads by face group. light may be nil:
// everything fully lit by the sky (tests).
mesh_chunk :: proc(
	s: ^Snapshot,
	light: ^Light_Snapshot,
	out: ^[dynamic]Vertex,
	merge := true, // greedy meshing (off: one quad a face, for tests)
) -> (
	counts: Counts,
) {
	clear(out)
	for layer in Layer {
		before := len(out)
		for y in i32(0) ..< game.CHUNK_SIZE {
			for z in i32(0) ..< game.CHUNK_SIZE {
				for x in i32(0) ..< game.CHUNK_SIZE {
					b := s[snapshot_index(x, y, z)]
					shape, l := block_shape(b)
					if l != layer {continue}
					switch shape {
					case .None:
					case .Cube:
						cube_faces(s, light, out, {x, y, z}, b, layer)
					case .Cross:
						cross_quads(s, light, out, {x, y, z}, b)
					}
				}
			}
		}
		if merge && layer != .Translucent {merge_faces(out, before)}
		lower_tilled(out[before:])
		counts[layer] = group_faces(out[before:])
	}
	return
}

// merge_faces: greedy meshing of the quads from before on. A quad whose
// four corners are alike (AO, light, texture: lit and shaded evenly) is
// mergeable; mergeable quads facing the same way in the same plane with
// the same corners join into rectangles (rows first, then down), drawn
// exactly as before: the corners' values interpolate to the same, and
// textures repeat with the world grid (the shader's uv is the position).
// Other quads are kept as they are. (Not water: its surface corners
// differ.)
@(private = "file")
merge_faces :: proc(out: ^[dynamic]Vertex, before: int) {
	POSITION_BITS :: u32(1 << 15 - 1)
	Mergeable :: struct {
		face:  int,
		plane: i32, // position along the face's axis
		attrs: u64, // the corners' shared bits (layer, light, AO), and the face
		u, v:  i32, // the quad's low corner, in the face's in-plane axes
	}
	quads := out[before:]
	found := make([dynamic]Mergeable, 0, len(quads) / 4, context.temp_allocator)
	kept := before
	for i := 0; i < len(quads); i += 4 {
		q := quads[i:][:4]
		attrs := q[0].packed &~ POSITION_BITS
		alike := true
		for v in q[1:] {alike &&= v.packed &~ POSITION_BITS == attrs && v.layer == q[0].layer}
		face := int(attrs >> 15 & 7)
		if !alike || face >= len(Face) {
			// Kept: moved down over the mergeable ones taken out.
			copy(out[kept:][:4], q)
			kept += 4
			continue
		}
		axes := FACE_AXES[Face(face)]
		lo := vertex_position(q[0])
		for v in q[1:] {lo = {min(lo.x, vertex_position(v).x), min(lo.y, vertex_position(v).y), min(lo.z, vertex_position(v).z)}}
		normal_axis := [3]i32{abs(axes.normal.x), abs(axes.normal.y), abs(axes.normal.z)}
		append(
			&found,
			Mergeable {
				face,
				dot(lo, normal_axis),
				u64(q[0].layer) << 32 | u64(attrs),
				dot(lo, axes.u),
				dot(lo, axes.v),
			},
		)
	}
	resize(out, kept)
	if len(found) == 0 {return}
	slice.sort_by(found[:], proc(a, b: Mergeable) -> bool {
		if a.face != b.face {return a.face < b.face}
		if a.plane != b.plane {return a.plane < b.plane}
		if a.attrs != b.attrs {return a.attrs < b.attrs}
		if a.v != b.v {return a.v < b.v}
		return a.u < b.u
	})
	// Each run of one face, plane and corners: a 16 x 16 grid to cover.
	for start := 0; start < len(found); {
		first := found[start]
		end := start
		grid: [game.CHUNK_SIZE][game.CHUNK_SIZE]bool // [v][u]
		for end < len(found) &&
		    found[end].face == first.face &&
		    found[end].plane == first.plane &&
		    found[end].attrs == first.attrs {
			grid[found[end].v][found[end].u] = true
			end += 1
		}
		for v in i32(0) ..< game.CHUNK_SIZE {
			for u in i32(0) ..< game.CHUNK_SIZE {
				if !grid[v][u] {continue}
				w := i32(1)
				for u + w < game.CHUNK_SIZE && grid[v][u + w] {w += 1}
				h := i32(1)
				grow: for v + h < game.CHUNK_SIZE {
					for k in u ..< u + w {if !grid[v + h][k] {break grow}}
					h += 1
				}
				for dv in v ..< v + h {
					for du in u ..< u + w {grid[dv][du] = false}
				}
				emit_merged(out, first, u, v, w, h)
			}
		}
		start = end
	}

	dot :: #force_inline proc(a, b: [3]i32) -> i32 {return a.x * b.x + a.y * b.y + a.z * b.z}
}

// emit_merged writes the rectangle u..u+w, v..v+h of a mergeable quad's
// plane, its corners in emit_face's order.
@(private = "file")
emit_merged :: proc(out: ^[dynamic]Vertex, m: $T, u, v, w, h: i32) {
	axes := FACE_AXES[Face(m.face)]
	normal_axis := [3]i32{abs(axes.normal.x), abs(axes.normal.y), abs(axes.normal.z)}
	base := normal_axis * m.plane
	attrs := u32(m.attrs)
	layer := u32(m.attrs >> 32)
	quad: [4]Vertex
	for corner, i in CORNERS {
		p := base + (u + corner[0] * w) * axes.u + (v + corner[1] * h) * axes.v
		quad[i] = {
			packed = attrs | u32(p.x) | u32(p.y) << 5 | u32(p.z) << 10,
			layer  = layer,
		}
	}
	append(out, ..quad[:])
}

// group_faces orders a layer's quads by face group (a counting sort, each
// group keeping its order) and counts each group's vertices.
@(private = "file")
group_faces :: proc(quads: []Vertex) -> (counts: [FACE_GROUPS]int) {
	group :: #force_inline proc(v: Vertex) -> int {return min(
			int(v.packed >> 15 & 7),
			CROSS_GROUP,
		)}
	for i := 0; i < len(quads); i += 4 {counts[group(quads[i])] += 4}
	sorted := make([]Vertex, len(quads), context.temp_allocator)
	at: [FACE_GROUPS]int
	for g in 1 ..< FACE_GROUPS {at[g] = at[g - 1] + counts[g - 1]}
	for i := 0; i < len(quads); i += 4 {
		g := group(quads[i])
		copy(sorted[at[g]:][:4], quads[i:][:4])
		at[g] += 4
	}
	copy(quads, sorted)
	return
}

// TILLED: set on every vertex of farmland's quads; LOWERED (read by the
// shader, as the texture layer's bit 16) on the vertices of them that are
// at the block's top, a sixteenth down: set after merging, which keeps a
// merged quad's four corners alike.
TILLED :: u32(1) << 17
LOWERED :: u32(1) << 16

// lower_tilled turns TILLED into LOWERED for the vertices at the top of
// each quad (every vertex of a top face, the upper two of a side, none of a
// bottom face).
@(private = "file")
lower_tilled :: proc(quads: []Vertex) {
	for i := 0; i + 3 < len(quads); i += 4 {
		q := quads[i:][:4]
		if q[0].layer & TILLED == 0 {continue}
		top := max(
			vertex_position(q[0]).y,
			vertex_position(q[1]).y,
			vertex_position(q[2]).y,
			vertex_position(q[3]).y,
		)
		face := vertex_face(q[0])
		for &v in q {
			v.layer &= ~TILLED
			if face == .Pos_Y ||
			   (face != .Neg_Y && vertex_position(v).y == top) {v.layer |= LOWERED}
		}
	}
}

// cube_faces: a cube's faces that can be seen: those not against an
// opaque block (nor, for a liquid, against more of it).
@(private = "file")
cube_faces :: proc(
	s: ^Snapshot,
	light: ^Light_Snapshot,
	out: ^[dynamic]Vertex,
	p: [3]i32,
	b: game.Block,
	layer: Layer,
) {
	for axes, face in FACE_AXES {
		front := p + axes.normal
		n := s[snapshot_index(front.x, front.y, front.z)]
		if game.block_opaque(n) {continue}
		_, water := game.water_level(b)
		_, water_beside := game.water_level(n)
		if water && water_beside {continue} 	// inside the same body of water
		if b == .Glass && n == .Glass {continue} 	// one pane
		tilled := game.block_is_farmland(b)
		if tilled && game.block_is_farmland(n) {continue} 	// (not opaque, but as good as)
		first := len(out)
		emit_face(s, light, out, p, face, axes, block_texture(b, face))
		if tilled {for &v in out[first:] {v.layer |= TILLED}}
		if _, under_water := game.water_level(s[snapshot_index(p.x, p.y + 1, p.z)]);
		   water && !under_water {
			for &v in out[first:] {
				at := vertex_position(v)
				if at.y == p.y + 1 {v.packed |= SURFACE | water_drop(s, at) << DROP_SHIFT}
			}
		}
	}
}

// water_drop: how far below its block's top a water surface corner at
// chunk-local corner c sits, in eighths: the average over the water
// blocks touching the corner (a source sits a ninth low, each flow level a
// ninth lower; water with water above it stays full).
@(private = "file")
water_drop :: proc(s: ^Snapshot, c: [3]i32) -> u32 {
	sum, n: f32
	y := c.y - 1
	for dz in i32(-1) ..= 0 {
		for dx in i32(-1) ..= 0 {
			level, water := game.water_level(s[snapshot_index(c.x + dx, y, c.z + dz)])
			if !water {continue}
			if _, fed := game.water_level(s[snapshot_index(c.x + dx, y + 1, c.z + dz)]);
			   fed {return 0}
			if level == game.WATER_FALLING_LEVEL {level = 0} 	// landed: as high as a source
			sum += f32(1 + level) / 9
			n += 1
		}
	}
	if n == 0 {return 1}
	return u32(clamp(sum / n * 8 + 0.5, 0, 7))
}

// cross_quads: a plant, two quads corner to corner, seen from both sides,
// lit by its own cell.
@(private = "file")
cross_quads :: proc(
	s: ^Snapshot,
	light: ^Light_Snapshot,
	out: ^[dynamic]Vertex,
	p: [3]i32,
	b: game.Block,
) {
	sky, block := u32(15), u32(0)
	if light != nil {
		l := light[snapshot_index(p.x, p.y, p.z)]
		sky, block = u32(l >> 4), u32(l & 15)
	}
	block = max(block, u32(game.block_light(b)))
	layer := block_texture(b, .Pos_X)
	PLANES :: [2][4][3]i32 {
		{{0, 0, 0}, {1, 0, 1}, {1, 1, 1}, {0, 1, 0}},
		{{1, 0, 0}, {0, 0, 1}, {0, 1, 1}, {1, 1, 0}},
	}
	for plane, i in PLANES {
		face := u32(CROSS_A + i)
		quad: [4]Vertex
		for c, k in plane {
			v := p + c
			quad[k] = {
				packed = u32(
					v.x,
				) | u32(v.y) << 5 | u32(v.z) << 10 | face << 15 | 3 << 18 | sky << 20 | block << 24,
				layer  = layer,
			}
		}
		append(out, ..quad[:])
		append(out, quad[3], quad[2], quad[1], quad[0]) // the back
	}
}

@(private = "file")
emit_face :: proc(
	s: ^Snapshot,
	light: ^Light_Snapshot,
	out: ^[dynamic]Vertex,
	p: [3]i32,
	face: Face,
	axes: Face_Axes,
	layer: u32,
) {
	solid :: #force_inline proc(s: ^Snapshot, p: [3]i32) -> int {
		return 1 if game.block_opaque(s[snapshot_index(p.x, p.y, p.z)]) else 0
	}
	front := p + axes.normal
	// The face's plane: the far side of the block for positive normals.
	base := p + {max(axes.normal.x, 0), max(axes.normal.y, 0), max(axes.normal.z, 0)}
	quad: [4]Vertex
	ao: [4]u32
	for corner, i in CORNERS {
		du := axes.u if corner[0] == 1 else -axes.u
		dv := axes.v if corner[1] == 1 else -axes.v
		side1, side2 := solid(s, front + du), solid(s, front + dv)
		corner_solid := solid(s, front + du + dv)
		level := 0 if side1 == 1 && side2 == 1 else 3 - side1 - side2 - corner_solid
		ao[i] = u32(level)
		sky, block := corner_light(light, front, du, dv, side1 == 1, side2 == 1, corner_solid == 1)
		emits := u32(game.block_light(s[snapshot_index(p.x, p.y, p.z)]))
		block = max(block, emits) // a light's own faces are as bright as it
		v := base + corner[0] * axes.u + corner[1] * axes.v
		quad[i] = {
			packed = u32(
				v.x,
			) | u32(v.y) << 5 | u32(v.z) << 10 | u32(face) << 15 | u32(level) << 18 | sky << 20 | block << 24,
			layer  = layer,
		}
	}
	if ao[0] + ao[2] < ao[1] + ao[3] {
		// Split along 1-3: start the quad at corner 1 (same winding).
		quad = {quad[1], quad[2], quad[3], quad[0]}
	}
	append(out, ..quad[:])
}

// corner_light averages sky and block light over the open cells touching a
// face corner: the cell in front of the face, the two beside it, and the
// one diagonal (unless both sides are solid, which hide it).
@(private = "file")
corner_light :: proc(
	light: ^Light_Snapshot,
	front, du, dv: [3]i32,
	side1, side2, corner: bool,
) -> (
	sky, block: u32,
) {
	if light == nil {return 15, 0}
	at :: proc(light: ^Light_Snapshot, p: [3]i32) -> u8 {return(
			light[snapshot_index(p.x, p.y, p.z)] \
		)}
	sum_sky, sum_block, n: u32
	add :: proc(l: u8, sum_sky, sum_block, n: ^u32) {
		sum_sky^ += u32(l >> 4)
		sum_block^ += u32(l & 15)
		n^ += 1
	}
	add(at(light, front), &sum_sky, &sum_block, &n)
	if !side1 {add(at(light, front + du), &sum_sky, &sum_block, &n)}
	if !side2 {add(at(light, front + dv), &sum_sky, &sum_block, &n)}
	if !corner && !(side1 && side2) {add(at(light, front + du + dv), &sum_sky, &sum_block, &n)}
	return (sum_sky + n / 2) / n, (sum_block + n / 2) / n
}

// Vertex fields, for tests and debugging (the shader unpacks the same way).
vertex_position :: proc(v: Vertex) -> [3]i32 {
	return {i32(v.packed & 31), i32(v.packed >> 5 & 31), i32(v.packed >> 10 & 31)}
}

vertex_face :: proc(v: Vertex) -> Face {
	return Face(v.packed >> 15 & 7)
}

vertex_ao :: proc(v: Vertex) -> u32 {
	return v.packed >> 18 & 3
}

vertex_light :: proc(v: Vertex) -> (sky, block: u32) {
	return v.packed >> 20 & 15, v.packed >> 24 & 15
}
