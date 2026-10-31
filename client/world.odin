package client

import "core:hash/xxhash"
import "core:log"
import "core:mem"
import "core:slice"
import "core:time"

import "client:gpu"
import "client:mesh"
import "client:render"
import "common:base"
import "common:game"

// The client's copy of the world: the chunks the server sent, and their
// meshes. Storage is sized once from the interest area the server announced
// (plus the drop margin), so it cannot grow however far the player goes.
//
// A chunk is meshed once it and all 26 neighbours are present (so its
// border faces and AO are right the first time): arrival of a chunk checks
// it and its neighbours. Meshing runs on worker threads from snapshots;
// results that are stale by the time they finish (chunk changed or gone)
// are dropped. Mesh uploads and removals touch the GPU, so they wait for
// world_apply in the frame's recording phase.
//
// Light (R4): a task first lights its chunk (game.light_chunk, the chunk
// and its 1-block border), then meshes it only if it must. Each chunk keeps
// the light its mesh was made with (Light_Cache) and the key of what that
// light was computed from: its 27 chunks' block versions and the column
// heights around. A task whose key matches takes the cached light without
// computing it; one whose blocks within a block of the chunk did not change
// (Client_Chunk.geometry) and whose light came out the same is not meshed
// again: its mesh is already that one. So an edit lights the chunks within
// LIGHT_MAX of it, and re-meshes only those whose light it changed and the
// few whose blocks it touched.

Chunk_Handle :: distinct u32

// Light_Cache: a chunk's light, as its mesh was made with it, and the key
// of its inputs (light_key).
Light_Cache :: struct {
	key:   u64,
	light: mesh.Light_Snapshot,
}

#assert(mesh.FACE_GROUPS == render.FACE_GROUPS)

Client_Chunk :: struct {
	pos:            game.Chunk_Pos,
	blocks:         game.Chunk_Blocks,
	version:        u32, // bumped whenever its mesh's inputs change: its blocks, or a neighbour's
	blocks_version: u32, // bumped whenever its own blocks change (what light keys are made of)
	light:          ^Light_Cache, // the light its mesh was made with (nil: none yet)
	geometry:       bool, // a block within a block of it changed since its last mesh began: mesh it whatever its light
	edited:         bool, // an edit (or prediction) dirtied it when it was clean (World_Stats.dirtied_edit)
	mesh:           render.Mesh_Handle, // 0: no mesh (nothing visible, or not meshed yet)
	dirty:          bool, // its mesh does not match its blocks
	queued:         bool, // waiting in to_mesh or being meshed
	group:          u32, // a bulk edit's mesh group it belongs to (0: none)
	pending:        render.Mesh_Handle, // its new mesh, uploaded hidden until its group is shown
	waiting:        bool, // a new mesh (pending, or none: empty) waits for its group
	meshes:         u32, // tasks started for it (lit, and meshed if they must)
	settled:        u32, // the last world_changes_settle that dirtied it (once per pass)
	checked:        u32, // ... that tried meshing it on the spot
	hurry:          bool, // a block change opened a hole in it: meshed before other waiting chunks
}

// Mesh_Group: the chunks a bulk edit touched, and their neighbours: their
// new meshes are shown together, in one frame, so no face goes missing
// between one mesh and the next (a see-through hole).
@(private)
Mesh_Group :: struct {
	id:      u32,
	members: [MAX_GROUP_MEMBERS]Chunk_Handle,
	count:   int,
	opened:  time.Tick,
	since:   u32, // chunk versions from the bulk edit on: meshes of those may be shown with it
}

MAX_GROUP_MEMBERS :: 512
MAX_GROUPS :: 16
GROUP_TIMEOUT :: 1500 * time.Millisecond // a group that cannot finish is shown anyway (on a starved machine, a moment late beats a hole)

World :: struct {
	chunks:        base.Pool(Client_Chunk, Chunk_Handle),
	by_pos:        map[game.Chunk_Pos]Chunk_Handle,
	arrays:        game.Block_Arrays,
	jobs:          base.Jobs,
	done:          base.Queue(^Mesh_Task), // from workers
	free_tasks:    [dynamic]^Mesh_Task,
	urgent_tasks:  [dynamic]^Mesh_Task, // free tasks reserved for meshing edits on the spot
	tasks:         []Mesh_Task,
	to_mesh:       [dynamic]Chunk_Handle, // complete and dirty, waiting for a task
	uploads:       [dynamic]^Mesh_Task, // meshed, waiting for staging room
	mesh_removals: [dynamic]render.Mesh_Handle,
	columns:       map[[2]i32]Client_Column,
	next_version:  u32,
	// Bulk edits (Mesh_Group):
	batch_left:    int, // chunks of the bulk edit still to come
	batch_since:   u32, // the first chunk version of the bulk edit
	batch:         [dynamic]game.Chunk_Pos, // ... those come so far
	groups:        [dynamic]Mesh_Group,
	next_group:    u32,
	// Block changes since the last world_changes_settle (heap: a frame may
	// bring any number):
	changed:       [dynamic][2]game.Block_Pos, // boxes whose chunks' light may be different
	cells:         [dynamic]game.Block_Pos, // cells that changed: the chunks within a block of each change geometry
	holes:         [dynamic]game.Block_Pos, // cells whose change could open a hole (opens_hole)
	settles:       u32, // world_changes_settle passes so far
	light_free:    [dynamic]^Light_Cache, // light caches to reuse (heap; as many as chunks ever lit at once)
	light_all:     [dynamic]^Light_Cache, // ... every one made, to free
	stats:         World_Stats,
	reg:           ^game.Registry, // what the blocks are (set by world_init)
}

