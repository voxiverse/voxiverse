package play

import "core:math"
import "core:testing"

import "common:game"
import "server:core"

// Squads (squad.odin) on the harness's flat world (its ground is y -1: a walker stands in
// y 0): a block of soldiers ordered to a point arrives around it, one route searched for
// them all and none on another; two sides set on each other fight it out by the numbers;
// the route cache lends more goals than it holds.

@(private = "file")
SQUAD_PACK :: `{"format": 1, "namespace": "squad", "version": "1.0.0", "title": "Squad", "requires": ["voxiverse"]}`
@(private = "file")
SQUAD_KINDS :: `{
	"soldier": {"box": [0.6, 1.6], "health": 10, "hittable": true, "physics": "walker",
	            "walker": {"walk_speed": 4, "run_speed": 4, "jump": 1.2, "step": 0},
	            "brain": "steered", "attack": {"damage": 2, "reach": 1, "cooldown": 0.5},
	            "model": {"box": [90, 140, 60]}}
}`

@(private = "file")
SQUAD_AREA :: core.Box{{-24, 0, -24}, {40, 3, 24}}

@(private = "file")
Squad_Rig :: struct {
	sess:  core.Session,
	files: [2]game.Pack_File,
	kind:  game.Kind_Id,
}

@(private = "file")
squad_start :: proc(t: ^testing.T, rig: ^Squad_Rig) -> bool {
	rig.files = {
		{"pack.json", transmute([]u8)string(SQUAD_PACK)},
		{"data/entities/soldier.json", transmute([]u8)string(SQUAD_KINDS)},
	}
	config := core.harness_world()
	config.game = {
		info = {id = "squad", name = "Squad", description = "server/play's squads"},
		pack = {"squad", rig.files[:]},
	}
	if !testing.expect(t, core.session_start(&rig.sess, {}, false, with = config)) {return false}
	s := &rig.sess.h.srv
	core.world_keep(s.home, {SQUAD_AREA.lo - {0, 4, 0}, SQUAD_AREA.hi})
	ready :: proc(data: rawptr) -> bool {
		s := (^core.Server)(data)
		return core.world_ready(s.home, {SQUAD_AREA.lo - {0, 4, 0}, SQUAD_AREA.hi})
	}
	_, ok := core.harness_step_until(&rig.sess.h, ready, s, 600)
	if !testing.expect(t, ok, "the ground never loaded") {return false}
	rig.kind, ok = game.registry_kind(s.registry, "squad:soldier")
	return testing.expect(t, ok)
}

@(test)
test_a_squad_arrives_around_its_goal :: proc(t: ^testing.T) {
	rig := new(Squad_Rig)
	defer free(rig)
	if !squad_start(t, rig) {
		core.session_stop(&rig.sess)
		return
	}
	defer core.session_stop(&rig.sess)
	s := &rig.sess.h.srv
	w := s.home
	units: [24]game.Entity_Handle
	for &u, i in units {
		u = core.entity_spawn(
			w,
			rig.kind,
			{f64(-16 + i % 6) + 0.5, 0, f64(-4 + i / 6) + 0.5},
			false,
		)
	}
	routes := Routes {
		area = SQUAD_AREA,
	}
	defer routes_free(w, &routes)
	goal := game.Block_Pos{30, 0, 2}
	route, ok := routes_get(s, w, &routes, goal, rig.kind)
	if !testing.expect(t, ok, "no route") {return}
	places := formation(s, w, goal, len(units))
	if !testing.expect_value(t, len(places), len(units)) {return}
	formation_assign(w, units[:], places)
	kept := make([]game.Block_Pos, len(places))
	defer delete(kept)
	copy(kept, places)
	for _ in 0 ..< 30 * 20 {
		there := 0
		for u, i in units {if march(w, u, kept[i], route) {there += 1}}
		core.harness_step(&rig.sess.h)
		if there == len(units) {break}
	}
	// Every one stands at its place, none on another: the spread of a crowd, not a pile.
	for u, i in units {
		p := core.entity_pos(w, u)
		to := place_point(kept[i])
		testing.expectf(
			t,
			math.abs(p.x - to.x) + math.abs(p.z - to.z) < 1.2,
			"soldier %d is not at its place",
			i,
		)
		for v in units[i + 1:] {
			q := core.entity_pos(w, v)
			testing.expect(
				t,
				math.abs(p.x - q.x) + math.abs(p.z - q.z) > 0.5,
				"two soldiers on one spot",
			)
		}
	}
	// One goal, one route: asked again, the same.
	again, _ := routes_get(s, w, &routes, goal, rig.kind)
	testing.expect_value(t, again, route)
	testing.expect_value(t, routes.count, 1)
}

@(test)
test_two_sides_fight_by_the_numbers :: proc(t: ^testing.T) {
	rig := new(Squad_Rig)
	defer free(rig)
	if !squad_start(t, rig) {
		core.session_stop(&rig.sess)
		return
	}
	defer core.session_stop(&rig.sess)
	s := &rig.sess.h.srv
	w := s.home
	army: [dynamic]game.Entity_Handle
	defer delete(army)
	for i in 0 ..< 8 {
		h := core.entity_spawn(w, rig.kind, {f64(i) + 0.5, 0, -6.5}, false)
		core.entity_set_team(w, h, 1)
		append(&army, h)
	}
	for i in 0 ..< 3 {
		h := core.entity_spawn(w, rig.kind, {f64(i) + 2.5, 0, 6.5}, false)
		core.entity_set_team(w, h, 2)
		append(&army, h)
	}
	alive :: proc(w: ^core.World, army: []game.Entity_Handle, team: u8) -> (n: int) {
		for h in army {if core.entity_health_of(w, h) > 0 && core.entity_team(w, h) == team {n += 1}}
		return
	}
	for _ in 0 ..< 30 * 30 {
		if alive(w, army[:], 2) == 0 {break}
		for h in army {
			if core.entity_health_of(w, h) <= 0 {continue}
			if foe := foe_nearest(w, h, 24); foe != 0 {fight(w, h, foe, 1)}
		}
		core.harness_step(&rig.sess.h)
	}
	testing.expect_value(t, alive(w, army[:], 2), 0)
	testing.expect(t, alive(w, army[:], 1) > 0, "the larger side was wiped out too")
}

@(test)
test_the_route_cache_lends_more_goals_than_it_holds :: proc(t: ^testing.T) {
	rig := new(Squad_Rig)
	defer free(rig)
	if !squad_start(t, rig) {
		core.session_stop(&rig.sess)
		return
	}
	defer core.session_stop(&rig.sess)
	s := &rig.sess.h.srv
	w := s.home
	routes := Routes {
		area = SQUAD_AREA,
	}
	defer routes_free(w, &routes)
	for i in 0 ..< core.MAX_ROUTES + 4 {
		_, ok := routes_get(s, w, &routes, {i32(i) - 10, 0, 0}, rig.kind)
		testing.expectf(t, ok, "no route for goal %d", i)
		core.harness_step(&rig.sess.h)
	}
	testing.expect_value(t, routes.count, SQUAD_ROUTES)
}
