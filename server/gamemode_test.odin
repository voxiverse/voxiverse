package server

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../common/game"

// The universes screen's creation (client/screen_creation.odin) starts a
// universe with the typed seed and a game mode; the files say what the
// screen's cards show.

// A universe made with a typed seed has that seed's glyph address as its
// home world's address; its mode is kept, and kept as it was made when it
// is opened with another.
@(test)
test_universe_made_with_a_seed_and_a_mode :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "universe_mode"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	typed, _ := game.seed_of_text("andromeda")
	config := Config {
		seed        = i64(typed),
		mode        = "survival",
		view_radius = 2,
		view_height = 1,
		workers     = 1,
		save_dir    = dir,
		generator   = .Classic,
	}
	srv: Server
	if !testing.expect(t, start(&srv, config, {})) {return}
	testing.expect_value(t, srv.home.address, game.seed_glyphs(typed))
	stop(&srv)
	text := read_universe(dir)
	testing.expect(
		t,
		strings.contains(
			text,
			strings.concatenate(
				{"home = ", game.address_dir(game.seed_glyphs(typed))},
				context.temp_allocator,
			),
		),
		"the home address is the seed's glyphs",
	)
	testing.expect(t, strings.contains(text, "mode = survival"))
	testing.expect(t, !strings.contains(text, "mode_changed"))

	// Opened as a creative one: the universe keeps what it was made as.
	config.mode = "creative"
	if !testing.expect(t, start(&srv, config, {})) {return}
	testing.expect_value(t, srv.config.mode, "survival")
	srv.config.mode, srv.config.mode_changed = "creative", true
	stop(&srv)
	text = read_universe(dir)
	testing.expect(t, strings.contains(text, "mode = creative"))
	testing.expect(t, strings.contains(text, "mode_changed = true"))
}

@(private = "file")
read_universe :: proc(dir: string) -> string {
	path := filepath.join({dir, UNIVERSE_FILE}, context.temp_allocator) or_else ""
	data, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	return string(data)
}

// Entering a universe again puts the character where it last stood: in the
// world it left by a gate, not the home world.
@(test)
test_rejoin_in_the_last_world :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "net_rejoin"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	perms := strings.concatenate(
		{DEFAULT_PERMISSIONS, "player alice\nrole admin\n"},
		context.temp_allocator,
	)
	testing.expect(
		t,
		os.write_entire_file(
			filepath.join({dir, PERMISSIONS_FILE}, context.temp_allocator) or_else "",
			transmute([]u8)perms,
		) ==
		nil,
	)
	config := Config {
		seed        = 4,
		view_radius = 2,
		view_height = 1,
		workers     = 1,
		save_dir    = dir,
		max_players = 4,
		listen      = true,
		generator   = .Classic,
		world_idle  = 0.5,
	}
	away := game.address_derive(999)
	@(static) want: game.Address
	want = away
	for round in 0 ..< 2 {
		srv: Server
		if !testing.expect(t, start(&srv, config, {})) {return}
		for !srv.listening {}
		alice: Net_Client
		net_connect(&alice, srv.host.socket.port, "alice")
		both := []^Net_Client{&alice}
		ok := net_wait(t, both, proc(cs: []^Net_Client) -> bool {
			return cs[0].welcomed && cs[0].update.acked > 0
		})
		testing.expect(t, ok, "alice never joined")
		if round == 0 {
			testing.expect(t, alice.address == srv.home.address, "the first time, at home")
			net_send(
				&alice,
				game.Command {
					strings.concatenate(
						{"travel ", game.address_dir(away)},
						context.temp_allocator,
					),
				},
			)
			ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
					return cs[0].address == want && cs[0].update.state.on_ground
				}, 30)
			testing.expect(t, ok, "alice never arrived")
		} else {
			testing.expect(t, alice.address == away, "the second time, in the world she left")
		}
		net_close(&alice)
		stop(&srv)
	}
}
