package server

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "../game"

// M24's exit check. A platform in the air over a landed player (its own
// columns, so "open sky" is exact), blocks set and random ticks run on the
// server thread by `call`, each case apart.

@(private = "file")
Farm :: struct {
	name:     string,
	x, y, z:  i32, // the platform's level and corner
	failures: [dynamic]string,
	numbers:  [8]f64, // what a case measured
}

@(private = "file")
farm_server :: proc(t: ^testing.T, srv: ^Server, a: ^Net_Client, dir := "") -> bool {
	config := Config {
		seed            = 24,
		generator       = .Classic,
		view_radius     = 3,
		view_height     = 2,
		workers         = 2,
		max_players     = 2,
		listen          = true,
		everyone_cheats = true,
		save_dir        = dir,
		no_sheep        = true,
	}
	if !testing.expect(t, start(srv, config, {})) {return false}
	net_connect(a, srv.host.socket.port, "a")
	return testing.expect(t, net_wait(t, {a}, proc(cs: []^Net_Client) -> bool {
			return landed(cs[0]) && len(cs[0].chunks) > 100
		}), "never landed")
}

@(private = "file")
farm_at :: proc(a: ^Net_Client) -> Farm {
	return {
		name = "a",
		x = i32(math.floor(a.update.state.position.x)) + 8,
		y = i32(math.floor(a.update.state.position.y)) + 14,
		z = i32(math.floor(a.update.state.position.z)) - 8,
	}
}

@(private = "file")
fail :: proc(f: ^Farm, what: string) {
	append(&f.failures, what)
}

@(private = "file")
block_at :: proc(w: ^World, p: game.Block_Pos) -> game.Block {
	b, _ := chunks_block(&w.chunks, p)
	return b
}

@(private = "file")
farm_run :: proc(t: ^testing.T, srv: ^Server, f: ^Farm, body: proc(s: ^Server, data: rawptr)) {
	call(srv, body, f)
	for what in f.failures {testing.expect(t, false, what)}
	delete(f.failures)
	f.failures = nil
}

// Grass spreads into lit dirt and not into dark dirt, and dies under stone.
@(test)
test_grass_spreads_and_dies :: proc(t: ^testing.T) {
	srv: Server
	a: Net_Client
	if !farm_server(t, &srv, &a) {return}
	defer stop(&srv)
	defer net_close(&a)
	f := farm_at(&a)
	farm_run(
		t,
		&srv,
		&f,
		proc(s: ^Server, data: rawptr) {
			f := (^Farm)(data)
			w := client_by_name(s, f.name).world
			p := game.Block_Pos{f.x, f.y, f.z}
			// A row at the platform's level: dark dirt, grass, lit dirt; the
			// dark one under a stone roof two up (nothing on it: it is only dark).
			for dx in i32(-3) ..= 3 {set_block(w, p + {dx, 0, 0}, .Dirt)}
			set_block(w, p + {-1, 0, 0}, .Dirt)
			set_block(w, p, .Grass)
			set_block(w, p + {-1, 2, 0}, .Stone)
			set_block(w, p + {-2, 2, 0}, .Stone)
			for _ in 0 ..< 300 {random_tick(w, p, .Grass)}
			if block_at(w, p + {1, 0, 0}) != .Grass {fail(f, "grass did not spread into lit dirt")}
			if block_at(w, p + {-1, 0, 0}) != .Dirt {fail(f, "grass spread into dark dirt")}
			// Under a block it dies.
			q := p + {0, 0, 6}
			set_block(w, q, .Grass)
			set_block(w, q + {0, 1, 0}, .Stone)
			random_tick(w, q, .Grass)
			if block_at(w, q) != .Dirt {fail(f, "grass lived under stone")}
			// Under a plant or air it does not.
			set_block(w, q, .Grass)
			set_block(w, q + {0, 1, 0}, .Poppy)
			random_tick(w, q, .Grass)
			if block_at(w, q) != .Grass {fail(f, "grass died under a flower")}
		},
	)
}

