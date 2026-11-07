package planet

import "common:base"
import "core:math"

// The economy, part 1 (docs/world.md, the economy): what a settlement's land gives and the
// prices that follow, its equilibrium. Computed once per world from the settlements and the
// roads between them; nothing is stored. Production is in *people supplied*: a good's yield
// per km² of the land that gives it, over the settlement's cell and the ring around it, set
// against `size`, the people who need it. A good no maker within reach produces has no market.

Good :: enum u8 {
	Grain,
	Timber,
	Ore,
	Salt,
	Fish,
	Wool,
	Tools,
	Cloth,
}

// People supplied per km² of full yield (grain: the farmers' density; the rest likewise
// from what a km² of that land gives against a person's yearly need).
SUPPLY_PER_KM2 :: [Good]f64 {
	.Grain  = FARMER_DENSITY,
	.Timber = 20,
	.Ore    = 3,
	.Salt   = 30,
	.Fish   = 15,
	.Wool   = 6,
	.Tools  = 0, // made, not grown
	.Cloth  = 0,
}
BASE_PRICE :: [Good]f32 {
	.Grain  = 1,
	.Timber = 1.5,
	.Ore    = 4,
	.Salt   = 6,
	.Fish   = 2,
	.Wool   = 3,
	.Tools  = 10,
	.Cloth  = 8,
}
TOOLS_ERA :: 1 // smiths: the Bronze Age
CLOTH_ERA :: 0 // weavers
GRAIN_MIN_YIELD :: 0.05 // a cell yielding less than this grows no grain worth the name
RUGGED_M :: 400.0 // a cell this far above its lowest land neighbour has ore at all
PRICE_FLOOR :: 0.5 // of the base price: a glut
PRICE_CEILING :: 4.0 // of the base price: a famine (a market, never an absurd price)
ROAD_COST_PER_KM :: 0.0004 // of the base price, per km of road
OFFROAD_FACTOR :: 3.0 // a way without a road costs this many times as much
REACH_COST :: 1.0 // a maker whose goods cost more than the base price to carry is out of reach
GRAIN_SWING :: 0.12 // grain's price: this much above and below its mean through the year

Town :: struct {
	settlement: int, // index in the settlements given to economy_build
	cell:       int,
	size:       f32, // people: the need
	era:        int,
	production: [Good]f32, // people supplied
	price:      [Good]f32, // the year's mean normal price; 0 where there is no market
	market:     [Good]bool,
	harvest:    int, // month (0 is January) of the grain harvest
}

Economy :: struct {
	towns: []Town, // the standing settlements, in order
}

economy_destroy :: proc(e: ^Economy) {
	delete(e.towns)
	e^ = {}
}

@(private = "file")
is_forest :: proc(c: Koppen) -> f64 {
	#partial switch c {
	case .Af, .Am:
		return 1
	case .Aw, .Csb, .Dsb, .Dwb, .Dfb:
		return 0.5
	case .Cwa, .Cwb, .Cfa, .Cfb, .Cfc, .Dwa, .Dfa:
		return 0.8
	case .Csc, .Dsc, .Dwc, .Dfc, .Dsa, .Dsd, .Dwd, .Dfd:
		return 0.6
	}
	return 0
}

