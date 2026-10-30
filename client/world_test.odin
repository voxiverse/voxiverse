package client

import "core:math"
import "core:mem/virtual"
import "core:testing"

import "../base"
import "../common/game"
import "render"

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
		testing.expect(
			t,
			world_init(&w, test_reg(), 64, 16, 1, virtual.arena_allocator(&arena)) == nil,
		)
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
	testing.expect(
		t,
		world_init(&w, test_reg(), 128, 32, 1, virtual.arena_allocator(&arena)) == nil,
	)
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
	world_changes_settle(&w) // (the end of the frame's messages)
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

// settled_world: the 27 chunks around the origin, all filled with fill,
// as if meshed (nothing dirty or queued).
@(private = "file")
settled_world :: proc(t: ^testing.T, w: ^World, fill: game.Block, arena: ^virtual.Arena) {
	scratch := new(game.Block_Array, context.temp_allocator)
	testing.expect(t, world_init(w, test_reg(), 128, 32, 1, virtual.arena_allocator(arena)) == nil)
	add_columns(w, 2)
	for z in i32(-1) ..= 1 {
		for y in i32(-1) ..= 1 {
			for x in i32(-1) ..= 1 {
				m := game.Chunk_Message {
					pos        = {x, y, z},
					uniform    = fill,
					is_uniform = true,
				}
				testing.expect(t, world_set_chunk(w, m, scratch))
			}
		}
	}
	clear(&w.to_mesh)
	for _, h in w.by_pos {
		c := base.pool_get(&w.chunks, h)
		c.dirty, c.queued, c.meshes = false, false, 1
	}
}

// R3: a frame's 200 block records in one chunk are absorbed once: flowing
// water (no hole it could open) meshes nothing on the main thread, and every
// chunk its light reaches is dirtied once; 200 broken blocks inside one
// chunk mesh it on the spot once.
@(test)
test_world_changes_settle_once_per_chunk :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	defer free_all(context.temp_allocator)
	cells := make([dynamic]game.Block_Pos, context.temp_allocator)
	for z in i32(7) ..= 8 {
		for y in i32(1) ..= 14 {
			for x in i32(1) ..= 14 {append(&cells, game.Block_Pos{x, y, z})}
		}
	}
	resize(&cells, 200)

	w: World
	settled_world(t, &w, .Air, &arena)
	levels := []game.Block{.Water_1, .Water_2, .Water_3, .Water_7, .Water_Falling, .Water}
	for p, i in cells {testing.expect(t, world_set_block(&w, p, levels[i % len(levels)]))}
	world_changes_settle(&w)
	testing.expect_value(t, w.stats.meshed_now, 0)
	testing.expect_value(t, len(w.uploads), 0)
	// Every chunk within light's reach of the cells, once (the centre's 26
	// neighbours are not complete: only the centre can be queued).
	testing.expect_value(t, w.stats.relit_edit, 27)
	testing.expect_value(t, len(w.to_mesh), 1)
	// Water going down again (a level, not geometry) still meshes nothing.
	for p in cells {world_set_block(&w, p, .Water_5)}
	world_changes_settle(&w)
	testing.expect_value(t, w.stats.meshed_now, 0)
	world_destroy(&w)

	settled_world(t, &w, .Stone, &arena)
	for p in cells {testing.expect(t, world_set_block(&w, p, .Air))}
	world_changes_settle(&w)
	testing.expect_value(t, w.stats.meshed_now, 1)
	testing.expect(t, len(w.uploads) == 1 && w.uploads[0].pos == {0, 0, 0})
	testing.expect_value(t, w.stats.relit_edit, 27)
	world_destroy(&w)
}

// R3: the x-ray rule. A cell opens a hole when what it held drew opaque or
// cutout faces and it holds something else now.
@(test)
test_opens_hole :: proc(t: ^testing.T) {
	blocks := &test_reg().blocks
	Case :: struct {
		old, new: game.Block,
		hole:     bool,
	}
	cases := []Case {
		{.Stone, .Air, true}, // broken
		{.Stone, .Water, true}, // flooded
		{.Leaves, .Air, true}, // cutout
		{.Tall_Grass, .Water_3, true}, // a plant washed away
		{.Glass, .Air, true},
		{.Air, .Stone, false}, // placed
		{.Air, .Water_1, false}, // water flowing in
		{.Water_1, .Water_2, false}, // its level
		{.Water_3, .Air, false}, // drained
		{.Water, .Stone, false},
		{.Stone, .Stone, false},
	}
	for c in cases {
		testing.expectf(
			t,
			opens_hole(blocks, c.old, c.new) == c.hole,
			"%v -> %v: want %v",
			c.old,
			c.new,
			c.hole,
		)
	}
}

