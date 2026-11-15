package main

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"

import "client:audio"
import "client:console"
import "client:dev"
import "client:engine"
import "client:font"
import "client:hud"
import "client:testkit"
import "client:ui"
import "common:game"
import "generated:games"
import games_client "generated:games/client"
import "server:core"

// A world playing a game (engine.Game): the server names it in Welcome, the session takes
// the client part of the same id, and that part's hooks run: started, its records
// received, its HUD, its F3 line and its console command. The game is the tests' own,
// declared as a games/ folder would declare it.

Count :: struct {
	ticks: u32,
}

COUNTER_KINDS :: game.Game_Kinds {
	states = {{name = "counter.count", value = Count}},
}

COUNTER_INFO :: game.Game_Info {
	id          = "counter",
	name        = "Counter",
	description = "The server's tick, counted.",
}

// The server part: every player is told the server's tick, every tick.
COUNTER_SERVER :: core.Game {
	info  = COUNTER_INFO,
	kinds = COUNTER_KINDS,
	tick  = counter_tick,
}

counter_tick :: proc(s: ^core.Server) {
	count := Count{u32(s.tick)}
	for &c in s.clients {
		if c.state == .Playing {core.game_put(s, &c, &count)}
	}
}

// The client part keeps the count, draws it, says it on F3 and to its command.
Counter_View :: struct {
	started:  bool,
	received: int,
	count:    Count,
	screen:   ui.Rect, // what its HUD was last given
}

COUNTER_CLIENT :: engine.Game {
	info = COUNTER_INFO,
	kinds = COUNTER_KINDS,
	state = Counter_View,
	started = proc(s: ^engine.Session) {engine.game_state(s, Counter_View).started = true},
	received = counter_received,
	hud = proc(s: ^engine.Session, ctx: ^ui.Context) {
		view := engine.game_state(s, Counter_View)
		view.screen = ctx.screen
		ui.label(
			ctx,
			fmt.tprintf("count %d", view.count.ticks),
			ctx.screen,
			.Center,
			ctx.theme.text,
		)
	},
	debug = proc(s: ^engine.Session) -> string {
		return fmt.tprintf("count %d", engine.game_state(s, Counter_View).count.ticks)
	},
	commands = {{"count", "count: say the count", counter_command}},
}

counter_received :: proc(s: ^engine.Session, r: game.Received) {
	view := engine.game_state(s, Counter_View)
	if count, ok := engine.game_value(s, r, Count); ok && count != nil {
		view.count = count^
		view.received += 1
	}
}

counter_command :: proc(app: ^engine.App, args: []string) {
	count := engine.game_state(app.session, Counter_View).count
	engine.console_print(&app.console, fmt.tprintf("the count is %d", count.ticks))
}

// game_join: a session joining the rig's server (which plays server_game) with the
// client games games, stepped until it plays or fails.
game_join :: proc(
	t: ^testing.T,
	rig: ^Frame_Rig,
	s: ^engine.Session,
	server_game: core.Game,
	games: []engine.Game,
) -> bool {
	config := core.Config {
		seed              = 33,
		view_radius       = 3,
		view_height       = 2,
		max_players       = 2,
		listen            = true,
		no_natural_spawns = true,
		rules             = engine.still_rules(),
		game              = server_game,
	}
	if !testing.expect(t, core.harness_start(&rig.h, config)) {return false}
	key: game.Account_Key
	game.account_key_set(&key, {0 ..< 32 = 5})
	engine.session_start(
		s,
		{
			name = "counter",
			key = key,
			join = engine.Join{address = core.harness_address(&rig.h)},
			view_radius = 3,
			view_height = 2,
			registry = testkit.test_reg(),
			net = &rig.h.net,
			games = games,
		},
	)
	rig_add(rig, s)
	core.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			s := (^Frame_Rig)(data).s
			return s.state == .Playing || s.state == .Failed
		}, rig, 3000)
	return true
}

