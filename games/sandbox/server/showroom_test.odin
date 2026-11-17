package sandbox_server

import "core:fmt"
import "core:testing"

import "common:game"
import "server:core"
import "server:playtest"

// The sandbox has a block of every material, and /showroom sets a family's up: the first
// wall of stone is the stone, the eighth sits beside the seventh, the ninth above the first.
@(test)
test_the_showroom :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !meadow(t, rig) {playtest.stop(rig); return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	for m in game.MATERIALS {
		_, ok := game.registry_block(s.registry, fmt.tprintf("sandbox:%s", m.name))
		testing.expectf(t, ok, "the sandbox has no block of %s", m.name)
	}
	playtest.say(rig, "showroom stone -8 0 -8")
	testing.expect(t, playtest.told(rig, "Showroom of 25 materials"))
	at :: proc(s: ^core.Server, p: game.Block_Pos) -> string {
		b, _ := core.block_at(s.home, p)
		return s.registry.blocks.defs[b].id
	}
	testing.expect_value(t, at(s, {-8, 0, -8}), "sandbox:stone")
	testing.expect_value(t, at(s, {-6, 2, -8}), "sandbox:stone")
	testing.expect_value(t, at(s, {-8 + 7 * 4, 0, -8}), "sandbox:basalt_bricks")
	testing.expect_value(t, at(s, {-8, 4, -8}), "sandbox:basalt_tiles")
	playtest.say(rig, "showroom granite")
	testing.expect(t, playtest.told(rig, "Usage: showroom"))
}
