package playtest

import "core:strings"
import "core:testing"

import "client:engine"
import "client:font"
import "client:hud"
import "client:testkit"
import "client:ui"
import "common:access"
import "common:game"
import "server:core"

// A game's client tests' rig (only tests import this package): the game played whole.
// Its server part runs on a stepped server that listens; a session joins it over the
// harness's network with the game's client part (fetching its pack as any pack), and
// steps with it a frame a tick; an App draws what the session's HUD would, at
// 1280x720, so a test asks what was drawn; guests join beside it.
//
//	rig := new(playtest.Rig)
//	defer free(rig)
//	if !playtest.start(t, rig, flood_server.GAME, GAME) {return}
//	defer playtest.stop(rig)
//	testing.expect(t, playtest.drawn(rig, "FLOOD  round 1"))

MAX_GUESTS :: 3
WIDTH :: 1280
HEIGHT :: 720

Rig :: struct {
	h:       core.Harness,
	s:       ^engine.Session,
	app:     ^engine.App,
	input:   engine.Input_State, // the keys and the pointer, as the test sets them
	actions: engine.Actions, // the actions pressed and held, as the test sets them
	ui:      bool, // the HUD is drawn every frame (its hook marks the world, uses the pointer)
	guests:  [MAX_GUESTS]core.Harness_Player,
	joined:  int,
	games:   [1]engine.Game, // the session's (it keeps the slice)
}

// Options: what a test changes of the rig's world and player.
Options :: struct {
	name:            string, // the player's ("": "player")
	seed:            i64, // (0: 33)
	view_radius:     i32, // (0: 3)
	everyone_cheats: bool, // the joined player may do what the host may (/commands, settings)
	ui:              bool, // draw the HUD every frame, as the game does (Rig.ui)
	kit:             string, // the players' kit ("": the game's modes' own, as a game's world gives)
}

// start: the server part started, the session playing it, the App ready to draw; false
// (and the test told) when it was not.
start :: proc(
	t: ^testing.T,
	rig: ^Rig,
	server_game: core.Game,
	client_game: engine.Game,
	o := Options{},
) -> bool {
	radius := o.view_radius if o.view_radius > 0 else 3
	config := core.Config {
		seed              = o.seed if o.seed != 0 else 33,
		view_radius       = radius,
		view_height       = 2,
		max_players       = 1 + MAX_GUESTS,
		listen            = true,
		no_natural_spawns = true, // (nothing wanders in by chance)
		rules             = engine.still_rules(),
		game              = server_game,
		kit               = o.kit,
		allow_cheats      = o.everyone_cheats,
		everyone_cheats   = o.everyone_cheats,
	}
	if !testing.expect(t, core.harness_start(&rig.h, config), "no server") {return false}
	rig.ui = o.ui
	rig.games = {client_game}
	rig.s = new(engine.Session)
	key: access.Account_Key
	access.account_key_set(&key, {0 ..< 32 = 5})
	engine.session_start(
		rig.s,
		{
			name = o.name if o.name != "" else "player",
			key = key,
			join = engine.Join{address = core.harness_address(&rig.h)},
			view_radius = radius,
			view_height = 2,
			registry = testkit.test_reg(),
			net = &rig.h.net,
			games = rig.games[:],
		},
	)
	rig.app = new(engine.App)
	app := rig.app
	engine.app_clock_fix(app)
	app.settings = engine.SETTINGS_DEFAULTS
	ok: bool
	app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	app.window.width, app.window.height = WIDTH, HEIGHT
	core.harness_add(&rig.h, frame, rig)
	playing :: proc(rig: ^Rig) -> bool {return rig.s.state == .Playing}
	if !testing.expect(t, until(rig, playing, 100), "the session never played") {return false}
	testing.expect(t, engine.item_icons_init(rig.s.reg, &app.item_icons, &app.ui))
	app.session, app.screen = rig.s, .Game
	return true
}

// stop: the session ended, the server stopped, every player and the App freed.
stop :: proc(rig: ^Rig) {
	if rig.app != nil {
		rig.app.session = nil
		delete(rig.app.item_icons)
		ui.destroy(&rig.app.ui)
		free(rig.app)
		rig.app = nil
	}
	engine.session_end(rig.s, nil, nil)
	core.harness_stop(&rig.h)
	for i in 0 ..< rig.joined {core.harness_player_free(&rig.guests[i])}
	free(rig.s)
}

