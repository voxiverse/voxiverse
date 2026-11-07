package planet

import "core:testing"

@(private = "file")
Fixture :: struct {
	p: Planet,
	r: Relief,
}

// A land cell of a class, with (coast) or without ocean in the 3x3 around it.
// A cell whose whole 3x3 is desert.
@(private = "file")
find_desert :: proc(p: Planet) -> int {
	w, h := p.land.width, p.land.height
	for k in w + 1 ..< w * (h - 1) - 1 {
		all := true
		for dj in -1 ..= 1 {
			for di in -1 ..= 1 {
				c := p.koppen[k + dj * w + di]
				if c != .BWh && c != .BWk {all = false}
			}
		}
		if all && k % w > 0 && k % w < w - 1 {return k}
	}
	return -1
}

@(private = "file")
find_cell :: proc(p: Planet, want: []Koppen, coast: bool) -> int {
	w, h := p.land.width, p.land.height
	for k in 0 ..< w * h {
		if !p.land.is_land[k] {continue}
		ok := false
		for c in want {if p.koppen[k] == c {ok = true}}
		if !ok {continue}
		i, j := k % w, k / w
		if j == 0 || j == h - 1 {continue}
		wet := false
		for dj in -1 ..= 1 {
			for di in -1 ..= 1 {
				if !p.land.is_land[(j + dj) * w + (i + di + w) % w] {wet = true}
			}
		}
		if wet == coast {return k}
	}
	return -1
}

@(test)
test_production_follows_the_land :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)

	desert := find_desert(p)
	testing.expect(t, desert >= 0)
	// A desert town far from any coast: no grain, no fish.
	d := produce(p, desert, 2)
	testing.expect_value(t, d[.Grain], 0)
	testing.expect_value(t, d[.Fish], 0)

	coastal := find_cell(p, {.Cfb, .Cfa, .Csa, .Af}, true)
	testing.expect(t, coastal >= 0)
	c := produce(p, coastal, 2)
	testing.expect(t, c[.Fish] > 0)
	testing.expect(t, c[.Salt] > 0)

	// The Stone Age has no smiths.
	for k in 0 ..< p.land.width * p.land.height {
		if !p.land.is_land[k] {continue}
		if produce(p, k, 2)[.Tools] > 0 {
			testing.expect_value(t, produce(p, k, 0)[.Tools], 0)
			break
		}
	}
}

@(private = "file")
town_at :: proc(p: Planet, cell, era: int, size: f32) -> Settlement {
	w, h := p.land.width, p.land.height
	return Settlement {
		cell = cell,
		lat = climate_lat(h, cell / w),
		lon = (f64(cell % w) + 0.5) * 360 / f64(w) - 180,
		size = size,
		era = era,
		ruined = -1,
	}
}

@(test)
test_no_maker_no_market :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)

	// One desert town alone: nobody makes grain or fish within reach.
	desert := find_desert(p)
	e := economy_build(p, {town_at(p, desert, 2, 1000)}, nil)
	defer economy_destroy(&e)
	testing.expect_value(t, len(e.towns), 1)
	tw := e.towns[0]
	testing.expect(t, !tw.market[.Grain])
	testing.expect_value(t, town_price(tw, .Grain, 3), 0)
	testing.expect(t, !tw.market[.Fish])
	base_price := BASE_PRICE
	for g in Good {
		if tw.market[g] {
			testing.expect(t, tw.price[g] > 0)
			testing.expect(t, tw.price[g] <= base_price[g] * PRICE_CEILING)
		}
	}
}

@(test)
test_grain_follows_the_harvest :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)

	checked := 0
	for want in ([][]Koppen{{.Cfb}, {.Cfa}, {.Dfb}, {.Af}, {.Csa}}) {
		cell := find_cell(p, want, true)
		if cell < 0 {continue}
		e := economy_build(p, {town_at(p, cell, 2, 100)}, nil)
		defer economy_destroy(&e)
		tw := e.towns[0]
		if !tw.market[.Grain] {continue}
		low, high := 0, 0
		prices: [12]f32
		for m in 0 ..< 12 {
			prices[m] = town_price(tw, .Grain, f64(m) + 0.5)
			if prices[m] < prices[low] {low = m}
			if prices[m] > prices[high] {high = m}
		}
		testing.expect_value(t, low, tw.harvest)
		testing.expect_value(t, high, (tw.harvest + 11) % 12)
		// The year's mean is the normal price; the swing is a season's, not a famine's.
		sum: f32
		for v in prices {sum += v}
		testing.expect(t, abs(sum / 12 - tw.price[.Grain]) < 0.001 * tw.price[.Grain])
		testing.expect(t, prices[high] / prices[low] < 1.3)
		// Other goods keep.
		testing.expect_value(t, town_price(tw, .Salt, 1), town_price(tw, .Salt, 7))
		checked += 1
	}
	testing.expect(t, checked > 0)
}

@(test)
test_equilibrium_is_deterministic :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)

	list := make([dynamic]Settlement)
	defer delete(list)
	for k := 0; k < p.land.width * p.land.height && len(list) < 200; k += 1 {
		if p.land.is_land[k] && k % 7 == 0 {append(&list, town_at(p, k, 1 + k % 2, 2000))}
	}
	e := economy_build(p, list[:], nil)
	defer economy_destroy(&e)
	again := economy_build(p, list[:], nil)
	defer economy_destroy(&again)
	for tw, i in e.towns {testing.expect(t, tw == again.towns[i])}
}
