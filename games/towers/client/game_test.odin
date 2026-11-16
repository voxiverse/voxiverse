package towers_client

import "core:fmt"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:font"
import "client:hud"
import "client:testkit"
import "client:ui"
import "common:game"
import "games:towers"
import towers_server "games:towers/server"
import "server:core"

// Towers played whole: the server part on a stepped server, a session that joins it
// over the harness's network with this client part (fetching the game's pack, its
// creeps and blocks with it), and what the client draws: the HUD's line, a wave's
// banner, the creeps' health bars, the tower's shots, the builders and the F3 line.

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
test_towers_on_the_hud :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	config := core.Config {
		seed        = 33,
		view_radius = 3,
		view_height = 2,
		max_players = 2,
		listen      = true,
		rules       = engine.still_rules(),
		game        = towers_server.GAME,
	}
	if !testing.expect(t, core.harness_start(&rig.h, config)) {return}
	defer core.harness_stop(&rig.h)
	rig.s = new(engine.Session)
	defer free(rig.s)
	s := rig.s
	key: game.Account_Key
	game.account_key_set(&key, {0 ..< 32 = 9})
	engine.session_start(
		s,
		{
			name = "builder",
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
	testing.expect_value(t, s.game.id, "towers")
	v := view(s)
	testing.expect(
		t,
		v.kinds[.Brute] != 0 && v.pieces[.Cannon] != game.NO_ITEM,
		"the pack did not reach the client",
	)
	core.harness_step(&rig.h, 10)
	testing.expect_value(t, v.run.phase, towers.Phase.Building)
	testing.expect(t, strings.has_prefix(status(s), "TOWERS  build!  first wave in "), status(s))
	testing.expect_value(t, mine(s).coins, towers.DEFAULT_SETTINGS.coins)

	// A tower by the gate, and the first wave: the banner, the shots, a creep hurt.
	srv := &rig.h.srv
	builder := &srv.clients[0]
	at := game.Block_Pos{towers.BUILD_MIN_X + 1, 0, towers.MID_Z + 2}
	builder.player.position = {f64(at.x) + 0.5, 3, f64(at.z) + 0.5}
	d := towers_server.state(srv)
	r := core.apply_edit(srv, builder, game.edit_plain(1, 0, at, d.blocks[.Arrow]))
	testing.expect(t, r.accepted, "the tower was refused")
	towers_server.wave_begin(srv)
	core.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			return view((^Rig)(data).s).shots > 0
		}, rig, 10 * game.TICK_RATE)
	testing.expect(t, v.shots > 0, "no shot was seen")
	testing.expect_value(t, v.run.phase, towers.Phase.Wave)
	hurt := false
	for _, e in s.entities {hurt ||= e.max_health > 0 && e.health < e.max_health}

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

	drawn :: proc(app: ^engine.App, prefix: string, scores := false) -> (found: bool) {
		if scores {app.actions.down += {.Player_List}} else {app.actions.down -= {.Player_List}}
		ui.begin_frame(&app.ui, {}, {1280, 720}, 1)
		hud.hud_draw(app, &app.ui)
		hud.player_list_draw(app, &app.ui)
		for x in app.ui.texts {found ||= strings.has_prefix(x, prefix)}
		ui.end_frame(&app.ui)
		return
	}
	testing.expect(t, drawn(app, "TOWERS  wave 1 of 10   creeps "), status(s))
	testing.expect(
		t,
		drawn(app, fmt.tprintf("WAVE 1: %d CREEPS", towers.wave_size(1))),
		"no wave banner",
	)
	testing.expect(t, hurt || v.shots > 0, "no creep was hurt")

	// The builders: one row, the player's own, with its coins and what it spent.
	testing.expect(t, drawn(app, "Towers: run 1, wave 1 of 10", scores = true), "no scoreboard")
	board, has_board := engine.game_scoreboard(s)
	if testing.expect(t, has_board && len(board.rows) == 1) {
		testing.expect_value(t, board.rows[0].name, "builder")
		testing.expect_value(t, board.rows[0].cells[2], fmt.tprint(towers.PIECES[.Arrow].price))
		testing.expect(t, board.rows[0].you)
	}

	// F3, and the run's end.
	line := engine.game_debug_line(s)
	testing.expect(t, strings.has_prefix(line, "game towers: run 1 Wave None  wave 1/10"), line)
	v.run.phase = .Results
	testing.expect(t, drawn(app, "a new run in "), "no results line")
}
