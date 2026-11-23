package main

import "core:math"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:hud"
import "client:menu"
import "client:testkit"
import "common:game"

// The HUD: F1, the item-name popup and its fade; the health bar, the compass, the effects,
// the pickup feed and the target frame.

@(test)
test_popup_timing :: proc(t: ^testing.T) {
	stone := game.Stack{3, 1, 0, 0}
	p: engine.Item_Popup
	// The first frame in a world shows it, at once.
	hud.popup_update(&p, 0, stone, 0.016)
	testing.expect_value(t, hud.popup_alpha(&p, false), 1)
	// It holds, then fades over POPUP_FADE, then is gone.
	hud.popup_update(&p, 0, stone, hud.POPUP_HOLD - 0.1)
	testing.expect_value(t, hud.popup_alpha(&p, false), 1)
	hud.popup_update(&p, 0, stone, 0.1 + hud.POPUP_FADE / 2)
	a := hud.popup_alpha(&p, false)
	testing.expect(t, a > 0.4 && a < 0.6, "half faded")
	hud.popup_update(&p, 0, stone, hud.POPUP_FADE)
	testing.expect_value(t, hud.popup_alpha(&p, false), 0)
	// A slot change starts it again; an empty slot shows nothing.
	hud.popup_update(&p, 1, stone, 0.016)
	testing.expect_value(t, hud.popup_alpha(&p, false), 1)
	hud.popup_update(&p, 2, {}, 0.016)
	testing.expect_value(t, hud.popup_alpha(&p, false), 0)
	// Reduce motion: no fade; shown for the hold, then gone.
	hud.popup_update(&p, 3, stone, 0.016)
	hud.popup_update(&p, 3, stone, hud.POPUP_HOLD - 0.1)
	testing.expect_value(t, hud.popup_alpha(&p, true), 1)
	hud.popup_update(&p, 3, stone, 0.2)
	testing.expect_value(t, hud.popup_alpha(&p, true), 0)
	// A new world starts afresh.
	engine.popup_reset(&p)
	hud.popup_update(&p, 3, stone, 0.016)
	testing.expect_value(t, hud.popup_alpha(&p, false), 1)
}

@(test)
test_hud_f1 :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	app := f.app
	menu.player_menu_close(app)
	stone := game.item_of_block(testkit.test_reg(), .Stone)
	f.s.inventory.slots[0] = {stone, 5, 0, 0}
	f.s.inventory.selected = 0
	f.s.max_health = 20
	f.s.health = 20
	f.s.mode, _ = game.mode_find(f.s.reg, "survival") // (health is its ability)
	drawn := proc(app: ^engine.App) -> (vertices: int, texts: []string) {
		ui_frame(app)
		return len(app.ui.output.vertices), app.ui.texts[:]
	}
	shown, texts := drawn(app)
	testing.expect(t, shown > 0, "the HUD is drawn")
	named := false
	for x in texts {if x == menu.item_title(testkit.test_reg(), stone) {named = true}}
	testing.expect(t, named, "the held item's name is above the hotbar")

	press :: proc(app: ^engine.App) {
		app.input.pressed = {.F1}
		engine.actions_sync(app)
		hud.hud_keys(app)
		app.input.pressed = {}
		engine.actions_sync(app)
	}
	press(app)
	testing.expect(t, app.hud_hidden)
	hidden, _ := drawn(app)
	testing.expect_value(t, hidden, 0)
	press(app)
	testing.expect(t, !app.hud_hidden)
	again, _ := drawn(app)
	testing.expect(t, again > 0, "shown again")
}

// With the popup's fade running, a frame later it is dimmer (and the slot
// change starts it again).
@(private = "file")
ui_frame :: proc(app: ^engine.App) {
	ui_begin(app)
	hud.hud_draw(app, &app.ui)
	ui_end(app)
}

@(private = "file")
said :: proc(app: ^engine.App, text: string) -> bool {
	for x in app.ui.texts {if x == text {return true}}
	return false
}

@(private = "file")
said_part :: proc(app: ^engine.App, part: string) -> bool {
	for x in app.ui.texts {if strings.contains(x, part) {return true}}
	return false
}

