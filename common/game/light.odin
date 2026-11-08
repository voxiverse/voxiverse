package game

import "core:slice"

// Light: sky light (from above) and block light (from lamps), 0..15 each,
// packed in a u8 (sky << 4 | block). Light falls by one per block it
// travels, around corners too, and opaque blocks stop it; under open sky
// (above the column's top: its highest block that shades) sky light is 15
// at any depth. Water and leaves shade without stopping light: it seeps
// into them from the open sky above, one less per block.
//
// A chunk's light is computed whole, never patched: light travels at most
// 15 blocks, so the light of a chunk and the 1-block border its mesh needs
// depends only on the blocks within 16 blocks of the chunk: its 3x3x3
// neighbourhood (a 48-block cube) and the column heights there. Meshing
// computes it from that every time (on worker threads), so there is no
// stored light to go stale and nothing to undo when a light is removed:
// an edit re-meshes the chunks within 15 blocks of it.

LIGHT_MAX :: 15
LIGHT_REGION :: 3 * CHUNK_SIZE // the cube light is computed over
LIGHT_REGION_VOLUME :: LIGHT_REGION * LIGHT_REGION * LIGHT_REGION
LIGHT_OUT :: CHUNK_SIZE + 2 // the chunk and a 1-block border
LIGHT_OUT_VOLUME :: LIGHT_OUT * LIGHT_OUT * LIGHT_OUT

// NO_GROUND: a column with no solid block at all (open to the bottom).
NO_GROUND :: min(i32)

Light_Input :: struct {
	// The 3x3x3 chunks around the one being lit, by offset:
	// chunks[(dx + 1) + (dy + 1) * 3 + (dz + 1) * 9].
	chunks:  [27]^Chunk_Blocks,
	// The highest solid block's y in each of the 48x48 columns, x fastest,
	// from (centre origin - 16) on x and z; NO_GROUND for none.
	heights: [LIGHT_REGION * LIGHT_REGION]i32,
	origin:  Block_Pos, // the centre chunk's origin
	table:   ^Block_Table, // what the blocks are
}

// Light_Scratch is a worker's working memory (about 0.5 MiB; reuse it).
Light_Scratch :: struct {
	light: [LIGHT_REGION_VOLUME]u8,
	solid: [LIGHT_REGION_VOLUME]bool,
	queue: [dynamic]u32,
}

light_scratch_destroy :: proc(s: ^Light_Scratch) {
	delete(s.queue)
}

