package worldgen

import "core:slice"
import "core:testing"

import "../base"
import "../game"

@(test)
test_generate_is_deterministic :: proc(t: ^testing.T) {
	g := generator_make(.Classic, 1234)
	one, two := generator_make(.Classic, 1), generator_make(.Classic, 2)
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
	g := generator_make(.Classic, 42)
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
	g := generator_make(.Earth, 24301)
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
						if game.block_shades(bl) {
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
	GOLDEN :: [2]u64{0x7c79_ad00_9b15_dbdf, 0x5fa6_19f7_68fc_9a8b}
	seeds := [2]i64{1, 24301}
	got: [2]u64
	arr := new(game.Block_Array)
	defer free(arr)
	for seed, i in seeds {
		g := generator_make(.Earth, seed)
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
	testing.expectf(t, got == GOLDEN, "worlds differ from Linux's: got %x", got)
}

// Structures: each kind turns up near the spawn; placements are the same
// every time; a structure's chunks come out the same whichever order they
// are made in; and the land's tops over them are exactly the highest
// blocks that shade.
@(test)
test_structures :: proc(t: ^testing.T) {
	g := generator_make(.Earth, 24301)
	found := make([dynamic]Structure)
	defer delete(found)
	structures_near(&g, {-2048, -2048}, {2048, 2048}, &found)
	again := make([dynamic]Structure)
	defer delete(again)
	structures_near(&g, {-2048, -2048}, {2048, 2048}, &again)
	testing.expect(t, slice.equal(found[:], again[:]), "placements differ between two looks")
	first: [Structure_Kind]Maybe(Structure)
	for s in found {if first[s.kind] == nil {first[s.kind] = s}}
	for kind in Structure_Kind {
		s, ok := first[kind].?
		if !testing.expectf(t, ok, "no %v within 2048 blocks", kind) {continue}
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