// Farmland is moist by water and dry without; dry bare farmland reverts,
// moist never straight to dirt; wheat keeps farmland.
@(test)
test_farmland_moisture :: proc(t: ^testing.T) {
	srv: Server
	a: Net_Client
	if !farm_server(t, &srv, &a) {return}
	defer stop(&srv)
	defer net_close(&a)
	f := farm_at(&a)
	farm_run(
		t,
		&srv,
		&f,
		proc(s: ^Server, data: rawptr) {
			f := (^Farm)(data)
			w := client_by_name(s, f.name).world
			p := game.Block_Pos{f.x, f.y, f.z}
			for dx in i32(-2) ..= 14 {set_block(w, p + {dx, 0, 0}, .Dirt)}
			set_block(w, p + {0, 0, 0}, .Farmland) // 4 from the water
			set_block(w, p + {4, 1, 0}, .Water) // on the level above is as good
			set_block(w, p + {9, 0, 0}, .Farmland) // 5 away: dry
			set_block(w, p + {11, 0, 0}, .Farmland) // dry, with wheat
			set_block(w, p + {11, 1, 0}, .Wheat_0)
			random_tick(w, p, .Farmland)
			if block_at(w, p) != .Farmland_Moist {fail(f, "farmland by water is not moist")}
			for _ in 0 ..< 20 {random_tick(w, p, block_at(w, p))}
			if block_at(w, p) != .Farmland_Moist {fail(f, "moist farmland changed")}
			random_tick(w, p + {11, 0, 0}, .Farmland)
			if block_at(w, p + {11, 0, 0}) != .Farmland {fail(f, "farmland under wheat went")}
			random_tick(w, p + {9, 0, 0}, .Farmland)
			if block_at(w, p + {9, 0, 0}) != .Dirt {fail(f, "dry bare farmland did not revert")}
			// The water goes: moist dries first, and only then, bare, reverts.
			set_block(w, p + {4, 1, 0}, .Air)
			random_tick(w, p, .Farmland_Moist)
			if block_at(w, p) != .Farmland {fail(f, "moist farmland stayed moist without water")}
			random_tick(w, p, .Farmland)
			if block_at(w, p) != .Dirt {fail(f, "the dried farmland did not revert")}
		},
	)
}

// Wheat ripens within the time its chances imply: 7 stages, each 1 tick in 3
// on moist farmland, 1 in 6 on dry; the mean over many plants.
@(test)
test_wheat_ripens :: proc(t: ^testing.T) {
	srv: Server
	a: Net_Client
	if !farm_server(t, &srv, &a) {return}
	defer stop(&srv)
	defer net_close(&a)
	f := farm_at(&a)
	farm_run(t, &srv, &f, proc(s: ^Server, data: rawptr) {
		f := (^Farm)(data)
		w := client_by_name(s, f.name).world
		PLANTS :: 160
		for wet in 0 ..< 2 {
			total := 0
			for i in i32(0) ..< PLANTS {
				p := game.Block_Pos{f.x + i % 16, f.y + i32(wet) * 4, f.z + i / 16 * 2}
				set_block(w, p, .Farmland_Moist if wet == 1 else .Farmland)
				up := p + {0, 1, 0}
				set_block(w, up, .Wheat_0)
				ticks := 0
				for block_at(w, up) != .Wheat_7 && ticks < 2000 {
					random_tick(w, up, block_at(w, up))
					ticks += 1
				}
				total += ticks
				if block_at(w, p) != (game.Block.Farmland_Moist if wet == 1 else .Farmland) {
					fail(f, "the farmland under wheat changed")
				}
			}
			f.numbers[wet] = f64(total) / PLANTS
		}
	})
	dry, moist := f.numbers[0], f.numbers[1] // (the case's own numbers: 42 and 21 expected)
	testing.expectf(
		t,
		moist > 17 && moist < 25,
		"moist wheat ripened in %.1f ticks on average (21 expected)",
		moist,
	)
	testing.expectf(
		t,
		dry > 36 && dry < 48,
		"dry wheat ripened in %.1f ticks on average (42 expected)",
		dry,
	)
}

