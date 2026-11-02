package core

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

import "common:base"
import "common:game"

// The interpreter, statement by statement. The rules are `random` rules over
// sim_test:creep (nothing runs them but these tests, by calling rule_run), written into a
// pack file; the world is the stepped test world.

@(private = "file")
Probe :: struct {
	name: string,
	text: string, // the rule's do items
}

@(private = "file")
probes :: proc() -> []Probe {
	@(static) list := [?]Probe {
		{"require", `"require self is voxiverse:stone", "set above voxiverse:dirt"`},
		{"chance", `"chance 5"`},
		{"pick_one", `"pick t 0..0 0..0 0..0", "pick u 0..0 0..0 0..0"`},
		{
			"stop_in_repeat",
			`{"repeat": 3, "do": ["set above voxiverse:dirt", "stop"]}, "set below voxiverse:dirt"`,
		},
		{
			"repeat_round",
			`{"repeat": 3, "do": ["require below is voxiverse:air", "set below voxiverse:dirt"]}, "set north voxiverse:dirt"`,
		},
		{
			"seen_by_next",
			`"set above voxiverse:dirt", "require above is voxiverse:dirt", "set north voxiverse:dirt"`,
		},
		{"same_value", `"set self voxiverse:stone"`},
		{"clamp_high", `"set above.potency 99"`},
		{"clamp_low", `"set above.potency 0 - 5"`},
		{"list_clamp", `"set above $voxiverse:water[9]"`},
		{"prop_clamp", `"set above[half] 9"`},
		{
			"short_and",
			`"require self is voxiverse:stone and count box(-1..1, -1..1, -1..1) is @opaque > 0", "set above voxiverse:dirt"`,
		},
		{
			"short_or",
			`"require self is voxiverse:air or count box(-1..1, -1..1, -1..1) is @opaque > 0", "set above voxiverse:dirt"`,
		},
		{"index", `"set above.potency index($voxiverse:water, self) + 1"`},
		{"cmp", `"require self.potency + 2 >= 3 - 1", "set above voxiverse:dirt"`},
	}
	return list[:]
}

@(private = "file")
Unloaded_Case :: struct {
	cond: string,
	want: u16, // the witness: 1 if the rule's condition is true
}

@(private = "file", rodata)
UNLOADED := [?]Unloaded_Case {
	{"east is voxiverse:air", 0},
	{"east not voxiverse:stone", 0},
	{"loaded east", 0},
	{"east.potency == 0", 0},
	{"east.potency != 3", 0},
	{"east[half] == 0", 0},
	{"index($voxiverse:water, east) == 0 - 1", 1},
	{"any box(1..2, 0..0, 0..0) is voxiverse:air", 0},
	{"count box(1..2, 0..0, 0..0) is voxiverse:air == 0", 1},
}

@(private = "file")
interp_pack :: proc() -> game.Pack_Source {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "{")
	for p, i in probes() {
		if i > 0 {strings.write_string(&sb, ",")}
		fmt.sbprintf(
			&sb,
			`"%s": {{"blocks": ["sim_test:creep"], "trigger": "random", "do": [%s]}}`,
			p.name,
			p.text,
		)
	}
	for cs, i in UNLOADED {
		fmt.sbprintf(
			&sb,
			`,"u%d": {{"blocks": ["sim_test:creep"], "trigger": "random", "do": ["require %s", "set self.potency 1"]}}`,
			i,
			cs.cond,
		)
	}
	strings.write_string(
		&sb,
		`,"unloaded_sets": {"blocks": ["sim_test:creep"], "trigger": "random", "do": ["set east voxiverse:dirt", "set east.potency 3", "schedule east 5"]}}`,
	)
	text := strings.to_string(sb)
	return game.sim_test_pack(
		{{"data/sim/probes.json", transmute([]u8)text}},
		allocator = runtime.default_allocator(),
	)
}

@(private = "file")
Rig :: struct {
	g:       ^Grief,
	w:       ^World,
	o:       game.Block_Pos, // the cell the rules run on
	potency: int,
}

@(private = "file")
rig_open :: proc(t: ^testing.T, dir: string) -> (r: Rig, ok: bool) {
	os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.extra_packs = make([]game.Pack_Source, 1, runtime.default_allocator())
	cfg.extra_packs[0] = interp_pack()
	g, opened := grief_open(t, dir, cfg)
	if !opened {grief_close(g); return}
	r.g, r.w = g, grief_world(g)
	r.potency, _ = game.registry_channel(grief_srv(g).registry, "sim_test:potency")
	r.o = at(g, 12, 0, 0)
	return r, true
}

