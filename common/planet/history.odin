package planet

import "base:runtime"
import "common:base"
import "core:fmt"
import "core:slice"
import "core:strings"

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

// War: a people with more numbers times knowledge than a neighbour takes its border cells.
WAR_RATIO :: 1.3 // the stronger must be this much stronger
WAR_TAKE :: 0.5 // chance per border cell and step (every third step, in turns)
WAR_LOSS :: 0.3 // of a taken cell's people die

// Collapse: a crowded people (their numbers at COLLAPSE_CROWD of their land's capacity) in a
// drought decade lose half their land, and then are safe for COLLAPSE_COOLDOWN steps.
COLLAPSE_CROWD :: 0.6
COLLAPSE_COOLDOWN :: 5
COLLAPSE_MIN_CELLS :: 4
DROUGHT_BLOCK :: 6 // a drought covers a block of this many cells square

// Eras by knowledge: the first three are the same everywhere, later ones are named per world.
ERA_KNOWLEDGE :: [?]f64{2, 4, 7, 10}
ERA_NAMES :: [?]string{"Stone Age", "Bronze Age", "Iron Age"}
ERA_LATER :: [?][1]string{{"Age of Sail"}, {"Age of Steam"}}

// A world's peoples' names are built from a set of its syllables.
SYLLABLES :: [?]string {
	"ta",
	"ka",
	"ne",
	"ri",
	"sha",
	"el",
	"mo",
	"ru",
	"ven",
	"dai",
	"lo",
	"kur",
	"an",
	"ith",
	"so",
	"bra",
	"zu",
	"mel",
	"oth",
	"pe",
	"gri",
	"ha",
	"yu",
	"dor",
	"fen",
	"qua",
	"is",
	"tor",
	"wa",
	"lin",
	"ur",
	"cha",
}
SYLLABLES_PER_WORLD :: 8

// Intervention is a player's act on the history, at a day and a place.
Intervention :: struct {
	day:      i64,
	lat, lon: f64,
	kind:     u8, // INTERVENTION_*
}

INTERVENTION_SETTLEMENT :: 1 // founds a settlement (a new people on free land, else settlers)

Event_Kind :: enum u8 {
	Farming,
	Era,
	War,
	Conquest,
	Collapse,
	Founding,
}

// Event is one thing that happened in the history, with why.
Event :: struct {
	year:   int,
	kind:   Event_Kind,
	people: int, // index in History.peoples
	other:  int, // the other people (war, conquest), else -1
	cell:   int, // where (a climate cell)
	text:   string, // "The Taka lose half their land"
	cause:  string, // "a great drought"
}

// People is one people: where farming began for them, how many they are, what they know.
People :: struct {
	origin:        int, // the climate cell
	origin_decade: int,
	population:    f64,
	cells:         int,
	knowledge:     f64, // 1 at the beginning of farming
	name:          string,
	era:           int, // index into the eras (0: the Stone Age)
	capacity:      f64, // what their land holds at what they know (this step)
	cooldown:      int, // the step before which a collapse cannot happen again
}

// History is the state at `years`: who holds each climate cell and how many live there.
History :: struct {
	width, height: int,
	years:         int,
	owner:         []u16, // 0: nobody, else a people's index + 1
	pop:           []f32,
	peoples:       [dynamic]People,
	events:        [dynamic]Event, // the chronicle, by year
	ruins:         [dynamic]int, // cells that lost their people to a collapse
}

history_destroy :: proc(h: ^History) {
	delete(h.owner)
	delete(h.pop)
	for pe in h.peoples {delete(pe.name)}
	delete(h.peoples)
	for e in h.events {
		delete(e.text)
		delete(e.cause)
	}
	delete(h.events)
	delete(h.ruins)
	h^ = {}
}

// Terrain is what the peoples' ground gives, once per planet: capacity and farming.
@(private = "file")
Ground :: struct {
	area:     []f32, // km² per cell
	capacity: []f32, // 0..1 of the best land
	river:    []f32, // 0..1: how big a river runs through the cell
	suit:     []f32, // farming suitability, before biogeography
	dry:      []f32, // chance per decade of a drought hitting the cell: its climate's variability
	row_cos:  []f64,
	cell_km:  f64,
}

