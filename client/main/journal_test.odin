package main

import "core:mem/virtual"
import "core:testing"

import "client:engine"
import "client:menu"
import "client:testkit"
import "client:ui"
import "common:game"

// The journal: places noted once (one near another of its kind is that one), named or
// called by their kind, listed nearest first with how far and which way; the creatures met
// once each. The map: the ground round the player (its cells made in the session's arena
// the first time it is shown), the places listed beside it.
@(test)
test_journal_and_map :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	defer virtual.arena_destroy(&f.s.arena)
	app, s := f.app, f.s
	said :: proc(app: ^engine.App, text: string) -> bool {
		for x in app.ui.texts {if x == text {return true}}
		return false
	}
	menu.player_menu_show(app, .Journal)
	overlay_frame(&f, {})
	testing.expect(t, said(app, "Nothing found yet") && said(app, "None met yet"))

	engine.journal_place(s, .Gate, {10, 5, -100})
	engine.journal_place(s, .Gate, {12, 5, -98}) // (the same gate)
	engine.journal_place(s, .Ruin, {-300, 5, 0}, "Old ruin")
	testing.expect_value(t, s.journal.place_count, 2)
	shambler, _ := game.registry_kind(testkit.test_reg(), "voxiverse:shambler")
	engine.journal_meet(s, shambler)
	engine.journal_meet(s, shambler)
	testing.expect_value(t, s.journal.met_count, 1)
	overlay_frame(&f, {})
	testing.expect(t, said(app, "Gate") && said(app, "100 m N"), "the gate, 100 m north")
	testing.expect(t, said(app, "Old ruin") && said(app, "300 m W"), "the ruin by its name")
	testing.expect(t, said(app, "shambler"), "the creature met")
	near := menu.places_by_distance(&s.journal, {})
	testing.expect(t, len(near) == 2 && near[0].kind == .Gate, "nearest first")

	// M: the map, its ground made the first time; the places beside it.
	menu.player_menu_show(app, .Map)
	overlay_frame(&f, {})
	testing.expect(t, menu.section_open(app, .Map))
	testing.expect(t, len(s.world_map.colors) > 0, "the map's cells")
	testing.expect(t, said(app, "256 m across") && said(app, "Old ruin"))
	lo := s.world_map.lo
	s.feet = {200, 0, 0} // walked off its middle: it follows
	overlay_frame(&f, {})
	testing.expect(t, s.world_map.lo.x > lo.x)

	// Everything on a 1280x720 screen.
	ui.begin_frame(&app.ui, {}, SCREEN, 1)
	panel, _, _ := menu.player_menu_panel(&app.ui)
	ui.end_frame(&app.ui)
	testing.expect(
		t,
		panel.x >= 0 &&
		panel.y >= 0 &&
		panel.x + panel.w <= SCREEN.x &&
		panel.y + panel.h <= SCREEN.y,
	)
}