@(private = "file")
rig_close :: proc(r: ^Rig, dir: string) {
	grief_close(r.g)
	os.remove_all(dir)
}

@(private = "file")
rule_named :: proc(r: ^Rig, name: string) -> ^game.Rule {
	reg := grief_srv(r.g).registry
	at, found := reg.ids[.Sim_Rule][fmt.tprintf("sim_test:%s", name)]
	assert(found, name)
	return &reg.sim.rules[at]
}

// reset: a 5 x 5 x 5 of air around the rule's cell, stone below it (y - 1 and under), and `self` as given.
@(private = "file")
reset :: proc(r: ^Rig, self: game.Block) {
	cmd(r.g, "fill %s air", box(r.g, {10, -3, -2}, {14, 3, 2}))
	set_block(r.w, r.o, self, world_act(r.w, .Command))
}

@(private = "file")
run_rule :: proc(r: ^Rig, name: string) -> Rule_Result {
	rule := rule_named(r, name)
	res := rule_run(r.w, r.o, rule, world_act(r.w, .Rule))
	assert(res.reads <= rule.program.cost, name)
	return res
}

@(test)
test_rule_statements :: proc(t: ^testing.T) {
	dir := "build/tmp/interp_statements"
	r, ok := rig_open(t, dir)
	if !ok {return}
	defer rig_close(&r, dir)
	w := r.w
	dirt: game.Block = .Dirt
	above, below, north := r.o + {0, 1, 0}, r.o + {0, -1, 0}, r.o + {0, 0, -1}

	// require ends the rule.
	reset(&r, .Air)
	run_rule(&r, "require")
	testing.expect_value(t, block_at_pos(w, above), game.Block.Air)
	reset(&r, .Stone)
	run_rule(&r, "require")
	testing.expect_value(t, block_at_pos(w, above), dirt)

	// chance draws exactly rng_int_max(n).
	reset(&r, .Air)
	copy := w.tick_rng
	res := run_rule(&r, "chance")
	base.rng_int_max(&copy, 5)
	testing.expect_value(t, res.draws, i32(1))
	testing.expect_value(t, w.tick_rng, copy)

	// a pick of one value draws nothing.
	before := w.tick_rng
	res = run_rule(&r, "pick_one")
	testing.expect_value(t, res.draws, i32(0))
	testing.expect_value(t, w.tick_rng, before)

	// stop inside a repeat ends the rule.
	reset(&r, .Air)
	run_rule(&r, "stop_in_repeat")
	testing.expect_value(t, block_at_pos(w, above), dirt)
	testing.expect_value(t, block_at_pos(w, below), game.Block.Air)

	// a failed require inside a repeat ends the round, not the rule: below is air at the
	// first round, dirt after the set, so the later rounds end at their require; north is set.
	reset(&r, .Air)
	run_rule(&r, "repeat_round")
	testing.expect_value(t, block_at_pos(w, below), dirt)
	testing.expect_value(t, block_at_pos(w, north), dirt)

	// writes are seen by the next statement.
	reset(&r, .Air)
	run_rule(&r, "seen_by_next")
	testing.expect_value(t, block_at_pos(w, north), dirt)

	// a set to the cell's own value is no change.
	reset(&r, .Stone)
	res = run_rule(&r, "same_value")
	testing.expect_value(t, res.writes, i32(0))
	testing.expect(t, !res.changed_self)

	// channels clamp to 0..max (4 bits: 15).
	reset(&r, .Air)
	set_block(w, above, .Stone, world_act(w, .Command))
	run_rule(&r, "clamp_high")
	v, _ := chunks_channel(w, above, r.potency)
	testing.expect_value(t, v, u16(15))
	run_rule(&r, "clamp_low")
	v, _ = chunks_channel(w, above, r.potency)
	testing.expect_value(t, v, u16(0))

	// a list index past the end gives the last block.
	reset(&r, .Air)
	run_rule(&r, "list_clamp")
	reg := grief_srv(r.g).registry
	at: int
	{
		context.allocator = context.temp_allocator // (rule_list_of formats an id)
		at, _ = game.rule_list_of(reg, "voxiverse:water")
	}
	water := reg.sim.lists[at].blocks
	testing.expect_value(t, block_at_pos(w, above), water[len(water) - 1])

	// a property clamps to its last value.
	reset(&r, .Air)
	stairs, _ := game.registry_block(reg, "voxiverse:planks_stairs[half=bottom]")
	set_block(w, above, stairs, world_act(w, .Command))
	run_rule(&r, "prop_clamp")
	top, _ := game.registry_block(reg, "voxiverse:planks_stairs[half=top]")
	got := block_at_pos(w, above)
	testing.expect(
		t,
		game.state_text(reg, got) == game.state_text(reg, top),
		"the half did not clamp to top",
	)

	// and / or short-circuit: the read counts show it.
	reset(&r, .Air)
	res = run_rule(&r, "short_and")
	testing.expect_value(t, res.reads, i32(1)) // (self is stone: false, the box is never read)
	reset(&r, .Stone)
	res = run_rule(&r, "short_and")
	testing.expect_value(t, res.reads, i32(1 + 27))
	reset(&r, .Air)
	res = run_rule(&r, "short_or")
	testing.expect_value(t, res.reads, i32(1)) // (self is air: true, the box is never read)

	// index: -1 for a block not in the list, so the channel is set to 0.
	reset(&r, .Air)
	set_block(w, above, .Stone, world_act(w, .Command))
	set_channel(w, above, r.potency, 7, world_act(w, .Command))
	run_rule(&r, "index")
	v, _ = chunks_channel(w, above, r.potency)
	testing.expect_value(t, v, u16(0))

	// arithmetic and comparison: potency 1 + 2 >= 3 - 1.
	reset(&r, .Stone)
	set_channel(w, r.o, r.potency, 1, world_act(w, .Command))
	run_rule(&r, "cmp")
	testing.expect_value(t, block_at_pos(w, above), dirt)
}

