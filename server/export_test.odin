package server

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:testing"

import "../base"
import "../common/game"

// M46b: a universe as one file and back (export.odin).

@(private = "file")
Test_File :: struct {
	path: string,
	data: string,
}

// vxu_bytes: a well-formed export of files, for the tests that need a file with
// one thing wrong in it.
@(private = "file")
vxu_bytes :: proc(files: []Test_File, save_format := SAVE_FORMAT) -> []u8 {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	put_u64 :: proc(w: ^game.Writer, v: u64) {
		game.write_u32(w, u32(v))
		game.write_u32(w, u32(v >> 32))
	}
	for c in EXPORT_MAGIC {game.write_u8(&w, u8(c))}
	game.write_u32(&w, EXPORT_FORMAT)
	game.write_u32(&w, u32(save_format))
	put_u64(&w, 1)
	put_u64(&w, 0)
	game.write_varint(&w, u32(len(files)))
	seal := u32(0)
	for f in files {
		crc := hash.crc32(transmute([]u8)f.data)
		game.write_string(&w, f.path)
		put_u64(&w, u64(len(f.data)))
		game.write_u32(&w, crc)
		append(&w.buf, f.data)
		seal = hash.crc32(transmute([]u8)f.path, seal)
		crc_bytes := [4]u8{u8(crc), u8(crc >> 8), u8(crc >> 16), u8(crc >> 24)}
		seal = hash.crc32(crc_bytes[:], seal)
	}
	for c in EXPORT_END {game.write_u8(&w, u8(c))}
	game.write_u32(&w, seal)
	return w.buf[:]
}

// import_of: the result of importing bytes into a fresh directory (and whether
// anything of it was left).
@(private = "file")
import_of :: proc(
	tag: string,
	bytes: []u8,
	limits := IMPORT_LIMITS,
) -> (
	problem: string,
	left: bool,
) {
	file := fmt.tprintf("build/test_export_%s.vxu", tag)
	dest := fmt.tprintf("build/test_export_%s", tag)
	os.remove_all(dest)
	os.remove_all(fmt.tprintf("%s.import", dest))
	_ = os.write_entire_file(file, bytes)
	defer os.remove(file)
	disk := base.Disk{}
	problem = universe_import(file, dest, &disk, limits)
	left = os.exists(dest) || os.exists(fmt.tprintf("%s.import", dest))
	os.remove_all(dest)
	os.remove_all(fmt.tprintf("%s.import", dest))
	return strings.clone(problem, context.temp_allocator), left
}

@(test)
test_export_import_round_trip :: proc(t: ^testing.T) {
	src := scratch_dir("export_src")
	defer delete(src)
	defer os.remove_all(src)
	file := "build/test_export_round.vxu"
	defer os.remove(file)
	dest := scratch_dir("export_dest")
	defer delete(dest)
	defer os.remove_all(dest)
	open := scratch_dir("export_open")
	defer delete(open)
	defer os.remove_all(open)
	os.remove_all(fmt.tprintf("%s.import", dest))

	g, ok := grief_open(t, src)
	if !ok {grief_close(g); return}
	grief_build(g)
	far_edit(g, 600, 0)
	run(g, 30)
	grief_locate(g)
	cmd(g, "protect add yard %s", box(g, {0, -1, 4}, {2, 3, 6}))
	expect := strings.clone(fixture_expect(g))
	defer delete(expect)
	// An open universe is another process's, as far as an export goes.
	disk := base.Disk{}
	why := universe_export(src, file, &disk)
	testing.expectf(
		t,
		strings.contains(why, "open in another process"),
		"exported an open universe: %q",
		why,
	)
	grief_close(g) // (the last save, and the lock released)

	testing.expectf(t, universe_export(src, file, &disk) == "", "the export failed")
	testing.expectf(t, universe_import(file, dest, &disk) == "", "the import failed")
	testing.expect(
		t,
		universe_import(file, dest, &disk) != "",
		"an existing destination was overwritten",
	)
	testing.expect(t, !os.exists(fmt.tprintf("%s.import", dest)), "a staging directory was left")
	// The same files, but for what a running server keeps (the lock, nothing else).
	testing.expect_value(t, state_digest(dest), state_digest(src))
	report := universe_check(dest)
	testing.expectf(t, report.ok, "the imported universe does not check: %v", report.problems[:])

	// Opened, it is the universe that was exported: its edited chunks, the character, the chests.
	text := fmt.tprintf("%s\n", expect)
	_ = os.write_entire_file(fmt.tprintf("%s/expect.txt", dest), transmute([]u8)text)
	g2, lines, ok2 := open_fixture(t, dest, open)
	defer grief_close(g2)
	defer free_lines(lines)
	if !ok2 {return}
	fixture_matches(t, g2, lines[:])
}

