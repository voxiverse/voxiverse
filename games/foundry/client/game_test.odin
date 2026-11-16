package foundry_client

import "core:strings"
import "core:testing"

import "client:engine"
import "client:playtest"
import "common:game"
import "games:foundry"
import foundry_server "games:foundry/server"
import "server:core"

// Foundry played whole: the server part on a stepped server, a session joined to it with
// this client part, and what it draws: the factory's line, a machine's label from what the
// machine shows, the hand-crafting list, a machine's panel, the builders.

@(test)
test_foundry_on_the_hud :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, foundry_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	s := rig.s
	testing.expect_value(t, s.game.id, "foundry")
	srv := playtest.srv(rig)
	playtest.until(
		rig,
		proc(rig: ^playtest.Rig) -> bool {return foundry_server.state(playtest.srv(rig)).built},
		60,
	)
	foundry_server.demo_build(srv, playtest.client(rig))
	playtest.until(
		rig,
		proc(rig: ^playtest.Rig) -> bool {return view(rig.s).status.supply > 0},
		10,
	)
	testing.expect(t, playtest.drawn(rig, "FOUNDRY  lodestar 0/1  "), "no factory line")
	// The belt's items reach the client: its copy of the belts carries them.
	carried := playtest.until(rig, proc(rig: ^playtest.Rig) -> bool {
			for _, lane in rig.s.belts.lanes {if lane.count > 0 {return true}}
			return false
		}, 10)
	testing.expectf(
		t,
		carried,
		"the client holds no items on its belts: %d lanes",
		len(s.belts.lanes),
	)

	// The furnace's label comes from what the server showed of it.
	shown := engine_shown(rig)
	testing.expect(
		t,
		shown != nil && shown.kind == .Furnace,
		"the client was not shown the furnace",
	)
	if shown !=
	   nil {testing.expect(t, strings.has_prefix(label(s, shown), "Furnace"), label(s, shown))}

	// The hand-crafting list, by its action's key.
	rig.app.actions.key_pressed += {.Game_1}
	testing.expect(t, playtest.drawn(rig, "Craft by hand"), "no crafting list")
	rig.app.actions.key_pressed -= {.Game_1}
	engine.game_screen_close(s)

	// A machine's panel, opened by the player's use of it.
	// (the player's use of the block it aims at, as its right button sends it)
	c := playtest.client(rig)
	c.player.position = {58.5, 0, 42.5}
	s.aim = game.Ray_Hit {
		block    = {58, 0, 40},
		normal   = {0, 0, 1},
		distance = 2,
	}
	testing.expect(t, engine.session_use_block(s), "the use of a machine was not sent")
	playtest.until(rig, proc(rig: ^playtest.Rig) -> bool {return view(rig.s).panel.open}, 5)
	testing.expect(t, playtest.drawn(rig, "Furnace"), "no panel")
	testing.expect(t, playtest.drawn(rig, foundry.tr(.Panel_Take)), "no panel buttons")
	engine.game_screen_close(s)
	testing.expect(t, playtest.drawn(rig, "Foundry", scores = true), "no scoreboard")
	_ = core.MAX_WORKING_CHUNKS
}

// engine_shown: what the demo line's furnace shows, once the session holds it.
@(private = "file")
engine_shown :: proc(rig: ^playtest.Rig) -> ^foundry.Shown {
	furnace :: proc(rig: ^playtest.Rig) -> ^foundry.Shown {
		return engine.machine_shown(rig.s, {58, 0, 40}, foundry.Shown)
	}
	playtest.until(rig, proc(rig: ^playtest.Rig) -> bool {return furnace(rig) != nil}, 10)
	return furnace(rig)
}
