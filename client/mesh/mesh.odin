package mesh

import "core:slice"

import "../../common/game"

// Chunk meshing: visible block faces with per-vertex ambient occlusion and
// smooth light, from an immutable padded snapshot (the chunk plus a 1-block
// border from its 26 neighbours, and its light from game.light_chunk), so it
// runs on worker threads while the world changes.
//
// Vertices are 8 bytes: chunk-local position (in sixteenths of a block,
// 0..256), face, AO level, sky and block light (0..15 each, averaged over the
// open cells around the corner) and texture layer. Texture coordinates follow
// from position and face in the shader. Every quad is 4 vertices drawn with the shared index pattern
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
	// x | y << 9 | z << 18 | face << 27 | ao << 30
	// (positions in sixteenths of a block, 0..256; ao: 0 darkest .. 3 open)
	packed: u32,
	// texture array layer (12 bits) | sky << 12 | block << 16 | surface << 20 | drop << 21
	// (sky and block light 0..15; surface and drop: see SURFACE)
	layer:  u32,
}

Face :: game.Face
Face_Axes :: game.Face_Axes

// The bits of a vertex: where a position, a texture layer, the surface mark and its drop sit.
POSITION_BITS :: u32(1 << 27 - 1)
LAYER_BITS :: u32(0xFFF)
SIXTEENTHS :: 16 // a block's width in the positions

make_vertex :: #force_inline proc(pos: [3]i32, face: u32, ao, sky, block, layer: u32) -> Vertex {
	return {
		packed = u32(pos.x) | u32(pos.y) << 9 | u32(pos.z) << 18 | face << 27 | ao << 30,
		layer = layer | sky << 12 | block << 16,
	}
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

// block_shape: how a block is drawn, from the registry (its render and layer).
block_shape :: proc(t: ^game.Block_Table, b: game.Block) -> (Shape, Layer) {
	def := &t.defs[b]
	shape: Shape
	switch def.render {
	case .Cube:
		shape = .Cube
	case .Cross:
		shape = .Cross
	case .None:
		shape = .None
	}
	return shape, Layer(def.layer)
}

// The two diagonal planes of a Cross, as face codes after the six cube
// faces (the shader shades and textures them).
CROSS_A :: 6
CROSS_B :: 7

// SURFACE: a vertex on a liquid's open top (the shader lowers and moves
// it), DROP_SHIFT: how far below the block's top it sits, in eighths (3
// bits: the levels of the water around that corner).
SURFACE :: u32(1) << 20 // (in the layer word)
DROP_SHIFT :: 21

// Face groups: within a layer, quads come grouped by the way they face,
// with the plants' crossed quads (seen from both sides) as a group of their
// own, so the renderer can leave out the directions that face away from
// the camera (a chunk wholly on one side of it shows at most three). The
// order, +x +y +z crossed -z -y -x, keeps the groups a camera sees together:
// one of each axis' two and the crossed make two runs on average (one draw
// command each), where Face order made three.
FACE_GROUPS :: 7
CROSS_GROUP :: 3

// FACE_GROUP: each face's group.
@(rodata)
FACE_GROUP := [game.Face]int {
	.Pos_X = 0,
	.Pos_Y = 1,
	.Pos_Z = 2,
	.Neg_Z = 4,
	.Neg_Y = 5,
	.Neg_X = 6,
}

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
	reg: ^game.Registry,
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
					shape, l := block_shape(&reg.blocks, b)
					if l != layer {continue}
					switch shape {
					case .None:
					case .Cube:
						switch rs := reg.blocks.render[b]; rs {
						case game.SHAPE_EMPTY:
						case game.SHAPE_CUBE:
							cube_faces(reg, s, light, out, {x, y, z}, b, layer)
						case:
							box_faces(
								reg,
								s,
								light,
								out,
								{x, y, z},
								b,
								game.shape_boxes(&reg.blocks, rs),
							)
						}
					case .Cross:
						cross_quads(reg, s, light, out, {x, y, z}, b)
					}
				}
			}
		}
		if merge && layer != .Translucent {merge_faces(out, before)}
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
		face := int(attrs >> 27 & 7)
		// Only whole cells' faces merge: every corner on a block boundary.
		for v in q {
			p := vertex_position(v)
			alike &&= p.x % SIXTEENTHS == 0 && p.y % SIXTEENTHS == 0 && p.z % SIXTEENTHS == 0
		}
		if !alike || face >= len(Face) {
			// Kept: moved down over the mergeable ones taken out.
			copy(out[kept:][:4], q)
			kept += 4
			continue
		}
		axes := game.FACE_AXES[Face(face)]
		lo := vertex_position(q[0]) / SIXTEENTHS
		for v in q[1:] {
			at := vertex_position(v) / SIXTEENTHS
			lo = {min(lo.x, at.x), min(lo.y, at.y), min(lo.z, at.z)}
		}
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
	axes := game.FACE_AXES[Face(m.face)]
	normal_axis := [3]i32{abs(axes.normal.x), abs(axes.normal.y), abs(axes.normal.z)}
	base := normal_axis * m.plane
	attrs := u32(m.attrs)
	layer := u32(m.attrs >> 32)
	quad: [4]Vertex
	for corner, i in CORNERS {
		p := (base + (u + corner[0] * w) * axes.u + (v + corner[1] * h) * axes.v) * SIXTEENTHS
		quad[i] = {
			packed = attrs | u32(p.x) | u32(p.y) << 9 | u32(p.z) << 18,
			layer  = layer,
		}
	}
	append(out, ..quad[:])
}

