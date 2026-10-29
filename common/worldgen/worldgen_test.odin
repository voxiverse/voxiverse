package worldgen

import "core:math"
import "core:slice"
import "core:testing"

import "../../base"
import "../game"

@(test)
test_generate_is_deterministic :: proc(t: ^testing.T) {
	g := generator_make(.Classic, 1234, test_reg())
	one, two := generator_make(.Classic, 1, test_reg()), generator_make(.Classic, 2, test_reg())
	a, b := new(game.Block_Array), new(game.Block_Array)
	defer free(a)
	defer free(b)
	for c in ([]game.Chunk_Pos{{0, 0, 0}, {-3, -1, 7}, {100, -2, -50}}) {
		generate(&g, c, a)
		generate(&g, c, b)
		testing.expect(t, a^ == b^)
	}
	// Another seed gives another world.
	differs := false
	for x in i32(0) ..< 8 {
		if column_top(&one, x * 37, 0) != column_top(&two, x * 37, 0) {differs = true}
	}
	testing.expect(t, differs)
}

@(test)
test_generate_terrain_shape :: proc(t: ^testing.T) {
	g := generator_make(.Classic, 42, test_reg())
	arr := new(game.Block_Array)
	defer free(arr)

	// Above every column: one uniform air chunk.
	uniform, ok := generate(&g, {0, 50, 0}, arr)
	testing.expect(t, ok && uniform == .Air)

	// Each column's top block (where it falls in this chunk) is ground and
	// the block above it is air.
	for cx in i32(-2) ..< 2 {
		for cz in i32(-2) ..< 2 {
			h := column_top(&g, cx * 16, cz * 16)
			c := game.chunk_of({cx * 16, h, cz * 16})
			generate(&g, c, arr)
			top := arr[game.local_index(game.local_of({cx * 16, h, cz * 16}))]
			testing.expect(
				t,
				top == .Grass || top == .Sand || top == .Gravel,
				"column top is ground",
			)
			above := game.Block_Pos{cx * 16, h + 1, cz * 16}
			if game.chunk_of(above) == c {
				testing.expect_value(
					t,
					arr[game.local_index(game.local_of(above))],
					game.Block.Air,
				)
			}
		}
	}

	// Deep underground there are caves: some air, mostly stone.
	air := 0
	for cx in i32(0) ..< 4 {
		_, _ = generate(&g, {cx, -6, 0}, arr)
		for b in arr {if b == .Air {air += 1}}
	}
	testing.expect(
		t,
		air > 0 && air < 4 * game.CHUNK_VOLUME / 4,
		"caves carve some but not most stone",
	)

	// The floor: bedrock everywhere at the bottom layer, never carved.
	for cx in i32(-3) ..< 3 {
		generate(&g, {cx, game.CHUNK_MIN_Y, cx * 2}, arr)
		for z in i32(0) ..< 16 {
			for x in i32(0) ..< 16 {
				testing.expect_value(t, arr[game.local_index({x, 0, z})], game.Block.Bedrock)
			}
		}
	}
}

