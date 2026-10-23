package mesh

import "core:testing"

import "../../game"

@(private = "file")
count_faces :: proc(out: []Vertex) -> (faces: [Face]int) {
	for i := 0; i < len(out); i += 4 {faces[vertex_face(out[i])] += 1}
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
	testing.expect_value(t, len(out), 10 * 4)

	// A block in the neighbour's border hides the face towards it, but is
	// not meshed itself.
	s[snapshot_index(-1, 0, 0)] = .Stone
	mesh_chunk(s, nil, &out)
	testing.expect_value(t, len(out), 9 * 4)

	// All solid: nothing visible.
	for &b in s {b = .Stone}
	mesh_chunk(s, nil, &out)
	testing.expect_value(t, len(out), 0)
	// Open the border on top: exactly the top layer shows.
	for z in i32(-1) ..= 16 {
		for x in i32(-1) ..= 16 {s[snapshot_index(x, 16, z)] = .Air}
	}
	mesh_chunk(s, nil, &out)
	testing.expect_value(t, count_faces(out[:])[.Pos_Y], 256)
	testing.expect_value(t, len(out), 256 * 4)
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
	a, b: [TEXTURE_SIZE * TEXTURE_SIZE]Rgba
	for tex in Texture {
		generate_texture(tex, a[:])
		generate_texture(tex, b[:])
		testing.expect(t, a == b) // deterministic
		lo, hi := 255, 0
		for p in a {
			testing.expect_value(t, p.a, 255)
			lo, hi = min(lo, int(p.g)), max(hi, int(p.g))
		}
		testing.expectf(t, hi - lo > 10, "%v has no detail", tex) // not flat
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
