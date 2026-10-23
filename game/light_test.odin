package game

import "core:testing"

// Test worlds are functions from position to block; heights are found by
// scanning down from TEST_TOP.
@(private = "file")
TEST_TOP :: 200

@(private = "file")
World_Fn :: proc(p: Block_Pos) -> Block

@(private = "file")
column_top :: proc(f: World_Fn, x, z: i32) -> i32 {
	for y := i32(TEST_TOP); y > -200; y -= 1 {
		if block_solid(f({x, y, z})) {return y}
	}
	return NO_GROUND
}

// light_of computes the light of chunk c the way meshing does.
@(private = "file")
light_of :: proc(f: World_Fn, c: Chunk_Pos, out: ^[LIGHT_OUT_VOLUME]u8) {
	chunks: [27]Chunk_Blocks
	arrays: Block_Arrays
	block_arrays_init(&arrays, 27)
	defer block_arrays_destroy(&arrays)
	input := new(Light_Input)
	defer free(input)
	input.origin = chunk_origin(c)
	for i in 0 ..< 27 {
		d := Chunk_Pos{i32(i % 3) - 1, i32(i / 3 % 3) - 1, i32(i / 9) - 1}
		o := chunk_origin(c + d)
		chunks[i].array, _ = block_arrays_take(&arrays)
		for j in 0 ..< CHUNK_VOLUME {chunks[i].array[j] = f(o + local_from_index(j))}
		input.chunks[i] = &chunks[i]
	}
	for z in i32(0) ..< LIGHT_REGION {
		for x in i32(0) ..< LIGHT_REGION {
			input.heights[x + z * LIGHT_REGION] = column_top(
				f,
				input.origin.x - CHUNK_SIZE + x,
				input.origin.z - CHUNK_SIZE + z,
			)
		}
	}
	scratch := new(Light_Scratch)
	defer {light_scratch_destroy(scratch); free(scratch)}
	light_chunk(input, scratch, out)
}

// reference_light floods a large box around chunk c (40 blocks of margin)
// with the plain rules and returns the light at p.
@(private = "file")
Reference :: struct {
	origin: Block_Pos,
	light:  []u8,
	size:   i32,
}

@(private = "file")
reference_build :: proc(f: World_Fn, c: Chunk_Pos) -> Reference {
	SIZE :: CHUNK_SIZE + 2 * 40
	r := Reference {
		origin = chunk_origin(c) - 40,
		light  = make([]u8, SIZE * SIZE * SIZE),
		size   = SIZE,
	}
	index :: proc(p: [3]i32) -> int {return int(p.x) + int(p.z) * SIZE + int(p.y) * SIZE * SIZE}
	solid := make([]bool, SIZE * SIZE * SIZE)
	defer delete(solid)
	tops := make([]i32, SIZE * SIZE)
	defer delete(tops)
	for z in i32(0) ..< SIZE {
		for x in i32(0) ..< SIZE {tops[x + z * SIZE] = column_top(f, r.origin.x + x, r.origin.z + z)}
	}
	queue: [dynamic][3]i32
	defer delete(queue)
	for y in i32(0) ..< SIZE {
		for z in i32(0) ..< SIZE {
			for x in i32(0) ..< SIZE {
				p := [3]i32{x, y, z}
				b := f(r.origin + p)
				i := index(p)
				solid[i] = block_solid(b)
				l := block_light(b)
				top := tops[x + z * SIZE]
				if !solid[i] && (top == NO_GROUND || r.origin.y + y > top) {l |= 15 << 4}
				r.light[i] = l
				if l != 0 {append(&queue, p)}
			}
		}
	}
	for head := 0; head < len(queue); head += 1 {
		p := queue[head]
		l := r.light[index(p)]
		for d in ([6][3]i32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
			n := p + d
			if n.x < 0 ||
			   n.y < 0 ||
			   n.z < 0 ||
			   n.x >= SIZE ||
			   n.y >= SIZE ||
			   n.z >= SIZE {continue}
			j := index(n)
			if solid[j] {continue}
			sky := max(r.light[j] >> 4, (l >> 4) - 1 if l >> 4 > 0 else 0)
			block := max(r.light[j] & 15, (l & 15) - 1 if l & 15 > 0 else 0)
			if sky << 4 | block != r.light[j] {
				r.light[j] = sky << 4 | block
				append(&queue, n)
			}
		}
	}
	return r
}

@(private = "file")
reference_at :: proc(r: Reference, p: Block_Pos) -> u8 {
	q := p - r.origin
	return r.light[int(q.x) + int(q.z) * int(r.size) + int(q.y) * int(r.size) * int(r.size)]
}

