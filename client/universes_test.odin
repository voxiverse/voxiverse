package client

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../common/game"
import "../server"

// The universes screen's cards (screen_universes.odin): the order, what a
// card knows from its config, Export and Import through the buttons. (Rename
// and Delete's one confirmation: menus_test.odin's test_saves_screen; that
// entering a universe puts the character where it last stood:
// server/gamemode_test.odin.)

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
	then := time.time_add(time.now(), -age)
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
	saves_override = dir
	defer saves_override = ""
	make_universe(dir, "Oldest", 1, "creative", 72 * time.Hour)
	make_universe(dir, "Newest", 42, "survival", time.Minute)
	make_universe(dir, "Middle", 7, "creative", 5 * time.Hour)
	app := ui_app(t)
	defer ui_app_free(app)
	defer universes_destroy(&app.universes)
	defer creation_destroy(&app.creation)
	universes_refresh(&app.universes)
	names: [3]string
	for e, i in app.universes.entries {names[i] = e.name}
	testing.expect_value(t, names, [3]string{"Newest", "Middle", "Oldest"})
	newest := app.universes.entries[0]
	testing.expect_value(t, newest.seed, 42)
	testing.expect_value(t, newest.mode, "survival")
	testing.expect(t, newest.stars[0].home, "the thumbnail's home star")
	galaxy: [THUMB_STARS]game.Star
	game.galaxy_stars(game.seed_glyphs(42), galaxy[:])
	testing.expect(t, newest.stars == galaxy, "the thumbnail is the seed's galaxy")
	// The screen draws them, the name and the mode and the time on each.
	app.screen = .Universes
	ui_frame(app)
	for want in ([]string{"Newest", "Oldest", "Survival"}) {
		found := false
		for text in app.ui.texts {if strings.contains(text, want) {found = true}}
		testing.expectf(t, found, "no %s on the cards", want)
	}
	free_all(context.temp_allocator)
}

// A real universe, made by the server (stepped, nobody joined, stopped).
@(private = "file")
server_made :: proc(t: ^testing.T, dir, name: string) -> bool {
	path := filepath.join({dir, name}, context.temp_allocator) or_else ""
	h: server.Harness
	config := server.Config {
		seed        = 5,
		view_radius = 2,
		view_height = 1,
		save_dir    = path,
		generator   = .Classic,
	}
	if !testing.expect(t, server.harness_start(&h, config)) {return false}
	server.harness_stop(&h)
	return true
}

@(test)
test_export_and_import_through_the_cards :: proc(t: ^testing.T) {
	dir := "build/test/cards_export"
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	saves_override = dir
	defer saves_override = ""
	if !server_made(t, dir, "Castle") {return}
	app := ui_app(t)
	defer ui_app_free(app)
	defer universes_destroy(&app.universes)
	defer creation_destroy(&app.creation)
	defer toasts_destroy(&app.toasts)
	universes_refresh(&app.universes)
	testing.expect_value(t, len(app.universes.entries), 1)
	app.screen = .Universes
	ui_frame(app)

	open_menu(t, app, "Castle")
	click(t, app, "Export")
	archive := filepath.join({dir, "Castle.vxu"}, context.temp_allocator) or_else ""
	testing.expect(t, os.exists(archive), "the archive was written")
	testing.expect_value(t, app.universes.mode, Saves_Mode.List)
	testing.expect_value(t, len(app.toasts.list), 1) // "Exported to ..."

	// Import: the button asks for the file; the universe comes back (as a
	// free name beside the one that is there).
	click(t, app, "Import")
	testing.expect_value(t, app.universes.mode, Saves_Mode.Import)
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
