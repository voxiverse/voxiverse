package sandbox_client

import "core:testing"

import "client:engine"
import "client:menu"
import "client:playtest"
import "common:game"
import sandbox_server "games:sandbox/server"
import "server:core"

// The sandbox played whole: its server part on a stepped server and a session that joins
// it over the harness's network with this client part, playing it.

@(test)
test_sandbox_joined :: proc(t: ^testing.T) {
	rig := new(playtest.Rig) // (the heap: a Harness is large, a test thread's stack is not)
	defer free(rig)
	if !playtest.start(t, rig, sandbox_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	s := rig.s
	testing.expect_value(t, s.game.id, "sandbox")
	testing.expect_value(t, s.welcome.game, "sandbox")
	testing.expect_value(t, engine.game_debug_line(s), "")
}

// The ruin's fight shows as a bar across the top while the player is in one, and nothing
// shows while it is in none.
@(test)
test_sandbox_ruin_bar :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, sandbox_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	testing.expect(t, !playtest.drawn(rig, "RUIN"), "a bar with no fight")
	view(rig.s).ruin = {
		phase   = .Wave,
		wave    = 2,
		waves   = 5,
		alive   = 3,
		to_come = 4,
	}
	testing.expect(t, playtest.drawn(rig, "RUIN   wave 2 of 5   7 creatures left"))
	view(rig.s).ruin = {
		phase = .Break,
		wave  = 2,
		waves = 5,
		left  = 6,
	}
	testing.expect(t, playtest.drawn(rig, "RUIN   wave 2 of 5 held   the next in 6 s"))
}

// The crafting screen: its action opens it; every recipe shows what it makes and what it
// takes against what is carried, and the side says no fabricator is near and what the
// world's outposts are.
@(test)
test_sandbox_crafting_screen :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, sandbox_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	fibre, _ := game.registry_item(s.registry, "sandbox:fibre")
	core.item_give(s, playtest.client(rig), fibre, 3)
	playtest.step(rig, 10)
	testing.expect(
		t,
		!playtest.drawn(rig, "Fabrication"),
		"a crafting screen before it was opened",
	)
	craft_open(rig.s)
	testing.expect(t, playtest.drawn(rig, "Fabrication"))
	testing.expect(t, playtest.drawn(rig, "2 x Cord"))
	testing.expect(t, playtest.drawn(rig, "Fibre 3/3"))
	testing.expect(t, playtest.drawn(rig, "No fabricator near"))
	testing.expect(t, playtest.drawn(rig, "None yet: make a beacon"))
	testing.expect(t, playtest.drawn_within(rig, 720))
}

// An item's tooltip says what the survival loop's data makes of it: a tool's tier and speed,
// what a consumable does, the defence and fall guard an armour piece gives.
@(test)
test_sandbox_item_tooltips :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, sandbox_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	reg := rig.s.reg
	has :: proc(lines: []string, want: string) -> bool {
		for l in lines {if l == want {return true}}
		return false
	}
	Want :: struct {
		item, line: string,
	}
	for w in ([]Want{{"sandbox:flint_pick", "Common pick"}, {"sandbox:flint_pick", "Gathers tier 1"}, {"sandbox:flint_pick", "2.5x as fast as hands"}, {"sandbox:alloy_drill", "Yield +1"}, {"sandbox:field_dressing", "Common consumable"}, {"sandbox:field_dressing", "Heals 4"}, {"sandbox:stim_patch", "Harm -25% for 30 s"}, {"sandbox:padded_boots", "Defence +2%"}, {"sandbox:padded_boots", "Fall guard +25%"}}) {
		item, ok := game.registry_item(reg, w.item)
		if !testing.expectf(t, ok, "no %s", w.item) {continue}
		lines := menu.item_lines(reg, item)
		testing.expectf(t, has(lines, w.line), "%s: %v, not %q", w.item, lines, w.line)
	}
}
