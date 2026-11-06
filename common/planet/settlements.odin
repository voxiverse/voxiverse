package planet

import "base:runtime"
import "common:base"
import pq "core:container/priority_queue"
import "core:math"
import "core:slice"

// Settlements: what a planet's history implies on the ground, placed once someone arrives
// (docs/world.md, peoples). Settlements stand on the cells a people holds, the best first;
// roads join a people's settlements by the cheapest way over the relief; ruins mark cells
// a collapse emptied. All of it is computed from the history, never stored.

SETTLEMENT_PEOPLE :: 500.0 // a people has one settlement per sqrt(numbers / this)
RIVER_PULL :: 1.0 // how much a river adds to a cell's worth as a site
COAST_PULL :: 0.5 // and a coast
RUIN_MIN_POP :: 50 // a cell with fewer people than this leaves no ruin
CLIMB_M_PER_KM :: 50.0 // a road: climbing this many metres costs as much as one km

// Settlement is a place where a people live (`ruined` -1) or lived.
Settlement :: struct {
	cell:     int, // the climate cell
	lat, lon: f64,
	people:   int, // index in History.peoples
	size:     f32, // the people living there (at the ruin: when it fell)
	era:      int, // the people's era (the era in the people's index at the day)
	founded:  int, // year the cell came to the people
	ruined:   int, // year of the collapse that emptied it; -1 while it stands
}

// Road is the cheapest path between two of a people's settlements: climate cells in order.
Road :: struct {
	people: int,
	cells:  []int,
}

// Placement is a history's settlements and roads.
Placement :: struct {
	settlements: [dynamic]Settlement,
	roads:       [dynamic]Road,
}

placement_destroy :: proc(pl: ^Placement) {
	for r in pl.roads {delete(r.cells)}
	delete(pl.roads)
	delete(pl.settlements)
	pl^ = {}
}

// Settlement_Cache holds the placement of one world's history; asking again with the same
// history (same address, seed, interventions in force, decade) gives it back unchanged.
Settlement_Cache :: struct {
	valid:     bool,
	key:       u64,
	history:   History,
	placement: Placement,
}

settlement_cache_destroy :: proc(c: ^Settlement_Cache) {
	if c.valid {
		history_destroy(&c.history)
		placement_destroy(&c.placement)
	}
	c^ = {}
}

@(private = "file")
history_key :: proc(p: Planet, address, seed: u64, day: i64, ivs: []Intervention) -> u64 {
	steps := max(day, 0) / DAYS_PER_YEAR / HISTORY_STEP_YEARS
	x := mix64(mix64(address, seed), u64(steps))
	x = mix64(x, u64(p.land.width * 4096 + p.land.height))
	for iv in ivs {
		if iv.day > day {continue}
		x = mix64(x, u64(iv.day))
		x = mix64(x, transmute(u64)iv.lat)
		x = mix64(x, transmute(u64)iv.lon)
		x = mix64(x, u64(iv.kind))
	}
	// An intervention in the decade not yet run is in the history only from its day.
	if len(ivs) > 0 {x = mix64(x, u64(day))}
	return x
}

// settlements_at is the settlements of a world at `day`, standing and ruined, cached:
// recomputed only when the history changes (a new decade or an intervention). The slice is
// the cache's and is valid until the next call.
settlements_at :: proc(
	c: ^Settlement_Cache,
	p: Planet,
	address, seed: u64,
	day: i64,
	interventions: []Intervention,
) -> []Settlement {
	placement_at(c, p, address, seed, day, interventions)
	return c.placement.settlements[:]
}

// roads_at is the roads of the same placement.
roads_at :: proc(
	c: ^Settlement_Cache,
	p: Planet,
	address, seed: u64,
	day: i64,
	interventions: []Intervention,
) -> []Road {
	placement_at(c, p, address, seed, day, interventions)
	return c.placement.roads[:]
}

