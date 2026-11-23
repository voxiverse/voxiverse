package main

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:screen"
import "client:ui"
import "common:base"
import "generated:games"
import games_client "generated:games/client"
import "server:core"

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

// Continue: on the title, first, while the universe played last is there to open, named
// by its name alone (there is one game); playing a universe makes it the one; a save that
// is gone, one that is unreadable, one whose game this build lacks, one of another game
// than Singleplayer's (a horde save: the setting is left as it is), or none at all: no
// Continue, and the title keeps to four buttons.
@(test)
test_title_continue :: proc(t: ^testing.T) {
	dir := "build/test/title_continue"
	os.remove_all(dir)
	defer os.remove_all(dir)
	screen.saves_override = dir
	defer screen.saves_override = ""
	cfg :: proc(dir, name, text: string) {
		save := filepath.join({dir, name}, context.temp_allocator) or_else ""
		os.make_directory_all(save)
		file := filepath.join({save, "universe.cfg"}, context.temp_allocator) or_else ""
		_ = os.write_entire_file(file, transmute([]u8)text)
	}
	cfg(dir, "Yard 2", "format = 1\nseed = 1\ngame = sandbox\n")
	cfg(dir, "Horde Yard", "format = 1\nseed = 1\ngame = horde\n")
	cfg(dir, "Elsewhere", "format = 1\nseed = 1\ngame = nonesuch\n")
	os.make_directory_all(filepath.join({dir, "Empty"}, context.temp_allocator) or_else "")
	app := ui_app(t)
	defer ui_app_free(app)
	defer screen.universes_destroy(&app.universes)
	app.games, app.server_games = games_client.CLIENT, games.SERVER
	app.screen = .Title
	buttons :: proc(app: ^engine.App) -> (continue_label: string, n: int) {
		ui_frame(app)
		for label in ([]string{"Singleplayer", "Multiplayer", "Options", "Quit Game"}) {
			if _, found := ui.find_widget(&app.ui, label); found {n += 1}
		}
		for text in app.ui.texts {
			if strings.has_prefix(text, "Continue") {continue_label, n = text, n + 1}
		}
		return
	}
	label, n := buttons(app)
	testing.expect_value(t, label, "")
	testing.expect_value(t, n, 4)

	// Played: the save is the one Continue opens.
	screen.save_played(app, filepath.join({dir, "Yard 2"}, context.temp_allocator) or_else "")
	label, n = buttons(app)
	testing.expect_value(t, label, "Continue: Yard 2")
	testing.expect_value(t, n, 5)
	r, _ := ui.find_widget(&app.ui, label)
	single, _ := ui.find_widget(&app.ui, "Singleplayer")
	testing.expect(t, r.y < single.y, "Continue is not first")

	// Gone (deleted on its page: the saves read again): no Continue.
	os.remove_all(filepath.join({dir, "Yard 2"}, context.temp_allocator) or_else "")
	screen.universes_refresh(&app.universes)
	label, n = buttons(app)
	testing.expect_value(t, label, "")
	testing.expect_value(t, n, 4)
	for name in ([]string{"Empty", "Elsewhere", "Horde Yard", "../escape"}) {
		base.var_text_set(&app.settings.last_save, name)
		label, _ = buttons(app)
		testing.expectf(t, label == "", "%s: %q", name, label)
		testing.expect_value(t, base.var_text(&app.settings.last_save), name)
	}
	testing.expect(
		t,
		os.is_file(
			filepath.join({dir, "Horde Yard", "universe.cfg"}, context.temp_allocator) or_else "",
		),
		"the horde save was touched",
	)
	free_all(context.temp_allocator)
}

// The splash is a stamp: address symbols resolving into the text from the left
// over SPLASH_REVEAL seconds; with reduce motion it is simply there.
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

