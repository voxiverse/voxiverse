package delve_client

import "core:fmt"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:playtest"
import "common:game"
import "games:delve"
import delve_server "games:delve/server"
import "server:core"

// Delve played whole: the server part on a stepped server, a session that joins it over
// the harness's network with this client part (fetching the game's pack), and what the
// client does and draws: the camera over the head, the pointer aiming, a game action
// pressed reaching the server, a hit's number, a creature's tag and bar, loot's label,
// the HUD's line, the delvers and the F3 line.

@(test)
test_delve_from_above :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(
		t,
		rig,
		delve_server.GAME,
		GAME,
		{name = "delver", seed = 41, view_radius = 4},
	) {return}
	defer playtest.stop(rig)
	s := rig.s
	playtest.until(
		rig,
		proc(rig: ^playtest.Rig) -> bool {return view(rig.s).dungeon.phase == .Delving},
		60,
	)
	if !testing.expect_value(t, view(s).dungeon.phase, delve.Phase.Delving) {return}
	playtest.step(rig, 20)
	v := view(s)
	srv := playtest.srv(rig)
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
		testing.expect_value(t, cut, i32(delve.WALL_HEIGHT))
	}
	testing.expect(t, !engine.crosshair_shown(s))

	// The pointer: a frame's view, then the pointer to the right of the middle: the
	// delver turns to face it (east: yaw -pi/2).
	engine.screen_view_update(rig.app)
	rig.input.mouse = {1100, 360}
	playtest.step(rig, 4)
	p, aimed := s.pointer.?
	testing.expect(t, aimed, "the pointer aims at nothing")
	testing.expectf(t, p.x > s.feet.x + 2, "the pointer's point %v is not east of %v", p, s.feet)
	testing.expectf(t, abs(s.camera.yaw + 1.5708) < 0.3, "the delver faces %v", s.camera.yaw)

	// The whirl (Z, the game's first action) reaches the server: its cooldown starts.
	rig.actions.pressed += {.Game_1}
	playtest.step(rig, 1)
	rig.actions.pressed -= {.Game_1}
	playtest.step(rig, 3)
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
	playtest.step(rig, 10)
	core.entity_harm(srv.home, h, {amount = 5, kind = .Hit, by = c})
	playtest.step(rig, 10)
	tagged := false
	elite: string
	for &tag in v.tags {
		if tag.id == id && tag.elite && tag.name_len > 0 {
			tagged, elite = true, string(tag.name[:tag.name_len])
		}
	}
	testing.expect(t, tagged, "the elite's tag never came")
	testing.expect(t, v.hits > 0, "no hit was told")

	testing.expect(t, playtest.drawn(rig, "DELVE  depth 1"), status(s))
	testing.expect(t, playtest.drawn(rig, "rare axe +40%"), "no loot label")
	testing.expect(t, playtest.drawn(rig, fmt.tprintf("%s, brute", elite)), "no elite's name")

	// The delvers, and F3.
	testing.expect(t, playtest.drawn(rig, "Delve: depth 1", scores = true), "no scoreboard")
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