@(test)
test_import_refuses_bad_paths :: proc(t: ^testing.T) {
	long := strings.repeat("a", 65, context.temp_allocator)
	deep := "a/b/c/d/e/f/g/h/i"
	cases := [?]string {
		"/etc/passwd",
		"../outside",
		"worlds/../../outside",
		"worlds//a",
		"./universe.cfg",
		"worlds/./a",
		"worlds\\a",
		"C:evil",
		"a:b",
		deep,
		long,
		"worlds/café",
		"has space",
		"star*",
		"",
		"trailing/",
	}
	for path in cases {
		problem, left := import_of(
			"paths",
			vxu_bytes({{"universe.cfg", "format = 5\n"}, {path, "x"}}),
		)
		testing.expectf(t, problem != "", "the path %q was accepted", path)
		if path !=
		   "" {testing.expectf(t, strings.contains(problem, fmt.tprintf("%q", path)) || path == deep || path == long, "%q: the problem does not name the path: %q", path, problem)}
		testing.expectf(t, !left, "%q: something of the import was left", path)
	}
	// A path of plain names is fine.
	problem, _ := import_of(
		"paths_ok",
		vxu_bytes({{"universe.cfg", "x"}, {"worlds/a-b_c.d/world.cfg", "y"}}),
	)
	testing.expect_value(t, problem, "")
	// Twice is not.
	problem, _ = import_of("paths_twice", vxu_bytes({{"a", "x"}, {"a", "y"}}))
	testing.expect(t, strings.contains(problem, "twice"), "a path given twice was accepted")
}

@(test)
test_import_refuses_sizes_and_versions :: proc(t: ^testing.T) {
	ok_file := vxu_bytes({{"universe.cfg", "x"}, {"a", "0123456789"}})
	problem, _ := import_of("limits_ok", ok_file)
	testing.expect_value(t, problem, "")
	for c in ([]struct {
			limits: Import_Limits,
			word:   string,
		}{{{100, 1, 100}, "too many"}, {{100, 10, 5}, "too large"}, {{10, 10, 100}, "too large"}}) {
		refused, left := import_of("limits", ok_file, c.limits)
		testing.expectf(t, strings.contains(refused, c.word), "limits %v: %q", c.limits, refused)
		testing.expect(t, !left, "something of the import was left")
	}
	// A header that claims more than the file holds.
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	for c in EXPORT_MAGIC {game.write_u8(&w, u8(c))}
	for v in ([]u32{EXPORT_FORMAT, SAVE_FORMAT, 0, 0, 0, 0}) {game.write_u32(&w, v)}
	game.write_varint(&w, 1)
	game.write_string(&w, "big")
	game.write_u32(&w, 0)
	game.write_u32(&w, 1 << 30) // 4 GiB: more than the file
	game.write_u32(&w, 0)
	problem, _ = import_of("claims", w.buf[:])
	testing.expect(t, problem != "", "a file that claims more than it holds was accepted")
	// A count over the limit before any entry.
	clear(&w.buf)
	for c in EXPORT_MAGIC {game.write_u8(&w, u8(c))}
	for v in ([]u32{EXPORT_FORMAT, SAVE_FORMAT, 0, 0, 0, 0}) {game.write_u32(&w, v)}
	game.write_varint(&w, IMPORT_MAX_FILES + 1)
	problem, _ = import_of("count", w.buf[:])
	testing.expect(
		t,
		strings.contains(problem, "too many"),
		"more files than the limit were accepted",
	)
	// A universe from a newer game, and an older one (it migrates when opened).
	newer, left := import_of("newer", vxu_bytes({{"universe.cfg", "x"}}, SAVE_FORMAT + 1))
	testing.expect(t, strings.contains(newer, "newer game"), "a newer universe was accepted")
	testing.expect(t, !left, "something of the import was left")
	problem, _ = import_of("older", vxu_bytes({{"universe.cfg", "x"}}, LEGACY_FORMAT))
	testing.expect_value(t, problem, "")
}

