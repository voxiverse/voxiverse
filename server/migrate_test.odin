package server

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

import "../common/game"

// The fixtures: a universe saved by an older format's code, committed under
// assets/fixtures/save-v<N>/ with the expect.txt of what it holds, so the
// migrations are tested from real files (docs/saves.md).

FIXTURE_WRITE :: #config(VX_FIXTURE_WRITE, false)
FIXTURE_V4 :: "assets/fixtures/save-v4"

// fixture_expect: what a loaded fixture must hold, as expect.txt's text: the
// hash of the chunks around its center, the character's inventory, the chests.
fixture_expect :: proc(g: ^Grief) -> string {
	b := strings.builder_make(context.temp_allocator)
	c := game.chunk_of(g.f)
	fmt.sbprintfln(&b, "center %d %d %d", c.x, c.y, c.z)
	fmt.sbprintfln(&b, "chunks %016x", world_hash_here(g))
	cl := grief_client(g)
	for st, i in cl.inventory.slots {
		if game.stack_empty(st) {continue}
		fmt.sbprintfln(&b, "inventory %d %s %d", i, game.item_name(st.item), st.count)
	}
	w := grief_world(g)
	for pos, rec in w.containers {
		for st, i in rec.slots {
			if game.stack_empty(st) {continue}
			fmt.sbprintfln(
				&b,
				"chest %d %d %d %d %s %d",
				pos.x,
				pos.y,
				pos.z,
				i,
				game.item_name(st.item),
				st.count,
			)
		}
	}
	return strings.to_string(b)
}

// Run once, by hand, with today's code of the format: writes the fixture.
@(test)
test_write_v4_fixture :: proc(t: ^testing.T) {
	if !FIXTURE_WRITE {return}
	dir := scratch_dir("fixture_v4")
	defer delete(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.no_sheep = false
	g, ok := grief_open(t, dir, cfg)
	if !ok {grief_close(g); return}
	defer grief_close(g)
	grief_build(g)
	cmd(g, "protect add house %s", box(g, {3, -1, -2}, {7, 3, 2}))
	home := g.f
	for far in ([]game.Block_Pos{{600, 0, 0}, {0, 0, 600}}) {
		cmd(g, "tp %d %d %d", home.x + far.x, home.y, home.z + far.z)
		run(g, 300)
		p := grief_client(g).player.position
		cmd(g, "setblock %d %d %d stone", i32(p.x), i32(p.y) - 1, i32(p.z))
		run(g, 30)
	}
	cmd(g, "tp %d %d %d", home.x, home.y, home.z)
	run(g, 300)
	w := grief_world(g)
	grief_locate(g)
	e := entity_spawn(w, .Item, {f64(home.x) + 0.5, f64(home.y) + 1, f64(home.z) + 5.5}, false)
	if e != nil {e.stack = {game.item_of_block(.Stone), 7}}
	entity_spawn(w, .Sheep, {f64(home.x) + 0.5, f64(home.y) + 1, f64(home.z) - 6.5}, false)
	run(g, 20)
	testing.expect(t, save(grief_srv(g)), "the save failed")
	expect := fixture_expect(g)
	os.remove_all(FIXTURE_V4)
	copy_tree(dir, FIXTURE_V4)
	_ = os.write_entire_file(fmt.tprintf("%s/expect.txt", FIXTURE_V4), transmute([]u8)expect)
}

// copy_tree copies directory from into to (made), files and directories.
copy_tree :: proc(from, to: string) {
	os.make_directory_all(to)
	entries, err := os.read_all_directory_by_path(from, context.temp_allocator)
	if err != nil {return}
	for e in entries {
		src, dst := fmt.tprintf("%s/%s", from, e.name), fmt.tprintf("%s/%s", to, e.name)
		if e.type == .Directory {
			copy_tree(src, dst)
		} else if data, rerr := os.read_entire_file_from_path(src, context.temp_allocator);
		   rerr == nil {
			_ = os.write_entire_file(dst, data)
		}
	}
}

// expect_lines: expect.txt's lines by key.
fixture_lines :: proc(text: string) -> (lines: [dynamic]string) {
	lines = make([dynamic]string) // (heap: the server frees the temp allocator every tick)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.trim_space(line) != "" {append(&lines, strings.clone(strings.trim_space(line)))}
	}
	return
}

// open_fixture: a copy of fixture (a committed save) in a scratch directory,
// opened as a stepped session at the player's place; expect.txt's lines too.
open_fixture :: proc(
	t: ^testing.T,
	fixture, dir: string,
) -> (
	g: ^Grief,
	expect: [dynamic]string,
	ok: bool,
) {
	os.remove_all(dir)
	copy_tree(fixture, dir)
	data, err := os.read_entire_file_from_path(fmt.tprintf("%s/expect.txt", fixture), context.allocator)
	defer delete(data)
	if !testing.expect(t, err == nil, "the fixture has no expect.txt") {return}
	expect = fixture_lines(string(data))
	os.remove(fmt.tprintf("%s/expect.txt", dir))
	cfg := grief_config(dir)
	cfg.no_sheep = false
	g, ok = grief_open(t, dir, cfg)
	if !ok {return}
	// The chunks the fixture hashed: the 5 x 3 x 5 around its center.
	center: [3]i32
	f := strings.fields(expect[0], context.temp_allocator)
	if !testing.expect(t, len(f) == 4 && f[0] == "center") {return}
	for i in 0 ..< 3 {
		v, _ := strconv.parse_int(f[i + 1])
		center[i] = i32(v)
	}
	clear(&g.chunks)
	for y in center.y - 1 ..= center.y + 1 {
		for z in center.z - 2 ..= center.z + 2 {
			for x in center.x - 2 ..= center.x + 2 {append(&g.chunks, game.Chunk_Pos{x, y, z})}
		}
	}
	return g, expect, true
}

// The fixture's own expect.txt text again, from the opened session.
fixture_matches :: proc(t: ^testing.T, g: ^Grief, expect: []string) {
	got := fixture_expect(g)
	rest := got
	i := 0
	for line in strings.split_lines_iterator(&rest) {
		if i == 0 {i += 1; continue} // (the center: set from expect)
		testing.expectf(
			t,
			i < len(expect) && strings.trim_space(line) == expect[i],
			"line %d: got %q, want %q",
			i,
			line,
			expect[i] if i < len(expect) else "<nothing>",
		)
		i += 1
	}
	testing.expect_value(t, i, len(expect))
}

@(test)
test_v4_save_migrates :: proc(t: ^testing.T) {
	dir := fmt.aprintf("build/test_migrate_v4")
	defer delete(dir)
	defer os.remove_all(dir)
	g, expect, ok := open_fixture(t, FIXTURE_V4, dir)
	if !ok {grief_close(g); return}
	defer grief_close(g)
	defer free_lines(expect)
	testing.expect_value(t, g.sess.srv.store.format, SAVE_FORMAT)
	fixture_matches(t, g, expect[:])
	text, _ := os.read_entire_file_from_path(fmt.tprintf("%s/universe.cfg", dir), context.temp_allocator)
	testing.expect(t, strings.contains(string(text), "format = 5"), "universe.cfg still says the old format")
	testing.expect(t, os.exists(fmt.tprintf("%s/backups/pre-migration-4/universe.cfg", dir)), "no backup")
}

free_lines :: proc(lines: [dynamic]string) {
	for l in lines {delete(l)}
	delete(lines)
}
