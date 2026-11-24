package sandbox_server

import "common:base"
import "common:game"

// A delve's layout: the keepers' complex under a stair head, laid out from the delve's own
// seed alone (delve_plan) and drawn into one template (delve_draw) that its site pastes as it
// is built (delve.odin). Three depths, one under the other, each a grid of DELVE_GRID by
// DELVE_GRID cells with a room in each, joined by corridors along a random tree of the grid,
// so every room reaches every other by one way. The first depth's landing lies under the
// stair head; each depth's descent, the room the most corridors from its landing, holds the
// spiral stair down to the next depth's landing straight under it; the third depth's is the
// boss's chamber, with its reward vault behind a ward. A leaf of the tree that is neither the
// landing nor the descent may be a vault behind a locked door (never on the way down: the
// tree has one way, and the way down does not pass a leaf). The other rooms are guard posts,
// store rooms, machine halls and collapsed rooms (DELVE_FILL).
//
// Every room and every corridor is shut in its own shell (walls, floor and ceiling), and the
// rock between is left as the world made it (the template's void), so nothing of the delve
// opens into a cave or water that runs through its box: the shell cuts it off
// (delve_sealed). Its rooms stand on one floor a depth, and the way from the stair head to
// the boss is walked, never jumped more than a block (delve_reaches).

DELVE_CELL :: 13 // blocks a side of a cell of a depth's grid
DELVE_GRID :: 3 // cells a side
DELVE_CELLS :: DELVE_GRID * DELVE_GRID
DELVE_SIDE :: DELVE_CELL * DELVE_GRID // the delve's columns a side
DELVE_DEPTHS :: 3
DELVE_STOREY :: 9 // blocks from one depth's floor to the next's
DELVE_DROP :: 16 // blocks from the stair head's floor to the first depth's
DELVE_AIR :: 4 // blocks of air in a room
DELVE_BOSS_AIR :: 6 // ... in the boss's chamber
DELVE_HALL_AIR :: 3 // ... in a corridor
DELVE_HEAD_AIR :: 5 // blocks the stair head stands over its floor
DELVE_SURFACE :: (DELVE_DEPTHS - 1) * DELVE_STOREY + DELVE_DROP // the stair head's floor (local)
DELVE_HEIGHT :: DELVE_SURFACE + DELVE_HEAD_AIR + 1 // the template's height
DELVE_MID :: DELVE_CELL / 2 // a cell's middle column (local to it): its corridors run along it
DELVE_HEAD :: 4 // the stair head's platform reaches this far from its middle

Dir :: enum u8 {
	North, // -z
	East, // +x
	South, // +z
	West, // -x
}

DIR_STEP :: [Dir][2]i32 {
	.North = {0, -1},
	.East  = {1, 0},
	.South = {0, 1},
	.West  = {-1, 0},
}

dir_back :: proc(d: Dir) -> Dir {return Dir((u8(d) + 2) % 4)}

Delve_Room_Kind :: enum u8 {
	Landing, // the foot of the stair from above
	Descent, // the head of the stair down
	Guard_Post,
	Store_Room,
	Machine_Hall,
	Collapsed,
	Vault, // behind a locked door
	Boss, // the third depth's descent: the boss's chamber and its reward vault
}

// DELVE_FILL: what the rooms that are neither landing, descent nor vault may be, each
// listed as often as it is likely.
DELVE_FILL :: [?]Delve_Room_Kind {
	.Guard_Post,
	.Guard_Post,
	.Store_Room,
	.Store_Room,
	.Machine_Hall,
	.Collapsed,
}

// Delve_Watch: the machines a room keeps, asleep at their posts.
Delve_Watch :: struct {
	scuttlers, spires, carapaces: int,
}

// DELVE_WATCH: what each kind of room keeps at each depth: more and heavier deeper.
@(rodata)
DELVE_WATCH := [Delve_Room_Kind][DELVE_DEPTHS]Delve_Watch {
	.Landing      = {{}, {}, {}},
	.Descent      = {{scuttlers = 1}, {scuttlers = 1}, {}},
	.Guard_Post   = {{scuttlers = 2}, {scuttlers = 2, spires = 1}, {scuttlers = 1, spires = 2}},
	.Store_Room   = {{scuttlers = 1}, {scuttlers = 2}, {scuttlers = 2, spires = 1}},
	.Machine_Hall = {{spires = 1}, {carapaces = 1}, {carapaces = 1, spires = 1}},
	.Collapsed    = {{scuttlers = 1}, {scuttlers = 2}, {scuttlers = 2, carapaces = 1}},
	.Vault        = {{spires = 1}, {spires = 1, carapaces = 1}, {spires = 1, carapaces = 1}},
	.Boss         = {{}, {}, {}},
}

