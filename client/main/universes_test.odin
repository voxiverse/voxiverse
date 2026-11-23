package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "client:engine"
import "client:overlay"
import "client:screen"
import "common:game"
import "common:starmap"
import "generated:games"
import games_client "generated:games/client"
import "server:core"

// Singleplayer's universes (screen/universes.odin): the order, what a save knows from its
// config, that only the game's universes are listed, Export and Import through the
// buttons. (Rename
// and Delete's one confirmation: menus_test.odin's test_saves_screen; that
// entering a universe puts the character where it last stood:
// server/core/gamemode_test.odin.)

@(private = "file")
make_universe :: proc(dir, name: string, seed: u64, mode: string, age: time.Duration) {
	save := filepath.join({dir, name}, context.temp_allocator) or_else ""
	os.make_directory_all(save)
	cfg := filepath.join({save, "universe.cfg"}, context.temp_allocator) or_else ""
	text := strings.concatenate(
		{"format = 1\nseed = ", fmt_u64(seed), "\nmode = ", mode, "\n"},
		context.temp_allocator,
	)
	_ = os.write_entire_file(cfg, transmute([]u8)text)
	then := time.time_add(time.Time{_nsec = engine.CLOCK_FIXED_WALL}, -age) // (ages are relative: no clock read)
	os.change_times(cfg, then, then)
}

@(private = "file")
fmt_u64 :: proc(n: u64) -> string {
	buf := make([]u8, 24, context.temp_allocator)
	i := len(buf)
	n := n
	for {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 {break}
	}
	return string(buf[i:])
}

@(test)
test_cards_newest_first_with_their_seed_and_mode :: proc(t: ^testing.T) {
	dir := "build/test/cards"
	os.remove_all(dir)
	defer os.remove_all(dir)
	screen.saves_override = dir
	defer screen.saves_override = ""
	make_universe(dir, "Oldest", 1, "creative", 72 * time.Hour)
	make_universe(dir, "Newest", 42, "survival\nage = 126000", time.Minute) // (70 minutes run)
	make_universe(dir, "Middle", 7, "creative", 5 * time.Hour)
	app := ui_app(t)
	defer ui_app_free(app)
	defer screen.universes_destroy(&app.universes)
	defer screen.creation_destroy(&app.creation)
	screen.universes_refresh(&app.universes)
	names: [3]string
	for e, i in app.universes.entries {names[i] = e.name}
	testing.expect_value(t, names, [3]string{"Newest", "Middle", "Oldest"})
	newest := app.universes.entries[0]
	testing.expect_value(t, newest.seed, 42)
	testing.expect_value(t, newest.mode, "survival")
	testing.expect_value(t, newest.age, 126000)
	testing.expect(t, newest.stars[0].home, "the thumbnail's home star")
	galaxy: [engine.THUMB_STARS]starmap.Star
	starmap.galaxy_stars(starmap.seed_glyphs(42), galaxy[:])
	testing.expect(t, newest.stars == galaxy, "the thumbnail is the seed's galaxy")
	// The page draws them: the name, the mode, when it was played and for how long.
	app.screen = .Universes
	ui_frame(app)
	for want in ([]string{"Newest", "Oldest", "Survival", "played 1 min ago", "1 h 10 min in all"}) {
		found := false
		for text in app.ui.texts {if strings.contains(text, want) {found = true}}
		testing.expectf(t, found, "no %s on the cards", want)
	}
	free_all(context.temp_allocator)
}

// A save knows the game its universe plays (universe.cfg's game; one from before games
// were recorded plays sandbox), and Singleplayer lists the game's universes and no save of
// another game; a universe of a game this build lacks is not opened (the `universe`
// command, which opens any save, says why).
@(test)
test_cards_know_their_game :: proc(t: ^testing.T) {
	dir := "build/test/cards_game"
	os.remove_all(dir)
	defer os.remove_all(dir)
	screen.saves_override = dir
	defer screen.saves_override = ""
	make_universe(dir, "Older", 1, "creative", 72 * time.Hour)
	make_universe(dir, "Yard", 2, "creative\ngame = horde", time.Hour)
	make_universe(dir, "Elsewhere", 3, "creative\ngame = nonesuch", time.Minute)
	app := ui_app(t)
	defer ui_app_free(app)
	defer screen.universes_destroy(&app.universes)
	defer screen.creation_destroy(&app.creation)
	app.games, app.server_games = games_client.CLIENT, games.SERVER
	screen.universes_refresh(&app.universes)
	e := app.universes.entries[:]
	if !testing.expect_value(t, len(e), 3) {return}
	testing.expect_value(t, e[0].game_id, "nonesuch")
	testing.expect_value(t, e[1].game_id, "horde")
	testing.expect_value(t, e[2].game_id, "")
	testing.expect_value(t, screen.entry_game(&e[2]), "sandbox")
	shows :: proc(app: ^engine.App, want: string) -> bool {
		for text in app.ui.texts {if text == want {return true}}
		return false
	}
	screen.universes_open(app)
	ui_frame(app)
	testing.expect(t, shows(app, "Older"), "Singleplayer lacks its universe")
	testing.expect(t, !shows(app, "Yard") && !shows(app, "Elsewhere"), "another game's save")
	testing.expect_value(t, len(screen.page_saves(&app.universes)), 1)
	why := screen.universe_enter(app, e[0].path)
	testing.expect(t, app.session == nil, "a universe of a game this build lacks was opened")
	testing.expect_value(t, why, "This universe plays nonesuch, a game this version does not have")
	free_all(context.temp_allocator)
}

