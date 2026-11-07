package tests

import "core:testing"
import "core:time"

import "common:planet"

// The economy's equilibrium for 600 towns takes under 100 ms (docs/world.md).
@(test)
test_economy_600_towns_within_budget :: proc(t: ^testing.T) {
	r, _ := planet.relief_decode(#load("../assets/planet/earth_relief.bin"))
	defer planet.relief_destroy(&r)
	p := planet.planet_build(r)
	defer planet.planet_destroy(&p)

	w, h := p.land.width, p.land.height
	list := make([dynamic]planet.Settlement)
	defer delete(list)
	for k := 0; k < w * h && len(list) < 600; k += 1 {
		if !p.land.is_land[k] || k % 7 != 0 {continue}
		append(
			&list,
			planet.Settlement {
				cell = k,
				lat = planet.climate_lat(h, k / w),
				lon = (f64(k % w) + 0.5) * 360 / f64(w) - 180,
				size = 2000,
				era = 1 + k % 2,
				ruined = -1,
			},
		)
	}
	testing.expect_value(t, len(list), 600)
	start := time.tick_now()
	e := planet.economy_build(p, list[:], nil)
	ms := time.duration_milliseconds(time.tick_since(start))
	defer planet.economy_destroy(&e)
	testing.expectf(t, ms < 100, "600 towns took %v ms", ms)
}

// The detailed markets of an island of 50 towns take under 0.5 ms a tick (docs/world.md).
@(test)
test_island_markets_within_budget :: proc(t: ^testing.T) {
	r, _ := planet.relief_decode(#load("../assets/planet/earth_relief.bin"))
	defer planet.relief_destroy(&r)
	p := planet.planet_build(r)
	defer planet.planet_destroy(&p)

	w, h := p.land.width, p.land.height
	list := make([dynamic]planet.Settlement)
	defer delete(list)
	for k := 0; k < w * h && len(list) < 600; k += 1 {
		if !p.land.is_land[k] || k % 7 != 0 {continue}
		append(
			&list,
			planet.Settlement {
				cell = k,
				lat = planet.climate_lat(h, k / w),
				lon = (f64(k % w) + 0.5) * 360 / f64(w) - 180,
				size = 2000,
				era = 1 + k % 2,
				ruined = -1,
			},
		)
	}
	e := planet.economy_build(p, list[:], nil)
	defer planet.economy_destroy(&e)

	// 50 towns that are neighbours: the first 50 of the land cells' order.
	island: [50]int
	for i in 0 ..< 50 {island[i] = i}
	m := planet.market_make(e, island[:], 0)
	defer planet.market_destroy(&m)
	TICKS :: 240
	start := time.tick_now()
	for _ in 0 ..< TICKS {planet.market_step(e, &m, nil)}
	ms := time.duration_milliseconds(time.tick_since(start)) / TICKS
	testing.expectf(t, ms < 0.5, "an island tick took %v ms", ms)

	start = time.tick_now()
	k := planet.kernel_measure(e)
	took := time.duration_milliseconds(time.tick_since(start))
	_ = k
	testing.expectf(t, took < 2000, "measuring the kernel of 600 towns took %v ms", took)
}