@(test)
test_import_refuses_damaged_files :: proc(t: ^testing.T) {
	good := vxu_bytes({{"universe.cfg", "format = 5\n"}, {"worlds/a/world.cfg", "seed = 1\n"}})
	problem, _ := import_of("damage", good)
	testing.expect_value(t, problem, "")
	// Cut short anywhere.
	for n in ([]int{0, 3, 10, 30, len(good) / 2, len(good) - 9, len(good) - 1}) {
		refused, left := import_of("cut", good[:n])
		testing.expectf(
			t,
			refused != "" && !left,
			"a file cut at %d of %d was accepted",
			n,
			len(good),
		)
	}
	// Any one byte changed (the body, a checksum, a path, the end).
	for i in 0 ..< len(good) { 	// (a flipped bit in the header may be harmless; none may leave anything)
		bad := make([]u8, len(good), context.temp_allocator)
		copy(bad, good)
		bad[i] ~= 0x01
		refused, left := import_of("flip", bad)
		testing.expectf(
			t,
			refused == "" || !left,
			"byte %d changed: a refused import left something",
			i,
		)
	}
	for i in 28 ..< len(good) { 	// (after the header: every byte is checked)
		bad := make([]u8, len(good), context.temp_allocator)
		copy(bad, good)
		bad[i] ~= 0x01
		refused, _ := import_of("flip", bad)
		testing.expectf(t, refused != "", "byte %d changed and the file was accepted", i)
	}
	// Not an export at all.
	problem, _ = import_of("magic", transmute([]u8)string("hello, this is not a universe"))
	testing.expect(t, problem != "", "a file that is not an export was accepted")
}

@(test)
test_v4_export_imports_and_migrates :: proc(t: ^testing.T) {
	src := "build/test_export_v4_src"
	file := "build/test_export_v4.vxu"
	dest := "build/test_export_v4_dest"
	open := "build/test_export_v4_open"
	for d in ([]string{src, dest, open}) {os.remove_all(d)}
	defer for d in ([]string{src, dest, open}) {os.remove_all(d)}
	defer os.remove(file)
	copy_tree(FIXTURE_V4, src)
	expect, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/expect.txt", src),
		context.temp_allocator,
	)
	os.remove(fmt.tprintf("%s/expect.txt", src))
	disk := base.Disk{}
	testing.expectf(t, universe_export(src, file, &disk) == "", "the export failed")
	testing.expectf(t, universe_import(file, dest, &disk) == "", "the import failed")
	_ = os.write_entire_file(fmt.tprintf("%s/expect.txt", dest), expect)
	g, lines, ok := open_fixture(t, dest, open)
	defer grief_close(g)
	defer free_lines(lines)
	if !ok {return}
	testing.expect_value(t, g.sess.srv.store.format, SAVE_FORMAT)
	fixture_matches(t, g, lines[:])
}
