package planet

import "core:slice"
import "core:testing"

// A world's worth of towns: land cells evenly spread over the whole planet, sized by the cell.
@(private = "file")
fixture_towns :: proc(p: Planet, limit: int) -> [dynamic]Settlement {
	list := make([dynamic]Settlement)
	w, h := p.land.width, p.land.height
	land := 0
	for k in 0 ..< w * h {if p.land.is_land[k] {land += 1}}
	stride := max(land / limit, 1)
	seen := 0
	for k in 0 ..< w * h {
		if !p.land.is_land[k] {continue}
		seen += 1
		if seen % stride == 0 {append(&list, town_at(p, k, 1 + k % 2, f32(500 + k % 7 * 500)))}
	}
	return list
}

@(private = "file")
median :: proc(v: []f32) -> f32 {
	slice.sort(v)
	return v[len(v) / 2] if len(v) > 0 else 0
}

@(test)
test_detailed_prices_stay_at_normal :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)
	list := fixture_towns(p, 150)
	defer delete(list)
	e := economy_build(p, list[:], nil)
	defer economy_destroy(&e)

	all := make([]int, len(e.towns))
	defer delete(all)
	for i in 0 ..< len(all) {all[i] = i}
	m := market_make(e, all, 0)
	defer market_destroy(&m)
	ratios: [Good][dynamic]f32
	defer for g in Good {delete(ratios[g])}
	for step in 0 ..< 120 {
		market_step(e, &m, nil)
		if step < 24 {continue}
		for i in 0 ..< len(all) {
			for g in Good {
				tp := town_price(e.towns[i], g, m.month)
				if tp > 0 {append(&ratios[g], market_price(e, m, i, g) / tp)}
			}
		}
	}
	for g in Good {
		if len(ratios[g]) == 0 {continue}
		med := median(ratios[g][:])
		testing.expectf(t, abs(med - 1) < 0.05, "%v: the detailed median is %v of normal", g, med)
	}
}

@(test)
test_best_ordinary_trip_pays_a_fair_margin :: proc(t: ^testing.T) {
	p, r := chronicle_planet()
	defer relief_destroy(&r)
	defer planet_destroy(&p)
	list := fixture_towns(p, 150)
	defer delete(list)
	e := economy_build(p, list[:], nil)
	defer economy_destroy(&e)

	base_price := BASE_PRICE
	best := f32(0)
	for a in 0 ..< len(e.towns) {
		for l in e.links[e.link_first[a]:e.link_first[a + 1]] {
			for g in Good {
				pa, pb := e.towns[a].price[g], e.towns[l.to].price[g]
				if pa == 0 || pb == 0 {continue}
				cost := pa + base_price[g] * l.carriage * MERCHANT_SHARE
				best = max(best, (pb - cost) / cost)
			}
		}
	}
	testing.expectf(t, best >= 0.2 && best <= 0.6, "the best trip pays %v", best)
}

@(private = "file")
Rig :: struct {
	e:       Economy,
	k:       Kernel,
	all:     []int,
	list:    [dynamic]Settlement,
	p:       Planet,
	r:       Relief,
	drought: Drought,
	centre:  int,
}

@(private = "file")
rig_make :: proc() -> (g: Rig) {
	g.p, g.r = chronicle_planet()
	g.list = fixture_towns(g.p, 150)
	g.e = economy_build(g.p, g.list[:], nil)
	g.k = kernel_measure(g.e)
	g.all = make([]int, len(g.e.towns))
	for i in 0 ..< len(g.all) {g.all[i] = i}
	g.centre = -1
	for tw, i in g.e.towns {
		if tw.market[.Grain] && tw.production[.Grain] > 0 {g.centre = i; break}
	}
	c := g.e.towns[g.centre]
	g.drought = Drought{c.lat, c.lon, 12, DROUGHT_STANDARD}
	return
}

@(private = "file")
rig_destroy :: proc(g: ^Rig) {
	economy_destroy(&g.e)
	delete(g.all)
	delete(g.list)
	relief_destroy(&g.r)
	planet_destroy(&g.p)
}

@(test)
test_drought_raises_grain_and_ripples :: proc(t: ^testing.T) {
	g := rig_make()
	defer rig_destroy(&g)
	e := g.e
	quiet := market_make(e, g.all, 0)
	defer market_destroy(&quiet)
	hit := market_make(e, g.all, 0)
	defer market_destroy(&hit)
	for _ in 0 ..< 12 {
		market_step(e, &quiet, nil)
		market_step(e, &hit, nil)
	}
	for _ in 0 ..< 6 {
		market_step(e, &quiet, nil)
		market_step(e, &hit, {g.drought})
	}
	c := e.towns[g.centre]
	near, far := 0.0, 0.0
	near_n, far_n := 0, 0
	for i in 0 ..< len(e.towns) {
		tw := e.towns[i]
		if !tw.market[.Grain] {continue}
		up := f64(market_price(e, hit, i, .Grain) / market_price(e, quiet, i, .Grain))
		d := km_between(c.lat, c.lon, tw.lat, tw.lon)
		if d < 300 {near += up; near_n += 1}
		if d > 600 && d < 1500 {far += up; far_n += 1}
		if i == g.centre {
			testing.expectf(t, up > 1.2, "the drought's own town: grain x%v", up)
		}
	}
	testing.expect(t, near_n > 0)
	near /= f64(near_n)
	testing.expectf(t, near > 1.1, "grain near the drought: x%v", near)
	if far_n > 0 {
		far /= f64(far_n)
		testing.expectf(t, far < near, "the ripple fades: near x%v, far x%v", near, far)
		testing.expectf(t, far >= 0.999, "the ripple never lowers grain: x%v", far)
	}
}

