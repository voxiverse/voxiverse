package core

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:game"

// wool_dropped: the wool lying about in client name's world.
@(private = "file")
wool_dropped :: proc(srv: ^Server, name: string) -> int {
	Data :: struct {
		name:  string,
		count: int,
	}
	d := Data {
		name = name,
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			d := (^Data)(data)
			w := client_by_name(s, d.name).world
			for e in entities_view(w) {
				if e.kind == test_reg().engine.item &&
				   e.stack.item == game.item_of_block(test_reg(), .Wool) {
					d.count += e.stack.count
				}
			}
		}, &d)
	return d.count
}

// The exit check, over UDP and the save: using a sheep drops 1 to 3 wool
// and shears it (a second player sees it shorn); using a shorn sheep does
// nothing; a shorn sheep is shorn after save and load.
@(test)
test_shearing_a_sheep :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "sheep"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		rules             = quiet_rules(),
		seed              = 23,
		view_radius       = 3,
		view_height       = 2,
		max_players       = 4,
		listen            = true,
		everyone_cheats   = true,
		save_dir          = dir,
		no_natural_spawns = true, // (only the summoned one: natural ones spawn by day)
	}
	h := new(Harness)
	defer free(h)
	srv := &h.srv
	if !testing.expect(t, harness_start(h, config)) {return}
	stopped := false
	defer if !stopped {harness_stop(h)}
	a := new(Net_Client)
	defer free(a)
	b := new(Net_Client)
	defer free(b)
	net_connect(a, 0, "a", h = h)
	net_connect(b, 0, "b", h = h)
	defer net_close(a)
	defer net_close(b)
	both := []^Net_Client{a, b}
	ok := net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return landed(cs[0]) && landed(cs[1])},
	)
	if !testing.expect(t, ok, "never landed") {return}
	net_send(a, game.Command{"time midnight"}) // (no sheep of their own)
	net_send(a, game.Command{"summon sheep"})
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return len(cs[0].entities) == 1 && len(cs[1].entities) == 1
	})
	if !testing.expect(t, ok, "the sheep never showed up") {return}
	id: u32
	for k in a.entities {id = k}
	testing.expect(t, !a.shorn[id] && !b.shorn[id], "it starts shorn")

	// Used: shorn, and 1 to 3 wool.
	net_send(a, game.Use_Entity{id, a.seq})
	// (Both must have been told: the server sends to each client on its own,
	// so b hearing first does not mean a has.)
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		for c in cs {
			told := false
			for _, v in c.shorn {told ||= v}
			if !told {return false}
		}
		return true
	})
	testing.expect(
		t,
		ok && a.shorn[id] && b.shorn[id],
		"the sheep was not shorn (or a client was not told)",
	)
	wool := wool_dropped(srv, "a")
	testing.expectf(t, wool >= 1 && wool <= 3, "%d wool dropped", wool)
	// Used again: nothing more.
	net_send(a, game.Use_Entity{id, a.seq})
	net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 0.5)
	testing.expect_value(t, wool_dropped(srv, "a"), wool)

	// Too far to use: another sheep, and a player far from it.
	// (Reach is judged by the server.)
	net_send(b, game.Teleport{position = {400.5, 120, 0.5}})
	ok = net_wait(
		t,
		both,
		proc(cs: []^Net_Client) -> bool {return cs[1].update.state.position.x > 300},
	)
	testing.expect(t, ok)
	net_send(b, game.Use_Entity{id, b.seq})
	net_wait(t, both, proc(cs: []^Net_Client) -> bool {return false}, 0.3)

	// Kept: stop, read the file, start again.
	netcode_close_both(h, a, b)
	expect_items_balanced(t, srv)
	testing.expect(t, harness_stop(h))
	stopped = true
	saved, _ := os.read_entire_file_from_path(
		filepath.join({home_dir(dir, 23), ENTITIES_FILE}, context.temp_allocator) or_else "",
		context.temp_allocator,
	)
	testing.expect(
		t,
		strings.contains(string(saved), "sheep") && strings.contains(string(saved), "true"),
		"shorn was not saved",
	)
	if !testing.expect(t, harness_start(h, config)) {return}
	stopped = false
	again := new(Net_Client)
	defer free(again)
	net_connect(again, 0, "a", h = h)
	defer net_close(again)
	ok = net_wait(t, {again}, proc(cs: []^Net_Client) -> bool {
		for _, v in cs[0].shorn {if v {return true}}
		return false
	})
	testing.expect(t, ok, "the sheep came back with its wool")
}

