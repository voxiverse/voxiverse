package planet

import "core:fmt"
import "core:math"
import "core:testing"

@(private = "file")
Place :: struct {
	name:     string,
	lat, lon: f64,
}

// Where farming really began early (the Fertile Crescent, Anatolia, the Nile, the Indus, the
// Yellow River, Mesoamerica, the Andes, the Sahel, New Guinea).
@(private = "file")
EARLY_FARMING :: [?]Place {
	{"Fertile Crescent", 35, 40},
	{"Anatolia", 38, 33},
	{"Nile", 26, 32},
	{"Indus", 28, 68},
	{"Yellow River", 35, 112},
	{"Mesoamerica", 18, -97},
	{"Andes", -12, -75},
	{"Sahel", 13, 0},
	{"New Guinea", -6, 144},
}

// earth_biogeography is Earth's real wild-species richness, by continent: the Old World's
// dry belt (Eurasia west of 125°E and south of 45°N, Africa north of 5°N), the Americas'
// tropical highlands (Mexico and the Andes), New Guinea. Elsewhere little was domesticable
// (eastern North America, South America's lowlands, southern Africa, Australia).
@(private = "file")
earth_biogeography :: proc(w, h: int) -> []f32 {
	bio := make([]f32, w * h, context.temp_allocator)
	for k in 0 ..< len(bio) {
		lat, lon := climate_lat(h, k / w), (f64(k % w) + 0.5) * 360 / f64(w) - 180
		rich :=
			(lat > 5 && lat < 45 && lon > -20 && lon < 125) ||
			(lat > 15 && lat < 25 && lon > -105 && lon < -90) ||
			(lat > -20 && lat < 5 && lon > -82 && lon < -65) ||
			(lat > -10 && lat < 0 && lon > 130 && lon < 150)
		bio[k] = 1 if rich else 0.1
	}
	return bio
}

@(private = "file")
great_circle_km :: proc(la1, lo1, la2, lo2: f64) -> f64 {
	r := math.PI / 180
	a := math.sin((la2 - la1) * r / 2)
	b := math.sin((lo2 - lo1) * r / 2)
	x := a * a + math.cos(la1 * r) * math.cos(la2 * r) * b * b
	return 2 * 6371 * math.asin(math.sqrt(x))
}

// likeliest_regions: the n best cells, each at least `apart_km` from the better ones.
@(private = "file")
likeliest_regions :: proc(raw: []f32, w, h, n: int, apart_km: f64) -> [dynamic][2]f64 {
	taken := make([]bool, len(raw), context.temp_allocator)
	// A region is a belt of cells: score a cell by the suitability around it (about 500 km).
	smooth := make([]f32, len(raw), context.temp_allocator)
	R :: 3
	for k in 0 ..< len(raw) {
		if raw[k] <= 0 {continue}
		i, j := k % w, k / w
		sum: f32
		for dj in -R ..= R {
			jj := j + dj
			if jj < 0 || jj >= h {continue}
			for di in -R ..= R {sum += raw[jj * w + (i + di + w) % w]}
		}
		smooth[k] = sum
	}
	suit := smooth
	out: [dynamic][2]f64
	for len(out) < n {
		best := -1
		for k in 0 ..< len(suit) {
			if !taken[k] && suit[k] > 0 && (best < 0 || suit[k] > suit[best]) {best = k}
		}
		if best < 0 {break}
		lat, lon := climate_lat(h, best / w), (f64(best % w) + 0.5) * 360 / f64(w) - 180
		append(&out, [2]f64{lat, lon})
		for k in 0 ..< len(suit) {
			la, lo := climate_lat(h, k / w), (f64(k % w) + 0.5) * 360 / f64(w) - 180
			if great_circle_km(lat, lon, la, lo) < apart_km {taken[k] = true}
		}
	}
	return out
}