@(test)
test_rule_unloaded :: proc(t: ^testing.T) {
	dir := "build/tmp/interp_unloaded"
	r, ok := rig_open(t, dir)
	if !ok {return}
	defer rig_close(&r, dir)
	w := r.w
	// The cell at the edge of an unloaded chunk: east of it is not loaded.
	here := game.chunk_of(r.g.f)
	edge_chunk := game.Chunk_Pos{here.x + 2, here.y, here.z}
	edge := game.chunk_origin(edge_chunk) + {0, 0, 0}
	c := chunks_get(&w.chunks, edge_chunk)
	if !testing.expect(t, c != nil && c.state == .Ready) {return}
	keep_edits(w, c)
	chunks_unload(&w.chunks, edge_chunk)
	_, loaded := chunks_block(&w.chunks, edge)
	if !testing.expect(t, !loaded, "the chunk is still loaded") {return}
	r.o = edge - {1, 0, 0}
	// Each condition about the unloaded east cell, then a witness write on self.
	for cs, i in UNLOADED {
		set_channel(w, r.o, r.potency, 0, world_act(w, .Command))
		rule_run(w, r.o, rule_named(&r, fmt.tprintf("u%d", i)), world_act(w, .Rule))
		v, _ := chunks_channel(w, r.o, r.potency)
		testing.expectf(t, v == cs.want, "%q: witness %d, want %d", cs.cond, v, cs.want)
	}
	// set and schedule on an unloaded cell do nothing (and do not crash).
	before := w.updates.count
	res := rule_run(w, r.o, rule_named(&r, "unloaded_sets"), world_act(w, .Rule))
	testing.expect_value(t, res.writes, i32(0))
	testing.expect_value(t, w.updates.count, before)
}

@(test)
test_rule_run_allocates_nothing :: proc(t: ^testing.T) {
	dir := "build/tmp/interp_alloc"
	r, ok := rig_open(t, dir)
	if !ok {return}
	defer rig_close(&r, dir)
	reset(&r, .Stone)
	// Counting allocator over the interpreter: rules that read, draw, compare and write
	// the value a cell already has (a write that changes a block is the engine's own set_block,
	// which has its journal and its change set to grow).
	counter := Counting{}
	for name in ([]string{"chance", "pick_one", "same_value", "short_and", "short_or", "cmp", "index"}) {
		rule := rule_named(&r, name)
		act := world_act(r.w, .Rule)
		counter.count = 0
		context.allocator = counting_allocator(&counter)
		context.temp_allocator = counting_allocator(&counter)
		for _ in 0 ..< 10000 {
			// (the writes of "cmp" and "index" happen once; the rest are reads)
			rule_run(r.w, r.o, rule, act)
		}
		context.allocator = runtime.default_allocator()
		testing.expectf(t, counter.count == 0, "%s: %d allocations", name, counter.count)
	}
}