ground_destroy :: proc(g: ^Ground) {
	delete(g.area)
	delete(g.capacity)
	delete(g.river)
	delete(g.suit)
	delete(g.dry)
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
	g.dry = make([]f32, n, allocator)
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
			// Rain varies most where it is scarce and where it comes in one season.
			wettest := 0.0
			for m in 0 ..< 12 {wettest = max(wettest, f64(p.precip.month[m][k]))}
			aridity := clamp(1 - pr / 1200, 0, 1)
			season := clamp((wettest / max(pr / 12, 1) - 1) / 4, 0, 1)
			g.dry[k] = f32(0.02 + 0.1 * aridity + 0.06 * season)
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

// Sim is the running state of one history computation.
@(private = "file")
Sim :: struct {
	p:         Planet,
	g:         Ground,
	res:       ^History,
	root:      u64,
	active:    [dynamic]int, // cells ever held, in the order taken
	listed:    []bool, // in `active`
	wars:      [dynamic]War,
	allocator: runtime.Allocator,
}

@(private = "file")
War :: struct {
	a, b:  int, // the people who began it (a) and the other
	since: int, // year
}

// drought_probability is each climate cell's chance per decade of a drought (the climate's
// variability: rain varies most where it is scarce or seasonal); 0 over the sea.
drought_probability :: proc(p: Planet, allocator := context.allocator) -> []f32 {
	g := ground_build(p, context.temp_allocator)
	out := make([]f32, len(g.dry), allocator)
	copy(out, g.dry)
	return out
}

// drought_in: whether a drought decade (the decade starting at `year`) hits cell k of a world.
// A drought covers a block of cells; `dry` is drought_probability.
drought_in :: proc(dry: []f32, width: int, address, seed: u64, year, k: int) -> bool {
	return drought_hit(dry, width, mix64(address, seed), year / HISTORY_STEP_YEARS, k)
}

@(private = "file")
drought_hit :: proc(dry: []f32, w: int, root: u64, step, k: int) -> bool {
	i, j := k % w, k / w
	cols := (w + DROUGHT_BLOCK - 1) / DROUGHT_BLOCK
	block := (j / DROUGHT_BLOCK) * cols + i / DROUGHT_BLOCK
	roll := unit(mix64(mix64(root, 0xd0d0), u64(step) << 32 | u64(block)))
	return roll < f64(dry[k])
}

// era_of is the era a people's knowledge has reached.
@(private = "file")
era_of :: proc(knowledge: f64) -> int {
	eras := ERA_KNOWLEDGE
	e := 0
	for t in eras {
		if knowledge >= t {e += 1}
	}
	return e
}

// era_name: the first eras are the same everywhere, later ones are named per world.
era_name :: proc(root: u64, era: int) -> string {
	names := ERA_NAMES
	if era < len(names) {return names[era]}
	later := ERA_LATER
	pick := int(mix64(root, u64(era)) % u64(len(later)))
	return later[pick][0]
}

// people_name builds a name from the world's syllables (the same people, the same name).
@(private = "file")
make_name :: proc(s: ^Sim, index: int) -> string {
	pool := SYLLABLES
	set: [SYLLABLES_PER_WORLD]string
	// The world's set: a seeded partial shuffle of the pool.
	order: [len(pool)]int
	for i in 0 ..< len(order) {order[i] = i}
	for i in 0 ..< SYLLABLES_PER_WORLD {
		r := i + int(mix64(s.root, u64(0x5111 + i)) % u64(len(order) - i))
		order[i], order[r] = order[r], order[i]
		set[i] = pool[order[i]]
	}
	for attempt in 0 ..< 50 {
		h := mix64(mix64(s.root, u64(0x7a3e + index)), u64(attempt))
		count := 2 + int(h % 2)
		h = h >> 8
		b := strings.builder_make(context.temp_allocator)
		for c in 0 ..< count {
			strings.write_string(&b, set[int(mix64(h, u64(c)) % SYLLABLES_PER_WORLD)])
		}
		name := strings.to_string(b)
		cap := strings.concatenate(
			{strings.to_upper(name[:1], context.temp_allocator), name[1:]},
			s.allocator,
		)
		unique := true
		for pe in s.res.peoples {
			if pe.name == cap {unique = false}
		}
		if unique || attempt == 49 {return cap}
		delete(cap, s.allocator)
	}
	return ""
}

@(private = "file")
record :: proc(
	s: ^Sim,
	year: int,
	kind: Event_Kind,
	people, other, cell: int,
	text, cause: string,
) {
	append(
		&s.res.events,
		Event {
			year = year,
			kind = kind,
			people = people,
			other = other,
			cell = cell,
			text = text,
			cause = cause,
		},
	)
}

@(private = "file")
tell :: proc(s: ^Sim, format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args, allocator = s.allocator)
}

