package arena_client

import "core:fmt"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:font"
import "client:hud"
import "client:testkit"
import "client:ui"
import "common:game"
import "games:arena"
import arena_server "games:arena/server"
import "server:core"

// Arena played whole: the server part on a stepped server, a session that joins it
// over the harness's network with this client part (fetching the game's pack as any
// pack), a second player beside it, and what the client draws: the HUD's line, the
// kill feed, the scoreboard, the results and the F3 line.

Rig :: struct {
	h:     core.Harness,
	s:     ^engine.Session,
	guest: core.Harness_Player,
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
test_arena_on_the_hud :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	config := core.Config {
		seed        = 33,
		view_radius = 3,
		view_height = 2,
		max_players = 2,
		listen      = true,
		rules       = engine.still_rules(),
		game        = arena_server.GAME,
	}
	if !testing.expect(t, core.harness_start(&rig.h, config)) {return}
	defer if rig.guest.h != nil {core.harness_player_free(&rig.guest)} 	// (once it joined)
	defer core.harness_stop(&rig.h)
	rig.s = new(engine.Session)
	defer free(rig.s)
	s := rig.s
	key: game.Account_Key
	game.account_key_set(&key, {0 ..< 32 = 7})
	engine.session_start(
		s,
		{
			name = "host",
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
	testing.expect_value(t, s.game.id, "arena")
	_, has_fighter := game.mode_find(s.reg, arena.FIGHTER_MODE)
	testing.expect(t, has_fighter, "the game's pack did not reach the client")

	// Alone over the LAN: the warm-up waits for a second player.
	core.harness_step(&rig.h, 10)
	v := view(s)
	testing.expect_value(t, v.match.phase, arena.Phase.Warmup)
	testing.expect_value(t, status(s), "ARENA  warm-up: waiting for players (1 of 2)")

	// A guest joins: the match.
	core.harness_player_join(&rig.h, &rig.guest, "guest")
	core.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			return view((^Rig)(data).s).match.phase == .Playing
		}, rig, 30 * game.TICK_RATE)
	if !testing.expect_value(t, v.match.phase, arena.Phase.Playing) {return}
	testing.expect_value(t, s.reg.game_modes[s.mode].id, arena.FIGHTER_MODE)

	// The host shoots the guest down (the engine's pipeline, as a shot does).
	srv := &rig.h.srv
	guest := core.harness_player_client(&rig.guest)
	host: ^core.Client
	for &c in srv.clients {if core.client_name(&c) == "host" {host = &c}}
	source := core.Damage_Source {
		kind     = .Weapon,
		attacker = core.player_id(srv, host),
		weapon   = "Rifle",
	}
	testing.expect_value(t, core.damage(srv, guest, 1000, source), core.Damage_Result.Killed)
	core.harness_step(&rig.h, 3)

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
	want := fmt.tprintf("ARENA  match %d   ", v.match.match)
	testing.expect(t, drawn(app, want), "the match is not on the HUD")
	testing.expect(
		t,
		drawn(app, "ARENA") && strings.contains(status(s), "you 1   leader host 1"),
		status(s),
	)
	testing.expect(t, drawn(app, "host [Rifle] guest"), "the kill is not in the feed")

	// The scoreboard: both fighters, the host first, with the frag and the death.
	testing.expect(t, drawn(app, "Arena: match 1, first to 15", scores = true), "no scoreboard")
	board, has_board := engine.game_scoreboard(s)
	testing.expect(t, has_board && len(board.rows) == 2, "the scoreboard does not list both")
	if len(board.rows) == 2 {
		testing.expect_value(t, board.rows[0].name, "host")
		testing.expect_value(t, board.rows[0].cells[0], "1")
		testing.expect(t, board.rows[0].you && !board.rows[1].you)
		testing.expect_value(t, board.rows[1].name, "guest")
		testing.expect_value(t, board.rows[1].cells[1], "1")
	}

	// F3.
	line := engine.game_debug_line(s)
	testing.expect(t, strings.has_prefix(line, "game arena: match 1 Playing  t="), line)

	// The results: the winner, big.
	v.match.phase, v.match.winner, v.match.top_frags = .Results, "host", 15
	testing.expect(t, drawn(app, "HOST WINS"), "no results banner")
	testing.expect(t, drawn(app, "next match in "))
}