// add_columns gives every column within r of the origin flat heights.
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
	testing.expect_value(t, o.track.count, 2)
	v, ok := other_view(&o, 10.5)
	testing.expect(t, ok && abs(v.position.x - 0.5) < 1e-9)
	testing.expectf(t, abs(abs(v.yaw) - math.PI) < 0.01, "turned the long way: yaw %v", v.yaw)
	v, ok = other_view(&o, 20)
	testing.expect(t, ok && v.position.x == 1, "after the newest: stays there")
	track_hold(&o.track, 500) // stood still until 500, then walked
	other_snapshot(&o, 501, {position = {2, 64, 0}})
	v, ok = other_view(&o, 400)
	testing.expect(t, ok && v.position.x == 1, "stood still: still there")
	v, _ = other_view(&o, 500.5)
	testing.expect(t, abs(v.position.x - 1.5) < 1e-9, "no glide across the time it stood")
	for i in 0 ..< 20 {other_snapshot(&o, u32(502 + i), {position = {f64(i), 0, 0}})}
	testing.expect_value(t, o.track.count, SNAPSHOTS)
}

// The render clock never jumps: with snapshots late and bunched it moves by
// about a frame's worth each frame, and it snaps only after a real stall.
@(test)
test_render_clock_smooth :: proc(t: ^testing.T) {
	c: Render_Clock
	clock_heard(&c, 100)
	testing.expect(t, abs(c.time - (100 - INTERPOLATION_TICKS)) < 1e-9)
	frame := f32(game.TICK_SECONDS)
	max_step, last := 0.0, c.time
	tick := u32(100)
	// Frames at the tick rate; a snapshot each tick but arrivals late (held
	// back 3 frames, then two together), bunched, and one 5 ticks late.
	for f in 0 ..< 600 {
		clock_advance(&c, frame)
		late := f % 40 >= 10 && f % 40 < 13
		if f % 97 == 50 {
			// a burst: the held ticks arrive together
			tick += 3
			clock_heard(&c, tick)
		} else if !late {
			tick += 1
			clock_heard(&c, tick)
		}
		max_step = max(max_step, c.time - last)
		testing.expect(t, c.time >= last, "the clock ran backwards")
		last = c.time
	}
	testing.expectf(t, max_step < 1.15, "stepped %v ticks in a frame", max_step)
	// A stall: nothing for a second, then a snapshot far ahead: it snaps.
	for _ in 0 ..< 60 {clock_advance(&c, frame)}
	testing.expect(t, !clock_live(c) || c.since <= STALE_SECONDS)
	clock_heard(&c, tick + 200)
	clock_advance(&c, frame)
	testing.expect(t, abs(c.time - clock_target(c)) < 1.2, "did not snap after a gap")
	// Old (reordered) snapshots change nothing.
	before := c
	clock_heard(&c, tick)
	testing.expect_value(t, c, before)
}

