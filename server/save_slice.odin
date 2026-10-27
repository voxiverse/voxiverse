package server

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "../base"
import "../common/game"

// A save that does not stall the tick (M46b).
//
// A save must describe one tick (items move between inventories, chests and
// dropped stacks), yet encoding a large universe takes longer than a tick. So
// save_begin captures at tick T and the following ticks encode what was
// captured (save_slice), with copy-on-write for what can still change:
//
//   - At T: the small state is encoded at once (universe.cfg, each world's
//     world.cfg, entities, containers, protections, stats, permissions,
//     community); each dirty character's record is copied (without its
//     counters); each changed region is captured: its flag cleared, its
//     unloaded chunks' encoded bytes and its tops copied, its loaded edited
//     chunks marked with the save's id (Chunk.capture).
//   - Before a marked chunk changes or goes (chunks.odin: chunk_cow) its blocks
//     are copied into Chunk_Store.cow.
//   - Each slice encodes chunks, one by one, until SAVE_SLICE_US of the tick
//     is used; a region's chunks go to the save worker as a Region_Job
//     (compact.odin), which compacts and encodes the file.
//
// Counters may be a few seconds newer than the inventory beside them; that
// is the only part of a save not from T. Timing is the wall clock's, so how
// many ticks a save takes varies, but not what it writes nor any hashed state.

SAVE_SLICE_US :: 2000

// Cap_Region: a region captured, its loaded chunks still to be encoded.
Cap_Region :: struct {
	job:  ^Region_Job,
	live: [dynamic]game.Chunk_Pos, // marked chunks to encode
	next: int,
}

Cap_World :: struct {
	world:   ^World,
	regions: [dynamic]Cap_Region,
}

// Cap_Character: a dirty character as it was at T; its counters are read when it
// is encoded (the client's, else the store's).
Cap_Character :: struct {
	name:   string,
	rec:    Player_Record, // (its counters are not here)
	forget: bool, // not playing at T: its record leaves the store once written
}

Save_Job :: struct {
	id:         u32,
	batch:      ^Save_Batch,
	worlds:     [dynamic]Cap_World,
	characters: [dynamic]Cap_Character,
	wi, ri, ci: int, // the next world, region and character to encode
	writer:     game.Writer,
	wait:       bool, // finish with a blocking commit
	export:     bool, // the worker writes exports/g<generation>.vxu after the commit
	ok:         bool, // everything staged so far did
}

@(private = "file")
heap :: proc() -> runtime.Allocator {return runtime.heap_allocator()}

// save_begin captures the universe at this tick (only: one world's files
// alone). False if a save is being collected already.
save_begin :: proc(s: ^Server, only: ^World = nil, export := false) -> bool {
	st := &s.store
	if st.job != nil || !store_stage(s) {return false}
	st.serial += 1
	job := new(Save_Job, heap())
	job.id, job.ok, job.export = st.serial, true, export
	st.slice_worst_us = 0
	game.writer_init(&job.writer, heap())
	if only == nil {
		write_universe_file(s)
		permissions_save(s)
		community_save(s)
		characters_capture(s, job)
	}
	for w in s.worlds {
		if only != nil && w != only {continue}
		if !world_stage(w) {job.ok = false}
		world_capture(s, job, w)
	}
	job.batch = st.staging
	st.staging = nil
	st.job = job
	return true
}

@(private = "file")
characters_capture :: proc(s: ^Server, job: ^Save_Job) {
	for &c in s.clients {if c.state == .Playing {keep_player(s, &c)}}
	gone := make([dynamic]string, context.temp_allocator)
	for name, &r in s.store.players {
		online := client_by_name(s, name) != nil
		if r.dirty {
			rec := r
			rec.stats = nil
			append(&job.characters, Cap_Character{strings.clone(name, heap()), rec, !online})
			r.dirty = false
			if _, claimed := r.account.?; claimed {
				// Its file from before accounts is this one now.
				old := character_path(s, name, nil)
				if os.exists(old) {store_delete(s, old)}
			}
		} else if !online {
			append(&gone, name)
		}
	}
	for name in gone {
		if r, present := &s.store.players[name]; present {counters_free(&r.stats)}
		key, _ := delete_key(&s.store.players, name)
		delete(key)
	}
}