World_Stats :: struct {
	meshed:         int, // chunks meshed in total
	remeshed:       int, // ... of chunks meshed before (a change, or churn)
	// Why chunks went dirty again after being complete: the server sent a
	// chunk we had, an edit (or prediction) changed light or blocks near
	// and it was meshed again for it, a column's top moved.
	dirtied_resent: int,
	dirtied_edit:   int,
	relit_edit:     int, // chunks an edit (or prediction) made light again (within LIGHT_MAX of it)
	unchanged:      int, // lit again without meshing: light and geometry as their mesh's
	light_reused:   int, // lit from the cache (the key matched): no light pass
	meshed_now:     int, // ... of chunks meshed on the main thread (mesh_now)
	dirtied_column: int,
	stale_meshes:   int, // results dropped because the chunk changed or left
	mesh_jobs_busy: int,
	groups_shown:   int, // bulk edits shown whole
	groups_late:    int, // ... shown on the timeout instead (could flash a hole)
	mesh_times:     base.Frame_Stats, // ms per task (lit, and meshed when it had to be), on the workers
}

@(private)
Mesh_Task :: struct {
	world:    ^World,
	handle:   Chunk_Handle,
	version:  u32,
	pos:      game.Chunk_Pos,
	// The 3x3x3 neighbourhood (light needs all of it) by reference: each
	// array holds one holder for this task (World.arrays), so an edit meanwhile
	// writes a fresh copy; released by task_free. And the column heights.
	chunks:   [27]game.Chunk_Blocks,
	light_in: game.Light_Input,
	scratch:  game.Light_Scratch,
	snapshot: mesh.Snapshot,
	light:    mesh.Light_Snapshot,
	key:      u64, // of light's inputs (light_key)
	old:      mesh.Light_Snapshot, // the light the chunk's mesh was made with, if has_old
	has_old:  bool,
	reuse:    bool, // old's key is key: old is the light, no light pass
	geometry: bool, // mesh whatever the light (Client_Chunk.geometry, or no mesh yet)
	again:    bool, // the chunk had a task before (World_Stats.remeshed)
	edited:   bool, // (Client_Chunk.edited, carried for the stats)
	meshed:   bool, // the result: meshed (vertices), or the old mesh stands
	vertices: [dynamic]mesh.Vertex, // heap; keeps its capacity between uses
	ms:       f32, // how long lighting and meshing took
	counts:   mesh.Counts, // vertices of each layer's face groups, in order
	urgent:   bool, // one of the reserve for edits (mesh_now)
}

// Client_Column: a column's heights (from the server) and how many of its
// chunks are loaded (it is dropped with the last one).
Client_Column :: struct {
	heights: [game.CHUNK_SIZE * game.CHUNK_SIZE]i32,
	chunks:  int,
}

// URGENT_TASKS: tasks kept for meshing edited chunks on the spot (an edit
// changes the geometry of at most 8 chunks: those within a block of it).
@(private)
URGENT_TASKS :: 8

// MESH_TASKS_PER_WORKER: snapshots in flight per mesh worker.
@(private)
MESH_TASKS_PER_WORKER :: 4

// world_init sizes storage for capacity chunks. Long-lived storage comes
// from arena; whatever workers touch from heap.
world_init :: proc(
	w: ^World,
	reg: ^game.Registry,
	capacity, columns, workers: int,
	arena: mem.Allocator,
	heap := context.allocator,
) -> mem.Allocator_Error {
	w^ = {
		next_version = 1,
		reg          = reg,
	}
	base.pool_init(&w.chunks, capacity, arena) or_return
	w.by_pos = base.map_make_fixed(map[game.Chunk_Pos]Chunk_Handle, capacity, arena) or_return
	// (Headroom: an edit writes a fresh array while a job still reads the old.)
	game.block_arrays_init(
		&w.arrays,
		capacity + 27 * (workers * MESH_TASKS_PER_WORKER + URGENT_TASKS + 1),
		arena,
	) or_return
	w.to_mesh = make([dynamic]Chunk_Handle, 0, capacity, arena) or_return
	w.mesh_removals = make([dynamic]render.Mesh_Handle, 0, capacity, arena) or_return
	// Columns: at most one per loaded chunk (in practice far fewer).
	w.columns = base.map_make_fixed(map[[2]i32]Client_Column, columns, arena) or_return
	count := max(workers, 1) * MESH_TASKS_PER_WORKER // (no workers: jobs run as they are submitted)
	w.tasks = make([]Mesh_Task, count + URGENT_TASKS, arena) or_return
	w.free_tasks = make([dynamic]^Mesh_Task, 0, count, arena) or_return
	w.urgent_tasks = make([dynamic]^Mesh_Task, 0, URGENT_TASKS, arena) or_return
	w.uploads = make([dynamic]^Mesh_Task, 0, count + URGENT_TASKS, arena) or_return
	w.batch = make([dynamic]game.Chunk_Pos, 0, MAX_GROUP_MEMBERS, arena) or_return
	w.groups = make([dynamic]Mesh_Group, 0, MAX_GROUPS, arena) or_return
	for &t, i in w.tasks {
		t.world = w
		t.vertices = make([dynamic]mesh.Vertex, heap)
		t.scratch.queue = make([dynamic]u32, heap)
		for &c, j in t.chunks {t.light_in.chunks[j] = &c}
		t.light_in.table = &reg.blocks
		t.urgent = i >= count
		task_free(w, &t)
	}
	w.changed = make([dynamic][2]game.Block_Pos, heap)
	w.cells = make([dynamic]game.Block_Pos, heap)
	w.light_free = make([dynamic]^Light_Cache, heap)
	w.light_all = make([dynamic]^Light_Cache, heap)
	w.holes = make([dynamic]game.Block_Pos, heap)
	base.queue_init(&w.done, heap)
	base.jobs_init(&w.jobs, "mesh", workers, heap)
	return nil
}