@(private = "file")
out_at :: proc(out: ^[LIGHT_OUT_VOLUME]u8, l: [3]i32) -> u8 {
	return out[int(l.x + 1) + int(l.z + 1) * LIGHT_OUT + int(l.y + 1) * LIGHT_OUT * LIGHT_OUT]
}

// Worlds to check: terrain with an overhang and a cave, lamps near chunk
// edges, a sealed room.
@(private = "file")
hilly :: proc(p: Block_Pos) -> Block {
	ground := i32(4 + (p.x * 7 + p.z * 3) % 5) // a little relief
	if p.x >= 20 {ground = -1} // a pit the tunnel opens into
	if p.y <= ground {
		// A tunnel under the surface along x, open to the sky at x > 20.
		if p.y >= 0 && p.y <= 2 && p.z >= 6 && p.z <= 8 && p.x < 20 {return .Air}
		return .Stone
	}
	// An overhang: a slab at y 12 over x 4..12, z 0..10.
	if p.y == 12 && p.x >= 4 && p.x <= 12 && p.z >= 0 && p.z <= 10 {return .Stone}
	return .Air
}

@(private = "file")
lamps :: proc(p: Block_Pos) -> Block {
	if p.y < 0 || p.y > 40 {return .Stone} 	// a cave system: roof keeps sky out
	if p == {15, 5, 15} || p == {-1, 20, 3} || p == {16, 30, 0} {return .Lamp}
	if p.x % 7 == 0 && p.z % 5 == 0 {return .Stone} 	// pillars
	return .Air
}

@(private = "file")
sealed :: proc(p: Block_Pos) -> Block {
	inside := p.x >= 2 && p.x <= 12 && p.y >= 2 && p.y <= 12 && p.z >= 2 && p.z <= 12
	if inside && p == {7, 7, 7} {return .Lamp}
	if inside {return .Air}
	if p.y > 30 {return .Air}
	return .Stone
}

@(test)
test_light_matches_reference :: proc(t: ^testing.T) {
	Case :: struct {
		name:  string,
		world: World_Fn,
		chunk: Chunk_Pos,
	}
	cases := []Case {
		{"hilly", hilly, {0, 0, 0}},
		{"hilly corner", hilly, {1, 0, 0}},
		{"lamps", lamps, {0, 1, 0}},
		{"lamps", lamps, {0, 0, 0}},
		{"sealed", sealed, {0, 0, 0}},
	}
	out := new([LIGHT_OUT_VOLUME]u8)
	defer free(out)
	for c in cases {
		light_of(c.world, c.chunk, out)
		ref := reference_build(c.world, c.chunk)
		defer delete(ref.light)
		mismatches := 0
		for y in i32(-1) ..= CHUNK_SIZE {
			for z in i32(-1) ..= CHUNK_SIZE {
				for x in i32(-1) ..= CHUNK_SIZE {
					want := reference_at(ref, chunk_origin(c.chunk) + {x, y, z})
					got := out_at(out, {x, y, z})
					if got != want {
						if mismatches <
						   3 {testing.expectf(t, false, "%s %v at %v: light %x, reference %x", c.name, c.chunk, [3]i32{x, y, z}, got, want)}
						mismatches += 1
					}
				}
			}
		}
		testing.expectf(t, mismatches == 0, "%s %v: %d cells differ", c.name, c.chunk, mismatches)
	}
}

@(test)
test_light_rules :: proc(t: ^testing.T) {
	out := new([LIGHT_OUT_VOLUME]u8)
	defer free(out)

	// Open sky: full sky light; in the tunnel, sky light fades from its mouth.
	light_of(hilly, {0, 0, 0}, out)
	testing.expect_value(t, out_at(out, {3, 15, 3}) >> 4, 15)
	under := out_at(out, {8, 11, 5}) >> 4 // under the overhang
	testing.expect(t, under > 0 && under < 15)
	deep := out_at(out, {5, 1, 7}) >> 4 // 15 blocks into the tunnel from x = 20
	mouth := out_at(out, {15, 1, 7}) >> 4
	testing.expect(t, deep < mouth)

	// A sealed room: no sky; a lamp lights by distance (Manhattan).
	light_of(sealed, {0, 0, 0}, out)
	testing.expect_value(t, out_at(out, {3, 3, 3}) >> 4, 0)
	testing.expect_value(t, out_at(out, {7, 8, 7}) & 15, 14)
	testing.expect_value(t, out_at(out, {7, 7, 10}) & 15, 12)
	testing.expect_value(t, out_at(out, {4, 4, 7}) & 15, 9)
	testing.expect_value(t, out_at(out, {7, 7, 7}) & 15, 15) // the lamp itself
	testing.expect_value(t, out_at(out, {1, 7, 7}), 0) // in the wall
}
