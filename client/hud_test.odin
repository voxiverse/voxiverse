package client

import "core:testing"

import "../common/game"

// The HUD: F1, the item-name popup and its fade.

@(test)
test_popup_timing :: proc(t: ^testing.T) {
	stone := game.Stack{3, 1}
	p: Item_Popup
	// The first frame in a world shows it, at once.
	popup_update(&p, 0, stone, 0.016)
	testing.expect_value(t, popup_alpha(&p, false), 1)
	// It holds, then fades over POPUP_FADE, then is gone.
	popup_update(&p, 0, stone, POPUP_HOLD - 0.1)
	testing.expect_value(t, popup_alpha(&p, false), 1)
	popup_update(&p, 0, stone, 0.1 + POPUP_FADE / 2)
	a := popup_alpha(&p, false)
	testing.expect(t, a > 0.4 && a < 0.6, "half faded")
	popup_update(&p, 0, stone, POPUP_FADE)
	testing.expect_value(t, popup_alpha(&p, false), 0)
	// A slot change starts it again; an empty slot shows nothing.
	popup_update(&p, 1, stone, 0.016)
	testing.expect_value(t, popup_alpha(&p, false), 1)
	popup_update(&p, 2, {}, 0.016)
	testing.expect_value(t, popup_alpha(&p, false), 0)
	// Reduce motion: no fade; shown for the hold, then gone.
	popup_update(&p, 3, stone, 0.016)
	popup_update(&p, 3, stone, POPUP_HOLD - 0.1)
	testing.expect_value(t, popup_alpha(&p, true), 1)
	popup_update(&p, 3, stone, 0.2)
	testing.expect_value(t, popup_alpha(&p, true), 0)
	// A new world starts afresh.
	popup_reset(&p)
	popup_update(&p, 3, stone, 0.016)
	testing.expect_value(t, popup_alpha(&p, false), 1)
}

@(test)
test_hud_f1 :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	app := f.app
	player_menu_close(app)
	stone := game.item_of_block(test_reg(), .Stone)
	f.s.inventory.slots[0] = {stone, 5}
	f.s.inventory.selected = 0
	f.s.max_health = 20
	f.s.health = 20
	f.s.mode, _ = game.mode_find(f.s.reg, "survival") // (health is its ability)
	drawn := proc(app: ^App) -> (vertices: int, texts: []string) {
		ui_frame(app)
		return len(app.ui.output.vertices), app.ui.texts[:]
	}
	shown, texts := drawn(app)
	testing.expect(t, shown > 0, "the HUD is drawn")
	named := false
	for x in texts {if x == item_title(test_reg(), stone) {named = true}}
	testing.expect(t, named, "the held item's name is above the hotbar")

	press :: proc(app: ^App) {
		app.input.pressed = {.F1}
		actions_sync(app)
		hud_keys(app)
		app.input.pressed = {}
		actions_sync(app)
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
ui_frame :: proc(app: ^App) {
	ui_begin(app)
	hud_draw(app, &app.ui)
	ui_end(app)
}
