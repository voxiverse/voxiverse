package sandbox_server

import "core:os"
import "core:testing"

import "games:sandbox"
import "server:core"
import "server:playtest"

// The economy the sandbox holds: arriving near a settlement builds its market, months step it
// as the model does, a save gives the same prices, and a market left and come back to after a
// year is the lazy one. (The harness's world is flat and small; told it is the planet's, it
// has the planet's towns, which the tests stand near by their latitude and longitude.)

Economy_Rig :: struct {
	rig:      ^playtest.Rig,
	s:        ^core.Server,
	w:        ^core.World,
	observer: [2]f64, // a town with a market
	town:     int,
}

// economy_rig: the sandbox started on the harness's world (by the test: GAME's lists live
// in the frame that names it), the world told it is the planet's, its economy built; the
// observer is a town's place.
economy_rig :: proc(t: ^testing.T, rig: ^playtest.Rig) -> (r: Economy_Rig, ok: bool) {
	r.rig = rig
	r.s = playtest.srv(rig)
	r.w = r.s.home
	r.w.params.planet = 1
	ok = economy_find(t, &r)
	return
}

economy_find :: proc(t: ^testing.T, r: ^Economy_Rig) -> bool {
	economy_sync(r.s, r.w, nil)
	we := world_of(r.w).economy
	if !testing.expect(t, we != nil && we.built && len(we.economy.towns) > 0, "no towns") {
		return false
	}
	r.town = -1
	for tw, i in we.economy.towns {
		if tw.market[.Grain] && tw.production[.Grain] > 0 {r.town = i; break}
	}
	if !testing.expect(t, r.town >= 0) {return false}
	tw := we.economy.towns[r.town]
	r.observer = {f64(tw.lat), f64(tw.lon)}
	return true
}

@(private = "file")
prices :: proc(w: ^core.World) -> (out: [dynamic][sandbox.Good]f32) {
	for i in 0 ..< len(world_of(w).economy.economy.towns) {
		row: [sandbox.Good]f32
		for g in sandbox.Good {row[g] = economy_price(w, i, g)}
		append(&out, row)
	}
	return
}

@(test)
test_economy_arrival_builds_a_market :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	r, ok := economy_rig(t, rig)
	if !ok {return}
	we := world_of(r.w).economy
	testing.expect(t, !we.resident, "a market with nobody near")
	economy_sync(r.s, r.w, {r.observer})
	if !testing.expect(t, we.resident, "arriving built no market") {return}
	i := we.market.local[r.town]
	testing.expect(t, i >= 0, "the town near the observer is not in detail")
	testing.expect(t, sandbox.market_price(we.economy, we.market, i, .Grain) > 0)
	// A town far from everyone is not.
	far := 0
	for tw in we.economy.towns {
		if sandbox.km_between(tw.lat, tw.lon, f32(r.observer.x), f32(r.observer.y)) >
		   2 * ECONOMY_RADIUS_KM {far += 1}
	}
	testing.expect_value(t, len(we.market.town) + far <= len(we.economy.towns), true)
	// Leaving drops it.
	economy_sync(r.s, r.w, nil)
	testing.expect(t, !we.resident, "the market stayed with nobody near")
}

@(test)
test_economy_ten_months_step_as_the_model_does :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	r, ok := economy_rig(t, rig)
	if !ok {return}
	w, we := r.w, world_of(r.w).economy
	w.clock = 100 * MONTH_DAYS
	economy_sync(r.s, w, {r.observer})
	if !testing.expect(t, we.resident) {return}

	// The same island by hand: entered at the same month, stepped ten times.
	towns := make([]int, len(we.market.town))
	defer delete(towns)
	copy(towns, we.market.town)
	m := sandbox.market_make(we.economy, towns, we.market.month)
	defer sandbox.market_destroy(&m)
	sandbox.market_enter(we.economy, we.kernel, &m, we.mem, nil)
	n := sandbox.news_make(we.economy, m)
	defer sandbox.news_destroy(&n)
	c: sandbox.Convoy
	defer sandbox.convoy_destroy(&c)
	for _ in 0 ..< 10 {sandbox.convoy_step(we.economy, &m, n, &c, nil)}

	w.clock = 110 * MONTH_DAYS
	economy_sync(r.s, w, {r.observer})
	testing.expect_value(t, we.market.month, 110)
	testing.expect_value(t, m.month, 110)
	for ti, i in towns {
		for g in sandbox.Good {
			want := sandbox.market_price(we.economy, m, i, g)
			got := economy_price(w, ti, g)
			testing.expectf(t, got == want, "town %d %v: %v, the model says %v", ti, g, got, want)
		}
	}
}

