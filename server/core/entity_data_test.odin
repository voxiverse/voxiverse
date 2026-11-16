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
