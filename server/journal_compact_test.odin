package server

import "core:fmt"
import "core:os"
import "core:testing"

import "../common/game"

// M45b: a segment older than the detail window is rewritten with one entry per
// run of changes of a block by one action; a rollback over compacted history
// puts back what a rollback over the detailed one does; retention deletes by
// age and by size.

COMPACT_SEGMENT :: 64 << 10
COMPACT_TICKS :: 120

compact_config :: proc(dir: string, detail, keep, most: u64) -> Config {
	c := grief_config(dir, segment = COMPACT_SEGMENT)
	c.journal_detail, c.journal_keep, c.journal_max_bytes = detail, keep, most
	return c
}

// compact_history changes 200 blocks three times a tick for COMPACT_TICKS ticks
// (one world action per tick: stone, dirt, then stone or air).
compact_history :: proc(g: ^Grief) {
	w := grief_world(g)
	for tick in 0 ..< COMPACT_TICKS {
		for pass in 0 ..< 3 {
			b := game.Block.Stone if pass == 0 else .Dirt
			if pass == 2 {b = .Stone if tick % 2 == 1 else .Air}
			for x in i32(0) ..< 10 {
				for z in i32(0) ..< 20 {
					set_block(w, at(g, x, 6, z), b, world_act(w, .Command))
				}
			}
		}
		run(g, 1)
	}
	g.h0 = 0
}

// segments_size: the bytes of a world's journal, and how many segments are compacted.
segments_size :: proc(w: ^World) -> (bytes: int, compacted: int, count: int) {
	for seq in journal_segments(w) {
		data, err := os.read_entire_file_from_path(segment_path(w, seq), context.temp_allocator)
		if err != nil {continue}
		bytes += len(data)
		count += 1
		if h, ok := segment_header_of(data);
		   ok && h.flags & game.JOURNAL_COMPACTED != 0 {compacted += 1}
	}
	return
}

segment_header_of :: proc(data: []u8) -> (game.Journal_Header, bool) {
	r := game.journal_read_segment(test_reg(), data, nil)
	return r.header, r.status != .Bad_Header
}

// compact_run: one session's history, a rollback of it, and the world after.
// detail 0: never compacted.
compact_run :: proc(
	t: ^testing.T,
	name: string,
	detail: u64,
) -> (
	before, after: u64,
	bytes, compacted: int,
	r: Rollback_Report,
) {
	dir := scratch_dir(name)
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir, compact_config(dir, detail if detail > 0 else 1 << 40, 0, 0))
	if !ok {grief_close(g); return}
	defer grief_close(g)
	before = world_hash_here(g)
	g.at = age_of(grief_srv(g))
	compact_history(g)
	run(g, 100)
	for _ in 0 ..< 8 {
		testing.expect(t, world_save(grief_world(g)))
		run(g, 2)
	}
	bytes, compacted, _ = segments_size(grief_world(g))
	testing.expect(t, world_hash_here(g) != before, "the history changed nothing")
	r = grief_rollback(g, "system command", "world")
	run(g, 60)
	after = world_hash_here(g)
	return
}

@(test)
test_journal_compacts :: proc(t: ^testing.T) {
	b0, a0, bytes0, compacted0, r0 := compact_run(t, "detailed", 0)
	testing.expect(t, r0.done, "the rollback over the detailed journal did not finish")
	testing.expect_value(t, compacted0, 0)
	testing.expect_value(t, a0, b0)

	b1, a1, bytes1, compacted1, r1 := compact_run(t, "compacted", 60)
	testing.expect(t, r1.done, "the rollback over the compacted journal did not finish")
	testing.expect(t, compacted1 >= 2, "segments should have been compacted")
	testing.expect(t, bytes1 < bytes0, "compaction should make the journal smaller")
	testing.expect_value(t, a1, b1)
	testing.expect_value(t, b1, b0)
	testing.expect_value(t, a1, a0)
	testing.expect_value(t, r1.missing, 0)
	journal_retention(t)
	fmt.printfln(
		"journal compaction: %d bytes detailed, %d compacted (%d segments)",
		bytes0,
		bytes1,
		compacted1,
	)
}

journal_retention :: proc(t: ^testing.T) {
	segments :: proc(
		t: ^testing.T,
		name: string,
		keep, most: u64,
	) -> (
		first, last: u32,
		count, bytes: int,
		before: int,
	) {
		dir := scratch_dir(name)
		defer delete(dir)
		defer os.remove_all(dir)
		g, ok := grief_open(t, dir, compact_config(dir, 1 << 40, 1 << 40, 1 << 40))
		if !ok {grief_close(g); return}
		defer grief_close(g)
		w := grief_world(g)
		compact_history(g)
		run(g, 100)
		testing.expect(t, world_save(w))
		before = len(journal_segments(w))
		// The same world, now with a retention.
		g.sess.srv.config.journal_keep, g.sess.srv.config.journal_max_bytes = keep, most
		g.sess.srv.config.journal_detail = 1 << 40
		testing.expect(t, world_save(w))
		segs := journal_segments(w)
		count = len(segs)
		if count > 0 {first, last = segs[0], segs[count - 1]}
		bytes, _, _ = segments_size(w)
		return
	}
	_, _, all, _, before := segments(t, "keeps", 1 << 40, 1 << 40)
	testing.expect(t, before >= 3, "the history should span several segments")
	testing.expect_value(t, all, before)
	// By age: only what began within the window stays.
	_, last, n, _, _ := segments(t, "age", 90, 1 << 40)
	testing.expect(t, n >= 1 && n < before, "old segments should be deleted by age")
	testing.expect_value(t, int(last), before)
	// By size: the oldest go while the directory is over its limit.
	_, last2, n2, bytes2, _ := segments(
		t,
		"size",
		1 << 40,
		2 * COMPACT_SEGMENT + COMPACT_SEGMENT / 2,
	)
	testing.expect(t, n2 >= 1 && n2 < before, "old segments should be deleted by size")
	testing.expect(t, bytes2 <= 2 * COMPACT_SEGMENT + COMPACT_SEGMENT / 2 || n2 == 1)
	testing.expect_value(t, int(last2), before)
}
