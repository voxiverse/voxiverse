package server

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../common/game"

// An address is the same kind of world in any universe (its parameters and
// rules), with terrain of its own (the seed); the home world is Earth's.
@(test)
test_world_kinds :: proc(t: ^testing.T) {
	a := game.address_derive(999)
	one, two: Server
	one.config.seed, two.config.seed = 1, 2
	w1 := World {
		server  = &one,
		address = a,
	}
	w2 := World {
		server  = &two,
		address = a,
	}
	world_kind(&w1)
	world_kind(&w2)
	testing.expect(t, w1.params == w2.params && w1.rules == w2.rules, "an address made two kinds")
	testing.expect(t, w1.seed != w2.seed, "two universes, the same terrain")
	other := World {
		server  = &one,
		address = game.address_derive(1000),
	}
	world_kind(&other)
	testing.expect(t, other.params != w1.params, "two addresses, one kind")
	testing.expect(t, w1.rules.gravity >= 16 && w1.rules.gravity <= 48)
}

// M17's exit check over UDP: an admin travels to another world with her
// inventory and builds there; the other player stays home; the world she
// left goes when empty, its edit kept in its own directory; travelling back
// and forth keeps memory flat.
@(test)
test_worlds_over_the_network :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "net_worlds"}, context.temp_allocator) or_else ""
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
	srv: Server
	if !testing.expect(t, start(&srv, config, {})) {return}
	stopped := false
	defer if !stopped {stop(&srv)}
	for !srv.listening {}
	port := srv.host.socket.port
	home := srv.home.address
	away := game.address_derive(999)
	@(static) want: game.Address

	alice, bob: Net_Client
	net_connect(&alice, port, "alice")
	net_connect(&bob, port, "bob")
	defer net_close(&alice)
	defer net_close(&bob)
	both := []^Net_Client{&alice, &bob}
	ok := net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		ready :: proc(c: ^Net_Client) -> bool {return(
				c.welcomed &&
				c.inv_updates > 0 &&
				c.update.acked > 0 \
			)}
		return ready(cs[0]) && ready(cs[1])
	})
	if !testing.expect(t, ok, "the players never joined") {return}
	testing.expect(t, alice.address == home)
	carried := alice.inventory

	// Alice travels away, carrying what she carries; bob stays home.
	net_send(
		&alice,
		game.Command {
			strings.concatenate({"travel ", game.address_dir(away)}, context.temp_allocator),
		},
	)
	want = away
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
			return cs[0].address == want && len(cs[0].chunks) > 10 && cs[0].update.state.on_ground
		}, 30)
	testing.expect(t, ok, "alice never arrived")
	testing.expect(t, alice.inventory == carried, "the inventory did not travel")
	testing.expect(t, bob.address == home && bob.travels == 0)
	testing.expect_value(t, stats(&srv).worlds, 2)

	// She builds there.
	feet := alice.update.state.position
	at := game.Block_Pos {
		i32(math.floor(feet.x)) + 1,
		i32(math.floor(feet.y)),
		i32(math.floor(feet.z)),
	}
	net_send(&alice, game.Edit{1, alice.seq, at, .Stone})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return 1 in cs[0].results})
	testing.expect(t, ok && alice.results[1].accepted, "her edit was refused")

	// Home again: the other world goes once empty, its edit saved there.
	net_send(
		&alice,
		game.Command {
			strings.concatenate({"travel ", game.address_dir(home)}, context.temp_allocator),
		},
	)
	want = home
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return(
				cs[0].address == want &&
				cs[0].update.state.on_ground \
			)},
		30,
	)
	testing.expect(t, ok, "alice never came home")
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 1.5)
	testing.expect_value(t, stats(&srv).worlds, 1)
	away_regions :=
		filepath.join(
			{dir, WORLDS_DIR, game.address_dir(away), "regions"},
			context.temp_allocator,
		) or_else ""
	entries, _ := os.read_all_directory_by_path(away_regions, context.temp_allocator)
	testing.expect(t, len(entries) > 0, "the other world's edit was not saved in its directory")

	// Back and forth: memory comes back each time the other world goes.
	settled := stats(&srv).arena_used
	for _ in 0 ..< 3 {
		for target in ([]game.Address{away, home}) {
			net_send(
				&alice,
				game.Command {
					strings.concatenate(
						{"travel ", game.address_dir(target)},
						context.temp_allocator,
					),
				},
			)
			want = target
			net_wait(
				t,
				both,
				proc(cs: []^Net_Client) -> bool {return(
						cs[0].address == want &&
						cs[0].update.state.on_ground \
					)},
				30,
			)
		}
		net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 1.5)
	}
	testing.expect_value(t, stats(&srv).worlds, 1)
	used := stats(&srv).arena_used
	testing.expectf(
		t,
		used <= settled + settled / 10,
		"memory grew over travel: %d -> %d bytes",
		settled,
		used,
	)
	testing.expect_value(t, alice.travels, 8)
}