// group_faces orders a layer's quads by face group (a counting sort, each
// group keeping its order) and counts each group's vertices.
@(private = "file")
group_faces :: proc(quads: []Vertex) -> (counts: [FACE_GROUPS]int) {
	group :: #force_inline proc(v: Vertex) -> int {
		face := v.packed >> 27 & 7
		return FACE_GROUP[game.Face(face)] if face < len(game.Face) else CROSS_GROUP
	}
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

// opposite: the face across the cell (a neighbour's face against this one).
opposite :: #force_inline proc(f: Face) -> Face {
	return Face(u8(f) ~ 1)
}

// rect_covered: every sixteenth of the face f of a cell inside lo..hi (only
// the two in-plane axes count) is set in the cover c.
@(private = "file")
rect_covered :: proc(c: ^game.Cover, f: Face, lo, hi: [3]u8) -> bool {
	axes := game.FACE_AXES[f]
	ua, va := 0, 0
	for k in 0 ..< 3 {
		if axes.u[k] != 0 {ua = k}
		if axes.v[k] != 0 {va = k}
	}
	mask := u16((u32(1) << hi[ua]) - (u32(1) << lo[ua]))
	for v in lo[va] ..< hi[va] {
		if c[f][v] & mask != mask {return false}
	}
	return true
}

// face_hidden: the cell n (across face f of a block) hides the part lo..hi of
// that face: n is opaque, or it is a solid shape (not see-through) whose
// render cover takes in the whole rectangle.
@(private = "file")
face_hidden :: proc(reg: ^game.Registry, n: game.Block, f: Face, lo, hi: [3]u8) -> bool {
	t := &reg.blocks
	if game.block_opaque(t, n) {return true}
	rs := t.render[n]
	if rs == game.SHAPE_EMPTY || rs == game.SHAPE_CUBE {return false}
	if Layer(t.defs[n].layer) != .Opaque {return false}
	return rect_covered(game.shape_cover(t, rs), opposite(f), lo, hi)
}

// cube_faces: a cube's faces that can be seen: those not hidden by the
// block across (opaque, or a shape that covers the face), nor, for a liquid,
// against more of it.
@(private = "file")
cube_faces :: proc(
	reg: ^game.Registry,
	s: ^Snapshot,
	light: ^Light_Snapshot,
	out: ^[dynamic]Vertex,
	p: [3]i32,
	b: game.Block,
	layer: Layer,
) {
	for axes, face in game.FACE_AXES {
		front := p + axes.normal
		n := s[snapshot_index(front.x, front.y, front.z)]
		if face_hidden(reg, n, face, {0, 0, 0}, {16, 16, 16}) {continue}
		_, water := game.water_level(b)
		_, water_beside := game.water_level(n)
		if water && water_beside {continue} 	// inside the same body of water
		if b == n && game.block_has(&reg.blocks, b, .Cull_Same) {continue} 	// one pane (glass)
		first := len(out)
		values := cell_face_values(reg, s, light, p, face, axes)
		at := i32(16) if axes.normal.x + axes.normal.y + axes.normal.z > 0 else 0
		emit_rect(out, values, face, axes, p, {0, 0}, {16, 16}, at, block_texture(reg, b, face))
		if _, under_water := game.water_level(s[snapshot_index(p.x, p.y + 1, p.z)]);
		   water && !under_water {
			for &v in out[first:] {
				at := vertex_position(v)
				if at.y == (p.y + 1) * SIXTEENTHS {
					v.layer |= SURFACE | water_drop(s, at / SIXTEENTHS) << DROP_SHIFT
				}
			}
		}
	}
}

