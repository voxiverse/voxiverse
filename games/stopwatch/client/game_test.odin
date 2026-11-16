package stopwatch_client

import "core:fmt"
import "core:strings"
import "core:testing"

import "client:console"
import "client:engine"
import "client:playtest"
import "common:game"
import "common:protocol"
import "games:stopwatch"
import stopwatch_server "games:stopwatch/server"

// The game played whole, as client/main's frame tests play the engine: the server part on
// a stepped server, a session that joins it over the harness's network with this client
// part, and the frame's HUD, F3 line and console command.

@(test)
test_stopwatch_on_the_hud :: proc(t: ^testing.T) {
	rig := new(playtest.Rig) // (the heap: a Harness is large, a test thread's stack is not)
	defer free(rig)
	if !playtest.start(t, rig, stopwatch_server.GAME, GAME, {name = "runner"}) {return}
	defer playtest.stop(rig)
	s := rig.s
	testing.expect_value(t, s.game.id, "stopwatch")

	// Three seconds of play: the server's word every second, the time running.
	playtest.step(rig, 3 * game.TICK_RATE + 2)
	v := view(s)
	testing.expect(t, v.told >= 3, "the server's Times did not arrive")
	testing.expect(t, v.times.time >= 2 && v.times.time <= 3, "the time did not run")
	testing.expect_value(t, v.times.record, 0)

	app := rig.app
	console.console_init(&app.console)
	defer console.console_destroy(&app.console)

	// The HUD's line, with the engine's HUD (and hidden with it by F1).
	want := fmt.tprintf("Stopwatch  0:%02d   record 0:00", v.times.time)
	testing.expect(t, playtest.drawn(rig, want), "the stopwatch is not on the HUD")
	app.hud_hidden = true
	testing.expect(t, !playtest.drawn(rig, want), "F1 did not hide the stopwatch")
	app.hud_hidden = false

	// F3 and the console.
	testing.expect_value(
		t,
		engine.game_debug_line(s),
		fmt.tprintf("game stopwatch: time %ds record 0s, told %d times", v.times.time, v.told),
	)
	console.console_execute(app, "stopwatch")
	said := false
	c := &app.console
	for i in 0 ..< c.count {
		said ||= c.lines[(c.first + i) % engine.CONSOLE_MAX_LINES].text == want
	}
	testing.expect(t, said, "the stopwatch command did not say the time")

	// A record broken as someone leaves: who broke it is shown beside it.
	broken := stopwatch.Record_Broken{"Steve_1", 75}
	r := protocol.Received {
		kind  = protocol.game_kind(&s.schema, stopwatch.Record_Broken) or_else -1,
		op    = .Event,
		value = &broken,
	}
	received(s, r)
	v.times.record = 75
	testing.expect(t, strings.has_suffix(line(v), "record 1:15 (Steve_1)"), line(v))
}