@(private = "file")
placement_at :: proc(
	c: ^Settlement_Cache,
	p: Planet,
	address, seed: u64,
	day: i64,
	interventions: []Intervention,
) {
	key := history_key(p, address, seed, day, interventions)
	if c.valid && c.key == key {return}
	settlement_cache_destroy(c)
	c.history = history(p, address, seed, day, interventions)
	c.placement = place(p, c.history)
	c.key, c.valid = key, true
}

// place puts the settlements, roads and ruins of a history on its planet.
place :: proc(p: Planet, h: History, allocator := context.allocator) -> Placement {
	pl := Placement {
		settlements = make([dynamic]Settlement, allocator),
		roads       = make([dynamic]Road, allocator),
	}
	g := ground_build(p, context.temp_allocator)
	w := h.width
	sc := scratch_make(len(h.owner))
	site :: proc(p: Planet, g: Ground, w, k: int) -> f64 {
		coast := false
		i, j := k % w, k / w
		for dj in -1 ..= 1 {
			jj := j + dj
			if jj < 0 || jj >= len(p.land.is_land) / w {continue}
			for di in -1 ..= 1 {
				if !p.land.is_land[jj * w + (i + di + w) % w] {coast = true}
			}
		}
		pull := 1 + RIVER_PULL * f64(g.river[k]) + (COAST_PULL if coast else 0)
		return f64(g.capacity[k]) * pull
	}

	// Standing settlements: each people's best cells, as many as their numbers call for.
	for pe, who in h.peoples {
		cells := make([dynamic]int, context.temp_allocator)
		for k in 0 ..< len(h.owner) {
			if int(h.owner[k]) == who + 1 {append(&cells, k)}
		}
		if len(cells) == 0 {continue}
		ranked := make([]Ranked, len(cells), context.temp_allocator)
		for k, i in cells {ranked[i] = Ranked{k, site(p, g, w, k)}}
		slice.sort_by(ranked, proc(a, b: Ranked) -> bool {
			return a.score > b.score || (a.score == b.score && a.cell < b.cell)
		})
		count := clamp(int(math.sqrt(pe.population / SETTLEMENT_PEOPLE)), 1, len(cells))
		first := len(pl.settlements)
		for r in ranked[:count] {
			append(
				&pl.settlements,
				settlement_at(h, r.cell, who, pe.era, -1, int(h.since[r.cell]), h.pop[r.cell]),
			)
		}
		join_by_roads(&pl, p, &sc, who, first, len(pl.settlements), allocator)
	}

	// Ruins: cells a collapse emptied and nobody holds now (the last collapse of a cell).
	for k, i in h.ruins {
		if h.owner[k] != 0 {continue}
		info := h.ruin_info[i]
		if info.pop < RUIN_MIN_POP {continue}
		later := false
		for j in i + 1 ..< len(h.ruins) {
			if h.ruins[j] == k {later = true}
		}
		if later {continue}
		append(
			&pl.settlements,
			settlement_at(
				h,
				k,
				info.people,
				h.peoples[info.people].era,
				info.year,
				info.founded,
				info.pop,
			),
		)
	}
	return pl
}

@(private = "file")
Ranked :: struct {
	cell:  int,
	score: f64,
}

@(private = "file")
settlement_at :: proc(h: History, k, who, era, ruined, founded: int, size: f32) -> Settlement {
	return Settlement {
		cell = k,
		lat = climate_lat(h.height, k / h.width),
		lon = (f64(k % h.width) + 0.5) * 360 / f64(h.width) - 180,
		people = who,
		size = size,
		era = era,
		founded = founded,
		ruined = ruined,
	}
}