// DELVE_TRAP_CHANCE: of a depth's corridors long enough, those with a trap across them (a
// trip plate, or from the second depth on, as likely a charged grating).
DELVE_TRAP_CHANCE :: [DELVE_DEPTHS]f32{0.35, 0.5, 0.6}
DELVE_LAMP_CHANCE :: 0.35 // of the rooms but landings, descents and the boss's, those with a lamp

// Delve_Room: a room of a depth: what it is, its inside's columns (delve-local, inclusive)
// and the ways its corridors leave it.
Delve_Room :: struct {
	kind:   Delve_Room_Kind,
	lo, hi: [2]i32,
	links:  bit_set[Dir],
}

// Delve_Depth: one depth: its floor's layer (local), its rooms by cell (x + z * DELVE_GRID),
// its landing's and its descent's cells, and its locked vault's (-1: none).
Delve_Depth :: struct {
	floor:       i32,
	rooms:       [DELVE_CELLS]Delve_Room,
	start, down: int,
	vault:       int,
}

// Delve_Plan: a delve's layout: its depths, the stair head's column (local), the side its
// boss's chamber is entered from, and the seed the rest is drawn from.
Delve_Plan :: struct {
	seed:      u64,
	depths:    [DELVE_DEPTHS]Delve_Depth,
	entry:     [2]i32,
	boss_from: Dir,
}

// delve_plan: the layout of the delve of a seed.
delve_plan :: proc(seed: u64) -> (p: Delve_Plan) {
	p.seed = seed
	rng := base.rng_make(seed ~ 0xde17_e5ee)
	start := base.rng_int_max(&rng, DELVE_CELLS)
	for &d, k in p.depths {
		d.floor = i32(DELVE_DEPTHS - 1 - k) * DELVE_STOREY
		d.start = start
		delve_tree(&d, &rng)
		d.down = delve_farthest(&d)
		d.vault = -1
		leaves: [DELVE_CELLS]int
		n := 0
		for room, i in d.rooms {
			if i != d.start && i != d.down && card(room.links) == 1 {
				leaves[n] = i
				n += 1
			}
		}
		if n > 0 {d.vault = leaves[base.rng_int_max(&rng, n)]}
		kinds := DELVE_FILL
		for &room, i in d.rooms {
			switch {
			case i == d.start:
				room.kind = .Landing
			case i == d.down && k == DELVE_DEPTHS - 1:
				room.kind = .Boss
			case i == d.down:
				room.kind = .Descent
			case i == d.vault:
				room.kind = .Vault
			case:
				room.kind = kinds[base.rng_int_max(&rng, len(kinds))]
			}
			cell := delve_cell(i)
			if room.kind == .Boss {
				for dir in room.links {p.boss_from = dir}
				room.lo, room.hi = boss_hall(cell, p.boss_from)
				continue
			}
			// The inside covers the cell's middle three columns each way (its corridors
			// come in along them) and the stair's five (landings and descents).
			origin := cell * DELVE_CELL
			room.lo = origin + {base.rng_roll(&rng, i32(2), 4), base.rng_roll(&rng, i32(2), 4)}
			room.hi = origin + {base.rng_roll(&rng, i32(8), 10), base.rng_roll(&rng, i32(8), 10)}
		}
		start = d.down
	}
	p.entry = delve_cell(p.depths[0].start) * DELVE_CELL + DELVE_MID
	return
}

// delve_cell: a cell's place in its grid from its index.
delve_cell :: proc(i: int) -> [2]i32 {return {i32(i % DELVE_GRID), i32(i / DELVE_GRID)}}

// delve_step: the cell beside i the way dir goes (false: off the grid).
delve_step :: proc(i: int, dir: Dir) -> (int, bool) {
	steps := DIR_STEP
	c := delve_cell(i) + steps[dir]
	if c.x < 0 || c.y < 0 || c.x >= DELVE_GRID || c.y >= DELVE_GRID {return 0, false}
	return int(c.x + c.y * DELVE_GRID), true
}

// delve_tree: corridors along a random tree of the grid from the depth's landing (a walk
// that turns off where it has not been and goes back when it cannot).
@(private = "file")
delve_tree :: proc(d: ^Delve_Depth, rng: ^base.Rng) {
	seen: [DELVE_CELLS]bool
	stack: [DELVE_CELLS]int
	stack[0], seen[d.start] = d.start, true
	n := 1
	for n > 0 {
		at := stack[n - 1]
		ways: [4]Dir
		k := 0
		for dir in Dir {
			if next, on := delve_step(at, dir); on && !seen[next] {
				ways[k] = dir
				k += 1
			}
		}
		if k == 0 {
			n -= 1
			continue
		}
		dir := ways[base.rng_int_max(rng, k)]
		next, _ := delve_step(at, dir)
		d.rooms[at].links += {dir}
		d.rooms[next].links += {dir_back(dir)}
		seen[next] = true
		stack[n] = next
		n += 1
	}
}

