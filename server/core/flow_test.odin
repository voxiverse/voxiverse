package core

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"

import "common:game"

// Fluids are data. Water's levels are the rule's levels; a pack's own fluid (oil: a
// type with states, no engine code) spreads by the same behaviour, and broken flow rules
// are refused at load with their file, line and the fix.

SIM_MANIFEST :: `{"format": 1, "namespace": "sim_test", "version": "1.0.0", "title": "Simulation test pack", "requires": ["voxiverse"]}`
OIL_BLOCK :: `{"oil": {"states": {"level": ["0", "1", "2", "3"], "falling": ["false", "true"]}, "default": {"level": "0", "falling": "false"}, "collides": false, "opaque": false, "targetable": false, "breakable": true, "placeable": true, "shades": true, "layer": "translucent", "textures": {"all": "voxiverse:water"}}}`
OIL_RULE :: `{"oil": {"behaviour": "flow", "levels": ["sim_test:oil[level=0]", "sim_test:oil[level=1]", "sim_test:oil[level=2]", "sim_test:oil[level=3]"], "falling": "sim_test:oil[falling=true]", "delay": 15, "reach": 2, "sources_form": false}}`

@(private = "file")
sim_pack :: proc(rule: string) -> game.Pack_Source {
	files := make([]game.Pack_File, 3, context.temp_allocator)
	files[0] = {"pack.json", transmute([]u8)string(SIM_MANIFEST)}
	files[1] = {"data/blocks/oil.json", transmute([]u8)string(OIL_BLOCK)}
	files[2] = {"data/sim/oil.json", transmute([]u8)rule}
	return {"sim_test", files}
}

@(test)
test_fluid_level_is_water_level :: proc(t: ^testing.T) {
	reg := test_reg()
	at, found := reg.ids[.Sim_Rule]["voxiverse:water"]
	if !testing.expect(t, found, "the base pack has no water rule") {return}
	f := &reg.sim.rules[at].fluid
	for level in i32(0) ..= game.WATER_FALLING_LEVEL {
		b := game.water_block(level)
		got, ok := game.fluid_level(f, b)
		testing.expectf(t, ok && got == level, "block %v: level %d, want %d", b, got, level)
		testing.expect_value(t, game.fluid_block(f, level), b)
		w, is_water := game.water_level(b)
		testing.expect(t, is_water && w == got)
	}
	_, other := game.fluid_level(f, .Stone)
	testing.expect(t, !other)
}

@(private = "file")
Oil_Run :: struct {
	hash:    u64,
	oil:     int, // oil cells on the platform's level
	reached: [4]bool, // levels 3 along +x, -x, +z, -z
	past:    bool, // oil at distance 4 along an axis
	fell:    bool, // falling oil under the platform's edge
	middle:  game.Block, // between two oil sources
	water:   game.Block, // the water source beside an oil source
}

