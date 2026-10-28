package client

import "core:slice"
import "core:testing"

import "ui"

@(test)
test_splashes_parse :: proc(t: ^testing.T) {
	got := splashes_parse("# a comment\n\nOne\n  Two  \n\n#three\r\nFour\r\n")
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, got[0], "One")
	testing.expect_value(t, got[1], "Two")
	testing.expect_value(t, got[2], "Four")
	// The shipped file has entries, the title's own line among them, and the
	// chosen one is stable.
	all := splashes_parse(SPLASHES)
	testing.expect(t, len(all) >= 1)
	testing.expect_value(t, slice.contains(all, "The Universe, voxelized."), true)
	for entry in all {
		testing.expect(t, entry != "")
	}
	testing.expect_value(t, splash_choose(all, 12345), splash_choose(all, 12345))
	testing.expect_value(t, splash_choose(nil, 5), "")
}

@(test)
test_title_buttons :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	app := f.app
	app.session = nil
	app.screen = .Title
	ui.begin_frame(&app.ui, {}, SCREEN, 1)
	title_screen(app, &app.ui)
	ui.end_frame(&app.ui)
	last: f32 = -1
	for label in ([]string{"Singleplayer", "Multiplayer", "Options", "Quit Game"}) {
		r, found := ui.find_widget(&app.ui, label)
		testing.expectf(t, found, "no %s button", label)
		testing.expectf(t, r.y > last, "%s is out of order", label)
		last = r.y
	}
	// The splash is picked by the clock, so any shipped entry is right.
	testing.expect_value(t, slice.contains(splashes_parse(SPLASHES), app.splash), true)
}