// The health bar says the health in numbers; a hit leaves its trail and makes the
// screen's edge glow; the compass names the way the eyes face; worn gear that changes the
// character shows in the effects row.
@(test)
test_hud_health_compass_and_effects :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	app, s := f.app, f.s
	menu.player_menu_close(app)
	s.max_health, s.health = 20, 20
	ui_frame(app)
	testing.expect(t, said(app, "20 / 20"), "the health in numbers")
	s.health = 14
	ui_frame(app)
	testing.expect(t, said(app, "14 / 20"))
	testing.expect(t, s.feel.pulse.color.a > 0, "a hit makes the edge glow")
	testing.expect_value(t, s.hud.trail, 20)

	// Facing north (yaw 0) the N is in the middle; facing east, the E.
	s.camera.yaw = 0
	ui_frame(app)
	testing.expect(t, said(app, "N") && said(app, "NE") && said(app, "NW") && !said(app, "S"))
	s.camera.yaw = -math.PI / 2
	ui_frame(app)
	testing.expect(t, said(app, "E") && said(app, "SE") && !said(app, "W"))
	near :: proc(a, b: f32) -> bool {return abs(a - b) < 0.01}
	testing.expect(t, near(hud.compass_heading(-math.PI / 2), 90), "east is 90")
	testing.expect(t, near(hud.compass_bearing({0, 0, 0}, {0, 0, -5}), 0), "north is -z")
	testing.expect(t, near(hud.compass_bearing({0, 0, 0}, {5, 0, 0}), 90), "east is +x")
	testing.expect_value(t, hud.compass_offset(350, 10), -20)

	// The feather charm worn as a trinket: its air jump in the effects row.
	testing.expect(t, !said(app, "+1"))
	s.inventory.equipment[.Trinket_1] = {game.item_of_material(.Feather_Charm), 1, 0, 0}
	ui_frame(app)
	testing.expect(t, said(app, "+1"), "the charm's effect")
}

// The pickup feed: what comes into the inventory is a line ("+3 dirt"), the first look is
// no news, more of the same soon after adds to the line, and lines go after a while; the
// target frame names the creature under the crosshair with its health.
@(test)
test_hud_pickups_and_target :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	app, s := f.app, f.s
	menu.player_menu_close(app)
	reg := testkit.test_reg()
	dirt := game.item_of_block(reg, .Dirt)
	s.inventory.slots[3] = {dirt, 5, 0, 0}
	ui_frame(app)
	testing.expect(t, !said_part(app, "+5"), "what was there already is no news")
	s.inventory.slots[4] = {dirt, 3, 0, 0}
	ui_frame(app)
	testing.expect(t, said(app, "+3 dirt"))
	s.inventory.slots[4].count = 5
	ui_frame(app)
	testing.expect(t, said(app, "+5 dirt"), "more soon after joins the line")
	s.feel.clock += hud.PICKUP_SECONDS * game.TICK_RATE + 1
	ui_frame(app)
	testing.expect(t, !said(app, "+5 dirt"), "and it goes")

	shambler, known := game.registry_kind(reg, "voxiverse:shambler")
	if !testing.expect(t, known) {return}
	s.entities[9] = {
		kind       = shambler,
		health     = 6,
		max_health = 20,
	}
	defer delete(s.entities)
	s.hud.aimed = 9
	ui_frame(app)
	testing.expect(t, said(app, "shambler") && said(app, "6 / 20"), "the target frame")
	s.hud.aimed = nil
	s.feel.clock += hud.TARGET_HOLD * game.TICK_RATE + 1
	ui_frame(app)
	testing.expect(t, !said(app, "shambler"), "it goes once the crosshair has left it")
}

// The target frame's creature is one in sight: a solid block between the eyes and it
// hides it, a gate's frame too (it is a solid, targetable block); the open gate's surface
// (not targetable) does not.
@(test)
test_target_stops_at_blocks :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	s := f.s
	reg := testkit.test_reg()
	shambler, _ := game.registry_kind(reg, "voxiverse:shambler")
	e := engine.Other_Entity {
		kind = shambler,
	}
	engine.track_add(&e.track, {tick = 10, position = {0.5, 0, -6.5}})
	s.entities[9] = e
	defer delete(s.entities)
	s.render_clock = {
		time   = 10,
		newest = 10,
		heard  = true,
	}
	s.camera.position = {0.5, 1.6, 0.5}
	s.camera.yaw, s.camera.pitch = 0, 0 // (facing -z: the shambler 7 blocks ahead)
	World :: struct {
		at:    game.Block_Pos,
		block: game.Block,
	}
	w: World
	get :: proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
		w := (^World)(data)
		return w.block if p == w.at else .Air, true
	}
	query := game.Block_Query{&w, get, &reg.blocks, {}}
	aimed := proc(s: ^engine.Session, q: game.Block_Query) -> bool {
		engine.aim_update(s, q)
		_, ok := s.hud.aimed.?
		return ok
	}
	testing.expect(t, aimed(s, query), "nothing between: the shambler")
	for b in ([]game.Block{.Stone, .Gate_Ring, .Gate_Chevron}) {
		w = {{0, 1, -3}, b}
		testing.expectf(t, !aimed(s, query), "%v hides it", b)
	}
	w = {{0, 1, -3}, .Gate_Horizon}
	testing.expect(t, aimed(s, query), "the open gate's surface does not")
}
