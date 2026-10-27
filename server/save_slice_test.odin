package server

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../common/game"

// M46b: a save describes the tick it began on, however many ticks it takes to
// encode (save_slice.odin).

// slice_scene: a stepped server with a house, a chest, edits in two regions and
// the player's pockets full, saved once.
@(private = "file")
slice_scene :: proc(t: ^testing.T, tag: string) -> (g: ^Grief, dir: string, ok: bool) {
	dir = fmt.aprintf("build/test_slice_%s", tag)
	os.remove_all(dir)
	g, ok = grief_open(t, dir)
	if !ok {return}
	grief_build(g)
	far_edit(g, 600, 0)
	if !testing.expect(t, save(grief_srv(g)), "the first save failed") {ok = false}
	// More play, so regions have changed since: loaded chunks around the player and unloaded ones far away.
	cmd(g, "fill %s stone", box(g, {0, 3, 4}, {1, 4, 5}))
	far_edit(g, 600, 0)
	cmd(g, "give @s stone 30")
	run(g, 3)
	return
}

// slice_files: a universe's files and its character's inventory as text, with the
// character's counters (which may be newer than T) left out.
@(private = "file")
slice_digest :: proc(dir: string) -> (digest: u64, character: string) {
	files := make([dynamic]string, context.temp_allocator)
	walk_files(dir, "", &files)
	for rel in files {
		if !strings.has_prefix(rel, "characters/") {continue}
		data, _ := os.read_entire_file_from_path(full_path(dir, rel), context.temp_allocator)
		r, ok := player_parse(data)
		if !ok {continue}
		character = fmt.aprintf("%v %v %v", r.state.position, r.look, r.inventory.slots)
		counters_free(&r.stats)
	}
	// A copy without what is not the save's items: the characters (their counters
	// may be newer than T), when each was last seen and the journal (both stamp the
	// wall clock).
	copy := fmt.tprintf("%s_digest", dir)
	os.remove_all(copy)
	defer os.remove_all(copy)
	copy_tree(dir, copy)
	os.remove_all(full_path(copy, "characters"))
	os.remove(full_path(copy, COMMUNITY_FILE))
	rest := make([dynamic]string, context.temp_allocator)
	walk_files(copy, "", &rest)
	for rel in rest {if strings.has_suffix(rel, ".vxj") {os.remove(full_path(copy, rel))}}
	return state_digest(copy), character
}

// region_diff: how two region files differ (the chunks each has that the other
// does not or has otherwise).
@(private = "file")
region_diff :: proc(x, y: []u8) -> string {
	out := strings.builder_make(context.temp_allocator)
	load :: proc(data: []u8) -> map[game.Chunk_Pos]string {
		m := make(map[game.Chunk_Pos]string, context.temp_allocator)
		le :: proc(b: []u8) -> i32 {return(
				i32(b[0]) |
				i32(b[1]) << 8 |
				i32(b[2]) << 16 |
				i32(b[3]) << 24 \
			)}
		r, _ := game.region_open(data, {le(data[8:]), le(data[12:])})
		for e in r.index {
			m[e.pos] = string(r.payloads[e.offset:][:e.length])
		}
		return m
	}
	a, b := load(x), load(y)
	for pos, bytes in a {
		if other, ok := b[pos]; !ok {
			fmt.sbprintf(&out, " only-in-want %v", pos)
		} else if other != bytes {
			fmt.sbprintf(&out, " differs %v", pos)
		}
	}
	for pos in b {if pos not_in a {fmt.sbprintf(&out, " only-in-got %v", pos)}}
	for i in 0 ..< min(len(x), len(y)) {
		if x[i] != y[i] {
			fmt.sbprintf(
				&out,
				" first byte difference at %d of %d: %v / %v",
				i,
				len(x),
				x[max(i - 8, 0):][:20],
				y[max(i - 8, 0):][:20],
			)
			break
		}
	}
	return strings.to_string(out)
}

// slice_diff: the files of two universes that differ (journal segments are cut
// at the end the world.cfg records, as state_digest does).
@(private = "file")
slice_diff :: proc(a, b: string) -> string {
	out := strings.builder_make(context.temp_allocator)
	files := make([dynamic]string, context.temp_allocator)
	walk_files(a, "", &files)
	for rel in files {
		x, _ := os.read_entire_file_from_path(full_path(a, rel), context.temp_allocator)
		y, err := os.read_entire_file_from_path(full_path(b, rel), context.temp_allocator)
		if rel == COMMUNITY_FILE || strings.has_prefix(rel, "characters/") {continue}
		if strings.has_suffix(rel, ".vxj") {continue}
		if err != nil {
			fmt.sbprintf(&out, " %s (missing)", rel)
		} else if string(x) != string(y) {
			fmt.sbprintf(&out, " %s", rel)
			if strings.has_suffix(rel, ".vxj") {
				d := 0
				for d < min(len(x), len(y)) && x[d] == y[d] {d += 1}
				fmt.sbprintf(&out, " [lengths %d %d, first difference at %d]", len(x), len(y), d)
			}
			if strings.has_suffix(rel, ".vxr") {fmt.sbprintf(&out, " [%s]", region_diff(x, y))}
			if strings.has_suffix(
				rel,
				".cfg",
			) {fmt.sbprintf(&out, " [%q != %q]", string(x), string(y))}
		}
	}
	return strings.to_string(out)
}

