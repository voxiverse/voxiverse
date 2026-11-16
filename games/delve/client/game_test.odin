package delve_client

import "core:fmt"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:font"
import "client:hud"
import "client:testkit"
import "client:ui"
import "common:game"
import "games:delve"
import delve_server "games:delve/server"
import "server:core"

// Delve played whole: the server part on a stepped server, a session that joins it over
// the harness's network with this client part (fetching the game's pack), and what the
// client does and draws: the camera over the head, the pointer aiming, a game action
// pressed reaching the server, a hit's number, a creature's tag and bar, loot's label,
// the HUD's line, the delvers and the F3 line.

Rig :: struct {
	h:       core.Harness,
	s:       ^engine.Session,
	input:   engine.Input_State,
	actions: engine.Actions,
}

rig_frame :: proc(data: rawptr) {
	r := (^Rig)(data)
	engine.session_update(
		r.s,
		&r.input,
		&r.actions,
		engine.SETTINGS_DEFAULTS,
		{},
		game.TICK_SECONDS,
		true,
	)
}

@(test)
test_delve_from_above :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	config := core.Config {
		seed        = 41,
		view_radius = 4,
		view_height = 2,
		max_players = 2,
		listen      = true,
		rules       = engine.still_rules(),
		game        = delve_server.GAME,
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
			name = "delver",
			key = key,
			join = engine.Join{address = core.harness_address(&rig.h)},
			view_radius = 4,
			view_height = 2,
			registry = testkit.test_reg(),
			net = &rig.h.net,
			games = {GAME},
		},
	)
	defer engine.session_end(s, nil, nil)
	core.harness_add(&rig.h, rig_frame, rig)
	core.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			r := (^Rig)(data)
			return r.s.state == .Playing && view(r.s).dungeon.phase == .Delving
		}, rig, 3000)
	if !testing.expect_value(t, s.state, engine.Session_State.Playing) {return}
	core.harness_step(&rig.h, 20)
	v := view(s)
	srv := &rig.h.srv
	c := &srv.clients[0]
	testing.expect_value(t, v.dungeon.depth, 1)
	testing.expect(t, v.items[.Axe] != game.NO_ITEM, "the pack did not reach the client")
	testing.expect_value(t, s.game_camera.kind, engine.Game_Camera_Kind.Top_Down)
	testing.expect(
		t,
		s.view.position.y > s.camera.position.y + 10,
		"the camera is not over the head",
	)
	if cut, has := s.view.cut.?; testing.expect(t, has, "no cut") {
		testing.expect_value(t, cut, i32(3))
	}
	testing.expect(t, !engine.crosshair_shown(s))

	// The pointer: a frame's view, then the pointer to the right of the middle: the
	// delver turns to face it (east: yaw -pi/2).
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
	app.window.width, app.window.height = 1280, 720
	engine.screen_view_update(app)
	rig.input.mouse = {1100, 360}
	core.harness_step(&rig.h, 4)
	p, aimed := s.pointer.?
	testing.expect(t, aimed, "the pointer aims at nothing")
	testing.expectf(t, p.x > s.feet.x + 2, "the pointer's point %v is not east of %v", p, s.feet)
	testing.expectf(t, abs(s.camera.yaw + 1.5708) < 0.3, "the delver faces %v", s.camera.yaw)

	// The whirl (Z, the game's first action) reaches the server: its cooldown starts.
	rig.actions.pressed += {.Game_1}
	core.harness_step(&rig.h, 1)
	rig.actions.pressed -= {.Game_1}
	core.harness_step(&rig.h, 3)
	testing.expect(
		t,
		delve_server.seat(srv, c).whirl_at > srv.tick,
		"the whirl never reached the server",
	)
	testing.expect(t, mine(s).hero.whirl > 0, "the whirl's cooldown was not told")

	// A creature near: its tag and its bar; struck, its number floats up; loot beside it.
	delve_server.clear_dungeon(srv)
	h := delve_server.foe_spawn(srv, .Brute, c.player.position + {3, 0, 0}, true)
	id := core.entity_id(srv.home, h)
	core.item_drop(
		srv,
		srv.home,
		c.player.position + {-2, 0.5, 0},
		{v.items[.Axe], 1, 0, delve.loot_data(.Rare, 40)},
	)
	core.harness_step(&rig.h, 10)
	core.entity_harm(srv.home, h, {amount = 5, kind = .Hit, by = c})
	core.harness_step(&rig.h, 10)
	tagged := false
	elite: string
	for &tag in v.tags {
		if tag.id == id && tag.elite && tag.name_len > 0 {
			tagged, elite = true, string(tag.name[:tag.name_len])
		}
	}
	testing.expect(t, tagged, "the elite's tag never came")
	testing.expect(t, v.hits > 0, "no hit was told")

	drawn :: proc(app: ^engine.App, prefix: string, scores := false) -> (found: bool) {
		if scores {app.actions.down += {.Player_List}} else {app.actions.down -= {.Player_List}}
		ui.begin_frame(&app.ui, {}, {1280, 720}, 1)
		hud.hud_draw(app, &app.ui)
		hud.player_list_draw(app, &app.ui)
		for x in app.ui.texts {found ||= strings.has_prefix(x, prefix)}
		ui.end_frame(&app.ui)
		return
	}
	testing.expect(t, drawn(app, "DELVE  depth 1"), status(s))
	testing.expect(t, drawn(app, "rare axe +40%"), "no loot label")
	testing.expect(t, drawn(app, fmt.tprintf("%s, brute", elite)), "no elite's name")

	// The delvers, and F3.
	testing.expect(t, drawn(app, "Delve: depth 1", scores = true), "no scoreboard")
	board, has_board := engine.game_scoreboard(s)
	if testing.expect(t, has_board && len(board.rows) == 1) {
		testing.expect_value(t, board.rows[0].name, "delver")
		testing.expect(t, board.rows[0].you)
	}
	line := engine.game_debug_line(s)
	testing.expect(
		t,
		strings.has_prefix(
			line,
			fmt.tprintf("game delve: depth 1 Delving seed %d", v.dungeon.seed),
		),
		line,
	)
}