@(private = "file")
world_capture :: proc(s: ^Server, job: ^Save_Job, w: ^World) {
	if w.dir == "" {return}
	cw := Cap_World {
		world = w,
	}
	index := make(map[game.Region_Pos]int, context.temp_allocator)
	for region, changed in w.regions {
		if !changed {continue}
		w.regions[region] = false
		rj := new(Region_Job, heap())
		rj.world, rj.region, rj.gen = w.address, region, w.chunks.gen
		rj.generation = s.store.generation + 1
		rj.path = strings.clone(relative_path(s.store.dir, region_path(w.dir, region)), heap())
		index[region] = len(cw.regions)
		append(&cw.regions, Cap_Region{job = rj})
	}
	if len(cw.regions) == 0 {return}
	for pos, bytes in w.saved {
		if i, ok := index[game.region_of(pos)]; ok {
			append(
				&cw.regions[i].job.chunks,
				Job_Chunk{pos = pos, bytes = slice.clone(bytes, heap())},
			)
		}
	}
	cow := new(Cow, heap())
	cow.id = job.id
	cow.copies = make(map[game.Chunk_Pos]game.Chunk_Blocks, heap())
	w.chunks.cow = cow
	it: base.Pool_Iterator
	for c in base.pool_next(&w.chunks.chunks, &it) {
		if !c.modified || c.state != .Ready {continue}
		if i, ok := index[game.region_of(c.pos)]; ok {
			c.capture = job.id
			append(&cw.regions[i].live, c.pos)
		}
	}
	for column, top in w.tops {
		r := game.region_of({column.x >> game.CHUNK_SHIFT, 0, column.y >> game.CHUNK_SHIFT})
		if i, ok := index[r]; ok {
			append(&cw.regions[i].job.tops, game.Saved_Top{column.x, column.y, top})
		}
	}
	for pos in w.revisit {
		if i, ok := index[game.region_of(pos)]; ok {
			append(&cw.regions[i].job.revisit, pos)
		}
	}
	for r in cw.regions {for pos in r.job.revisit {delete_key(&w.revisit, pos)}}
	append(&job.worlds, cw)
}

// save_slice encodes captured items until SAVE_SLICE_US of this tick are used
// (all of them with no budget); commits when everything is encoded.
save_slice :: proc(s: ^Server, unlimited := false) -> bool {
	st := &s.store
	job := st.job
	if job == nil || (st.slice_hold && !unlimited) {return true}
	start := time.tick_now()
	// (the thread's CPU time, so a core taken by another thread is not the slice's cost)
	cpu := base.thread_cpu_us()
	defer st.slice_worst_us = max(st.slice_worst_us, base.thread_cpu_us() - cpu)
	for !job_encoded(job) {
		job_step(s, job)
		if !unlimited && time.duration_microseconds(time.tick_since(start)) >= SAVE_SLICE_US {
			return true
		}
	}
	return save_job_commit(s, job)
}

// save_finish runs the rest of the save at once, with no budget, and waits for
// it; false if it failed.
save_finish :: proc(s: ^Server) -> bool {
	st := &s.store
	job := st.job
	if job == nil {return save_wait(s)}
	job.wait = true
	ok := save_slice(s, unlimited = true)
	return save_wait(s) && ok
}

@(private = "file")
job_encoded :: proc(job: ^Save_Job) -> bool {
	return job.wi >= len(job.worlds) && job.ci >= len(job.characters)
}

@(private = "file")
job_step :: proc(s: ^Server, job: ^Save_Job) {
	if job.wi < len(job.worlds) {
		cw := &job.worlds[job.wi]
		if job.ri >= len(cw.regions) {
			job.wi, job.ri = job.wi + 1, 0
			return
		}
		cr := &cw.regions[job.ri]
		if cr.next < len(cr.live) {
			chunk_encode(job, cw, cr, cr.live[cr.next])
			cr.next += 1
			return
		}
		append(&job.batch.regions, cr.job)
		cr.job = nil
		job.ri += 1
		return
	}
	cc := &job.characters[job.ci]
	job.ci += 1
	st := &s.store
	rec := cc.rec
	if c := client_by_name(s, cc.name); c != nil {
		rec.stats = c.stats
	} else if r, ok := st.players[cc.name]; ok {
		rec.stats = r.stats
	}
	path := character_path(s, cc.name, rec.account)
	batch_stage(job.batch, relative_path(st.dir, path), player_json(&rec))
	if r, ok := &st.players[cc.name];
	   ok && cc.forget && !r.dirty && client_by_name(s, cc.name) == nil {
		counters_free(&r.stats)
		key, _ := delete_key(&st.players, cc.name)
		delete(key)
	}
	delete(cc.name, heap())
}

