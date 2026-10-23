package client

import "core:math"
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
		testing.expect(t, world_init(&w, 64, 16, 1, virtual.arena_allocator(&arena)) == nil)
		add_columns(&w, 1)
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

// An edit re-meshes its chunk and the neighbours whose border it is on.
@(test)
test_world_edit_remeshes_neighbours :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	scratch := new(game.Block_Array)
	defer free(scratch)
	w: World
	testing.expect(t, world_init(&w, 128, 32, 1, virtual.arena_allocator(&arena)) == nil)
	defer world_destroy(&w)
	add_columns(&w, 2)
	for z in i32(-2) ..= 2 {
		for y in i32(-2) ..= 2 {
			for x in i32(-2) ..= 2 {
				testing.expect(
					t,
					world_set_chunk(
						&w,
						{pos = {x, y, z}, uniform = .Stone, is_uniform = true},
						scratch,
					),
				)
			}
		}
	}
	// Pretend everything is meshed.
	clear(&w.to_mesh)
	for x in i32(-2) ..= 2 {
		for y in i32(-2) ..= 2 {
			for z in i32(-2) ..= 2 {
				c := world_get(&w, {x, y, z})
				c.dirty, c.queued = false, false
			}
		}
	}
	// A block in the corner of chunk (0,0,0) at (15, 0, 15): chunks +x, -y,
	// +z (and their combinations) see it in their borders; others do not.
	testing.expect(t, world_set_block(&w, {15, 0, 15}, .Air))
	testing.expect(t, world_get(&w, {0, 0, 0}).dirty)
	testing.expect(
		t,
		world_get(&w, {1, 0, 0}).dirty &&
		world_get(&w, {0, -1, 0}).dirty &&
		world_get(&w, {1, -1, 1}).dirty,
	)
	testing.expect(t, !world_get(&w, {-1, 0, 0}).dirty && !world_get(&w, {0, 1, 0}).dirty)
	b, _ := world_block(&w, {15, 0, 15})
	testing.expect_value(t, b, game.Block.Air)

	// The chunks whose geometry changed were meshed on the spot: their
	// current meshes are already waiting for upload, no worker involved.
	for pos in ([]game.Chunk_Pos{{0, 0, 0}, {1, 0, 0}, {0, -1, 1}, {1, -1, 1}}) {
		c := world_get(&w, pos)
		ready := false
		for task in w.uploads {
			if task.pos == pos && task.version == c.version {ready = true}
		}
		testing.expectf(t, ready, "chunk %v not meshed on the spot", pos)
	}
	// One that is near enough for light but not geometry is left to workers.
	for task in w.uploads {testing.expect(t, task.pos != {0, 1, 0})}
}

// add_columns gives every column within r of the origin flat heights.
@(private = "file")
add_columns :: proc(w: ^World, r: i32) {
	for z in -r ..= r {
		for x in -r ..= r {
			c := game.Column {
				pos = {x, z},
			}
			for &h in c.heights {h = 0}
			world_set_column(w, c)
		}
	}
}

// Other players move smoothly between snapshots, take the short way round
// when turning, ignore late snapshots and vanish when nothing comes.
@(test)
test_other_players_interpolate :: proc(t: ^testing.T) {
	o: Other_Player
	other_snapshot(&o, 10, {position = {0, 64, 0}, yaw = 3.0})
	other_snapshot(&o, 11, {position = {1, 64, 0}, yaw = -3.0}) // turned 0.28 rad, across ±π
	other_snapshot(&o, 9, {position = {50, 0, 0}}) // late: ignored
	testing.expect_value(t, o.count, 2)
	v, ok := other_view(&o, 10.5)
	testing.expect(t, ok && abs(v.position.x - 0.5) < 1e-9)
	testing.expectf(t, abs(abs(v.yaw) - math.PI) < 0.01, "turned the long way: yaw %v", v.yaw)
	v, ok = other_view(&o, 20)
	testing.expect(t, ok && v.position.x == 1, "after the newest: stays there")
	_, ok = other_view(&o, 11 + STALE_TICKS + 1)
	testing.expect(t, !ok, "stale players are hidden")
	for i in 0 ..< 20 {other_snapshot(&o, u32(12 + i), {position = {f64(i), 0, 0}})}
	testing.expect_value(t, o.count, SNAPSHOTS)
	testing.expect(t, abs(render_tick(100, 0.5) - (100 + 15 - INTERPOLATION_TICKS)) < 1e-9)
}