// A real universe, made by the server (stepped, nobody joined, stopped), recording the
// game Singleplayer lists (the engine's own rules: no hook of that game's runs).
@(private = "file")
server_made :: proc(t: ^testing.T, dir, name: string) -> bool {
	path := filepath.join({dir, name}, context.temp_allocator) or_else ""
	h := new(core.Harness) // (heap: a Harness is too big for a test thread's stack on macOS, #104)
	defer free(h)
	played := core.HARNESS_GAME
	played.id = game.DEFAULT_GAME
	config := core.Config {
		seed        = 5,
		view_radius = 2,
		view_height = 1,
		save_dir    = path,
		generator   = .Classic,
		game        = played,
	}
	if !testing.expect(t, core.harness_start(h, config)) {return false}
	core.harness_stop(h)
	return true
}

@(test)
test_export_and_import_through_the_cards :: proc(t: ^testing.T) {
	dir := "build/test/cards_export"
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	screen.saves_override = dir
	defer screen.saves_override = ""
	if !server_made(t, dir, "Castle") {return}
	app := ui_app(t)
	defer ui_app_free(app)
	defer screen.universes_destroy(&app.universes)
	defer screen.creation_destroy(&app.creation)
	defer overlay.toasts_destroy(&app.toasts)
	screen.universes_open(app)
	testing.expect_value(t, len(app.universes.entries), 1)
	ui_frame(app)

	click(t, app, "Export") // (the save played last is selected)
	archive := filepath.join({dir, "Castle.vxu"}, context.temp_allocator) or_else ""
	testing.expect(t, os.exists(archive), "the archive was written")
	testing.expect_value(t, app.universes.mode, engine.Saves_Mode.List)
	testing.expect_value(t, len(app.toasts.list), 1) // "Exported to ..."

	// Import: the button asks for the file; the universe comes back (as a
	// free name beside the one that is there).
	click(t, app, "Import")
	testing.expect_value(t, app.universes.mode, engine.Saves_Mode.Import)
	append(&app.universes.path, archive)
	ui_frame(app)
	click(t, app, "Import File")
	testing.expect_value(t, app.universes.message, "")
	testing.expect_value(t, len(app.universes.entries), 2)
	testing.expect(
		t,
		os.exists(
			filepath.join({dir, "Castle (2)", "universe.cfg"}, context.temp_allocator) or_else "",
		),
	)
	// A file that is not an export says so and adds nothing.
	click(t, app, "Import")
	append(&app.universes.path, "build/test/nothing_here.vxu")
	ui_frame(app)
	click(t, app, "Import File")
	testing.expect(t, app.universes.message != "")
	testing.expect_value(t, len(app.universes.entries), 2)
	free_all(context.temp_allocator)
}

// A click selects a card and does not play it; a second click on it within
// DOUBLE_CLICK plays it (the README: "play a save (or double-click it)").
@(test)
test_a_click_selects_and_a_double_click_plays :: proc(t: ^testing.T) {
	w: engine.Universes_Screen
	w.list.selected = -1
	t0 := time.Tick {
		_nsec = 1_000_000_000,
	}
	ms :: proc(t: time.Tick, n: i64) -> time.Tick {return time.Tick {
			_nsec = t._nsec + n * 1_000_000,
		}}
	testing.expect(t, !screen.card_click(&w, 1, t0), "one click only selects")
	testing.expect_value(t, w.list.selected, 1)
	testing.expect(t, !screen.card_click(&w, 0, ms(t0, 100)), "a click on another card selects it")
	testing.expect_value(t, w.list.selected, 0)
	testing.expect(
		t,
		!screen.card_click(&w, 0, ms(t0, 900)),
		"the same card after the window: selects again",
	)
	testing.expect(
		t,
		screen.card_click(&w, 0, ms(t0, 1100)),
		"twice quickly on the same card: play",
	)
}
