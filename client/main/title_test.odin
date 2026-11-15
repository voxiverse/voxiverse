package main

import "core:slice"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:screen"
import "client:ui"
import "common:game"
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

// The splash is a stamp: dial glyphs resolving into the text from the left
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

// The launcher: the title lists every game this build has (the default first, then by
// folder), each a button with its description under it, on one line within the column;
// the rest of the title follows. Picking one, by the mouse or by the pad as the rest of
// the menu is driven, asks for a world playing it (App.launch, which the frame starts),
// and the session that world's server part makes plays that game.
@(test)
test_launcher_lists_and_starts_every_game :: proc(t: ^testing.T) {
	r := rig_make(t)
	defer rig_free(r)
	app := r.app
	app.session = nil
	app.screen = .Title
	app.games, app.server_games = games_client.CLIENT, games.SERVER
	ui_frame(app)
	order := make([dynamic]string, context.temp_allocator)
	append(&order, game.DEFAULT_GAME)
	for g in games_client.CLIENT {if g.id != game.DEFAULT_GAME {append(&order, g.id)}}
	testing.expect_value(t, len(order), len(games.SERVER))
	last: f32 = -1
	about := app.ui.theme.font_size * screen.LAUNCHER_ABOUT
	for id in order {
		g, found := engine.game_find(app.games, id)
		if !testing.expectf(t, found, "%s has no client part", id) {continue}
		r, shown := ui.find_widget(&app.ui, g.name)
		testing.expectf(t, shown, "the launcher does not list %s", g.name)
		testing.expectf(t, r.y > last, "%s is out of order", g.name)
		last = r.y
		testing.expect(t, slice.contains(app.ui.texts[:], g.description), g.description)
		testing.expectf(
			t,
			ui.measure_text(&app.ui, g.description, about) <= screen.TITLE_WIDTH,
			"%s's description is wider than the title's column",
			g.id,
		)
	}
	singleplayer, _ := ui.find_widget(&app.ui, "Singleplayer")
	testing.expect(t, singleplayer.y > last, "the games are not above the rest of the title")

	// The pad: the default game is lit at once; Down moves to the next game, A picks it.
	pad_connect(app, .Xbox)
	pad_frame(app)
	first, _ := engine.game_find(app.games, order[0])
	testing.expect_value(t, ui.focused_label(&app.ui), first.name)
	pad_go(app, .Down)
	pad_tap(app, .A)
	testing.expect_value(t, app.launch, order[1])
	app.launch = ""

	// The mouse: each game's button asks for its world; nothing starts in the UI itself.
	for id in order {
		g, _ := engine.game_find(app.games, id)
		click(t, app, g.name)
		testing.expect_value(t, app.launch, id)
		testing.expect(t, app.session == nil && app.screen == .Title)
		app.launch = ""
	}

	// What the frame then starts: a world hosted with that game's server part, whose
	// session plays it (on the stepped server; the embedded one runs on its own thread).
	for id in order {
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
