package core

import "base:runtime"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

import "common:game"
import "common:worldgen"

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

// The exit check over UDP: an admin travels to another world with her
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
		save_dir    = dir,
		max_players = 4,
		listen      = true,
		generator   = .Classic,
		world_idle  = 0.5,
	}
	h := new(Harness)
	defer free(h)
	srv := &h.srv
	if !testing.expect(t, harness_start(h, config)) {return}
	stopped := false
	defer if !stopped {harness_stop(h)}
	home := srv.home.address
	away := game.address_derive(999)
	@(static) want: game.Address

	alice := new(Net_Client)
	defer free(alice)
	bob := new(Net_Client)
	defer free(bob)
	net_connect(alice, 0, "alice", h = h)
	net_connect(bob, 0, "bob", h = h)
	defer net_close(alice)
	defer net_close(bob)
	both := []^Net_Client{alice, bob}
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
		alice,
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
	testing.expect_value(t, stats(srv).worlds, 2)

	// She builds there.
	feet := alice.update.state.position
	at := game.Block_Pos {
		i32(math.floor(feet.x)) + 1,
		i32(math.floor(feet.y)),
		i32(math.floor(feet.z)),
	}
	net_send(alice, game.edit_plain(1, alice.seq, at, .Stone))
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return 1 in cs[0].results})
	testing.expect(t, ok && alice.results[1].accepted, "her edit was refused")

	// Home again: the other world goes once empty, its edit saved there.
	net_send(
		alice,
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
	testing.expect_value(t, stats(srv).worlds, 1)
	away_regions :=
		filepath.join(
			{dir, WORLDS_DIR, game.address_dir(away), "regions"},
			context.temp_allocator,
		) or_else ""
	entries, _ := os.read_all_directory_by_path(away_regions, context.temp_allocator)
	testing.expect(t, len(entries) > 0, "the other world's edit was not saved in its directory")

	// Back and forth: memory comes back each time the other world goes.
	settled := stats(srv).arena_used
	for _ in 0 ..< 3 {
		for target in ([]game.Address{away, home}) {
			net_send(
				alice,
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
	testing.expect_value(t, stats(srv).worlds, 1)
	used := stats(srv).arena_used
	testing.expectf(
		t,
		used <= settled + settled / 10,
		"memory grew over travel: %d -> %d bytes",
		settled,
		used,
	)
	testing.expect_value(t, alice.travels, 8)
}

// terrain_hash: a hash of some chunks of the terrain a world would generate.
@(private = "file")
terrain_hash :: proc(w: ^World, reg: ^game.Registry) -> u64 {
	arr := new(game.Block_Array)
	defer free(arr)
	g := worldgen.generator_make(.Earth, terrain_seed(w), reg)
	h := u64(0xcbf2_9ce4_8422_2325)
	for k in i32(0) ..< 5 {
		for cy in ([]i32{-2, 0, 1}) {
			uniform, is_uniform := worldgen.generate(&g, {k * 41 - 90, cy, k * -29 + 60}, arr)
			bytes: []u8
			if is_uniform {
				u := uniform
				bytes = ([^]u8)(&u)[:size_of(u)]
			} else {
				bytes = slice.to_bytes(arr[:])
			}
			for b in bytes {h = (h ~ u64(b)) * 0x100_0000_01b3}
		}
	}
	return h
}

// Earth is the same Earth in every universe: its terrain comes from its
// address, not the universe's seed. Another world's terrain does follow the
// seed.
@(test)
test_earth_same_in_every_universe :: proc(t: ^testing.T) {
	reg := game.registry_base(runtime.default_allocator())
	one, two: Server
	one.config.seed, two.config.seed = 1, 2
	earth := game.earth_address()
	e1 := World {
		server  = &one,
		address = earth,
	}
	e2 := World {
		server  = &two,
		address = earth,
	}
	testing.expect_value(t, terrain_hash(&e1, reg), terrain_hash(&e2, reg))
	other := game.address_derive(7)
	a1 := World {
		server  = &one,
		address = other,
		seed    = 1,
	}
	a2 := World {
		server  = &two,
		address = other,
		seed    = 2,
	}
	testing.expect(
		t,
		terrain_hash(&a1, reg) != terrain_hash(&a2, reg),
		"alien terrain ignored the seed",
	)
	// A new universe's home address: Earth's when asked, else made from the seed.
	testing.expect_value(t, home_address(&one), game.address_derive(1))
	one.config.earth = true
	testing.expect_value(t, home_address(&one), earth)
}

// A new world at Earth's address is built on the planet model; an alien one
// is not.
@(test)
test_earth_world_is_planet :: proc(t: ^testing.T) {
	w := World {
		address = game.earth_address(),
	}
	world_set_planet(&w)
	testing.expect_value(t, w.params.planet, 1)
	a := World {
		address = game.address_derive(7),
	}
	world_set_planet(&a)
	testing.expect_value(t, a.params.planet, worldgen.PARAMS_DEFAULTS.planet)
}

// Each universe begins somewhere else on the same Earth: the start comes from
// the universe's seed (the same seed, the same start), on habitable land.
@(test)
test_earth_start_comes_from_the_universe_seed :: proc(t: ^testing.T) {
	start :: proc(seed: i64) -> (f32, f32) {
		w := World {
			address = game.earth_address(),
			seed    = seed,
			params  = worldgen.PARAMS_DEFAULTS,
		}
		world_set_planet(&w)
		return w.params.spawn_lat, w.params.spawn_lon
	}
	a_lat, a_lon := start(1)
	b_lat, b_lon := start(2)
	again_lat, again_lon := start(1)
	testing.expect(
		t,
		a_lat == again_lat && a_lon == again_lon,
		"the same seed gives the same start",
	)
	testing.expect(t, a_lat != b_lat || a_lon != b_lon, "two seeds give two starts")
	for seed in i64(1) ..= 8 {
		lat, lon := start(seed)
		testing.expectf(t, lat >= -55 && lat <= 62, "seed %d: latitude %v", seed, lat)
		testing.expectf(t, !(lat == 43.3 && lon == 5.4), "seed %d: still Marseille", seed)
	}
}
