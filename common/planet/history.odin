package planet

import "common:base"
import "core:slice"

// History: the peoples of a planet from their beginning to a day, a pure function of the
// planet model, the address, the seed and the day (docs/world.md, peoples). Time moves in
// steps of one decade; each step's randomness is a hash of (address, seed, decade, cell), so
// the history at any day is computed, never a running state.

HISTORY_STEP_YEARS :: 10
DAYS_PER_YEAR :: 365

// Farming: a cell can begin it where a long, harsh dry season kills perennials, or in hot
// desert along a big river. The rate is per decade at suitability 1.
FARMING_RATE :: 0.00005
FARMING_APART_KM :: 1200.0 // a new people does not arise this close to another
RIVER_BIG :: 150.0 // runoff (mm of rain, summed over the cells upstream) of a big river

// Numbers: people per square km at the best land.
FORAGER_DENSITY :: 0.2
FARMER_DENSITY :: 8.0
GROWTH_PER_STEP :: 0.15
CROWDED :: 0.7 // a cell this full of its capacity sends settlers out
SETTLE_SHARE :: 0.3 // of the cell's people go
KNOWLEDGE_RATE :: 0.012 // per step, times the people's share of a million
KNOWLEDGE_MAX :: 12.0

// Intervention is a player's act on the history. Not applied yet (a later part).
Intervention :: struct {
	day:      i64,
	lat, lon: f64,
	kind:     u8,
}

// People is one people: where farming began for them, how many they are, what they know.
People :: struct {
	origin:        int, // the climate cell
	origin_decade: int,
	population:    f64,
	cells:         int,
	knowledge:     f64, // 1 at the beginning of farming
}

// History is the state at `years`: who holds each climate cell and how many live there.
History :: struct {
	width, height: int,
	years:         int,
	owner:         []u16, // 0: nobody, else a people's index + 1
	pop:           []f32,
	peoples:       [dynamic]People,
}

history_destroy :: proc(h: ^History) {
	delete(h.owner)
	delete(h.pop)
	delete(h.peoples)
	h^ = {}
}

// Terrain is what the peoples' ground gives, once per planet: capacity and farming.
@(private = "file")
Ground :: struct {
	area:     []f32, // km² per cell
	capacity: []f32, // 0..1 of the best land
	river:    []f32, // 0..1: how big a river runs through the cell
	suit:     []f32, // farming suitability, before biogeography
	row_cos:  []f64,
	cell_km:  f64,
}

ground_destroy :: proc(g: ^Ground) {
	delete(g.area)
	delete(g.capacity)
	delete(g.river)
	delete(g.suit)
	delete(g.row_cos)
}

@(private = "file")
mix64 :: proc(a, b: u64) -> u64 {
	z := (a ~ (b + 0x9e37_79b9_7f4a_7c15)) * 0xbf58_476d_1ce4_e5b9
	z = (z ~ (z >> 30)) * 0x94d0_49bb_1331_11eb
	z = (z ~ (z >> 27)) * 0xbf58_476d_1ce4_e5b9
	return z ~ (z >> 31)
}

// unit is a hash as a number in [0, 1).
@(private = "file")
unit :: proc(h: u64) -> f64 {
	return f64(h >> 11) / f64(u64(1) << 53)
}

// biogeography is which domesticable species a region had: a seeded field per world,
// 0 (none worth farming) to 1 (many), value noise over regions about 40 degrees across.
@(private = "file")
biogeography :: proc(root: u64, lat, lon: f64) -> f64 {
	octave :: proc(root: u64, lat, lon, size: f64, salt: u64) -> f64 {
		cols := int(360 / size)
		x := (lon + 180) / size
		y := (lat + 90) / size
		i0, j0 := int(x), int(y)
		fx, fy := x - f64(i0), y - f64(j0)
		fx = fx * fx * (3 - 2 * fx)
		fy = fy * fy * (3 - 2 * fy)
		v :: proc(root, salt: u64, i, j, cols: int) -> f64 {
			return unit(mix64(mix64(root, salt), u64(j * cols + i % cols)))
		}
		a := v(root, salt, i0, j0, cols) * (1 - fx) + v(root, salt, i0 + 1, j0, cols) * fx
		b := v(root, salt, i0, j0 + 1, cols) * (1 - fx) + v(root, salt, i0 + 1, j0 + 1, cols) * fx
		return a * (1 - fy) + b * fy
	}
	n := 0.65 * octave(root, lat, lon, 40, 1) + 0.35 * octave(root, lat, lon, 20, 2)
	return clamp((n - 0.3) * 2.2, 0.05, 1)
}