// produce is what the land around a cell gives, raw goods and the tools and cloth the era's
// smiths and weavers make of them: people supplied, per good.
produce :: proc(p: Planet, cell, era: int) -> (out: [Good]f32) {
	w, h := p.land.width, p.land.height
	cell_km := 40075.0 / f64(w)
	per := SUPPLY_PER_KM2
	raw: [Good]f64
	ci, cj := cell % w, cell / w
	for dj in -1 ..= 1 {
		jj := cj + dj
		if jj < 0 || jj >= h {continue}
		area := cell_km * cell_km * max(base.cos(climate_lat(h, jj) * PI / 180), 0.02)
		for di in -1 ..= 1 {
			k := jj * w + (ci + di + w) % w
			if !p.land.is_land[k] {continue}
			pr, t := 0.0, 0.0
			for m in 0 ..< 12 {
				pr += f64(p.precip.month[m][k])
				t += f64(p.temp.month[m][k]) / 10
			}
			t /= 12
			c := p.koppen[k]
			// Water and low land around the cell.
			coast, lowest, pit := false, f64(p.land.elevation[k]), true
			for ej in -1 ..= 1 {
				j2 := jj + ej
				if j2 < 0 || j2 >= h {continue}
				for ei in -1 ..= 1 {
					q := j2 * w + (ci + di + ei + w) % w
					if !p.land.is_land[q] {coast = true; continue}
					e := f64(p.land.elevation[q])
					lowest = min(lowest, e)
					if e < f64(p.land.elevation[k]) {pit = false}
				}
			}
			grain := min(pr / 1100, 1) * clamp((t + 5) / 20, 0, 1)
			if c == .BWh || c == .BWk || t < 5 || grain < GRAIN_MIN_YIELD {grain = 0}
			raw[.Grain] += grain * area * per[.Grain]
			raw[.Timber] += is_forest(c) * area * per[.Timber]
			rugged := f64(p.land.elevation[k]) - lowest
			if rugged >= RUGGED_M {
				raw[.Ore] += clamp(rugged / 1500, 0, 1) * area * per[.Ore]
			}
			if coast {
				raw[.Fish] += area * per[.Fish]
				raw[.Salt] += area * per[.Salt]
			} else if pit && (c == .BWh || c == .BWk || c == .BSk) {
				raw[.Salt] += 0.3 * area * per[.Salt] // a dry basin's salt pan
			}
			#partial switch c {
			case .BSk, .BSh, .Csa, .Csb:
				raw[.Wool] += area * per[.Wool]
			}
		}
	}
	for g in Good.Grain ..= Good.Wool {out[g] = f32(raw[g])}
	if era >= TOOLS_ERA {out[.Tools] = f32(min(raw[.Ore], raw[.Timber]))}
	if era >= CLOTH_ERA {out[.Cloth] = f32(raw[.Wool])}
	return
}

// harvest_month is the month grain comes in at a cell: after the rains in the tropics,
// else two months after the warmest.
harvest_month :: proc(p: Planet, cell: int) -> int {
	warm, wet, cold := 0, 0, 99.0
	for m in 0 ..< 12 {
		if p.temp.month[m][cell] > p.temp.month[warm][cell] {warm = m}
		if p.precip.month[m][cell] > p.precip.month[wet][cell] {wet = m}
		cold = min(cold, f64(p.temp.month[m][cell]) / 10)
	}
	return ((wet if cold > 18 else warm) + 2) % 12
}

// grain_season is grain's price against its mean in a town at `month_fraction` (months from
// the start of January): lowest right after the harvest, rising until the next.
grain_season :: proc(harvest: int, month_fraction: f64) -> f64 {
	since := math.mod(month_fraction - f64(harvest) + 24, 12)
	return 1 + GRAIN_SWING * (2 * since / 12 - 1)
}

// town_price is the normal price of a good in a town at a time of year, 0 where it has no
// market. Only grain, which cannot be kept from one harvest to the next, has a cycle.
town_price :: proc(t: Town, g: Good, month_fraction: f64) -> f32 {
	if !t.market[g] {return 0}
	if g == .Grain {return t.price[g] * f32(grain_season(t.harvest, month_fraction))}
	return t.price[g]
}

