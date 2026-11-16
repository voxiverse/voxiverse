package delve

import "common:base"

// A dungeon level, laid out from its seed and its depth: a grid of cells, a room in
// each, joined by corridors three blocks wide along a random tree of the grid (every
// room reaches every other) and a few more, for loops. The start room is a corner's;
// the boss's is the room the most corridors away from it. Plans only: x and z, in
// blocks from the dungeon's corner; the server part builds them (y 0 is the floor's
// level, WALL_HEIGHT blocks of air over it).

CELL :: 14 // blocks a side of a grid cell
MAX_GRID :: 7 // cells along x, at most (and along z)
MAX_ROOMS :: MAX_GRID * MAX_GRID
MAX_PASSAGES :: 2 * MAX_ROOMS
CORRIDOR :: 3 // blocks wide
WALL_HEIGHT :: 4
ROOM_MIN, ROOM_MAX :: 6, 11 // a room's sides, blocks

// Area: blocks lo ..= hi in x and z.
Area :: struct {
	lo, hi: [2]i32,
}

Room :: struct {
	area: Area,
	cell: [2]int,
}

// Passage: a corridor between two rooms (their indices), as its two legs.
Passage :: struct {
	a, b: int,
	legs: [2]Area,
}

Dungeon :: struct {
	seed:       u32,
	depth:      int,
	grid:       [2]int, // cells along x and z
	rooms:      [MAX_ROOMS]Room,
	room_count: int,
	passages:   [MAX_PASSAGES]Passage,
	pass_count: int,
	start:      int, // the room players come in at
	boss:       int, // the room the boss waits in, and the way down
}

// dungeon_grid: how many cells a dungeon of a depth spans: bigger the deeper.
dungeon_grid :: proc(depth: int) -> [2]int {
	n := clamp(3 + depth, 4, MAX_GRID)
	return {n, clamp(2 + depth, 3, MAX_GRID - 1)}
}

// dungeon_size: the dungeon's extent in blocks (x, z).
dungeon_size :: proc(d: ^Dungeon) -> [2]i32 {
	return {i32(d.grid.x * CELL), i32(d.grid.y * CELL)}
}

// dungeon_plan: the dungeon of a seed and depth.
dungeon_plan :: proc(d: ^Dungeon, seed: u32, depth: int) {
	d^ = {}
	d.seed, d.depth = seed, depth
	d.grid = dungeon_grid(depth)
	r := base.rng_make(u64(seed) ~ 0xde1fe ~ u64(depth) << 32)
	// A room in every cell, of a random size somewhere inside it.
	for z in 0 ..< d.grid.y {
		for x in 0 ..< d.grid.x {
			w := base.rng_int_range(&r, ROOM_MIN, ROOM_MAX + 1)
			h := base.rng_int_range(&r, ROOM_MIN, ROOM_MAX + 1)
			ox := x * CELL + 1 + base.rng_int_range(&r, 0, CELL - 1 - w)
			oz := z * CELL + 1 + base.rng_int_range(&r, 0, CELL - 1 - h)
			d.rooms[d.room_count] = {
				area = {{i32(ox), i32(oz)}, {i32(ox + w - 1), i32(oz + h - 1)}},
				cell = {x, z},
			}
			d.room_count += 1
		}
	}
	// A random tree over the grid (a walk that branches from where it has been), then
	// a few more passages between neighbours, for loops.
	joined: [MAX_ROOMS]bool
	frontier: [MAX_ROOMS]int
	n := 0
	d.start =
		[4]int{0, d.grid.x - 1, d.room_count - d.grid.x, d.room_count - 1}[base.rng_int_max(&r, 4)]
	joined[d.start] = true
	frontier[0], n = d.start, 1
	for n > 0 {
		at := base.rng_int_max(&r, n)
		room := frontier[at]
		free: [4]int
		count := 0
		for nb in neighbours(d, room) {
			if nb >= 0 && !joined[nb] {
				free[count] = nb
				count += 1
			}
		}
		if count == 0 {
			frontier[at] = frontier[n - 1]
			n -= 1
			continue
		}
		next := free[base.rng_int_max(&r, count)]
		joined[next] = true
		passage_add(d, room, next)
		frontier[n] = next
		n += 1
	}
	for _ in 0 ..< 1 + depth / 2 {
		a := base.rng_int_max(&r, d.room_count)
		b := neighbours(d, a)[base.rng_int_max(&r, 4)]
		if b >= 0 && !passage_between(d, a, b) {passage_add(d, a, b)}
	}
	d.boss = farthest(d, d.start)
}

// neighbours: the rooms of the cells beside a room's (-1: the grid's edge), +x, -x, +z, -z.
neighbours :: proc(d: ^Dungeon, room: int) -> (out: [4]int) {
	c := d.rooms[room].cell
	out = {-1, -1, -1, -1}
	if c.x + 1 < d.grid.x {out[0] = room + 1}
	if c.x > 0 {out[1] = room - 1}
	if c.y + 1 < d.grid.y {out[2] = room + d.grid.x}
	if c.y > 0 {out[3] = room - d.grid.x}
	return
}

passage_between :: proc(d: ^Dungeon, a, b: int) -> bool {
	for p in d.passages[:d.pass_count] {
		if (p.a == a && p.b == b) || (p.a == b && p.b == a) {return true}
	}
	return false
}

// passage_add: a corridor from a's middle to b's: along x, then along z.
@(private = "file")
passage_add :: proc(d: ^Dungeon, a, b: int) {
	if d.pass_count >= MAX_PASSAGES {return}
	ca, cb := room_middle(d.rooms[a].area), room_middle(d.rooms[b].area)
	half :: CORRIDOR / 2
	x_leg := Area{{min(ca.x, cb.x) - half, ca.y - half}, {max(ca.x, cb.x) + half, ca.y + half}}
	z_leg := Area{{cb.x - half, min(ca.y, cb.y) - half}, {cb.x + half, max(ca.y, cb.y) + half}}
	d.passages[d.pass_count] = {a, b, {x_leg, z_leg}}
	d.pass_count += 1
}

// room_middle: the block in the middle of an area (x, z).
room_middle :: proc(a: Area) -> [2]i32 {
	return {(a.lo.x + a.hi.x) / 2, (a.lo.y + a.hi.y) / 2}
}

// farthest: the room the most passages away from `from` (the lowest index of a tie).
farthest :: proc(d: ^Dungeon, from: int) -> int {
	steps: [MAX_ROOMS]int
	for &s in steps {s = -1}
	queue: [MAX_ROOMS]int
	head, tail := 0, 1
	queue[0], steps[from] = from, 0
	best := from
	for head < tail {
		room := queue[head]
		head += 1
		if steps[room] > steps[best] {best = room}
		for p in d.passages[:d.pass_count] {
			other := p.b if p.a == room else (p.a if p.b == room else -1)
			if other < 0 || steps[other] >= 0 {continue}
			steps[other] = steps[room] + 1
			queue[tail] = other
			tail += 1
		}
	}
	return best
}

// dungeon_open: whether the floor at x, z is open (in a room or a corridor).
dungeon_open :: proc(d: ^Dungeon, x, z: i32) -> bool {
	inside :: proc(a: Area, x, z: i32) -> bool {
		return x >= a.lo.x && x <= a.hi.x && z >= a.lo.y && z <= a.hi.y
	}
	for room in d.rooms[:d.room_count] {if inside(room.area, x, z) {return true}}
	for p in d.passages[:d.pass_count] {
		if inside(p.legs[0], x, z) || inside(p.legs[1], x, z) {return true}
	}
	return false
}