// box_faces: the faces of a block drawn as boxes (a stair, a slab, a ladder,
// farmland): a face on the cell's boundary is left out where the block across
// hides it; a face inside the cell is always drawn, open (AO 3) and lit by the
// cell itself.
@(private = "file")
box_faces :: proc(
	reg: ^game.Registry,
	s: ^Snapshot,
	light: ^Light_Snapshot,
	out: ^[dynamic]Vertex,
	p: [3]i32,
	b: game.Block,
	boxes: []game.Box,
) {
	_, water := game.water_level(b)
	own := Face_Values{}
	own_ready := false
	cell: [Face]Face_Values
	cell_ready: [Face]bool
	for box in boxes {
		for axes, face in game.FACE_AXES {
			axis, ua, va := 0, 0, 0
			for k in 0 ..< 3 {
				if axes.normal[k] != 0 {axis = k}
				if axes.u[k] != 0 {ua = k}
				if axes.v[k] != 0 {va = k}
			}
			positive := axes.normal[axis] > 0
			at := box.hi[axis] if positive else box.lo[axis]
			layer_bits := block_texture(reg, b, face)
			uv_lo, uv_hi :=
				[2]i32{i32(box.lo[ua]), i32(box.lo[va])}, [2]i32{i32(box.hi[ua]), i32(box.hi[va])}
			if at == (16 if positive else 0) {
				front := p + axes.normal
				n := s[snapshot_index(front.x, front.y, front.z)]
				if face_hidden(reg, n, face, box.lo, box.hi) {continue}
				_, water_beside := game.water_level(n)
				if water && water_beside {continue}
				if b == n && game.block_has(&reg.blocks, b, .Cull_Same) {continue}
				if !cell_ready[face] {
					cell[face] = cell_face_values(reg, s, light, p, face, axes)
					cell_ready[face] = true
				}
				emit_rect(out, cell[face], face, axes, p, uv_lo, uv_hi, i32(at), layer_bits)
			} else {
				if !own_ready {
					own = own_values(reg, s, light, p, b)
					own_ready = true
				}
				emit_rect(out, own, face, axes, p, uv_lo, uv_hi, i32(at), layer_bits)
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
	reg: ^game.Registry,
	s: ^Snapshot,
	light: ^Light_Snapshot,
	out: ^[dynamic]Vertex,
	p: [3]i32,
	b: game.Block,
) {
	own := own_values(reg, s, light, p, b)
	layer := block_texture(reg, b, .Pos_X)
	PLANES :: [2][4][3]i32 {
		{{0, 0, 0}, {1, 0, 1}, {1, 1, 1}, {0, 1, 0}},
		{{1, 0, 0}, {0, 0, 1}, {0, 1, 1}, {1, 1, 0}},
	}
	for plane, i in PLANES {
		face := u32(CROSS_A + i)
		quad: [4]Vertex
		for c, k in plane {
			quad[k] = make_vertex((p + c) * SIXTEENTHS, face, 3, own.sky[0], own.block[0], layer)
		}
		append(out, ..quad[:])
		append(out, quad[3], quad[2], quad[1], quad[0]) // the back
	}
}

// Face_Values: the AO level and the sky and block light at the four corners of
// a face (in CORNERS' order).
@(private = "file")
Face_Values :: struct {
	ao, sky, block: [4]u32,
}

// cell_face_values: the values at the corners of the whole cell's face: AO
// from the opaque cells around the cell in front, light from the open ones.
@(private = "file")
cell_face_values :: proc(
	reg: ^game.Registry,
	s: ^Snapshot,
	light: ^Light_Snapshot,
	p: [3]i32,
	face: Face,
	axes: Face_Axes,
) -> (
	v: Face_Values,
) {
	solid :: #force_inline proc(t: ^game.Block_Table, s: ^Snapshot, p: [3]i32) -> int {
		return 1 if game.block_opaque(t, s[snapshot_index(p.x, p.y, p.z)]) else 0
	}
	front := p + axes.normal
	for corner, i in CORNERS {
		du := axes.u if corner[0] == 1 else -axes.u
		dv := axes.v if corner[1] == 1 else -axes.v
		side1, side2 := solid(&reg.blocks, s, front + du), solid(&reg.blocks, s, front + dv)
		corner_solid := solid(&reg.blocks, s, front + du + dv)
		level := 0 if side1 == 1 && side2 == 1 else 3 - side1 - side2 - corner_solid
		v.ao[i] = u32(level)
		sky, block := corner_light(light, front, du, dv, side1 == 1, side2 == 1, corner_solid == 1)
		emits := u32(game.block_light(&reg.blocks, s[snapshot_index(p.x, p.y, p.z)]))
		block = max(block, emits) // a light's own faces are as bright as it
		v.sky[i], v.block[i] = sky, block
	}
	return
}

// own_values: the values of a face inside a cell: open, lit as the cell is
// (and as bright as the block itself).
@(private = "file")
own_values :: proc(
	reg: ^game.Registry,
	s: ^Snapshot,
	light: ^Light_Snapshot,
	p: [3]i32,
	b: game.Block,
) -> (
	v: Face_Values,
) {
	sky, block := u32(15), u32(0)
	if light != nil {
		l := light[snapshot_index(p.x, p.y, p.z)]
		sky, block = u32(l >> 4), u32(l & 15)
	}
	block = max(block, u32(game.block_light(&reg.blocks, b)))
	for i in 0 ..< 4 {v.ao[i], v.sky[i], v.block[i] = 3, sky, block}
	return
}

// bilinear: the four corner values (CORNERS' order) at (u, v) in sixteenths
// of the face, rounded to the nearest level; at a corner, exactly its value.
@(private = "file")
bilinear :: #force_inline proc(c: [4]u32, u, v: i32) -> u32 {
	sum :=
		i32(c[0]) * (16 - u) * (16 - v) +
		i32(c[1]) * u * (16 - v) +
		i32(c[2]) * u * v +
		i32(c[3]) * (16 - u) * v
	return u32((sum + 128) / 256)
}

// emit_rect: the part uv_lo..uv_hi (in sixteenths, along the face's u and v
// axes) of the face of cell p, at `at` sixteenths along its normal axis (the
// positive face of a whole cube: 16, the negative face: 0), its corner values
// interpolated from the face's.
@(private = "file")
emit_rect :: proc(
	out: ^[dynamic]Vertex,
	values: Face_Values,
	face: Face,
	axes: Face_Axes,
	p: [3]i32,
	uv_lo, uv_hi: [2]i32,
	at: i32,
	layer: u32,
) {
	plane := p * SIXTEENTHS
	if axes.normal.x != 0 {plane.x += at}
	if axes.normal.y != 0 {plane.y += at}
	if axes.normal.z != 0 {plane.z += at}
	quad: [4]Vertex
	for corner, i in CORNERS {
		u := uv_hi[0] if corner[0] == 1 else uv_lo[0]
		v := uv_hi[1] if corner[1] == 1 else uv_lo[1]
		pos := plane + u * axes.u + v * axes.v
		quad[i] = make_vertex(
			pos,
			u32(face),
			bilinear(values.ao, u, v),
			bilinear(values.sky, u, v),
			bilinear(values.block, u, v),
			layer,
		)
	}
	if vertex_ao(quad[0]) + vertex_ao(quad[2]) < vertex_ao(quad[1]) + vertex_ao(quad[3]) {
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
// Positions are in sixteenths of a block.
vertex_position :: proc(v: Vertex) -> [3]i32 {
	return {i32(v.packed & 511), i32(v.packed >> 9 & 511), i32(v.packed >> 18 & 511)}
}

vertex_face :: proc(v: Vertex) -> Face {
	return Face(v.packed >> 27 & 7)
}

vertex_ao :: proc(v: Vertex) -> u32 {
	return v.packed >> 30 & 3
}

vertex_light :: proc(v: Vertex) -> (sky, block: u32) {
	return v.layer >> 12 & 15, v.layer >> 16 & 15
}