// delve_farthest: the room the most corridors from the landing (the first of them).
@(private = "file")
delve_farthest :: proc(d: ^Delve_Depth) -> int {
	far: [DELVE_CELLS]int
	for &f in far {f = -1}
	queue: [DELVE_CELLS]int
	queue[0], far[d.start] = d.start, 0
	head, tail := 0, 1
	best := d.start
	for head < tail {
		at := queue[head]
		head += 1
		if far[at] > far[best] {best = at}
		for dir in d.rooms[at].links {
			next, _ := delve_step(at, dir)
			if far[next] >= 0 {continue}
			far[next] = far[at] + 1
			queue[tail] = next
			tail += 1
		}
	}
	return best
}

// boss_place: a column of the boss's cell given across (u) and along (v, from the wall it is
// entered by) its cell, both 0..DELVE_CELL - 1, delve-local.
boss_place :: proc(cell: [2]i32, from: Dir, u, v: i32) -> [2]i32 {
	E :: DELVE_CELL - 1
	l: [2]i32
	switch from {
	case .North:
		l = {u, v}
	case .South:
		l = {u, E - v}
	case .West:
		l = {v, u}
	case .East:
		l = {E - v, u}
	}
	return cell * DELVE_CELL + l
}

// boss_box: the columns between two of boss_place's, lo..hi.
boss_box :: proc(cell: [2]i32, from: Dir, u0, v0, u1, v1: i32) -> (lo, hi: [2]i32) {
	a, b := boss_place(cell, from, u0, v0), boss_place(cell, from, u1, v1)
	return {min(a.x, b.x), min(a.y, b.y)}, {max(a.x, b.x), max(a.y, b.y)}
}

// The boss's chamber, along its cell from the wall it is entered by: its hall's inside
// (BOSS_HALL), the vault's inside behind it (BOSS_VAULT) and the ward between (BOSS_WARD,
// the hall's back wall), the boss's post in the hall's middle (BOSS_POST).
BOSS_HALL :: [4]i32{1, 1, DELVE_CELL - 2, 8} // u0, v0, u1, v1
BOSS_VAULT :: [4]i32{DELVE_MID - 1, 10, DELVE_MID + 1, 11}
BOSS_WARD_V :: 9
BOSS_POST :: [2]i32{DELVE_MID, 5}

boss_hall :: proc(cell: [2]i32, from: Dir) -> (lo, hi: [2]i32) {
	h := BOSS_HALL
	return boss_box(cell, from, h[0], h[1], h[2], h[3])
}

// delve_boss_cell: the third depth's descent, the boss's cell.
delve_boss_cell :: proc(p: ^Delve_Plan) -> [2]i32 {return delve_cell(
		p.depths[DELVE_DEPTHS - 1].down,
	)}

// delve_doorway: the cells of a room's wall where its corridor the way dir comes in (three
// wide on its cell's middle, its corridor's air high), delve-local.
delve_doorway :: proc(
	d: ^Delve_Depth,
	room: ^Delve_Room,
	cell: [2]i32,
	dir: Dir,
) -> (
	lo, hi: [3]i32,
) {
	c := cell * DELVE_CELL + DELVE_MID
	y0, y1 := d.floor + 1, d.floor + DELVE_HALL_AIR
	switch dir {
	case .North:
		return {c.x - 1, y0, room.lo.y - 1}, {c.x + 1, y1, room.lo.y - 1}
	case .South:
		return {c.x - 1, y0, room.hi.y + 1}, {c.x + 1, y1, room.hi.y + 1}
	case .West:
		return {room.lo.x - 1, y0, c.y - 1}, {room.lo.x - 1, y1, c.y + 1}
	case .East:
		return {room.hi.x + 1, y0, c.y - 1}, {room.hi.x + 1, y1, c.y + 1}
	}
	return
}

// Delve_Post: a machine of the delve and where it stands asleep (its feet, delve-local).
Delve_Post :: struct {
	which: Wild,
	at:    [3]i32,
}

MAX_DELVE_POSTS :: 64

// Delve_Kit: what a delve is built of, in this session's registry: the kit's stone and
// metal, the remains' finds, and the delve's own blocks (pack/data/blocks/delve.json).
Delve_Kit :: struct {
	slate_bricks, slate_tiles, slate_cobble:         game.Block,
	basalt_bricks, basalt_tiles, basalt_cobble:      game.Block,
	dark_bricks, polished_slate, mossy_bricks, moss: game.Block,
	steel, riveted, rust, copper, grating, rune:     game.Block,
	salvage_heap, alloy_relic, relic_vault:          game.Block,
	cache, door, plate, grid, ward:                  game.Block,
}