// ground_build computes capacity, rivers and farming suitability from the climate grid.
@(private = "file")
ground_build :: proc(p: Planet, allocator := context.allocator) -> Ground {
	w, h := p.land.width, p.land.height
	n := w * h
	g: Ground
	g.area = make([]f32, n, allocator)
	g.capacity = make([]f32, n, allocator)
	g.river = make([]f32, n, allocator)
	g.suit = make([]f32, n, allocator)
	g.row_cos = make([]f64, h, allocator)
	g.cell_km = 40075.0 / f64(w)
	annual := make([]f32, n, context.temp_allocator)
	mean_t := make([]f32, n, context.temp_allocator)
	cold_t := make([]f32, n, context.temp_allocator) // the coldest month's mean
	for j in 0 ..< h {
		g.row_cos[j] = max(base.cos(climate_lat(h, j) * PI / 180), 0.02)
		for i in 0 ..< w {
			k := j * w + i
			g.area[k] = f32(g.cell_km * g.cell_km * g.row_cos[j])
			if !p.land.is_land[k] {continue}
			pr, t, cold := 0.0, 0.0, 99.0
			for m in 0 ..< 12 {
				pr += f64(p.precip.month[m][k])
				t += f64(p.temp.month[m][k]) / 10
				cold = min(cold, f64(p.temp.month[m][k]) / 10)
			}
			annual[k] = f32(pr)
			mean_t[k] = f32(t / 12)
			cold_t[k] = f32(cold)
		}
	}

	// Rivers: each land cell drains to its lowest lower neighbour (a pit keeps its water),
	// processed from the highest down so a cell's whole catchment is in before it passes on.
	order := make([dynamic]int, 0, n / 3, context.temp_allocator)
	for k in 0 ..< n {
		if p.land.is_land[k] {append(&order, k)}
	}
	elev := p.land.elevation
	// Counting sort by metre (stable, so ties keep cell order): no comparison sort needed.
	lo, hi := 0, 0
	for k in order {
		e := int(elev[k])
		lo, hi = min(lo, e), max(hi, e)
	}
	counts := make([]int, hi - lo + 2, context.temp_allocator)
	for k in order {counts[int(elev[k]) - lo + 1] += 1}
	for e in 1 ..< len(counts) {counts[e] += counts[e - 1]}
	sorted := make([]int, len(order), context.temp_allocator)
	for k in order {
		e := int(elev[k]) - lo
		sorted[counts[e]] = k
		counts[e] += 1
	}
	flow := make([]f32, n, context.temp_allocator)
	for k in order {flow[k] = annual[k] / 100}
	for s := len(sorted) - 1; s >= 0; s -= 1 {
		k := sorted[s]
		i, j := k % w, k / w
		best, be := -1, elev[k]
		for dj in -1 ..= 1 {
			for di in -1 ..= 1 {
				if di == 0 && dj == 0 {continue}
				jj := j + dj
				if jj < 0 || jj >= h {continue}
				q := jj * w + (i + di + w) % w
				if p.land.is_land[q] && elev[q] < be {best, be = q, elev[q]}
			}
		}
		if best >= 0 {flow[best] += flow[k]}
	}
	for k in order {g.river[k] = f32(min(flow[k] / RIVER_BIG, 1))}

	// Capacity: what grows (rain and warmth), plus the water of a river.
	for k in order {
		wet := min(f64(annual[k]) / 1100, 1)
		warm := clamp((f64(mean_t[k]) + 5) / 20, 0, 1)
		c := wet * warm
		c = c + (1 - c) * 0.6 * f64(g.river[k]) * warm
		g.capacity[k] = f32(c)
	}

	// Farming suitability, from the climate class.
	for k in order {
		c := p.koppen[k]
		s := 0.0
		#partial switch c {
		case .Csa, .Csb:
			// (the cool-season annuals: a winter, not a tropical year that only looks dry)
			s = 1 if cold_t[k] < 15 else 0
		case .BSk:
			s = 1
		case .BSh:
			s = 0.7
		case .Cwa, .Cwb:
			s = 0.7 if cold_t[k] < 15 else 0
		case .Dwa, .Dwb, .Dsa, .Dsb:
			s = 0.5
		case .Aw:
			if annual[k] < 800 {s = 0.4}
		case .BWh, .BWk:
			s = 0.9 * f64(g.river[k]) if mean_t[k] > 10 && g.river[k] > 0.3 else 0
		}
		if mean_t[k] < 5 {s = 0}
		// Wild grass stands need enough growth to be worth sowing.
		g.suit[k] = f32(s * min(f64(g.capacity[k]) / 0.4, 1))
	}
	return g
}

