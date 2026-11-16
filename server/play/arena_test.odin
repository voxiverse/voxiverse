package play

import "core:testing"

import "common:game"
import "server:core"

// A round's ground: an arena of a template, walled, stone under it, built once its
// chunks are there; a phase's clock; a watcher placed and turned; an item put in hand.
@(private = "file")
TEST_ARENA :: Arena {
	origin   = {2, 0, 3},
	size     = {6, 4, 5},
	wall_top = 6,
	depth    = 2,
}

@(private = "file")
Ground_Phase :: enum u8 {
	Building,
	Playing,
}

@(private = "file")
Ground :: struct {
	phase: Phase(Ground_Phase),
	built: bool,
}

@(private = "file")
GROUND_GAME :: core.Game {
	info = {id = "ground", name = "Ground", description = "server/play's tests' arena"},
	server_state = Ground,
	configure = proc(config: ^core.Config) {configure_flat(config, {5.5, 0, 5.5}, "creative")},
	start = proc(s: ^core.Server) -> bool {
		world_still(s, s.home)
		core.world_keep(s.home, arena_area(TEST_ARENA))
		return true
	},
	tick = proc(s: ^core.Server) {
		g := core.game_state(s, Ground)
		if g.built {return}
		t := game.template_make(TEST_ARENA.size, context.temp_allocator)
		game.template_fill(&t, {0, 0, 0}, {5, 0, 4}, .Planks)
		if built, _ := arena_build(s, s.home, TEST_ARENA, &t, force = false); built {
			g.built = true
			phase_set(s, &g.phase, .Playing)
		}
	},
}

@(test)
test_arena_and_watchers :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	config := core.harness_world()
	config.game = GROUND_GAME
	if !testing.expect(t, core.session_start(sess, {}, false, with = config)) {return}
	defer core.session_stop(sess)
	s := &sess.h.srv
	built :: proc(data: rawptr) -> bool {
		s := (^core.Server)(data)
		return core.game_state(s, Ground).built && s.clients[0].state == .Playing
	}
	_, ok := core.harness_step_until(&sess.h, built, s, 600)
	if !testing.expect(t, ok, "never built") {return}
	testing.expect_value(t, s.home.rules.drops, false)
	testing.expect_value(t, s.home.rules.daylight_cycle, false)
	w := s.home
	at :: proc(w: ^core.World, p: game.Block_Pos) -> game.Block {
		b, _ := core.block_at(w, p)
		return b
	}
	testing.expect_value(t, arena_area(TEST_ARENA), core.Box{{1, -2, 2}, {8, 6, 8}})
	testing.expect_value(t, at(w, {2, 0, 3}), game.Block.Planks) // the template's floor
	testing.expect_value(t, at(w, {7, 3, 7}), game.Block.Air) // its air, pasted
	testing.expect_value(t, at(w, {1, 5, 5}), game.Block.Bedrock) // a wall
	testing.expect_value(t, at(w, {5, 6, 8}), game.Block.Bedrock) // another, at its top
	testing.expect_value(t, at(w, {5, -2, 5}), game.Block.Stone) // under the floor
	testing.expect(t, arena_holds(TEST_ARENA, {4, 1, 4}))
	testing.expect(t, !arena_holds(TEST_ARENA, {1.5, 1, 4}))
	testing.expect(t, !arena_holds(TEST_ARENA, {4, 7, 4}))
	testing.expect(t, arena_holds(TEST_ARENA, {4, 7, 4}, above = 2))

	g := core.game_state(s, Ground)
	phase_set(s, &g.phase, .Playing)
	core.harness_step(&sess.h, 45)
	testing.expect_value(t, phase_seconds(s, &g.phase), 1.5)
	testing.expect_value(t, phase_left(s, &g.phase, 4), 3)
	testing.expect_value(t, phase_left(s, &g.phase, 1), 0)
	testing.expect_value(t, present(s), 1)
	c := &s.clients[0]
	testing.expect(t, here(s, c))

	// A watcher floats at its seat's place, looking at the point.
	watch(s, c, "creative", {5, 10, 5}, {5, 0, 5})
	testing.expect(t, c.player.flying)
	seat := f64(core.player_id(s, c))
	testing.expect_value(t, c.player.position.x, 5 + (seat - 7.5) * 2)
	testing.expect(t, c.teleport[1] < -0.5, "the watcher does not look down")
	look := look_at({0, 0, 0}, {0, 0, -5}) // (north: -z, yaw 0)
	testing.expect_value(t, look, [2]f32{0, 0})

	// An item in hand from the hotbar; one it does not carry is not.
	rifle, _ := game.registry_item(s.registry, "voxiverse:rifle")
	c.inventory.slots[3] = {
		item  = rifle,
		count = 1,
	}
	testing.expect(t, hold(s, c, "voxiverse:rifle"))
	testing.expect_value(t, game.inventory_held(&c.inventory).item, rifle)
	testing.expect(t, !hold(s, c, "voxiverse:grappling_hook"))
}