// chunk_encode: pos's blocks as at the capture (a copy-on-write copy, else the
// live chunk, still unchanged), into the region's job.
@(private = "file")
chunk_encode :: proc(job: ^Save_Job, cw: ^Cap_World, cr: ^Cap_Region, pos: game.Chunk_Pos) {
	blocks: ^game.Chunk_Blocks
	if copy, ok := &cw.world.chunks.cow.copies[pos]; ok {
		blocks = copy
	} else if c := chunks_get(&cw.world.chunks, pos);
	   c != nil && c.state == .Ready && c.capture == job.id {
		blocks = &c.blocks
	} else {
		log.errorf("server save lost a chunk it captured chunk=%v", pos)
		job.ok = false
		return
	}
	clear(&job.writer.buf)
	game.write_chunk_blocks(&job.writer, blocks)
	append(&cr.job.chunks, Job_Chunk{pos = pos, bytes = slice.clone(job.writer.buf[:], heap())})
}

// job_release ends the marks and copies of a save (everything is encoded, or
// it is given up).
@(private = "file")
job_release :: proc(s: ^Server, job: ^Save_Job) {
	for &cw in job.worlds {
		w := cw.world
		if w.chunks.cow == nil {continue}
		it: base.Pool_Iterator
		for c in base.pool_next(&w.chunks.chunks, &it) {
			if c.capture == job.id {c.capture = 0}
		}
		for _, blocks in w.chunks.cow.copies {
			if blocks.array != nil {free(blocks.array, heap())}
		}
		delete(w.chunks.cow.copies)
		free(w.chunks.cow, heap())
		w.chunks.cow = nil
	}
}

@(private = "file")
job_free :: proc(job: ^Save_Job) {
	for &cw in job.worlds {
		for &cr in cw.regions {if cr.job != nil {region_job_free(cr.job)}}
		for &cr in cw.regions {delete(cr.live)}
		delete(cw.regions)
	}
	delete(job.worlds)
	for &cc in job.characters[job.ci:] {delete(cc.name, heap())}
	delete(job.characters)
	game.writer_destroy(&job.writer)
	free(job, heap())
}

@(private = "file")
save_job_commit :: proc(s: ^Server, job: ^Save_Job) -> bool {
	st := &s.store
	job_release(s, job)
	st.job = nil
	st.staging = job.batch
	ok := job.ok
	wait := job.wait
	if job.export {
		name := fmt.tprintf("%s/g%d.vxu", EXPORTS_DIR, job.batch.generation)
		st.staging.export_to = strings.clone(full_path(st.dir, name), heap())
	}
	job.batch = nil
	if !ok {log.errorf("server save could not stage everything, it is committed as it is")}
	committed := store_commit(s, wait)
	log.infof("server saved worlds=%d dir=%s", len(s.worlds), st.dir)
	job_free(job)
	return ok && committed
}

// save_job_abandon gives up a save that never committed (the server is closing).
save_job_abandon :: proc(s: ^Server) {
	st := &s.store
	job := st.job
	if job == nil {return}
	st.job = nil
	live: [dynamic]^World
	defer delete(live)
	for w in s.worlds {append(&live, w)}
	kept := job.worlds
	job.worlds = {}
	for cw in kept {
		if slice.contains(live[:], cw.world) {
			append(&job.worlds, cw)
		} else {
			for cr in cw.regions {if cr.job != nil {region_job_free(cr.job)}}
			delete(cw.regions)
		}
	}
	delete(kept)
	job_release(s, job)
	if job.batch != nil {batch_free(job.batch)}
	job_free(job)
}

// save_collect captures and encodes everything at once, and leaves the batch,
// whole (its regions compacted and encoded), in Store.staging for the caller to
// run: the crash tests' way to hold one save.
save_collect :: proc(s: ^Server) -> bool {
	st := &s.store
	if !save_begin(s) {return false}
	job := st.job
	for !job_encoded(job) {job_step(s, job)}
	job_release(s, job)
	st.job = nil
	batch := job.batch
	job.batch = nil
	job_free(job)
	for j in batch.regions {
		region_job_run(batch, j)
		region_job_free(j)
	}
	clear(&batch.regions)
	st.staging = batch
	return true
}
