package play

import "core:testing"

import "common:game"
import "server:core"

// Hunting (hunt.odin) on the harness's flat world, with the base pack's creatures: an open
// world's shambler goes for a player who can be hurt and strikes it, and stands by one who
// cannot (creative); a spitter keeps its distance and spits.

@(private = "file")
hunt_start :: proc(t: ^testing.T, sess: ^core.Session) -> (c: ^core.Client, ok: bool) {
	if !testing.expect(
		t,
		core.session_start(sess, {}, false, with = core.harness_world()),
	) {return}
	_, ok = core.harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			sess := (^core.Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, sess, 600)
	if !testing.expect(t, ok, "the player never came") {return}
	return &sess.h.srv.clients[0], true
}

@(private = "file")
hunt_for :: proc(sess: ^core.Session, seconds: int) {
	s := &sess.h.srv
	for _ in 0 ..< seconds * game.TICK_RATE {
		hunt_tick(s, s.home)
		core.harness_step(&sess.h)
	}
}

@(test)
test_a_creature_hunts_only_who_can_be_hurt :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	c, ok := hunt_start(t, sess)
	defer core.session_stop(sess)
	if !ok {return}
	s := &sess.h.srv
	w := s.home
	shambler, _ := game.registry_kind(s.registry, "voxiverse:shambler")
	core.game_mode(s, c, "creative")
	testing.expect(t, !prey_fair(s, c), "a creative player is fair game")
	h := core.entity_spawn(w, shambler, c.player.position + {5, 0, 0}, false)
	if !testing.expect(t, h != 0) {return}
	at := core.entity_pos(w, h)
	hunt_for(sess, 3)
	moved := core.entity_pos(w, h) - at
	testing.expectf(
		t,
		moved.x * moved.x + moved.z * moved.z < 0.25,
		"it went for a creative player: %v",
		moved,
	)

	core.game_mode(s, c, "survival")
	testing.expect(t, prey_fair(s, c), "a survival player is not fair game")
	before := c.health
	hunt_for(sess, 6)
	testing.expect(t, c.health < before, "the shambler never struck")
}

@(test)
test_a_spitter_keeps_its_distance_and_spits :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	c, ok := hunt_start(t, sess)
	defer core.session_stop(sess)
	if !ok {return}
	s := &sess.h.srv
	w := s.home
	core.game_mode(s, c, "survival")
	spitter, _ := game.registry_kind(s.registry, "voxiverse:spitter")
	h := core.entity_spawn(w, spitter, c.player.position + {10, 0, 0}, false)
	if !testing.expect(t, h != 0) {return}
	before := c.health
	hunt_for(sess, 6)
	testing.expect(t, c.health < before, "the spitter never spat")
	d := core.entity_pos(w, h) - c.player.position
	testing.expectf(t, d.x * d.x + d.z * d.z > 9, "the spitter came within %v", d)
}