// What breaking leaves: tall grass seeds 1 time in 8; wheat seeds, and wheat
// once ripe; farmland dirt; nothing with rules.drops off.
@(test)
test_crop_drops :: proc(t: ^testing.T) {
	srv: Server
	a: Net_Client
	if !farm_server(t, &srv, &a) {return}
	defer stop(&srv)
	defer net_close(&a)
	f := farm_at(&a)
	farm_run(
		t,
		&srv,
		&f,
		proc(s: ^Server, data: rawptr) {
			f := (^Farm)(data)
			w := client_by_name(s, f.name).world
			p := game.Block_Pos{f.x, f.y, f.z}
			seeds, wheat := game.item_of_material(.Seeds), game.item_of_material(.Wheat)
			count :: proc(w: ^World, item: game.Item) -> (n: int) {
				for e in w.entities.list {if e.kind == .Item && e.stack.item == item {n += e.stack.count}}
				return
			}
			// Tall grass: seeds about 1 in 8 (300 tries: 37 expected).
			for _ in 0 ..< 300 {block_drop(w, p, .Tall_Grass)}
			n := count(w, seeds)
			if n < 18 ||
			   n >
				   60 {fail(f, fmt.tprintf("300 tall grass dropped %d seeds (about 37 expected)", n))}
			clear(&w.entities.list)
			// Unripe wheat: one seed, no wheat. Ripe: one wheat, 1 to 3 seeds.
			for stage in 0 ..< game.WHEAT_STAGES - 1 {block_drop(w, p, game.wheat_block(stage))}
			if count(w, seeds) != 7 ||
			   count(w, wheat) != 0 {fail(f, "unripe wheat did not leave exactly a seed each")}
			clear(&w.entities.list)
			for _ in 0 ..< 40 {
				before := count(w, seeds)
				block_drop(w, p, .Wheat_7)
				got := count(w, seeds) - before
				if got < 1 || got > 3 {fail(f, "ripe wheat left seeds outside 1 to 3")}
			}
			if count(w, wheat) != 40 {fail(f, "ripe wheat did not leave one wheat each")}
			clear(&w.entities.list)
			// Farmland breaks into dirt; with drops off, nothing.
			block_drop(w, p, .Farmland_Moist)
			if count(w, game.item_of_block(.Dirt)) != 1 {fail(f, "farmland did not leave dirt")}
			clear(&w.entities.list)
			w.rules.drops = false
			block_drop(w, p, .Wheat_7)
			if len(w.entities.list) != 0 {fail(f, "a drop with rules.drops off")}
			w.rules.drops = true
		},
	)
}

// Random ticks run by themselves: with the speed raised, dry bare farmland
// reverts without anyone calling anything; at speed 0 nothing changes.
@(test)
test_random_ticks_run :: proc(t: ^testing.T) {
	srv: Server
	a: Net_Client
	if !farm_server(t, &srv, &a) {return}
	defer stop(&srv)
	defer net_close(&a)
	f := farm_at(&a)
	farm_run(
		t,
		&srv,
		&f,
		proc(s: ^Server, data: rawptr) {
			f := (^Farm)(data)
			w := client_by_name(s, f.name).world
			p := game.Block_Pos{f.x, f.y, f.z}
			set_block(w, p, .Dirt)
			set_block(w, p + {0, 1, 0}, .Farmland)
			set_block(w, p + {0, 1, 0}, .Farmland) // (the ground the farmland stands on is dirt)
			w.rules.random_tick_speed = 0
			for _ in 0 ..< 300 {random_ticks(w)}
			if block_at(w, p + {0, 1, 0}) != .Farmland {fail(f, "random ticks ran at speed 0")}
			w.rules.random_tick_speed = 100
			for _ in 0 ..< 1500 {
				random_ticks(w)
				if block_at(w, p + {0, 1, 0}) == .Dirt {break}
			}
			if block_at(w, p + {0, 1, 0}) !=
			   .Dirt {fail(f, "dry bare farmland never reverted by itself")}
		},
	)
}

