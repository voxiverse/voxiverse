package core

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"

import "common:game"
import "common:protocol"
import "common:starmap"
import "common:worldgen"
import "server:store"

// An address is the same kind of world in any universe (its parameters and
// rules), with terrain of its own (the seed); the home world is Earth's.
@(test)
test_world_kinds :: proc(t: ^testing.T) {
	a := starmap.address_derive(999)
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
		address = starmap.address_derive(1000),
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
	away := starmap.address_derive(999)
	@(static) want: starmap.Address

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
		protocol.Command {
			strings.concatenate({"travel ", starmap.address_dir(away)}, context.temp_allocator),
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
	net_send(alice, protocol.edit_plain(1, alice.seq, at, .Stone))
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {return 1 in cs[0].results})
	testing.expect(t, ok && alice.results[1].accepted, "her edit was refused")

	// Home again: the other world goes once empty, its edit saved there.
	net_send(
		alice,
		protocol.Command {
			strings.concatenate({"travel ", starmap.address_dir(home)}, context.temp_allocator),
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
			{dir, store.WORLDS_DIR, starmap.address_dir(away), "regions"},
			context.temp_allocator,
		) or_else ""
	entries, _ := os.read_all_directory_by_path(away_regions, context.temp_allocator)
	testing.expect(t, len(entries) > 0, "the other world's edit was not saved in its directory")

	// Back and forth: memory comes back each time the other world goes.
	settled := stats(srv).arena_used
	for _ in 0 ..< 3 {
		for target in ([]starmap.Address{away, home}) {
			net_send(
				alice,
				protocol.Command {
					strings.concatenate(
						{"travel ", starmap.address_dir(target)},
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
	earth := starmap.earth_address()
	e1 := World {
		server  = &one,
		address = earth,
	}
	e2 := World {
		server  = &two,
		address = earth,
	}
	testing.expect_value(t, terrain_hash(&e1, reg), terrain_hash(&e2, reg))
	other := starmap.address_derive(7)
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
	testing.expect_value(t, home_address(&one), starmap.address_derive(1))
	one.config.earth = true
	testing.expect_value(t, home_address(&one), earth)
}

// A new world at Earth's address is built on the planet model; an alien one
// is not.
@(test)
test_earth_world_is_planet :: proc(t: ^testing.T) {
	w := World {
		address = starmap.earth_address(),
	}
	world_set_planet(&w)
	testing.expect_value(t, w.params.planet, 1)
	a := World {
		address = starmap.address_derive(7),
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
			address = starmap.earth_address(),
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

// A kept area is loaded with nobody near, stays loaded through the sweeps that free what
// no player wants, and goes once it is released.
@(test)
test_world_keeps_an_area :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	if !testing.expect(t, session_start(sess, {}, false, with = harness_world())) {return}
	defer session_stop(sess)
	w := sess.h.srv.home
	// Far from the spawn (the player's interest is 2 chunks around it): 3 x 2 x 3 chunks.
	area := Box{{320, -16, 320}, {360, 15, 360}}
	testing.expect(t, !world_ready(w, area))
	world_keep(w, area)
	ready :: proc(data: rawptr) -> bool {
		w := (^World)(data)
		return world_ready(w, {{320, -16, 320}, {360, 15, 360}})
	}
	_, ok := harness_step_until(&sess.h, ready, w, 300)
	testing.expect(t, ok, "the kept area was never loaded")
	harness_step(&sess.h, 2 * UNLOAD_SWEEP_TICKS)
	testing.expect(t, world_ready(w, area), "a sweep freed a kept chunk")
	testing.expect(t, chunks_get(&w.chunks, game.chunk_of(area.lo) - {1, 0, 0}) == nil)

	world_release(w)
	harness_step(&sess.h, UNLOAD_SWEEP_TICKS)
	testing.expect(t, chunks_get(&w.chunks, game.chunk_of(area.lo)) == nil, "released, it stayed")
}

// A game keeps state and files of its own for each world: made when the world opens (the
// home world after start, another as it loads), its files staged by each save and read back
// when the universe opens again, freed when the world closes (unloaded, or the session
// stops); a damaged file is moved aside, and --check finds it; a name it may not keep is
// refused at start.
@(private = "file")
Notes_Game :: struct {
	opened, closed, saved: int,
}

@(private = "file")
Notes :: struct {
	n:    int,
	read: bool, // its file was there when it opened
}

@(private = "file")
NOTES_GAME :: Game {
	info = {id = "notes", name = "Notes", description = "Keeps a note in each world."},
	server_state = Notes_Game,
	world_state = Notes,
	world_files = {{name = "note.txt", check = proc(data: []u8) -> bool {
				_, ok := strconv.parse_int(string(data))
				return ok
			}}},
	world_opened = proc(s: ^Server, w: ^World) {
		game_state(s, Notes_Game).opened += 1
		if data, ok := world_file_read(w, "note.txt"); ok {
			n, parsed := strconv.parse_int(string(data))
			if !parsed {
				world_file_aside(w, "note.txt")
				return
			}
			world_state(w, Notes)^ = {n, true}
		}
	},
	world_closed = proc(s: ^Server, w: ^World) {game_state(s, Notes_Game).closed += 1},
	world_save = proc(s: ^Server, w: ^World) {
		game_state(s, Notes_Game).saved += 1
		world_file_write(w, "note.txt", transmute([]u8)fmt.tprint(world_state(w, Notes).n))
	},
}

@(test)
test_a_game_keeps_files_of_its_own_in_each_world :: proc(t: ^testing.T) {
	dir := scratch_dir("world_files")
	defer delete(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.game = NOTES_GAME
	cfg.world_idle = 0.5
	g, ok := grief_open(t, dir, cfg)
	if !ok {
		grief_close(g)
		return
	}
	s := grief_srv(g)
	notes := game_state(s, Notes_Game)
	testing.expect_value(t, notes.opened, 1)
	world_state(s.home, Notes).n = 42
	testing.expect(t, save(s))
	path := filepath.join({s.home.dir, "notes.note.txt"}, context.temp_allocator) or_else ""
	text, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect_value(t, string(text), "42")

	// Another world opens as it loads and closes as it unloads, saved first.
	other := world_load(s, starmap.address_derive(4242))
	if !testing.expect(t, other != nil, "no second world") {
		grief_close(g)
		return
	}
	testing.expect_value(t, notes.opened, 2)
	world_state(other, Notes).n = 7
	run(g, 60)
	testing.expect_value(t, len(s.worlds), 1)
	testing.expect_value(t, notes.closed, 1)
	other_path :=
		filepath.join(
			{dir, "worlds", starmap.address_dir(starmap.address_derive(4242)), "notes.note.txt"},
			context.temp_allocator,
		) or_else ""
	text, _ = os.read_entire_file_from_path(other_path, context.temp_allocator)
	testing.expect_value(t, string(text), "7")
	grief_close(g)

	// Opened again: the home world's note is read back.
	g2, ok2 := grief_open(t, dir, cfg)
	if ok2 {
		home := grief_srv(g2).home
		testing.expect_value(t, world_state(home, Notes)^, Notes{42, true})
		grief_close_keep(g2)
	}
	grief_close(g2)

	// A file the game cannot read is moved aside; the world opens without it.
	_ = os.write_entire_file(path, transmute([]u8)string("forty-two"))
	// --check asks the game whether its files read (only the game the universe plays).
	report := universe_check(dir, {NOTES_GAME})
	testing.expectf(t, !report.ok && len(report.problems) == 1, "%v", report.problems)
	testing.expect(t, universe_check(dir).ok, "a game not given checked its files")
	quiet := context.logger // (opening reports it as an error, quieted here)
	quiet.lowest_level = .Fatal
	context.logger = quiet
	g3, ok3 := grief_open(t, dir, cfg)
	if ok3 {
		testing.expect_value(t, world_state(grief_srv(g3).home, Notes)^, Notes{})
		testing.expect(t, os.exists(fmt.tprintf("%s.bad", path)), "the damaged file stayed")
		grief_close_keep(g3)
	}
	grief_close(g3)

	// Names a game may not keep.
	for bad in ([]string{"", "../note", "Note", "a/b"}) {
		game := NOTES_GAME
		game.world_files = {{name = bad}}
		testing.expectf(t, harness_refused({game = game}), "%q was kept", bad)
	}
	game := NOTES_GAME
	game.world_files = {{name = "note.txt"}, {name = "note.txt"}}
	testing.expect(t, harness_refused({game = game}), "a name twice was kept")
}

// A game sends a player to another world and back (travel, go_to), and is told of each
// change of world through its travelled hook, as it is of a gate's; a move within one
// world tells it nothing.
@(private = "file")
Trips :: struct {
	n:        int,
	from, to: [4]starmap.Address,
}

@(private = "file")
TRIPS_GAME :: Game {
	info = {id = "trips", name = "Trips", description = "Counts its players' trips."},
	server_state = Trips,
	travelled = proc(s: ^Server, c: ^Client, from, to: ^World) {
		trips := game_state(s, Trips)
		assert(c.world == to, "told of a trip before it was made")
		if trips.n < len(trips.from) {
			trips.from[trips.n], trips.to[trips.n] = from.address, to.address
		}
		trips.n += 1
	},
}

@(test)
test_a_game_sends_players_between_worlds :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	config := harness_world()
	config.game = TRIPS_GAME
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return}
	defer session_stop(sess)
	s := &sess.h.srv
	if !testing.expect(t, harness_landed(&sess.h), "the player never landed") {return}
	c := &s.clients[0]
	trips := game_state(s, Trips)
	home, away := s.home.address, starmap.address_derive(31)

	testing.expect_value(t, travel(s, c, away), "")
	testing.expect_value(t, c.world.address, away)
	testing.expect_value(t, go_to(s, c, {home, {3.5, 0, 3.5}, {}}), "")
	testing.expect_value(t, c.world, s.home)
	testing.expect_value(t, go_to(s, c, {home, {0.5, 0, 0.5}, {}}), "")
	testing.expect_value(t, trips.n, 2)
	testing.expect_value(t, trips.from[0], home)
	testing.expect_value(t, trips.to[0], away)
	testing.expect_value(t, trips.from[1], away)
	testing.expect_value(t, trips.to[1], home)

	// Through an open gate at the player's feet, as one dialed would be.
	for _ in 0 ..< 3 {session_step(sess, false)}
	feet := c.player.position
	ring := worldgen.Structure {
		kind = .Gate,
		lo   = {
			i32(math.floor(feet.x)) - 5,
			i32(math.floor(feet.y)) - 1,
			i32(math.floor(feet.z)) - 1,
		},
	}
	append(
		&s.home.gates,
		Gate {
			structure = ring,
			phase = .Open,
			outgoing = true,
			to = away,
			far = ring,
			next_at = s.tick + 100,
		},
	)
	session_step(sess, false)
	testing.expect_value(t, trips.n, 3)
	testing.expect_value(t, c.world.address, away)
	testing.expect_value(t, trips.from[2], home)
	clear(&sess.failures) // (the mirror does not follow every record of a world it left)
}

// harness_landed steps the harness until its first seat plays and has landed; false if it
// never does.
harness_landed :: proc(h: ^Harness) -> bool {
	_, ok := harness_step_until(h, proc(data: rawptr) -> bool {
			c := &(^Server)(data).clients[0]
			return c.state == .Playing && c.landing == nil
		}, &h.srv, 600)
	return ok
}

// A game claims one address as a flat world of its own (Game.world_kind): a player travels
// there with no gate, lands at its spawn and comes back; unloaded and loaded again, it is
// the same world. Every other address is the engine's kind, as it was.
@(private = "file")
CLAIMED_ADDRESS :: 4243

@(private = "file")
CLAIMS_GAME :: Game {
	info = {id = "claims", name = "Claims", description = "Claims one world as flat."},
	world_kind = proc(s: ^Server, a: starmap.Address) -> (World_Kind, bool) {
		if a != starmap.address_derive(CLAIMED_ADDRESS) {return {}, false}
		rules := game.RULES_DEFAULTS
		rules.gravity = 20
		return {generator = .Flat, rules = rules}, true
	},
}

@(test)
test_a_game_claims_a_world :: proc(t: ^testing.T) {
	dir := scratch_dir("claimed_world")
	defer delete(dir)
	defer os.remove_all(dir)
	sess := new(Session)
	defer free(sess)
	config := harness_world()
	config.game = CLAIMS_GAME
	config.generator = .Earth // (the home world: unclaimed, as ever)
	config.spawn = nil
	config.save_dir = dir
	config.world_idle = 0.5
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return}
	defer session_stop(sess)
	s := &sess.h.srv
	if !testing.expect(t, harness_landed(&sess.h), "the player never landed") {return}
	c := &s.clients[0]
	home, claimed := s.home.address, starmap.address_derive(CLAIMED_ADDRESS)

	// Another address is the engine's kind, the game's or not.
	other := World {
		server  = s,
		address = starmap.address_derive(CLAIMED_ADDRESS + 1),
	}
	plain: Server
	plain.config.seed = s.config.seed
	plain_other := World {
		server  = &plain,
		address = other.address,
	}
	world_kind(&other)
	world_kind(&plain_other)
	testing.expect_value(t, other.generator, worldgen.Kind.Earth)
	testing.expect(t, other.params == plain_other.params && other.rules == plain_other.rules)

	// There and back, with no gate.
	testing.expect_value(t, travel(s, c, claimed), "")
	w := c.world
	testing.expect_value(t, w.generator, worldgen.Kind.Flat)
	testing.expect_value(t, w.rules.gravity, 20)
	if !testing.expect(t, harness_landed(&sess.h), "never landed in the claimed world") {return}
	feet := c.player.position
	below := game.Block_Pos {
		i32(math.floor(feet.x)),
		i32(math.floor(feet.y)) - 1,
		i32(math.floor(feet.z)),
	}
	b, loaded := chunks_block(&w.chunks, below)
	testing.expect(t, loaded && b != .Air, "nothing to stand on at the spawn")
	around := []game.Chunk_Pos{game.chunk_of(below), game.chunk_of(below) + {1, 0, 0}}
	for p in around {testing.expect(t, chunks_get(&w.chunks, p) != nil, "a chunk by the spawn not loaded")}
	hash := hash_chunks(w, around)
	params, rules := w.params, w.rules
	testing.expect_value(t, travel(s, c, home), "")

	// Unloaded once nobody is in it, then loaded again: the same world.
	_, gone := harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			return len((^Server)(data).worlds) == 1
		}, s, 600)
	if !testing.expect(t, gone, "the claimed world never unloaded") {return}
	testing.expect_value(t, travel(s, c, claimed), "")
	if !testing.expect(t, harness_landed(&sess.h), "never landed again") {return}
	w = c.world
	testing.expect_value(t, w.generator, worldgen.Kind.Flat)
	testing.expect(t, w.params == params && w.rules == rules, "loaded again, another kind")
	testing.expect_value(t, hash_chunks(w, around), hash)
	testing.expect_value(t, travel(s, c, home), "")
	clear(&sess.failures) // (the mirror does not follow every record of a world it left)
}