// Delve_Draft: a delve drawn: its blocks (temporary memory; void where the world stays as
// it is) and the machines it posts, the boss's apart.
Delve_Draft :: struct {
	t:          game.Template,
	posts:      [MAX_DELVE_POSTS]Delve_Post,
	post_count: int,
	boss:       [3]i32,
}

// delve_look: a depth's walls and floor: slate above, basalt below it, dark bricks at the
// bottom.
@(private = "file")
delve_look :: proc(k: ^Delve_Kit, depth: int) -> (wall, floor: game.Block) {
	switch depth {
	case 0:
		return k.slate_bricks, k.slate_tiles
	case 1:
		return k.basalt_bricks, k.basalt_tiles
	}
	return k.dark_bricks, k.polished_slate
}

// delve_draw: the plan's blocks and posts.
delve_draw :: proc(p: ^Delve_Plan, k: ^Delve_Kit) -> (dr: Delve_Draft) {
	dr.t = game.template_make({DELVE_SIDE, DELVE_HEIGHT, DELVE_SIDE}, context.temp_allocator)
	for &c in dr.t.cells {c = game.VOID}
	rng := base.rng_make(p.seed ~ 0x5ee1_d1a5)
	for &d, k_ in p.depths {draw_depth(&dr, p, &d, k_, k, &rng)}
	// The stairs: from the head down to the first landing, and each descent to the landing
	// under it.
	head_y := i32(DELVE_SURFACE)
	draw_shaft(&dr, k, p.entry, p.depths[0].floor, head_y, DELVE_AIR, k.slate_bricks)
	for k_ in 0 ..< DELVE_DEPTHS - 1 {
		upper, lower := &p.depths[k_], &p.depths[k_ + 1]
		middle := delve_cell(upper.down) * DELVE_CELL + DELVE_MID
		wall, _ := delve_look(k, k_ + 1)
		draw_shaft(&dr, k, middle, lower.floor, upper.floor, DELVE_AIR, wall)
	}
	draw_head(&dr, k, p.entry)
	// What each room holds and keeps, last: nothing drawn after takes its place.
	for &d, k_ in p.depths {
		for &room, i in d.rooms {draw_room(&dr, p, &d, &room, i, k_, k, &rng)}
	}
	return
}

// put: block at local p.
@(private = "file")
put :: proc(dr: ^Delve_Draft, p: [3]i32, b: game.Block) {
	t := &dr.t
	if p.x < 0 ||
	   p.y < 0 ||
	   p.z < 0 ||
	   p.x >= t.size.x ||
	   p.y >= t.size.y ||
	   p.z >= t.size.z {return}
	t.cells[game.template_index(t, p)] = u16(b)
}

// cell_at: what is drawn at local p (VOID outside the template too).
cell_at :: proc(t: ^game.Template, p: [3]i32) -> u16 {
	if p.x < 0 || p.y < 0 || p.z < 0 || p.x >= t.size.x || p.y >= t.size.y || p.z >= t.size.z {
		return game.VOID
	}
	return t.cells[game.template_index(t, p)]
}

@(private = "file")
fill :: proc(dr: ^Delve_Draft, lo, hi: [3]i32, b: game.Block) {game.template_fill(
		&dr.t,
		lo,
		hi,
		b,
	)}

@(private = "file")
post :: proc(dr: ^Delve_Draft, which: Wild, at: [3]i32) {
	if dr.post_count == MAX_DELVE_POSTS {return}
	dr.posts[dr.post_count] = {which, at}
	dr.post_count += 1
}

// Corridor: one of a depth's corridors, from room a's wall to room b's (east or south of
// it): its inside's box, delve-local.
@(private = "file")
corridor_box :: proc(d: ^Delve_Depth, a: int, dir: Dir) -> (lo, hi: [3]i32) {
	b, _ := delve_step(a, dir)
	ra, rb := &d.rooms[a], &d.rooms[b]
	c := delve_cell(a) * DELVE_CELL + DELVE_MID
	y0, y1 := d.floor + 1, d.floor + DELVE_HALL_AIR
	if dir == .East {return {ra.hi.x + 1, y0, c.y - 1}, {rb.lo.x - 1, y1, c.y + 1}}
	return {c.x - 1, y0, ra.hi.y + 1}, {c.x + 1, y1, rb.lo.y - 1} // (south)
}

