package core

import "core:os"
import "core:path/filepath"
import "core:testing"

import "common:access"
import "common:game"

// The engine gives nothing by default: a kit is the game's (Config.kit) or the
// universe's. (The harness's worlds name a kit of blocks: HARNESS_KIT.)
@(test)
test_default_kit_is_nothing :: proc(t: ^testing.T) {
	reg := game.test_reg()
	stacks, parsed := kit_parse(reg, "")
	testing.expect(t, parsed && len(stacks) == 0, "the engine's own kit is not empty")
	launcher, ok := game.item_by_name(reg, "rocket_launcher")
	if !testing.expect(t, ok) {return}
	if stacks, parsed = kit_parse(reg, SANDBOX_KIT); testing.expect(t, parsed) {
		testing.expect_value(t, len(stacks), 1)
		testing.expect_value(t, stacks[0], game.Stack{launcher, 1, 0, 0})
	}
	if stacks, parsed = kit_parse(reg, HARNESS_KIT); testing.expect(t, parsed) {
		testing.expect(t, len(stacks) > 1, "the harness's kit")
	}
}

// SANDBOX_KIT: games/sandbox's KIT (the engine's tests import no game).
SANDBOX_KIT :: "rocket_launcher 1"

// A new player's inventory: the launcher in hotbar slot 1 and nothing else;
// without world.fire not even that (the grants say: with cheats it is allowed).
@(test)
test_new_character_has_the_launcher_only :: proc(t: ^testing.T) {
	for cheats in ([]bool{true, false}) {
		dir := filepath.join({"build", "test", "kit_default"}, context.temp_allocator) or_else ""
		os.remove_all(dir)
		defer os.remove_all(dir)
		h := new(Harness)
		defer free(h)
		config := Config {
			rules           = quiet_rules(),
			everyone_cheats = cheats,
			seed            = 22,
			view_radius     = 2,
			view_height     = 1,
			save_dir        = dir,
			max_players     = 2,
			listen          = true,
			generator       = .Classic,
			kit             = SANDBOX_KIT,
		}
		if !testing.expect(t, harness_start(h, config)) {return}
		stopped := false
		defer if !stopped {harness_stop(h)}
		a := new(Net_Client)
		defer free(a)
		net_connect(a, 0, "alice", h = h)
		defer net_close(a)
		if !testing.expect(
			t,
			net_wait(
				t,
				{a},
				proc(cs: []^Net_Client) -> bool {return(
						cs[0].inv_updates > 0 &&
						cs[0].update.acked > 0 &&
						cs[0].update.state.on_ground \
					)},
			),
		) {
			return
		}
		launcher := game.item_of_tool(.Launcher)
		if access.allowed(a.grants[:], "world.fire") {
			testing.expect_value(t, a.inventory.slots[0], game.Stack{launcher, 1, 0, 0})
		} else {
			testing.expect(
				t,
				game.stack_empty(a.inventory.slots[0]),
				"no launcher without world.fire",
			)
		}
		for s in a.inventory.slots[1:] {testing.expect(t, game.stack_empty(s))}
		testing.expectf(
			t,
			access.allowed(a.grants[:], "world.fire") == cheats || !cheats,
			"cheats %v",
			cheats,
		)
		stopped = harness_stop(h)
	}
}

// A world that names no kit gives nothing, also in a test: a game's tests start with
// what the game gives and nothing else (the engine's tests' blocks once reached every
// test build that linked the engine, the games' too).
@(test)
test_no_kit_gives_nothing_in_tests :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	config := harness_world()
	config.kit = ""
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return}
	defer session_stop(sess)
	welcomed :: proc(data: rawptr) -> bool {return (^Session)(data).mirror.welcomed}
	_, ok := harness_step_until(&sess.h, welcomed, sess, 600)
	if !testing.expect(t, ok) {return}
	harness_step(&sess.h, 4)
	for st in sess.h.srv.clients[0].inventory.slots {
		testing.expectf(t, game.stack_empty(st), "the host holds %v", st)
	}
}