@(private = "file")
Counting :: struct {
	count: int,
}

@(private = "file")
counting_allocator :: proc(c: ^Counting) -> runtime.Allocator {
	return {
		procedure = proc(
			data: rawptr,
			mode: runtime.Allocator_Mode,
			size, alignment: int,
			old: rawptr,
			old_size: int,
			loc := #caller_location,
		) -> (
			[]byte,
			runtime.Allocator_Error,
		) {
			c := (^Counting)(data)
			#partial switch mode {
			case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
				c.count += 1
			}
			return nil, .Out_Of_Memory
		},
		data = c,
	}
}

_ :: mem

// test_rule_reads_within_cost: rules written by the fuzz generator (seed 85) that compile,
// each run at 20 places of a random 25 x 25 x 25 neighbourhood (random blocks and channels):
// the reads never exceed the rule's static cost.
@(test)
test_rule_reads_within_cost :: proc(t: ^testing.T) {
	dir := "build/tmp/interp_reads"
	os.remove_all(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.extra_packs = make([]game.Pack_Source, 1, runtime.default_allocator())
	cfg.extra_packs[0] = game.sim_test_pack(
		with_rules = false,
		allocator = runtime.default_allocator(),
	)
	g, opened := grief_open(t, dir, cfg)
	defer grief_close(g)
	if !opened {return}
	w := grief_world(g)
	reg := grief_srv(g).registry
	potency, _ := game.registry_channel(reg, "sim_test:potency")
	palette: [dynamic]game.Block
	defer delete(palette)
	for name in ([]string{"voxiverse:air", "voxiverse:stone", "voxiverse:planks", "voxiverse:log", "voxiverse:leaves", "voxiverse:wool", "voxiverse:water", "sim_test:creep", "sim_test:fire", "voxiverse:planks_stairs[half=top]"}) {
		b, found := game.registry_block(reg, name)
		assert(found, name)
		append(&palette, b)
	}
	rng := base.rng_make(85)
	act := world_act(w, .Command)
	lo := at(g, 8, -12, -12)
	for y in i32(0) ..< 25 {
		for z in i32(0) ..< 25 {
			for x in i32(0) ..< 25 {
				p := lo + {x, y, z}
				set_block(w, p, palette[base.rng_int_max(&rng, len(palette))], act)
				if base.rng_int_max(&rng, 3) ==
				   0 {set_channel(w, p, potency, u16(base.rng_int_max(&rng, 16)), act)}
			}
		}
	}
	centre := lo + {12, 12, 12}
	compiled, tried := 0, 0
	for compiled < 60 && tried < 600 {
		tried += 1
		data := make([dynamic]u8, context.temp_allocator)
		game.fuzz_generate_sim_rules(&rng, &data)
		sources := []game.Pack_Source {
			game.base_pack_source(context.temp_allocator),
			game.sim_test_pack(
				{{"data/sim/gen.json", data[:]}},
				with_rules = false,
				allocator = context.temp_allocator,
			),
		}
		rreg, _ := game.registry_build(sources, .Server, runtime.default_allocator())
		if rreg == nil {continue}
		defer game.registry_destroy(rreg)
		id, found := rreg.ids[.Sim_Rule]["sim_test:r"]
		if !found {continue}
		rule := &rreg.sim.rules[id]
		compiled += 1
		for _ in 0 ..< 20 {
			p :=
				centre +
				{
						i32(base.rng_int_max(&rng, 9)) - 4,
						i32(base.rng_int_max(&rng, 9)) - 4,
						i32(base.rng_int_max(&rng, 9)) - 4,
					}
			res := rule_run(w, p, rule, world_act(w, .Rule))
			if res.reads > rule.program.cost {
				testing.expectf(
					t,
					false,
					"rule read %d cells, cost %d:\n%s",
					res.reads,
					rule.program.cost,
					string(data[:]),
				)
				return
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, compiled >= 20, "only %d of %d generated rules compiled", compiled, tried)
}
