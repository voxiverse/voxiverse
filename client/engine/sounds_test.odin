package engine

import "core:mem/virtual"
import "core:testing"

import "client:testkit"
import "common:game"

@(test)
test_sound_occlusion_clear :: proc(t: ^testing.T) {
	var_arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&var_arena) == nil)
	defer virtual.arena_destroy(&var_arena)

	reg := testkit.test_reg()
	w: World
	testing.expect(t, world_init(&w, reg, 64, 4, 0, virtual.arena_allocator(&var_arena)) == nil)
	defer world_destroy(&w)

	scratch := new(game.Block_Array, context.temp_allocator)
	world_set_column(&w, {pos = {0, 0}})
	m := game.Chunk_Message {
		pos        = {0, 0, 0},
		uniform    = .Air,
		is_uniform = true,
	}
	testing.expect(t, world_set_chunk(&w, m, scratch))

	// Direct line of sight across air:
	listener := [3]f64{0.5, 1.6, 0.5}
	source := [3]f64{0.5, 1.6, 10.5}
	cutoff, gain := sound_occlusion(&w, reg, listener, source)
	testing.expect_value(t, cutoff, 0)
	testing.expect_value(t, gain, 1.0)

	// Very close / self sound:
	close_source := [3]f64{0.5, 1.5, 0.6}
	c_close, g_close := sound_occlusion(&w, reg, listener, close_source)
	testing.expect_value(t, c_close, 0)
	testing.expect_value(t, g_close, 1.0)

	// Nil world or reg safely returns unoccluded:
	c_nil, g_nil := sound_occlusion(nil, reg, listener, source)
	testing.expect_value(t, c_nil, 0)
	testing.expect_value(t, g_nil, 1.0)
}

@(test)
test_sound_occlusion_obstruction :: proc(t: ^testing.T) {
	var_arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&var_arena) == nil)
	defer virtual.arena_destroy(&var_arena)

	reg := testkit.test_reg()
	w: World
	testing.expect(t, world_init(&w, reg, 64, 4, 0, virtual.arena_allocator(&var_arena)) == nil)
	defer world_destroy(&w)

	scratch := new(game.Block_Array, context.temp_allocator)
	world_set_column(&w, {pos = {0, 0}})
	m := game.Chunk_Message {
		pos        = {0, 0, 0},
		uniform    = .Air,
		is_uniform = true,
	}
	testing.expect(t, world_set_chunk(&w, m, scratch))

	listener := [3]f64{0.5, 1.6, 0.5}
	source := [3]f64{0.5, 1.6, 10.5}

	// 1-block thin wall at z = 5:
	world_set_block(&w, {0, 1, 5}, .Stone)
	cutoff_thin, gain_thin := sound_occlusion(&w, reg, listener, source)
	testing.expect_value(t, cutoff_thin, 850)
	testing.expect_value(t, gain_thin, 0.80)

	// Thick wall spanning z = 4, 5, 6 (3 blocks thick):
	world_set_block(&w, {0, 1, 4}, .Stone)
	world_set_block(&w, {0, 1, 6}, .Stone)
	cutoff_thick, gain_thick := sound_occlusion(&w, reg, listener, source)
	testing.expect_value(t, cutoff_thick, 450)
	testing.expect_value(t, gain_thick, 0.60)
}