// Earth: the same chunk twice is the same; each column's natural top is
// exactly its highest block that shades as generated (overhangs, trees,
// water included), for columns across every kind of land near the spawn; the
// spawn is on dry land.
@(test)
test_earth :: proc(t: ^testing.T) {
	g := generator_make(.Earth, 24301, test_reg())
	a, b := new(game.Block_Array), new(game.Block_Array)
	defer free(a)
	defer free(b)
	for c in ([]game.Chunk_Pos{{0, 0, 0}, {-3, -1, 7}, {40, 2, -50}}) {
		generate(&g, c, a)
		generate(&g, c, b)
		testing.expect(t, a^ == b^)
	}

	// Chunk columns spread over a few kilometres: mountains, forests, sea.
	seen: [Biome]bool
	checked := 0
	for n in i32(0) ..< 24 {
		column := [2]i32{(n % 6) * 23 - 60, (n / 6) * 31 - 50}
		tops: Tops
		column_tops(&g, column, &tops)
		lo, hi := max(i32), min(i32)
		for top in tops {lo, hi = min(lo, top), max(hi, top)}
		// The highest opaque block of each column, from the chunks around
		// the tops.
		found: [COLUMN_AREA]i32
		for &f in found {f = game.WORLD_MIN_Y}
		for cy := game.chunk_of({0, hi + 1, 0}).y; cy >= game.chunk_of({0, lo, 0}).y; cy -= 1 {
			uniform, is_uniform := generate(&g, {column.x, cy, column.y}, a)
			for z in i32(0) ..< game.CHUNK_SIZE {
				for x in i32(0) ..< game.CHUNK_SIZE {
					i := x + z * game.CHUNK_SIZE
					if found[i] != game.WORLD_MIN_Y {continue}
					for y := i32(game.CHUNK_SIZE - 1); y >= 0; y -= 1 {
						bl := uniform if is_uniform else a[game.local_index({x, y, z})]
						if game.block_shades(test_blocks(), bl) {
							found[i] = cy * game.CHUNK_SIZE + y
							break
						}
					}
				}
			}
		}
		for i in 0 ..< COLUMN_AREA {
			if !testing.expectf(
				t,
				found[i] == tops[i],
				"column %v+%d: top %d, generated %d",
				column,
				i,
				tops[i],
				found[i],
			) {return}
		}
		origin := column * game.CHUNK_SIZE
		seen[earth_biome(&g, origin.x + 8, origin.y + 8)] = true
		checked += 1
	}
	kinds := 0
	for s in seen {if s {kinds += 1}}
	testing.expectf(t, kinds >= 4, "only %d biomes among the columns checked", kinds)

	spawn := spawn_point(&g)
	below := i32(spawn.y) - 2
	testing.expect(t, below > g.params.sea_level, "the spawn is under the sea")
}

@(test)
test_params_table :: proc(t: ^testing.T) {
	testing.expect(t, base.var_table_check(params_table()))
	p := PARAMS_DEFAULTS
	testing.expect_value(
		t,
		base.var_set(params_table(), &p, "worldgen.sea_level", "12"),
		base.Var_Error.None,
	)
	testing.expect_value(t, p.sea_level, 12)
}

// The same seed makes the same world on every OS: hashes of chunks and
// column tops across a few kilometres, for two seeds, as recorded on
// Linux. CI runs this on Windows, Linux and macOS: a different number
// means a platform rounds differently (a fused multiply-add, a libm
// call) and its worlds would not match a server's.
@(test)
test_earth_same_everywhere :: proc(t: ^testing.T) {
	GOLDEN :: [2]u64{0x23f2_d1b1_db29_8716, 0x150f_68fb_7379_597e}
	// Without blending, as worlds made before it (their saved chunks must
	// still meet new ones).
	GOLDEN_UNBLENDED :: [2]u64{0x7c79_ad00_9b15_dbdf, 0x5fa6_19f7_68fc_9a8b}
	got := earth_hashes(PARAMS_DEFAULTS)
	testing.expectf(t, got == GOLDEN, "worlds differ from Linux's: got %x", got)
	unblended := PARAMS_DEFAULTS
	unblended.biome_blend = 0
	unblended.gates = 0 // (as worlds made before them)
	got = earth_hashes(unblended)
	testing.expectf(t, got == GOLDEN_UNBLENDED, "unblended worlds changed: got %x", got)
}

@(private = "file")
earth_hashes :: proc(params: Params) -> (got: [2]u64) {
	seeds := [2]i64{1, 24301}
	arr := new(game.Block_Array)
	defer free(arr)
	for seed, i in seeds {
		g := generator_make(.Earth, seed, test_reg())
		g.params = params
		h := u64(0xcbf2_9ce4_8422_2325)
		mix :: proc(h: ^u64, bytes: []u8) {
			for b in bytes {h^ = (h^ ~ u64(b)) * 0x100_0000_01b3}
		}
		for k in i32(0) ..< 16 {
			column := [2]i32{k * 37 - 300, k * -53 + 200}
			tops: Tops
			column_tops(&g, column, &tops)
			mix(&h, slice.to_bytes(tops[:]))
			for cy in ([]i32{-3, -1, 0, 1, 3}) {
				uniform, is_uniform := generate(&g, {column.x, cy, column.y}, arr)
				if is_uniform {
					u := uniform
					mix(&h, ([^]u8)(&u)[:size_of(u)])
				} else {
					mix(&h, slice.to_bytes(arr[:]))
				}
			}
		}
		got[i] = h
	}
	return
}

