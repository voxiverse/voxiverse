package planet

import "common:base"
import "core:math"

// The economy, part 2 (docs/world.md, the economy): markets inside islands in detail, lazy
// outside, no seams. A *detailed* market (`Market`) holds the stocks of the towns of one
// island and ticks a month at a time: prices come from stocks, supply answers the price, and
// merchants carry goods along the ways while a gap they know of beats the cost of the way,
// counting the caravans already on the road (expectations). A *lazy* town has no state: its
// price is its normal price (part 1) times the response kernel of the world's known droughts
// (`Kernel`, measured once per world from the detailed model), carrying a short memory of the
// detailed price it left an island with, so entering and leaving never jump.
// Nothing here is random: the same economy, events and months give the same prices.

MONTH_RESTORE :: 0.5 // how fast supply closes a town's gap to its normal stock, per month
STOCK_MIN :: 0.05 // months of need
STOCK_MAX :: 8.0
RESERVE :: 0.5 // months of need a merchant leaves in the town he buys from
BAND_LOW :: 0.5 // the detailed price stays within these times its normal price
BAND_HIGH :: 4.0
SHIP_RATE :: 0.25 // of a gap's relative size, in the smaller town's monthly need
MERCHANT_SHARE :: 0.6 // of a way's carriage is the merchant's real cost; the rest is profit
MEMORY_MONTHS :: 3.0 // a price left an island with fades into the lazy one over this

DROUGHT_RADIUS_KM :: 400.0
DROUGHT_MONTHS :: 12.0
DROUGHT_STANDARD :: 0.2 // the yield lost at its centre: what the kernel is measured at
KERNEL_KM :: 100.0 // distance bin
KERNEL_DIST_BINS :: 20
KERNEL_AGES :: 72 // months after a drought's start

// Drought is a known event: grain yields fall within `DROUGHT_RADIUS_KM` of a place for a year.
Drought :: struct {
	lat, lon: f32,
	start:    f32, // month
	severity: f32, // yield lost at the centre (0.2 is the standard drought)
}

// Kernel is a drought's effect on grain's price by distance and months since it began, as the
// log of the ratio to the normal price at the standard severity.
Kernel :: struct {
	ln_ratio: [KERNEL_DIST_BINS * KERNEL_AGES]f32,
}

// Lazy_State is what a town carries out of an island: the relative gap between the detailed
// price and the lazy one when it left, fading.
Lazy_State :: struct {
	dev:  [Good]f32,
	left: f64, // month
}

Market :: struct {
	town:    []int, // the towns of the island (indices in the economy)
	local:   []int, // town -> index in `town`, -1 if outside
	stock:   [][Good]f32, // months of need
	inbound: [][Good]f32, // on the road, lands next month, in the buyer's months of need
	month:   f64,
}

market_destroy :: proc(m: ^Market) {
	delete(m.town)
	delete(m.local)
	delete(m.stock)
	delete(m.inbound)
	m^ = {}
}

km_between :: proc(alat, alon, blat, blon: f32) -> f64 {
	dl := abs(f64(alon - blon))
	dl = min(dl, 360 - dl)
	mid := 0.5 * (f64(alat) + f64(blat))
	dx := dl * math.PI / 180 * base.cos(mid * math.PI / 180)
	dy := f64(alat - blat) * math.PI / 180
	return 6371 * math.sqrt(dx * dx + dy * dy)
}

// grain_shock is the factor on a town's grain yield from the droughts at a month.
grain_shock :: proc(t: Town, ds: []Drought, month: f64) -> f64 {
	f := 1.0
	if t.production[.Grain] <= 0 {return f}
	for d in ds {
		age := month - f64(d.start)
		if age < 0 || age >= DROUGHT_MONTHS {continue}
		dist := km_between(t.lat, t.lon, d.lat, d.lon)
		if dist >= DROUGHT_RADIUS_KM {continue}
		f *= 1 - f64(d.severity) * (1 - dist / DROUGHT_RADIUS_KM)
	}
	return f
}

