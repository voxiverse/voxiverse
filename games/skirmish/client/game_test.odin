package skirmish_client

import "core:testing"

import "client:engine"
import "client:overview"
import "client:playtest"
import "games:skirmish"
import skirmish_server "games:skirmish/server"
import "server:core"

// Skirmish played whole: the session joins its server part, takes a side, sees its base
// from the free camera with its line of stock and supply, the minimap and the fog; a box
// dragged over its workers picks them and the command panel offers their buildings; a
// right click on the ground sends them there, as an order the server carries out; Ctrl and
// a digit keeps a group a digit picks again.

@(test)
test_skirmish_from_the_free_camera :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	o := playtest.Options {
		name        = "commander",
		view_radius = 4,
		ui          = true,
	}
	if !playtest.start(t, rig, skirmish_server.GAME, GAME, o) {return}
	defer playtest.stop(rig)
	s := rig.s
	v := view(s)
	ready :: proc(rig: ^playtest.Rig) -> bool {
		v := view(rig.s)
		return v.match.phase == .Playing && v.economy.team != 0 && v.units[3].id != 0
	}
	if !playtest.until(rig, ready, 60) {
		testing.expectf(
			t,
			false,
			"never played a side: %v team %d server %v units %v",
			v.match.phase,
			v.economy.team,
			skirmish_server.state(playtest.srv(rig)).phase.now,
			v.units[:4],
		)
		return
	}
	playtest.step(rig, 30)
	testing.expect_value(t, s.game_camera.kind, engine.Game_Camera_Kind.Free)
	testing.expect(
		t,
		playtest.drawn(rig, "SKIRMISH   ore 150   wood 100   supply 4/10"),
		"no status line",
	)

	// A box over the whole screen picks the side's units and buildings on it.
	tool := engine.pointer_tool(s)
	ctx := &rig.app.ui
	playtest.draw(rig)
	tool.buttons[.Primary] = {
		pressed = true,
		down    = true,
		at      = {2, 2},
	}
	overview.selection_update(&v.sel, s, ctx, v.economy.team)
	tool.buttons[.Primary] = {
		released = true,
		at       = {2, 2},
	}
	ctx.input.mouse = {1278, 718}
	overview.selection_update(&v.sel, s, ctx, v.economy.team)
	tool.buttons = {} // (the release was this frame's)
	testing.expectf(
		t,
		len(selected_units(v)) == skirmish.START_WORKERS,
		"picked %d units",
		len(selected_units(v)),
	)
	testing.expect(t, playtest.drawn(rig, "4 units"), "the panel does not say what is picked")
	testing.expect(t, playtest.drawn(rig, "Barracks"), "the panel offers no barracks")

	// Ctrl and 1 keeps them as group 1; picked away, 1 picks them again.
	overview.group_keep(&v.sel, 1)
	overview.selection_clear(&v.sel)
	testing.expect(t, overview.group_pick(&v.sel, 1))
	testing.expect_value(t, len(selected_units(v)), skirmish.START_WORKERS)

	// A right click on the ground: they go there.
	srv := playtest.srv(rig)
	side := skirmish_server.side_of(srv, playtest.client(rig))
	goal := side.start + {12, 0}
	command(s, {released = true, clicked = true, from = {goal.x, skirmish.GROUND - 1, goal.y}})
	moved :: proc(rig: ^playtest.Rig) -> bool {
		srv := playtest.srv(rig)
		n := 0
		for &k in view(rig.s).units {
			h, ok := core.entity_find(srv.home, k.id)
			if ok && skirmish_server.mind(srv.home, h).order == .Move {n += 1}
		}
		return n == skirmish.START_WORKERS
	}
	testing.expect(t, playtest.until(rig, moved, 5), "the workers were not sent")

	// The minimap and the fog are made for the field.
	testing.expect(t, overview.fog_ready(&v.fog))
	testing.expect(
		t,
		overview.fog_sees(&v.fog, f64(side.start.x), f64(side.start.y)),
		"its base in the fog",
	)
	testing.expect(
		t,
		!overview.fog_sees(&v.fog, skirmish.MAP - 10, skirmish.MAP - 10),
		"the far corner seen",
	)
}
