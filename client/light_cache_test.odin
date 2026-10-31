package client

import "core:mem/virtual"
import "core:slice"
import "core:testing"

import "client:mesh"
import "common:base"
import "common:game"
import "common:worldgen"

// R4: the light cache. Terrain from the generator (5x5 chunk columns, five
// chunks high round the surface: the middle 3x3x3 can be meshed) is meshed
// through the world's tasks (no workers: each runs as it is started), and
// every mesh is compared with one made the old way, lit from scratch.

@(private = "file")
Cache_Fixture :: struct {
	arena:   virtual.Arena,
	w:       World,
	meshes:  map[game.Chunk_Pos][]mesh.Vertex, // what each chunk shows now
	meshed:  map[game.Chunk_Pos]bool, // ... meshed by the last drain
	tasks:   int, // tasks the last drain finished (lit, meshed or not)
	surface: i32, // the middle column's surface chunk
}

@(private = "file")
fixture_make :: proc(t: ^testing.T, f: ^Cache_Fixture) {
	testing.expect(t, virtual.arena_init_growing(&f.arena) == nil)
	reg := test_reg()
	testing.expect(t, world_init(&f.w, reg, 256, 32, 0, virtual.arena_allocator(&f.arena)) == nil)
	gen := worldgen.generator_make(.Earth, 12345, reg)
	cache := new(worldgen.Column_Cache, context.temp_allocator)
	scratch := new(game.Block_Array, context.temp_allocator)
	tops: worldgen.Tops
	worldgen.column_tops(&gen, {0, 0}, &tops, cache)
	f.surface = tops[8 + 8 * game.CHUNK_SIZE] >> game.CHUNK_SHIFT
	for cz in i32(-2) ..= 2 {
		for cx in i32(-2) ..= 2 {
			worldgen.column_tops(&gen, {cx, cz}, &tops, cache)
			world_set_column(&f.w, {pos = {cx, cz}, heights = tops})
			for cy in f.surface - 2 ..= f.surface + 2 {
				u, uniform := worldgen.generate(&gen, {cx, cy, cz}, scratch, cache)
				m := game.Chunk_Message {
					pos        = {cx, cy, cz},
					uniform    = u,
					is_uniform = uniform,
				}
				testing.expect(t, world_set_chunk(&f.w, m, scratch))
			}
		}
	}
	drain(f)
}

@(private = "file")
fixture_destroy :: proc(f: ^Cache_Fixture) {
	for _, v in f.meshes {delete(v)}
	delete(f.meshes)
	delete(f.meshed)
	world_destroy(&f.w)
	virtual.arena_destroy(&f.arena)
}

// drain settles the changes and runs tasks until nothing waits, taking
// their results as world_apply does (without the GPU).
@(private = "file")
drain :: proc(f: ^Cache_Fixture) {
	w := &f.w
	clear(&f.meshed)
	f.tasks = 0
	world_changes_settle(w)
	for {
		world_update(w, {})
		base.queue_drain(&w.done, &w.uploads)
		if len(w.uploads) == 0 && len(w.to_mesh) == 0 {break}
		for task in w.uploads {
			f.tasks += 1
			c, for_group, ok := task_take(w, task)
			if !ok {continue}
			if old, had := f.meshes[c.pos]; had {delete(old)}
			f.meshes[c.pos] = slice.clone(task.vertices[:])
			f.meshed[c.pos] = true
			task_meshed(w, c, task, for_group)
		}
		clear(&w.uploads)
	}
}

// fresh lights and meshes pos the old way: light_chunk every time.
@(private = "file")
fresh :: proc(
	w: ^World,
	pos: game.Chunk_Pos,
	allocator := context.temp_allocator,
) -> (
	vertices: []mesh.Vertex,
	light: ^mesh.Light_Snapshot,
) {
	task := new(Mesh_Task, context.temp_allocator)
	task.scratch.queue = make([dynamic]u32, context.temp_allocator)
	task.vertices = make([dynamic]mesh.Vertex, context.temp_allocator)
	for &c, j in task.chunks {task.light_in.chunks[j] = &c}
	task.light_in.table = &w.reg.blocks
	task_fill(w, task, pos)
	game.light_chunk(&task.light_in, &task.scratch, &task.light)
	n: mesh.Neighbourhood
	for &c, i in task.chunks {n[i] = &c}
	mesh.snapshot_fill(&task.snapshot, &n)
	mesh.mesh_chunk(w.reg, &task.snapshot, &task.light, &task.vertices)
	for &c in task.chunks {if c.array != nil {game.block_arrays_give(&w.arrays, c.array)}}
	return task.vertices[:], &task.light
}