// Biome borders blend: every column's (blended) biome is one found
// unblended within the blend around it, and where two climates meet along
// a line the sides mix (the biome changes back and forth) instead of
// meeting once. (Coasts and rivers follow the land, not the climate.)
@(test)
test_biome_borders_blend :: proc(t: ^testing.T) {
	g := generator_make(.Earth, 24301, test_reg())
	hard := g.params
	hard.biome_blend = 0
	reach := i32(g.params.biome_blend) + 1
	for x := i32(0); x < 1500; x += 3 {
		s := column_at(&g.params, g.seed, x, 40).biome
		found := false
		for dz := -reach; dz <= reach && !found; dz += 1 {
			for dx := -reach; dx <= reach && !found; dx += 1 {
				found = column_at(&hard, g.seed, x + dx, 40 + dz).biome == s
			}
		}
		testing.expectf(t, found, "at x=%d the blended %v is nowhere near unblended", x, s)
	}
	climate :: proc(b: Biome) -> bool {return(
			b == .Plains ||
			b == .Forest ||
			b == .Taiga ||
			b == .Tundra ||
			b == .Desert \
		)}
	borders, mixed := 0, 0
	prev := column_at(&hard, g.seed, 0, 40).biome
	for x in i32(1) ..< 8000 {
		cur := column_at(&hard, g.seed, x, 40).biome
		defer prev = cur
		if cur == prev || !climate(cur) || !climate(prev) {continue}
		borders += 1
		flips := 0
		last := column_at(&g.params, g.seed, x - 16, 40).biome
		for bx in x - 15 ..= x + 16 {
			b := column_at(&g.params, g.seed, bx, 40).biome
			if b != last {flips += 1}
			last = b
		}
		if flips > 1 {mixed += 1}
	}
	testing.expectf(t, borders >= 3, "too few climate borders on the line (%d) to tell", borders)
	testing.expectf(
		t,
		mixed * 4 >= borders * 3,
		"only %d of %d climate borders mix",
		mixed,
		borders,
	)
}


// Structures: each kind turns up within 4096 blocks of the middle (gates
// not nearer than 2000); placements are the same
// every time; a structure's chunks come out the same whichever order they
// are made in; and the land's tops over them are exactly the highest
// blocks that shade.
@(test)
test_structures :: proc(t: ^testing.T) {
	g := generator_make(.Earth, 24301, test_reg())
	found := make([dynamic]Structure)
	defer delete(found)
	structures_near(&g, {-4096, -4096}, {4096, 4096}, &found)
	again := make([dynamic]Structure)
	defer delete(again)
	structures_near(&g, {-4096, -4096}, {4096, 4096}, &again)
	testing.expect(t, slice.equal(found[:], again[:]), "placements differ between two looks")
	first: [Structure_Kind]Maybe(Structure)
	for s in found {if first[s.kind] == nil {first[s.kind] = s}}
	for kind in Structure_Kind {
		s, ok := first[kind].?
		if !testing.expectf(t, ok, "no %v within 4096 blocks", kind) {continue}
		lo, hi := game.chunk_of(s.lo), game.chunk_of(s.hi)
		// Every chunk of it, forwards and backwards.
		chunks := make([dynamic]game.Chunk_Pos, context.temp_allocator)
		for cy in lo.y - 1 ..= hi.y + 1 {
			for cz in lo.z ..= hi.z {
				for cx in lo.x ..= hi.x {append(&chunks, game.Chunk_Pos{cx, cy, cz})}
			}
		}
		made := make(map[game.Chunk_Pos]^game.Block_Array, context.temp_allocator)
		for c in chunks {
			made[c] = new(game.Block_Array, context.temp_allocator)
			generate(&g, c, made[c])
		}
		arr := new(game.Block_Array, context.temp_allocator)
		#reverse for c in chunks {
			generate(&g, c, arr)
			testing.expectf(t, arr^ == made[c]^, "%v: chunk %v differs made later", kind, c)
		}
		// Tops over it, from the chunk columns' blocks (down to the land).
		for cz in lo.z ..= hi.z {
			for cx in lo.x ..= hi.x {
				tops: Tops
				column_tops(&g, {cx, cz}, &tops)
				for z in i32(0) ..< game.CHUNK_SIZE {
					for x in i32(0) ..< game.CHUNK_SIZE {
						want := tops[x + z * game.CHUNK_SIZE]
						got := i32(game.WORLD_MIN_Y)
						for y := want + 40; y >= want - 40 && got == game.WORLD_MIN_Y; y -= 1 {
							c := game.chunk_of({cx * 16 + x, y, cz * 16 + z})
							if c not_in made {
								made[c] = new(game.Block_Array, context.temp_allocator)
								generate(&g, c, made[c])
							}
							if game.block_shades(
								test_blocks(),
								made[c][game.local_index(game.local_of({cx * 16 + x, y, cz * 16 + z}))],
							) {got = y}
						}
						testing.expectf(
							t,
							got == want,
							"%v at %v: top %d, built %d",
							kind,
							[2]i32{cx * 16 + x, cz * 16 + z},
							want,
							got,
						)
					}
				}
			}
		}
	}
}