@(private = "file")
netcode_close_both :: proc(h: ^Harness, a, b: ^Net_Client) {
	net_close(a)
	net_close(b)
	a^, b^ = {}, {}
	harness_step(h, 4)
}

// Grazing: a shorn sheep with its head down over grass eats it (the block
// becomes dirt) and has its wool back; one over no grass keeps it bare.
@(test)
test_grazing_regrows_wool :: proc(t: ^testing.T) {
	config := Config {
		rules             = quiet_rules(),
		seed              = 23,
		generator         = .Classic,
		view_radius       = 3,
		view_height       = 2,
		max_players       = 2,
		listen            = true,
		everyone_cheats   = true,
		no_natural_spawns = true, // (the test counts its own two: natural ones spawn by day)
	}
	h := new(Harness)
	defer free(h)
	srv := &h.srv
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	a := new(Net_Client)
	defer free(a)
	net_connect(a, 0, "a", h = h)
	defer net_close(a)
	if !testing.expect(t, net_wait(t, {a}, proc(cs: []^Net_Client) -> bool {
			return landed(cs[0]) && len(cs[0].chunks) > 100
		}), "never landed") {return}
	Case :: struct {
		x, y, z: i32,
		front:   game.Block_Pos, // the sheep's, over grass
		bare:    game.Block_Pos, // the other's, over stone
	}
	c := Case {
		x = i32(math.floor(a.update.state.position.x)),
		y = i32(math.floor(a.update.state.position.y)) + 14,
		z = i32(math.floor(a.update.state.position.z)),
	}
	// A platform: grass on one half, stone on the other; two sheep on it,
	// shorn, facing -z (their feet at y + 1).
	call(
		srv,
		proc(s: ^Server, data: rawptr) {
			c := (^Case)(data)
			w := client_by_name(s, "a").world
			for dx in i32(-3) ..= 3 {
				for dz in i32(-6) ..= 6 {
					b := game.Block.Grass if dx < 0 else game.Block.Stone
					set_block(w, {c.x + 10 + dx, c.y, c.z + dz}, b, test_act(w))
				}
			}
			for dx in ([]f64{-1.5, 1.5}) {
				ent := entity_spawn(
					w,
					test_reg().engine.sheep,
					{f64(c.x) + 10 + dx, f64(c.y) + 1, f64(c.z) + 0.5},
					false,
				)
				entity_set_yaw(w, ent, 0) // facing -z
				ent.shorn = true
				ent.brain = {
					state = .Graze,
					timer = 40,
				}
			}
			c.front = {c.x + 8, c.y, c.z - 1} // (the block before the grass sheep's feet, at x 8.5)
			c.bare = {c.x + 11, c.y, c.z - 1}
		},
		&c,
	)
	harness_step(h, 2 * game.TICK_RATE)
	Result :: struct {
		c:           ^Case,
		front_block: game.Block,
		bare_block:  game.Block,
		shorn:       [2]bool,
		sheep:       int,
	}
	r := Result {
		c = &c,
	}
	call(
		srv,
		proc(s: ^Server, data: rawptr) {
			r := (^Result)(data)
			w := client_by_name(s, "a").world
			r.front_block, _ = chunks_block(&w.chunks, r.c.front)
			r.bare_block, _ = chunks_block(&w.chunks, r.c.bare)
			for &e in entities_view(w) {
				if e.kind != test_reg().engine.sheep {continue}
				// The grass one is the one on the grass half.
				i := 0 if entity_pos(w, &e).x < f64(r.c.x) + 10 else 1
				r.shorn[i] = e.shorn
				r.sheep += 1
			}
		},
		&r,
	)
	testing.expect_value(t, r.sheep, 2)
	testing.expect_value(t, r.front_block, game.Block.Dirt) // eaten
	testing.expect_value(t, r.bare_block, game.Block.Stone)
	testing.expect(t, !r.shorn[0], "the sheep that ate has no wool")
	testing.expect(t, r.shorn[1], "the sheep over stone grew its wool back")
}