// A dying entity bursts into pieces that fly, are drawn, and are gone
// after PUFF_SECONDS; its death is heard where it was.
@(test)
test_entity_death_puff :: proc(t: ^testing.T) {
	s: Session
	s.reg = test_reg()
	s.puffs = make([dynamic]Puff, 0, MAX_PUFFS)
	defer delete(s.puffs)
	defer delete(s.sounds)
	defer delete(s.entities)
	e := Other_Entity {
		kind      = .Sheep,
		last_seen = {10, 64, 10},
	}
	entity_died(&s, &e)
	testing.expect_value(t, len(s.puffs), PUFF_PIECES)
	testing.expect(t, len(s.sounds) == 1 && s.sounds[0].kind == .Entity_Die)
	d: render.Entity_Draw
	render.entity_draw_init(&d)
	defer render.entity_draw_destroy(&d)
	entities_draw(&s, &d, 0.1)
	testing.expect_value(t, len(d.boxes), PUFF_PIECES)
	for p in s.puffs {testing.expect(t, p.position != {10, 64, 10} || p.velocity != {})}
	for _ in 0 ..< 10 {
		clear(&d.boxes)
		entities_draw(&s, &d, 0.1)
	}
	testing.expect_value(t, len(s.puffs), 0)
	testing.expect_value(t, len(d.boxes), 0)

	// Effects never grow the particles past their room: the rest are dropped.
	for len(s.puffs) < MAX_PUFFS - 5 {entity_died(&s, &e)}
	explosion_effects(&s, {0, 64, 0}, 6)
	entity_died(&s, &e)
	testing.expect_value(t, len(s.puffs), MAX_PUFFS)
	testing.expect_value(t, cap(s.puffs), MAX_PUFFS)
}

// Loading waits for the ground around the player only: the 5x5 columns near,
// from one chunk above down to one below (or to the lowest ground), each
// here and meshed; far chunks do not matter.
@(test)
test_near_ready :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	scratch := new(game.Block_Array)
	defer free(scratch)
	w: World
	testing.expect(
		t,
		world_init(&w, test_reg(), 512, 64, 1, virtual.arena_allocator(&arena)) == nil,
	)
	defer world_destroy(&w)
	add_columns(&w, 2) // (the columns 3 away are not known: they must not matter)
	set :: proc(t: ^testing.T, w: ^World, p: game.Chunk_Pos, scratch: ^game.Block_Array) {
		testing.expect(
			t,
			world_set_chunk(w, {pos = p, uniform = .Stone, is_uniform = true}, scratch),
		)
		c := world_get(w, p)
		c.dirty, c.queued = false, false // (meshed)
	}
	RADIUS, HEIGHT :: 6, 4
	centre := game.Chunk_Pos{0, 0, 0}
	for z in i32(-2) ..= 2 {
		for x in i32(-2) ..= 2 {
			for y in i32(-1) ..= 1 {set(t, &w, {x, y, z}, scratch)}
		}
	}
	testing.expect(t, world_near_ready_at(&w, centre, RADIUS, HEIGHT), "everything near is meshed")
	c := world_get(&w, {1, 0, 1})
	c.queued = true
	testing.expect(t, !world_near_ready_at(&w, centre, RADIUS, HEIGHT), "a queued chunk")
	c.queued, c.waiting = false, true
	testing.expect(
		t,
		!world_near_ready_at(&w, centre, RADIUS, HEIGHT),
		"a chunk waiting for its group",
	)
	c.waiting, c.dirty = false, true
	testing.expect(t, !world_near_ready_at(&w, centre, RADIUS, HEIGHT), "dirty and meshable")
	c.dirty = false
	edge := world_get(&w, {2, 0, 2})
	edge.dirty = true // (its neighbours beyond never come: it cannot mesh)
	testing.expect(t, world_near_ready_at(&w, centre, RADIUS, HEIGHT), "dirty, but cannot mesh")
	edge.dirty = false
	// A chunk of the column 3 away is missing: it does not matter.
	testing.expect(t, world_get(&w, {3, 0, 0}) == nil)
	// A missing column or chunk does.
	delete_key(&w.columns, [2]i32{2, 2})
	testing.expect(t, !world_near_ready_at(&w, centre, RADIUS, HEIGHT), "an unknown column")
	add_columns(&w, 2)
	// Ground 40 blocks below: the chunks down to it are needed.
	column := w.columns[{0, 0}]
	for &h in column.heights {h = -40}
	w.columns[{0, 0}] = column
	testing.expect(t, !world_near_ready_at(&w, centre, RADIUS, HEIGHT), "ground far below")
	set(t, &w, {0, -2, 0}, scratch)
	testing.expect(t, !world_near_ready_at(&w, centre, RADIUS, HEIGHT), "still not down to it")
	set(t, &w, {0, -3, 0}, scratch)
	testing.expect(t, world_near_ready_at(&w, centre, RADIUS, HEIGHT), "down to the ground")
}