@(private = "file")
hold :: proc(s: ^Sim, k, people: int) {
	s.res.owner[k] = u16(people + 1)
	if !s.listed[k] {
		s.listed[k] = true
		append(&s.active, k)
	}
}

// found a new people at free land k.
@(private = "file")
found :: proc(s: ^Sim, k, year, decade: int) -> int {
	index := len(s.res.peoples)
	append(
		&s.res.peoples,
		People {
			origin = k,
			origin_decade = decade,
			knowledge = 1,
			cells = 1,
			name = make_name(s, index),
		},
	)
	hold(s, k, index)
	s.res.pop[k] = 20
	return index
}

@(private = "file")
cell_of :: proc(res: History, lat, lon: f64) -> int {
	j := clamp(int((90 - lat) / 180 * f64(res.height)), 0, res.height - 1)
	i := int((lon + 180) / 360 * f64(res.width)) % res.width
	if i < 0 {i += res.width}
	return j * res.width + i
}

@(private = "file")
apply_intervention :: proc(s: ^Sim, iv: Intervention, decade: int) {
	if iv.kind != INTERVENTION_SETTLEMENT {return}
	k := cell_of(s.res^, iv.lat, iv.lon)
	if !s.p.land.is_land[k] {return}
	year := int(max(iv.day, 0) / DAYS_PER_YEAR)
	cause := tell(s, "a settlement founded from outside on day %d", iv.day)
	if s.res.owner[k] == 0 {
		who := found(s, k, year, decade)
		name := s.res.peoples[who].name
		record(s, year, .Founding, who, -1, k, tell(s, "The %s settle new land", name), cause)
	} else {
		who := int(s.res.owner[k]) - 1
		s.res.pop[k] += 50
		name := s.res.peoples[who].name
		record(s, year, .Founding, who, -1, k, tell(s, "Settlers join the %s", name), cause)
	}
}