// farming_suitability is each climate cell's likelihood that farming begins there on this
// world, 0..1: the climate's, times the biogeography of its region: the seeded field, or
// `bio` (a value per climate cell) where a world's real species are known (Earth's).
farming_suitability :: proc(
	p: Planet,
	address, seed: u64,
	bio: []f32 = nil,
	allocator := context.allocator,
) -> []f32 {
	g := ground_build(p, context.temp_allocator)
	return suitability_of(p, g, mix64(address, seed), bio, allocator)
}

@(private = "file")
suitability_of :: proc(
	p: Planet,
	g: Ground,
	root: u64,
	bio: []f32,
	allocator := context.allocator,
) -> []f32 {
	w, h := p.land.width, p.land.height
	out := make([]f32, w * h, allocator)
	for j in 0 ..< h {
		lat := climate_lat(h, j)
		for i in 0 ..< w {
			k := j * w + i
			if g.suit[k] == 0 {continue}
			lon := (f64(i) + 0.5) * 360 / f64(w) - 180
			out[k] = g.suit[k] * (bio[k] if bio != nil else f32(biogeography(root, lat, lon)))
		}
	}
	return out
}

// history computes the peoples from the beginning to `day` (365 days a year). Pure and
// deterministic. `interventions` are accepted and not yet applied.
history :: proc(
	p: Planet,
	address, seed: u64,
	day: i64,
	interventions: []Intervention,
	allocator := context.allocator,
) -> History {
	_ = interventions
	w, h := p.land.width, p.land.height
	n := w * h
	years := int(max(day, 0) / DAYS_PER_YEAR)
	steps := years / HISTORY_STEP_YEARS
	res := History {
		width   = w,
		height  = h,
		years   = steps * HISTORY_STEP_YEARS,
		owner   = make([]u16, n, allocator),
		pop     = make([]f32, n, allocator),
		peoples = make([dynamic]People, allocator),
	}
	root := mix64(address, seed)
	g := ground_build(p, context.temp_allocator)
	suit := suitability_of(p, g, root, nil, context.temp_allocator)

	// The cells that can begin farming, each with the decade it would (a hash of the cell
	// and the world, over its rate): the ones inside the history, earliest first.
	begins := make([dynamic]u64, context.temp_allocator)
	for k in 0 ..< n {
		s := f64(suit[k])
		if s <= 0 {continue}
		onset := unit(mix64(root, u64(k))) / (FARMING_RATE * s * s * s)
		if onset < f64(steps) {append(&begins, u64(onset) << 32 | u64(k))}
	}
	slice.sort(begins[:])
	next_begin := 0
	apart := int(FARMING_APART_KM / g.cell_km) + 1

	active := make([dynamic]int, context.temp_allocator) // cells held, in the order taken
	for step in 0 ..< steps {
		sroot := mix64(root, u64(step))
		// 1. Farming begins somewhere new.
		for next_begin < len(begins) && int(begins[next_begin] >> 32) <= step {
			k := int(begins[next_begin] & 0xffff_ffff)
			next_begin += 1
			if res.owner[k] != 0 || near_people(res, k, apart) {continue}
			append(&res.peoples, People{origin = k, origin_decade = step, knowledge = 1})
			res.owner[k] = u16(len(res.peoples))
			res.pop[k] = 20
			append(&active, k)
		}
		// 2. Knowledge grows with numbers (as of the last step's count).
		for &pe in res.peoples {
			share := pe.population / 1e6
			pe.knowledge = min(
				pe.knowledge + KNOWLEDGE_RATE * share / (1 + share) * pe.knowledge,
				KNOWLEDGE_MAX,
			)
			pe.population = 0
		}
		// 3. Growth to capacity, and settling when crowded.
		count := len(active)
		for a in 0 ..< count {
			k := active[a]
			pe := &res.peoples[res.owner[k] - 1]
			dens := FORAGER_DENSITY + FARMER_DENSITY * (1 - 1 / pe.knowledge)
			cap := max(f64(g.capacity[k]) * f64(g.area[k]) * dens, 1)
			pop := f64(res.pop[k])
			pop += pop * GROWTH_PER_STEP * (1 - pop / cap)
			// (a crowded cell looks for room every fourth decade, in turns)
			if pop > CROWDED * cap && (step + k) % 4 == 0 {
				if t := settle_target(p, g, res, k, mix64(sroot, u64(k) + u64(2 * n))); t >= 0 {
					res.owner[t] = res.owner[k]
					res.pop[t] = f32(pop * SETTLE_SHARE)
					pop -= pop * SETTLE_SHARE
					append(&active, t)
				}
			}
			res.pop[k] = f32(pop)
			pe.population += pop
		}
	}
	for &pe in res.peoples {
		pe.population, pe.cells = 0, 0
	}
	for k in active {
		pe := &res.peoples[res.owner[k] - 1]
		pe.population += f64(res.pop[k])
		pe.cells += 1
	}
	return res
}

