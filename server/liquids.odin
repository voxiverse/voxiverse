package server

import "core:log"
import "core:mem"

import "../base"
import "../game"

// Liquids: water flows by Minecraft's rules, through scheduled block
// updates. Water levels are block ids (game.water_level): a source (0)
// stays; flowing water (1..7) lives as long as something feeds it (water
// above it, or beside it one level stronger), and spreads down first, else
// sideways one level weaker, towards the nearest way down within
// WATER_REACH blocks (every way, when there is none). Between two sources
// over firm ground a new source forms.
//
// Updates: a queue of (due tick, position), ordered by tick then position
// (the same edits give the same water on every run), at most one per
// position, at most UPDATE_BUDGET run per tick. Anything that changes a
// block wakes the water around it; an update whose chunk is not loaded is
// dropped, and a saved chunk's water wakes again when it loads.

MAX_UPDATES :: 1 << 16 // waiting at once (more are dropped, logged)
UPDATE_BUDGET :: 16384 // run per tick
WATER_DELAY :: game.TICK_RATE / 6 // ticks per step of flowing water
WATER_REACH :: 4 // blocks: how far flowing water looks for a way down

Update :: struct {
	due: u64,
	pos: game.Block_Pos,
}

Updates :: struct {
	heap:    []Update, // a binary heap by (due, pos), count used
	count:   int,
	queued:  map[game.Block_Pos]struct{}, // fixed: what is in the heap
	dropped: int, // full: logged once per run of drops
	run:     int, // updates run (stats)
}

updates_init :: proc(u: ^Updates, allocator := context.allocator) -> (err: mem.Allocator_Error) {
	u.heap = make([]Update, MAX_UPDATES, allocator) or_return
	u.queued = base.map_make_fixed(map[game.Block_Pos]struct{}, MAX_UPDATES, allocator) or_return
	return
}

// schedule wakes the block at p in delay ticks (unless already waiting).
schedule :: proc(s: ^Server, p: game.Block_Pos, delay: u64) {
	u := &s.updates
	if p in u.queued {return}
	if u.count == MAX_UPDATES {
		if u.dropped ==
		   0 {log.warnf("server block updates full (%d waiting): dropping", MAX_UPDATES)}
		u.dropped += 1
		return
	}
	u.queued[p] = {}
	u.heap[u.count] = {s.tick + delay, p}
	u.count += 1
	sift_up(u.heap[:u.count], u.count - 1)
}