// join_by_roads links settlements [from, to) of one people into a tree, each to the nearest
// one already linked, by the cheapest path.
@(private = "file")
join_by_roads :: proc(
	pl: ^Placement,
	p: Planet,
	sc: ^Scratch,
	who, from, to: int,
	allocator: runtime.Allocator,
) {
	w := p.land.width
	linked := make([dynamic]int, context.temp_allocator)
	for i in from ..< to {
		cell := pl.settlements[i].cell
		if len(linked) > 0 {
			near, nd := -1, max(int)
			for o in linked {
				di := abs(o % w - cell % w)
				di = min(di, w - di)
				d := di * di + (o / w - cell / w) * (o / w - cell / w)
				if d < nd {near, nd = o, d}
			}
			path := cheapest_path(p, sc, near, cell, allocator)
			if path != nil {append(&pl.roads, Road{people = who, cells = path})}
		}
		append(&linked, cell)
	}
}

@(private = "file")
Node :: struct {
	cost: f32, // the way so far plus the least way left
	cell: int,
}

// Scratch is the path search's memory, kept between searches: only touched cells are reset.
@(private = "file")
Scratch :: struct {
	dist:    []f32,
	prev:    []i32,
	touched: [dynamic]int,
}

@(private = "file")
scratch_make :: proc(n: int) -> Scratch {
	s := Scratch {
		dist    = make([]f32, n, context.temp_allocator),
		prev    = make([]i32, n, context.temp_allocator),
		touched = make([dynamic]int, context.temp_allocator),
	}
	for k in 0 ..< n {s.dist[k] = math.F32_MAX; s.prev[k] = -1}
	return s
}

// cheapest_path is the cheapest way over land from a to b (cells, a first), or nil: A* where
// a step costs its length plus its climb (the sea is closed) and the rest of the way is at
// least the rows between.
@(private = "file")
cheapest_path :: proc(p: Planet, sc: ^Scratch, a, b: int, allocator: runtime.Allocator) -> []int {
	w, h := p.land.width, p.land.height
	cell_km := 40075.0 / f64(w)
	left :: proc(k, b, w: int, cell_km: f64) -> f32 {
		return f32(f64(abs(k / w - b / w)) * cell_km)
	}
	q: pq.Priority_Queue(Node)
	pq.init(
		&q,
		proc(x, y: Node) -> bool {return x.cost < y.cost},
		pq.default_swap_proc(Node),
		256,
		context.temp_allocator,
	)
	sc.dist[a] = 0
	append(&sc.touched, a)
	pq.push(&q, Node{left(a, b, w, cell_km), a})
	for pq.len(q) > 0 {
		cur := pq.pop(&q)
		if cur.cost > sc.dist[cur.cell] + left(cur.cell, b, w, cell_km) {continue}
		if cur.cell == b {break}
		i, j := cur.cell % w, cur.cell / w
		for dj in -1 ..= 1 {
			jj := j + dj
			if jj < 0 || jj >= h {continue}
			ew := max(base.cos(climate_lat(h, jj) * math.PI / 180), 0.05)
			for di in -1 ..= 1 {
				if di == 0 && dj == 0 {continue}
				nb := jj * w + (i + di + w) % w
				if !p.land.is_land[nb] {continue}
				ex := f64(di) * ew
				len_km := cell_km * math.sqrt(ex * ex + f64(dj * dj))
				climb := abs(f64(p.land.elevation[nb] - p.land.elevation[cur.cell]))
				d := sc.dist[cur.cell] + f32(len_km + climb / CLIMB_M_PER_KM)
				if d < sc.dist[nb] {
					if sc.dist[nb] == math.F32_MAX {append(&sc.touched, nb)}
					sc.dist[nb] = d
					sc.prev[nb] = i32(cur.cell)
					pq.push(&q, Node{d + left(nb, b, w, cell_km), nb})
				}
			}
		}
	}
	path: []int
	if sc.prev[b] >= 0 || a == b {
		count := 1
		for k := b; k != a; k = int(sc.prev[k]) {count += 1}
		path = make([]int, count, allocator)
		k := b
		for i := count - 1; i >= 0; i -= 1 {
			path[i] = k
			if i > 0 {k = int(sc.prev[k])}
		}
	}
	for k in sc.touched {sc.dist[k] = math.F32_MAX; sc.prev[k] = -1}
	clear(&sc.touched)
	return path
}
