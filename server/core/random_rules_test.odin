package core

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"

import "common:base"
import "common:game"

// The reference for the differential test (M49e): the random tick of grass, farmland and
// wheat as it was written in Odin before it became data (assets/packs/voxiverse/data/sim/
// growth.json). The only copy of that code; test_random_rules_match_code holds the rules to it.

// reference_random_tick runs the random tick of block b at p.
reference_random_tick :: proc(w: ^World, p: game.Block_Pos, b: game.Block) {
	r := &w.tick_rng
	up := p + {0, 1, 0}
	above, loaded := chunks_block(&w.chunks, up)
	if !loaded {return}
	switch {
	case b == .Grass:
		if game.block_opaque(&w.server.registry.blocks, above) {
			set_block(w, p, .Dirt, world_act(w, .Random_Tick)) // buried
			return
		}
		// Spread: a few tries at dirt in the 3 x 5 x 3 around (lit, nothing solid on it).
		for _ in 0 ..< 4 {
			t :=
				p +
				{
						i32(base.rng_int_max(r, 3)) - 1,
						i32(base.rng_int_max(r, 5)) - 3,
						i32(base.rng_int_max(r, 3)) - 1,
					}
			tb, t_loaded := chunks_block(&w.chunks, t)
			if !t_loaded || tb != .Dirt {continue}
			over, over_loaded := chunks_block(&w.chunks, t + {0, 1, 0})
			if !over_loaded ||
			   game.block_opaque(&w.server.registry.blocks, over) ||
			   light_above(w, t + {0, 1, 0}) < 9 {continue}
			set_block(w, t, .Grass, world_act(w, .Random_Tick))
		}
	case game.block_is_farmland(b):
		wet := reference_farmland_wet(w, p)
		switch {
		case wet && b == .Farmland:
			set_block(w, p, .Farmland_Moist, world_act(w, .Random_Tick))
		case !wet && b == .Farmland_Moist:
			set_block(w, p, .Farmland, world_act(w, .Random_Tick))
		case !wet && b == .Farmland:
			// Dry and nothing planted: back to dirt.
			if _, planted := game.wheat_stage(above);
			   !planted {set_block(w, p, .Dirt, world_act(w, .Random_Tick))}
		}
	case:
		stage, _ := game.wheat_stage(b)
		if stage >= game.WHEAT_STAGES - 1 {return}
		below, _ := chunks_block(&w.chunks, p + {0, -1, 0})
		chance := i32(3) if below == .Farmland_Moist else 6
		if i32(base.rng_int_max(r, int(chance))) ==
		   0 {set_block(w, p, game.wheat_block(stage + 1), world_act(w, .Random_Tick))}
	}
}

// reference_farmland_wet: water within 4 blocks across, on the farmland's level or the
// one above.
reference_farmland_wet :: proc(w: ^World, p: game.Block_Pos) -> bool {
	for y in i32(0) ..= 1 {
		for z in i32(-4) ..= 4 {
			for x in i32(-4) ..= 4 {
				b, _ := chunks_block(&w.chunks, p + {x, y, z})
				if _, water := game.water_level(b); water {return true}
			}
		}
	}
	return false
}


RANDOM_BOX :: 17 // the neighbourhood: a 17 x 17 x 17 box
RANDOM_CASES :: 20000
RANDOM_PER_BOX :: 400 // cells ticked in one neighbourhood

@(private = "file")
palette :: proc() -> [dynamic]game.Block {
	p := make([dynamic]game.Block, context.temp_allocator)
	append(&p, game.Block.Air, .Stone, .Dirt, .Grass, .Farmland, .Farmland_Moist, .Glass, .Lamp)
	for s in 0 ..< game.WHEAT_STAGES {append(&p, game.wheat_block(s))}
	for l in i32(0) ..= game.WATER_FALLING_LEVEL {append(&p, game.water_block(l))}
	for b in game.Block {append(&p, b)} 	// (and every other block once)
	return p
}