// A world saved when the animal was a critter loads with sheep in its place.
@(test)
test_old_saves_have_sheep :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "sheep_old"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		rules             = quiet_rules(),
		seed              = 24,
		view_radius       = 3,
		view_height       = 2,
		max_players       = 2,
		listen            = true,
		save_dir          = dir,
		generator         = .Classic,
		no_natural_spawns = true,
	}
	h := new(Harness)
	defer free(h)
	srv := &h.srv
	if !testing.expect(t, harness_start(h, config)) {return}
	a := new(Net_Client)
	defer free(a)
	net_connect(a, 0, "a", h = h)
	ok := net_wait(t, {a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	testing.expect(t, ok)
	net_close(a)
	a^ = {}
	harness_step(h, 4)
	testing.expect(t, harness_stop(h))
	path := filepath.join({home_dir(dir, 24), ENTITIES_FILE}, context.temp_allocator) or_else ""
	old := "# Voxiverse entities\ncritter 4.5000 20.0000 4.5000 1.0000 4 false\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)old) == nil)
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	b := new(Net_Client)
	defer free(b)
	net_connect(b, 0, "a", h = h)
	defer net_close(b)
	ok = net_wait(t, {b}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	testing.expect(t, ok)
	n := 0
	call(srv, proc(s: ^Server, data: rawptr) {
			w := client_by_name(s, "a").world
			for e in entities_view(w) {
				if e.kind == test_reg().engine.sheep && !e.shorn {(^int)(data)^ += 1}
			}
		}, &n)
	testing.expect_value(t, n, 1)
}

// Saves name kinds by their registry id: a save from before (the bare name) loads into
// the same kind, a pack's kind the world no longer has is dropped (and reported), and
// the next save writes the id.
@(test)
test_saves_name_kinds_by_id :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "sheep_ids"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		rules             = quiet_rules(),
		seed              = 25,
		view_radius       = 3,
		view_height       = 2,
		max_players       = 2,
		listen            = true,
		save_dir          = dir,
		generator         = .Classic,
		no_natural_spawns = true,
	}
	h := new(Harness)
	defer free(h)
	srv := &h.srv
	if !testing.expect(t, harness_start(h, config)) {return}
	a := new(Net_Client)
	defer free(a)
	net_connect(a, 0, "a", h = h)
	ok := net_wait(t, {a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	testing.expect(t, ok)
	net_close(a)
	a^ = {}
	harness_step(h, 4)
	testing.expect(t, harness_stop(h))
	path := filepath.join({home_dir(dir, 25), ENTITIES_FILE}, context.temp_allocator) or_else ""
	old :=
		"# Voxiverse entities\nsheep 4.5000 20.0000 4.5000 1.0000 4 false\n" +
		"voxiverse:sheep 6.5000 20.0000 4.5000 1.0000 4 false\n" +
		"voxiverse:cow 8.5000 20.0000 4.5000 1.0000 4 false\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)old) == nil)
	if !testing.expect(t, harness_start(h, config)) {return}
	b := new(Net_Client)
	defer free(b)
	net_connect(b, 0, "a", h = h)
	defer net_close(b)
	ok = net_wait(t, {b}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	testing.expect(t, ok)
	n := 0
	call(srv, proc(s: ^Server, data: rawptr) {
			w := client_by_name(s, "a").world
			(^int)(data)^ = len(entities_view(w))
			for e in entities_view(w) {
				if e.kind != s.registry.engine.sheep {(^int)(data)^ = -100}
			}
		}, &n)
	testing.expect_value(t, n, 2)
	net_close(b)
	b^ = {}
	harness_step(h, 4)
	testing.expect(t, harness_stop(h))
	saved, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(saved), "# Voxiverse entities"))
	testing.expect(t, strings.contains(string(saved), "\nvoxiverse:sheep "), "the id is written")
	testing.expect(t, !strings.contains(string(saved), "\nsheep "), "no bare name")
}
