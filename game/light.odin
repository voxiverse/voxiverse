package game

// Light: sky light (from above) and block light (from lamps), 0..15 each,
// packed in a u8 (sky << 4 | block). Light falls by one per block it
// travels, around corners too, and solid blocks stop it; under open sky
// (above the column's highest solid block) sky light is 15 at any depth.
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
	// Blocks, and seeds: lamps, and open sky.
	clear(&s.queue)
	for i in 0 ..< LIGHT_REGION_VOLUME {
		p := region_pos(i)
		c := input.chunks[(p.x / CHUNK_SIZE) + (p.y / CHUNK_SIZE) * 3 + (p.z / CHUNK_SIZE) * 9]
		b := chunk_get(c, p % CHUNK_SIZE)
		s.solid[i] = block_solid(b)
		light: u8 = block_light(b)
		ground := input.heights[p.x + p.z * LIGHT_REGION]
		if !s.solid[i] &&
		   (ground == NO_GROUND || region_origin.y + p.y > ground) {light |= LIGHT_MAX << 4}
		s.light[i] = light
	}
	// Only cells that can light a darker neighbour start the spread.
	for i in 0 ..< LIGHT_REGION_VOLUME {
		l := s.light[i]
		if l == 0 {continue}
		p := region_pos(i)
		for d in NEIGHBOURS {
			n := p + d
			if !in_region(n) {continue}
			j := region_index(n)
			if s.solid[j] {continue}
			if s.light[j] >> 4 < (l >> 4) - 1 || s.light[j] & 15 < (l & 15) - 1 {
				append(&s.queue, u32(i))
				break
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