// frame: the session's frame each tick, the HUD drawn too when asked; a press and a
// release last one frame.
@(private = "file")
frame :: proc(data: rawptr) {
	rig := (^Rig)(data)
	drawing := rig.ui && rig.app.session != nil
	if drawing {rig.s.pointer_over_ui = ui.pointer_over(&rig.app.ui)}
	engine.session_update(
		rig.s,
		&rig.input,
		&rig.actions,
		engine.SETTINGS_DEFAULTS,
		{},
		game.TICK_SECONDS,
		true,
	)
	if drawing {
		engine.screen_view_update(rig.app)
		ui.begin_frame(&rig.app.ui, engine.ui_input(&rig.input, 1), {WIDTH, HEIGHT}, 1)
		hud.hud_draw(rig.app, &rig.app.ui)
		ui.end_frame(&rig.app.ui)
	}
	rig.input.mouse_pressed, rig.input.mouse_released = {}, {}
}

srv :: proc(rig: ^Rig) -> ^core.Server {return &rig.h.srv}

// step: n ticks of the server, the session and every guest.
step :: proc(rig: ^Rig, n := 1) {core.harness_step(&rig.h, n)}

// until: steps until done(rig) (false: not within seconds).
until :: proc(rig: ^Rig, done: proc(rig: ^Rig) -> bool, seconds := 20.0) -> bool {
	Wait :: struct {
		rig:  ^Rig,
		done: proc(rig: ^Rig) -> bool,
	}
	w := Wait{rig, done}
	_, ok := core.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			w := (^Wait)(data)
			return w.done(w.rig)
		}, &w, int(seconds * game.TICK_RATE))
	return ok
}

// guest_join: one more player joins (over the network, standing still); its client on
// the server once it plays (nil: it never did, within ten seconds).
guest_join :: proc(rig: ^Rig, name: string) -> ^core.Client {
	assert(rig.joined < MAX_GUESTS)
	p := &rig.guests[rig.joined]
	rig.joined += 1
	core.harness_player_join(&rig.h, p, name)
	Wait :: struct {
		p: ^core.Harness_Player,
	}
	w := Wait{p}
	core.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			c := core.harness_player_client((^Wait)(data).p)
			return c != nil && c.state == .Playing
		}, &w, 10 * game.TICK_RATE)
	return core.harness_player_client(p)
}

// client: the session's player on the server (its seat is its player id).
client :: proc(rig: ^Rig) -> ^core.Client {
	return &rig.h.srv.clients[rig.s.welcome.player]
}

// draw: one frame of the HUD as the App draws it (the player list's key held: scores),
// and the game's screen over it while it is open, what was drawn left in rig.app.ui until
// the next.
draw :: proc(rig: ^Rig, scores := false) {
	app := rig.app
	if scores {app.actions.down += {.Player_List}} else {app.actions.down -= {.Player_List}}
	engine.screen_view_update(app)
	engine.game_screen_sync(app)
	ui.begin_frame(&app.ui, {}, {WIDTH, HEIGHT}, 1)
	hud.hud_draw(app, &app.ui)
	hud.player_list_draw(app, &app.ui)
	engine.game_screen_draw(app, &app.ui, true)
}

// drawn: a frame of the HUD drew a text that begins with prefix.
drawn :: proc(rig: ^Rig, prefix: string, scores := false) -> (found: bool) {
	draw(rig, scores)
	for x in rig.app.ui.texts {found ||= strings.has_prefix(x, prefix)}
	ui.end_frame(&rig.app.ui)
	return
}

// drawn_within: a frame of the game's HUD given the screen below y (as under F3) drew
// nothing outside it.
drawn_within :: proc(rig: ^Rig, y: f32) -> bool {
	ui.begin_frame(&rig.app.ui, {}, {WIDTH, HEIGHT}, 1)
	engine.game_hud(rig.s, &rig.app.ui, y)
	low, high: f32 = 1e9, -1e9
	for v in rig.app.ui.output.layers[.Base].vertices {
		low, high = min(low, v.pos.y), max(high, v.pos.y)
	}
	ui.end_frame(&rig.app.ui)
	return low >= y && high <= HEIGHT
}