market_make :: proc(
	e: Economy,
	towns: []int,
	month: f64,
	allocator := context.allocator,
) -> Market {
	m := Market {
		town    = make([]int, len(towns), allocator),
		local   = make([]int, len(e.towns), allocator),
		stock   = make([][Good]f32, len(towns), allocator),
		inbound = make([][Good]f32, len(towns), allocator),
		month   = month,
	}
	copy(m.town, towns)
	for &v in m.local {v = -1}
	for ti, i in towns {
		m.local[ti] = i
		for g in Good {m.stock[i][g] = 1}
	}
	return m
}

// market_price is a town's detailed price of a good from its stock (and the caravans on the
// way, when `expected`).
market_price :: proc(e: Economy, m: Market, i: int, g: Good, expected := false) -> f32 {
	t := e.towns[m.town[i]]
	if !t.market[g] {return 0}
	s := m.stock[i][g]
	if expected {s += m.inbound[i][g]}
	c := max(s, STOCK_MIN)
	return town_price(t, g, m.month) * clamp(1 / c, BAND_LOW, BAND_HIGH)
}

// market_step ticks the island a month: caravans land, supply answers prices (a drought cuts
// grain's), merchants load where a gap beats the way's cost.
market_step :: proc(e: Economy, m: ^Market, ds: []Drought) {
	for i in 0 ..< len(m.town) {
		t := e.towns[m.town[i]]
		shock := grain_shock(t, ds, m.month)
		for g in Good {
			if !t.market[g] {continue}
			s := m.stock[i][g] + m.inbound[i][g]
			m.inbound[i][g] = 0
			sh := shock if g == .Grain else 1.0
			c := max(s, STOCK_MIN)
			s += MONTH_RESTORE * f32(sh / math.sqrt(f64(c)) - 1)
			m.stock[i][g] = clamp(s, 0, STOCK_MAX)
		}
	}
	base_price := BASE_PRICE
	for i in 0 ..< len(m.town) {
		ti := m.town[i]
		a := e.towns[ti]
		for l in e.links[e.link_first[ti]:e.link_first[ti + 1]] {
			j := m.local[l.to]
			if j < 0 {continue}
			b := e.towns[l.to]
			for g in Good {
				if !a.market[g] || !b.market[g] {continue}
				if m.stock[i][g] <= RESERVE {continue}
				pa := market_price(e, m^, i, g)
				pb := market_price(e, m^, j, g, true)
				gap := pb - pa - base_price[g] * l.carriage * MERCHANT_SHARE
				if gap <= 0 {continue}
				goods := f32(SHIP_RATE) * gap / pb * min(a.size, b.size)
				out := min(goods / a.size, m.stock[i][g] - RESERVE)
				m.stock[i][g] -= out
				m.inbound[j][g] += out * a.size / b.size
			}
		}
	}
	m.month += 1
}

// kernel_at is the log ratio at a distance and age (bilinear; 0 beyond the table).
kernel_at :: proc(k: Kernel, dist_km: f64, age: f64) -> f64 {
	if age < 0 {return 0}
	x := dist_km / KERNEL_KM
	if x >= KERNEL_DIST_BINS - 1 || age >= KERNEL_AGES - 1 {return 0}
	x0, a0 := int(x), int(age)
	fx, fa := x - f64(x0), age - f64(a0)
	at :: proc(k: Kernel, x, a: int) -> f64 {return f64(k.ln_ratio[x * KERNEL_AGES + a])}
	lo := at(k, x0, a0) * (1 - fa) + at(k, x0, a0 + 1) * fa
	hi := at(k, x0 + 1, a0) * (1 - fa) + at(k, x0 + 1, a0 + 1) * fa
	return lo * (1 - fx) + hi * fx
}

// lazy_price is a town's price outside every island: its normal price at the month, times
// what the known droughts did to grain, times what it left an island with, faded.
lazy_price :: proc(
	e: Economy,
	k: Kernel,
	mem: Lazy_State,
	ti: int,
	g: Good,
	month: f64,
	ds: []Drought,
) -> f32 {
	p := lazy_price_pure(e, k, ti, g, month, ds)
	if p == 0 {return 0}
	return p * f32(1 + f64(mem.dev[g]) * base.exp(-(month - mem.left) / MEMORY_MONTHS))
}