// meshable: the middle 3x3x3, whose neighbours are all here (with nothing
// to draw without meshing, trivially_empty, never meshed: left out).
@(private = "file")
meshable :: proc(f: ^Cache_Fixture) -> []game.Chunk_Pos {
	out := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for i in 0 ..< 27 {
		pos := game.Chunk_Pos{i32(i % 3) - 1, f.surface + i32(i / 3 % 3) - 1, i32(i / 9) - 1}
		if !trivially_empty(&f.w, world_get(&f.w, pos)) {append(&out, pos)}
	}
	return out[:]
}

// expect_identical: every chunk shows what lighting it from scratch makes.
@(private = "file")
expect_identical :: proc(t: ^testing.T, f: ^Cache_Fixture, when_: string) {
	for pos in meshable(f) {
		want, _ := fresh(&f.w, pos)
		got := f.meshes[pos]
		testing.expectf(
			t,
			slice.equal(slice.to_bytes(got), slice.to_bytes(want)),
			"%s: chunk %v's mesh (%d vertices) is not the one made the old way (%d)",
			when_,
			pos,
			len(got),
			len(want),
		)
	}
}

// lights: each meshable chunk's light, lit from scratch now.
@(private = "file")
lights :: proc(f: ^Cache_Fixture) -> map[game.Chunk_Pos]mesh.Light_Snapshot {
	out := make(map[game.Chunk_Pos]mesh.Light_Snapshot, context.temp_allocator)
	for pos in meshable(f) {
		_, l := fresh(&f.w, pos)
		out[pos] = l^
	}
	return out
}

// within_a_block: the meshable chunks within a block of p (its geometry's).
@(private = "file")
within_a_block :: proc(f: ^Cache_Fixture, p: game.Block_Pos) -> map[game.Chunk_Pos]bool {
	out := make(map[game.Chunk_Pos]bool, context.temp_allocator)
	a, z := game.chunk_of(p - 1), game.chunk_of(p + 1)
	for pos in meshable(f) {
		if pos.x >= a.x &&
		   pos.x <= z.x &&
		   pos.y >= a.y &&
		   pos.y <= z.y &&
		   pos.z >= a.z &&
		   pos.z <= z.z {
			out[pos] = true
		}
	}
	return out
}

// Meshes made with the cached light are byte-identical to meshes lit from
// scratch, after the first meshing and after each edit.
@(test)
test_cached_light_meshes_are_byte_identical :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Cache_Fixture
	fixture_make(t, &f)
	defer fixture_destroy(&f)
	testing.expect(t, len(f.meshed) > 0)
	expect_identical(t, &f, "first meshing")
	// Lamps on the ground and below it, in turn.
	top := f.w.columns[{0, 0}].heights[8 + 8 * game.CHUNK_SIZE]
	for p in ([]game.Block_Pos{{8, top + 1, 8}, {3, top - 4, 12}, {14, top - 9, 1}}) {
		testing.expect(t, world_set_block(&f.w, p, .Lamp))
		drain(&f)
		expect_identical(t, &f, "after an edit")
	}
	testing.expect(t, f.w.stats.unchanged > 0, "every chunk lit again was meshed again")
}

// An edit far from any light change (a block dug out of solid rock, in
// the dark) re-meshes only the chunks within a block of it, though it
// lights again every chunk within LIGHT_MAX.
@(test)
test_an_edit_in_the_dark_remeshes_only_its_geometry :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Cache_Fixture
	fixture_make(t, &f)
	defer fixture_destroy(&f)
	// A cell in the dark deep in the bottom middle chunk, rock all round.
	origin := game.chunk_origin({0, f.surface - 1, 0})
	_, light := fresh(&f.w, {0, f.surface - 1, 0})
	p: game.Block_Pos
	found := false
	search: for y in i32(2) ..< 14 {
		for z in i32(2) ..< 14 {
			for x in i32(2) ..< 14 {
				q := origin + {x, y, z}
				dark := true
				for d in ([7][3]i32{{0, 0, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
					b, _ := world_block(&f.w, q + d)
					l := light[mesh.snapshot_index(x + d.x, y + d.y, z + d.z)]
					if !game.block_opaque(&f.w.reg.blocks, b) || l != 0 {dark = false}
				}
				if dark {
					p, found = q, true
					break search
				}
			}
		}
	}
	if !testing.expect(t, found, "no cell in the dark in the bottom chunk") {return}
	before := lights(&f)
	testing.expect(t, world_set_block(&f.w, p, .Air))
	drain(&f)
	after := lights(&f)
	for pos in meshable(&f) {testing.expectf(t, before[pos] == after[pos], "light changed in %v", pos)}
	want := within_a_block(&f, p)
	testing.expect_value(t, len(f.meshed), len(want))
	for pos in f.meshed {testing.expectf(t, want[pos], "%v meshed again, its light the same", pos)}
	testing.expect(t, f.tasks > len(f.meshed), "only the chunks meshed again were lit again")
	expect_identical(t, &f, "after the dig")
}

// A lamp placed re-meshes exactly the chunks its light reaches (and those
// within a block of it).
@(test)
test_a_lamp_remeshes_the_chunks_its_light_reaches :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Cache_Fixture
	fixture_make(t, &f)
	defer fixture_destroy(&f)
	top := f.w.columns[{0, 0}].heights[15 + 15 * game.CHUNK_SIZE]
	p := game.Block_Pos{15, top + 1, 15}
	before := lights(&f)
	testing.expect(t, world_set_block(&f.w, p, .Lamp))
	drain(&f)
	after := lights(&f)
	want := within_a_block(&f, p)
	for pos in meshable(&f) {if before[pos] != after[pos] {want[pos] = true}}
	testing.expect(
		t,
		len(want) > len(within_a_block(&f, p)),
		"the lamp lit no chunk beyond its own",
	)
	testing.expect_value(t, len(f.meshed), len(want))
	for pos in f.meshed {testing.expectf(t, want[pos], "%v meshed again, unchanged", pos)}
	expect_identical(t, &f, "after the lamp")
}

