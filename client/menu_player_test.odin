package client

import "core:strings"
import "core:testing"

import "platform"

// The player menu: the section table, the keys that open, switch and close
// it, Escape, the pad's View and bumpers, and what is above it.

@(private = "file")
tap :: proc(f: ^Overlay_Fixture, key: platform.Key) {
	f.app.input.pressed = {key}
	actions_sync(f.app)
	player_menu_keys(f.app)
	f.app.input.pressed = {}
	actions_sync(f.app)
}

@(test)
test_section_table :: proc(t: ^testing.T) {
	order := [?]Section_Id{.Map, .Journal, .Inventory, .Character, .Atlas, .Statistics}
	i := 0
	for id in Section_Id {
		testing.expect_value(t, id, order[i])
		i += 1
	}
	keys := [Section_Id]Action {
		.Map        = .World_Map,
		.Journal    = .Journal,
		.Inventory  = .Inventory,
		.Character  = .Character,
		.Atlas      = .Atlas,
		.Statistics = .Stats,
	}
	for sec, id in SECTIONS {
		testing.expect_value(t, sec.action, keys[id])
		shown := id == .Inventory || id == .Statistics
		testing.expectf(t, sec.visible == shown, "%v: visible is %v", id, sec.visible)
		testing.expectf(t, (sec.draw != nil) == shown, "%v: a draw proc iff shown", id)
	}
	// The defaults: Tab, E, K, M, J, C, L.
	b := DEFAULT_BINDINGS
	testing.expect_value(t, b.player_menu, platform.Key.Tab)
	testing.expect_value(t, b.inventory, platform.Key.E)
	testing.expect_value(t, b.stats, platform.Key.K)
	testing.expect_value(t, b.world_map, platform.Key.M)
	testing.expect_value(t, b.journal, platform.Key.J)
	testing.expect_value(t, b.character, platform.Key.C)
	testing.expect_value(t, b.atlas, platform.Key.L)
	testing.expect_value(t, b.toggle_hud, platform.Key.F1)
	// Stepping skips the hidden ones and wraps.
	testing.expect_value(t, section_step(.Inventory, 1), Section_Id.Statistics)
	testing.expect_value(t, section_step(.Statistics, 1), Section_Id.Inventory)
	testing.expect_value(t, section_step(.Inventory, -1), Section_Id.Statistics)
	testing.expect_value(t, section_step(.Statistics, -1), Section_Id.Inventory)
}

@(test)
test_player_menu_keys :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, true)
	defer overlay_fixture_destroy(&f)
	defer stats_view_destroy(&f.app.stats_view)
	app := f.app
	// (The fixture opened it with Tab: the inventory, the first time.)
	testing.expect(t, section_open(app, .Inventory))

	// A section's key closes the menu on its own section, and switches from another.
	tap(&f, .E)
	testing.expect(t, !overlay_is_open(&app.overlays, .Player_Menu), "E closes")
	tap(&f, .K)
	testing.expect(t, section_open(app, .Statistics), "K opens the statistics")
	tap(&f, .E)
	testing.expect(t, section_open(app, .Inventory), "E switches")
	tap(&f, .K)
	testing.expect(t, section_open(app, .Statistics))
	tap(&f, .K)
	testing.expect(t, !overlay_is_open(&app.overlays, .Player_Menu), "K closes")

	// Tab opens the last section and closes.
	tap(&f, .Tab)
	testing.expect(t, section_open(app, .Statistics), "Tab opens the last")
	tap(&f, .Tab)
	testing.expect(t, !overlay_is_open(&app.overlays, .Player_Menu), "Tab closes")

	// The hidden sections' keys do nothing, in the world and in the menu.
	for k in ([]platform.Key{.M, .J, .C, .L}) {
		tap(&f, k)
		testing.expectf(t, !overlay_is_open(&app.overlays, .Player_Menu), "%v does nothing", k)
	}
	tap(&f, .E)
	for k in ([]platform.Key{.M, .J, .C, .L}) {
		tap(&f, k)
		testing.expectf(t, section_open(app, .Inventory), "%v does nothing in the menu", k)
	}

	// No Q or E stepping off the slots: Q does nothing here.
	tap(&f, .Q)
	testing.expect(t, section_open(app, .Inventory))
	testing.expect_value(t, app.inventory_view.tab, Inventory_Tab.Inventory)

	// It does not pause the world; Escape closes it and opens nothing else.
	testing.expect(t, !world_paused(app))
	escape(app)
	testing.expect(t, !overlay_is_open(&app.overlays, .Player_Menu))
	testing.expect(
		t,
		!overlay_is_open(&app.overlays, .Game_Menu),
		"no game menu in the same press",
	)
	testing.expect_value(t, app.overlays.count, 0)
}

// What is above the menu gets the keys: the menu does not see them.
@(test)
test_player_menu_below_an_overlay :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	defer stats_view_destroy(&f.app.stats_view)
	app := f.app
	overlay_open(&app.overlays, .Quit_Dialog)
	tap(&f, .K)
	testing.expect(t, section_open(app, .Inventory), "K went to the dialog above, not the menu")
	tap(&f, .Tab)
	testing.expect(t, overlay_is_open(&app.overlays, .Player_Menu), "Tab too")
	overlay_close(&app.overlays, .Quit_Dialog)
	tap(&f, .K)
	testing.expect(t, section_open(app, .Statistics))
}

// Each section and the title draw (the pictures themselves are looked at by
// hand: the "Check by hand" list): a frame has vertices and says what a
// player reads.
@(test)
test_sections_draw :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, true)
	defer overlay_fixture_destroy(&f)
	defer stats_view_destroy(&f.app.stats_view)
	app := f.app
	says :: proc(app: ^App, what: string) -> bool {
		for x in app.ui.texts {if strings.contains(x, what) {return true}}
		return false
	}
	overlay_frame(&f, {})
	testing.expect(t, len(app.ui.output.vertices) > 0)
	testing.expect(t, says(app, "Inventory"), "the inventory's strip")
	testing.expect(t, says(app, "Statistics"))
	testing.expect(t, says(app, "(E)"), "the key of a section is on its tab")
	// The chest: no strip, the chest's title.
	f.s.inventory.chest_open = true
	overlay_frame(&f, {})
	testing.expect(t, says(app, "Chest"))
	f.s.inventory.chest_open = false
	player_menu_show(app, .Statistics)
	overlay_frame(&f, {})
	testing.expect(t, len(app.ui.output.vertices) > 0)
	testing.expect(t, says(app, "search") || says(app, "Statistics"))
}