// near_people: some people began within `r` cells of k.
@(private = "file")
near_people :: proc(res: History, k, r: int) -> bool {
	w := res.width
	for pe in res.peoples {
		di := abs(pe.origin % w - k % w)
		di = min(di, w - di)
		if di <= r && abs(pe.origin / w - k / w) <= r {return true}
	}
	return false
}

// settle_target is the best free neighbouring land cell of k, or -1.
@(private = "file")
settle_target :: proc(p: Planet, g: Ground, res: History, k: int, roll: u64) -> int {
	w, h := res.width, res.height
	i, j := k % w, k / w
	best, bv := -1, -1.0
	for dj in -1 ..= 1 {
		for di in -1 ..= 1 {
			if di == 0 && dj == 0 {continue}
			jj := j + dj
			if jj < 0 || jj >= h {continue}
			q := jj * w + (i + di + w) % w
			if !p.land.is_land[q] || res.owner[q] != 0 || g.capacity[q] <= 0.01 {continue}
			v := f64(g.capacity[q]) * f64(g.area[q]) * (0.9 + 0.2 * unit(mix64(roll, u64(q))))
			if v > bv {best, bv = q, v}
		}
	}
	return best
}

// history_hash is a hash of a history, for the determinism test.
history_hash :: proc(h: History) -> u64 {
	x := u64(0xcbf29ce484222325)
	for k in 0 ..< len(h.owner) {
		x = (x ~ u64(h.owner[k])) * 0x100000001b3
		x = (x ~ u64(transmute(u32)h.pop[k])) * 0x100000001b3
	}
	for pe in h.peoples {
		x = (x ~ u64(pe.origin)) * 0x100000001b3
		x = (x ~ u64(pe.origin_decade)) * 0x100000001b3
		x = (x ~ transmute(u64)pe.knowledge) * 0x100000001b3
	}
	return x
}