// draw_depth: a depth's rooms and corridors, their shells, the moss on them and the traps in
// its corridors (what each room holds is drawn after the stairs: draw_room).
@(private = "file")
draw_depth :: proc(
	dr: ^Delve_Draft,
	p: ^Delve_Plan,
	d: ^Delve_Depth,
	depth: int,
	k: ^Delve_Kit,
	rng: ^base.Rng,
) {
	wall, floor := delve_look(k, depth)
	f := d.floor
	// The shells, then the insides (a corridor's air opens its doorways in the walls).
	for &room, i in d.rooms {
		air := i32(DELVE_BOSS_AIR if room.kind == .Boss else DELVE_AIR)
		fill(
			dr,
			{room.lo.x - 1, f, room.lo.y - 1},
			{room.hi.x + 1, f + air + 1, room.hi.y + 1},
			wall,
		)
		if room.kind == .Boss {
			v := BOSS_VAULT
			lo, hi := boss_box(delve_cell(i), p.boss_from, v[0] - 1, v[1] - 1, v[2] + 1, v[3] + 1)
			fill(dr, {lo.x, f, lo.y}, {hi.x, f + DELVE_HALL_AIR + 1, hi.y}, wall)
		}
		for dir in room.links {
			if dir != .East && dir != .South {continue}
			lo, hi := corridor_box(d, i, dir)
			fill(dr, lo - {1, 1, 1}, hi + {1, 1, 1}, wall)
		}
	}
	for &room, i in d.rooms {
		air := i32(DELVE_BOSS_AIR if room.kind == .Boss else DELVE_AIR)
		fill(dr, {room.lo.x, f + 1, room.lo.y}, {room.hi.x, f + air, room.hi.y}, .Air)
		fill(dr, {room.lo.x, f, room.lo.y}, {room.hi.x, f, room.hi.y}, floor)
		for dir in room.links {
			if dir != .East && dir != .South {continue}
			lo, hi := corridor_box(d, i, dir)
			fill(dr, lo, hi, .Air)
			draw_trap(dr, k, lo, hi, dir, depth, rng)
		}
	}
	// Moss and old patches on the walls and floors.
	for &room in d.rooms {
		for z in room.lo.y - 1 ..= room.hi.y + 1 {
			for x in room.lo.x - 1 ..= room.hi.x + 1 {
				r := base.rng_f32(rng)
				if r < 0.08 {
					if cell_at(&dr.t, {x, f, z}) == u16(floor) {put(dr, {x, f, z}, k.moss)}
				} else if r < 0.16 {
					for y in f + 1 ..= f + 2 {
						if cell_at(&dr.t, {x, y, z}) ==
						   u16(wall) {put(dr, {x, y, z}, k.mossy_bricks)}
					}
				}
			}
		}
	}
}

// draw_trap: across a corridor's middle, if it is long enough and the roll says so: a row of
// trip plates in its floor, or from the second depth two rows of charged grating (delve.odin
// springs them).
@(private = "file")
draw_trap :: proc(
	dr: ^Delve_Draft,
	k: ^Delve_Kit,
	lo, hi: [3]i32,
	dir: Dir,
	depth: int,
	rng: ^base.Rng,
) {
	chance := DELVE_TRAP_CHANCE
	along := 0 if dir == .East else 2
	length := hi[along] - lo[along] - 1 // (between its doorways)
	if length < 3 || base.rng_f32(rng) >= chance[depth] {return}
	mid := (lo[along] + hi[along]) / 2
	grid := depth > 0 && length >= 4 && base.rng_int_max(rng, 2) == 0
	rows := 2 if grid else 1
	for r in 0 ..< rows {
		a, b := lo, hi
		a[along], b[along] = mid + i32(r), mid + i32(r)
		a.y, b.y = lo.y - 1, lo.y - 1
		fill(dr, a, b, k.grid if grid else k.plate)
	}
}

// Slots: where in a room things stand: its four inside corners first, then a step in from
// each, a column apiece (what is drawn and posted there takes it).
@(private = "file")
Slots :: struct {
	at:   [8][2]i32,
	used: [8]bool,
}

@(private = "file")
slots_of :: proc(room: ^Delve_Room) -> (s: Slots) {
	lo, hi := room.lo, room.hi
	s.at = {
		{lo.x, lo.y},
		{hi.x, hi.y},
		{hi.x, lo.y},
		{lo.x, hi.y},
		{lo.x + 1, lo.y + 1},
		{hi.x - 1, hi.y - 1},
		{hi.x - 1, lo.y + 1},
		{lo.x + 1, hi.y - 1},
	}
	return
}

// slot_take: the first free slot from `from` on (false: none).
@(private = "file")
slot_take :: proc(s: ^Slots, from: int) -> ([2]i32, bool) {
	for i in from ..< len(s.at) {
		if s.used[i] {continue}
		s.used[i] = true
		return s.at[i], true
	}
	return {}, false
}