@(test)
test_world_plays_a_game :: proc(t: ^testing.T) {
	rig := new(Frame_Rig)
	defer free(rig)
	s := new(engine.Session)
	defer free(s)
	games := []engine.Game{COUNTER_CLIENT}
	if !game_join(t, rig, s, COUNTER_SERVER, games) {return}
	defer core.harness_stop(&rig.h)
	defer engine.session_end(s, nil, nil)
	if !testing.expect_value(t, s.state, engine.Session_State.Playing) {return}
	testing.expect_value(t, s.game.id, "counter")
	view := engine.game_state(s, Counter_View)
	testing.expect(t, view.started, "the game's started hook did not run")
	for _ in 0 ..< 10 {rig_frame(rig, nil)}
	testing.expect(t, view.received >= 5, "the game's records did not arrive")
	testing.expect(t, view.count.ticks > 0 && u64(view.count.ticks) <= rig.h.srv.tick)

	// Its HUD with the engine's, its F3 line, its console command.
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
	ui_begin(app)
	hud.hud_draw(app, &app.ui)
	shown := false
	for text in app.ui.texts {shown ||= text == fmt.tprintf("count %d", view.count.ticks)}
	ui_end(app)
	testing.expect(t, shown, "the game's HUD was not drawn")
	testing.expect_value(t, view.screen, ui.Rect{0, 0, SCREEN.x, SCREEN.y})
	// With F3 open (drawn first, as app_ui does), the game's HUD is given the screen
	// below the overlay, so neither covers the other.
	mixer := new(audio.Mixer)
	defer free(mixer)
	audio.mixer_init(mixer, audio.DEVICE_RATE)
	app.mixer = mixer
	ui_begin(app)
	dev.debug_overlay(app, &app.ui)
	hud.hud_draw(app, &app.ui)
	ui_end(app)
	testing.expect(t, app.debug_bottom > 100, "F3 did not say how far down it reaches")
	testing.expect_value(t, view.screen.y, app.debug_bottom)
	testing.expect_value(t, view.screen.y + view.screen.h, SCREEN.y)
	testing.expect_value(t, app.ui.screen, ui.Rect{0, 0, SCREEN.x, SCREEN.y})
	testing.expect_value(
		t,
		engine.game_debug_line(s),
		fmt.tprintf("game counter: count %d", view.count.ticks),
	)
	console.console_execute(app, "count")
	said := false
	c := &app.console
	for i in 0 ..< c.count {
		said ||= strings.has_prefix(
			c.lines[(c.first + i) % engine.CONSOLE_MAX_LINES].text,
			"the count is ",
		)
	}
	testing.expect(t, said, "the game's command did not run")
}

// A server playing a game this client does not have, or with other records of it: the
// session fails with the reason, before playing.
@(test)
test_world_game_refused :: proc(t: ^testing.T) {
	context.logger = log.nil_logger() // (the refusal is logged: the point)
	{
		rig := new(Frame_Rig)
		defer free(rig)
		s := new(engine.Session)
		defer free(s)
		if !game_join(t, rig, s, COUNTER_SERVER, nil) {return}
		defer core.harness_stop(&rig.h)
		defer engine.session_end(s, nil, nil)
		testing.expect_value(t, s.state, engine.Session_State.Failed)
		testing.expect_value(
			t,
			s.failure,
			"the server plays counter, a game this version does not have",
		)
	}
	{
		Other :: struct {
			ticks: u64,
		}
		other := COUNTER_CLIENT
		other.kinds = {
			states = {{name = "counter.count", value = Other}},
		}
		rig := new(Frame_Rig)
		defer free(rig)
		s := new(engine.Session)
		defer free(s)
		if !game_join(t, rig, s, COUNTER_SERVER, {other}) {return}
		defer core.harness_stop(&rig.h)
		defer engine.session_end(s, nil, nil)
		testing.expect_value(t, s.state, engine.Session_State.Failed)
		testing.expect(
			t,
			strings.has_prefix(s.failure, "the server runs a different version"),
			s.failure,
		)
	}
}

// A Game read from the lists of games outlives the procedure that read it: its kinds are
// slices, which a constant list built on that procedure's stack (the dedicated server's
// game_find returned one that dangled, and its server failed to start).
@(test)
test_game_lists_outlive_their_readers :: proc(t: ^testing.T) {
	taken :: proc(i: int) -> core.Game {return games.SERVER[i]}
	scrub :: proc() -> (sum: int) {
		junk: [16384]u8
		for &b, i in junk {b = u8(i * 7 + 1)}
		for b in junk {sum += int(b)}
		return
	}
	for i in 0 ..< len(games.SERVER) {
		g := taken(i)
		testing.expect(t, scrub() > 0)
		for k in g.kinds.states {testing.expectf(t, strings.has_prefix(k.name, g.id), "%s: kind %q", g.id, k.name)}
		for k in g.kinds.events {testing.expectf(t, strings.has_prefix(k.name, g.id), "%s: kind %q", g.id, k.name)}
	}
}

// With no --game, a world of our own plays the sandbox: the game chosen is the default,
// this build has both its parts, and a session playing the server part the App hosts
// with (on the stepped server, where the embedded server runs on its own thread) plays it.
@(test)
test_no_game_plays_sandbox :: proc(t: ^testing.T) {
	id := game_chosen({})
	testing.expect_value(t, id, "sandbox")
	testing.expect(t, game_playable(id), "this build cannot play the default game")
	app := new(engine.App)
	defer free(app)
	app.games, app.server_games, app.game = games_client.CLIENT, games.SERVER, id
	hosted := engine.host_game(app, app.game)
	testing.expect_value(t, hosted.id, "sandbox")

	rig := new(Frame_Rig)
	defer free(rig)
	s := new(engine.Session)
	defer free(s)
	if !game_join(t, rig, s, hosted, app.games) {return}
	defer core.harness_stop(&rig.h)
	defer engine.session_end(s, nil, nil)
	if !testing.expect_value(t, s.state, engine.Session_State.Playing) {return}
	testing.expect_value(t, s.game.id, "sandbox")
	testing.expect_value(t, s.welcome.game, "sandbox")
}
