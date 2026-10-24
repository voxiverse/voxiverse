package worldgen

import "core:testing"

import "../game"

@(test)
test_generate_is_deterministic :: proc(t: ^testing.T) {
	g := Generator{.Classic, 1234}
	one, two := Generator{.Classic, 1}, Generator{.Classic, 2}
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
	g := Generator{.Classic, 42}
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
