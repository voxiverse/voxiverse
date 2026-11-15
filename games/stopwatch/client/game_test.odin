package stopwatch_client

import "core:fmt"
import "core:strings"
import "core:testing"

import "client:console"
import "client:engine"
import "client:font"
import "client:hud"
import "client:testkit"
import "client:ui"
import "common:game"
import "games:stopwatch"
import stopwatch_server "games:stopwatch/server"
import "server:core"

// The game played whole, as client/main's frame tests play the engine: the server part on
// a stepped server, a session that joins it over the harness's network with this client
// part, and the frame's HUD, F3 line and console command.

// Rig: the stepped server and the session it runs a frame of before each tick.
Rig :: struct {
	h:     core.Harness,
	s:     ^engine.Session,
	input: engine.Input_State,
	idle:  engine.Actions,
}

rig_frame :: proc(data: rawptr) {
	r := (^Rig)(data)
	engine.session_update(
		r.s,
		&r.input,
		&r.idle,
		engine.SETTINGS_DEFAULTS,
		{},
		game.TICK_SECONDS,
		true,
	)
}

@(test)
test_stopwatch_on_the_hud :: proc(t: ^testing.T) {
	rig := new(Rig) // (the heap: a Harness is large, a test thread's stack is not)
	defer free(rig)
	config := core.Config {
		seed              = 33,
		view_radius       = 3,
		view_height       = 2,
		max_players       = 2,
		listen            = true,
		no_natural_spawns = true,
		rules             = engine.still_rules(),
		game              = stopwatch_server.GAME,
	}
	if !testing.expect(t, core.harness_start(&rig.h, config)) {return}
	defer core.harness_stop(&rig.h)
	rig.s = new(engine.Session)
	defer free(rig.s)
	s := rig.s
	key: game.Account_Key
	game.account_key_set(&key, {0 ..< 32 = 3})
	engine.session_start(
		s,
		{
			name = "runner",
			key = key,
			join = engine.Join{address = core.harness_address(&rig.h)},
			view_radius = 3,
			view_height = 2,
			registry = testkit.test_reg(),
			net = &rig.h.net,
			games = {GAME},
		},
	)
	defer engine.session_end(s, nil, nil)
	core.harness_add(&rig.h, rig_frame, rig)
	core.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			return (^Rig)(data).s.state == .Playing
		}, rig, 3000)
	if !testing.expect_value(t, s.state, engine.Session_State.Playing) {return}
	testing.expect_value(t, s.game.id, "stopwatch")

	// Three seconds of play: the server's word every second, the time running.
	core.harness_step(&rig.h, 3 * game.TICK_RATE + 2)
	v := view(s)
	testing.expect(t, v.told >= 3, "the server's Times did not arrive")
	testing.expect(t, v.times.time >= 2 && v.times.time <= 3, "the time did not run")
	testing.expect_value(t, v.times.record, 0)

	app := new(engine.App)
	defer free(app)
	engine.app_clock_fix(app)
	app.settings = engine.SETTINGS_DEFAULTS
	ok: bool
	app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	defer ui.destroy(&app.ui)
	testing.expect(t, engine.item_icons_init(s.reg, &app.item_icons, &app.ui))
	defer delete(app.item_icons)
	console.console_init(&app.console)
	defer console.console_destroy(&app.console)
	app.session, app.screen = s, .Game
	defer app.session = nil

	// The HUD's line, with the engine's HUD (and hidden with it by F1).
	want := fmt.tprintf("Stopwatch  0:%02d   record 0:00", v.times.time)
	drawn :: proc(app: ^engine.App, text: string) -> (found: bool) {
		ui.begin_frame(&app.ui, {}, {1280, 720}, 1)
		hud.hud_draw(app, &app.ui)
		for x in app.ui.texts {found ||= x == text}
		ui.end_frame(&app.ui)
		return
	}
	testing.expect(t, drawn(app, want), "the stopwatch is not on the HUD")
	app.hud_hidden = true
	testing.expect(t, !drawn(app, want), "F1 did not hide the stopwatch")
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
	r := game.Received {
		kind  = game.game_kind(&s.schema, stopwatch.Record_Broken) or_else -1,
		op    = .Event,
		value = &broken,
	}
	received(s, r)
	v.times.record = 75
	testing.expect(t, strings.has_suffix(line(v), "record 1:15 (Steve_1)"), line(v))
}
