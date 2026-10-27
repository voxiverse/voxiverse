package server

import "core:os"
import "core:testing"

import "../common/game"

// M46b: a region file holds only what differs from the generator's (compact.odin).

// region_has: the chunks (and the number of tops) a world's region file holds;
// none if there is no file.
@(private = "file")
region_has :: proc(
	w: ^World,
	region: game.Region_Pos,
) -> (
	chunks: []game.Chunk_Pos,
	tops: []game.Saved_Top,
) {
	data, err := os.read_entire_file_from_path(region_path(w.dir, region), context.temp_allocator)
	if err != nil {return}
	r, open_err := game.region_open(data, region)
	if open_err != .None {return}
	list := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for e in r.index {append(&list, e.pos)}
	return list[:], r.tops[:]
}

@(private = "file")
contains :: proc(list: []game.Chunk_Pos, pos: game.Chunk_Pos) -> bool {
	for p in list {if p == pos {return true}}
	return false
}

@(test)
test_rolled_back_chunk_leaves_its_region :: proc(t: ^testing.T) {
	dir := scratch_dir("compact")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	defer grief_close(g)
	if !ok {return}
	s := grief_srv(g)
	w := grief_world(g)
	// Kept: a block in the player's chunk. Griefed: another chunk of the same region.
	kept := at(g, 0, 3, 0)
	griefed := at(g, 40, 3, 0)
	if game.region_of(game.chunk_of(griefed)) != game.region_of(game.chunk_of(kept)) {
		griefed = at(g, -40, 3, 0)
	}
	for chunk in ([]game.Chunk_Pos{game.chunk_of(kept), game.chunk_of(griefed)}) {
		testing.expect(t, chunks_get(&w.chunks, chunk) != nil, "a chunk is not loaded")
	}
	testing.expect_value(
		t,
		game.region_of(game.chunk_of(kept)),
		game.region_of(game.chunk_of(griefed)),
	)
	cmd(g, "setblock %d %d %d stone", kept.x, kept.y, kept.z)
	run(g, 100) // (long before the grief: the rollback leaves it)
	g.at = age_of(s)
	cmd(g, "setblock %d %d %d stone", griefed.x, griefed.y, griefed.z)
	region := game.region_of(game.chunk_of(kept))
	testing.expect(t, save(s), "the first save failed")
	before, _ := region_has(w, region)
	testing.expect(t, contains(before, game.chunk_of(kept)), "the kept chunk is not saved")
	testing.expect(t, contains(before, game.chunk_of(griefed)), "the griefed chunk is not saved")

	r := grief_rollback(g, grief_player(g))
	testing.expect(t, r.done, "the rollback did not finish")
	run(g, 5)
	testing.expect_value(t, block_at_pos(w, griefed), game.Block.Air)
	testing.expect_value(t, block_at_pos(w, kept), game.Block.Stone)
	hash := world_hash_here(g)
	testing.expect(t, save(s), "the second save failed")
	after, _ := region_has(w, region)
	testing.expect(t, contains(after, game.chunk_of(kept)), "the kept chunk left its region")
	testing.expect(
		t,
		!contains(after, game.chunk_of(griefed)),
		"the rolled back chunk is still in its region",
	)
	testing.expect_value(t, world_hash_here(g), hash) // (compaction changes the file, never the world)
	// The dropped chunk is natural now: nothing keeps it saved.
	c := chunks_get(&w.chunks, game.chunk_of(griefed))
	testing.expect(t, c != nil && !c.modified, "the natural chunk is still marked edited")
}

@(test)
test_emptied_region_is_deleted :: proc(t: ^testing.T) {
	dir := scratch_dir("compact_empty")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	defer grief_close(g)
	if !ok {return}
	s := grief_srv(g)
	w := grief_world(g)
	p := at(g, 2, 3, 2)
	g.at = age_of(s)
	cmd(g, "setblock %d %d %d stone", p.x, p.y, p.z)
	region := game.region_of(game.chunk_of(p))
	testing.expect(t, save(s), "the first save failed")
	testing.expect(t, os.exists(region_path(w.dir, region)), "the region was not written")
	r := grief_rollback(g, grief_player(g))
	testing.expect(t, r.done, "the rollback did not finish")
	run(g, 5)
	testing.expect(t, save(s), "the second save failed")
	testing.expect(t, !os.exists(region_path(w.dir, region)), "the empty region was not deleted")
	report := universe_check(dir)
	testing.expectf(t, report.ok, "the universe does not check: %v", report.problems[:])
}

@(test)
test_tops_equal_to_natural_are_dropped :: proc(t: ^testing.T) {
	dir := scratch_dir("compact_tops")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	defer grief_close(g)
	if !ok {return}
	s := grief_srv(g)
	w := grief_world(g)
	p := at(g, 2, 3, 2)
	cmd(g, "setblock %d %d %d stone", p.x, p.y, p.z)
	region := game.region_of(game.chunk_of(p))
	// A top that says what the generator says (as a changed generator leaves them).
	column := [2]i32{p.x + 5, p.z + 5}
	natural := natural_top(w, column.x, column.y)
	w.tops[column] = natural
	mark_edited(w, game.chunk_of(p))
	testing.expect(t, save(s), "the save failed")
	_, tops := region_has(w, region)
	_, still := w.tops[column]
	testing.expect(t, !still, "the world still keeps the natural top")
	for top in tops {
		testing.expect(t, [2]i32{top.x, top.z} != column, "the region file keeps the natural top")
	}
}
