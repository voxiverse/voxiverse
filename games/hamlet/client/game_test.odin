package hamlet_client

import "core:strings"
import "core:testing"

import "client:engine"
import "client:font"
import "client:hud"
import "client:testkit"
import "client:ui"
import "common:game"
import "games:hamlet"
import hamlet_server "games:hamlet/server"
import "server:core"

// Hamlet played whole: the server part on a stepped server, a session that joins it with
// this client part, and what the client does: the free camera over a planner with no
// body, the town's line and the toolbar, a toolbar's click that is the UI's and not the
// world's, a road dragged on the ground that the server lays, the overlay.

Rig :: struct {
	h:       core.Harness,
	s:       ^engine.Session,
	app:     ^engine.App,
	input:   engine.Input_State,
	actions: engine.Actions,
}

rig_frame :: proc(data: rawptr) {
	r := (^Rig)(data)
	if r.app != nil {r.s.pointer_over_ui = ui.pointer_over(&r.app.ui)}
	engine.session_update(
		r.s,
		&r.input,
		&r.actions,
		engine.SETTINGS_DEFAULTS,
		{},
		game.TICK_SECONDS,
		true,
	)
	if r.app != nil {
		// The frame's UI: the HUD (the game's hook marks the ground and uses the tools).
		engine.screen_view_update(r.app)
		ui.begin_frame(&r.app.ui, engine.ui_input(&r.input, 1), {1280, 720}, 1)
		hud.hud_draw(r.app, &r.app.ui)
		ui.end_frame(&r.app.ui)
	}
	r.input.mouse_pressed, r.input.mouse_released = {}, {}
}

