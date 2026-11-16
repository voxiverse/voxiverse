package hamlet_server

import "common:game"
import "games:hamlet"
import "server:core"

// The village on the map: its ground built from the seed, its tiles, its structures
// placed and taken down (each one bulk edit through the journal, credited to the
// game), its roads, and the ways along them.

// AREA: what the game keeps loaded and builds in (the map, a border, the hills' height).
AREA :: core.Box {
	{-2, hamlet.GROUND - 3, -2},
	{hamlet.MAP + 1, hamlet.GROUND + hamlet.MAX_HILL + 8, hamlet.MAP + 1},
}

// ground_build: the map's land in the world (hills, the pond, trees, rocks); false
// while its blocks are not all loaded.
ground_build :: proc(s: ^core.Server) -> bool {
	w := s.home
	t := state(s)
	if !core.world_ready(w, AREA) {return false}
	act := core.game_act(s, w, .Structure)
	g := &t.ground
	set :: proc(w: ^core.World, lo, hi: game.Block_Pos, b: game.Block, act: core.Act) {
		core.bulk_edit(w, {shape = core.Box{lo, hi}, op = .Set, block = b}, act)
	}
	ground :: hamlet.GROUND
	for z in i32(0) ..< hamlet.MAP {
		// Runs of the same height along the row: one edit each.
		x := i32(0)
		for x < hamlet.MAP {
			h := hamlet.ground_top(g, x, z)
			end := x
			for end + 1 < hamlet.MAP && hamlet.ground_top(g, end + 1, z) == h {end += 1}
			if h > ground {
				set(w, {x, ground, z}, {end, h - 1, z}, t.dirt, act)
				set(w, {x, h, z}, {end, h, z}, t.grass, act)
			}
			x = end + 1
		}
	}
	for z in i32(0) ..< hamlet.MAP {
		for x in i32(0) ..< hamlet.MAP {
			h := hamlet.ground_top(g, x, z)
			switch g.tiles[z][x] {
			case .Water:
				set(w, {x, ground - 1, z}, {x, ground, z}, t.water, act)
			case .Tree:
				set(w, {x - 1, h + 3, z - 1}, {x + 1, h + 4, z + 1}, t.leaves, act)
				set(w, {x, h + 5, z}, {x, h + 5, z}, t.leaves, act)
				set(w, {x, h + 1, z}, {x, h + 3, z}, t.log, act)
			case .Rock:
				set(w, {x, h, z}, {x, h + 1, z}, t.stone, act)
			case .Grass, .Road, .Zone, .House, .Building:
			}
		}
	}
	return true
}

// tile: what stands on tile (x, z) (Water off the map: nothing goes there).
tile :: proc(t: ^Town, x, z: i32) -> hamlet.Tile {
	return hamlet.tile_at(&t.tiles, x, z)
}

tile_set :: proc(t: ^Town, x, z: i32, v: hamlet.Tile, owner := -1) {
	t.tiles[z][x] = v
	t.owner[z][x] = i16(owner)
}

// structure_access: where a structure's people come and go.
structure_access :: proc(t: ^Town, i: int) -> ([2]i32, bool) {
	st := &t.structures[i]
	return hamlet.access(&t.tiles, st.at, hamlet.footprint(st.kind, st.rotation))
}

// center: a structure's middle tile.
center :: proc(st: ^Structure) -> [2]i32 {
	size := hamlet.footprint(st.kind, st.rotation)
	return st.at + size / 2
}

// within: tiles a and b are within reach (on the square).
within :: proc(a, b: [2]i32, reach: i32) -> bool {
	return abs(a.x - b.x) <= reach && abs(a.y - b.y) <= reach
}

// watered: a house's middle is within WELL_REACH of a well's.
watered :: proc(t: ^Town, i: int) -> bool {
	c := center(&t.structures[i])
	for &st in t.structures[:t.count] {
		if st.used && st.kind == .Well && within(center(&st), c, hamlet.WELL_REACH) {return true}
	}
	return false
}

// market_near: a house's middle is within MARKET_REACH of a market's.
market_near :: proc(t: ^Town, i: int) -> bool {
	c := center(&t.structures[i])
	for &st in t.structures[:t.count] {
		if st.used && st.kind == .Market && within(center(&st), c, hamlet.MARKET_REACH) {
			return true
		}
	}
	return false
}

// fit: why a structure may not go somewhere ("": it may): the map's rules
// (hamlet.placement), then whether the blocks there leave it room (core.structure_fit).
fit :: proc(
	s: ^core.Server,
	kind: hamlet.Kind,
	at: [2]i32,
	rotation: u8,
	allow: bit_set[hamlet.Tile],
) -> (
	floor: i32,
	refusal: string,
) {
	t := state(s)
	floor, refusal = hamlet.placement(&t.tiles, &t.ground, kind, at, rotation, allow)
	if refusal != "" {return}
	switch core.structure_fit(s.home, &t.templates[kind], {at.x, floor, at.y}, rotation, 1) {
	case .Fits:
	case .Not_Loaded:
		return 0, "That land is not loaded"
	case .Blocked:
		return 0, "Something is in the way"
	case .Uneven, .Out_Of_World:
		return 0, "The ground is too steep"
	}
	return floor, ""
}