// light_chunk computes the light of the centre chunk and its border into
// out, indexed like the mesher's snapshot (-1..16 on each axis).
light_chunk :: proc(input: ^Light_Input, s: ^Light_Scratch, out: ^[LIGHT_OUT_VOLUME]u8) {
	region_origin := input.origin - CHUNK_SIZE
	clear(&s.queue)
	// Blocks, chunk by chunk (uniform chunks are one fill), and lamps.
	for ci in 0 ..< 27 {
		c := input.chunks[ci]
		base := [3]i32{i32(ci % 3), i32(ci / 3 % 3), i32(ci / 9)} * CHUNK_SIZE
		// Row by row: x runs along both layouts (the chunk's and the region's).
		if c.array == nil {
			solid, light :=
				block_opaque(input.table, c.uniform), block_light(input.table, c.uniform)
			for y in i32(0) ..< CHUNK_SIZE {
				for z in i32(0) ..< CHUNK_SIZE {
					row := region_index(base + {0, y, z})
					slice.fill(s.solid[row:][:CHUNK_SIZE], solid)
					slice.fill(s.light[row:][:CHUNK_SIZE], light)
					if light > 0 {
						for x in 0 ..< CHUNK_SIZE {append(&s.queue, u32(row + x))}
					}
				}
			}
			continue
		}
		for y in i32(0) ..< CHUNK_SIZE {
			for z in i32(0) ..< CHUNK_SIZE {
				row := region_index(base + {0, y, z})
				src := c.array[local_index({0, y, z}):][:CHUNK_SIZE]
				solid := s.solid[row:][:CHUNK_SIZE]
				light := s.light[row:][:CHUNK_SIZE]
				for b, x in src {
					solid[x] = block_opaque(input.table, b)
					emit := block_light(input.table, b)
					light[x] = emit
					if emit > 0 {append(&s.queue, u32(row + x))}
				}
			}
		}
	}
	// Open sky: everything above a column's top is air at full sky light.
	// Spreading sideways starts only where a column's sky meets a taller
	// neighbour's shade: from just above this top up to the neighbour's.
	LIGHT_PLANE :: LIGHT_REGION * LIGHT_REGION
	for z in i32(0) ..< LIGHT_REGION {
		for x in i32(0) ..< LIGHT_REGION {
			first := sky_start(input, region_origin, x, z) // local y of the lowest sky cell
			y0 := max(first, 0)
			xz := int(x) + int(z) * LIGHT_REGION
			sky_i := xz + int(y0) * LIGHT_PLANE
			for _ in y0 ..< LIGHT_REGION {
				if !s.solid[sky_i] {s.light[sky_i] |= LIGHT_MAX << 4}
				sky_i += LIGHT_PLANE
			}
			highest := first - 1
			// Seeping down into the top itself when it lets light through.
			if first - 1 >= 0 &&
			   first - 1 < LIGHT_REGION &&
			   !s.solid[xz + int(first - 1) * LIGHT_PLANE] {highest = max(highest, first)}
			for d in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
				nx, nz := x + d[0], z + d[1]
				if nx < 0 || nz < 0 || nx >= LIGHT_REGION || nz >= LIGHT_REGION {continue}
				highest = max(highest, sky_start(input, region_origin, nx, nz) - 1)
			}
			y_high := min(highest, LIGHT_REGION - 1)
			if y0 <= y_high {
				q_i := xz + int(y0) * LIGHT_PLANE
				for _ in y0 ..= y_high {
					if !s.solid[q_i] {append(&s.queue, u32(q_i))}
					q_i += LIGHT_PLANE
				}
			}
		}
	}
	// Breadth-first: each step lights neighbours one less, both channels.
	for head := 0; head < len(s.queue); head += 1 {
		i := int(s.queue[head])
		l := s.light[i]
		sky, block := l >> 4, l & 15
		if sky <= 1 && block <= 1 {continue}
		target_sky := sky - 1 if sky > 0 else 0
		target_block := block - 1 if block > 0 else 0

		y := i / LIGHT_PLANE
		rem := i - y * LIGHT_PLANE
		z := rem / LIGHT_REGION
		x := rem - z * LIGHT_REGION

		if x > 0 {step_neighbor(s, i - 1, target_sky, target_block)}
		if x < LIGHT_REGION - 1 {step_neighbor(s, i + 1, target_sky, target_block)}
		if z > 0 {step_neighbor(s, i - LIGHT_REGION, target_sky, target_block)}
		if z < LIGHT_REGION - 1 {step_neighbor(s, i + LIGHT_REGION, target_sky, target_block)}
		if y > 0 {step_neighbor(s, i - LIGHT_PLANE, target_sky, target_block)}
		if y < LIGHT_REGION - 1 {step_neighbor(s, i + LIGHT_PLANE, target_sky, target_block)}
	}
	// The centre chunk and its border.
	for y in 0 ..< LIGHT_OUT {
		for z in 0 ..< LIGHT_OUT {
			for x in 0 ..< LIGHT_OUT {
				p := [3]i32{i32(x), i32(y), i32(z)} + CHUNK_SIZE - 1
				out[x + z * LIGHT_OUT + y * LIGHT_OUT * LIGHT_OUT] = s.light[region_index(p)]
			}
		}
	}
}

@(private = "file")
step_neighbor :: #force_inline proc(s: ^Light_Scratch, j: int, target_sky, target_block: u8) {
	if s.solid[j] {return}
	old := s.light[j]
	old_sky, old_block := old >> 4, old & 15
	if old_sky >= target_sky && old_block >= target_block {return}
	new_sky := max(old_sky, target_sky)
	new_block := max(old_block, target_block)
	s.light[j] = new_sky << 4 | new_block
	append(&s.queue, u32(j))
}

// sky_start is the local y (in the region) of a column's lowest open-sky
// cell: just above its top.
@(private = "file")
sky_start :: #force_inline proc(input: ^Light_Input, region_origin: Block_Pos, x, z: i32) -> i32 {
	top := input.heights[x + z * LIGHT_REGION]
	if top == NO_GROUND {return -1}
	return clamp(top + 1 - region_origin.y, -1, LIGHT_REGION) // -1: all of it
}

@(private = "file")
region_index :: #force_inline proc(p: [3]i32) -> int {
	return int(p.x) + int(p.z) * LIGHT_REGION + int(p.y) * LIGHT_REGION * LIGHT_REGION
}