// world_destroy stops the workers and frees what is outside the arena. The
// caller removes meshes first (world_remove_all_meshes + world_apply).
world_destroy :: proc(w: ^World) {
	base.jobs_destroy(&w.jobs)
	base.queue_destroy(&w.done)
	for &t in w.tasks {
		delete(t.vertices)
		game.light_scratch_destroy(&t.scratch)
	}
	game.block_arrays_destroy(&w.arrays)
	for l in w.light_all {free(l, w.light_all.allocator)}
	delete(w.light_all)
	delete(w.light_free)
	delete(w.changed)
	delete(w.cells)
	delete(w.holes)
	w^ = {}
}

// world_block reads one block for physics (game.Block_Query); not loaded
// where the chunk has not arrived.
world_block :: proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
	c := world_get((^World)(data), game.chunk_of(p))
	if c == nil {return .Air, false}
	return game.chunk_get(&c.blocks, game.local_of(p)), true
}

world_get :: proc(w: ^World, pos: game.Chunk_Pos) -> ^Client_Chunk {
	h, ok := w.by_pos[pos]
	if !ok {return nil}
	return base.pool_get(&w.chunks, h)
}

// world_set_chunk stores a chunk from the server (blocks from the decoder's
// scratch array unless uniform).
world_set_chunk :: proc(w: ^World, m: game.Chunk_Message, scratch: ^game.Block_Array) -> bool {
	h, exists := w.by_pos[m.pos]
	c: ^Client_Chunk
	if exists {
		c = base.pool_get(&w.chunks, h)
		game.chunk_release(&c.blocks, &w.arrays)
	} else {
		column, has_column := &w.columns[[2]i32{m.pos.x, m.pos.z}]
		if !has_column {
			log.errorf("client chunk before its column pos=%v", m.pos)
			return false
		}
		column.chunks += 1
		added: bool
		h, c, added = base.pool_add(&w.chunks, Client_Chunk{pos = m.pos})
		if !added {
			log.errorf("client no room for chunk pos=%v loaded=%d", m.pos, w.chunks.count)
			return false
		}
		w.by_pos[m.pos] = h
	}
	if m.is_uniform {
		c.blocks = {
			uniform = m.uniform,
		}
	} else {
		array, err := game.block_arrays_take(&w.arrays)
		if err != nil {
			log.errorf("client out of chunk arrays (%v)", err)
			return false
		}
		array^ = scratch^
		c.blocks = {
			array = array,
		}
	}
	c.version = w.next_version
	c.blocks_version = w.next_version
	w.next_version += 1
	c.dirty, c.geometry = true, true
	if w.batch_left > 0 {
		append(&w.batch, m.pos)
		w.batch_left -= 1
		if w.batch_left == 0 {group_open(w)}
	}
	// It, and neighbours whose border it is, may now be complete. A changed
	// chunk also makes its meshed neighbours stale.
	for dz in i32(-1) ..= 1 {
		for dy in i32(-1) ..= 1 {
			for dx in i32(-1) ..= 1 {
				n := world_get(w, m.pos + {dx, dy, dz})
				if n == nil {continue}
				if exists {
					// Its mesh was made from the old blocks here: a result still
					// on its way is stale too (border faces, light).
					if n.meshes > 0 {w.stats.dirtied_resent += 1}
					n.dirty, n.geometry = true, true
					n.version = w.next_version
					w.next_version += 1
				}
				queue_if_complete(w, n)
			}
		}
	}
	return true
}

// world_set_block changes one block (an edit, predicted or confirmed) and
// records it: the chunks whose meshes it touches are dirtied and meshed by
// the next world_changes_settle, once however many blocks changed in them.
// False if its chunk is not loaded.
world_set_block :: proc(w: ^World, p: game.Block_Pos, b: game.Block) -> bool {
	c := world_get(w, game.chunk_of(p))
	if c == nil {return false}
	local := game.local_of(p)
	old := game.chunk_get(&c.blocks, local)
	if old == b {return true}
	if c.blocks.array != nil && game.block_arrays_holders(&w.arrays, c.blocks.array) > 1 {
		// A mesh job reads it: write a copy, the job keeps the old.
		fresh, err := game.block_arrays_take(&w.arrays)
		if err != nil {
			log.error("client out of chunk arrays for an edit")
			return false
		}
		fresh^ = c.blocks.array^
		game.block_arrays_give(&w.arrays, c.blocks.array)
		c.blocks.array = fresh
	}
	if game.chunk_set(&c.blocks, &w.arrays, local, b) != nil {
		log.error("client out of chunk arrays for an edit")
		return false
	}
	c.blocks_version = w.next_version
	w.next_version += 1
	// Light reaches 15 blocks: everything that close may be lit differently;
	// within a block, its geometry changed.
	append(&w.changed, [2]game.Block_Pos{p - game.LIGHT_MAX, p + game.LIGHT_MAX})
	append(&w.cells, p)
	if opens_hole(&w.reg.blocks, old, b) {append(&w.holes, p)}
	predict_column_top(w, p, b)
	return true
}