// The stamp's motion: nothing at 0 s, an overshoot past 1, ringing down to
// 1; the pulse breathes around 1; the angle breathes around the tilt; and
// all of it rests still at rest values when seconds pass.
@(test)
test_splash_motion :: proc(t: ^testing.T) {
	testing.expect_value(t, screen.splash_pop(0), 0)
	peak: f32 = 0
	for i := 1; i <= 200; i += 1 {
		peak = max(peak, screen.splash_pop(f32(i) * 0.01))
	}
	testing.expect(t, peak > 1.1, "the stamp overshoots")
	testing.expect(t, peak < 1.5, "the stamp's overshoot is a spring, not an explosion")
	rest := screen.splash_pop(3)
	testing.expect(t, rest > 0.99 && rest < 1.01, "the stamp settles to full size")
	for i := 0; i <= 40; i += 1 {
		seconds := f32(i) * 0.25
		pulse := screen.splash_pulse(seconds)
		testing.expect(t, pulse > 0.9 && pulse < 1.1, "the pulse stays a swell, not a blink")
		angle := screen.splash_angle(seconds)
		testing.expect(
			t,
			angle > screen.SPLASH_TILT - screen.SPLASH_WOBBLE - 0.001 &&
			angle < screen.SPLASH_TILT + screen.SPLASH_WOBBLE + 0.001,
			"the angle breathes around the tilt",
		)
	}
}

// Singleplayer: one game, so no list of games: the title's Singleplayer opens the game's
// universes, titled Singleplayer and naming no game, New Universe first, then its
// universes (one from before games were recorded too) and no save of another game, which
// stays on the disk as it was. Every game built can still be played alone (`--game`, the
// dedicated server, the `universe` command): a world hosted with its server part, whose
// session plays it.
@(test)
test_singleplayer_lists_the_game_universes_only :: proc(t: ^testing.T) {
	dir := "build/test/singleplayer_saves"
	os.remove_all(dir)
	defer os.remove_all(dir)
	screen.saves_override = dir
	defer screen.saves_override = ""
	cfg :: proc(dir, name, text: string) {
		save := filepath.join({dir, name}, context.temp_allocator) or_else ""
		os.make_directory_all(save)
		file := filepath.join({save, "universe.cfg"}, context.temp_allocator) or_else ""
		_ = os.write_entire_file(file, transmute([]u8)text)
	}
	cfg(dir, "Home", "format = 1\nseed = 1\ngame = sandbox\n")
	cfg(dir, "Before Games", "format = 1\nseed = 2\n")
	cfg(dir, "Horde Yard", "format = 1\nseed = 3\ngame = horde\n")
	cfg(dir, "Arena Pit", "format = 1\nseed = 4\ngame = arena\n")
	r := rig_make(t)
	defer rig_free(r)
	app := r.app
	app.session = nil
	app.screen = .Title
	app.games, app.server_games = games_client.CLIENT, games.SERVER
	ui_frame(app)
	click(t, app, "Singleplayer")
	testing.expect_value(t, app.screen, engine.Screen.Universes)
	testing.expect(t, !app.universes.host, "Singleplayer hosts")
	testing.expect(t, slice.contains(app.ui.texts[:], "Singleplayer"), "not titled Singleplayer")
	for g in app.games {
		testing.expectf(t, !slice.contains(app.ui.texts[:], g.name), "the page names %s", g.name)
	}
	_, has_new := ui.find_widget(&app.ui, "New Universe")
	testing.expect(t, has_new, "no New Universe")
	for name in ([]string{"Home", "Before Games"}) {
		testing.expectf(t, slice.contains(app.ui.texts[:], name), "%s is not listed", name)
	}
	for name in ([]string{"Horde Yard", "Arena Pit"}) {
		testing.expectf(t, !slice.contains(app.ui.texts[:], name), "%s is listed", name)
		file := filepath.join({dir, name, "universe.cfg"}, context.temp_allocator) or_else ""
		testing.expectf(t, os.is_file(file), "%s was touched", name)
	}
	testing.expect_value(t, len(screen.page_saves(&app.universes)), 2)
	testing.expect_value(t, len(app.universes.entries), 4)
	click(t, app, "Back")
	testing.expect_value(t, app.screen, engine.Screen.Title)

	// What the frame starts: a world hosted with that game's server part, whose session
	// plays it (on the stepped server; the embedded one runs on its own thread).
	for g in app.games {
		id := g.id
		hosted := engine.host_game(app, id)
		testing.expect_value(t, hosted.id, id)
		rig := new(Frame_Rig)
		defer free(rig)
		s := new(engine.Session)
		defer free(s)
		if !game_join(t, rig, s, hosted, app.games) {continue}
		testing.expectf(t, s.state == .Playing, "%s: the session did not play (%s)", id, s.failure)
		testing.expect_value(t, s.game.id, id)
		engine.session_end(s, nil, nil)
		core.harness_stop(&rig.h)
	}
}
