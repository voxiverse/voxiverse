package core

import "core:testing"

import "common:base"
import "common:game"

// rules.show_coordinates: on by default, a variable like the others
// (world.cfg, the console), and sent to the clients with the rest of the
// rules; it is the client's F3 that hides the position when it is off, for
// a player without the permission debug.coordinates (client/main/camera_test.odin).
@(test)
test_show_coordinates_rule :: proc(t: ^testing.T) {
	rules := game.RULES_DEFAULTS
	testing.expect(t, rules.show_coordinates)
	table := game.rules_table()
	testing.expect(t, base.var_table_check(table))
	testing.expect_value(
		t,
		base.var_set(table, &rules, "rules.show_coordinates", "false"),
		base.Var_Error.None,
	)
	testing.expect(t, !rules.show_coordinates)
	// Over the wire.
	w: game.Writer
	game.writer_init(&w)
	defer game.writer_destroy(&w)
	game.encode_server(&w, game.World_Changed{game.address_derive(1), rules}, nil)
	got, ok := game.decode_server(w.buf[:], nil)
	testing.expect(t, ok)
	testing.expect(t, !got.(game.World_Changed).rules.show_coordinates)
}

// rules.explosion_size and rules.explosion_throw scale every explosion in their world:
// what it carves and how far it reaches, and how hard it throws.
@(test)
test_explosion_rules :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	if !testing.expect(t, session_start(sess, {}, false, with = harness_world())) {return}
	defer session_stop(sess)
	welcomed :: proc(data: rawptr) -> bool {return (^Session)(data).mirror.welcomed}
	_, ok := harness_step_until(&sess.h, welcomed, sess, 600)
	if !testing.expect(t, ok, "the player never joined") {return}
	harness_step(&sess.h, 30)
	s := &sess.h.srv
	c := &s.clients[0]
	w := c.world
	testing.expect_value(t, w.rules.explosion_size, 1)
	testing.expect_value(t, w.rules.explosion_throw, 1)

	// air: the air blocks in the cube of side 2r+1 around p.
	air :: proc(w: ^World, p: game.Block_Pos, r: i32) -> (n: int) {
		for y in p.y - r ..= p.y + r {
			for z in p.z - r ..= p.z + r {
				for x in p.x - r ..= p.x + r {
					if b, _ := chunks_block(&w.chunks, {x, y, z}); b == .Air {n += 1}
				}
			}
		}
		return
	}
	// thrown: c's velocity from a blast offset from its middle, in a world with these rules.
	thrown :: proc(s: ^Server, c: ^Client, offset: [3]f64) -> [3]f32 {
		c.player.velocity = {}
		explode(
			c.world,
			c.player.position + {0, 0.9, 0} + offset,
			4,
			world_act(c.world, .Explosion).action,
		)
		return c.player.velocity
	}
	// Underground, a blast of radius 4 carves less than one of 4 x 1.75 = 7.
	small_at, large_at := game.Block_Pos{-8, -9, 0}, game.Block_Pos{8, -9, 0}
	testing.expect_value(t, air(w, small_at, 7) + air(w, large_at, 7), 0)
	explode(w, {-7.5, -8.5, 0.5}, 4, world_act(w, .Explosion).action)
	small := air(w, small_at, 7)
	w.rules.explosion_size = 1.75
	explode(w, {8.5, -8.5, 0.5}, 4, world_act(w, .Explosion).action)
	large := air(w, large_at, 7)
	testing.expectf(
		t,
		small > 200 && large > 4 * small,
		"carved %d at size 1, %d at 1.75",
		small,
		large,
	)

	// The throw: twice the rule, twice the impulse; 9 blocks off is past a rocket's
	// reach (8) and within one 1.75 times as large.
	w.rules.explosion_size = 1
	near := thrown(s, c, {3, 0, 0})
	testing.expect(t, near.x < 0 && near.y > 0, "a blast to the east does not throw west and up")
	w.rules.explosion_throw = 2
	testing.expect_value(t, thrown(s, c, {3, 0, 0}), near * 2)
	w.rules.explosion_throw = 1
	testing.expect_value(t, thrown(s, c, {9, 0, 0}), [3]f32{})
	w.rules.explosion_size = 1.75
	testing.expect(t, thrown(s, c, {9, 0, 0}).x < 0, "a larger blast does not reach farther")
}