// opens_hole: a cell going from old to new could show a see-through hole
// until its chunk is meshed again: old drew opaque or cutout faces (they
// hid what is behind, and the faces around it were culled against it), and
// it holds something else now. Blocks appearing, and water (translucent)
// changing, never do: at worst they show a frame late.
opens_hole :: proc(t: ^game.Block_Table, old, new: game.Block) -> bool {
	if old == new {return false}
	d := t.defs[old]
	return d.render != .None && d.layer != .Translucent
}

// world_changes_settle absorbs the block changes since the last call: each
// chunk they reach is dirtied once (the union of their light boxes: lit
// again, and meshed again if its light or geometry changed), those within a
// block of a changed cell are marked to be meshed whatever their light, and
// those whose geometry could show a hole (opens_hole), within a block of
// such a cell, are meshed on this thread at once, at most URGENT_TASKS of
// them; the rest are meshed by the workers, those first. Called after
// messages are received and after predictions, before world_update.
world_changes_settle :: proc(w: ^World) {
	if len(w.changed) == 0 && len(w.holes) == 0 && len(w.cells) == 0 {return}
	base.profile_scope("settle block changes")
	defer {
		clear(&w.changed)
		clear(&w.holes)
		clear(&w.cells)
	}
	w.settles += 1
	last: [2]game.Chunk_Pos
	for box, i in w.changed {
		a, b := game.chunk_of(box[0]), game.chunk_of(box[1])
		if i > 0 && last == {a, b} {continue} 	// the same chunks as the one before
		last = {a, b}
		b.y = min(b.y, game.CHUNK_MAX_Y - 1)
		a.y = max(a.y, game.CHUNK_MIN_Y)
		for cy in a.y ..= b.y {
			for cz in a.z ..= b.z {
				for cx in a.x ..= b.x {
					n := world_get(w, {cx, cy, cz})
					if n == nil || n.settled == w.settles {continue}
					n.settled = w.settles
					if n.meshes > 0 {w.stats.relit_edit += 1}
					if n.meshes > 0 && !n.dirty {n.edited = true} 	// (dirty already: meshed again for something else)
					n.dirty = true
					n.version = w.next_version // a mesh being made now is stale
					w.next_version += 1
					queue_if_complete(w, n)
				}
			}
		}
	}
	// Geometry changes only within a block of a cell: those chunks (all of
	// them dirtied above) are meshed whatever their light.
	last_cell: [2]game.Chunk_Pos
	for p, i in w.cells {
		a, z := game.chunk_of(p - 1), game.chunk_of(p + 1)
		if i > 0 && last_cell == {a, z} {continue}
		last_cell = {a, z}
		for cy in a.y ..= z.y {
			for cz in a.z ..= z.z {
				for cx in a.x ..= z.x {
					if n := world_get(w, {cx, cy, cz}); n != nil {n.geometry = true}
				}
			}
		}
	}
	// Holes, within a block of a cell: those chunks, once each.
	for p in w.holes {
		a, z := game.chunk_of(p - 1), game.chunk_of(p + 1)
		for cy in a.y ..= z.y {
			for cz in a.z ..= z.z {
				for cx in a.x ..= z.x {
					n := world_get(w, {cx, cy, cz})
					if n == nil || n.checked == w.settles {continue}
					n.checked = w.settles
					// (On the main thread, within the frame: an edit never
					// shows a hole.) Past the budget: the workers', first.
					if !mesh_now(w, {cx, cy, cz}) {n.hurry = true}
				}
			}
		}
	}
}

// mesh_now meshes a chunk on this thread with a reserved task; its result
// is uploaded by the next world_apply like any other. Without a free
// reserved task it stays queued for the workers (false).
mesh_now :: proc(w: ^World, pos: game.Chunk_Pos) -> bool {
	h, ok := w.by_pos[pos]
	if !ok || len(w.urgent_tasks) == 0 || !neighbours_present(w, pos) {return false}
	base.profile_scope("mesh now (block changed)")
	c := base.pool_get(&w.chunks, h)
	task := pop(&w.urgent_tasks)
	w.stats.meshed_now += 1
	c.hurry = false
	c.geometry = true // (meshed now: whatever its light)
	task_start(w, task, h, c)
	mesh_task_run(task)
	append(&w.uploads, task)
	return true
}

// task_free returns a task to its free list.
@(private)
task_free :: proc(w: ^World, task: ^Mesh_Task) {
	for &c in task.chunks {
		if c.array != nil {game.block_arrays_give(&w.arrays, c.array)}
		c = {}
	}
	append(&w.urgent_tasks if task.urgent else &w.free_tasks, task)
}

// world_set_column stores a column's heights from the server, re-meshing
// where they changed (sky light below a top that moved).
world_set_column :: proc(w: ^World, m: game.Column) {
	column, existed := &w.columns[m.pos]
	if !existed {
		w.columns[m.pos] = {
			heights = m.heights,
		}
		return
	}
	for h, i in m.heights {
		old := column.heights[i]
		if old == h {continue}
		x := m.pos.x * game.CHUNK_SIZE + i32(i % game.CHUNK_SIZE)
		z := m.pos.y * game.CHUNK_SIZE + i32(i / game.CHUNK_SIZE)
		remesh_box(
			w,
			{x, min(old, h), z} - game.LIGHT_MAX,
			{x, max(old, h), z} + game.LIGHT_MAX,
			&w.stats.dirtied_column,
		)
	}
	column.heights = m.heights
}

