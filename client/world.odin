package client

import "core:log"
import "core:mem"
import "core:slice"

import "../base"
import "../game"
import "../gpu"
import "../render"
import "mesh"

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

Chunk_Handle :: distinct u32

Client_Chunk :: struct {
	pos:     game.Chunk_Pos,
	blocks:  game.Chunk_Blocks,
	version: u32, // bumped whenever blocks change
	mesh:    render.Mesh_Handle, // 0: no mesh (nothing visible, or not meshed yet)
	dirty:   bool, // its mesh does not match its blocks
	queued:  bool, // waiting in to_mesh or being meshed
}

World :: struct {
	chunks:        base.Pool(Client_Chunk, Chunk_Handle),
	by_pos:        map[game.Chunk_Pos]Chunk_Handle,
	arrays:        game.Block_Arrays,
	jobs:          base.Jobs,
	done:          base.Queue(^Mesh_Task), // from workers
	free_tasks:    [dynamic]^Mesh_Task,
	tasks:         []Mesh_Task,
	to_mesh:       [dynamic]Chunk_Handle, // complete and dirty, waiting for a task
	uploads:       [dynamic]^Mesh_Task, // meshed, waiting for staging room
	mesh_removals: [dynamic]render.Mesh_Handle,
	next_version:  u32,
	stats:         World_Stats,
}

World_Stats :: struct {
	meshed:         int, // chunks meshed in total
	stale_meshes:   int, // results dropped because the chunk changed or left
	mesh_jobs_busy: int,
}

@(private)
Mesh_Task :: struct {
	world:    ^World,
	handle:   Chunk_Handle,
	version:  u32,
	pos:      game.Chunk_Pos,
	snapshot: mesh.Snapshot,
	vertices: [dynamic]mesh.Vertex, // heap; keeps its capacity between uses
}

// MESH_TASKS_PER_WORKER: snapshots in flight per mesh worker.
@(private)
MESH_TASKS_PER_WORKER :: 4

// world_init sizes storage for capacity chunks. Long-lived storage comes
// from arena; whatever workers touch from heap.
world_init :: proc(
	w: ^World,
	capacity, workers: int,
	arena: mem.Allocator,
	heap := context.allocator,
) -> mem.Allocator_Error {
	w^ = {
		next_version = 1,
	}
	base.pool_init(&w.chunks, capacity, arena) or_return
	w.by_pos = base.map_make_fixed(map[game.Chunk_Pos]Chunk_Handle, capacity, arena) or_return
	game.block_arrays_init(&w.arrays, capacity, arena) or_return
	w.to_mesh = make([dynamic]Chunk_Handle, 0, capacity, arena) or_return
	w.mesh_removals = make([dynamic]render.Mesh_Handle, 0, capacity, arena) or_return
	count := workers * MESH_TASKS_PER_WORKER
	w.tasks = make([]Mesh_Task, count, arena) or_return
	w.free_tasks = make([dynamic]^Mesh_Task, 0, count, arena) or_return
	w.uploads = make([dynamic]^Mesh_Task, 0, count, arena) or_return
	for &t in w.tasks {
		t.world = w
		t.vertices = make([dynamic]mesh.Vertex, heap)
		append(&w.free_tasks, &t)
	}
	base.queue_init(&w.done, heap)
	base.jobs_init(&w.jobs, "mesh", workers, heap)
	return nil
}

// world_destroy stops the workers and frees what is outside the arena. The
// caller removes meshes first (world_remove_all_meshes + world_apply).
world_destroy :: proc(w: ^World) {
	base.jobs_destroy(&w.jobs)
	base.queue_destroy(&w.done)
	for &t in w.tasks {delete(t.vertices)}
	game.block_arrays_destroy(&w.arrays)
	w^ = {}
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
	w.next_version += 1
	c.dirty = true
	// It, and neighbours whose border it is, may now be complete. A changed
	// chunk also makes its meshed neighbours stale.
	for dz in i32(-1) ..= 1 {
		for dy in i32(-1) ..= 1 {
			for dx in i32(-1) ..= 1 {
				n := world_get(w, m.pos + {dx, dy, dz})
				if n == nil {continue}
				if exists {n.dirty = true}
				queue_if_complete(w, n)
			}
		}
	}
	return true
}

world_remove_chunk :: proc(w: ^World, pos: game.Chunk_Pos) {
	h, ok := w.by_pos[pos]
	if !ok {return}
	c := base.pool_get(&w.chunks, h)
	if c.mesh != 0 {append(&w.mesh_removals, c.mesh)}
	game.chunk_release(&c.blocks, &w.arrays)
	delete_key(&w.by_pos, pos)
	base.pool_remove(&w.chunks, h) // queued work for it is dropped as stale
}

