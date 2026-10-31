package server

import "core:os"
import "core:path/filepath"
import "core:testing"

import "common:game"

// The worlds the tests start give their players the blocks the old default
// kit gave (the tests place and break them); the real default, the rocket
// launcher alone, is what kit_default and a Config's kit are tested with.
TEST_KIT :: "stone 64, dirt 64, grass 64, sand 64, log 64, leaves 64, water 64, lamp 64, rocket_launcher 1"

// (Odin compiles a _test.odin file into every build of the package: without
// the `when`, the game and the server started everyone with these blocks.)
when ODIN_TEST {
	@(init)
	test_kit_init :: proc "contextless" () {
		default_kit_override = TEST_KIT
	}
}

@(test)
test_default_kit_is_the_launcher :: proc(t: ^testing.T) {
	reg := game.test_reg()
	kit: [dynamic]game.Stack
	defer delete(kit)
	launcher, ok := game.item_by_name(reg, "rocket_launcher")
	if !testing.expect(t, ok) {return}
	if stacks, parsed := kit_parse(reg, DEFAULT_KIT_TEXT); testing.expect(t, parsed) {
		testing.expect_value(t, len(stacks), 1)
		testing.expect_value(t, stacks[0], game.Stack{launcher, 1, 0})
	}
	// (kit_default itself is the override while the tests run.)
	kit_default(reg, &kit)
	testing.expect(t, len(kit) > 1, "the tests' kit")
}

// A new player's inventory: the launcher in hotbar slot 1 and nothing else;
// without world.fire not even that (the grants say: with cheats it is allowed).
@(test)
test_new_character_has_the_launcher_only :: proc(t: ^testing.T) {
	for cheats in ([]bool{true, false}) {
		dir := filepath.join({"build", "test", "kit_default"}, context.temp_allocator) or_else ""
		os.remove_all(dir)
		defer os.remove_all(dir)
		h: Harness
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
			kit             = DEFAULT_KIT_TEXT,
		}
		if !testing.expect(t, harness_start(&h, config)) {return}
		stopped := false
		defer if !stopped {harness_stop(&h)}
		a: Net_Client
		net_connect(&a, 0, "alice", h = &h)
		defer net_close(&a)
		if !testing.expect(
			t,
			net_wait(
				t,
				{&a},
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
		if game.allowed(a.grants[:], "world.fire") {
			testing.expect_value(t, a.inventory.slots[0], game.Stack{launcher, 1, 0})
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
			game.allowed(a.grants[:], "world.fire") == cheats || !cheats,
			"cheats %v",
			cheats,
		)
		stopped = harness_stop(&h)
	}
}