// predict_column_top updates p's column height for a predicted edit (the
// server's Column has the last word).
@(private = "file")
predict_column_top :: proc(w: ^World, p: game.Block_Pos, b: game.Block) {
	column, ok := &w.columns[[2]i32{p.x >> game.CHUNK_SHIFT, p.z >> game.CHUNK_SHIFT}]
	if !ok {return}
	i := int(p.x & game.CHUNK_MASK) + int(p.z & game.CHUNK_MASK) * game.CHUNK_SIZE
	old := column.heights[i]
	top := game.column_top_after(game.Block_Query{w, world_block, &w.reg.blocks}, old, p, b, nil)
	if top == old {return}
	column.heights[i] = top
	append(
		&w.changed,
		[2]game.Block_Pos {
			{p.x, min(old, top), p.z} - game.LIGHT_MAX,
			{p.x, max(old, top), p.z} + game.LIGHT_MAX,
		},
	)
}

// world_clear drops every chunk and column (travelling: none of them is
// in the next world); their meshes go with the next world_apply.
world_clear :: proc(w: ^World) {
	positions := make([dynamic]game.Chunk_Pos, 0, len(w.by_pos), context.temp_allocator)
	for pos in w.by_pos {append(&positions, pos)}
	for pos in positions {world_remove_chunk(w, pos)}
	clear(&w.columns)
	clear(&w.groups)
	w.batch_left = 0
}

// remesh_box re-meshes every loaded chunk that overlaps the box.
@(private = "file")
remesh_box :: proc(w: ^World, lo, hi: game.Block_Pos, counter: ^int) {
	a, b := game.chunk_of(lo), game.chunk_of(hi)
	b.y = min(b.y, game.CHUNK_MAX_Y - 1)
	a.y = max(a.y, game.CHUNK_MIN_Y)
	for cy in a.y ..= b.y {
		for cz in a.z ..= b.z {
			for cx in a.x ..= b.x {
				n := world_get(w, {cx, cy, cz})
				if n == nil {continue}
				if n.meshes > 0 && !n.dirty {counter^ += 1}
				n.dirty = true
				n.version = w.next_version // a mesh being made now is stale
				w.next_version += 1
				queue_if_complete(w, n)
			}
		}
	}
}

world_remove_chunk :: proc(w: ^World, pos: game.Chunk_Pos) {
	h, ok := w.by_pos[pos]
	if !ok {return}
	c := base.pool_get(&w.chunks, h)
	if c.mesh != 0 {append(&w.mesh_removals, c.mesh)}
	if c.pending != 0 {append(&w.mesh_removals, c.pending)}
	game.chunk_release(&c.blocks, &w.arrays)
	light_release(w, c)
	delete_key(&w.by_pos, pos)
	column := &w.columns[[2]i32{pos.x, pos.z}]
	column.chunks -= 1
	if column.chunks <= 0 {delete_key(&w.columns, [2]i32{pos.x, pos.z})}
	base.pool_remove(&w.chunks, h) // queued work for it is dropped as stale
}

@(private)
queue_if_complete :: proc(w: ^World, c: ^Client_Chunk) {
	if c.queued || !c.dirty || !neighbours_present(w, c.pos) {return}
	c.queued = true
	append(&w.to_mesh, w.by_pos[c.pos])
}

// world_mesh_idle: no mesh job is running and none waits for its upload (every
// task is back in its free list): the registry may be swapped.
world_mesh_idle :: proc(w: ^World) -> bool {
	return len(w.free_tasks) + len(w.urgent_tasks) == len(w.tasks)
}

// world_remesh_all makes every loaded chunk mesh again (the registry changed:
// textures, light, shapes). Its old mesh stays until the new one replaces it.
world_remesh_all :: proc(w: ^World) {
	for _, h in w.by_pos {
		c := base.pool_get(&w.chunks, h)
		if c == nil {continue}
		c.dirty, c.geometry = true, true
		light_release(w, c) // (light may be another now)
		c.version = w.next_version
		w.next_version += 1
		queue_if_complete(w, c)
	}
}

