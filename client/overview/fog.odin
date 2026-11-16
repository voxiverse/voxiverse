package overview

import "core:mem"

import "client:engine"

// The fog of war as a side's player sees it: over a game's map, the ground none of its own
// sees is darkened, and the ground none has ever seen darker still. What the server sends
// is already only what the side sees (server/core/sides.odin): this is the picture of it,
// from the entities the session knows of its side and their vision (their records).
//
// The map is cut in cells of FOG_CELL blocks; each cell's ground height is read once from
// the world as the session holds it (a few rows a frame, so a map loads into it without a
// hitch), and an unseen cell is one translucent quad on it: a 128-block map is at most
// 4 096 quads a frame.

FOG_CELL :: 2 // blocks a side of a cell
FOG_ROWS_A_FRAME :: 4 // rows of cells whose ground is read again each frame
NO_GROUND :: min(f32) // a cell whose ground is not read yet

Fog :: struct {
	lo, hi:   [2]i32, // the map's blocks (x, z), inclusive
	y_lo:     i32, // the heights its ground lies between
	y_hi:     i32,
	size:     [2]int, // cells
	seen:     []bool, // seen now
	explored: []bool, // ever seen
	height:   []f32, // the ground's top y in each cell (NO_GROUND: not read yet)
	next_row: int, // the next row whose ground is read
}

// fog_init: a fog over the map lo..hi (x, z) whose ground lies between y_lo and y_hi,
// its cells allocated (the session's arena, with the game's state).
fog_init :: proc(
	f: ^Fog,
	lo, hi: [2]i32,
	y_lo, y_hi: i32,
	allocator := context.allocator,
	loc := #caller_location,
) -> mem.Allocator_Error {
	f.lo, f.hi, f.y_lo, f.y_hi = lo, hi, y_lo, y_hi
	f.size = {int(hi.x - lo.x) / FOG_CELL + 1, int(hi.y - lo.y) / FOG_CELL + 1}
	n := f.size.x * f.size.y
	f.seen = make([]bool, n, allocator, loc) or_return
	f.explored = make([]bool, n, allocator, loc) or_return
	f.height = make([]f32, n, allocator, loc) or_return
	for &h in f.height {h = NO_GROUND}
	return nil
}

// fog_ready: the fog has its cells.
fog_ready :: proc(f: ^Fog) -> bool {return len(f.seen) > 0}

// fog_cell: the cell of a block column (false: off the map).
fog_cell :: proc(f: ^Fog, x, z: f64) -> (int, bool) {
	cx, cz := int((x - f64(f.lo.x)) / FOG_CELL), int((z - f64(f.lo.y)) / FOG_CELL)
	if x < f64(f.lo.x) || z < f64(f.lo.y) || cx >= f.size.x || cz >= f.size.y {return 0, false}
	return cz * f.size.x + cx, true
}

// fog_sees: the side sees the point now (on the map).
fog_sees :: proc(f: ^Fog, x, z: f64) -> bool {
	i, ok := fog_cell(f, x, z)
	return ok && f.seen[i]
}

// fog_explored: the side has seen the point (on the map).
fog_explored :: proc(f: ^Fog, x, z: f64) -> bool {
	i, ok := fog_cell(f, x, z)
	return ok && f.explored[i]
}

// fog_update: what the side sees this frame, from every entity of its team the session
// knows and its vision; what it sees is explored for good.
fog_update :: proc(f: ^Fog, s: ^engine.Session, team: u8) {
	if !fog_ready(f) {return}
	for &v in f.seen {v = false}
	for id, e in s.entities {
		if e.team != team || e.vision == 0 {continue}
		p := engine.entity_place(s, id) or_continue
		r := f64(e.vision)
		c0, _ := cell_clamped(f, p.x - r, p.z - r)
		c1, _ := cell_clamped(f, p.x + r, p.z + r)
		for cz in c0.y ..= c1.y {
			for cx in c0.x ..= c1.x {
				// (the cell's middle within the vision)
				mx := f64(f.lo.x) + (f64(cx) + 0.5) * FOG_CELL - p.x
				mz := f64(f.lo.y) + (f64(cz) + 0.5) * FOG_CELL - p.z
				if mx * mx + mz * mz > r * r {continue}
				i := cz * f.size.x + cx
				f.seen[i], f.explored[i] = true, true
			}
		}
	}
	// A few rows of the ground's heights, read again (blocks change; chunks arrive).
	for _ in 0 ..< FOG_ROWS_A_FRAME {
		cz := f.next_row
		f.next_row = (f.next_row + 1) % f.size.y
		for cx in 0 ..< f.size.x {
			x := f.lo.x + i32(cx * FOG_CELL)
			z := f.lo.y + i32(cz * FOG_CELL)
			if _, top, ok := engine.ground_top(s, x, z, f.y_lo, f.y_hi); ok {
				f.height[cz * f.size.x + cx] = f32(top)
			}
		}
	}
}

@(private = "file")
cell_clamped :: proc(f: ^Fog, x, z: f64) -> ([2]int, bool) {
	cx := clamp(int((x - f64(f.lo.x)) / FOG_CELL), 0, f.size.x - 1)
	cz := clamp(int((z - f64(f.lo.y)) / FOG_CELL), 0, f.size.y - 1)
	return {cx, cz}, true
}

// fog_draw: the ground the side does not see darkened (`unseen`), and the ground it never
// saw more so (`unexplored`): a quad a cell, on its ground.
fog_draw :: proc(f: ^Fog, s: ^engine.Session, unseen, unexplored: [4]u8) {
	if !fog_ready(f) {return}
	for cz in 0 ..< f.size.y {
		for cx in 0 ..< f.size.x {
			i := cz * f.size.x + cx
			if f.seen[i] || f.height[i] == NO_GROUND {continue}
			color := unseen if f.explored[i] else unexplored
			x0 := f64(f.lo.x) + f64(cx * FOG_CELL)
			z0 := f64(f.lo.y) + f64(cz * FOG_CELL)
			x1, z1 := x0 + FOG_CELL, z0 + FOG_CELL
			y := f64(f.height[i]) + 0.04
			if !engine.ground_quad(s, {x0, y, z0}, {x1, y, z0}, {x1, y, z1}, {x0, y, z1}, color) {
				return
			}
		}
	}
}
