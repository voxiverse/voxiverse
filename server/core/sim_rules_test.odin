package core

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "common:game"

// M49b: neighbour rules as data. A pack defines a creeping substance (with a channel of its
// own) and fire in rule files only; the server runs them on M49's scheduler.

@(private = "file")
rules_config :: proc(dir: string, extra: []game.Pack_File = nil) -> Config {
	cfg := grief_config(dir)
	cfg.extra_packs = make([]game.Pack_Source, 1, context.temp_allocator)
	cfg.extra_packs[0] = game.sim_test_pack(extra)
	return cfg
}

@(private = "file")
block_of :: proc(g: ^Grief, text: string) -> game.Block {
	b, ok := game.registry_block(grief_srv(g).registry, text)
	assert(ok, text)
	return b
}

// The world hash after 600 ticks (pinned when the test first passed: the three OSes' CI
// runs check that the rules give bit-identical worlds everywhere).
CREEP_HASH :: u64(11098566303082434175)
FIRE_HASH :: u64(899791116715346582)

@(private = "file")
Creep_Run :: struct {
	hash:   u64,
	cells:  int,
	zero:   bool,
	bad:    int, // cells with a potency above the distance's bound
	leaked: int, // creep outside the stone box
}

@(private = "file")
creep_run :: proc(
	t: ^testing.T,
	dir: string,
	ticks: int,
	save_at: int,
) -> (
	r: Creep_Run,
	ok: bool,
) {
	os.remove_all(dir)
	defer os.remove_all(dir)
	g, opened := grief_open(t, dir, rules_config(dir))
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	reg := grief_srv(g).registry
	potency, _ := game.registry_channel(reg, "sim_test:potency")
	creep := block_of(g, "sim_test:creep")
	cmd(g, "fill %s stone", box(g, {2, -15, -15}, {32, 15, 15}))
	centre := at(g, 17, 0, 0)
	set_block(w, centre, creep, world_act(w, .Command))
	set_channel(w, centre, potency, 15, world_act(w, .Command))
	if save_at > 0 {
		run(g, save_at)
		chunks := make([dynamic]game.Chunk_Pos, context.temp_allocator)
		here := game.chunk_of(g.f)
		lo, hi := game.chunk_of(at(g, 2, -15, -15)), game.chunk_of(at(g, 32, 15, 15))
		for cy in lo.y ..= hi.y {
			for cz in lo.z ..= hi.z {
				for cx in lo.x ..= hi.x {
					if (game.Chunk_Pos{cx, cy, cz}) !=
					   here {append(&chunks, game.Chunk_Pos{cx, cy, cz})}
				}
			}
		}
		testing.expect(t, world_save(w), "the save failed")
		for pos in chunks {
			c := chunks_get(&w.chunks, pos)
			if c == nil || c.state != .Ready {continue}
			keep_edits(w, c)
			chunks_unload(&w.chunks, pos)
		}
		for pos in chunks {testing.expect(t, request_chunk(w, pos))}
		run(g, ticks - save_at)
	} else {
		run(g, ticks)
	}
	for y in i32(-17) ..= 17 {
		for z in i32(-17) ..= 17 {
			for x in i32(-17) ..= 17 {
				p := centre + {x, y, z}
				if block_at_pos(w, p) != creep {continue}
				inside := abs(x) <= 15 && abs(y) <= 15 && abs(z) <= 15
				if !inside {r.leaked += 1; continue}
				r.cells += 1
				v, _ := chunks_channel(w, p, potency)
				dist := max(abs(x), abs(y), abs(z))
				if int(v) > 15 - int(dist) {r.bad += 1}
				if v == 0 {r.zero = true}
			}
		}
	}
	r.hash = world_hash_here(g)
	return r, true
}

@(test)
test_creep_spreads :: proc(t: ^testing.T) {
	a, ok1 := creep_run(t, "build/tmp/rules_creep_a", 600, 0)
	b, ok2 := creep_run(t, "build/tmp/rules_creep_b", 600, 0)
	if !testing.expect(t, ok1 && ok2) {return}
	fmt.println("creep:", a)
	testing.expect(t, a.cells > 20, "the creep did not spread")
	testing.expect(t, a.zero, "no creep cell reached potency 0")
	testing.expect_value(t, a.bad, 0)
	testing.expect_value(t, a.leaked, 0)
	testing.expect_value(t, a.hash, b.hash)
	testing.expect_value(t, a.hash, CREEP_HASH)
}