// world_update settles the frame's block changes and starts mesh jobs for
// waiting chunks, nearest to the camera first. Runs every frame, also when nothing is drawn.
world_update :: proc(w: ^World, camera_chunk: game.Chunk_Pos) {
	world_changes_settle(w) // what this frame's predictions changed
	base.profile_scope("start meshing")
	if len(w.to_mesh) > len(w.free_tasks) {
		// More waiting than can start: a bulk edit's first, then the nearest.
		Sort :: struct {
			w:      ^World,
			camera: game.Chunk_Pos,
		}
		context.user_ptr = &Sort{w, camera_chunk}
		slice.sort_by(
			w.to_mesh[:],
			proc(a, b: Chunk_Handle) -> bool {
				s := (^Sort)(context.user_ptr)
				ca, cb := base.pool_get(&s.w.chunks, a), base.pool_get(&s.w.chunks, b)
				if ca == nil || cb == nil {return ca == nil && cb != nil} 	// stale first: dropped right away
				// A hole a block change opened first, then a bulk edit's
				// chunks (it is shown when all are done), then the nearest.
				if ca.hurry != cb.hurry {return ca.hurry}
				if (ca.group != 0) != (cb.group != 0) {return ca.group != 0}
				return(
					game.chunk_distance_sq(ca.pos, s.camera) <
					game.chunk_distance_sq(cb.pos, s.camera) \
				)
			},
		)
	}
	started := 0
	for started < len(w.to_mesh) && len(w.free_tasks) > 0 {
		h := w.to_mesh[started]
		started += 1
		c := base.pool_get(&w.chunks, h)
		if c == nil {continue} 	// unloaded meanwhile
		c.queued = false
		if !c.dirty {continue} 	// meshed meanwhile (an edit, on the spot)
		if !neighbours_present(w, c.pos) {continue} 	// a neighbour left; requeued when it returns
		if trivially_empty(w, c) {
			if c.group != 0 {
				// Nothing to draw, once its group is shown.
				if c.pending != 0 {append(&w.mesh_removals, c.pending)}
				c.pending, c.waiting = 0, true
			} else {
				if c.mesh != 0 {append(&w.mesh_removals, c.mesh)}
				c.mesh = 0
			}
			c.dirty, c.geometry, c.edited = false, false, false
			light_release(w, c)
			continue
		}
		c.queued, c.hurry = true, false
		task := pop(&w.free_tasks)
		task_start(w, task, h, c)
		base.jobs_submit(&w.jobs, mesh_job, task)
	}
	remove_range(&w.to_mesh, 0, started)
	w.stats.mesh_jobs_busy = len(w.tasks) - URGENT_TASKS - len(w.free_tasks)
}

// world_bulk_begin: the next count chunks are one bulk edit's.
world_bulk_begin :: proc(w: ^World, count: int) {
	clear(&w.batch)
	w.batch_left = min(count, MAX_GROUP_MEMBERS)
	w.batch_since = w.next_version
}

// group_since: the first chunk version of group id's bulk edit.
@(private = "file")
group_since :: proc(w: ^World, id: u32) -> u32 {
	for &g in w.groups {if g.id == id {return g.since}}
	return max(u32)
}

// group_open makes a group of the batch's chunks and their neighbours.
@(private = "file")
group_open :: proc(w: ^World) {
	defer clear(&w.batch)
	if len(w.groups) == MAX_GROUPS {return} 	// too many at once: shown as they come
	w.next_group += 1
	g := Mesh_Group {
		id     = w.next_group,
		opened = time.tick_now(),
		since  = w.batch_since,
	}
	for pos in w.batch {
		for dz in i32(-1) ..= 1 {
			for dy in i32(-1) ..= 1 {
				for dx in i32(-1) ..= 1 {
					h, ok := w.by_pos[pos + {dx, dy, dz}]
					if !ok || g.count == MAX_GROUP_MEMBERS {continue}
					c := base.pool_get(&w.chunks, h)
					if c.group == g.id {continue}
					c.group = g.id
					g.members[g.count] = h
					g.count += 1
				}
			}
		}
	}
	append(&w.groups, g)
}

// groups_update shows each group whose chunks all have their new meshes
// (uploaded hidden as they came), or that waited past the timeout: in one
// frame, the new meshes replace the old.
@(private = "file")
groups_update :: proc(w: ^World, pass: ^render.World_Pass, g: ^gpu.Gpu) {
	for i := 0; i < len(w.groups); {
		grp := &w.groups[i]
		ready := true
		for h in grp.members[:grp.count] {
			c := base.pool_get(&w.chunks, h)
			if c == nil || c.group != grp.id {continue}
			if c.waiting {continue} 	// its new mesh is here
			// One that cannot be meshed (a neighbour beyond the view) has
			// nothing coming: not waited for.
			if c.queued || (c.dirty && neighbours_present(w, c.pos)) {
				ready = false
				break
			}
		}
		late := !ready && time.tick_since(grp.opened) > GROUP_TIMEOUT
		if !ready && !late {
			i += 1
			continue
		}
		if late {w.stats.groups_late += 1} else {w.stats.groups_shown += 1}
		base.metric_add(.Edit_Shown, f32(time.duration_milliseconds(time.tick_since(grp.opened))))
		for h in grp.members[:grp.count] {
			c := base.pool_get(&w.chunks, h)
			if c == nil || c.group != grp.id {continue}
			c.group = 0
			if !c.waiting {continue}
			if c.mesh != 0 {render.world_remove_mesh(pass, g, c.mesh)}
			c.mesh = c.pending
			if c.mesh != 0 {render.world_show_mesh(pass, c.mesh)}
			c.pending, c.waiting = 0, false
		}
		ordered_remove(&w.groups, i)
	}
}

// replace_mesh puts a chunk's new mesh (0: none) in place, or, while its
// group waits, beside the old one, hidden.
@(private = "file")
replace_mesh :: proc(
	w: ^World,
	pass: ^render.World_Pass,
	g: ^gpu.Gpu,
	c: ^Client_Chunk,
	mesh: render.Mesh_Handle,
) {
	if c.group != 0 {
		if c.pending != 0 {render.world_remove_mesh(pass, g, c.pending)}
		c.pending, c.waiting = mesh, true
		return
	}
	if c.mesh != 0 {render.world_remove_mesh(pass, g, c.mesh)}
	c.mesh = mesh
}