@(private = "file")
lazy_price_pure :: proc(
	e: Economy,
	k: Kernel,
	ti: int,
	g: Good,
	month: f64,
	ds: []Drought,
) -> f32 {
	t := e.towns[ti]
	p := town_price(t, g, month)
	if p == 0 || g != .Grain {return p}
	ln := 0.0
	for d in ds {
		dist := km_between(t.lat, t.lon, d.lat, d.lon)
		ln += kernel_at(k, dist, month - f64(d.start)) * f64(d.severity) / DROUGHT_STANDARD
	}
	return p * f32(base.exp(ln))
}

// market_enter starts the island's stocks from the lazy prices, so no price moves.
market_enter :: proc(e: Economy, k: Kernel, m: ^Market, mem: []Lazy_State, ds: []Drought) {
	for ti, i in m.town {
		t := e.towns[ti]
		for g in Good {
			m.inbound[i][g] = 0
			p := lazy_price(e, k, mem[ti], ti, g, m.month, ds)
			if p == 0 {continue}
			m.stock[i][g] = clamp(town_price(t, g, m.month) / p, 1 / BAND_HIGH, 1 / BAND_LOW)
		}
	}
}

// market_leave hands the towns back to the lazy model, remembering how far each price was
// from the lazy one, so it fades instead of jumping.
market_leave :: proc(e: Economy, k: Kernel, m: Market, mem: []Lazy_State, ds: []Drought) {
	for ti, i in m.town {
		mem[ti].left = m.month
		for g in Good {
			mem[ti].dev[g] = 0
			p := lazy_price_pure(e, k, ti, g, m.month, ds)
			if p == 0 {continue}
			mem[ti].dev[g] = market_price(e, m, i, g) / p - 1
		}
	}
}

// kernel_measure runs the detailed model over the whole economy once, with and without a
// standard drought at some towns, and keeps the average effect on grain's price by distance
// and age.
kernel_measure :: proc(e: Economy) -> (k: Kernel) {
	n := len(e.towns)
	if n == 0 {return}
	all := make([]int, n, context.temp_allocator)
	for i in 0 ..< n {all[i] = i}
	WARM :: 12
	run :: proc(e: Economy, all: []int, ds: []Drought, out: []f32) {
		m := market_make(e, all, 0, context.temp_allocator)
		for _ in 0 ..< WARM {market_step(e, &m, nil)}
		for a in 0 ..< KERNEL_AGES {
			for i in 0 ..< len(all) {out[a * len(all) + i] = market_price(e, m, i, .Grain)}
			market_step(e, &m, ds)
		}
	}
	base := make([]f32, KERNEL_AGES * n, context.temp_allocator)
	run(e, all, nil, base)
	got := make([]f32, KERNEL_AGES * n, context.temp_allocator)
	sum: [KERNEL_DIST_BINS * KERNEL_AGES]f64
	cnt: [KERNEL_DIST_BINS * KERNEL_AGES]f64
	centres := min(n, 6)
	for c in 0 ..< centres {
		ci := c * n / centres
		for ci < n - 1 && !e.towns[ci].market[.Grain] {ci += 1}
		t := e.towns[ci]
		d := Drought{t.lat, t.lon, WARM, DROUGHT_STANDARD}
		run(e, all, {d}, got)
		for i in 0 ..< n {
			dist := km_between(t.lat, t.lon, e.towns[i].lat, e.towns[i].lon)
			bin := int(dist / KERNEL_KM + 0.5)
			if bin >= KERNEL_DIST_BINS {continue}
			for a in 0 ..< KERNEL_AGES {
				b, v := base[a * n + i], got[a * n + i]
				if b <= 0 || v <= 0 {continue}
				sum[bin * KERNEL_AGES + a] += math.ln(f64(v / b))
				cnt[bin * KERNEL_AGES + a] += 1
			}
		}
	}
	for j in 0 ..< len(sum) {
		if cnt[j] > 0 {k.ln_ratio[j] = f32(sum[j] / cnt[j])}
	}
	return
}