@(test)
test_lazy_grain_follows_the_detailed_drought :: proc(t: ^testing.T) {
	g := rig_make()
	defer rig_destroy(&g)
	e := g.e
	// The drought's own town and the towns within 1 000 km of it, in detail.
	c := e.towns[g.centre]
	near := make([dynamic]int)
	defer delete(near)
	for tw, i in e.towns {
		if km_between(c.lat, c.lon, tw.lat, tw.lon) < 1000 && tw.market[.Grain] {append(&near, i)}
	}
	// The kernel is measured over the whole economy; the check is against the same economy
	// run whole (the island's edge is the seam test's business).
	m := market_make(e, g.all, 0)
	defer market_destroy(&m)
	for _ in 0 ..< 12 {market_step(e, &m, nil)}
	errs := make([dynamic]f32)
	defer delete(errs)
	for age in 0 ..< 36 {
		if age % 6 == 3 {
			for i in near[:] {
				lazy := lazy_price(e, g.k, {}, i, .Grain, m.month, {g.drought})
				full := market_price(e, m, i, .Grain)
				append(&errs, abs(lazy / full - 1))
			}
		}
		market_step(e, &m, {g.drought})
	}
	med := median(errs[:])
	testing.expectf(t, med < 0.1, "lazy grain misses the detailed model by %v (median)", med)
}

@(test)
test_island_seams_do_not_jump :: proc(t: ^testing.T) {
	g := rig_make()
	defer rig_destroy(&g)
	e := g.e
	ds := []Drought{g.drought}
	island := make([dynamic]int)
	defer delete(island)
	c := e.towns[g.centre]
	for tw, i in e.towns {
		if len(island) < 50 && km_between(c.lat, c.lon, tw.lat, tw.lon) < 2500 {append(&island, i)}
	}
	mem := make([]Lazy_State, len(e.towns))
	defer delete(mem)

	m := market_make(e, island[:], 14)
	defer market_destroy(&m)
	// Entering: no price differs from the lazy one by more than a grain month's change.
	before := make([dynamic][Good]f32)
	defer delete(before)
	for ti in island[:] {
		row: [Good]f32
		for good in Good {row[good] = lazy_price(e, g.k, mem[ti], ti, good, m.month, ds)}
		append(&before, row)
	}
	market_enter(e, g.k, &m, mem, ds)
	moves := make([dynamic]f32)
	defer delete(moves)
	jump := f32(0)
	for _, i in island[:] {
		for good in Good {
			if before[i][good] == 0 {continue}
			jump = max(jump, abs(market_price(e, m, i, good) / before[i][good] - 1))
		}
	}
	// The detailed model's own change from one month to the next (grain's, the median).
	last := make([]f32, len(island))
	defer delete(last)
	for i in 0 ..< len(island) {last[i] = market_price(e, m, i, .Grain)}
	for _ in 0 ..< 36 {
		market_step(e, &m, ds)
		for i in 0 ..< len(island) {
			p := market_price(e, m, i, .Grain)
			if p > 0 && last[i] > 0 {append(&moves, abs(p / last[i] - 1))}
			last[i] = p
		}
	}
	own := median(moves[:])
	testing.expectf(
		t,
		jump <= own,
		"entering jumps %v, the model's own monthly change is %v",
		jump,
		own,
	)

	// Leaving: the lazy price carries on from the detailed one, and meets the lazy model.
	market_leave(e, g.k, m, mem, ds)
	jump = 0
	for ti, i in island[:] {
		for good in Good {
			d := market_price(e, m, i, good)
			if d == 0 {continue}
			l := lazy_price(e, g.k, mem[ti], ti, good, m.month, ds)
			jump = max(jump, abs(l / d - 1))
		}
	}
	testing.expectf(
		t,
		jump <= own,
		"leaving jumps %v, the model's own monthly change is %v",
		jump,
		own,
	)
	// A year later nothing of the island is left in a town's price but the lazy model's.
	for ti in island[:] {
		for good in Good {
			l := lazy_price(e, g.k, mem[ti], ti, good, m.month + 36, ds)
			p := lazy_price(e, g.k, {}, ti, good, m.month + 36, ds)
			testing.expect(t, abs(l - p) <= 0.001 * max(p, 0.001))
		}
	}
}