@(test)
test_history_earth :: proc(t: ^testing.T) {
	r, ok := relief_decode(#load("../../assets/planet/earth_relief.bin"))
	defer relief_destroy(&r)
	testing.expect(t, ok)
	p := planet_build(r)
	defer planet_destroy(&p)

	// The validation: of the 10 likeliest farming regions, at least 5 lie within 1 200 km of a
	// real early-farming region (a test only: Earth has no peoples in the game).
	worst := 10
	// (Earth's biogeography is given, so the seed does not matter here.)
	for seed in u64(1) ..= 1 {
		suit := farming_suitability(
			p,
			0xea27,
			seed,
			earth_biogeography(p.land.width, p.land.height),
		)
		defer delete(suit)
		regions := likeliest_regions(suit, p.land.width, p.land.height, 10, 1000)
		defer delete(regions)
		hits := 0
		for reg in regions {
			fmt.printfln("  region %.0f %.0f", reg.x, reg.y)
			for real in EARLY_FARMING {
				if great_circle_km(reg.x, reg.y, real.lat, real.lon) <= 1200 {
					hits += 1
					break
				}
			}
		}
		fmt.printfln("seed %d: %d of 10 regions near real early farming", seed, hits)
		worst = min(worst, hits)
	}
	testing.expectf(t, worst >= 5, "only %d of the 10 likeliest regions near real ones", worst)
}

@(test)
test_history_deterministic :: proc(t: ^testing.T) {
	r, ok := relief_decode(#load("../../assets/planet/earth_relief.bin"))
	defer relief_destroy(&r)
	testing.expect(t, ok)
	p := planet_build(r)
	defer planet_destroy(&p)

	day := i64(6000 * DAYS_PER_YEAR)
	a := history(p, 7, 3, day, nil)
	defer history_destroy(&a)
	b := history(p, 7, 3, day, nil)
	defer history_destroy(&b)
	c := history(p, 7, 4, day, nil)
	defer history_destroy(&c)
	testing.expect_value(t, history_hash(a), history_hash(b))
	testing.expect(t, history_hash(a) != history_hash(c))
	fmt.printfln("history hash: %#x", history_hash(a))

	held := 0
	for pe in a.peoples {held += pe.cells}
	fmt.printfln("%d peoples, %d cells held after %d years", len(a.peoples), held, a.years)
	testing.expect(t, len(a.peoples) > 0 && held > len(a.peoples))
	// A day inside the same decade is the same history; the past is a prefix of the future.
	d := history(p, 7, 3, day + 100, nil)
	defer history_destroy(&d)
	testing.expect_value(t, history_hash(d), history_hash(a))
	e := history(p, 7, 3, day / 2, nil)
	defer history_destroy(&e)
	testing.expect(t, len(e.peoples) <= len(a.peoples))
	for pe, i in e.peoples {
		testing.expect(t, pe.origin == a.peoples[i].origin)
	}
	for pe in a.peoples {testing.expect(t, pe.population >= 0)}
}

chronicle_planet :: proc() -> (p: Planet, r: Relief) {
	r, _ = relief_decode(#load("../../assets/planet/earth_relief.bin"))
	p = planet_build(r)
	return
}

@(test)
test_history_chronicle :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)

	dry := drought_probability(p)
	defer delete(dry)
	counts: [Event_Kind]int
	for seed in u64(1) ..= 4 {
		hist := history(p, 9, seed, 6000 * DAYS_PER_YEAR, nil)
		defer history_destroy(&hist)
		last := 0
		for e in hist.events {
			counts[e.kind] += 1
			testing.expect(t, len(e.cause) > 0 && len(e.text) > 0, "an event has no cause")
			testing.expect(t, e.year >= last, "the chronicle is not in order")
			last = e.year
			testing.expect(t, e.people >= 0 && e.people < len(hist.peoples))
			if e.kind == .Collapse {
				// A drought decade in the climate's statistics precedes every collapse.
				testing.expectf(
					t,
					drought_in(dry, hist.width, 9, seed, e.year, hist.peoples[e.people].origin),
					"collapse of the %s in %d with no drought",
					hist.peoples[e.people].name,
					e.year,
				)
			}
		}
		for pe in hist.peoples {testing.expect(t, len(pe.name) > 0)}
	}
	fmt.printfln("events over 4 worlds: %v", counts)
	testing.expect(t, counts[.Farming] > 0 && counts[.War] > 0 && counts[.Collapse] > 0)
}

@(test)
test_history_intervention :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)

	end := i64(6000 * DAYS_PER_YEAR)
	base_h := history(p, 7, 3, end, nil)
	defer history_destroy(&base_h)
	// Free land at the end of the history: a place for a new settlement.
	cell := -1
	for k in 0 ..< len(base_h.owner) {
		if p.land.is_land[k] && base_h.owner[k] == 0 {cell = k; break}
	}
	testing.expect(t, cell >= 0)
	iv := Intervention {
		day  = 3000 * DAYS_PER_YEAR + 100,
		lat  = climate_lat(p.land.height, cell / p.land.width),
		lon  = (f64(cell % p.land.width) + 0.5) * 360 / f64(p.land.width) - 180,
		kind = INTERVENTION_SETTLEMENT,
	}
	// Nothing changes before its day.
	before := history(p, 7, 3, iv.day - 1, {iv})
	defer history_destroy(&before)
	clean := history(p, 7, 3, iv.day - 1, nil)
	defer history_destroy(&clean)
	testing.expect_value(t, history_hash(before), history_hash(clean))
	// From its day on, it is in the history.
	for day in ([?]i64{iv.day, iv.day + 5000, end}) {
		with := history(p, 7, 3, day, {iv})
		defer history_destroy(&with)
		found := false
		for e in with.events {
			if e.kind == .Founding && e.year == 3000 && with.peoples[e.people].origin == cell {
				found = len(e.cause) > 0
			}
		}
		testing.expectf(t, found, "no founding in the history at day %d", day)
	}
	again := history(p, 7, 3, end, {iv})
	defer history_destroy(&again)
	other := history(p, 7, 3, end, {iv})
	defer history_destroy(&other)
	testing.expect_value(t, history_hash(again), history_hash(other))
	testing.expect(t, history_hash(again) != history_hash(base_h))
}