@(test)
test_sliced_save_is_the_capture_tick :: proc(t: ^testing.T) {
	// The reference: the same scene saved at once at T.
	g1, dir1, ok1 := slice_scene(t, "block")
	defer delete(dir1)
	defer os.remove_all(dir1)
	defer grief_close(g1)
	if !ok1 {return}
	testing.expect(t, save(grief_srv(g1)), "the blocking save failed")
	want, want_character := slice_digest(dir1)
	defer delete(want_character)

	g2, dir2, ok2 := slice_scene(t, "sliced")
	defer delete(dir2)
	defer os.remove_all(dir2)
	defer grief_close(g2)
	if !ok2 {return}
	s := grief_srv(g2)
	s.store.slice_hold = true
	testing.expect(t, save_begin(s), "the capture failed")
	testing.expect(t, s.store.job != nil, "no save is running")
	// Everything a save holds changes before one slice is encoded: blocks in
	// loaded chunks, the chest, the pockets, the player; chunks go away.
	w := grief_world(g2)
	cmd(g2, "fill %s obsidian", box(g2, {-2, 0, -2}, {2, 3, 2}))
	cmd(g2, "fill %s air", box(g2, {3, 0, -1}, {7, 2, 1}))
	cmd(g2, "give @s planks 5")
	cmd(g2, "clear @s stone")
	chest := at(g2, -3, 0, 2)
	if rec, held := &w.containers[chest]; held {rec.slots[0] = {}}
	far_edit(g2, 0, 700) // (the area around the player is left and unloaded: copies and bytes)
	run(g2, 100)
	testing.expect(
		t,
		w.chunks.cow != nil && len(w.chunks.cow.copies) > 0,
		"no chunk was copied before it changed or went",
	)
	testing.expect(t, s.store.job != nil, "the save ended before it was finished")
	testing.expect(t, save_finish(s), "the sliced save failed")
	testing.expect(t, s.store.job == nil, "the save is still running")
	report := universe_check(dir2)
	testing.expectf(t, report.ok, "the universe does not check: %v", report.problems[:])
	got, got_character := slice_digest(dir2)
	defer delete(got_character)
	testing.expectf(
		t,
		got == want,
		"the sliced save differs from the blocking one in:%s",
		slice_diff(dir1, dir2),
	)
	testing.expectf(
		t,
		got_character == want_character,
		"the character differs: want %s got %s",
		want_character,
		got_character,
	)
}

@(test)
test_world_stays_while_its_save_runs :: proc(t: ^testing.T) {
	dir := fmt.aprintf("build/test_slice_unload")
	defer delete(dir)
	os.remove_all(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.world_idle = 0.5
	g, ok := grief_open(t, dir, cfg)
	defer grief_close(g)
	if !ok {return}
	s := grief_srv(g)
	other := world_load(s, game.address_derive(4242))
	if !testing.expect(t, other != nil, "no second world") {return}
	set_block(other, {0, 100, 0}, .Stone, {})
	s.store.slice_hold = true
	testing.expect(t, save_begin(s), "the capture failed")
	run(g, 60) // (idle for 3 s: it would have gone)
	testing.expect_value(t, len(s.worlds), 2)
	testing.expect(t, save_finish(s), "the save failed")
	run(g, 60)
	testing.expect_value(t, len(s.worlds), 1)
}

@(test)
test_stop_writes_a_running_save :: proc(t: ^testing.T) {
	g, dir, ok := slice_scene(t, "stop")
	defer delete(dir)
	defer os.remove_all(dir)
	defer grief_close(g)
	if !ok {return}
	s := grief_srv(g)
	generation := s.store.generation
	s.store.slice_hold = true
	testing.expect(t, save_begin(s), "the capture failed")
	cmd(g, "fill %s obsidian", box(g, {-2, 0, -2}, {2, 3, 2}))
	// What stop does: a save with wait, while one is running: both are written.
	testing.expect(t, save(s), "the save failed")
	testing.expect(t, s.store.job == nil, "a save is still running")
	testing.expect_value(t, s.store.generation, generation + 2)
	report := universe_check(dir)
	testing.expectf(t, report.ok, "the universe does not check: %v", report.problems[:])
	testing.expect_value(t, report.generation, generation + 2)
}