// The hoe, seeds and the plant's footing, over UDP: farmland only with a hoe
// in hand and only out of grass or dirt with air above; seeds only on
// farmland; breaking the farmland takes the wheat with it.
@(test)
test_hoe_and_seeds_over_the_network :: proc(t: ^testing.T) {
	srv: Server
	a: Net_Client
	if !farm_server(t, &srv, &a) {return}
	defer stop(&srv)
	defer net_close(&a)
	feet := a.update.state.position
	ground := game.Block_Pos {
		i32(math.floor(feet.x)),
		i32(math.floor(feet.y)) - 1,
		i32(math.floor(feet.z)) + 1,
	}
	Data :: struct {
		ground: game.Block_Pos,
	}
	d := Data{ground}
	call(&srv, proc(s: ^Server, data: rawptr) {
			d := (^Data)(data)
			w := client_by_name(s, "a").world
			set_block(w, d.ground, .Grass)
			set_block(w, d.ground + {0, 1, 0}, .Air)
			set_block(w, d.ground + {0, 2, 0}, .Air)
		}, &d)
	net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return false}, 0.3)
	hoe, seeds := game.item_of_tool(.Hoe), game.item_of_material(.Seeds)
	// Hoe in slot 3 (hotbar 4), seeds in slot 4 (the kit's sand and log go to the cursor, and are lost).
	seq := u32(0)
	req :: proc(a: ^Net_Client, seq: ^u32, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
		seq^ += 1
		net_send(a, game.Inventory_Request{seq^, {kind, slot, arg}})
	}
	req(&a, &seq, .Take, game.CURSOR_SLOT, int(hoe))
	req(&a, &seq, .Click, 3)
	req(&a, &seq, .Take, game.CURSOR_SLOT, int(seeds))
	req(&a, &seq, .Click, 4)
	ok := net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return cs[0].inv_acked == 4})
	testing.expect(
		t,
		ok && a.inventory.slots[3].item == hoe && a.inventory.slots[4].item == seeds,
		"no hoe and seeds",
	)
	pos := ground
	up := pos + {0, 1, 0}
	// Without a hoe in hand (slot 0 holds stone): refused.
	net_send(&a, game.Edit{1, a.seq, pos, .Farmland})
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return 1 in cs[0].results})
	testing.expect(t, ok && !a.results[1].accepted, "tilled without a hoe")
	// With it (slot 3 selected): farmland.
	req(&a, &seq, .Select, 0, 3)
	net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return cs[0].inv_acked == 5})
	net_send(&a, game.Edit{2, a.seq, pos, .Farmland})
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return 2 in cs[0].results})
	testing.expect(t, ok && a.results[2].accepted, "the hoe did not till")
	net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return false}, 0.3)
	b := server_block(&srv, pos)
	testing.expect(t, game.block_is_farmland(b), "no farmland")
	// Tilling it again, or a block with something above it: refused.
	net_send(&a, game.Edit{3, a.seq, pos, .Farmland})
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return 3 in cs[0].results})
	testing.expect(t, ok && !a.results[3].accepted, "tilled farmland")
	// Seeds (slot 4) on the farmland: wheat, one seed used; on the grass beside: refused.
	req(&a, &seq, .Select, 0, 4)
	net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return cs[0].inv_acked == 6})
	net_send(&a, game.Edit{4, a.seq, pos + {1, 1, 0}, .Wheat_0}) // beside, in the air: nothing under it
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return 4 in cs[0].results})
	testing.expect(t, ok && !a.results[4].accepted, "seeds in the air")
	net_send(&a, game.Edit{5, a.seq, up, .Wheat_0})
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return 5 in cs[0].results})
	testing.expect(t, ok && a.results[5].accepted, "seeds on farmland were refused")
	net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return false}, 0.3)
	b = server_block(&srv, up)
	testing.expect_value(t, b, game.Block.Wheat_0)
	// Breaking the farmland takes the wheat with it, and leaves dirt.
	net_send(&a, game.Edit{6, a.seq, pos, .Air})
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return 6 in cs[0].results})
	testing.expect(t, ok && a.results[6].accepted)
	net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return false}, 0.5)
	b = server_block(&srv, up)
	testing.expect_value(t, b, game.Block.Air)
}