// on_way: a column of a room's cell that its corridors' line or a stair runs over (local to
// the cell 4..8 either way): nothing that stands in the way is drawn there.
@(private = "file")
on_way :: proc(c: [2]i32) -> bool {
	l := [2]i32{c.x %% DELVE_CELL, c.y %% DELVE_CELL}
	return(
		(l.x >= DELVE_MID - 2 && l.x <= DELVE_MID + 2) ||
		(l.y >= DELVE_MID - 2 && l.y <= DELVE_MID + 2) \
	)
}

// draw_room: what a room holds by its kind (its lamp, its finds, what stands in it) and the
// machines it keeps (DELVE_WATCH).
@(private = "file")
draw_room :: proc(
	dr: ^Delve_Draft,
	p: ^Delve_Plan,
	d: ^Delve_Depth,
	room: ^Delve_Room,
	i: int,
	depth: int,
	k: ^Delve_Kit,
	rng: ^base.Rng,
) {
	f := d.floor
	stand := f + 1
	ceiling := f + DELVE_AIR + 1
	middle := delve_cell(i) * DELVE_CELL + DELVE_MID
	slots := slots_of(room)
	if room.kind == .Boss {
		draw_boss(dr, p, d, room, i, k)
		return
	}
	switch room.kind {
	case .Landing:
		put(dr, {room.lo.x, ceiling, room.lo.y}, .Lamp)
	case .Descent:
	// (the stair's pillar is its lamp: draw_shaft)
	case .Guard_Post:
		// Crates of rusted iron in two corners.
		for _ in 0 ..< 2 {
			if c, ok := slot_take(&slots, 2); ok {put(dr, {c.x, stand, c.y}, k.rust)}
		}
	case .Store_Room:
		// Caches in the corners, salvage beside them.
		caches := base.rng_roll(rng, 2, 3)
		for _ in 0 ..< caches {
			if c, ok := slot_take(&slots, 0); ok {
				put(dr, {c.x, stand, c.y}, k.cache)
				beside := c + {1 if c.x == room.lo.x else -1, 0}
				if !on_way(beside) && base.rng_f32(rng) < 0.6 {
					put(dr, {beside.x, stand, beside.y}, k.salvage_heap)
					for a, j in slots.at {if a == beside {slots.used[j] = true}}
				}
			}
		}
	case .Machine_Hall:
		// Pillars of dark steel off the corridors' lines, copper conduits in the floor along
		// them, an alloy relic at one pillar's foot now and then.
		for s in 4 ..< 8 {
			c := slots.at[s]
			if on_way(c) {continue}
			slots.used[s] = true
			fill(dr, {c.x, stand, c.y}, {c.x, f + DELVE_AIR, c.y}, k.steel)
			if base.rng_f32(rng) < 0.25 {put(dr, {c.x, stand, c.y}, k.alloy_relic)}
		}
		for x in room.lo.x ..= room.hi.x {put(dr, {x, f, middle.y}, k.copper)}
		for z in room.lo.y ..= room.hi.y {put(dr, {middle.x, f, z}, k.copper)}
		put(dr, {middle.x, ceiling, middle.y}, k.rune)
	case .Collapsed:
		// The ceiling come down in heaps off the corridors' lines (the shell over it whole).
		for z in room.lo.y ..= room.hi.y {
			for x in room.lo.x ..= room.hi.x {
				if on_way({x, z}) {continue}
				r := base.rng_f32(rng)
				rubble := k.basalt_cobble if base.rng_int_max(rng, 2) == 0 else k.slate_cobble
				switch {
				case r < 0.12:
					fill(dr, {x, stand, z}, {x, stand + 1, z}, rubble)
				case r < 0.4:
					put(dr, {x, stand, z}, rubble if base.rng_int_max(rng, 3) > 0 else .Gravel)
				}
			}
		}
		for c, j in slots.at {slots.used[j] = !delve_open(&dr.t, {c.x, stand, c.y})}
	case .Vault:
		if c, ok := slot_take(&slots, 0); ok {put(dr, {c.x, stand, c.y}, k.relic_vault)}
		for _ in 0 ..< 2 {
			if c, ok := slot_take(&slots, 0); ok {put(dr, {c.x, stand, c.y}, k.cache)}
		}
		put(dr, {middle.x, ceiling, middle.y}, k.rune)
		for dir in room.links {
			lo, hi := delve_doorway(d, room, delve_cell(i), dir)
			fill(dr, lo, hi, k.door)
		}
	case .Boss:
	}
	if room.kind != .Landing &&
	   room.kind != .Descent &&
	   room.kind != .Vault &&
	   base.rng_f32(rng) < DELVE_LAMP_CHANCE {
		put(dr, {room.lo.x, ceiling, room.hi.y}, .Lamp)
	}
	watch := DELVE_WATCH[room.kind][depth]
	for _ in 0 ..< watch.spires {post_free(dr, &slots, 0, .Spire, stand)}
	for _ in 0 ..< watch.scuttlers {post_free(dr, &slots, 4, .Scuttler, stand)}
	for _ in 0 ..< watch.carapaces {
		for o in ([4][2]i32{{2, 2}, {-2, 2}, {2, -2}, {-2, -2}}) {
			at := [3]i32{middle.x + o.x, stand, middle.y + o.y}
			if delve_stands(&dr.t, at) {
				post(dr, .Carapace, at)
				break
			}
		}
	}
}

