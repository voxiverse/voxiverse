package core

import "core:os"
import "core:testing"

import "common:game"

// A game's creature survives a restart whole, without its game making it again: its
// kind, place, health and most health, the way it was going and the game's own record on
// it (Game.entity_data: CREATURES_GAME's Creature_Data).
@(test)
test_a_games_creature_survives_a_restart :: proc(t: ^testing.T) {
	dir :: "build/tmp/test_game_creature"
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := harness_world()
	config.save_dir = dir
	config.game = harness_creatures()
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, config)) {return}
	s := &h.srv
	kind, known := game.registry_kind(s.registry, "creatures:walker")
	if !testing.expect(t, known) {
		harness_stop(h)
		return
	}
	e := entity_spawn(s.home, kind, {3.5, 1, 3.5}, false)
	if !testing.expect(t, e != 0) {
		harness_stop(h)
		return
	}
	id := entity_id(s.home, e)
	want := Creature_Data {
		number = -42,
		mood   = .Scared,
		home   = {7, -1, 300},
	}
	entity_data(s.home, e, Creature_Data)^ = want
	entity_set_max_health(s.home, e, 9)
	entity_set_health(s.home, e, 6)
	entity_set_speed(s.home, e, 2.5)
	entity_go(s.home, e, {20.5, 1, 3.5})
	testing.expect(t, harness_stop(h))

	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	back, found := entity_find(s.home, id)
	if !testing.expect(t, found, "the creature was not kept") {return}
	testing.expect_value(t, entity_kind(s.home, back), kind)
	testing.expect_value(t, entity_pos(s.home, back), [3]f64{3.5, 1, 3.5})
	testing.expect_value(t, entity_health_of(s.home, back), 6)
	testing.expect_value(t, entity_max_health(s.home, back), 9)
	testing.expect_value(t, entity_data(s.home, back, Creature_Data)^, want)
	st := entity_steer(s.home, back)
	if !testing.expect(t, st != nil) {return}
	testing.expect_value(t, st.mode, Steer_Mode.Go)
	testing.expect_value(t, st.target, [3]f64{20.5, 1, 3.5})
	testing.expect_value(t, st.speed, 2.5)
}

// A game's brain: the creatures of each of its kinds whose brain is "game" are given to
// its think hook once a tick, all of them in one call (lowest id first), and what it
// steers them to do they do. Hundreds cost one call a tick.
@(test)
test_a_games_brain_thinks_for_its_creatures :: proc(t: ^testing.T) {
	Seen :: struct {
		calls, last: int,
		in_order:    bool,
	}
	h := new(Harness)
	defer free(h)
	config := harness_world()
	config.game = harness_creatures()
	config.game.server_state = Seen
	config.game.think = proc(
		s: ^Server,
		w: ^World,
		kind: game.Kind_Id,
		entities: []game.Entity_Handle,
	) {
		seen := game_state(s, Seen)
		seen.calls += 1
		seen.last = len(entities)
		seen.in_order = true
		for e, i in entities {
			if i > 0 && entity_id(w, entities[i - 1]) >= entity_id(w, e) {seen.in_order = false}
			data := entity_data(w, e, Creature_Data)
			data.number += 1
			if data.number == 1 {entity_go(w, e, entity_pos(w, e) + {4, 0, 0})}
		}
	}
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	s := &h.srv
	kind, _ := game.registry_kind(s.registry, "creatures:thinker")
	walker, _ := game.registry_kind(s.registry, "creatures:walker")
	area := Box{{-24, -16, -24}, {24, 16, 24}}
	world_keep(s.home, area)
	for _ in 0 ..< 300 {
		if world_ready(s.home, area) {break}
		harness_step(h)
	}
	if !testing.expect(t, world_ready(s.home, area), "the ground never came") {return}
	COUNT :: 300
	first: game.Entity_Handle
	for i in 0 ..< COUNT {
		e := entity_spawn(s.home, kind, {f64(i % 20) * 1.5 - 15, 0, f64(i / 20) * 1.5 - 12}, false)
		if i == 0 {first = e}
	}
	entity_spawn(s.home, walker, {0.5, 1, 20.5}, false) // (no brain of the game's: not given)
	start := entity_pos(s.home, first)
	seen := game_state(s, Seen)
	seen.calls = 0
	harness_step(h, 30)
	testing.expect_value(t, seen.calls, 30)
	testing.expect_value(t, seen.last, COUNT)
	testing.expect(t, seen.in_order, "not lowest id first")
	testing.expect_value(t, entity_data(s.home, first, Creature_Data).number, 30)
	st := entity_steer(s.home, first)
	testing.expectf(
		t,
		entity_pos(s.home, first).x > start.x + 0.5,
		"the brain's steering did nothing: %v -> %v, %v %v %v",
		start,
		entity_pos(s.home, first),
		st.mode,
		st.target,
		st.path.count,
	)
}