// history computes the peoples from the beginning to `day` (365 days a year): their farming,
// numbers, knowledge, wars, collapses and the chronicle of it. Pure and deterministic.
// Interventions enter at their day and place; one after `day` changes nothing.
history :: proc(
	p: Planet,
	address, seed: u64,
	day: i64,
	interventions: []Intervention,
	allocator := context.allocator,
) -> History {
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
		events  = make([dynamic]Event, allocator),
		ruins   = make([dynamic]int, allocator),
	}
	root := mix64(address, seed)
	g := ground_build(p, context.temp_allocator)
	suit := suitability_of(p, g, root, nil, context.temp_allocator)
	s := Sim {
		p         = p,
		g         = g,
		res       = &res,
		root      = root,
		active    = make([dynamic]int, context.temp_allocator),
		listed    = make([]bool, n, context.temp_allocator),
		wars      = make([dynamic]War, context.temp_allocator),
		allocator = allocator,
	}

	// The cells that can begin farming, each with the decade it would (a hash of the cell
	// and the world, over its rate): the ones inside the history, earliest first.
	begins := make([dynamic]u64, context.temp_allocator)
	for k in 0 ..< n {
		sv := f64(suit[k])
		if sv <= 0 {continue}
		onset := unit(mix64(root, u64(k))) / (FARMING_RATE * sv * sv * sv)
		if onset < f64(steps) {append(&begins, u64(onset) << 32 | u64(k))}
	}
	slice.sort(begins[:])
	next_begin := 0
	apart := int(FARMING_APART_KM / g.cell_km) + 1
	eras_at := ERA_KNOWLEDGE

	for step in 0 ..< steps {
		sroot := mix64(root, u64(step))
		year := step * HISTORY_STEP_YEARS
		// 0. Interventions of this decade.
		for iv in interventions {
			if max(iv.day, 0) / DAYS_PER_YEAR / HISTORY_STEP_YEARS == i64(step) {
				apply_intervention(&s, iv, step)
			}
		}
		// 1. Farming begins somewhere new.
		for next_begin < len(begins) && int(begins[next_begin] >> 32) <= step {
			k := int(begins[next_begin] & 0xffff_ffff)
			next_begin += 1
			if res.owner[k] != 0 || near_people(res, k, apart) {continue}
			who := found(&s, k, year, step)
			record(
				&s,
				year,
				.Farming,
				who,
				-1,
				k,
				tell(&s, "The %s begin to farm", res.peoples[who].name),
				tell(&s, "wild grasses and herds suited the land"),
			)
		}
		// 2. Knowledge grows with numbers (as of the last step's count), and eras turn.
		for &pe, who in res.peoples {
			if pe.cells > 0 {
				share := pe.population / 1e6
				pe.knowledge = min(
					pe.knowledge + KNOWLEDGE_RATE * share / (1 + share) * pe.knowledge,
					KNOWLEDGE_MAX,
				)
				if era := era_of(pe.knowledge); era > pe.era {
					pe.era = era
					record(
						&s,
						year,
						.Era,
						who,
						-1,
						pe.origin,
						tell(&s, "The %s enter the %s", pe.name, era_name(root, era)),
						tell(
							&s,
							"their numbers passed on what they learned (knowledge %.0f)",
							eras_at[era - 1],
						),
					)
				}
			}
			pe.population = 0
			pe.capacity = 0
		}
		// 3. Growth to capacity, and settling when crowded.
		count := len(s.active)
		for a in 0 ..< count {
			k := s.active[a]
			if res.owner[k] == 0 {continue}
			pe := &res.peoples[res.owner[k] - 1]
			dens := FORAGER_DENSITY + FARMER_DENSITY * (1 - 1 / pe.knowledge)
			cap := max(f64(g.capacity[k]) * f64(g.area[k]) * dens, 1)
			pop := f64(res.pop[k])
			pop += pop * GROWTH_PER_STEP * (1 - pop / cap)
			// (a crowded cell looks for room every fourth decade, in turns)
			if pop > CROWDED * cap && (step + k) % 4 == 0 {
				if t := settle_target(p, g, res, k, mix64(sroot, u64(k) + u64(2 * n))); t >= 0 {
					hold(&s, t, int(res.owner[k]) - 1)
					res.pop[t] = f32(pop * SETTLE_SHARE)
					pop -= pop * SETTLE_SHARE
					pe.cells += 1
				}
			}
			res.pop[k] = f32(pop)
			pe.population += pop
			pe.capacity += cap
		}
		// 4. War at the borders: the stronger by numbers and knowledge takes cells.
		for a in 0 ..< len(s.active) {
			k := s.active[a]
			o := int(res.owner[k])
			if o == 0 || (step + k) % 3 != 0 {continue}
			roll := mix64(sroot, u64(k) + u64(3 * n))
			d := int(roll % 8)
			if d >= 4 {d += 1} 	// the eight neighbours (not the cell)
			jj := k / w + d / 3 - 1
			if jj < 0 || jj >= h {continue}
			q := jj * w + (k % w + d % 3 - 1 + w) % w
			ob := int(res.owner[q])
			if ob == 0 || ob == o {continue}
			a_pe, b_pe := &res.peoples[o - 1], &res.peoples[ob - 1]
			if a_pe.population * a_pe.knowledge <
			   WAR_RATIO * b_pe.population * b_pe.knowledge {continue}
			if unit(mix64(roll, 77)) >= WAR_TAKE {continue}
			if war_between(&s, o - 1, ob - 1) < 0 {
				append(&s.wars, War{a = o - 1, b = ob - 1, since = year})
				record(
					&s,
					year,
					.War,
					o - 1,
					ob - 1,
					q,
					tell(&s, "The %s and the %s go to war", a_pe.name, b_pe.name),
					tell(&s, "their borders met and the %s were the stronger", a_pe.name),
				)
			}
			res.owner[q] = u16(o)
			res.pop[q] *= 1 - WAR_LOSS
			a_pe.cells += 1
			b_pe.cells -= 1
			if b_pe.cells == 0 {
				wi := war_between(&s, o - 1, ob - 1)
				long := year - s.wars[wi].since >= 50
				record(
					&s,
					year,
					.Conquest,
					o - 1,
					ob - 1,
					q,
					tell(&s, "The %s conquer the %s", a_pe.name, b_pe.name),
					tell(&s, "%s war that took their last land", "a long" if long else "a short"),
				)
			}
		}
		// 5. Collapse: a drought decade takes half the land of a crowded people.
		for &pe, who in res.peoples {
			if pe.cells < COLLAPSE_MIN_CELLS || step < pe.cooldown {continue}
			if pe.population < COLLAPSE_CROWD * pe.capacity {continue}
			if !drought_hit(g.dry, w, root, step, pe.origin) {continue}
			pe.cooldown = step + COLLAPSE_COOLDOWN
			owned := 0
			for k in s.active {
				if int(res.owner[k]) != who + 1 {continue}
				owned += 1
				if owned % 2 == 0 {
					res.owner[k] = 0
					res.pop[k] = 0
					pe.cells -= 1
					append(&res.ruins, k)
				}
			}
			record(
				&s,
				year,
				.Collapse,
				who,
				-1,
				pe.origin,
				tell(&s, "The %s lose half their land", pe.name),
				tell(&s, "a great drought, with their land crowded"),
			)
		}
	}
	// Interventions in the decade not yet run (after the last whole step, up to `day`).
	for iv in interventions {
		if iv.day <= day && max(iv.day, 0) / DAYS_PER_YEAR / HISTORY_STEP_YEARS >= i64(steps) {
			apply_intervention(&s, iv, steps)
		}
	}
	for &pe in res.peoples {
		pe.population, pe.cells = 0, 0
	}
	for k in s.active {
		if res.owner[k] == 0 {continue}
		pe := &res.peoples[res.owner[k] - 1]
		pe.population += f64(res.pop[k])
		pe.cells += 1
	}
	slice.stable_sort_by(res.events[:], proc(a, b: Event) -> bool {return a.year < b.year})
	return res
}

@(private = "file")
war_between :: proc(s: ^Sim, a, b: int) -> int {
	for w, i in s.wars {
		if (w.a == a && w.b == b) || (w.a == b && w.b == a) {return i}
	}
	return -1
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
		for c in transmute([]u8)pe.name {x = (x ~ u64(c)) * 0x100000001b3}
	}
	for e in h.events {
		x = (x ~ u64(e.year)) * 0x100000001b3
		x = (x ~ u64(e.kind)) * 0x100000001b3
		x = (x ~ u64(e.people)) * 0x100000001b3
		x = (x ~ u64(e.cell)) * 0x100000001b3
		for c in transmute([]u8)e.text {x = (x ~ u64(c)) * 0x100000001b3}
		for c in transmute([]u8)e.cause {x = (x ~ u64(c)) * 0x100000001b3}
	}
	for c in h.ruins {x = (x ~ u64(c)) * 0x100000001b3}
	return x
}
