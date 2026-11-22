package sandbox_server

import "core:testing"

import "common:game"
import "server:core"
import "server:playtest"

// The sandbox's nights: its pack lets the base pack's shamblers and skitters out from dusk
// to dawn, clear of the spawn point (and no other hostile kind); one goes for a player who
// can be hurt and leaves a creative one alone.
@(test)
test_the_night_has_creatures :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := s.home
	rule :: proc(s: ^core.Server, id: string) -> (game.Kind_Spawn_Rule, bool) {
		k, _ := game.registry_kind(s.registry, id)
		return game.kind_info(s.registry, k).spawn.?
	}
	for id in ([]string{"voxiverse:shambler", "voxiverse:skitter"}) {
		r, has := rule(s, id)
		if !testing.expectf(t, has, "%s has no spawn rule", id) {continue}
		testing.expectf(t, core.spawn_hours(r.day, 0.0), "%s does not come at midnight", id)
		testing.expectf(t, !core.spawn_hours(r.day, 0.5), "%s comes at noon", id)
		testing.expectf(t, r.safe >= 32, "%s comes within %d of the spawn", id, r.safe)
	}
	for id in ([]string{"voxiverse:spitter", "voxiverse:hulk", "voxiverse:matriarch"}) {
		_, has := rule(s, id)
		testing.expectf(t, !has, "%s comes by itself", id)
	}

	h := playtest.host(rig)
	shambler, _ := game.registry_kind(s.registry, "voxiverse:shambler")
	core.game_mode(s, h, "creative")
	e := core.entity_spawn(w, shambler, h.player.position + {5, 0, 0}, false)
	if !testing.expect(t, e != 0) {return}
	at := core.entity_pos(w, e)
	playtest.step(rig, 3 * game.TICK_RATE)
	moved := core.entity_pos(w, e) - at
	testing.expectf(
		t,
		moved.x * moved.x + moved.z * moved.z < 0.25,
		"it went for a creative player: %v",
		moved,
	)
	core.game_mode(s, h, "survival")
	before := h.health
	playtest.step(rig, 6 * game.TICK_RATE)
	testing.expect(t, h.health < before, "the shambler never struck")
}