// economy_build computes the normal prices of the standing settlements among `settlements`:
// each good's price in a town is the cheaper of its own scarcity price (its production
// against its need) and what a maker with a surplus within reach asks plus the carriage on
// the roads (distance, cheaper where a road joins the two). It has no market where nobody
// within reach makes it.
economy_build :: proc(
	p: Planet,
	settlements: []Settlement,
	roads: []Road,
	allocator := context.allocator,
) -> Economy {
	n := 0
	for s in settlements {if s.ruined < 0 {n += 1}}
	e := Economy {
		towns = make([]Town, n, allocator),
	}
	at := make(map[int]int, n * 2, context.temp_allocator) // cell -> town
	cos_lat := make([]f64, n, context.temp_allocator)
	i := 0
	for s, si in settlements {
		if s.ruined >= 0 {continue}
		e.towns[i] = Town {
			settlement = si,
			cell       = s.cell,
			size       = s.size,
			era        = s.era,
			production = produce(p, s.cell, s.era),
			harvest    = harvest_month(p, s.cell),
		}
		cos_lat[i] = base.cos(s.lat * PI / 180)
		at[s.cell] = i
		i += 1
	}

	// Road carriage between joined towns: the road's length in km (0: none).
	road_km := make([]f32, n * n, context.temp_allocator)
	w := p.land.width
	cell_km := 40075.0 / f64(w)
	for r in roads {
		a, oka := at[r.cells[0]]
		b, okb := at[r.cells[len(r.cells) - 1]]
		if !oka || !okb {continue}
		km := 0.0
		for c in 1 ..< len(r.cells) {
			di := abs(r.cells[c] % w - r.cells[c - 1] % w)
			di = min(di, w - di)
			dj := r.cells[c] / w - r.cells[c - 1] / w
			cj := climate_lat(p.land.height, r.cells[c] / w)
			ex := f64(di) * max(base.cos(cj * PI / 180), 0.05)
			km += cell_km * math.sqrt(ex * ex + f64(dj * dj))
		}
		road_km[a * n + b], road_km[b * n + a] = f32(km), f32(km)
	}

	base_price := BASE_PRICE
	scarcity :: proc(t: Town, g: Good, base_price: f32) -> f32 {
		s := f64(t.production[g]) / max(f64(t.size), 1)
		return base_price * f32(clamp(math.sqrt(1 / s), PRICE_FLOOR, PRICE_CEILING))
	}
	lats := make([]f64, n, context.temp_allocator)
	lons := make([]f64, n, context.temp_allocator)
	for t, ti in e.towns {
		lats[ti] = climate_lat(p.land.height, t.cell / w)
		lons[ti] = (f64(t.cell % w) + 0.5) * 360 / f64(w) - 180
	}
	// What carrying a good between two towns costs, in base prices (0: out of reach).
	carriage := make([]f32, n * n, context.temp_allocator)
	for a in 0 ..< n {
		for b in a + 1 ..< n {
			km: f64
			rate := ROAD_COST_PER_KM
			if road_km[a * n + b] > 0 {
				km = f64(road_km[a * n + b])
			} else {
				dl := abs(lons[a] - lons[b])
				dl = min(dl, 360 - dl)
				dx := dl * math.PI / 180 * 0.5 * (cos_lat[a] + cos_lat[b])
				dy := (lats[a] - lats[b]) * math.PI / 180
				km = 6371 * math.sqrt(dx * dx + dy * dy)
				rate *= OFFROAD_FACTOR
			}
			c := f32(km * rate)
			if c <= REACH_COST {carriage[a * n + b], carriage[b * n + a] = c, c}
		}
	}
	for g in Good {
		for a in 0 ..< n {
			ta := &e.towns[a]
			best := f32(0)
			if ta.production[g] > 0 {
				best = scarcity(ta^, g, base_price[g])
				ta.market[g] = true
			}
			for b in 0 ..< n {
				if b == a || carriage[a * n + b] == 0 {continue}
				tb := e.towns[b]
				// Only a surplus is sold on.
				if f64(tb.production[g]) <= f64(tb.size) {continue}
				price := scarcity(tb, g, base_price[g]) + carriage[a * n + b] * base_price[g]
				if !ta.market[g] || price < best {best = price}
				ta.market[g] = true
			}
			if ta.market[g] {
				ta.price[g] = min(best, base_price[g] * PRICE_CEILING)
			}
		}
	}
	return e
}
