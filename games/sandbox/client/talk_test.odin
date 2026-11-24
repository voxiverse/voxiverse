package sandbox_client

import "core:testing"

import "client:engine"
import "client:playtest"
import sandbox_server "games:sandbox/server"
import "server:core"

// A conversation as the player sees it (talk.odin): opened by using one of a camp's people,
// its name plate, line and the replies offered drawn from the dialogue, an answer sent and
// the next line shown, and the screen closed (Escape) leaving the conversation on the
// server too.
@(test)
test_talk_screen :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(
		t,
		rig,
		sandbox_server.GAME,
		GAME,
		{name = "visitor", everyone_cheats = true},
	) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	c := playtest.client(rig)
	planned :: proc(rig: ^playtest.Rig) -> bool {
		return sandbox_server.settlements_of(playtest.srv(rig)).planned
	}
	if !testing.expect(t, playtest.until(rig, planned, 10), "the camps never planned") {return}
	sandbox_server.settlement_command(s, c, {"ring"})
	ss := sandbox_server.settlements_of(s)
	i := ss.count - 1
	trader := sandbox_server.camp_folk(s, i)[1]
	if !testing.expect(t, trader != 0, "no trader") {return}
	core.teleport(s, c, core.entity_pos(s.home, trader) + {0, 0, 2}, {0, 0})
	playtest.step(rig, 2)
	testing.expect_value(t, sandbox_server.entity_use(s, c, trader, {}), "")
	talking :: proc(rig: ^playtest.Rig) -> bool {
		return view(rig.s).talk.person != 0 && engine.game_screen_shown(rig.s)
	}
	if !testing.expect(t, playtest.until(rig, talking, 5), "no conversation shown") {return}
	testing.expect(t, playtest.drawn(rig, "1.  Show me what you have."), "no first reply")
	testing.expect(t, playtest.drawn(rig, "Goods from three camps"), "no line")
	testing.expect(t, playtest.drawn(rig, "Leave"), "no way to leave")

	talk_say(rig.s, 1)
	moved :: proc(rig: ^playtest.Rig) -> bool {return view(rig.s).talk.node == 1}
	testing.expect(t, playtest.until(rig, moved, 5), "the answer did nothing")
	testing.expect(t, playtest.drawn(rig, "Each camp is short"), "not the next line")

	engine.game_screen_close(rig.s) // (Escape)
	playtest.draw(rig) // (the HUD sees it closed)
	left :: proc(rig: ^playtest.Rig) -> bool {
		return sandbox_server.talk_seat(playtest.srv(rig), playtest.client(rig)).person == 0
	}
	testing.expect(t, playtest.until(rig, left, 5), "the server still talks")
}
