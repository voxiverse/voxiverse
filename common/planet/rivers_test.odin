package planet

import "core:testing"

@(private = "file")
Earth :: struct {
	rel: Relief,
	p:   Planet,
	r:   Rivers,
}

@(private = "file")
earth_rivers :: proc() -> (e: Earth, ok: bool) {
	e.rel, ok = relief_decode(#load("../../assets/planet/earth_relief.bin"))
	if !ok {return}
	e.p = planet_build(e.rel)
	e.r = rivers_build(e.p.land, e.p.precip)
	return
}

@(private = "file")
earth_destroy :: proc(e: ^Earth) {
	rivers_destroy(&e.r)
	planet_destroy(&e.p)
	relief_destroy(&e.rel)
}

// test_rivers_reach_the_sea: from 20 river cells spread over the land, following
// the routing ends in the ocean or a lake, never in a dead end or a loop.
@(test)
test_rivers_reach_the_sea :: proc(t: ^testing.T) {
	e, ok := earth_rivers()
	testing.expect(t, ok)
	if !ok {return}
	defer earth_destroy(&e)
	l, r := e.p.land, e.r
	n := l.width * l.height

	rivers := make([dynamic]int, context.temp_allocator)
	for k in 0 ..< n {
		if l.is_land[k] && river_width(r.flow[k]) > 0 {append(&rivers, k)}
	}
	testing.expect(t, len(rivers) > 20)
	checked := 0
	for s in 0 ..< 20 {
		k := rivers[s * len(rivers) / 20]
		steps := 0
		for l.is_land[k] && r.next[k] >= 0 && steps <= n {
			k = int(r.next[k])
			steps += 1
		}
		testing.expectf(t, steps <= n, "a river from cell %d loops", rivers[s * len(rivers) / 20])
		testing.expectf(
			t,
			!l.is_land[k],
			"a river from cell %d ends on land at %d",
			rivers[s * len(rivers) / 20],
			k,
		)
		checked += 1
	}
	testing.expect_value(t, checked, 20)

	// Every land cell drains, and flow only grows downstream.
	for k in 0 ..< n {
		if !l.is_land[k] {continue}
		nx := int(r.next[k])
		if nx < 0 {testing.fail_now(t, "a land cell drains nowhere")}
		if l.is_land[nx] && r.flow[nx] < r.flow[k] {testing.fail_now(t, "flow shrinks downstream")}
		if r.filled[k] <
		   l.elevation[k] {testing.fail_now(t, "the filled surface is under the land")}
	}
}

// The great rivers appear where they are: the biggest flow in the Amazon's basin is
// near its mouth and is wider than a creek.
@(test)
test_great_rivers :: proc(t: ^testing.T) {
	e, ok := earth_rivers()
	testing.expect(t, ok)
	if !ok {return}
	defer earth_destroy(&e)
	best :: proc(e: Earth, lat0, lat1, lon0, lon1: f64) -> f32 {
		w, h := e.r.width, e.r.height
		cell :: proc(lat, lon: f64, w, h: int) -> (i, j: int) {
			return int((lon + 180) / 360 * f64(w)), int((90 - lat) / 180 * f64(h))
		}
		i0, j1 := cell(lat0, lon0, w, h)
		i1, j0 := cell(lat1, lon1, w, h)
		f: f32
		for j in j0 ..= j1 {
			for i in i0 ..= i1 {f = max(f, e.r.flow[j * e.r.width + i])}
		}
		return f
	}
	// Amazon's lower reach, Nile in Egypt, Mississippi's lower reach, Volga's (the Yangtze's flow is still too small on part 1's rain: left for a later part).
	for box, name in ([4][4]f64{{-4, 0, -58, -50}, {24, 31, 30, 34}, {29, 34, -92, -88}, {45, 50, 43, 49}}) {
		f := best(e, box[0], box[1], box[2], box[3])
		testing.expectf(t, river_width(f) >= 8, "great river %d has flow %v", name, f)
	}
}
