package server

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"

import "common:game"
import "common:worldgen"

// Replay (docs/journal.md): the journal applied onto a snapshot of the world
// (a saved copy of its directory, or the generator) must give the world as it
// is. A write that bypassed the pipeline is the first entry whose `old` the
// replay does not hold, or a final difference; either is named.

Replay_Result :: struct {
	entries:  int, // applied
	chunks:   int, // touched
	live:     u64, // a hash of those chunks as the world has them
	replayed: u64, // ... as the replay has them
	problem:  string, // "" when it matches (temp allocator)
}

// journal_replay replays the entries made after age `since` onto the chunks
// of snapshot_dir ("": the generator's) and compares with the live world.
journal_replay :: proc(w: ^World, snapshot_dir: string, since: u64) -> (r: Replay_Result) {
	journal_flush(w)
	j := &w.journal
	entries := make([dynamic]game.Journal_Entry, context.temp_allocator)
	params := u64(0)
	if w.dir != "" {
		for seq in journal_segments(w) {
			seg, ok := segment_load(w, seq)
			if !ok {continue}
			for e in seg.entries {if e.age > since {append(&entries, e)}}
			for age in seg.params {if age > since && params == 0 {params = age}}
		}
	} else {
		for i := ring_oldest(j); i < j.head; i += 1 {
			if e := ring_at(j, i)^; e.age > since {append(&entries, e)}
		}
	}
	if params != 0 {
		r.problem = fmt.tprintf(
			"generator parameters changed at age %d: replay from after it",
			params,
		)
		return
	}
	held := make(map[game.Chunk_Pos]^game.Block_Array, 64, context.temp_allocator)
	regions := make(
		map[game.Region_Pos]map[game.Chunk_Pos]^game.Block_Array,
		4,
		context.temp_allocator,
	)
	for e, i in entries {
		pos := game.chunk_of(e.pos)
		blocks, have := held[pos]
		if !have {
			blocks = snapshot_chunk(w, snapshot_dir, pos, &regions)
			held[pos] = blocks
		}
		l := game.local_index(game.local_of(e.pos))
		if blocks[l] != e.old && r.problem == "" {
			r.problem = fmt.tprintf(
				"replay: entry %d at (%d, %d, %d) action %d (%v): expected old %s, found %s",
				i,
				e.pos.x,
				e.pos.y,
				e.pos.z,
				e.action,
				e.how,
				game.block_name(w.server.registry, e.old),
				game.block_name(w.server.registry, blocks[l]),
			)
		}
		blocks[l] = e.new
		r.entries += 1
	}
	order := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for pos in held {append(&order, pos)}
	slice.sort_by(order[:], game.chunk_pos_less)
	r.chunks = len(order)
	hl, hr := game.hasher_make(), game.hasher_make()
	for pos in order {
		replayed := held[pos]
		live, found := live_chunk(w, pos)
		if !found {
			if r.problem ==
			   "" {r.problem = fmt.tprintf("replay: chunk (%d, %d, %d) is not in the world", pos.x, pos.y, pos.z)}
			continue
		}
		rb := game.Chunk_Blocks {
			array = replayed,
		}
		lb := game.Chunk_Blocks {
			array = live,
		}
		game.hash_chunk(&hr, pos, &rb)
		game.hash_chunk(&hl, pos, &lb)
		if r.problem == "" {
			for i in 0 ..< game.CHUNK_VOLUME {
				if live[i] == replayed[i] {continue}
				p := game.chunk_origin(pos) + game.local_from_index(i)
				r.problem = fmt.tprintf(
					"replay differs in chunk (%d, %d, %d) at (%d, %d, %d): the world has %s, the replay %s",
					pos.x,
					pos.y,
					pos.z,
					p.x,
					p.y,
					p.z,
					game.block_name(w.server.registry, live[i]),
					game.block_name(w.server.registry, replayed[i]),
				)
				break
			}
		}
	}
	r.live, r.replayed = game.hasher_finish(hl), game.hasher_finish(hr)
	return
}

// snapshot_chunk: the chunk as the snapshot has it (a copy): from its region
// file in snapshot_dir, else generated.
@(private = "file")
snapshot_chunk :: proc(
	w: ^World,
	dir: string,
	pos: game.Chunk_Pos,
	regions: ^map[game.Region_Pos]map[game.Chunk_Pos]^game.Block_Array,
) -> ^game.Block_Array {
	if dir != "" {
		region := game.region_of(pos)
		if region not_in regions {regions[region] = read_snapshot_region(w, dir, region)}
		if blocks, ok := regions[region][pos]; ok {
			copy_ := new(game.Block_Array, context.temp_allocator)
			copy_^ = blocks^
			return copy_
		}
	}
	blocks := new(game.Block_Array, context.temp_allocator)
	gen := w.chunks.gen
	uniform, is_uniform := worldgen.generate(&gen, pos, blocks)
	if is_uniform {for &b in blocks {b = uniform}}
	return blocks
}

@(private = "file")
read_snapshot_region :: proc(
	w: ^World,
	dir: string,
	region: game.Region_Pos,
) -> map[game.Chunk_Pos]^game.Block_Array {
	chunks := make(map[game.Chunk_Pos]^game.Block_Array, 16, context.temp_allocator)
	name := fmt.tprintf("r.%d.%d.vxr", region.x, region.y)
	path :=
		filepath.join(
			{dir, WORLDS_DIR, game.address_dir(w.address), "regions", name},
			context.temp_allocator,
		) or_else name
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return chunks}
	r, open_err := game.region_open(w.server.registry, data, region)
	if open_err != .None {return chunks}
	entities := make([dynamic]game.Block_Entity, context.temp_allocator)
	for {
		scratch := new(game.Block_Array, context.temp_allocator)
		pos, uniform, is_uniform, got := game.region_next_chunk(&r, scratch, &entities)
		if !got {break}
		if is_uniform {for &b in scratch {b = uniform}}
		chunks[pos] = scratch
	}
	return chunks
}

// live_chunk: the world's blocks of a chunk, whether loaded or saved.
@(private = "file")
live_chunk :: proc(w: ^World, pos: game.Chunk_Pos) -> (blocks: ^game.Block_Array, found: bool) {
	out := new(game.Block_Array, context.temp_allocator)
	if c := chunks_get(&w.chunks, pos); c != nil && c.state == .Ready {
		for i in 0 ..< game.CHUNK_VOLUME {out[i] = game.chunk_get(&c.blocks, game.local_from_index(i))}
		return out, true
	}
	if bytes, saved := w.saved[pos]; saved {
		r := game.reader_make(bytes, w.server.registry)
		uniform, is_uniform := game.read_chunk_blocks(&r, out)
		if is_uniform {for &b in out {b = uniform}}
		return out, r.ok
	}
	return nil, false
}
