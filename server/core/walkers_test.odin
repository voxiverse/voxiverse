package core

import "core:testing"

import "common:game"

// The walkers a game steers (walkers.odin), on a stepped server in the flat world (its
// ground is y -1: a walker stands in y 0), with a game whose pack has one steered kind,
// a creep that does not jump.

@(private = "file")
WALKERS_PACK :: `{"format": 1, "namespace": "walkers", "version": "1.0.0", "title": "Walkers", "requires": ["voxiverse"]}`
@(private = "file")
WALKERS_KINDS :: `{
	"creep": {"box": [0.6, 0.9], "health": 5, "hittable": true, "physics": "walker",
	          "walker": {"walk_speed": 4, "run_speed": 4, "jump": 0, "step": 0},
	          "brain": "steered", "model": {"box": [200, 60, 60]}}
}`

// The ground the tests walk on.
@(private = "file")
GROUND :: Box{{-16, 0, -16}, {24, 3, 16}}

// Rig: the harness and the game's pack files, which live as long as it.
@(private = "file")
Rig :: struct {
	h:     Harness,
	files: [2]game.Pack_File,
}

@(private = "file")
walkers_start :: proc(t: ^testing.T, rig: ^Rig) -> (kind: game.Kind_Id, ok: bool) {
	h := &rig.h
	rig.files = {
		{"pack.json", transmute([]u8)string(WALKERS_PACK)},
		{"data/entities/creep.json", transmute([]u8)string(WALKERS_KINDS)},
	}
	config := harness_world()
	config.game = {
		info = {id = "walkers", name = "Walkers"},
		pack = {"walkers", rig.files[:]},
	}
	if !testing.expect(t, harness_start(h, config)) {return}
	w := h.srv.home
	world_keep(w, {GROUND.lo - {0, 16, 0}, GROUND.hi})
	ready :: proc(data: rawptr) -> bool {
		w := (^World)(data)
		return world_ready(w, {GROUND.lo - {0, 16, 0}, GROUND.hi})
	}
	_, loaded := harness_step_until(h, ready, w, 300)
	if !testing.expect(t, loaded, "the ground never loaded") {return}
	kind, ok = game.registry_kind(h.srv.registry, "walkers:creep")
	testing.expect(t, ok, "no creep in the registry")
	return
}

// wall: blocks x, z from..to, y 0 and 1 (a creep does not climb).
@(private = "file")
wall :: proc(w: ^World, x, z_from, z_to: i32) {
	bulk_edit(
		w,
		{shape = Box{{x, 0, z_from}, {x, 1, z_to}}, op = .Set, block = .Stone},
		world_act(w, .Structure),
	)
}

// walk: steps until the walker arrived (or `most` ticks), and says whether it ever
// stood in a block of the box.
@(private = "file")
walk :: proc(
	h: ^Harness,
	e: game.Entity_Handle,
	avoid: Box,
	most := 600,
) -> (
	arrived, through: bool,
) {
	w := h.srv.home
	for _ in 0 ..< most {
		harness_step(h)
		p := entity_pos(w, e)
		at := game.Block_Pos{floor_i32(p.x), floor_i32(p.y + 0.01), floor_i32(p.z)}
		if box_has(avoid, at) {through = true}
		if entity_arrived(w, e) {return true, through}
	}
	return
}

@(private = "file")
floor_i32 :: proc(x: f64) -> i32 {
	i := i32(x)
	return i - 1 if f64(i) > x else i
}

// A creep follows a route round a wall to its goal, and never through it; a wall built
// across its way while it walks sends it round the new one (the route is searched again,
// once).
@(test)
test_walker_follows_a_route :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	h := &rig.h
	kind, ok := walkers_start(t, rig)
	if !ok {
		harness_stop(h)
		return
	}
	defer harness_stop(h)
	w := h.srv.home
	wall(w, 4, -6, 6)
	route, made := route_make(w, GROUND, {-12, 0, 0}, {20, 0, 0}, kind)
	if !testing.expect(t, made) {return}
	testing.expect(t, route_reaches(w, route, {-12, 0, 0}))
	cost, _ := route_cost(w, route, {-12, 0, 0})
	testing.expectf(t, cost > 33, "the way does not go round the wall: %v", cost)
	e := entity_spawn(w, kind, {-11.5, 0, 0.5}, false)
	if !testing.expect(t, e != 0 && entity_follow(w, e, route)) {return}
	arrived, through := walk(h, e, {{4, 0, -6}, {4, 1, 6}})
	testing.expect(t, arrived, "the creep never arrived")
	testing.expect(t, !through, "the creep walked through the wall")
	p := entity_pos(w, e)
	testing.expectf(t, abs(p.x - 20.5) < 0.7 && abs(p.z - 0.5) < 0.7, "arrived at %v", p)

	// Again from the start; halfway, a second wall goes up across its way.
	e2 := entity_spawn(w, kind, {-11.5, 0, 0.5}, false)
	entity_follow(w, e2, route)
	harness_step(h, 20)
	builds := w.entities.walkers.builds
	wall(w, 12, -16, 8) // (round its end, at z 9 and beyond)
	arrived, through = walk(h, e2, {{12, 0, -16}, {12, 1, 8}})
	testing.expect(t, arrived && !through, "the creep did not go round the new wall")
	testing.expect_value(t, w.entities.walkers.builds, builds + 1)
	route_free(w, route)
	testing.expect(t, !entity_follow(w, e2, route), "followed a route that is gone")
}

