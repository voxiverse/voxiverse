package core

import "core:testing"

import "common:game"

// A spawn rule's hours may run across midnight (a night's creatures), and its `safe` keeps
// a ring round the world's spawn point clear of it: on the harness's flat grass, with the
// player at the spawn, the night kind comes at night and not by day, the kind kept clear
// of the spawn never.

@(private = "file")
NIGHT_PACK :: `{"format": 1, "namespace": "night", "version": "1.0.0", "requires": ["voxiverse"]}`
@(private = "file")
NIGHT_KINDS :: `{
	"prowler": {"box": [0.6, 1.6], "physics": "walker", "brain": "steered", "model": {"box": [90, 40, 40]},
	            "walker": {"walk_speed": 2, "run_speed": 2, "jump": 1.2, "step": 0},
	            "spawn": {"on": "voxiverse:grass", "day": [0.8, 0.2], "every": 10, "chance": 1, "cap": 3,
	                      "within": 32, "distance": [8, 14], "group": [1, 1]}},
	"shy": {"box": [0.6, 1.6], "physics": "walker", "brain": "steered", "model": {"box": [40, 40, 90]},
	        "walker": {"walk_speed": 2, "run_speed": 2, "jump": 1.2, "step": 0},
	        "spawn": {"on": "voxiverse:grass", "day": [0.8, 0.2], "every": 10, "chance": 1, "cap": 3,
	                  "within": 32, "distance": [8, 14], "group": [1, 1], "safe": 40}}
}`

@(test)
test_a_night_spawns_clear_of_the_spawn_point :: proc(t: ^testing.T) {
	files := [2]game.Pack_File {
		{"pack.json", transmute([]u8)string(NIGHT_PACK)},
		{"data/entities/night.json", transmute([]u8)string(NIGHT_KINDS)},
	}
	config := harness_world()
	config.no_natural_spawns = false
	config.game = {
		info = {id = "night", name = "Night", description = "spawn rules by night"},
		pack = {"night", files[:]},
	}
	sess := new(Session)
	defer free(sess)
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return}
	defer session_stop(sess)
	s := &sess.h.srv
	w := s.home
	_, ok := harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			sess := (^Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, sess, 600)
	if !testing.expect(t, ok, "the player never came") {return}
	prowler, _ := game.registry_kind(s.registry, "night:prowler")
	shy, _ := game.registry_kind(s.registry, "night:shy")
	count :: proc(w: ^World, kind: game.Kind_Id) -> (n: int) {
		it := entities_each(w)
		for e in entities_next(&it) {if entity_kind(w, e) == kind {n += 1}}
		return
	}
	testing.expect(t, spawn_hours({0.8, 0.2}, 0.9) && spawn_hours({0.8, 0.2}, 0.1))
	testing.expect(t, !spawn_hours({0.8, 0.2}, 0.5))
	game_rule(s, w, "daylight_cycle", "false")
	w.clock = 0.5 // noon: neither comes
	harness_step(&sess.h, 120)
	testing.expect_value(t, count(w, prowler), 0)
	w.clock = 0.95 // night
	harness_step(&sess.h, 120)
	testing.expect(t, count(w, prowler) >= 1, "no prowler came at night")
	testing.expect_value(t, count(w, shy), 0)
}