@(test)
test_economy_save_and_load_give_the_same_prices :: proc(t: ^testing.T) {
	dir :: "build/tmp/sandbox_economy_save"
	os.remove_all(dir)
	defer os.remove_all(dir)
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
	r, ok := economy_rig(t, rig)
	if !ok {
		playtest.stop(rig)
		return
	}
	w := r.w
	w.clock = 50 * MONTH_DAYS
	economy_sync(r.s, w, {r.observer})
	w.clock = 54 * MONTH_DAYS
	economy_sync(r.s, w, {r.observer})
	before := prices(w)
	defer delete(before)
	key := world_of(w).economy.key
	testing.expect(t, world_of(w).economy.resident)
	w.params.planet = 0 // (see the reopening below)
	observer := r.observer
	playtest.stop(rig) // (the last save writes the file)

	rig2 := new(playtest.Rig)
	defer free(rig2)
	if !playtest.start(t, rig2, GAME, {save_dir = dir}) {return}
	defer playtest.stop(rig2)
	s2 := playtest.srv(rig2)
	w2 := s2.home
	// (The planet's terrain is a place the test player cannot land on, so the world is
	// reopened as a flat one and told it is the planet's, then reads its file as it does
	// when it opens.)
	w2.params.planet = 1
	economy_load(w2)
	we2 := world_of(w2).economy
	if !testing.expect(t, we2 != nil && we2.has_saved, "the file was not read") {return}
	testing.expect_value(t, economy_month(w2.clock), 54)
	economy_sync(s2, w2, {observer})
	testing.expect_value(t, we2.key, key)
	after := prices(w2)
	defer delete(after)
	if !testing.expect_value(t, len(after), len(before)) {return}
	for row, i in before {
		for g in sandbox.Good {
			testing.expectf(
				t,
				after[i][g] == row[g],
				"town %d %v: %v then %v",
				i,
				g,
				row[g],
				after[i][g],
			)
		}
	}
}

@(test)
test_economy_back_after_a_year_matches_the_lazy_price :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	r, ok := economy_rig(t, rig)
	if !ok {return}
	w, we := r.w, world_of(r.w).economy
	w.clock = 20 * MONTH_DAYS
	economy_sync(r.s, w, {r.observer})
	w.clock = 26 * MONTH_DAYS
	economy_sync(r.s, w, {r.observer})
	economy_sync(r.s, w, nil) // gone
	testing.expect(t, !we.resident)
	w.clock = 38 * MONTH_DAYS // a year on
	before := prices(w) // what the lazy model says now
	defer delete(before)
	economy_sync(r.s, w, {r.observer}) // back
	if !testing.expect(t, we.resident) {return}
	worst := f32(0)
	for ti in we.market.town {
		for g in sandbox.Good {
			if before[ti][g] == 0 {continue}
			worst = max(worst, abs(economy_price(w, ti, g) / before[ti][g] - 1))
		}
	}
	testing.expectf(t, worst < 0.05, "a year away, a price moved %v on return", worst)
}

@(test)
test_economy_file_damage_is_refused :: proc(t: ^testing.T) {
	we := World_Economy {
		key = 7,
	}
	defer delete(we.mem)
	data := economy_encode(&we, context.temp_allocator)
	good, ok := economy_decode(data)
	testing.expect(t, ok, "an empty economy does not read back")
	saved_destroy(&good)
	testing.expect(t, !economy_check(data[:len(data) - 1]), "a cut file reads")
	bad := make([]u8, len(data), context.temp_allocator)
	copy(bad, data)
	bad[9] ~= 1
	testing.expect(t, !economy_check(bad), "a flipped bit reads")
	testing.expect(t, !economy_check(nil))
}
