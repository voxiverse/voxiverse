package game

import "core:slice"

// The interest area: the chunks a client receives around the chunk it is
// in, a cylinder radius chunks across and height chunks above and below,
// walked nearest first. The server decides it and announces radius and
// height in Welcome; the client sizes its storage from them. Chunks are
// dropped only past a margin, so moving back and forth across a chunk border
// sends nothing again.

CLIENT_DROP_MARGIN :: 1 // the client drops chunks this far past the area
SERVER_UNLOAD_MARGIN :: 2 // the server frees them this far past it

MAX_VIEW_HEIGHT :: 16

in_interest :: #force_inline proc(d: Chunk_Pos, radius, height: i32) -> bool {
	return d.x * d.x + d.z * d.z <= radius * radius && abs(d.y) <= height
}

// interest_count is the number of chunks in the area.
interest_count :: proc(radius, height: i32) -> int {
	n := 0
	for z in -radius ..= radius {
		for x in -radius ..= radius {
			if x * x + z * z <= radius * radius {n += 1}
		}
	}
	return n * int(2 * height + 1)
}

// interest_offsets lists the area's chunk offsets, nearest first.
interest_offsets :: proc(radius, height: i32, allocator := context.allocator) -> []Chunk_Pos {
	out := make([dynamic]Chunk_Pos, 0, interest_count(radius, height), allocator)
	for y in -height ..= height {
		for z in -radius ..= radius {
			for x in -radius ..= radius {
				if in_interest({x, y, z}, radius, height) {append(&out, Chunk_Pos{x, y, z})}
			}
		}
	}
	slice.sort_by(out[:], proc(a, b: Chunk_Pos) -> bool {
		return a.x * a.x + a.y * a.y + a.z * a.z < b.x * b.x + b.y * b.y + b.z * b.z
	})
	return out[:]
}

// in_world: a chunk that exists (inside the height bounds and the limits
// the protocol can carry).
in_world :: proc(p: Chunk_Pos) -> bool {
	return(
		abs(p.x) < CHUNK_LIMIT &&
		abs(p.z) < CHUNK_LIMIT &&
		p.y >= CHUNK_MIN_Y &&
		p.y < CHUNK_MAX_Y \
	)
}

// interest_count_at counts the area's chunks around center that exist
// (fewer than interest_count near the top and bottom of the world).
interest_count_at :: proc(center: Chunk_Pos, radius, height: i32) -> int {
	n := 0
	for y in -height ..= height {
		if !in_world(center + {0, y, 0}) {continue}
		for z in -radius ..= radius {
			for x in -radius ..= radius {
				if x * x + z * z <= radius * radius && in_world(center + {x, y, z}) {n += 1}
			}
		}
	}
	return n
}
