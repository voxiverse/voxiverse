package flood_client

import "core:fmt"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:playtest"
import "common:base"
import "common:game"
import "games:flood"
import flood_server "games:flood/server"

// Flood played whole: the server part on a stepped server, a session that joins it over
// the harness's network with this client part (fetching the game's pack as any pack),
// and the HUD and F3 line it draws.

@(test)
test_flood_on_the_hud :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, flood_server.GAME, GAME, {name = "swimmer"}) {return}
	defer playtest.stop(rig)
	s := rig.s
	testing.expect_value(t, s.game.id, "flood")
	_, has_out := game.mode_find(s.reg, flood.OUT_MODE)
	testing.expect(t, has_out, "the game's pack did not reach the client")

	// Into the round: the server's word arrives, and the player is a runner.
	playtest.until(
		rig,
		proc(rig: ^playtest.Rig) -> bool {return view(rig.s).round.phase == .Playing},
	)
	v := view(s)
	if !testing.expect_value(t, v.round.phase, flood.Phase.Playing) {return}
	testing.expect_value(t, v.round.players, 1)
	testing.expect_value(t, s.reg.game_modes[s.mode].id, flood.RUNNER_MODE)

	want := fmt.tprintf("FLOOD  round %d   0:", v.round.round)
	testing.expect(t, playtest.drawn(rig, want), "the round is not on the HUD")
	testing.expect(t, playtest.drawn(rig, "Water in "), "the grace is not counted down")
	rig.app.hud_hidden = true
	testing.expect(t, !playtest.drawn(rig, "FLOOD"), "F1 did not hide the round")
	rig.app.hud_hidden = false
	line := engine.game_debug_line(s)
	testing.expect(
		t,
		strings.has_prefix(
			line,
			fmt.tprintf("game flood: round %d Playing  rule ", v.round.round),
		),
		line,
	)

	// The reveal shows the result and the rule.
	v.round.phase, v.round.result, v.round.rule = .Reveal, .Won, .Tide
	testing.expect(t, playtest.drawn(rig, "ROUND WON"))
	testing.expect(t, playtest.drawn(rig, "TIDE: THE WATER SURGED AND FELL BACK"))

	// While F3 is open the engine gives the HUD only the screen below it (here from y 336):
	// all Flood draws stays inside, the banners shrunk to fit.
	testing.expect(t, playtest.drawn_within(rig, 336), "drawn outside the screen below F3")
}

// Every key of Flood's text table has its English.
@(test)
test_flood_text_table :: proc(t: ^testing.T) {
	key, missing := base.text_missing(flood.TEXT_EN)
	testing.expectf(t, !missing, "%v has no text", key)
	testing.expect_value(t, flood.tr(.Made_It, 2, 3), "2 of 3 made it")
	testing.expect_value(t, flood.rule_title(.Rot), "ROT: WET BLOCKS CRUMBLED")
}
