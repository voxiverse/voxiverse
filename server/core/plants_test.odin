package core

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"

import "common:game"
import "common:protocol"

// The exit check: a plant breaks, and drops its item, when the block
// under it goes or stops holding it; one rule for a single block, a chain
// of plants, and a bulk edit; a plant is not placed where it would not hold.
@(test)
test_plants_need_support :: proc(t: ^testing.T) {
	config := Config {
		rules           = quiet_rules(),
		seed            = 22,
		generator       = .Classic,
		view_radius     = 3,
		view_height     = 2,
		max_players     = 2,
		listen          = true,
		everyone_cheats = true,
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
	x, z := i32(math.floor(a.update.state.position.x)), i32(math.floor(a.update.state.position.z))
	y := i32(math.floor(a.update.state.position.y)) + 14 // in the air over the ground

	Case :: struct {
		name:     string,
		x, y, z:  i32,
		failures: [dynamic]string,
	}
	data := Case {
		name = "a",
		x    = x,
		y    = y,
		z    = z,
	}
	defer delete(data.failures)
	call(
		srv,
		proc(s: ^Server, data: rawptr) {
			c := (^Case)(data)
			w := client_by_name(s, c.name).world
			fail :: proc(c: ^Case, what: string) {append(&c.failures, what)}
			at :: proc(c: ^Case, dx, dy, dz: i32) -> game.Block_Pos {
				return {c.x + dx, c.y + dy, c.z + dz}
			}
			block :: proc(w: ^World, p: game.Block_Pos) -> game.Block {
				b, _ := chunks_block(&w.chunks, p)
				return b
			}
			drops :: proc(w: ^World, item: game.Item) -> (n: int) {
				for e in entities_snapshot(w) {if entity_kind(w, e) == test_reg().engine.item && entity_stack(w, e)^.item == item {n += 1}}
				return
			}
			// A flower on dirt, a dandelion on sand, tall grass on grass.
			set_block(w, at(c, 0, 0, 0), .Dirt, test_act(w))
			set_block(w, at(c, 0, 1, 0), .Poppy, test_act(w))
			set_block(w, at(c, 2, 0, 0), .Sand, test_act(w))
			set_block(w, at(c, 2, 1, 0), .Dandelion, test_act(w))
			set_block(w, at(c, 4, 0, 0), .Grass, test_act(w))
			set_block(w, at(c, 4, 1, 0), .Tall_Grass, test_act(w))
			set_block(w, at(c, 6, 0, 0), .Stone, test_act(w)) // a flower the stone does not hold
			set_block(w, at(c, 6, 1, 0), .Poppy, test_act(w))
			if block(w, at(c, 0, 1, 0)) != .Poppy || block(w, at(c, 2, 1, 0)) != .Dandelion {
				fail(c, "plants on what holds them were removed")
			}
			// The ground goes from under the poppy: it breaks and drops itself.
			poppy := game.item_of_block(test_reg(), .Poppy)
			before := drops(w, poppy)
			set_block(w, at(c, 0, 0, 0), .Air, test_act(w))
			if block(w, at(c, 0, 1, 0)) != .Air {fail(c, "the poppy stayed in the air")}
			if drops(w, poppy) != before + 1 {fail(c, "the poppy dropped nothing")}
			// Water or a placed stone in place of the dirt does the same.
			set_block(w, at(c, 2, 0, 0), .Stone, test_act(w))
			if block(w, at(c, 2, 1, 0)) != .Air {fail(c, "the dandelion stayed on stone")}
			// Tall grass drops nothing (until it has seeds), but goes.
			set_block(w, at(c, 4, 0, 0), .Air, test_act(w))
			if block(w, at(c, 4, 1, 0)) != .Air {fail(c, "the tall grass stayed")}
			// Placed by hand where nothing holds it: the edit is refused.
			if support_placeable(
				w,
				at(c, 6, 1, 0),
				.Poppy,
			) {fail(c, "a poppy may be placed on stone")}
			set_block(w, at(c, 8, 0, 0), .Grass, test_act(w))
			if !support_placeable(w, at(c, 8, 1, 0), .Poppy) ||
			   !support_placeable(w, at(c, 8, 1, 0), .Stone) {
				fail(c, "placing is refused where it should not be")
			}
			// Drops off: nothing left behind.
			w.rules.drops = false
			set_block(w, at(c, 8, 1, 0), .Dandelion, test_act(w))
			dandelion := game.item_of_block(test_reg(), .Dandelion)
			count := drops(w, dandelion)
			set_block(w, at(c, 8, 0, 0), .Air, test_act(w))
			if drops(w, dandelion) != count {fail(c, "a drop with rules.drops off")}
			w.rules.drops = true
		},
		&data,
	)
	for f in data.failures {testing.expect(t, false, f)}

	// A bulk edit: a row of grass with flowers, the row replaced by air.
	net_send(a, protocol.Command{"fill 0 0 0 0 0 0 air"}) // (a command that does nothing: the permission check)
	for dx in i32(0) ..< 6 {
		net_send(a, protocol.Command{bulk_at("fill", x + 10 + dx, y, z, "grass")})
		net_send(a, protocol.Command{bulk_at("fill", x + 10 + dx, y + 1, z, "poppy")})
	}
	net_for(t, {a}, 1)
	for dx in i32(0) ..< 6 {
		b, _ := net_block(a, {x + 10 + dx, y + 1, z})
		testing.expect_value(t, b, game.Block.Poppy)
	}
	net_send(a, protocol.Command{bulk_row("fill", x + 10, x + 15, y, z, "air")})
	net_for(t, {a}, 1)
	for dx in i32(0) ..< 6 {
		b, _ := net_block(a, {x + 10 + dx, y + 1, z})
		testing.expectf(t, b == .Air, "a poppy stayed at %d after the bulk edit", dx)
	}
	after := poppies_dropped(srv, x + 5)
	dropped := after
	testing.expectf(
		t,
		dropped == 6,
		"the bulk edit's poppies dropped %d (6 expected; the first, over the player, is theirs)",
		dropped,
	)
}

@(private = "file")
poppies_dropped :: proc(srv: ^Server, beyond: i32) -> (count: int) {
	Data :: struct {
		count:  int,
		beyond: f64,
	}
	d := Data{0, f64(beyond)}
	call(srv, proc(s: ^Server, data: rawptr) {
			d := (^Data)(data)
			n := &d.count
			w := client_by_name(s, "a").world
			for e in entities_snapshot(w) {
				if entity_kind(w, e) == test_reg().engine.item &&
				   entity_stack(w, e)^.item ==
					   game.item_of_block(test_reg(), .Poppy) {n^ += entity_stack(w, e)^.count}
			}
		}, &d)
	return d.count
}

@(private = "file")
bulk_at :: proc(cmd: string, x, y, z: i32, block: string) -> string {
	return fmt.tprintf("%s %d %d %d %d %d %d %s", cmd, x, y, z, x, y, z, block)
}

@(private = "file")
bulk_row :: proc(cmd: string, x0, x1, y, z: i32, block: string) -> string {
	return fmt.tprintf("%s %d %d %d %d %d %d %s", cmd, x0, y, z, x1, y, z, block)
}

CANE_BLOCK :: `{"cane": {"collides": false, "opaque": false, "render": "cross", "layer": "cutout", "support": {"below": "sim_test:cane_soil"}, "textures": {"all": "voxiverse:water"}}}`
CANE_TAG :: `{"cane_soil": {"values": ["voxiverse:grass", "sim_test:cane"]}}`

// A cascade is bounded: a stack of plants each standing on the one under it, taller than
// a settle reaches, goes over several ticks, no tick taking more than a settle's reach,
// and ends as it did when it went all at once: every cane gone, each dropping its item,
// every change journaled with the cause of the change under the stack, how Support.
@(test)
test_support_cascade_is_bounded :: proc(t: ^testing.T) {
	dir := "build/tmp/support_cascade"
	os.remove_all(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	files := make([]game.Pack_File, 3, context.temp_allocator)
	files[0] = {"pack.json", transmute([]u8)string(SIM_MANIFEST)}
	files[1] = {"data/blocks/cane.json", transmute([]u8)string(CANE_BLOCK)}
	files[2] = {"data/block_tags/cane.json", transmute([]u8)string(CANE_TAG)}
	cfg.extra_packs = []game.Pack_Source{{"sim_test", files}}
	g, opened := grief_open(t, dir, cfg)
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	reg := grief_srv(g).registry
	cane, found := game.registry_block(reg, "sim_test:cane")
	if !testing.expect(t, found) {return}
	HEIGHT :: 24
	ground := at(g, 6, 2, 0)
	cmd(g, "fill %s air", box(g, {6, 2, 0}, {6, 2 + HEIGHT + 1, 0}))
	set_block(w, ground, .Grass, test_act(w))
	for y in i32(1) ..= HEIGHT {set_block(w, ground + {0, y, 0}, cane, test_act(w))}
	standing :: proc(w: ^World, ground: game.Block_Pos, cane: game.Block) -> (n: int) {
		for y in i32(1) ..= HEIGHT {if block_at_pos(w, ground + {0, y, 0}) == cane {n += 1}}
		return
	}
	if !testing.expect_value(t, standing(w, ground, cane), HEIGHT) {return}

	act := Act{action_begin(w, {}, .Command), .Command}
	head := w.journal.head
	set_block(w, ground, .Air, act)
	left := standing(w, ground, cane)
	reach := 2 * SUPPORT_REACH + 1
	testing.expectf(t, left > 0, "all %d canes went in the tick of the change", HEIGHT)
	testing.expectf(t, HEIGHT - left <= reach, "%d canes went at once", HEIGHT - left)
	ticks := 0
	for left > 0 && ticks < HEIGHT {
		run(g, 1)
		ticks += 1
		now := standing(w, ground, cane)
		testing.expectf(t, left - now <= reach, "%d canes went in one tick", left - now)
		left = now
	}
	testing.expectf(t, left == 0, "%d canes stand after %d ticks", left, ticks)
	testing.expect(t, ticks > 1, "the stack did not take several ticks")

	gone := 0
	for k in head + 1 ..< w.journal.head {
		e := ring_at(&w.journal, k)
		if e.new != .Air || e.old != cane {continue}
		gone += 1
		testing.expectf(
			t,
			e.action == u32(act.action) && e.how == .Support,
			"a cane went by %v",
			e^,
		)
	}
	testing.expect_value(t, gone, HEIGHT)
	dropped := 0
	for e in entities_snapshot(w) {
		if entity_kind(w, e) == reg.engine.item &&
		   entity_stack(w, e)^.item ==
			   game.item_of_block(reg, cane) {dropped += entity_stack(w, e)^.count}
	}
	testing.expect_value(t, dropped, HEIGHT)
}