@(test)
test_creep_survives_save :: proc(t: ^testing.T) {
	plain, ok1 := creep_run(t, "build/tmp/rules_survive_a", 600, 0)
	cut, ok2 := creep_run(t, "build/tmp/rules_survive_b", 600, 100)
	if !testing.expect(t, ok1 && ok2) {return}
	testing.expect_value(t, cut.hash, plain.hash)
	testing.expect_value(t, cut.cells, plain.cells)
}

@(private = "file")
Fire_Run :: struct {
	hash:   u64,
	fires:  int,
	planks: int,
	stray:  int, // stone or air outside the house changed
}

@(private = "file")
fire_run :: proc(t: ^testing.T, dir: string) -> (r: Fire_Run, ok: bool) {
	os.remove_all(dir)
	defer os.remove_all(dir)
	g, opened := grief_open(t, dir, rules_config(dir))
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	fire := block_of(g, "sim_test:fire")
	planks := block_of(g, "voxiverse:planks")
	// A stone floor, clear air above it, and a planks house (5 x 3 x 5) on it.
	cmd(g, "fill %s stone", box(g, {10, 4, -6}, {26, 4, 6}))
	cmd(g, "fill %s air", box(g, {10, 5, -6}, {26, 12, 6}))
	cmd(g, "fill %s voxiverse:planks", box(g, {16, 5, -2}, {20, 7, 2}))
	set_block(w, at(g, 18, 8, 0), fire, world_act(w, .Command))
	run(g, 3000)
	for y in i32(4) ..= 12 {
		for z in i32(-6) ..= 6 {
			for x in i32(10) ..= 26 {
				p := at(g, x, y, z)
				b := block_at_pos(w, p)
				if b == fire {r.fires += 1}
				house := x >= 16 && x <= 20 && y >= 5 && y <= 7 && z >= -2 && z <= 2
				if b == planks {r.planks += 1}
				if !house {
					want :=
						game.Block.Stone if y == 4 && x >= 10 && x <= 26 && z >= -6 && z <= 6 else game.Block.Air
					if b != want && !(y == 8 && x == 18 && z == 0) {r.stray += 1}
				}
			}
		}
	}
	r.hash = world_hash_here(g)
	return r, true
}

@(test)
test_fire_burns_out :: proc(t: ^testing.T) {
	a, ok1 := fire_run(t, "build/tmp/rules_fire_a")
	b, ok2 := fire_run(t, "build/tmp/rules_fire_b")
	if !testing.expect(t, ok1 && ok2) {return}
	fmt.println("fire:", a)
	testing.expect_value(t, a.fires, 0)
	testing.expect(t, a.planks <= 37, "less than half the planks burned")
	testing.expect_value(t, a.stray, 0)
	testing.expect_value(t, a.hash, b.hash)
	testing.expect_value(t, a.hash, FIRE_HASH)
}

// A creep that also wakes when a chunk loads beside it.
@(private = "file")
CREEP_LOADING :: `{"creep": {"blocks": ["sim_test:creep"], "trigger": "scheduled", "delay": 10, "wake": ["placed", "load"], "do": ["require self.potency > 0", {"repeat": 2, "do": ["pick t -1..1 -1..1 -1..1", "require t is voxiverse:stone", "set t sim_test:creep", "set t.potency self.potency - 1", "schedule t 10"]}]}}`