// structure_add: kind built at `at` turned rotation on floor (its fit already judged):
// its blocks placed, its tiles taken; its index (-1: no room for another).
structure_add :: proc(
	s: ^core.Server,
	kind: hamlet.Kind,
	at: [2]i32,
	rotation: u8,
	floor: i32,
) -> int {
	t := state(s)
	i := -1
	for &st, k in t.structures[:t.count] {if !st.used {i = k; break}}
	if i < 0 {
		if t.count >= hamlet.MAX_STRUCTURES {return -1}
		i = t.count
		t.count += 1
	}
	t.structures[i] = {
		used     = true,
		kind     = kind,
		at       = at,
		rotation = rotation,
		floor    = floor,
	}
	act := core.game_act(s, s.home, .Structure)
	core.structure_place(s.home, &t.templates[kind], {at.x, floor, at.y}, rotation, act)
	size := hamlet.footprint(kind, rotation)
	for z in at.y ..< at.y + size.y {
		for x in at.x ..< at.x + size.x {
			tile_set(t, x, z, .House if kind == .House else .Building, i)
		}
	}
	return i
}

// structure_take: structure i goes: its blocks taken down, its tiles grass again, its
// people homeless (they leave) and its workers out of work.
structure_take :: proc(s: ^core.Server, i: int) {
	t := state(s)
	st := &t.structures[i]
	act := core.game_act(s, s.home, .Structure)
	core.structure_remove(
		s.home,
		&t.templates[st.kind],
		{st.at.x, st.floor, st.at.y},
		st.rotation,
		act,
	)
	size := hamlet.footprint(st.kind, st.rotation)
	for z in st.at.y ..< st.at.y + size.y {
		for x in st.at.x ..< st.at.x + size.x {tile_set(t, x, z, .Grass)}
	}
	for &c, k in t.citizens {
		if c.id == 0 {continue}
		if c.home == i {citizen_leave(s, k)} else if c.job == i {c.job = -1}
	}
	st^ = {}
}

// road_lay: the road tiles laid in the world (the ground's top block: gravel).
road_lay :: proc(s: ^core.Server, tiles: [][2]i32) {
	t := state(s)
	act := core.game_act(s, s.home, .Structure)
	for p in tiles {
		if t.tiles[p.y][p.x] == .Road {continue}
		tile_set(t, p.x, p.y, .Road)
		core.set_block(s.home, {p.x, hamlet.ground_top(&t.ground, p.x, p.y), p.y}, t.road, act)
	}
}

// road_take: a road tile is grass again.
road_take :: proc(s: ^core.Server, p: [2]i32) {
	t := state(s)
	act := core.game_act(s, s.home, .Structure)
	tile_set(t, p.x, p.y, .Grass)
	core.set_block(s.home, {p.x, hamlet.ground_top(&t.ground, p.x, p.y), p.y}, t.grass, act)
}

// way: the road tiles from one road tile to another (both ends), by a breadth-first
// search over the roads; false when they are not joined.
way :: proc(
	t: ^Town,
	from, to: [2]i32,
	allocator := context.temp_allocator,
) -> (
	tiles: [][2]i32,
	ok: bool,
) {
	if tile(t, from.x, from.y) != .Road || tile(t, to.x, to.y) != .Road {return}
	came := make([]i32, hamlet.MAP * hamlet.MAP, context.temp_allocator)
	for &c in came {c = -1}
	index :: proc(p: [2]i32) -> i32 {return p.y * hamlet.MAP + p.x}
	queue := make([dynamic][2]i32, 0, 256, context.temp_allocator)
	append(&queue, from)
	came[index(from)] = index(from)
	for i := 0; i < len(queue); i += 1 {
		p := queue[i]
		if p == to {break}
		for d in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			n := p + d
			if tile(t, n.x, n.y) != .Road || came[index(n)] >= 0 {continue}
			came[index(n)] = index(p)
			append(&queue, n)
		}
	}
	if came[index(to)] < 0 {return}
	back := make([dynamic][2]i32, allocator)
	for p := to; true; {
		append(&back, p)
		if p == from {break}
		k := came[index(p)]
		p = {k % hamlet.MAP, k / hamlet.MAP}
	}
	for a, b := 0, len(back) - 1; a < b; a, b = a + 1, b - 1 {back[a], back[b] = back[b], back[a]}
	return back[:], true
}