// The spawn is on open ground: something to stand on, room to stand, and
// no tree there.
@(test)
test_spawn_on_open_ground :: proc(t: ^testing.T) {
	chunks := make(map[game.Chunk_Pos]^game.Block_Array, context.temp_allocator)
	for seed in i64(1) ..= 8 {
		g := generator_make(.Earth, seed, test_reg())
		clear(&chunks)
		block :: proc(
			g: ^Generator,
			chunks: ^map[game.Chunk_Pos]^game.Block_Array,
			p: game.Block_Pos,
		) -> game.Block {
			pos := game.chunk_of(p)
			a, ok := chunks[pos]
			if !ok {
				a = new(game.Block_Array, context.temp_allocator)
				uniform, is_uniform := generate(g, pos, a)
				if is_uniform {for &b in a {b = uniform}}
				chunks[pos] = a
			}
			return a[game.local_index(game.local_of(p))]
		}
		// Where the server lands a newcomer: on the ground of the column.
		Generated :: struct {
			g:      ^Generator,
			chunks: ^map[game.Chunk_Pos]^game.Block_Array,
		}
		data := Generated{&g, &chunks}
		query := game.Block_Query {
			&data,
			proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
				d := (^Generated)(data)
				return block(d.g, d.chunks, p), true
			},
			test_blocks(),
		}
		spawn, _ := game.landing_spot(query, spawn_point(&g) + {0, 1, 0}, .Ground)
		feet := game.Block_Pos {
			i32(math.floor(spawn.x)),
			i32(math.floor(spawn.y)),
			i32(math.floor(spawn.z)),
		}
		below := block(&g, &chunks, feet - {0, 1, 0})
		testing.expectf(
			t,
			game.block_collides(test_blocks(), below),
			"seed %d: standing on %v",
			seed,
			below,
		)
		for dy in i32(0) ..< 2 {
			b := block(&g, &chunks, feet + {0, dy, 0})
			testing.expectf(
				t,
				!game.block_collides(test_blocks(), b),
				"seed %d: %v at the spawn",
				seed,
				b,
			)
		}
		for dz in i32(-2) ..= 2 {
			for dx in i32(-2) ..= 2 {
				for dy in i32(-1) ..< 8 {
					b := block(&g, &chunks, feet + {dx, dy, dz})
					testing.expectf(
						t,
						b != .Log && b != .Leaves && b != .Spruce_Log && b != .Spruce_Leaves,
						"seed %d: a tree at the spawn (%v)",
						seed,
						b,
					)
				}
			}
		}
	}
}