@(private = "file")
oil_run :: proc(t: ^testing.T, dir: string) -> (r: Oil_Run, ok: bool) {
	os.remove_all(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.extra_packs = make([]game.Pack_Source, 1, context.temp_allocator)
	cfg.extra_packs[0] = sim_pack(OIL_RULE)
	g, opened := grief_open(t, dir, cfg)
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	reg := grief_srv(g).registry
	oil :: proc(reg: ^game.Registry, text: string) -> game.Block {
		b, found := game.registry_block(reg, text)
		assert(found, text)
		return b
	}
	source := oil(reg, "sim_test:oil[level=0]")
	level3 := oil(reg, "sim_test:oil[level=3]")
	falling := oil(reg, "sim_test:oil[falling=true]")
	// A platform in the air, cleared above: x 5..25, z -10..10, its top at y + 9.
	cmd(g, "fill %s stone", box(g, {5, 9, -10}, {25, 9, 10}))
	cmd(g, "fill %s air", box(g, {5, 10, -10}, {25, 16, 10}))
	put :: proc(g: ^Grief, p: game.Block_Pos, b: game.Block) {
		w := grief_world(g)
		set_block(w, p, b, world_act(w, .Command))
	}
	// One source in the middle; two sources with a gap; one by the edge; one beside water.
	put(g, at(g, 10, 10, 0), source)
	put(g, at(g, 17, 10, -8), source)
	put(g, at(g, 19, 10, -8), source)
	put(g, at(g, 23, 10, 8), source)
	put(g, at(g, 10, 10, 8), source)
	put(g, at(g, 11, 10, 8), .Water)
	for d in ([3]game.Block_Pos{{1, 0, -1}, {1, 0, 1}, {2, 0, 0}}) {put(g, at(g, 10, 10, 8) + d, .Stone)} 	// (a pocket: the water has nowhere else to go)
	run(g, 600)
	for x in i32(5) ..= 15 {
		for z in i32(-5) ..= 5 {
			if block_at_pos(w, at(g, x, 10, z)) != .Air {r.oil += 1}
		}
	}
	centre := at(g, 10, 10, 0)
	for d, i in ([4]game.Block_Pos{{3, 0, 0}, {-3, 0, 0}, {0, 0, 3}, {0, 0, -3}}) {
		r.reached[i] = block_at_pos(w, centre + d) == level3
	}
	for d in ([4]game.Block_Pos{{4, 0, 0}, {-4, 0, 0}, {0, 0, 4}, {0, 0, -4}}) {
		if block_at_pos(w, centre + d) != .Air {r.past = true}
	}
	r.fell = block_at_pos(w, at(g, 26, 9, 8)) == falling
	r.middle = block_at_pos(w, at(g, 18, 10, -8))
	r.water = block_at_pos(w, at(g, 11, 10, 8))
	r.hash = world_hash_here(g)
	return r, true
}

@(test)
test_pack_fluid_flows :: proc(t: ^testing.T) {
	a, ok1 := oil_run(t, "build/tmp/flow_oil_a")
	b, ok2 := oil_run(t, "build/tmp/flow_oil_b")
	if !testing.expect(t, ok1 && ok2) {return}
	testing.expect_value(t, a.hash, b.hash)
	testing.expectf(
		t,
		a.reached == {true, true, true, true},
		"oil did not spread three cells each way: %v",
		a.reached,
	)
	testing.expect(t, !a.past, "oil spread past three cells")
	testing.expect(t, a.fell, "oil did not fall off the platform's edge")
	testing.expectf(
		t,
		a.middle != .Water && a.middle != .Air,
		"no oil between two oil sources: %v",
		a.middle,
	)
	testing.expect(t, a.water == .Water, "the water beside an oil source changed")
}

@(private = "file")
refused :: proc(t: ^testing.T, rule: string, want: string) {
	context.logger = log.nil_logger()
	srcs := []game.Pack_Source{game.base_pack_source(context.temp_allocator), sim_pack(rule)}
	reg, errs := game.registry_build(srcs, .Server, context.temp_allocator)
	if !testing.expectf(t, reg == nil && len(errs) > 0, "the rule was accepted: %s", want) {return}
	text := game.pack_error_text(errs[0])
	testing.expectf(t, contains(text, want), "the message %q lacks %q", text, want)
	testing.expectf(
		t,
		contains(text, "data/sim/oil.json:"),
		"the message %q names no file and line",
		text,
	)
}

@(private = "file")
contains :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) {
		if s[i:i + len(sub)] == sub {return true}
	}
	return false
}

@(test)
test_broken_flow_rules_are_refused :: proc(t: ^testing.T) {
	refused(
		t,
		`{"oil": {"behaviour": "flow", "levels": ["sim_test:oil[level=0]", "sim_test:nothing"], "falling": "sim_test:oil[falling=true]"}}`,
		"is not a block",
	)
	refused(
		t,
		`{"oil": {"behaviour": "flow", "levels": ["sim_test:oil[level=0]", "sim_test:oil[level=0]"], "falling": "sim_test:oil[falling=true]"}}`,
		"named twice",
	)
	levels := ""
	for i in 0 ..< 16 {
		if i > 0 {levels = fmt.tprintf("%s, ", levels)}
		levels = fmt.tprintf("%s\"sim_test:oil[level=%d]\"", levels, i % 4)
	}
	refused(
		t,
		fmt.tprintf(
			`{"oil": {"behaviour": "flow", "levels": [%s, "voxiverse:stone"], "falling": "sim_test:oil[falling=true]"}}`,
			levels,
		),
		"1 to 15 flowing levels",
	)
	refused(
		t,
		`{"oil": {"behaviour": "flow", "levels": ["sim_test:oil[level=0]"], "falling": "sim_test:oil[falling=true]", "reach": 7}}`,
		"reach is 0..6",
	)
	refused(
		t,
		`{"oil": {"behaviour": "flow", "levels": ["sim_test:oil[level=0]"], "falling": "sim_test:oil[falling=true]"}, "oil2": {"behaviour": "flow", "levels": ["sim_test:oil[level=1]", "sim_test:oil[level=0]"], "falling": "sim_test:oil[level=2]"}}`,
		"one flow rule a block",
	)
}