@(test)
test_hamlet_from_the_free_camera :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	config := core.Config {
		seed            = 7,
		view_radius     = 4,
		view_height     = 2,
		max_players     = 2,
		listen          = true,
		rules           = engine.still_rules(),
		game            = hamlet_server.GAME,
		// (this player joins over the network: the host's say over the speed is given it)
		allow_cheats    = true,
		everyone_cheats = true,
	}
	if !testing.expect(t, core.harness_start(&rig.h, config)) {return}
	defer core.harness_stop(&rig.h)
	rig.s = new(engine.Session)
	defer free(rig.s)
	s := rig.s
	key: game.Account_Key
	game.account_key_set(&key, {0 ..< 32 = 6})
	engine.session_start(
		s,
		{
			name = "planner",
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
			return(
				r.s.state == .Playing &&
				view(r.s).seed_known &&
				hamlet_server.state(&r.h.srv).phase == .Running \
			)
		}, rig, 3000)
	if !testing.expect_value(t, s.state, engine.Session_State.Playing) {return}
	core.harness_step(&rig.h, 20)
	v := view(s)
	srv := &rig.h.srv
	town := hamlet_server.state(srv)

	// The camera: free, over the planner, which has no body.
	testing.expect_value(t, s.game_camera.kind, engine.Game_Camera_Kind.Free)
	testing.expect(t, engine.session_ability(s, .Bodiless), "the planner has a body")
	testing.expect(t, s.view.position.y > s.feet.y + 20, "the camera is not over the village")
	testing.expect(t, v.shaped, "the buildings' shapes did not resolve")
	testing.expect_value(t, v.ground.height, town.ground.height)

	// Panning: the focus moves along the screen by the input (predicted, the server's
	// the same).
	from := s.feet
	rig.actions.move = {1, 0}
	core.harness_step(&rig.h, 15)
	rig.actions.move = {}
	core.harness_step(&rig.h, 10)
	testing.expectf(t, s.feet.x > from.x + 3, "the focus did not pan: %v to %v", from, s.feet)
	c := &srv.clients[0]
	testing.expectf(
		t,
		abs(c.player.position.x - s.feet.x) < 0.01,
		"the server's focus %v, ours %v",
		c.player.position,
		s.feet,
	)

	// The HUD: the town's line and the toolbar.
	app := new(engine.App)
	defer free(app)
	rig.app = app
	defer rig.app = nil
	engine.app_clock_fix(app)
	app.settings = engine.SETTINGS_DEFAULTS
	ok: bool
	app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	defer ui.destroy(&app.ui)
	app.session, app.screen = s, .Game
	defer app.session = nil
	app.window.width, app.window.height = 1280, 720
	engine.screen_view_update(app)
	core.harness_step(&rig.h, 2)
	line := false
	for x in app.ui.texts {line ||= strings.has_prefix(x, "HAMLET  day 0   people 0")}
	testing.expect(t, line, "no town line")

	// A click on the toolbar's 2x is the UI's: the speed changes, and the world's tool
	// (the road, chosen first) does nothing with it.
	v.tool = .Road
	speed := find(app, "2x")
	if testing.expect(t, speed.w > 0, "no 2x button") {
		click(rig, {speed.x + speed.w / 2, speed.y + speed.h / 2})
		core.harness_step(&rig.h, 4)
		testing.expect_value(t, srv.sim_speed, 2)
		testing.expect_value(t, v.town.speed, 2)
		for p in engine.pointer_tool(s).buttons {testing.expect(t, !p.down && !p.released)}
	}

	// A road dragged on the ground: the server lays it.
	engine.screen_view_update(app)
	rig.input.mouse = {560, 360}
	core.harness_step(&rig.h, 2)
	tool := engine.pointer_tool(s)
	if !testing.expect(
		t,
		tool.on_ground && !tool.over_ui,
		"the pointer is not on the ground",
	) {return}
	a := tool.ground
	rig.input.mouse_pressed, rig.input.mouse_down = {.Left}, {.Left}
	core.harness_step(&rig.h, 1)
	rig.input.mouse = {720, 360}
	core.harness_step(&rig.h, 2)
	b := engine.pointer_tool(s).ground
	rig.input.mouse_released, rig.input.mouse_down = {.Left}, {}
	core.harness_step(&rig.h, 6)
	testing.expectf(t, a.x != b.x, "the drag went nowhere: %v %v", a, b)
	testing.expect_value(t, town.tiles[a.z][a.x], hamlet.Tile.Road)
	testing.expect_value(t, town.tiles[a.z][b.x], hamlet.Tile.Road)
	testing.expect_value(t, v.tiles[a.z][b.x], hamlet.Tile.Road)

	// A village laid out, at speed: its people come, and the client sees them walk.
	hamlet_server.plan(srv)
	core.sim_speed_set(srv, 4)
	core.harness_step(&rig.h, 300)
	testing.expectf(t, town.population >= 10, "%d people", town.population)
	citizens := 0
	citizen, _ := game.registry_kind(s.reg, hamlet.CITIZEN_KIND)
	for _, e in s.entities {if e.kind == citizen {citizens += 1}}
	testing.expectf(
		t,
		citizens >= 10,
		"the client sees %d citizens of %d",
		citizens,
		town.population,
	)

	// The overlay button cycles; the F3 line.
	overlay := find(app, "Overlay")
	click(rig, {overlay.x + 4, overlay.y + 4})
	testing.expect_value(t, v.overlay, Overlay.Access)
	debug_line := engine.game_debug_line(s)
	testing.expect(
		t,
		strings.has_prefix(debug_line, "game hamlet: seed 7 tool Road overlay Access"),
		debug_line,
	)
}

// find: where the last frame drew a button labelled text (zero: none).
find :: proc(app: ^engine.App, text: string) -> ui.Rect {
	r, _ := ui.find_widget(&app.ui, text)
	return r
}

// click: the left button pressed and released at p over two frames.
click :: proc(rig: ^Rig, p: [2]f32) {
	rig.input.mouse = p
	core.harness_step(&rig.h, 1)
	rig.input.mouse_pressed, rig.input.mouse_down = {.Left}, {.Left}
	core.harness_step(&rig.h, 1)
	rig.input.mouse_released, rig.input.mouse_down = {.Left}, {}
	core.harness_step(&rig.h, 1)
}
