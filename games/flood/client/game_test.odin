package flood_client

import "core:fmt"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:font"
import "client:hud"
import "client:testkit"
import "client:ui"
import "common:game"
import "games:flood"
import flood_server "games:flood/server"
import "server:core"

// Flood played whole: the server part on a stepped server, a session that joins it over
// the harness's network with this client part (fetching the game's pack as any pack),
// and the HUD and F3 line it draws.

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
test_flood_on_the_hud :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	config := core.Config {
		seed        = 33,
		view_radius = 3,
		view_height = 2,
		max_players = 2,
		listen      = true,
		rules       = engine.still_rules(),
		game        = flood_server.GAME,
	}
	if !testing.expect(t, core.harness_start(&rig.h, config)) {return}
	defer core.harness_stop(&rig.h)
	rig.s = new(engine.Session)
	defer free(rig.s)
	s := rig.s
	key: game.Account_Key
	game.account_key_set(&key, {0 ..< 32 = 5})
	engine.session_start(
		s,
		{
			name = "swimmer",
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
	testing.expect_value(t, s.game.id, "flood")
	_, has_out := game.mode_find(s.reg, flood.OUT_MODE)
	testing.expect(t, has_out, "the game's pack did not reach the client")

	// Into the round: the server's word arrives, and the player is a runner.
	core.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			return view((^Rig)(data).s).round.phase == .Playing
		}, rig, 20 * game.TICK_RATE)
	v := view(s)
	if !testing.expect_value(t, v.round.phase, flood.Phase.Playing) {return}
	testing.expect_value(t, v.round.players, 1)
	testing.expect_value(t, s.reg.game_modes[s.mode].id, flood.RUNNER_MODE)

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
	app.session, app.screen = s, .Game
	defer app.session = nil

	drawn :: proc(app: ^engine.App, prefix: string) -> (found: bool) {
		ui.begin_frame(&app.ui, {}, {1280, 720}, 1)
		hud.hud_draw(app, &app.ui)
		for x in app.ui.texts {found ||= strings.has_prefix(x, prefix)}
		ui.end_frame(&app.ui)
		return
	}
	want := fmt.tprintf("FLOOD  round %d   0:", v.round.round)
	testing.expect(t, drawn(app, want), "the round is not on the HUD")
	testing.expect(t, drawn(app, "Water in "), "the grace is not counted down")
	app.hud_hidden = true
	testing.expect(t, !drawn(app, "FLOOD"), "F1 did not hide the round")
	app.hud_hidden = false
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
	testing.expect(t, drawn(app, "ROUND WON"))
	testing.expect(t, drawn(app, "TIDE: THE WATER SURGED AND FELL BACK"))

	// While F3 is open the engine gives the HUD only the screen below it (here from y 336):
	// all Flood draws stays inside, the banners shrunk to fit.
	ui.begin_frame(&app.ui, {}, {1280, 720}, 1)
	engine.game_hud(s, &app.ui, 336)
	low, high: f32 = 1e9, -1e9
	for v in app.ui.output.layers[.Base].vertices {
		low, high = min(low, v.pos.y), max(high, v.pos.y)
	}
	ui.end_frame(&app.ui)
	testing.expectf(t, low >= 336 && high <= 720, "drawn from y %v to %v", low, high)
}
