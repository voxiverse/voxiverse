package mesh

import "core:testing"

import "../../game"

@(private = "file")
count_faces :: proc(out: []Vertex) -> (faces: [Face]int) {
	for i := 0; i < len(out); i += 4 {faces[vertex_face(out[i])] += 1}
	return
}

// quad_box: the low and high corners of a quad.
@(private = "file")
quad_box :: proc(q: []Vertex) -> (lo, hi: [3]i32) {
	lo, hi = vertex_position(q[0]), vertex_position(q[0])
	for v in q {
		p := vertex_position(v)
		lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
		hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
	}
	return
}

// face_area: block faces covered, by direction (a merged quad covers many).
@(private = "file")
face_area :: proc(out: []Vertex) -> (area: [Face]int) {
	for i := 0; i < len(out); i += 4 {
		lo, hi := quad_box(out[i:][:4])
		d := hi - lo
		area[vertex_face(out[i])] += int(max(d.x, 1) * max(d.y, 1) * max(d.z, 1))
	}
	return
}

@(private = "file")
total :: proc(a: [Face]int) -> (n: int) {
	for x in a {n += x}
	return
}

@(test)
test_single_block :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	out: [dynamic]Vertex
	defer delete(out)

	s[snapshot_index(3, 4, 5)] = .Stone
	mesh_chunk(s, nil, &out)
	testing.expect_value(t, len(out), 24)
	for n in count_faces(out[:]) {testing.expect_value(t, n, 1)}
	for v in out {
		testing.expect_value(t, vertex_ao(v), 3) // nothing around it
		p := vertex_position(v)
		testing.expect(t, p.x >= 3 && p.x <= 4 && p.y >= 4 && p.y <= 5 && p.z >= 5 && p.z <= 6)
	}
	// The top face lies in the plane y = 5, the bottom in y = 4.
	for i := 0; i < len(out); i += 4 {
		face := vertex_face(out[i])
		if face == .Pos_Y || face == .Neg_Y {
			want := i32(5) if face == .Pos_Y else 4
			for v in out[i:][:4] {testing.expect_value(t, vertex_position(v).y, want)}
		}
	}
}

@(test)
test_hidden_faces_and_border :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	out: [dynamic]Vertex
	defer delete(out)

	// Two touching blocks: the shared faces are hidden.
	s[snapshot_index(0, 0, 0)] = .Dirt
	s[snapshot_index(1, 0, 0)] = .Dirt
	mesh_chunk(s, nil, &out)
	testing.expect_value(t, total(face_area(out[:])), 10)

	// A block in the neighbour's border hides the face towards it, but is
	// not meshed itself.
	s[snapshot_index(-1, 0, 0)] = .Stone
	mesh_chunk(s, nil, &out)
	testing.expect_value(t, total(face_area(out[:])), 9)

	// All solid: nothing visible.
	for &b in s {b = .Stone}
	mesh_chunk(s, nil, &out)
	testing.expect_value(t, len(out), 0)
	// Open the border on top: exactly the top layer shows.
	for z in i32(-1) ..= 16 {
		for x in i32(-1) ..= 16 {s[snapshot_index(x, 16, z)] = .Air}
	}
	mesh_chunk(s, nil, &out)
	testing.expect_value(t, face_area(out[:])[.Pos_Y], 256)
	testing.expect_value(t, total(face_area(out[:])), 256)
	testing.expect_value(t, len(out), 4) // evenly lit: greedy meshing makes it one quad
	mesh_chunk(s, nil, &out, merge = false)
	testing.expect_value(t, len(out), 256 * 4)
}

