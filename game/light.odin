package game

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
		if c.array == nil {
			solid, light := block_opaque(c.uniform), block_light(c.uniform)
			for y in i32(0) ..< CHUNK_SIZE {
				for z in i32(0) ..< CHUNK_SIZE {
					row := region_index(base + {0, y, z})
					for x in 0 ..< CHUNK_SIZE {
						s.solid[row + x] = solid
						s.light[row + x] = light
						if light > 0 {append(&s.queue, u32(row + x))}
					}
				}
			}
			continue
		}
		for j in 0 ..< CHUNK_VOLUME {
			i := region_index(base + local_from_index(j))
			b := c.array[j]
			s.solid[i] = block_opaque(b)
			s.light[i] = block_light(b)
			if s.light[i] > 0 {append(&s.queue, u32(i))}
		}
	}
	// Open sky: everything above a column's top is air at full sky light.
	// Spreading sideways starts only where a column's sky meets a taller
	// neighbour's shade: from just above this top up to the neighbour's.
	for z in i32(0) ..< LIGHT_REGION {
		for x in i32(0) ..< LIGHT_REGION {
			first := sky_start(input, region_origin, x, z) // local y of the lowest sky cell
			for y in max(first, 0) ..< LIGHT_REGION {
				i := region_index({x, y, z})
				if !s.solid[i] {s.light[i] |= LIGHT_MAX << 4}
			}
			highest := first - 1
			// Seeping down into the top itself when it lets light through.
			if first - 1 >= 0 &&
			   first - 1 < LIGHT_REGION &&
			   !s.solid[region_index({x, first - 1, z})] {highest = max(highest, first)}
			for d in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
				nx, nz := x + d[0], z + d[1]
				if nx < 0 || nz < 0 || nx >= LIGHT_REGION || nz >= LIGHT_REGION {continue}
				highest = max(highest, sky_start(input, region_origin, nx, nz) - 1)
			}
			for y in max(first, 0) ..= min(highest, LIGHT_REGION - 1) {
				i := region_index({x, y, z})
				if !s.solid[i] {append(&s.queue, u32(i))}
			}
		}
	}
	// Breadth-first: each step lights neighbours one less, both channels.
	for head := 0; head < len(s.queue); head += 1 {
		i := int(s.queue[head])
		l := s.light[i]
		sky, block := l >> 4, l & 15
		p := region_pos(i)
		for d in NEIGHBOURS {
			n := p + d
			if !in_region(n) {continue}
			j := region_index(n)
			if s.solid[j] {continue}
			old := s.light[j]
			new_sky := max(old >> 4, sky - 1 if sky > 0 else 0)
			new_block := max(old & 15, block - 1 if block > 0 else 0)
			new := new_sky << 4 | new_block
			if new != old {
				s.light[j] = new
				append(&s.queue, u32(j))
			}
		}
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

// sky_start is the local y (in the region) of a column's lowest open-sky
// cell: just above its top.
@(private = "file")
sky_start :: #force_inline proc(input: ^Light_Input, region_origin: Block_Pos, x, z: i32) -> i32 {
	top := input.heights[x + z * LIGHT_REGION]
	if top == NO_GROUND {return -1}
	return clamp(top + 1 - region_origin.y, -1, LIGHT_REGION) // -1: all of it
}

@(private = "file", rodata)
NEIGHBOURS := [6][3]i32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}

@(private = "file")
region_index :: #force_inline proc(p: [3]i32) -> int {
	return int(p.x) + int(p.z) * LIGHT_REGION + int(p.y) * LIGHT_REGION * LIGHT_REGION
}

@(private = "file")
region_pos :: #force_inline proc(i: int) -> [3]i32 {
	return {
		i32(i % LIGHT_REGION),
		i32(i / (LIGHT_REGION * LIGHT_REGION)),
		i32(i / LIGHT_REGION % LIGHT_REGION),
	}
}

@(private = "file")
in_region :: #force_inline proc(p: [3]i32) -> bool {
	return(
		p.x >= 0 &&
		p.x < LIGHT_REGION &&
		p.y >= 0 &&
		p.y < LIGHT_REGION &&
		p.z >= 0 &&
		p.z < LIGHT_REGION \
	)
}