// wake_water schedules p and its six neighbours if they are water.
wake_water :: proc(s: ^Server, p: game.Block_Pos) {
	for d in ([7]game.Block_Pos{{0, 0, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
		b, loaded := world_block(&s.world, p + d)
		if _, water := game.water_level(b); loaded && water {schedule(s, p + d, WATER_DELAY)}
	}
}

// wake_water_box schedules the water in lo..hi and around it that could
// change (after a bulk edit, a saved chunk loading, a new chunk next to
// water that was waiting for it: only_border, its faces' neighbours).
wake_water_box :: proc(s: ^Server, lo, hi: game.Block_Pos, only_border := false) {
	for y in lo.y - 1 ..= hi.y + 1 {
		for z in lo.z - 1 ..= hi.z + 1 {
			for x in lo.x - 1 ..= hi.x + 1 {
				inside :=
					x >= lo.x && x <= hi.x && y >= lo.y && y <= hi.y && z >= lo.z && z <= hi.z
				if only_border && inside {continue}
				if restless(s, {x, y, z}) {schedule(s, {x, y, z}, WATER_DELAY)}
			}
		}
	}
}

// restless: water at p that could change: flowing, or a source next to
// somewhere it could flow (still lakes and seas are left alone).
@(private = "file")
restless :: proc(s: ^Server, p: game.Block_Pos) -> bool {
	b, loaded := world_block(&s.world, p)
	level, water := game.water_level(b)
	if !loaded || !water {return false}
	if level != 0 {return true}
	for d in ([5]game.Block_Pos{{1, 0, 0}, {-1, 0, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
		nb, n_loaded := world_block(&s.world, p + d)
		if n_loaded && takes_water(nb, 7) {return true}
	}
	return false
}

// updates_run runs the updates due this tick (up to the budget).
updates_run :: proc(s: ^Server) {
	base.profile_scope("block updates")
	u := &s.updates
	if u.dropped > 0 && u.count < MAX_UPDATES / 2 {u.dropped = 0}
	for n := 0; n < UPDATE_BUDGET && u.count > 0 && u.heap[0].due <= s.tick; n += 1 {
		p := u.heap[0].pos
		u.count -= 1
		u.heap[0] = u.heap[u.count]
		sift_down(u.heap[:u.count], 0)
		delete_key(&u.queued, p)
		u.run += 1
		water_update(s, p)
	}
}

// water_update: the water at p takes the state its neighbours give it,
// then spreads.
@(private = "file")
water_update :: proc(s: ^Server, p: game.Block_Pos) {
	b, loaded := world_block(&s.world, p)
	level, water := game.water_level(b)
	if !loaded || !water {return}
	if level != 0 {
		want, alive := fed_level(s, p)
		if !alive {
			set_block(s, p, .Air)
			return
		}
		if want != level {
			set_block(s, p, game.water_block(want))
			level = want
		}
	}
	// Down first.
	below := p + {0, -1, 0}
	under, under_loaded := world_block(&s.world, below)
	if !under_loaded {return}
	if takes_water(under, game.WATER_FALLING_LEVEL) {
		set_block(s, below, .Water_Falling)
		return
	}
	// On firm ground (or on water), sideways, a level weaker.
	if _, on_water := game.water_level(under);
	   on_water && level != 0 && level != game.WATER_FALLING_LEVEL {return}
	next := i32(1) if level == 0 || level == game.WATER_FALLING_LEVEL else level + 1
	if next > 7 {return}
	ways := ways_down(s, p)
	for d, i in SIDES {
		if !ways[i] {continue}
		n := p + d
		nb, n_loaded := world_block(&s.world, n)
		if n_loaded && takes_water(nb, next) {set_block(s, n, game.water_block(next))}
	}
}

@(private = "file", rodata)
SIDES := [4]game.Block_Pos{{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}

// fed_level: the level flowing water at p should have, from what feeds it
// (false: nothing does; it dries up).
@(private = "file")
fed_level :: proc(s: ^Server, p: game.Block_Pos) -> (level: i32, alive: bool) {
	above, _ := world_block(&s.world, p + {0, 1, 0})
	if _, water := game.water_level(above); water {return game.WATER_FALLING_LEVEL, true}
	sources := 0
	best := i32(game.WATER_FALLING_LEVEL)
	for d in SIDES {
		nb, _ := world_block(&s.world, p + d)
		l, water := game.water_level(nb)
		if !water {continue}
		if l == 0 {sources += 1}
		if l == game.WATER_FALLING_LEVEL {
			// Falling water feeds what is beside it only where it lands.
			under, _ := world_block(&s.world, p + d + {0, -1, 0})
			if game.block_collides(under) {best = min(best, 0)}
			continue
		}
		best = min(best, l)
	}
	if sources >= 2 {
		// Between two sources over firm ground (or a source): a source.
		under, _ := world_block(&s.world, p + {0, -1, 0})
		if l, water := game.water_level(under);
		   game.block_collides(under) || (water && l == 0) {return 0, true}
	}
	if best >= 7 {return 0, false}
	return best + 1, true
}

// takes_water: water of level may flow into a block that is b: air, or
// what gives way (tall grass; flowers wash away), or weaker water.
@(private = "file")
takes_water :: proc(b: game.Block, level: i32) -> bool {
	if l, water := game.water_level(b); water {
		if l == 0 || l == game.WATER_FALLING_LEVEL {return false}
		return level == game.WATER_FALLING_LEVEL || level < l
	}
	info := game.BLOCK_INFO[b]
	return b == .Air || info.replaceable || (!info.collides && info.breakable)
}

// ways_down: which sides lead to the nearest way down within WATER_REACH
// (a block water can fall from); every side water can take when none do.
@(private = "file")
ways_down :: proc(s: ^Server, p: game.Block_Pos) -> (ways: [4]bool) {
	best := i32(WATER_REACH + 1)
	dist: [4]i32
	for d, i in SIDES {
		dist[i] = distance_down(s, p + d, d, 1)
		best = min(best, dist[i])
	}
	for d, i in SIDES {
		nb, _ := world_block(&s.world, p + d)
		ways[i] = takes_water(nb, 7) && (best > WATER_REACH || dist[i] == best)
	}
	return
}

// distance_down: steps from p (reached in steps) to a block water could
// fall from, going on in any direction but back (WATER_REACH + 1: none).
@(private = "file")
distance_down :: proc(s: ^Server, p, came: game.Block_Pos, steps: i32) -> i32 {
	b, loaded := world_block(&s.world, p)
	if !loaded || !takes_water(b, 7) {return WATER_REACH + 1}
	under, _ := world_block(&s.world, p + {0, -1, 0})
	if takes_water(under, game.WATER_FALLING_LEVEL) {return steps}
	if steps >= WATER_REACH {return WATER_REACH + 1}
	best := i32(WATER_REACH + 1)
	for d in SIDES {
		if d == -came {continue}
		best = min(best, distance_down(s, p + d, d, steps + 1))
	}
	return best
}

@(private = "file")
update_less :: #force_inline proc(a, b: Update) -> bool {
	if a.due != b.due {return a.due < b.due}
	if a.pos.y != b.pos.y {return a.pos.y < b.pos.y}
	if a.pos.z != b.pos.z {return a.pos.z < b.pos.z}
	return a.pos.x < b.pos.x
}

@(private = "file")
sift_up :: proc(h: []Update, i: int) {
	i := i
	for i > 0 {
		parent := (i - 1) / 2
		if !update_less(h[i], h[parent]) {return}
		h[i], h[parent] = h[parent], h[i]
		i = parent
	}
}

@(private = "file")
sift_down :: proc(h: []Update, i: int) {
	i := i
	for {
		l, r := 2 * i + 1, 2 * i + 2
		m := i
		if l < len(h) && update_less(h[l], h[m]) {m = l}
		if r < len(h) && update_less(h[r], h[m]) {m = r}
		if m == i {return}
		h[i], h[m] = h[m], h[i]
		i = m
	}
}