// Greedy meshing changes nothing on screen: every block face of the merged
// mesh is in the unmerged one, drawn with the same texture, light and AO,
// and the other way round (merged quads are evenly lit: each block face
// in one is too). Over uneven ground, overhangs, plants and a lamp, lit.
@(test)
test_greedy_meshing_is_exact :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	light := new(Light_Snapshot)
	defer free(light)
	merged, plain: [dynamic]Vertex
	defer delete(merged)
	defer delete(plain)
	n := u32(7)
	for y in i32(-1) ..= 16 {
		for z in i32(-1) ..= 16 {
			for x in i32(-1) ..= 16 {
				n = n * 1664525 + 1013904223
				ground := 4 + (x / 5 + z / 3) % 4
				b := game.Block.Air
				if y <= ground {b = .Stone if y < ground else .Grass}
				if y == ground + 3 && n >> 28 == 0 {b = .Planks} 	// overhangs
				if y == ground + 1 && n >> 27 == 3 {b = .Tall_Grass}
				s[snapshot_index(x, y, z)] = b
				// Open sky above, dimmer below; a little lamp light here and there.
				sky := u8(15) if y > ground + 3 else u8(max(0, 12 - int(ground + 3 - y)))
				light[snapshot_index(x, y, z)] = sky << 4 | u8(n >> 30)
			}
		}
	}
	s[snapshot_index(8, 9, 8)] = .Lamp
	mesh_chunk(s, light, &merged)
	mesh_chunk(s, light, &plain, merge = false)
	testing.expect(t, len(merged) < len(plain), "nothing merged")
	Cell :: struct {
		face:   Face,
		at:     [3]i32,
		packed: u32, // with the position left out when evenly lit
		layer:  u32,
	}
	POSITION :: u32(1 << 15 - 1)
	cells :: proc(out: []Vertex, set: ^map[Cell]int) {
		for i := 0; i < len(out); i += 4 {
			q := out[i:][:4]
			face := vertex_face(q[0])
			alike := true
			for v in q {alike &&= v.packed &~ POSITION == q[0].packed &~ POSITION && v.layer == q[0].layer}
			if !alike || int(face) >= len(Face) {
				// Never merged: its corners as they are.
				for v in q {set[{face, vertex_position(v), v.packed, v.layer}] += 1}
				continue
			}
			// Evenly lit: one cell per block face it covers.
			lo, hi := quad_box(q)
			for y in lo.y ..= max(hi.y - 1, lo.y) {
				for z in lo.z ..= max(hi.z - 1, lo.z) {
					for x in lo.x ..= max(hi.x - 1, lo.x) {
						set[{face, {x, y, z}, q[0].packed &~ POSITION, q[0].layer}] += 1
					}
				}
			}
		}
	}
	a, b := make(map[Cell]int), make(map[Cell]int)
	defer delete(a)
	defer delete(b)
	cells(merged[:], &a)
	cells(plain[:], &b)
	testing.expect_value(t, len(a), len(b))
	for k, v in b {
		got, ok := a[k]
		if !testing.expectf(
			t,
			ok && got == v,
			"face %v at %v drawn differently once merged",
			k.face,
			k.at,
		) {break}
	}
}

@(test)
test_ambient_occlusion :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	out: [dynamic]Vertex
	defer delete(out)

	// A floor block with a wall block standing next to it on +x, one up:
	// the floor's top face darkens along its +x edge.
	s[snapshot_index(5, 5, 5)] = .Stone
	s[snapshot_index(6, 6, 5)] = .Stone
	mesh_chunk(s, nil, &out)
	found := false
	for i := 0; i < len(out); i += 4 {
		if vertex_face(out[i]) != .Pos_Y ||
		   vertex_position(out[i]).y != 6 ||
		   vertex_position(out[i]).x > 6 {continue}
		if vertex_position(out[i]).x < 5 {continue}
		// The floor block's top quad (x 5..6, y 6).
		all_in := true
		for v in out[i:][:4] {
			p := vertex_position(v)
			if p.x < 5 || p.x > 6 || p.z < 5 || p.z > 6 {all_in = false}
		}
		if !all_in {continue}
		found = true
		for v in out[i:][:4] {
			p := vertex_position(v)
			want := u32(2) if p.x == 6 else 3 // one side neighbour at the wall edge
			testing.expectf(
				t,
				vertex_ao(v) == want,
				"corner %v: ao %d, want %d",
				p,
				vertex_ao(v),
				want,
			)
		}
	}
	testing.expect(t, found, "floor top face not found")

	// In a corner between two walls the inner vertex is fully dark.
	clear(&out)
	for &b in s {b = .Air}
	s[snapshot_index(5, 5, 5)] = .Stone
	s[snapshot_index(6, 6, 5)] = .Stone
	s[snapshot_index(5, 6, 6)] = .Stone
	mesh_chunk(s, nil, &out)
	darkest := u32(3)
	for i := 0; i < len(out); i += 4 {
		if vertex_face(out[i]) != .Pos_Y {continue}
		for v in out[i:][:4] {
			if vertex_position(v) == {6, 6, 6} && vertex_position(out[i]).y == 6 {
				p0 := vertex_position(out[i])
				if p0.x >= 5 &&
				   p0.x <= 6 &&
				   p0.z >= 5 &&
				   p0.z <= 6 {darkest = min(darkest, vertex_ao(v))}
			}
		}
	}
	testing.expect_value(t, darkest, 0)
}