// route_would_shut: a block in the last gap of a wall would leave the start with no
// way, as would one that walls a creep in where it stands; elsewhere it would not. Asking
// changes nothing.
@(test)
test_route_would_shut :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	h := &rig.h
	kind, ok := walkers_start(t, rig)
	if !ok {
		harness_stop(h)
		return
	}
	defer harness_stop(h)
	w := h.srv.home
	wall(w, 4, -16, -1) // a wall across the ground with a gap at z 0
	wall(w, 4, 1, 16)
	route, _ := route_make(w, GROUND, {-12, 0, 0}, {20, 0, 0}, kind)
	testing.expect(
		t,
		route_would_shut(w, route, {4, 0, 0}, .Stone),
		"the gap's block did not shut it",
	)
	testing.expect(
		t,
		!route_would_shut(w, route, {8, 0, 3}, .Stone),
		"a block in the open shut it",
	)
	testing.expect(t, route_reaches(w, route, {-12, 0, 0}), "asking shut the way")

	// A creep boxed in on three sides: the fourth would shut its way (not the start's).
	e := entity_spawn(w, kind, {10.5, 0, 10.5}, false)
	entity_follow(w, e, route)
	for p in ([]game.Block_Pos{{9, 0, 10}, {10, 0, 9}, {10, 0, 11}}) {
		bulk_edit(
			w,
			{shape = Box{p, p + {0, 1, 0}}, op = .Set, block = .Stone},
			world_act(w, .Structure),
		)
	}
	testing.expect(t, route_would_shut(w, route, {11, 0, 10}, .Stone), "walled a creep in")
	testing.expect(t, !route_would_shut(w, route, {11, 0, 12}, .Stone))
}

// entity_go: a creep goes to a point by its own path, round a wall; a block put on the
// way it planned makes it plan again, and it does not walk into it.
@(test)
test_walker_goes_to_a_point :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	h := &rig.h
	kind, ok := walkers_start(t, rig)
	if !ok {
		harness_stop(h)
		return
	}
	defer harness_stop(h)
	w := h.srv.home
	wall(w, 0, -4, 4)
	e := entity_spawn(w, kind, {-5.5, 0, 0.5}, false)
	testing.expect(t, entity_go(w, e, {6.5, 0, 0.5}))
	harness_step(h, 3)
	st := entity_steer(w, e)
	if !testing.expect(t, st != nil && st.path.count > 0, "no way planned") {return}
	// A pillar on the planned way, a few steps ahead.
	ahead := st.path.steps[min(st.step + 3, st.path.count - 1)]
	bulk_edit(
		w,
		{shape = Box{ahead, ahead + {0, 1, 0}}, op = .Set, block = .Stone},
		world_act(w, .Structure),
	)
	arrived, through := walk(h, e, {ahead, ahead + {0, 1, 0}})
	testing.expect(t, arrived, "the creep never arrived")
	testing.expect(t, !through, "the creep walked into the pillar")

	// A sheep is no steered walker; standing stops it.
	testing.expect(t, entity_go(w, e, {-5.5, 0, 0.5}))
	entity_stand(w, e)
	harness_step(h, 10)
	testing.expect(t, !entity_arrived(w, e))
	sheep := entity_spawn(w, h.srv.registry.engine.sheep, {0.5, 0, 8.5}, false)
	testing.expect(t, !entity_go(w, sheep, {0.5, 0, 0.5}), "steered a sheep")
}

// entities_of: the creeps near a point, nearest first; one beyond the radius is not
// among them. A game sets a creep's most health (both its health and its most).
@(test)
test_entities_of_and_max_health :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	h := &rig.h
	kind, ok := walkers_start(t, rig)
	if !ok {
		harness_stop(h)
		return
	}
	defer harness_stop(h)
	w := h.srv.home
	far := entity_spawn(w, kind, {9.5, 0, 0.5}, false)
	near := entity_spawn(w, kind, {2.5, 0, 0.5}, false)
	mid := entity_spawn(w, kind, {5.5, 0, 0.5}, false)
	harness_step(h)
	found := entities_of(w, kind, {0.5, 0, 0.5}, 6)
	testing.expect_value(t, len(found), 2)
	if len(found) == 2 {testing.expect(t, found[0] == near && found[1] == mid)}
	testing.expect_value(t, len(entities_of(w, kind, {0.5, 0, 0.5}, 20)), 3)
	_ = far
	testing.expect_value(t, entity_max_health(w, near), 5)
	entity_set_max_health(w, near, 40)
	testing.expect_value(t, entity_health_of(w, near), 40)
	testing.expect_value(t, entity_max_health(w, near), 40)
}

// The walkers' budget scene (`build bench budgets` times it): 200 walkers on one route
// go their way, and every wall that goes up across it has the route searched again.
@(test)
test_budget_walkers_walk :: proc(t: ^testing.T) {
	r, ok := budget_walkers()
	testing.expect(t, ok, "the scene did not start")
	testing.expectf(
		t,
		r.moved >= BUDGET_WALKERS * 9 / 10,
		"only %d walkers went their way",
		r.moved,
	)
	testing.expectf(t, r.builds >= 5, "the route was searched %d times", r.builds)
}