// world_apply uploads finished meshes and removes old ones; call between
// render.world_begin and world_draw. Meshes that don't fit in this frame's
// staging wait for the next.
world_apply :: proc(w: ^World, pass: ^render.World_Pass, g: ^gpu.Gpu) {
	base.profile_scope("apply meshes")
	for h in w.mesh_removals {render.world_remove_mesh(pass, g, h)}
	clear(&w.mesh_removals)
	waiting := len(w.uploads)
	base.queue_drain(&w.done, &w.uploads)
	for task in w.uploads[waiting:] {base.frame_stats_add(&w.stats.mesh_times, task.ms)}
	defer groups_update(w, pass, g)
	kept := 0
	for task, i in w.uploads {
		c, for_group, ok := task_take(w, task)
		if !ok {continue}
		mesh: render.Mesh_Handle
		failed := false
		if len(task.vertices) > 0 {
			bytes := slice.to_bytes(task.vertices[:])
			counts: render.Mesh_Counts
			for groups, l in task.counts {
				for n, group in groups {counts[render.Mesh_Layer(l)][group] = u32(n)}
			}
			result: render.Upload_Result
			mesh, result = render.world_add_mesh(
				pass,
				g,
				c.pos,
				bytes,
				counts,
				hidden = c.group != 0,
			)
			if result == .Busy {
				// Keep this and everything after it for the next frame.
				copy(w.uploads[kept:], w.uploads[i:])
				kept += len(w.uploads) - i
				break
			}
			failed = result != .Ok
		}
		if !failed {replace_mesh(w, pass, g, c, mesh)}
		task_meshed(w, c, task, for_group)
	}
	resize(&w.uploads, kept)
}

// task_take judges a finished task: unloaded or changed while being meshed
// (flowing water into a crater) and it is dropped and the chunk meshed
// again; lit the same, and the chunk keeps its mesh (and the new key);
// otherwise ok: its mesh is to be put in place (then task_meshed). For a
// bulk edit's chunk still without its new mesh, one made since the edit is
// shown with it all the same (for_group; it is meshed again after).
@(private)
task_take :: proc(w: ^World, task: ^Mesh_Task) -> (c: ^Client_Chunk, for_group, ok: bool) {
	c = base.pool_get(&w.chunks, task.handle)
	for_group =
		c != nil &&
		c.version != task.version &&
		c.group != 0 &&
		!c.waiting &&
		task.meshed &&
		task.version >= group_since(w, c.group)
	// (Lit the same, but its cache dropped meanwhile: nothing to keep it by.)
	if c == nil || (c.version != task.version && !for_group) || (!task.meshed && c.light == nil) {
		w.stats.stale_meshes += 1
		task_free(w, task)
		if c != nil {
			c.geometry ||= task.geometry // (what it had to mesh, it still has to)
			c.edited ||= task.edited
			c.queued = false
			queue_if_complete(w, c)
		}
		return nil, false, false
	}
	if !task.meshed {
		w.stats.unchanged += 1
		c.light.key = task.key
		c.dirty, c.queued = false, false
		task_free(w, task)
		return nil, false, false
	}
	return c, for_group, true
}

// task_meshed finishes a chunk's task once its mesh is in place: the light
// it was made with is kept, and the chunk is clean (or, for_group, meshed
// again).
@(private)
task_meshed :: proc(w: ^World, c: ^Client_Chunk, task: ^Mesh_Task, for_group: bool) {
	if c.light == nil {c.light = light_take(w)}
	c.light^ = {
		key   = task.key,
		light = task.light,
	}
	c.dirty, c.queued = for_group, false
	if for_group {queue_if_complete(w, c)}
	w.stats.meshed += 1
	if task.again {w.stats.remeshed += 1}
	if task.edited {w.stats.dirtied_edit += 1}
	task_free(w, task)
}

// world_remove_all_meshes schedules every mesh for removal (session end).
world_remove_all_meshes :: proc(w: ^World) {
	it: base.Pool_Iterator
	for c in base.pool_next(&w.chunks, &it) {
		if c.mesh != 0 {append(&w.mesh_removals, c.mesh)}
		if c.pending != 0 {append(&w.mesh_removals, c.pending)}
		c.mesh, c.pending = 0, 0
	}
}

// neighbours_present: every chunk around pos (the world's edges count) is here.
neighbours_present :: proc(w: ^World, pos: game.Chunk_Pos) -> bool {
	for dz in i32(-1) ..= 1 {
		for dy in i32(-1) ..= 1 {
			for dx in i32(-1) ..= 1 {
				if neighbour_blocks(w, pos + {dx, dy, dz}) == nil {return false}
			}
		}
	}
	return true
}

// Outside the world's height bounds: air above, bedrock below (never sent).
@(private = "file", rodata)
ABOVE_WORLD := game.Chunk_Blocks {
	uniform = .Air,
}
@(private = "file", rodata)
BELOW_WORLD := game.Chunk_Blocks {
	uniform = .Bedrock,
}

// neighbour_blocks: a chunk's blocks, whether loaded or outside the world;
// nil if it should exist but has not arrived.
@(private = "file")
neighbour_blocks :: proc(w: ^World, pos: game.Chunk_Pos) -> ^game.Chunk_Blocks {
	if pos.y >= game.CHUNK_MAX_Y {return &ABOVE_WORLD}
	if pos.y < game.CHUNK_MIN_Y {return &BELOW_WORLD}
	c := world_get(w, pos)
	return &c.blocks if c != nil else nil
}

