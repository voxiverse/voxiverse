package client

import "core:mem/virtual"
import "core:testing"

import "../game"

// Chunks at the top and bottom of the world are meshed once their neighbours
// inside the world have arrived (outside counts as air above, bedrock below).
@(test)
test_world_edges_mesh :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	scratch := new(game.Block_Array)
	defer free(scratch)

	for layer in ([]i32{game.CHUNK_MAX_Y - 1, game.CHUNK_MIN_Y}) {
		w: World
		testing.expect(t, world_init(&w, 64, 1, virtual.arena_allocator(&arena)) == nil)
		inward: i32 = -1 if layer == game.CHUNK_MAX_Y - 1 else 1
		// Everything around (0, layer, 0) that exists, except the last one.
		positions := make([dynamic]game.Chunk_Pos, context.temp_allocator)
		for dz in i32(-1) ..= 1 {
			for dx in i32(-1) ..= 1 {
				append(
					&positions,
					game.Chunk_Pos{dx, layer, dz},
					game.Chunk_Pos{dx, layer + inward, dz},
				)
			}
		}
		for p in positions[:len(positions) - 1] {
			testing.expect(
				t,
				world_set_chunk(&w, {pos = p, uniform = .Stone, is_uniform = true}, scratch),
			)
		}
		centre := world_get(&w, {0, layer, 0})
		testing.expect(t, !centre.queued, "queued before its neighbours arrived")
		last := positions[len(positions) - 1]
		testing.expect(
			t,
			world_set_chunk(&w, {pos = last, uniform = .Stone, is_uniform = true}, scratch),
		)
		testing.expectf(t, centre.queued, "chunk at layer %d never queued for meshing", layer)
		world_destroy(&w)
	}
}
