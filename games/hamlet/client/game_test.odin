package hamlet_client

import "core:strings"
import "core:testing"

import "client:engine"
import "client:playtest"
import "client:ui"
import "common:game"
import "games:hamlet"
import hamlet_server "games:hamlet/server"
import "server:core"

// Hamlet played whole: the server part on a stepped server, a session that joins it with
// this client part, and what the client does: the free camera over a planner with no
// body, the town's line and the toolbar, a toolbar's click that is the UI's and not the
// world's, a road dragged on the ground that the server lays, the overlay.

@(test)
test_hamlet_from_the_free_camera :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	// (this player joins over the network: the host's say over the speed is given it)
	o := playtest.Options {
		name            = "planner",
		seed            = 7,
		view_radius     = 4,
		everyone_cheats = true,
		ui              = true,
	}
	if !playtest.start(t, rig, hamlet_server.GAME, GAME, o) {return}
	defer playtest.stop(rig)
	s := rig.s
	ready :: proc(rig: ^playtest.Rig) -> bool {
		return view(rig.s).seed_known && hamlet_server.state(&rig.h.srv).phase == .Running
	}
	if !testing.expect(t, playtest.until(rig, ready, 60), "the village never ran") {return}
	playtest.step(rig, 20)
	v := view(s)
	srv := playtest.srv(rig)
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
	playtest.step(rig, 15)
	rig.actions.move = {}
	playtest.step(rig, 10)
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
	app := rig.app
	engine.screen_view_update(app)
	playtest.step(rig, 2)
	line := false
	for x in app.ui.texts {line ||= strings.has_prefix(x, "HAMLET  day 0   people 0")}
	testing.expect(t, line, "no town line")

	// A click on the toolbar's 2x is the UI's: the speed changes, and the world's tool
	// (the road, chosen first) does nothing with it.
	v.tool = .Road
	speed := find(app, "2x")
	if testing.expect(t, speed.w > 0, "no 2x button") {
		click(rig, {speed.x + speed.w / 2, speed.y + speed.h / 2})
		playtest.step(rig, 4)
		testing.expect_value(t, srv.sim_speed, 2)
		testing.expect_value(t, v.town.speed, 2)
		for p in engine.pointer_tool(s).buttons {testing.expect(t, !p.down && !p.released)}
	}

	// A road dragged on the ground: the server lays it.
	engine.screen_view_update(app)
	rig.input.mouse = {560, 360}
	playtest.step(rig, 2)
	tool := engine.pointer_tool(s)
	if !testing.expect(
		t,
		tool.on_ground && !tool.over_ui,
		"the pointer is not on the ground",
	) {return}
	a := tool.ground
	rig.input.mouse_pressed, rig.input.mouse_down = {.Left}, {.Left}
	playtest.step(rig, 1)
	rig.input.mouse = {720, 360}
	playtest.step(rig, 2)
	b := engine.pointer_tool(s).ground
	rig.input.mouse_released, rig.input.mouse_down = {.Left}, {}
	playtest.step(rig, 6)
	testing.expectf(t, a.x != b.x, "the drag went nowhere: %v %v", a, b)
	testing.expect_value(t, town.tiles[a.z][a.x], hamlet.Tile.Road)
	testing.expect_value(t, town.tiles[a.z][b.x], hamlet.Tile.Road)
	testing.expect_value(t, v.tiles[a.z][b.x], hamlet.Tile.Road)

	// A village laid out, at speed: its people come, and the client sees them walk.
	hamlet_server.plan(srv)
	core.sim_speed_set(srv, 4)
	playtest.step(rig, 300)
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
click :: proc(rig: ^playtest.Rig, p: [2]f32) {
	rig.input.mouse = p
	playtest.step(rig, 1)
	rig.input.mouse_pressed, rig.input.mouse_down = {.Left}, {.Left}
	playtest.step(rig, 1)
	rig.input.mouse_released, rig.input.mouse_down = {.Left}, {}
	playtest.step(rig, 1)
}
