package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

import "../common/game"

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
		fmt.sbprintfln(&b, "inventory %d %s %d", i, game.item_name(test_reg(), st.item), st.count)
	}
	w := grief_world(g)
	for at in block_entities_all(w) {
		pos := at.pos
		for st, i in at.e.slots {
			if game.stack_empty(st) {continue}
			fmt.sbprintfln(
				&b,
				"chest %d %d %d %d %s %d",
				pos.x,
				pos.y,
				pos.z,
				i,
				game.item_name(test_reg(), st.item),
				st.count,
			)
		}
	}
	return strings.to_string(b)
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
fixture_lines :: proc(text: string, allocator := context.allocator) -> (lines: [dynamic]string) {
	lines = make([dynamic]string, allocator) // (heap: the server frees the temp allocator every tick)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.trim_space(line) !=
		   "" {append(&lines, strings.clone(strings.trim_space(line), allocator))}
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
	data, err := os.read_entire_file_from_path(
		fmt.tprintf("%s/expect.txt", fixture),
		context.allocator,
	)
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
		if i == 0 {i += 1; continue} 	// (the center: set from expect)
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

free_lines :: proc(lines: [dynamic]string) {
	for l in lines {delete(l)}
	delete(lines)
}

// The registry is a chain: sorted, contiguous, ending at the current format
// (empty while nothing is migrated: before 1.0 older saves are refused).
@(test)
test_migrations_are_a_chain :: proc(t: ^testing.T) {
	for m, i in MIGRATIONS {
		testing.expect(t, m.name != "" && m.run != nil, "a migration needs a name and a run")
		if i > 0 {testing.expect_value(t, m.from, MIGRATIONS[i - 1].from + 1)}
	}
	next := SAVE_FORMAT
	for m in MIGRATIONS {next = m.from + 1}
	testing.expect_value(t, next, SAVE_FORMAT)
}

// A universe of an older format (or from before universes) is refused with
// the reason; nothing of it is touched.
@(test)
test_older_save_is_refused :: proc(t: ^testing.T) {
	for case_, i in ([]struct {
			file, text: string,
		}{{UNIVERSE_FILE, "format = 5\nseed = 7\n"}, {WORLD_FILE, "format = 4\nseed = 7\n"}}) {
		dir := fmt.tprintf("build/test_older_save_%d", i)
		os.remove_all(dir)
		defer os.remove_all(dir)
		os.make_directory_all(dir)
		path := fmt.tprintf("%s/%s", dir, case_.file)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)case_.text) == nil)
		srv: Server
		config := Config {
			seed        = 7,
			view_radius = 2,
			view_height = 1,
			workers     = 1,
			stepped     = true,
			save_dir    = dir,
		}
		{
			context.logger = log.nil_logger() // (the refusal is the point)
			testing.expect(t, !start(&srv, config, {}), "an older save was opened")
		}
		testing.expect_value(t, srv.refusal, OLDER_BUILD)
		data, _ := os.read_entire_file_from_path(path, context.temp_allocator)
		testing.expect_value(t, string(data), case_.text)
	}
}

// A world with a containers.cfg (the chests' contents before block entities)
// is an older build's: refused, not read.
@(test)
test_containers_cfg_world_is_refused :: proc(t: ^testing.T) {
	dir := "build/test_containers_cfg"
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		seed        = 7,
		view_radius = 2,
		view_height = 1,
		workers     = 1,
		stepped     = true,
		save_dir    = dir,
	}
	{
		srv: Server
		if !testing.expect(t, start(&srv, config, {})) {return}
		stop(&srv)
	}
	worlds, _ := os.read_all_directory_by_path(
		fmt.tprintf("%s/%s", dir, WORLDS_DIR),
		context.temp_allocator,
	)
	testing.expect(t, len(worlds) == 1)
	path := fmt.tprintf("%s/%s/%s/containers.cfg", dir, WORLDS_DIR, worlds[0].name)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("1 2 3\n")) == nil)
	srv: Server
	context.logger = log.nil_logger()
	testing.expect(t, !start(&srv, config, {}), "a world with a containers.cfg was opened")
	testing.expect_value(t, srv.refusal, OLDER_BUILD)
}
