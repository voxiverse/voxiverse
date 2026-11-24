package sandbox_client

import "core:strings"
import "core:testing"

import "client:engine"
import "client:menu"
import "client:playtest"
import "client:ui"
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

// A consumable used up shows in the HUD's effects row with its seconds left, as its player's
// server counts them, until they are up.
@(test)
test_sandbox_effect_shown :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, sandbox_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	c := playtest.client(rig)
	stim, _ := game.registry_item(s.registry, "sandbox:stim_patch")
	core.item_give(s, c, stim, 1)
	for st, i in c.inventory.slots {if st.item == stim {core.hotbar_select(s, c, i)}}
	testing.expect_value(t, core.item_consume(s, c), "")
	playtest.step(rig, 10)
	testing.expect_value(t, rig.s.effect, stim)
	testing.expect_value(t, rig.s.effect_left, 30)
	testing.expect(t, playtest.drawn(rig, "30 s"), "no effect in the HUD")
	playtest.step(rig, 31 * game.TICK_RATE)
	testing.expect_value(t, rig.s.effect_left, 0)
	testing.expect(t, !playtest.drawn(rig, "1 s"), "an effect past its time")
}

// The home world's creatures read well in the target frame and the journal: each a word or
// two, no id's colon or underscore.
@(test)
test_sandbox_creature_names :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, sandbox_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	reg := rig.s.reg
	names := sandbox_server.WILD_KINDS
	for id in names {
		kind, ok := game.registry_kind(reg, id)
		if !testing.expectf(t, ok, "no %s", id) {continue}
		name := menu.creature_name(reg, kind)
		testing.expectf(
			t,
			name != "" && strings.index_any(name, ":_") < 0,
			"%s reads %q",
			id,
			name,
		)
	}
}

// The quest tracker: in survival, the first quest under way and its step at the top right,
// with how far along it is; a step done says so (made's chime and gold words) and the next
// shows; Options' Quest tracker hides it, and a player in creative is shown none.
@(test)
test_sandbox_quest_tracker :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, sandbox_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	c := playtest.client(rig)
	fibre, _ := game.registry_item(s.registry, "sandbox:fibre")
	core.game_mode(s, c, "creative")
	playtest.step(rig, 4)
	testing.expect(t, !playtest.drawn(rig, "Waking at the Gate"), "a tracker in creative")
	core.game_mode(s, c, "survival")
	core.item_give(s, c, fibre, 2)
	playtest.step(rig, 4)
	testing.expect(t, playtest.drawn(rig, "Waking at the Gate"))
	testing.expect(t, playtest.drawn(rig, "Strip leaves for fibre"))
	testing.expect(t, playtest.drawn(rig, "2/6"))
	core.item_give(s, c, fibre, 4)
	playtest.step(rig, 4)
	testing.expect(t, playtest.drawn(rig, "Break gravel for flint"))
	said := false
	for &f in rig.s.feel.floats {said ||= string(f.text[:f.len]) == "Done: Strip leaves for fibre"}
	testing.expect(t, said, "the step done not said")
	rig.app.settings.quest_tracker = false
	testing.expect(t, !playtest.drawn(rig, "Break gravel for flint"), "a tracker turned off")
}

// The journal's Quests page, first where the registry has quests: those under way, then
// those done, and the one picked with its steps done, the one it is on and its reward.
@(test)
test_sandbox_journal_quests :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, sandbox_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	c := playtest.client(rig)
	core.game_mode(s, c, "survival")
	fibre, _ := game.registry_item(s.registry, "sandbox:fibre")
	flint, _ := game.registry_item(s.registry, "sandbox:flint")
	log_item, _ := game.registry_item(s.registry, "voxiverse:log")
	core.item_give(s, c, fibre, 6)
	core.item_give(s, c, flint, 5)
	core.item_give(s, c, log_item, 4)
	playtest.step(rig, 6)
	app := rig.app
	menu.player_menu_show(app, .Journal)
	drew :: proc(rig: ^playtest.Rig, prefix: string) -> (found: bool) {
		app := rig.app
		ui.begin_frame(&app.ui, {}, {playtest.WIDTH, playtest.HEIGHT}, 1)
		menu.player_menu_ui(app, &app.ui, true)
		for x in app.ui.texts {found ||= strings.has_prefix(x, prefix)}
		ui.end_frame(&app.ui)
		return
	}
	testing.expect(t, drew(rig, "Edge and Point"))
	testing.expect(t, drew(rig, "Waking at the Gate"))
	testing.expect(t, drew(rig, "Saw logs into planks"))
	testing.expect(t, drew(rig, "+1 field dressing")) // (its reward, in its slot)
	testing.expect(t, drew(rig, "Tracked"))
	testing.expect(t, !drew(rig, "Twist fibre into cord"), "a step to come shown")
}