// The quad diagonal follows the AO: the split runs between the two corners
// whose AO sum is larger, so dark corners don't bleed across the quad.
@(test)
test_quad_split_follows_ao :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	out: [dynamic]Vertex
	defer delete(out)
	for config in 0 ..< 64 {
		for &b in s {b = .Air}
		s[snapshot_index(5, 5, 5)] = .Stone
		// Some of the 8 blocks around the top face's front layer.
		around := [8][2]i32{{-1, -1}, {0, -1}, {1, -1}, {1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}}
		for d, i in around {
			if (config * 37 + i * 11) % 3 == 0 {s[snapshot_index(5 + d[0], 6, 5 + d[1])] = .Stone}
		}
		mesh_chunk(s, nil, &out)
		for i := 0; i < len(out); i += 4 {
			q := out[i:][:4]
			if vertex_face(q[0]) != .Pos_Y || vertex_position(q[0]).y != 6 {continue}
			// Indices 0 1 2 0 2 3: the diagonal is q[0]-q[2].
			testing.expect(
				t,
				vertex_ao(q[0]) + vertex_ao(q[2]) >= vertex_ao(q[1]) + vertex_ao(q[3]),
			)
		}
	}
}

@(test)
test_snapshot_fill_uses_neighbours :: proc(t: ^testing.T) {
	arrays: game.Block_Arrays
	testing.expect(t, game.block_arrays_init(&arrays, 4) == nil)
	defer game.block_arrays_destroy(&arrays)

	chunks: [27]game.Chunk_Blocks
	n: Neighbourhood
	for &c, i in chunks {
		c.uniform = .Air
		n[i] = &c
	}
	n[neighbour_index({1, 0, 0})].uniform = .Stone
	n[neighbour_index({0, -1, 0})].uniform = .Dirt
	n[neighbour_index({-1, 1, -1})].uniform = .Sand
	centre := n[neighbour_index({0, 0, 0})]
	testing.expect(t, game.chunk_set(centre, &arrays, {15, 0, 0}, .Gravel) == nil)
	defer game.chunk_release(centre, &arrays)

	s := new(Snapshot)
	defer free(s)
	snapshot_fill(s, &n)
	testing.expect_value(t, s[snapshot_index(16, 3, 3)], game.Block.Stone)
	testing.expect_value(t, s[snapshot_index(3, -1, 3)], game.Block.Dirt)
	testing.expect_value(t, s[snapshot_index(-1, 16, -1)], game.Block.Sand)
	testing.expect_value(t, s[snapshot_index(15, 0, 0)], game.Block.Gravel)
	testing.expect_value(t, s[snapshot_index(3, 3, 3)], game.Block.Air)
	testing.expect_value(t, s[snapshot_index(16, 16, 16)], game.Block.Air)
}

@(test)
test_textures :: proc(t: ^testing.T) {
	// Each texture's alpha suits the layer of the blocks that use it:
	// opaque, cutout (fully there or not at all), translucent.
	layer_of: [Texture]Maybe(Layer)
	for b in game.Block {
		shape, layer := block_shape(b)
		if shape == .None {continue}
		side, top, bottom := block_faces(b)
		for tex in ([3]Texture{side, top, bottom}) {
			if l, seen := layer_of[tex].?; seen {
				testing.expectf(t, l == layer, "%v is used in two layers", tex)
			}
			layer_of[tex] = layer
		}
	}
	a, b: [TEXTURE_SIZE * TEXTURE_SIZE]Rgba
	for tex in Texture {
		generate_texture(tex, a[:])
		generate_texture(tex, b[:])
		testing.expect(t, a == b) // deterministic
		layer, used := layer_of[tex].?
		testing.expectf(t, used, "%v is used by no block", tex)
		lo, hi := 255, 0
		holes := 0
		for p in a {
			switch layer {
			case .Opaque:
				testing.expectf(t, p.a == 255, "%v: alpha %d", tex, p.a)
			case .Cutout:
				testing.expectf(t, p.a == 0 || p.a == 255, "%v: alpha %d", tex, p.a)
			case .Translucent:
				testing.expectf(t, p.a > 0 && p.a < 255, "%v: alpha %d", tex, p.a)
			}
			if p.a == 0 {
				holes += 1
				continue
			}
			lo, hi = min(lo, int(p.g)), max(hi, int(p.g))
		}
		testing.expectf(t, hi - lo > 10, "%v has no detail", tex) // not flat
		if layer == .Cutout {testing.expectf(t, holes > 0, "%v has no holes", tex)}
	}
	// Every block face has a texture of its own kind.
	testing.expect_value(t, block_texture(.Grass, .Pos_Y), u32(Texture.Grass_Top))
	testing.expect_value(t, block_texture(.Grass, .Neg_Y), u32(Texture.Dirt))
	testing.expect_value(t, block_texture(.Grass, .Pos_X), u32(Texture.Grass_Side))

	// Mips average in linear light: black and white average to mid grey in
	// light (188 in sRGB), not 128.
	src := [4]Rgba{{0, 0, 0, 255}, {255, 255, 255, 255}, {0, 0, 0, 255}, {255, 255, 255, 255}}
	dst: [1]Rgba
	generate_mip(src[:], 2, dst[:])
	testing.expect_value(t, dst[0], Rgba{188, 188, 188, 255})
}

