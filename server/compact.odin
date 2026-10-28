package server

import "base:runtime"
import "core:slice"

import "../common/game"
import "../common/worldgen"

// Region compaction (M46b). A region's file holds the chunks edits left
// different from the generator's and the column tops that differ from its
// own. Edits get undone (a rollback, an undo, a redo), so as the save worker
// prepares each region it:
//
//   - generates again each chunk a rollback, undo or redo touched since the
//     region was written (World.revisit) and drops it if it is identical: it is
//     a natural chunk again;
//   - drops tops equal to the natural top;
//   - has the region deleted if nothing is left.
//
// When the batch commits, the server thread clears `modified` on the dropped
// chunks that are still as they were (compaction_apply). The world's state
// and hash never change: only what the file holds.

// Job_Chunk: one edited chunk of a region, its blocks encoded (heap).
Job_Chunk :: struct {
	pos:     game.Chunk_Pos,
	bytes:   []u8,
	dropped: bool, // the worker found it identical to the generator's
}

// Region_Job: a region as captured, for the worker (heap).
Region_Job :: struct {
	reg:          ^game.Registry,
	world:        game.Address,
	region:       game.Region_Pos,
	path:         string, // relative to the universe
	generation:   u64,
	chunks:       [dynamic]Job_Chunk,
	tops:         [dynamic]game.Saved_Top,
	revisit:      [dynamic]game.Chunk_Pos,
	gen:          worldgen.Generator, // a copy: the world's may change while this runs
	tops_dropped: [dynamic]game.Saved_Top, // the worker's result
}

region_job_free :: proc(j: ^Region_Job) {
	a := runtime.heap_allocator()
	for c in j.chunks {delete(c.bytes, a)}
	delete(j.chunks)
	delete(j.tops)
	delete(j.revisit)
	delete(j.tops_dropped)
	delete(j.path, a)
	free(j, a)
}

// region_job_run compacts and encodes j into b's files (or its deletions).
region_job_run :: proc(b: ^Save_Batch, j: ^Region_Job) {
	a := runtime.heap_allocator()
	cache: ^worldgen.Column_Cache
	defer if cache != nil {free(cache, a)}
	if len(j.revisit) > 0 || len(j.tops) > 0 {
		cache = new(worldgen.Column_Cache, a)
	}
	if len(j.revisit) > 0 {
		have := new(game.Block_Array, a)
		natural := new(game.Block_Array, a)
		defer free(have, a)
		defer free(natural, a)
		for &c in j.chunks {
			if !slice.contains(j.revisit[:], c.pos) {continue}
			r := game.reader_make(c.bytes, j.reg)
			u1, uni1 := game.read_chunk_blocks(&r, have)
			if !game.reader_finish(&r) {continue}
			u2, uni2 := worldgen.generate(&j.gen, c.pos, natural, cache)
			a_, b_ := game.Chunk_Blocks {
					uniform = u1,
				}, game.Chunk_Blocks {
					uniform = u2,
				}
			if !uni1 {a_.array = have}
			if !uni2 {b_.array = natural}
			if blocks_equal(&a_, &b_) {c.dropped = true}
		}
	}
	encoded := make([dynamic]game.Encoded_Chunk, a)
	defer delete(encoded)
	for c in j.chunks {
		if !c.dropped {append(&encoded, game.Encoded_Chunk{c.pos, c.bytes})}
	}
	tops := make([dynamic]game.Saved_Top, a)
	defer delete(tops)
	if len(j.tops) > 0 {
		natural := make(map[[2]i32]worldgen.Tops, a)
		defer delete(natural)
		for t in j.tops {
			column := [2]i32{t.x >> game.CHUNK_SHIFT, t.z >> game.CHUNK_SHIFT}
			if column not_in natural {
				out: worldgen.Tops
				worldgen.column_tops(&j.gen, column, &out, cache)
				natural[column] = out
			}
			if natural[column][(t.x & game.CHUNK_MASK) + (t.z & game.CHUNK_MASK) * game.CHUNK_SIZE] ==
			   t.top {
				append(&j.tops_dropped, t)
			} else {
				append(&tops, t)
			}
		}
	}
	// (map order varies: a region file is the same bytes whenever it is written)
	slice.sort_by(tops[:], proc(a, b: game.Saved_Top) -> bool {
		return a.z != b.z ? a.z < b.z : a.x < b.x
	})
	if len(encoded) == 0 && len(tops) == 0 {
		batch_delete(b, j.path)
		return
	}
	w: game.Writer
	game.writer_init(&w, a)
	defer game.writer_destroy(&w)
	game.region_encode_bytes(j.reg, &w, j.region, encoded[:], tops[:], j.generation)
	batch_stage(b, j.path, w.buf[:])
}

// blocks_equal: the same block at every position.
blocks_equal :: proc(x, y: ^game.Chunk_Blocks) -> bool {
	if x.array == nil && y.array == nil {return x.uniform == y.uniform}
	for i in 0 ..< game.CHUNK_VOLUME {
		l := game.local_from_index(i)
		if game.chunk_get(x, l) != game.chunk_get(y, l) {return false}
	}
	return true
}

// compaction_apply: the server's side once a batch committed. A dropped chunk
// that is as it was at the capture (loaded or not) is natural now.
compaction_apply :: proc(s: ^Server, b: ^Save_Batch) {
	for j in b.regions {
		w: ^World
		for x in s.worlds {if x.address == j.world {w = x}}
		if w == nil {continue}
		for c in j.chunks {
			if !c.dropped {continue}
			if saved, ok := w.saved[c.pos]; ok {
				if string(saved) == string(c.bytes) {
					delete(saved)
					delete_key(&w.saved, c.pos)
				}
			} else if chunk := chunks_get(&w.chunks, c.pos);
			   chunk != nil && chunk.state == .Ready {
				if chunk.modified && string(chunk_bytes(chunk)) == string(c.bytes) {
					chunk.modified = false
				}
			}
		}
		for t in j.tops_dropped {
			if top, ok := w.tops[{t.x, t.z}];
			   ok && top == t.top {delete_key(&w.tops, [2]i32{t.x, t.z})}
		}
	}
}

// chunk_bytes: c's blocks as saved (temp).
@(private = "file")
chunk_bytes :: proc(c: ^Chunk) -> []u8 {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	game.write_chunk_blocks(&w, &c.blocks)
	return w.buf[:]
}