// Every Earth world has gates, none near its middle: their chevrons and
// ring where gates.odin says, inside the ring clear, a traveller's spot in
// front free; a block of one finds it; worlds made before gates have none.
@(test)
test_gates :: proc(t: ^testing.T) {
	arr := new(game.Block_Array)
	defer free(arr)
	block_at :: proc(g: ^Generator, arr: ^game.Block_Array, p: game.Block_Pos) -> game.Block {
		uniform, is_uniform := generate(g, game.chunk_of(p), arr)
		if is_uniform {return uniform}
		return arr[game.local_index(game.local_of(p))]
	}
	for seed in i64(1) ..= 6 {
		g := generator_make(.Earth, seed, test_reg())
		s, ok := arrival_gate(&g)
		if !testing.expectf(t, ok, "seed %d: no gate", seed) {continue}
		d := math.sqrt(f64(s.lo.x) * f64(s.lo.x) + f64(s.lo.z) * f64(s.lo.z))
		testing.expectf(
			t,
			d >= f64(g.params.gate_distance),
			"seed %d: a gate %.0f from the middle",
			seed,
			d,
		)
		for c in gate_chevrons(s) {
			testing.expectf(
				t,
				block_at(&g, arr, c) == .Gate_Chevron,
				"seed %d: no chevron at %v",
				seed,
				c,
			)
		}
		testing.expect_value(t, block_at(&g, arr, gate_at(s, 0, 0)), game.Block.Stone_Bricks)
		testing.expect_value(t, block_at(&g, arr, gate_at(s, 5, 0)), game.Block.Gate_Ring)
		testing.expect_value(t, block_at(&g, arr, gate_at(s, 0, 5)), game.Block.Gate_Ring)
		inside := make([dynamic]game.Block_Pos, context.temp_allocator)
		gate_inside(s, &inside)
		testing.expect(t, len(inside) > 30)
		for p in inside {testing.expectf(t, block_at(&g, arr, p) == .Air, "seed %d: %v inside the ring", seed, p)}
		front, _ := gate_front(s)
		feet := game.Block_Pos {
			i32(math.floor(front.x)),
			i32(math.floor(front.y)),
			i32(math.floor(front.z)),
		}
		testing.expect(
			t,
			game.block_collides(test_blocks(), block_at(&g, arr, feet - {0, 1, 0})),
			"nothing to arrive on",
		)
		testing.expect(
			t,
			!game.block_collides(test_blocks(), block_at(&g, arr, feet)),
			"the arrival spot is in a block",
		)
		testing.expect(
			t,
			!game.block_collides(test_blocks(), block_at(&g, arr, feet + {0, 1, 0})),
			"the arrival spot is in a block",
		)
		found, has := gate_containing(&g, gate_chevrons(s)[3])
		testing.expect(t, has && found.lo == s.lo, "a chevron does not find its gate")
		old := g
		old.params.gates = 0
		_, has = arrival_gate(&old)
		testing.expect(t, !has, "a world from before gates has one")
	}

	// The same places on every machine (as the terrain's golden hashes).
	g := generator_make(.Earth, 1, test_reg())
	found := make([dynamic]Structure, context.temp_allocator)
	structures_near(&g, {-8192, -8192}, {8192, 8192}, &found)
	sum: [3]i64
	n := 0
	for f in found {
		if f.kind != .Gate {continue}
		n += 1
		sum += {i64(f.lo.x), i64(f.lo.y), i64(f.lo.z)}
	}
	arrival, _ := arrival_gate(&g)
	testing.expect_value(t, arrival.lo, game.Block_Pos{-151, 12, -2470})
	testing.expect_value(t, n, 16)
	testing.expect_value(t, sum, [3]i64{19264, 131, -31347})
}

// A worker's Column_Cache changes nothing: chunks come out the same with it
// as without, in any order, and after the generator changes (live tuning).
@(test)
test_column_cache :: proc(t: ^testing.T) {
	cache := new(Column_Cache)
	defer free(cache)
	a, b := new(game.Block_Array), new(game.Block_Array)
	defer free(a)
	defer free(b)
	g := generator_make(.Earth, 24301, test_reg())
	check :: proc(
		t: ^testing.T,
		g: ^Generator,
		cache: ^Column_Cache,
		a, b: ^game.Block_Array,
		c: game.Chunk_Pos,
	) {
		ua, sa := generate(g, c, a)
		ub, sb := generate(g, c, b, cache)
		testing.expectf(
			t,
			sa == sb && (sa ? ua == ub : a^ == b^),
			"chunk %v differs with the cache",
			c,
		)
	}
	// Scrambled: columns and heights interleaved, revisited, colliding.
	n := u32(12345)
	for _ in 0 ..< 400 {
		n = n * 1664525 + 1013904223
		c := game.Chunk_Pos{i32(n >> 8 % 24) - 12, i32(n >> 16 % 10) - 4, i32(n >> 24 % 24) - 12}
		check(t, &g, cache, a, b, c)
		if n >> 4 % 4 == 0 {
			// The column's tops too.
			plain, cached: Tops
			column_tops(&g, {c.x, c.z}, &plain)
			column_tops(&g, {c.x, c.z}, &cached, cache)
			testing.expectf(t, plain == cached, "column %v's tops differ with the cache", c.xz)
		}
	}
	g.params.tree_density = 2
	g.params.sea_level = 9
	for x in i32(-3) ..= 3 {check(t, &g, cache, a, b, {x, 0, 1})}
}