@(private = "file")
queue_if_complete :: proc(w: ^World, c: ^Client_Chunk) {
	if c.queued || !c.dirty || !neighbours_present(w, c.pos) {return}
	c.queued = true
	append(&w.to_mesh, w.by_pos[c.pos])
}

// world_update starts mesh jobs for waiting chunks, nearest to the camera
// first. Runs every frame, also when nothing is drawn.
world_update :: proc(w: ^World, camera_chunk: game.Chunk_Pos) {
	base.profile_scope("start meshing")
	if len(w.to_mesh) > len(w.free_tasks) {
		// More waiting than can start: start the nearest.
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
		if !neighbours_present(w, c.pos) {continue} 	// a neighbour left; requeued when it returns
		if trivially_empty(w, c) {
			if c.mesh != 0 {append(&w.mesh_removals, c.mesh)}
			c.mesh = 0
			c.dirty = false
			continue
		}
		c.queued = true
		task := pop(&w.free_tasks)
		task.handle, task.version, task.pos = h, c.version, c.pos
		n: mesh.Neighbourhood
		for dz in i32(-1) ..= 1 {
			for dy in i32(-1) ..= 1 {
				for dx in i32(-1) ..= 1 {
					n[mesh.neighbour_index({dx, dy, dz})] = neighbour_blocks(
						w,
						c.pos + {dx, dy, dz},
					)
				}
			}
		}
		mesh.snapshot_fill(&task.snapshot, &n)
		base.jobs_submit(&w.jobs, mesh_job, task)
	}
	remove_range(&w.to_mesh, 0, started)
	w.stats.mesh_jobs_busy = len(w.tasks) - len(w.free_tasks)
}

// world_apply uploads finished meshes and removes old ones; call between
// render.world_begin and world_draw. Meshes that don't fit in this frame's
// staging wait for the next.
world_apply :: proc(w: ^World, pass: ^render.World_Pass, g: ^gpu.Gpu) {
	base.profile_scope("apply meshes")
	for h in w.mesh_removals {render.world_remove_mesh(pass, g, h)}
	clear(&w.mesh_removals)
	base.queue_drain(&w.done, &w.uploads)
	kept := 0
	for task, i in w.uploads {
		c := base.pool_get(&w.chunks, task.handle)
		if c == nil || c.version != task.version {
			// Unloaded, or changed while being meshed: mesh it again.
			w.stats.stale_meshes += 1
			append(&w.free_tasks, task)
			if c != nil {
				c.queued = false
				queue_if_complete(w, c)
			}
			continue
		}
		if len(task.vertices) == 0 {
			if c.mesh != 0 {render.world_remove_mesh(pass, g, c.mesh)}
			c.mesh, c.dirty, c.queued = 0, false, false
			w.stats.meshed += 1
			append(&w.free_tasks, task)
			continue
		}
		bytes := slice.to_bytes(task.vertices[:])
		h, result := render.world_add_mesh(pass, g, c.pos, bytes)
		if result == .Busy {
			// Keep this and everything after it for the next frame.
			copy(w.uploads[kept:], w.uploads[i:])
			kept += len(w.uploads) - i
			break
		}
		if result == .Ok {
			if c.mesh != 0 {render.world_remove_mesh(pass, g, c.mesh)}
			c.mesh = h
		}
		c.dirty, c.queued = false, false
		w.stats.meshed += 1
		append(&w.free_tasks, task)
	}
	resize(&w.uploads, kept)
}

// world_remove_all_meshes schedules every mesh for removal (session end).
world_remove_all_meshes :: proc(w: ^World) {
	it: base.Pool_Iterator
	for c in base.pool_next(&w.chunks, &it) {
		if c.mesh != 0 {append(&w.mesh_removals, c.mesh)}
		c.mesh = 0
	}
}

@(private = "file")
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
@(private = "file")
trivially_empty :: proc(w: ^World, c: ^Client_Chunk) -> bool {
	if c.blocks.array != nil {return false}
	if !game.block_solid(c.blocks.uniform) {return true}
	for d in ([6]game.Chunk_Pos{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
		n := neighbour_blocks(w, c.pos + d)
		if n.array != nil || !game.block_solid(n.uniform) {return false}
	}
	return true
}

@(private = "file")
mesh_job :: proc(data: rawptr) {
	task := (^Mesh_Task)(data)
	if !base.jobs_stopping(&task.world.jobs) {
		base.profile_scope("mesh chunk")
		mesh.mesh_chunk(&task.snapshot, &task.vertices)
	}
	base.queue_push(&task.world.done, task)
}
