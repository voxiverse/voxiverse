package island

import "core:math"
import "core:testing"

@(private = "file")
near :: proc(a, b, tol: f64) -> bool {return math.abs(a - b) <= tol * math.abs(b)}

@(test)
test_walking_away_and_back_shows_no_seam :: proc(t: ^testing.T) {
	toy: Toy_Growth
	defer toy_destroy(&toy)
	w := Lazy_World {
		sys = toy_system(&toy),
	}
	defer lazy_destroy(&w)
	c := Chunk{3, 0, 4}
	day := 5.0
	dt := 0.01
	// Detailed from day 5 to 25, away until day 60, detailed again to 70.
	lazy_sync(&w, {c}, nil, nil, day)
	for _ in 0 ..< 2000 {lazy_step(&w, dt); day += dt}
	lazy_sync(&w, nil, {c}, nil, day)
	testing.expect_value(t, len(toy.values), 0)
	day = 60
	lazy_sync(&w, {c}, nil, nil, day)
	for _ in 0 ..< 1000 {lazy_step(&w, dt); day += dt}
	want := toy_grow(TOY_START, day)
	testing.expect(t, near(toy.values[c], want, 0.01), "value after leaving and returning")
	// Outside detail the lazy state is the same.
	lazy_sync(&w, nil, {c}, nil, day)
	got := lazy_state(&w, c, nil, day + 30)
	testing.expect(t, near(got[0], toy_grow(TOY_START, day + 30), 0.01))
}

@(test)
test_region_outside_every_island_costs_nothing :: proc(t: ^testing.T) {
	toy: Toy_Growth
	defer toy_destroy(&toy)
	w := Lazy_World {
		sys = toy_system(&toy),
	}
	defer lazy_destroy(&w)
	lazy_step(&w, 0.05)
	testing.expect_value(t, len(w.detailed), 0)
	testing.expect_value(t, len(toy.values), 0)
	lazy_sync(&w, {{0, 0, 0}}, nil, nil, 1)
	lazy_sync(&w, nil, {{0, 0, 0}}, nil, 1)
	before := toy.values[{0, 0, 0}]
	lazy_step(&w, 0.05)
	testing.expect_value(t, len(toy.values), 0)
	testing.expect_value(t, before, 0)
}

@(test)
test_influence_arrives_at_finite_speed :: proc(t: ^testing.T) {
	toy: Toy_Growth
	defer toy_destroy(&toy)
	w := Lazy_World {
		sys = toy_system(&toy),
	}
	defer lazy_destroy(&w)
	// 1 000 blocks east of the region's centre, on day 10.
	c := Chunk{0, 0, 0}
	cen := region_center(c)
	iv := Influence {
		day    = 10,
		place  = {i32(cen.x) + 1000, 0, i32(cen.z)},
		amount = 20,
	}
	days := 1000.0 / TOY_SPEED // 10
	base := lazy_state(&w, c, nil, 30)[0]
	before := lazy_state(&w, c, {iv}, 10 + days - 0.1)[0]
	testing.expect_value(t, before, lazy_state(&w, c, nil, 10 + days - 0.1)[0])
	after := lazy_state(&w, c, {iv}, 10 + days + 0.1)[0]
	testing.expect(t, after > lazy_state(&w, c, nil, 10 + days + 0.1)[0] + 10, "arrived")
	testing.expect(t, lazy_state(&w, c, {iv}, 30)[0] > base)
	// An influence from the future (after the asked day) is never seen.
	future := Influence {
		day    = 40,
		place  = iv.place,
		amount = 50,
	}
	testing.expect_value(t, lazy_state(&w, c, {future}, 30)[0], base)
}