@(test)
test_rule_reads_unloaded :: proc(t: ^testing.T) {
	dir := "build/tmp/rules_edge"
	os.remove_all(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.extra_packs = make([]game.Pack_Source, 1, runtime.default_allocator())
	cfg.extra_packs[0] = game.sim_test_pack(
		creep = CREEP_LOADING,
		allocator = runtime.default_allocator(),
	)
	g, opened := grief_open(t, dir, cfg)
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	reg := grief_srv(g).registry
	potency, _ := game.registry_channel(reg, "sim_test:potency")
	creep := block_of(g, "sim_test:creep")
	here := game.chunk_of(g.f)
	a := game.Chunk_Pos{here.x + 4, here.y - 1, here.z}
	b := game.Chunk_Pos{here.x + 5, here.y - 1, here.z}
	if !testing.expect(t, chunks_get(&w.chunks, a) != nil, "chunk A is not loaded") {return}
	if !testing.expect(t, chunks_get(&w.chunks, b) == nil, "chunk B is loaded") {return}
	edge := game.chunk_origin(a) + {game.CHUNK_SIZE - 1, 8, 8}
	// Stone around the creep on A's side of the border.
	for y in i32(-3) ..= 3 {
		for z in i32(-3) ..= 3 {
			for x in i32(-6) ..= 0 {
				set_block(w, edge + {x, y, z}, .Stone, world_act(w, .Command))
			}
		}
	}
	set_block(w, edge, creep, world_act(w, .Command))
	set_channel(w, edge, potency, 15, world_act(w, .Command))
	run(g, 400)
	inward := 0
	for y in i32(-3) ..= 3 {
		for z in i32(-3) ..= 3 {
			for x in i32(-6) ..= 0 {
				if block_at_pos(w, edge + {x, y, z}) == creep {inward += 1}
			}
		}
	}
	testing.expect(t, inward > 1, "the creep did not spread inward")
	_, loaded := chunks_block(&w.chunks, edge + {1, 0, 0})
	testing.expect(t, !loaded, "the neighbour loaded by itself")
	// B arrives (made stone where the creep reaches): the creep goes on into it.
	testing.expect(t, request_chunk(w, b))
	run(g, 5)
	for y in i32(-3) ..= 3 {
		for z in i32(-3) ..= 3 {
			for x in i32(1) ..= 6 {
				set_block(w, edge + {x, y, z}, .Stone, world_act(w, .Command))
			}
		}
	}
	run(g, 400)
	beyond := 0
	for y in i32(-3) ..= 3 {
		for z in i32(-3) ..= 3 {
			for x in i32(1) ..= 6 {
				if block_at_pos(w, edge + {x, y, z}) == creep {beyond += 1}
			}
		}
	}
	testing.expect(t, beyond > 0, "the creep did not go on into the chunk that loaded")
}

@(test)
test_rules_hot_reload :: proc(t: ^testing.T) {
	dir := "build/tmp/rules_reload"
	os.remove_all(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.extra_packs = make([]game.Pack_Source, 1, runtime.default_allocator())
	cfg.extra_packs[0] = game.sim_test_pack(allocator = runtime.default_allocator())
	g, opened := grief_open(t, dir, cfg)
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	srv := grief_srv(g)
	reg := srv.registry
	creep := block_of(g, "sim_test:creep")
	testing.expect_value(t, reg.sim.delay[creep], u16(10))
	// A creep waits in the queue; the rule's delay changes 10 -> 40 and the pack reloads.
	p := at(g, 20, 0, 0)
	cmd(g, "fill %s stone", box(g, {18, -2, -2}, {22, 2, 2}))
	set_block(w, p, creep, world_act(w, .Command))
	waiting := w.updates.count
	testing.expect(t, waiting > 0)
	slower, _ := strings.replace(
		game.SIM_TEST_CREEP,
		`"delay": 10`,
		`"delay": 40`,
		1,
		runtime.default_allocator(),
	)
	srv.config.extra_packs[0] = game.sim_test_pack(
		creep = slower,
		allocator = runtime.default_allocator(),
	)
	packs_reload_request(srv)
	run(g, 3)
	testing.expect_value(t, srv.reload.swaps, 1)
	testing.expect(t, srv.registry == reg, "the registry moved")
	testing.expect_value(t, reg.sim.delay[creep], u16(40))
	// Next runs use it: a creep placed now waits 40 ticks.
	q := at(g, 21, 0, 0)
	set_block(w, q, creep, world_act(w, .Command))
	due := u64(0)
	for i in 0 ..< w.updates.count {
		if w.updates.heap[i].pos == q {due = w.updates.heap[i].due}
	}
	testing.expect_value(t, due, srv.tick + 40)
}

@(test)
test_ten_thousand_rule_cells :: proc(t: ^testing.T) {
	r, ok := budget_rules()
	if !testing.expect(t, ok, "the rules scene did not run") {return}
	testing.expectf(t, r.most >= 10_000, "only %d cells waiting at the peak", r.most)
	testing.expect(t, r.runs > 10_000, "the rules barely ran")
}