// Farmland and every stage of wheat are kept through save and load.
@(test)
test_farming_saved :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "farming"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	srv: Server
	a: Net_Client
	if !farm_server(t, &srv, &a, dir) {return}
	stopped := false
	defer if !stopped {stop(&srv)}
	defer net_close(&a)
	f := farm_at(&a)
	call(
		&srv,
		proc(s: ^Server, data: rawptr) {
			f := (^Farm)(data)
			w := client_by_name(s, f.name).world
			p := game.Block_Pos{f.x, f.y, f.z}
			w.rules.random_tick_speed = 0 // (as set)
			for stage in 0 ..< game.WHEAT_STAGES {
				base := p + {i32(stage), 0, 0}
				set_block(w, base, .Farmland_Moist if stage % 2 == 0 else .Farmland)
				set_block(w, base + {0, 1, 0}, game.wheat_block(stage))
			}
		},
		&f,
	)
	net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return false}, 0.5)
	net_close(&a)
	a = {}
	time.sleep(100 * time.Millisecond)
	testing.expect(t, stop(&srv))
	stopped = true
	if !testing.expect(
		t,
		start(
			&srv,
			Config {
				seed = 24,
				generator = .Classic,
				view_radius = 3,
				view_height = 2,
				workers = 2,
				max_players = 2,
				listen = true,
				everyone_cheats = true,
				save_dir = dir,
				no_sheep = true,
			},
			{},
		),
	) {return}
	stopped = false
	again: Net_Client
	net_connect(&again, srv.host.socket.port, "a")
	defer net_close(&again)
	ok := net_wait(
		t,
		{&again},
		proc(cs: []^Net_Client) -> bool {return landed(cs[0]) && len(cs[0].chunks) > 100},
	)
	testing.expect(t, ok)
	// The player may be elsewhere now; read the world on the server.
	call(&srv, proc(s: ^Server, data: rawptr) {
			f := (^Farm)(data)
			w := client_by_name(s, f.name).world
			p := game.Block_Pos{f.x, f.y, f.z}
			for stage in 0 ..< game.WHEAT_STAGES {
				base := p + {i32(stage), 0, 0}
				want := game.Block.Farmland_Moist if stage % 2 == 0 else .Farmland
				if block_at(w, base) !=
				   want {fail(f, fmt.tprintf("farmland %d was not kept", stage))}
				if block_at(w, base + {0, 1, 0}) !=
				   game.wheat_block(
					   stage,
				   ) {fail(f, fmt.tprintf("wheat stage %d was not kept", stage))}
			}
		}, &f)
	for what in f.failures {testing.expect(t, false, what)}
	delete(f.failures)
}

// server_block: the block at p, read on the server's thread (a client is not
// told of its own edits again).
@(private = "file")
server_block :: proc(srv: ^Server, p: game.Block_Pos) -> game.Block {
	Data :: struct {
		p: game.Block_Pos,
		b: game.Block,
	}
	d := Data{p, .Air}
	call(srv, proc(s: ^Server, data: rawptr) {
			d := (^Data)(data)
			d.b = block_at(client_by_name(s, "a").world, d.p)
		}, &d)
	return d.b
}