// post_free: a machine posted at the first free slot from `from` on (round again from the
// first) where it stands clear (none: it is left out).
@(private = "file")
post_free :: proc(dr: ^Delve_Draft, slots: ^Slots, from: int, which: Wild, stand: i32) {
	for k in 0 ..< len(slots.at) {
		i := (from + k) % len(slots.at)
		c := slots.at[i]
		if slots.used[i] || !delve_stands(&dr.t, {c.x, stand, c.y}) {continue}
		slots.used[i] = true
		post(dr, which, {c.x, stand, c.y})
		return
	}
}

// draw_boss: the boss's chamber: its hall (two pillars of riveted iron, lamps in the far
// corners, rune stones in the back wall), the ward that shuts its vault, the vault with two
// caches and a lamp; the boss's post in the middle of the hall.
@(private = "file")
draw_boss :: proc(
	dr: ^Delve_Draft,
	p: ^Delve_Plan,
	d: ^Delve_Depth,
	room: ^Delve_Room,
	i: int,
	k: ^Delve_Kit,
) {
	f := d.floor
	cell := delve_cell(i)
	from := p.boss_from
	at :: proc(cell: [2]i32, from: Dir, u, v, y: i32) -> [3]i32 {
		c := boss_place(cell, from, u, v)
		return {c.x, y, c.y}
	}
	v := BOSS_VAULT
	vlo, vhi := boss_box(cell, from, v[0], v[1], v[2], v[3])
	fill(dr, {vlo.x, f + 1, vlo.y}, {vhi.x, f + DELVE_HALL_AIR, vhi.y}, .Air)
	fill(dr, {vlo.x, f, vlo.y}, {vhi.x, f, vhi.y}, k.polished_slate)
	wlo, whi := boss_box(cell, from, v[0], BOSS_WARD_V, v[2], BOSS_WARD_V)
	fill(dr, {wlo.x, f + 1, wlo.y}, {whi.x, f + DELVE_HALL_AIR, whi.y}, k.ward)
	put(dr, at(cell, from, v[0], v[3], f + 1), k.cache)
	put(dr, at(cell, from, v[2], v[3], f + 1), k.cache)
	put(dr, at(cell, from, DELVE_MID, v[3], f + DELVE_HALL_AIR + 1), .Lamp)
	for u in ([2]i32{3, DELVE_CELL - 4}) {
		fill(dr, at(cell, from, u, 6, f + 1), at(cell, from, u, 6, f + DELVE_BOSS_AIR), k.riveted)
	}
	top := f + DELVE_BOSS_AIR + 1
	put(dr, at(cell, from, 1, 8, top), .Lamp)
	put(dr, at(cell, from, DELVE_CELL - 2, 8, top), .Lamp)
	for u in ([4]i32{2, 4, 8, 10}) {put(dr, at(cell, from, u, BOSS_WARD_V, f + 3), k.rune)}
	spot := BOSS_POST
	dr.boss = at(cell, from, spot.x, spot.y, f + 1)
}

// draw_shaft: a spiral stair in a shaft five blocks square whose corner is `middle` - 2, from
// the floor `bottom` (its room's, whose air is `air` high: the stair stands free in it) up
// through the floor `top`: walls of `wall` round it above the room below, a step a block
// higher every block round its pillar of dark steel (each a step up, never more), the
// pillar's top a lamp in the floor above, which is open over the stair.
@(private = "file")
draw_shaft :: proc(
	dr: ^Delve_Draft,
	k: ^Delve_Kit,
	middle: [2]i32,
	bottom, top, air: i32,
	wall: game.Block,
) {
	RING :: [8][2]i32{{1, 1}, {2, 1}, {3, 1}, {3, 2}, {3, 3}, {2, 3}, {1, 3}, {1, 2}}
	ring := RING
	corner := middle - 2
	for y in bottom + 1 ..= top {
		r := y - bottom
		for j in i32(0) ..< 5 {
			for i in i32(0) ..< 5 {
				p := [3]i32{corner.x + i, y, corner.y + j}
				if i == 0 || j == 0 || i == 4 || j == 4 {
					if y > bottom + air && y < top {put(dr, p, wall)}
					continue
				}
				if i == 2 && j == 2 {
					put(dr, p, .Lamp if y == top else k.steel)
					continue
				}
				b := game.Block.Air
				for q, n in ring {
					if q.x == i &&
					   q.y == j &&
					   r < top - bottom &&
					   (r - 1) % 8 == i32(n) {b = k.slate_cobble}
				}
				put(dr, p, b)
			}
		}
	}
}