// No plant is generated standing on something that would not hold it (the
// server breaks such plants as soon as a block next to them changes).
@(test)
test_no_floating_plants :: proc(t: ^testing.T) {
	a, below := new(game.Block_Array), new(game.Block_Array)
	defer free(a)
	defer free(below)
	for kind in ([]Kind{.Classic, .Earth}) {
		g := generator_make(kind, 24301, test_reg())
		plants := 0
		for cz in i32(-6) ..= 6 {
			for cx in i32(-6) ..= 6 {
				for cy in i32(-1) ..= 3 {
					generate(&g, {cx, cy, cz}, a)
					generate(&g, {cx, cy - 1, cz}, below)
					for y in i32(0) ..< game.CHUNK_SIZE {
						for z in i32(0) ..< game.CHUNK_SIZE {
							for x in i32(0) ..< game.CHUNK_SIZE {
								b := a[game.local_index({x, y, z})]
								if !game.block_is_plant(test_blocks(), b) {continue}
								plants += 1
								under :=
									a[game.local_index({x, y - 1, z})] if y > 0 else below[game.local_index({x, game.CHUNK_SIZE - 1, z})]
								testing.expectf(
									t,
									game.block_supported(test_blocks(), b, under),
									"%v: a %v over %v at chunk %v %v",
									kind,
									b,
									under,
									[3]i32{cx, cy, cz},
									[3]i32{x, y, z},
								)
							}
						}
					}
				}
			}
		}
		testing.expectf(
			t,
			kind == .Classic || plants > 20,
			"%v made only %d plants to look at",
			kind,
			plants,
		)
	}
}

// The flat world: the table's blocks at every (x, z) and for every seed.
@(test)
test_flat_world :: proc(t: ^testing.T) {
	arr := new(game.Block_Array)
	defer free(arr)
	for seed in ([]i64{1, 66}) {
		g := generator_make(.Flat, seed, test_reg())
		for x in ([]i32{0, -3, 41}) {
			for z in ([]i32{0, 7, -90}) {
				uniform, ok := generate(&g, {x, 0, z}, arr)
				testing.expect(t, ok && uniform == .Air)
				uniform, ok = generate(&g, {x, -2, z}, arr)
				testing.expect(t, ok && uniform == .Stone)
				_, ok = generate(&g, {x, -1, z}, arr)
				testing.expect(t, !ok)
				for l in 0 ..< game.CHUNK_VOLUME {
					want: game.Block
					switch y := game.local_from_index(l).y; {
					case y == 15:
						want = .Grass
					case y >= 12:
						want = .Dirt
					case:
						want = .Stone
					}
					if arr[l] != want {
						testing.expectf(
							t,
							false,
							"chunk y -1, block %d: %v, want %v",
							l,
							arr[l],
							want,
						)
						break
					}
				}
				_, ok = generate(&g, {x, -16, z}, arr)
				testing.expect(t, !ok)
				for l in 0 ..< game.CHUNK_VOLUME {
					want := game.Block.Bedrock if game.local_from_index(l).y == 0 else .Stone
					if arr[l] != want {
						testing.expectf(
							t,
							false,
							"chunk y -16, block %d: %v, want %v",
							l,
							arr[l],
							want,
						)
						break
					}
				}
			}
		}
		testing.expect_value(t, column_top(&g, 0, 0), -1)
		testing.expect_value(t, column_top(&g, -1000, 777), -1)
		tops: Tops
		column_tops(&g, {3, -4}, &tops)
		for top in tops {testing.expect_value(t, top, -1)}
		testing.expect_value(t, spawn_point(&g), [3]f64{0.5, 0, 0.5})
	}
	kind, ok := kind_by_name("flat")
	testing.expect(t, ok && kind == .Flat)
}
