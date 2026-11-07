package main

import "core:slice"
import "core:strings"
import "core:testing"

import "client:screen"
import "client:ui"

@(test)
test_splashes_parse :: proc(t: ^testing.T) {
	got := screen.splashes_parse("# a comment\n\nOne\n  Two  \n\n#three\r\nFour\r\n")
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, got[0], "One")
	testing.expect_value(t, got[1], "Two")
	testing.expect_value(t, got[2], "Four")
	// The shipped file has entries (which ones is the owner's to edit, so the
	// test pins none of them) and the chosen one is stable.
	all := screen.splashes_parse(screen.SPLASHES)
	testing.expect(t, len(all) >= 1)
	for entry in all {
		testing.expect(t, entry != "")
	}
	testing.expect_value(t, screen.splash_choose(all, 12345), screen.splash_choose(all, 12345))
	testing.expect_value(t, screen.splash_choose(nil, 5), "")
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
	screen.title_screen(app, &app.ui)
	ui.end_frame(&app.ui)
	last: f32 = -1
	for label in ([]string{"Singleplayer", "Multiplayer", "Options", "Quit Game"}) {
		r, found := ui.find_widget(&app.ui, label)
		testing.expectf(t, found, "no %s button", label)
		testing.expectf(t, r.y > last, "%s is out of order", label)
		last = r.y
	}
	// The splash is picked by the clock, so any shipped entry is right.
	testing.expect_value(
		t,
		slice.contains(screen.splashes_parse(screen.SPLASHES), app.splash),
		true,
	)
}

// The splash arrives as a transmission: dial glyphs resolving into the text
// from the left over SPLASH_REVEAL seconds; with reduce motion it is simply there.
@(test)
test_splash_resolves_from_glyphs :: proc(t: ^testing.T) {
	text := "Not a modpack"
	at0, _ := screen.splash_reveal(text, 0, false)
	testing.expect(t, at0 != text, "at once: glyphs")
	testing.expect(t, !strings.contains(at0, "N"), "no letter resolved yet")
	testing.expect_value(t, strings.count(at0, " "), 2) // spaces stay spaces
	half, _ := screen.splash_reveal(text, screen.SPLASH_REVEAL / 2, false)
	testing.expect(t, strings.has_prefix(half, "Not a"), "half way: the first half resolved")
	testing.expect(t, half != text, "half way: not all of it")
	done, _ := screen.splash_reveal(text, screen.SPLASH_REVEAL, false)
	testing.expect_value(t, done, text)
	still, _ := screen.splash_reveal(text, 0, true)
	testing.expect_value(t, still, text)
	free_all(context.temp_allocator)
}
