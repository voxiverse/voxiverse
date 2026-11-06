package main

import "core:testing"

import "client:engine"

@(test)
test_crash_track_follows_the_screen_and_world :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	app := f.app
	tr := &app.crash_track

	// In a world (singleplayer, loaded): the state names the kind, never an address.
	app.screen = .Game
	engine.crash_track(app)
	testing.expect_value(t, engine.crash_state(app), "world singleplayer")
	testing.expect_value(t, string(tr.state[:tr.state_n]), "world singleplayer")
	testing.expect(t, tr.in_world)

	// A remote world, then loading, then the title.
	app.session.remote = true
	testing.expect_value(t, engine.crash_state(app), "world remote")
	app.session.loading = engine.Loading{}
	testing.expect_value(t, engine.crash_state(app), "loading")
	app.session.loading = nil

	before := tr.overlays
	engine.overlay_open(&app.overlays, .Game_Menu)
	engine.crash_track(app)
	testing.expect(t, .Game_Menu in tr.overlays)
	testing.expect_value(t, string(tr.state[:tr.state_n]), "world remote")
	engine.overlay_close(&app.overlays, .Game_Menu)
	engine.crash_track(app)
	testing.expect(t, tr.overlays == before - {.Game_Menu})

	saved := app.session
	app.session = nil
	app.screen = .Title
	engine.crash_track(app)
	testing.expect_value(t, string(tr.state[:tr.state_n]), "title")
	testing.expect(t, !tr.in_world)
	testing.expect_value(t, tr.screen, engine.Screen.Title)
	app.session = saved
}