// draw_head: the stair head on the land: a platform of slate tiles round the stair's
// opening, four posts of dark steel at its corners under a frame of riveted iron, the air
// over it clear.
@(private = "file")
draw_head :: proc(dr: ^Delve_Draft, k: ^Delve_Kit, middle: [2]i32) {
	y := i32(DELVE_SURFACE)
	R :: DELVE_HEAD
	for dz in i32(-R) ..= R {
		for dx in i32(-R) ..= R {
			c := middle + {dx, dz}
			for h in i32(1) ..= DELVE_HEAD_AIR {put(dr, {c.x, y + h, c.y}, .Air)}
			if abs(dx) <= 1 && abs(dz) <= 1 {continue} 	// (the opening: draw_shaft)
			put(
				dr,
				{c.x, y, c.y},
				k.polished_slate if abs(dx) == 2 || abs(dz) == 2 else k.slate_tiles,
			)
			if abs(dx) == 3 && abs(dz) == 3 {
				fill(dr, {c.x, y + 1, c.y}, {c.x, y + 3, c.y}, k.steel)
			}
			if (abs(dx) == 3 && abs(dz) <= 3) || (abs(dz) == 3 && abs(dx) <= 3) {
				put(dr, {c.x, y + 4, c.y}, k.riveted)
			}
		}
	}
}

// ---- what is checked of a drawing ----

// delve_open: a cell one walks through (air: everything a delve draws else is solid).
delve_open :: proc(t: ^game.Template, p: [3]i32) -> bool {return(
		cell_at(t, p) ==
		u16(game.Block.Air) \
	)}

// delve_stands: one can stand at p (feet): its feet and head in air, something under them.
delve_stands :: proc(t: ^game.Template, p: [3]i32) -> bool {
	under := cell_at(t, p - {0, 1, 0})
	return delve_open(t, p) && delve_open(t, p + {0, 1, 0}) && under != u16(game.Block.Air)
}

// delve_walk: every place one standing at `from` (feet, local) walks to: a step to a column
// beside at most a block up (a jump, with its head clear) or down as far as three; locked
// doors and wards in the way are solid. By template index (temporary memory).
delve_walk :: proc(t: ^game.Template, from: [3]i32) -> []bool {
	seen := make([]bool, len(t.cells), context.temp_allocator)
	if !delve_stands(t, from) {return seen}
	queue := make([dynamic][3]i32, context.temp_allocator)
	append(&queue, from)
	seen[game.template_index(t, from)] = true
	steps := DIR_STEP
	for head := 0; head < len(queue); head += 1 {
		at := queue[head]
		for s in steps {
			for dy in i32(-3) ..= 1 {
				next := at + {s.x, dy, s.y}
				if next.y < 0 || next.y >= t.size.y || !delve_stands(t, next) {continue}
				clear := true
				if dy == 1 {
					clear = delve_open(t, at + {0, 2, 0})
				} else {
					for y in next.y + 2 ..= at.y + 1 {clear &&= delve_open(t, {next.x, y, next.z})}
				}
				i := game.template_index(t, next)
				if !clear || seen[i] {continue}
				seen[i] = true
				append(&queue, next)
			}
		}
	}
	return seen
}

// delve_reaches: one standing at `from` walks to `to` (delve_walk).
delve_reaches :: proc(t: ^game.Template, from, to: [3]i32) -> bool {
	if to.x < 0 ||
	   to.y < 0 ||
	   to.z < 0 ||
	   to.x >= t.size.x ||
	   to.y >= t.size.y ||
	   to.z >= t.size.z {
		return false
	}
	return delve_walk(t, from)[game.template_index(t, to)]
}

// delve_sealed: no air the delve draws under its stair head's floor touches the template's
// void (the rock as the world made it, where a cave or water may run) or its edge: its shells
// are whole. The first open cell that does, and false.
delve_sealed :: proc(t: ^game.Template) -> (leak: [3]i32, sealed: bool) {
	NEXT :: [6][3]i32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	for y in i32(0) ..< DELVE_SURFACE {
		for z in i32(0) ..< t.size.z {
			for x in i32(0) ..< t.size.x {
				p := [3]i32{x, y, z}
				if !delve_open(t, p) {continue}
				for n in NEXT {
					q := p + n
					if q.y > DELVE_SURFACE {continue}
					if cell_at(t, q) == game.VOID {return p, false}
				}
			}
		}
	}
	return {}, true
}
