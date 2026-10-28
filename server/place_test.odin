package server

import "core:os"
import "core:path/filepath"
import "core:testing"

import "../common/worldgen"

// M44: the server tells a player the biome under their feet (and the world's
// warmth and wetness), only when it changes; and tells them when they die.
@(test)
test_place_record :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "place"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	rules := quiet_rules()
	srv: Server
	if !testing.expect(
		t,
		start(
			&srv,
			Config {
				mode = "survival",
				rules = rules,
				seed = 1,
				view_radius = 2,
				view_height = 1,
				workers = 2,
				save_dir = dir,
				max_players = 2,
				listen = true,
				generator = .Earth,
				no_sheep = true,
			},
			{},
		),
	) {return}
	defer stop(&srv)
	for !srv.listening {}
	gen := worldgen.generator_make(.Earth, srv.home.seed, srv.registry, srv.home.params)
	desert, found := worldgen.locate(&gen, .Desert, 0, 0, 8192)
	ocean, found_ocean := worldgen.locate(&gen, .Ocean, 0, 0, 8192)
	if !testing.expect(t, found && found_ocean, "the test seed has a desert and an ocean") {return}

	a: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	defer net_close(&a)
	if !testing.expect(
		t,
		net_wait(
			t,
			{&a},
			proc(cs: []^Net_Client) -> bool {return cs[0].welcomed && cs[0].update.acked > 0},
			30,
		),
		"never joined",
	) {return}
	to :: proc(srv: ^Server, at: [2]i32) {
		Move :: struct {
			srv: ^Server,
			at:  [2]i32,
		}
		m := Move{srv, at}
		call(
			srv,
			proc(s: ^Server, data: rawptr) {
				m := (^Move)(data)
				if c := client_by_name(s, "a"); c != nil {
					c.player.position = {f64(m.at.x) + 0.5, 150, f64(m.at.y) + 0.5}
					c.player.velocity = {}
					c.player.flying = true // (stays up: only the column matters)
				}
			},
			&m,
		)
	}
	to(&srv, desert)
	ok := net_wait(
		t,
		{&a},
		proc(cs: []^Net_Client) -> bool {return cs[0].place.biome == u8(worldgen.Biome.Desert)},
		5,
	)
	testing.expect(t, ok, "the client was not told the desert")
	testing.expect_value(t, a.place.warmth, i8(0))
	testing.expect_value(t, a.place.wetness, i8(0))
	// Standing still, nothing more is sent.
	seen := a.places
	net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return false}, 1)
	testing.expect_value(t, a.places, seen)
	// Another biome: told again.
	to(&srv, ocean)
	ok = net_wait(
		t,
		{&a},
		proc(cs: []^Net_Client) -> bool {return cs[0].place.biome == u8(worldgen.Biome.Ocean)},
		5,
	)
	testing.expect(t, ok, "the client was not told the ocean")
	testing.expect(t, a.places > seen)
	// Death: told before they land at the spawn.
	call(&srv, proc(s: ^Server, data: rawptr) {
			if c := client_by_name(s, "a"); c != nil {damage_player(s, c, 1000, "test")}
		}, nil)
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return cs[0].deaths == 1}, 5)
	testing.expect(t, ok, "the client was not told it died")
}