// Random neighbourhoods; in each, cells ticked by the reference and then by the rules from
// equal RNG states, the world put back between: the blocks changed (position order) and
// the RNG state after must be equal.
@(test)
test_random_rules_match_code :: proc(t: ^testing.T) {
	dir := "build/tmp/random_rules_match"
	os.remove_all(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	if !ok {grief_close(g); return}
	defer grief_close(g)
	w := grief_world(g)
	here := game.chunk_of(g.f)
	edge_chunk := game.Chunk_Pos{here.x + 2, here.y, here.z}
	edge := game.chunk_origin(edge_chunk)
	c := chunks_get(&w.chunks, edge_chunk)
	if !testing.expect(t, c != nil && c.state == .Ready) {return}
	keep_edits(w, c)
	chunks_unload(&w.chunks, edge_chunk)

	pal := palette()
	gen := base.rng_make(49)
	N :: RANDOM_BOX
	H :: N / 2
	W :: 9
	before := make([]game.Block, W * W * W)
	after := make([]game.Block, W * W * W)
	defer delete(before)
	defer delete(after)
	// snapshot: the 9 x 9 x 9 around p (what a tick can change), x fastest.
	snapshot :: proc(w: ^World, p: game.Block_Pos, into: []game.Block) {
		i := 0
		for y in i32(-4) ..= 4 {
			for z in i32(-4) ..= 4 {
				for x in i32(-4) ..= 4 {
					into[i], _ = chunks_block(&w.chunks, p + {x, y, z})
					i += 1
				}
			}
		}
	}
	act := world_act(w, .Command)
	mismatches := 0
	cases := 0
	changing := 0 // cases in which something changed
	for cases < RANDOM_CASES && mismatches < 5 {
		// Every fourth neighbourhood sits on the edge of an unloaded chunk.
		centre := g.f + {0, 2, 0}
		if base.rng_int_max(&gen, 4) == 0 {
			centre = edge + {-1 - i32(base.rng_int_max(&gen, 3)), 2, 4}
		} else {
			centre += {i32(base.rng_int_max(&gen, 5)) - 2, 0, i32(base.rng_int_max(&gen, 5)) - 2}
		}
		o := centre - {H, H, H}
		// Mostly one kind of block with a few others, so that every rule's case is met.
		main := pal[base.rng_int_max(&gen, len(pal))]
		for y in i32(0) ..< N {
			for z in i32(0) ..< N {
				for x in i32(0) ..< N {
					b := main
					if base.rng_int_max(&gen, 3) == 0 {b = pal[base.rng_int_max(&gen, len(pal))]}
					if y < H - 1 && base.rng_int_max(&gen, 4) != 0 {b = .Dirt} 	// (ground below: spreading has targets)
					set_block(w, o + {x, y, z}, b, act)
				}
			}
		}
		ran := 0
		for _ in 0 ..< RANDOM_PER_BOX * 8 {
			if ran >= RANDOM_PER_BOX {break}
			p :=
				centre +
				{
						i32(base.rng_int_max(&gen, 9)) - 4,
						i32(base.rng_int_max(&gen, 9)) - 4,
						i32(base.rng_int_max(&gen, 9)) - 4,
					}
			b, loaded := chunks_block(&w.chunks, p)
			if !loaded || !has_random_tick(w, b) {continue}
			cases += 1
			ran += 1
			snapshot(w, p, before)
			seed := base.rng_u64(&gen)
			// The reference.
			w.tick_rng = base.rng_make(seed)
			world_act(w, .Random_Tick) // (the tick's action is opened by its first write: open it, or the first case alone differs)
			head0, action0 := w.journal.head, w.journal.next_action
			reference_random_tick(w, p, b)
			head_ref, action_ref := w.journal.head - head0, w.journal.next_action - action0
			rng_ref := w.tick_rng
			snapshot(w, p, after)
			changed_ref := make([dynamic]string, context.temp_allocator)
			for i in 0 ..< W * W * W {
				if before[i] != after[i] {
					append(&changed_ref, fmt.tprintf("%d:%v->%v", i, before[i], after[i]))
				}
			}
			if len(changed_ref) > 0 {changing += 1}
			// Put the world back, then the rules.
			for i in 0 ..< W * W * W {
				if before[i] != after[i] {
					x, y, z := i % W - 4, i / (W * W) - 4, (i / W) % W - 4
					set_block(w, p + {i32(x), i32(y), i32(z)}, before[i], act)
				}
			}
			w.tick_rng = base.rng_make(seed)
			head0, action0 = w.journal.head, w.journal.next_action
			random_tick(w, p, b)
			journal_same :=
				head_ref == w.journal.head - head0 && action_ref == w.journal.next_action - action0
			rng_new := w.tick_rng
			snapshot(w, p, after)
			changed_new := make([dynamic]string, context.temp_allocator)
			for i in 0 ..< W * W * W {
				if before[i] != after[i] {
					append(&changed_new, fmt.tprintf("%d:%v->%v", i, before[i], after[i]))
				}
			}
			same := journal_same && rng_ref == rng_new && len(changed_ref) == len(changed_new)
			for i in 0 ..< min(len(changed_ref), len(changed_new)) {
				if changed_ref[i] != changed_new[i] {same = false}
			}
			if !same {
				mismatches += 1
				testing.expectf(
					t,
					false,
					"case seed %d, cell %v, block %v: reference wrote %v, rules wrote %v (rng equal: %v, journal equal: %v)",
					seed,
					p,
					b,
					changed_ref[:],
					changed_new[:],
					rng_ref == rng_new,
					journal_same,
				)
			}
			// The world as it was, for the next cell.
			for i in 0 ..< W * W * W {
				if before[i] != after[i] {
					x, y, z := i % W - 4, i / (W * W) - 4, (i / W) % W - 4
					set_block(w, p + {i32(x), i32(y), i32(z)}, before[i], act)
				}
			}
			if cases >= RANDOM_CASES {break}
		}
	}
	testing.expectf(
		t,
		mismatches > 0 || changing > cases / 10,
		"only %d of %d cases changed anything",
		changing,
		cases,
	)
	testing.expectf(t, cases >= RANDOM_CASES || mismatches > 0, "only %d cases ran", cases)
}

// random_ticks.odin names no block: the rules are data.
@(test)
test_random_ticks_no_block_names :: proc(t: ^testing.T) {
	src := #load("random_ticks.odin", string)
	for name in reflect.enum_field_names(game.Block) {
		needle := fmt.tprintf(".%s", name)
		rest := src
		for {
			i := strings.index(rest, needle)
			if i < 0 {break}
			after := rest[i + len(needle):]
			if len(after) == 0 ||
			   !(after[0] == '_' ||
					   (after[0] >= 'a' && after[0] <= 'z') ||
					   (after[0] >= 'A' && after[0] <= 'Z') ||
					   (after[0] >= '0' && after[0] <= '9')) {
				testing.expectf(t, false, "random_ticks.odin names the block %s", needle)
			}
			rest = after
		}
	}
	for word in ([]string{"wheat_", "water_level"}) {
		testing.expectf(t, !strings.contains(src, word), "random_ticks.odin mentions %q", word)
	}
}

MOSS_RULE :: `{"moss": {"blocks": ["voxiverse:cobblestone"], "trigger": "random", "do": [
	"require any box(-1..1, -1..1, -1..1) is $voxiverse:water", "chance 4", "set self voxiverse:stone_bricks"]}}`

// A pack's random rule, no engine code: cobblestone beside water turns to stone bricks.
@(test)
test_pack_random_rule :: proc(t: ^testing.T) {
	hashes: [2]u64
	for run in 0 ..< 2 {
		dir := fmt.tprintf("build/tmp/random_rules_pack%d", run)
		os.remove_all(dir)
		defer os.remove_all(dir)
		cfg := grief_config(dir)
		cfg.extra_packs = make([]game.Pack_Source, 1, runtime.default_allocator())
		cfg.extra_packs[0] = game.sim_test_pack(
			{{"data/sim/moss.json", transmute([]u8)string(MOSS_RULE)}},
			allocator = runtime.default_allocator(),
		)
		g, ok := grief_open(t, dir, cfg)
		if !ok {grief_close(g); return}
		w := grief_world(g)
		act := world_act(w, .Command)
		o := g.f + {0, 20, 0}
		for x in i32(0) ..< 16 {
			for z in i32(0) ..< 16 {
				set_block(w, o + {x, 0, z}, .Cobblestone, act)
				set_block(w, o + {x, 1, z}, .Air, act)
			}
		}
		for x in i32(0) ..< 16 {set_block(w, o + {x, 1, 0}, .Water, act)}
		w.rules.random_tick_speed = 300
		for _ in 0 ..< 600 {random_ticks(w)}
		bricks := 0
		for x in i32(0) ..< 16 {
			for z in i32(0) ..< 16 {
				b, _ := chunks_block(&w.chunks, o + {x, 0, z})
				if b == .Stone_Bricks {
					bricks += 1
					testing.expectf(t, z <= 1, "bricks at %d,%d, away from the water", x, z)
				}
			}
		}
		testing.expect(t, bricks > 0, "no cobblestone turned to bricks")
		hashes[run] = world_hash(grief_srv(g))
		grief_close(g)
	}
	testing.expect_value(t, hashes[0], hashes[1])
}
