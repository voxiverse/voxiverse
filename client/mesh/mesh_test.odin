package mesh

import "core:fmt"
import "core:strings"
import "core:testing"

import "../../common/game"

// bp: a vertex's position in blocks (the whole-cell quads of cubes lie on block boundaries).
@(private = "file")
bp :: proc(v: Vertex) -> [3]i32 {
	return vertex_position(v) / SIXTEENTHS
}

@(private = "file")
count_faces :: proc(out: []Vertex) -> (faces: [Face]int) {
	for i := 0; i < len(out); i += 4 {faces[vertex_face(out[i])] += 1}
	return
}

// quad_box: the low and high corners of a quad.
@(private = "file")
quad_box :: proc(q: []Vertex) -> (lo, hi: [3]i32) {
	lo, hi = bp(q[0]), bp(q[0])
	for v in q {
		p := bp(v)
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
	mesh_chunk(test_reg(), s, nil, &out)
	testing.expect_value(t, len(out), 24)
	for n in count_faces(out[:]) {testing.expect_value(t, n, 1)}
	for v in out {
		testing.expect_value(t, vertex_ao(v), 3) // nothing around it
		p := bp(v)
		testing.expect(t, p.x >= 3 && p.x <= 4 && p.y >= 4 && p.y <= 5 && p.z >= 5 && p.z <= 6)
	}
	// The top face lies in the plane y = 5, the bottom in y = 4.
	for i := 0; i < len(out); i += 4 {
		face := vertex_face(out[i])
		if face == .Pos_Y || face == .Neg_Y {
			want := i32(5) if face == .Pos_Y else 4
			for v in out[i:][:4] {testing.expect_value(t, bp(v).y, want)}
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
	mesh_chunk(test_reg(), s, nil, &out)
	testing.expect_value(t, total(face_area(out[:])), 10)

	// A block in the neighbour's border hides the face towards it, but is
	// not meshed itself.
	s[snapshot_index(-1, 0, 0)] = .Stone
	mesh_chunk(test_reg(), s, nil, &out)
	testing.expect_value(t, total(face_area(out[:])), 9)

	// All solid: nothing visible.
	for &b in s {b = .Stone}
	mesh_chunk(test_reg(), s, nil, &out)
	testing.expect_value(t, len(out), 0)
	// Open the border on top: exactly the top layer shows.
	for z in i32(-1) ..= 16 {
		for x in i32(-1) ..= 16 {s[snapshot_index(x, 16, z)] = .Air}
	}
	mesh_chunk(test_reg(), s, nil, &out)
	testing.expect_value(t, face_area(out[:])[.Pos_Y], 256)
	testing.expect_value(t, total(face_area(out[:])), 256)
	testing.expect_value(t, len(out), 4) // evenly lit: greedy meshing makes it one quad
	mesh_chunk(test_reg(), s, nil, &out, merge = false)
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
	mesh_chunk(test_reg(), s, light, &merged)
	mesh_chunk(test_reg(), s, light, &plain, merge = false)
	testing.expect(t, len(merged) < len(plain), "nothing merged")
	Cell :: struct {
		face:   Face,
		at:     [3]i32,
		packed: u32, // with the position left out when evenly lit
		layer:  u32,
	}
	POSITION :: POSITION_BITS
	cells :: proc(out: []Vertex, set: ^map[Cell]int) {
		for i := 0; i < len(out); i += 4 {
			q := out[i:][:4]
			face := vertex_face(q[0])
			alike := true
			for v in q {alike &&= v.packed &~ POSITION == q[0].packed &~ POSITION && v.layer == q[0].layer}
			if !alike || int(face) >= len(Face) {
				// Never merged: its corners as they are.
				for v in q {set[{face, bp(v), v.packed, v.layer}] += 1}
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
	mesh_chunk(test_reg(), s, nil, &out)
	found := false
	for i := 0; i < len(out); i += 4 {
		if vertex_face(out[i]) != .Pos_Y || bp(out[i]).y != 6 || bp(out[i]).x > 6 {continue}
		if bp(out[i]).x < 5 {continue}
		// The floor block's top quad (x 5..6, y 6).
		all_in := true
		for v in out[i:][:4] {
			p := bp(v)
			if p.x < 5 || p.x > 6 || p.z < 5 || p.z > 6 {all_in = false}
		}
		if !all_in {continue}
		found = true
		for v in out[i:][:4] {
			p := bp(v)
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
	mesh_chunk(test_reg(), s, nil, &out)
	darkest := u32(3)
	for i := 0; i < len(out); i += 4 {
		if vertex_face(out[i]) != .Pos_Y {continue}
		for v in out[i:][:4] {
			if bp(v) == {6, 6, 6} && bp(out[i]).y == 6 {
				p0 := bp(out[i])
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
		mesh_chunk(test_reg(), s, nil, &out)
		for i := 0; i < len(out); i += 4 {
			q := out[i:][:4]
			if vertex_face(q[0]) != .Pos_Y || bp(q[0]).y != 6 {continue}
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
	layer_of: [Texture_Generator]Maybe(Layer)
	for b in game.Block {
		shape, layer := frozen_block_shape(b)
		if shape == .None {continue}
		side, top, bottom := frozen_block_faces(b)
		for tex in ([3]Texture_Generator{side, top, bottom}) {
			if l, seen := layer_of[tex].?; seen {
				testing.expectf(t, l == layer, "%v is used in two layers", tex)
			}
			layer_of[tex] = layer
		}
	}
	layer_of[.Ladder] = .Cutout // (the base pack's ladder block, after the builtins)
	layer_of[.Door_Lower], layer_of[.Door_Upper] = .Opaque, .Opaque // (its door)
	a, b: [TEXTURE_SIZE * TEXTURE_SIZE]Rgba
	for tex in Texture_Generator {
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
	testing.expect_value(
		t,
		block_texture(test_reg(), .Grass, .Pos_Y),
		u32(Texture_Generator.Grass_Top),
	)
	testing.expect_value(t, block_texture(test_reg(), .Grass, .Neg_Y), u32(Texture_Generator.Dirt))
	testing.expect_value(
		t,
		block_texture(test_reg(), .Grass, .Pos_X),
		u32(Texture_Generator.Grass_Side),
	)

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
	mesh_chunk(test_reg(), s, light, &out)
	for i := 0; i < len(out); i += 4 {
		if vertex_face(out[i]) != .Pos_Y {continue}
		for v in out[i:][:4] {
			_, block := vertex_light(v)
			p := bp(v)
			// Corners on the +x edge average 12 and 4 (and dark cells).
			if p.x == 5 {testing.expectf(t, block < 12, "corner %v: %d", p, block)}
			testing.expect(t, block <= 12)
		}
	}
	// Without light: full sky.
	mesh_chunk(test_reg(), s, nil, &out)
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
	grouped := mesh_chunk(test_reg(), s, nil, &out)
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
		face := v.packed >> 27 & 7
		testing.expect(t, face == CROSS_A || face == CROSS_B)
		testing.expect_value(t, v.layer & LAYER_BITS, u32(Texture_Generator.Poppy))
	}
	water := out[counts[.Opaque] + counts[.Cutout]:]
	for v in water {
		p := bp(v)
		testing.expectf(t, (v.layer & SURFACE != 0) == (p.y == 2), "surface flag at %v", p)
	}
	// Water between the two: neither +x of the first nor -x of the second.
	for i := 0; i < len(water); i += 4 {
		face := vertex_face(water[i])
		x := bp(water[i]).x
		testing.expect(t, !(face == .Pos_X && x == 5) && !(face == .Neg_X && x == 5))
	}
}

// Farmland is a shape: its top at 15/16 of the block, its sides 15/16 high; the
// row of farmland hides its own neighbouring sides but not the stone's; beside
// stone, the stone's face is drawn (farmland's cover is not full).
@(test)
test_farmland_is_low :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	out: [dynamic]Vertex
	defer delete(out)
	for x in i32(3) ..= 5 {s[snapshot_index(x, 4, 5)] = .Farmland}
	s[snapshot_index(6, 4, 5)] = .Stone
	mesh_chunk(test_reg(), s, nil, &out)
	tops := 0
	for i := 0; i < len(out); i += 4 {
		q := out[i:][:4]
		face := vertex_face(q[0])
		is_farm := q[0].layer & LAYER_BITS == block_texture(test_reg(), .Farmland, face)
		if !is_farm {continue}
		for v in q {
			p := vertex_position(v)
			switch face {
			case .Pos_Y:
				testing.expect_value(t, p.y, 4 * 16 + 15)
			case .Neg_Y:
				testing.expect_value(t, p.y, 4 * 16)
			case .Pos_X, .Neg_X, .Pos_Z, .Neg_Z:
				testing.expect(t, p.y == 4 * 16 || p.y == 4 * 16 + 15)
			}
		}
		if face == .Pos_Y {tops += 1}
	}
	testing.expect_value(t, tops, 3) // (the shaped tops are not merged)
	// The stone's side towards the farmland is drawn; the farmlands' sides towards each other are not.
	stone_west, farm_east := 0, 0
	for i := 0; i < len(out); i += 4 {
		q := out[i:][:4]
		lo, _ := quad_box(q)
		is_stone := q[0].layer & LAYER_BITS == block_texture(test_reg(), .Stone, .Neg_X)
		if is_stone && vertex_face(q[0]) == .Neg_X && lo.x == 6 {stone_west += 1}
		if !is_stone && vertex_face(q[0]) == .Pos_X && lo.x == 6 {farm_east += 1}
	}
	testing.expect_value(t, stone_west, 1)
	testing.expect_value(t, farm_east, 0) // (the end of the row: the stone hides it)
}

// The base pack is the old look: every block's shape, layer and faces from
// the registry equal the tables in this package (and the generators are the
// registry's names).
@(test)
test_base_looks_the_same :: proc(t: ^testing.T) {
	reg := game.registry_base()
	defer game.registry_destroy(reg)
	testing.expect_value(t, len(game.TEXTURE_GENERATOR_NAMES), len(Texture_Generator))
	for name, i in game.TEXTURE_GENERATOR_NAMES {
		testing.expect_value(
			t,
			name,
			strings.to_lower(fmt.tprintf("%v", Texture_Generator(i)), context.temp_allocator),
		)
	}
	for b in game.Block {
		shape, layer := frozen_block_shape(b)
		def := reg.blocks.defs[b]
		want_render := game.Render_Kind.None
		switch shape {
		case .None:
			want_render = .None
		case .Cube:
			want_render = .Cube
		case .Cross:
			want_render = .Cross
		}
		testing.expectf(t, def.render == want_render, "%v render", b)
		if shape != .None {
			testing.expectf(t, int(def.layer) == int(layer), "%v layer", b)
			side, top, bottom := frozen_block_faces(b)
			testing.expectf(
				t,
				def.faces == {u32(side), u32(top), u32(bottom)},
				"%v faces %v",
				b,
				def.faces,
			)
		}
	}
}