// trivially_empty: nothing to draw without meshing: all air, or solid all
// the way through with solid chunks on all six sides.
@(private)
trivially_empty :: proc(w: ^World, c: ^Client_Chunk) -> bool {
	if c.blocks.array != nil {return false}
	if c.blocks.uniform == .Air {return true} 	// (a uniform chunk of another non-solid block, water, has faces)
	for d in ([6]game.Chunk_Pos{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
		n := neighbour_blocks(w, c.pos + d)
		if n.array != nil || !game.block_opaque(&w.reg.blocks, n.uniform) {return false}
	}
	return true
}

// task_start hands chunk c's next mesh to task: what meshing needs (copies:
// the job never touches the live world), the light its mesh was made with,
// and whether it must be meshed whatever its light.
@(private = "file")
task_start :: proc(w: ^World, task: ^Mesh_Task, h: Chunk_Handle, c: ^Client_Chunk) {
	task.handle, task.version, task.pos = h, c.version, c.pos
	task.again = c.meshes > 0
	c.meshes += 1
	task_fill(w, task, c.pos)
	task.has_old = c.light != nil
	task.reuse = task.has_old && c.light.key == task.key
	if task.has_old {task.old = c.light.light}
	task.geometry = c.geometry || !task.has_old
	task.edited = c.edited
	c.geometry, c.edited = false, false
	if task.reuse {w.stats.light_reused += 1}
}

// task_fill copies what meshing pos needs: its neighbourhood's blocks and
// the column heights around it, and the key of light's inputs.
@(private)
task_fill :: proc(w: ^World, task: ^Mesh_Task, pos: game.Chunk_Pos) {
	versions: [27]u32 // (0 outside the world: its blocks never change)
	for i in 0 ..< 27 {
		d := game.Chunk_Pos{i32(i % 3) - 1, i32(i / 3 % 3) - 1, i32(i / 9) - 1}
		src: ^game.Chunk_Blocks
		if n := world_get(w, pos + d); n != nil {
			versions[i] = n.blocks_version
			src = &n.blocks
		} else {
			src = neighbour_blocks(w, pos + d) // (the sky and the bedrock; nil if not here)
		}
		if src.array != nil {
			game.block_arrays_ref(&w.arrays, src.array)
			task.chunks[i] = {
				array = src.array,
			}
		} else {
			task.chunks[i] = {
				uniform = src.uniform,
			}
		}
	}
	task.light_in.origin = game.chunk_origin(pos)
	for dz in i32(-1) ..= 1 {
		for dx in i32(-1) ..= 1 {
			column := w.columns[{pos.x + dx, pos.z + dz}] // present: its chunks are
			for z in 0 ..< game.CHUNK_SIZE {
				for x in 0 ..< game.CHUNK_SIZE {
					rx, rz := int(dx + 1) * game.CHUNK_SIZE + x, int(dz + 1) * game.CHUNK_SIZE + z
					task.light_in.heights[rx + rz * game.LIGHT_REGION] =
						column.heights[x + z * game.CHUNK_SIZE]
				}
			}
		}
	}
	task.key = light_key(&versions, &task.light_in.heights)
}

// light_key: the key of a chunk's light inputs, its 27 chunks' block
// versions and the column heights around (never 0: no key).
@(private)
light_key :: proc(
	versions: ^[27]u32,
	heights: ^[game.LIGHT_REGION * game.LIGHT_REGION]i32,
) -> u64 {
	key := xxhash.XXH3_64(slice.to_bytes(versions[:]))
	key = xxhash.XXH3_64(slice.to_bytes(heights[:]), key)
	return max(key, 1)
}

// light_take: a light cache to fill (reused, or made).
@(private = "file")
light_take :: proc(w: ^World) -> ^Light_Cache {
	if l, ok := pop_safe(&w.light_free); ok {return l}
	l := new(Light_Cache, w.light_all.allocator)
	append(&w.light_all, l)
	return l
}

// light_release gives back a chunk's light cache (its blocks or what they
// are changed beyond what a key sees, or it has no mesh to keep light for).
@(private = "file")
light_release :: proc(w: ^World, c: ^Client_Chunk) {
	if c.light == nil {return}
	append(&w.light_free, c.light)
	c.light = nil
}

@(private = "file")
mesh_job :: proc(data: rawptr) {
	task := (^Mesh_Task)(data)
	if !base.jobs_stopping(&task.world.jobs) {mesh_task_run(task)}
	base.queue_push(&task.world.done, task)
}

// mesh_task_run lights a filled task (from the cache if its key matched),
// then meshes it unless its geometry and light are its mesh's (any thread).
@(private)
mesh_task_run :: proc(task: ^Mesh_Task) {
	start := time.tick_now()
	defer task.ms = f32(time.duration_milliseconds(time.tick_since(start)))
	if task.reuse {
		task.light = task.old
	} else {
		base.profile_scope("light chunk")
		base.metric_scope(.Light_Chunk)
		game.light_chunk(&task.light_in, &task.scratch, &task.light)
	}
	task.meshed = task.geometry || task.light != task.old
	clear(&task.vertices)
	if !task.meshed {return}
	base.profile_scope("mesh chunk")
	base.metric_scope(.Mesh_Chunk)
	base.metric_scope(.Mesh_Faces)
	n: mesh.Neighbourhood
	for &c, i in task.chunks {n[i] = &c}
	mesh.snapshot_fill(&task.snapshot, &n)
	task.counts = mesh.mesh_chunk(task.world.reg, &task.snapshot, &task.light, &task.vertices)
}