@(private = "file")
Survive_Run :: struct {
	hash:    u64,
	waiting: int, // updates waiting at the save
	kept:    int, // of them still there, as due, after the reload
}

// survive_run: water flowing over a platform; with interrupt, at tick 12 (the water is still spreading) the world is saved and
// the platform's chunks are unloaded and loaded again from the save.
@(private = "file")
survive_run :: proc(t: ^testing.T, dir: string, interrupt: bool) -> (r: Survive_Run, ok: bool) {
	os.remove_all(dir)
	defer os.remove_all(dir)
	g, opened := grief_open(t, dir)
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	cmd(g, "fill %s stone", box(g, {20, 9, -8}, {40, 9, 8}))
	cmd(g, "fill %s air", box(g, {20, 10, -8}, {40, 14, 8}))
	set_block(w, at(g, 30, 10, 0), .Water, world_act(w, .Command))
	chunks := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	here := game.chunk_of(g.f)
	for cx in game.chunk_of(at(g, 20, 9, -8)).x ..= game.chunk_of(at(g, 40, 9, 8)).x {
		for cz in game.chunk_of(at(g, 20, 9, -8)).z ..= game.chunk_of(at(g, 40, 9, 8)).z {
			for cy in game.chunk_of(at(g, 20, 9, -8)).y ..= game.chunk_of(at(g, 40, 14, 8)).y {
				if (game.Chunk_Pos{cx, cy, cz}) == here {continue}
				append(&chunks, game.Chunk_Pos{cx, cy, cz})
			}
		}
	}
	started := age_of(grief_srv(g))
	for age_of(grief_srv(g)) - started < 12 {run(g, 1)}
	if interrupt {
		before := make([dynamic]Update, context.temp_allocator)
		for i in 0 ..< w.updates.count {
			x := w.updates.heap[i]
			if slice_has(chunks[:], game.chunk_of(x.pos)) {append(&before, x)}
		}
		r.waiting = len(before)
		testing.expect(t, world_save(w), "the save failed")
		for pos in chunks {
			c := chunks_get(&w.chunks, pos)
			if c == nil || c.state != .Ready {continue}
			keep_edits(w, c)
			chunks_unload(&w.chunks, pos)
		}
		for pos in chunks {testing.expect(t, request_chunk(w, pos))}
		for x in before {
			if x.pos in w.updates.queued {
				for i in 0 ..< w.updates.count {
					y := w.updates.heap[i]
					if y.pos == x.pos && y.due == x.due {r.kept += 1}
				}
			}
		}
	}
	for age_of(grief_srv(g)) - started < 400 {run(g, 1)}
	r.hash = hash_chunks(w, chunks[:])
	return r, true
}

@(private = "file")
slice_has :: proc(s: []game.Chunk_Pos, p: game.Chunk_Pos) -> bool {
	for x in s {if x == p {return true}}
	return false
}

@(test)
test_updates_survive_save :: proc(t: ^testing.T) {
	plain, ok1 := survive_run(t, "build/tmp/flow_survive_a", false)
	cut, ok2 := survive_run(t, "build/tmp/flow_survive_b", true)
	if !testing.expect(t, ok1 && ok2) {return}
	testing.expect(t, cut.waiting > 0, "no update was waiting at the save")
	testing.expect_value(t, cut.kept, cut.waiting)
	testing.expect_value(t, cut.hash, plain.hash)
}