@(test)
test_smooth_light :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	light := new(Light_Snapshot)
	defer free(light)
	out: [dynamic]Vertex
	defer delete(out)

	// A floor block with block light 12 above it, 4 to the +x side above.
	s[snapshot_index(5, 5, 5)] = .Stone
	for &l in light {l = 0}
	light[snapshot_index(5, 6, 5)] = 12
	light[snapshot_index(6, 6, 5)] = 4
	mesh_chunk(s, light, &out)
	for i := 0; i < len(out); i += 4 {
		if vertex_face(out[i]) != .Pos_Y {continue}
		for v in out[i:][:4] {
			_, block := vertex_light(v)
			p := vertex_position(v)
			// Corners on the +x edge average 12 and 4 (and dark cells).
			if p.x == 5 {testing.expectf(t, block < 12, "corner %v: %d", p, block)}
			testing.expect(t, block <= 12)
		}
	}
	// Without light: full sky.
	mesh_chunk(s, nil, &out)
	sky, block := vertex_light(out[0])
	testing.expect(t, sky == 15 && block == 0)
}

// Layers: stone, then a plant's crossed quads (both sides) in the cutout
// layer, then two water blocks side by side: no face between them, and
// their open tops marked as a surface; stone faces show through water.
@(test)
test_layers :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	out: [dynamic]Vertex
	defer delete(out)
	s[snapshot_index(1, 1, 1)] = .Stone
	s[snapshot_index(8, 8, 8)] = .Poppy
	s[snapshot_index(4, 1, 1)] = .Water
	s[snapshot_index(5, 1, 1)] = .Water
	s[snapshot_index(5, 0, 1)] = .Stone // under the second water block
	grouped := mesh_chunk(s, nil, &out)
	counts: [Layer]int
	for l in Layer {counts[l] = counts_layer(grouped, l)}
	testing.expect_value(t, counts[.Opaque], 2 * 24) // two stones (the one under water shows through it)
	testing.expect_value(t, counts[.Cutout], 16) // 2 planes x 2 sides x 4 corners
	testing.expect_value(t, counts[.Translucent], 4 * (10 - 1)) // 10 faces of two cubes, less the bottom on stone
	testing.expect_value(t, len(out), counts[.Opaque] + counts[.Cutout] + counts[.Translucent])
	// Quads by face group: the stones' faces in Face order, the plant's all crossed.
	testing.expect_value(t, grouped[.Opaque], [FACE_GROUPS]int{8, 8, 8, 8, 8, 8, 0})
	testing.expect_value(t, grouped[.Cutout][CROSS_GROUP], 16)
	at := 0
	for n, g in grouped[.Opaque] {
		for v in out[at:][:n] {testing.expect_value(t, int(vertex_face(v)), g)}
		at += n
	}
	plant := out[counts[.Opaque]:][:counts[.Cutout]]
	for v in plant {
		face := v.packed >> 15 & 7
		testing.expect(t, face == CROSS_A || face == CROSS_B)
		testing.expect_value(t, v.layer, u32(Texture.Poppy))
	}
	water := out[counts[.Opaque] + counts[.Cutout]:]
	for v in water {
		p := vertex_position(v)
		testing.expectf(t, (v.packed & SURFACE != 0) == (p.y == 2), "surface flag at %v", p)
	}
	// Water between the two: neither +x of the first nor -x of the second.
	for i := 0; i < len(water); i += 4 {
		face := vertex_face(water[i])
		x := vertex_position(water[i]).x
		testing.expect(t, !(face == .Pos_X && x == 5) && !(face == .Neg_X && x == 5))
	}
}
