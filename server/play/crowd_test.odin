package play

import "core:testing"

import "common:game"
import "common:wave"
import "server:core"

// A crowd (crowd.odin) on the harness's flat world: a wave sent comes out of its lairs one
// creature at a time, as tough as the wave says, until the whole wave is out; its
// creatures go for the player the game's rule lets them hunt and strike it; a creature
// that dies leaves the crowd, and clearing it takes the rest and what was still to come.

@(private = "file")
fair_or_none :: proc(s: ^core.Server, c: ^core.Client) -> bool {return prey_fair(s, c)}

@(test)
test_a_crowd_sends_its_waves :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	if !testing.expect(
		t,
		core.session_start(sess, {}, false, with = core.harness_world()),
	) {return}
	defer core.session_stop(sess)
	_, ok := core.harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			sess := (^core.Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, sess, 600)
	if !testing.expect(t, ok, "the player never came") {return}
	s := &sess.h.srv
	w := s.home
	c := &s.clients[0]
	core.game_mode(s, c, "survival")
	crowd := new(Crowd)
	defer free(crowd)
	if !testing.expect(t, crowd_start(s, crowd), "the base pack lacks a foe") {return}

	lairs := [][3]f64{c.player.position + {8, 0, 0}, c.player.position + {-8, 0, 0}}
	crowd_send(s, crowd, 2)
	testing.expect_value(t, crowd_waiting(crowd), wave.size(2))
	before := c.health
	for _ in 0 ..< 10 * game.TICK_RATE {
		crowd_spawn_due(s, crowd, w, lairs, 0.25)
		crowd_tick(s, crowd, w, fair_or_none)
		core.harness_step(&sess.h)
	}
	testing.expect_value(t, crowd_waiting(crowd), 0)
	testing.expect_value(t, crowd.foe_count, wave.size(2))
	testing.expect(t, c.health < before, "the crowd never struck")
	f := crowd.foes[0]
	h, there := core.entity_find(w, f.id)
	if !testing.expect(t, there) {return}
	kind_health := game.kind_info(s.registry, crowd.kinds[f.foe]).health
	testing.expect_value(
		t,
		core.entity_max_health(w, h),
		int(f32(kind_health) * wave.plan(2).health + 0.5),
	)

	// One killed is forgotten; clearing takes the rest.
	core.entity_harm(w, h, {amount = 100_000, kind = .Game})
	crowd_tick(s, crowd, w, fair_or_none)
	testing.expect_value(t, crowd.foe_count, wave.size(2) - 1)
	crowd.coming[.Hulk] = 3
	ids := make([dynamic]u32, context.temp_allocator)
	for g in crowd.foes[:crowd.foe_count] {append(&ids, g.id)}
	crowd_clear(crowd, w)
	testing.expect_value(t, crowd.foe_count, 0)
	testing.expect_value(t, crowd_waiting(crowd), 0)
	for id in ids {
		_, still := core.entity_find(w, id)
		testing.expect(t, !still, "a creature outlived its crowd")
	}
}
