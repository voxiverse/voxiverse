// The lazy contract (docs/world.md, "Lazy systems"): a system whose state lives everywhere
// (a town's market, a forest's growth) is never simulated outside an island. There a region's
// state is `lazy_evaluate`d from the world's history; when the region enters an island it
// becomes detailed from that state (`detail_enter`), is simulated (`detail_step`), and when it
// leaves, `detail_leave` records a Summary the next evaluation starts from.
//
// Influence travels at the system's finite speed: an evaluation sees an influence (an
// intervention, an event) only once it could have arrived, never one from the future or from
// beyond its light cone.
package island

import "common:game"

import "core:math"

// State is what a system keeps for one region (a system uses the slots it needs).
State :: [4]f64

// Summary is what a region was when it left detail, at `day`.
Summary :: struct {
	day:   f64,
	state: State,
}

// Influence is something that happened at `place` on `day` that a system may feel.
Influence :: struct {
	day:    f64,
	place:  [3]i32, // block position
	amount: f64, // what the system reads of it
}

// Lazy_System is one system's side of the contract. `user` is the system's own data.
Lazy_System :: struct {
	user:                 rawptr,
	speed_blocks_per_day: f64, // how fast its influence travels (> 0)
	// What the region is at `day`: from `from` (the region's last summary, or the value at
	// day 0 when it has none) and the influences already arrived (in order of arrival).
	lazy_evaluate:        proc(
		user: rawptr,
		region: Chunk,
		from: Summary,
		arrived: []Influence,
		day: f64,
	) -> State,
	detail_enter:         proc(user: rawptr, region: Chunk, state: State, day: f64),
	detail_step:          proc(user: rawptr, region: Chunk, dt: f64),
	detail_leave:         proc(user: rawptr, region: Chunk, day: f64) -> Summary,
}

// Lazy_World: a system with the regions that are detailed and the summaries of those that left.
Lazy_World :: struct {
	sys:       Lazy_System,
	detailed:  map[Chunk]struct{},
	summaries: map[Chunk]Summary,
}

lazy_destroy :: proc(w: ^Lazy_World) {
	delete(w.detailed)
	delete(w.summaries)
	w^ = {}
}

// region_center: the block position of a region's centre (its column's middle).
region_center :: proc(c: Chunk) -> [3]f64 {
	s := f64(game.CHUNK_SIZE)
	return {f64(c.x) * s + s / 2, 0, f64(c.z) * s + s / 2}
}

// arrival_day: when an influence reaches a region (never before it happened).
arrival_day :: proc(speed: f64, iv: Influence, region: Chunk) -> f64 {
	c := region_center(region)
	dx, dz := f64(iv.place.x) - c.x, f64(iv.place.z) - c.z
	return iv.day + math.sqrt(dx * dx + dz * dz) / speed
}

// lazy_state: the region's state at `day` without simulating it: from its summary if it
// has one, with the influences that arrived after the summary and by `day`.
// Inside detail the state is the simulation's, not this.
lazy_state :: proc(w: ^Lazy_World, region: Chunk, influences: []Influence, day: f64) -> State {
	assert(w.sys.speed_blocks_per_day > 0)
	from := w.summaries[region] or_else Summary{}
	arrived := make([dynamic]Influence, context.temp_allocator)
	for iv in influences {
		at := arrival_day(w.sys.speed_blocks_per_day, iv, region)
		if at > day || at < from.day {continue}
		append(&arrived, Influence{day = at, place = iv.place, amount = iv.amount})
	}
	// Order of arrival (insertion sort: few).
	for k in 1 ..< len(arrived) {
		for j := k; j > 0 && arrived[j].day < arrived[j - 1].day; j -= 1 {
			arrived[j], arrived[j - 1] = arrived[j - 1], arrived[j]
		}
	}
	return w.sys.lazy_evaluate(w.sys.user, region, from, arrived[:], day)
}

// lazy_sync: regions entered and left detail (an `Update_Result`'s lists) on `day`.
lazy_sync :: proc(w: ^Lazy_World, entered, left: []Chunk, influences: []Influence, day: f64) {
	for c in left {
		if c not_in w.detailed {continue}
		delete_key(&w.detailed, c)
		w.summaries[c] = w.sys.detail_leave(w.sys.user, c, day)
	}
	for c in entered {
		if c in w.detailed {continue}
		w.detailed[c] = {}
		w.sys.detail_enter(w.sys.user, c, lazy_state(w, c, influences, day), day)
	}
}

// lazy_step: one tick of simulation, for the detailed regions only. A world with none costs
// nothing.
lazy_step :: proc(w: ^Lazy_World, dt: f64) {
	for c in w.detailed {w.sys.detail_step(w.sys.user, c, dt)}
}