// A chunk lit again with nothing changed takes its cached light (the key
// matches): no light pass, and no mesh.
@(test)
test_light_reused_when_the_key_matches :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Cache_Fixture
	fixture_make(t, &f)
	defer fixture_destroy(&f)
	first := len(f.meshed)
	c := world_get(&f.w, {0, f.surface, 0})
	c.dirty = true
	queue_if_complete(&f.w, c)
	drain(&f)
	testing.expect_value(t, f.w.stats.light_reused, 1)
	testing.expect_value(t, f.tasks, 1)
	testing.expect_value(t, len(f.meshed), 0)
	// The registry swapped: no cache is trusted, everything meshed again.
	world_remesh_all(&f.w)
	drain(&f)
	testing.expect_value(t, len(f.meshed), first)
	testing.expect_value(t, f.w.stats.light_reused, 1)
	expect_identical(t, &f, "after the registry")
}

// R3b: a job's snapshot is by reference; an edit meanwhile writes a copy.

@(private = "file")
find_array_chunk :: proc(f: ^Cache_Fixture) -> game.Chunk_Pos {
	for i in 0 ..< 27 {
		pos := game.Chunk_Pos{i32(i % 3) - 1, f.surface + i32(i / 3 % 3) - 1, i32(i / 9) - 1}
		if world_get(&f.w, pos).blocks.array != nil {return pos}
	}
	return {}
}

@(test)
test_a_job_snapshot_is_unchanged_by_an_edit_made_while_it_runs :: proc(t: ^testing.T) {
	f: Cache_Fixture
	fixture_make(t, &f)
	defer fixture_destroy(&f)
	w := &f.w
	pos := find_array_chunk(&f)
	c := world_get(w, pos)
	testing.expect(t, c.blocks.array != nil)
	task := pop(&w.free_tasks)
	task_fill(w, task, pos)
	before := c.blocks.array^
	live := c.blocks.array
	testing.expect_value(t, game.block_arrays_holders(&w.arrays, live), 2)
	// The edit between task_fill and the job.
	p := game.chunk_origin(pos)
	old := game.chunk_get(&c.blocks, {0, 0, 0})
	nb := game.Block.Air if old != .Air else game.Block.Stone
	testing.expect(t, world_set_block(w, p, nb))
	testing.expect(t, c.blocks.array != live)
	testing.expect_value(t, game.chunk_get(&c.blocks, {0, 0, 0}), nb)
	testing.expect(t, slice.equal(live[:], before[:])) // the job's array: as it was
	testing.expect(t, task.chunks[13].array == live)
	testing.expect_value(t, game.block_arrays_holders(&w.arrays, live), 1)
	task_free(w, task)
	// Released: the old array went back.
}

@(test)
test_an_array_a_job_holds_is_not_handed_out_until_released :: proc(t: ^testing.T) {
	f: Cache_Fixture
	fixture_make(t, &f)
	defer fixture_destroy(&f)
	w := &f.w
	pos := find_array_chunk(&f)
	c := world_get(w, pos)
	task := pop(&w.free_tasks)
	task_fill(w, task, pos)
	held := c.blocks.array
	game.chunk_release(&c.blocks, &w.arrays) // the world drops it (a resent chunk, an unload)
	for _ in 0 ..< 50 {
		a, err := game.block_arrays_take(&w.arrays)
		testing.expect(t, err == nil && a != held)
	}
	testing.expect_value(t, game.block_arrays_holders(&w.arrays, held), 1)
	used := game.block_arrays_in_use(&w.arrays)
	task_free(w, task)
	testing.expect_value(t, game.block_arrays_in_use(&w.arrays), used - 1)
	a, _ := game.block_arrays_take(&w.arrays)
	testing.expect(t, a == held) // only now it comes back
}
