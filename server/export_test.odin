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
vxu_bytes :: proc(
	files: []Test_File,
	save_format := SAVE_FORMAT,
	packs := []Export_Pack{},
) -> []u8 {
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
	game.write_varint(&w, u32(len(packs)))
	for p in packs {
		game.write_string(&w, p.namespace)
		game.write_string(&w, p.hash)
	}
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
	// A universe from a newer game, and an older one (it is refused when opened).
	newer, left := import_of("newer", vxu_bytes({{"universe.cfg", "x"}}, SAVE_FORMAT + 1))
	testing.expect(t, strings.contains(newer, "newer game"), "a newer universe was accepted")
	testing.expect(t, !left, "something of the import was left")
	problem, _ = import_of("older", vxu_bytes({{"universe.cfg", "x"}}, SAVE_FORMAT - 1))
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

// M47i: a universe's packs travel in its export, are listed in its header
// (their hashes, readable without unpacking), and are built into a registry
// before an import is accepted.
@(private = "file")
write_pack_dir :: proc(universe: string, pack: game.Pack_Source) {
	for f in pack.files {
		path := fmt.tprintf("%s/%s/%s/%s", universe, PACKS_DIR, pack.namespace, f.path)
		_ = os.make_directory_all(filepath_dir(path))
		_ = os.write_entire_file(path, f.data)
	}
}

@(private = "file")
filepath_dir :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return path[:i] if i >= 0 else "."
}

@(test)
test_export_carries_packs :: proc(t: ^testing.T) {
	src := "build/test_export_packs_src"
	dest := "build/test_export_packs_dest"
	file := "build/test_export_packs.vxu"
	for d in ([]string{src, dest, fmt.tprintf("%s.import", dest)}) {os.remove_all(d)}
	defer {
		os.remove_all(src)
		os.remove_all(dest)
		os.remove(file)
	}
	_ = os.make_directory_all(src)
	_ = os.write_entire_file(
		fmt.tprintf("%s/%s", src, UNIVERSE_FILE),
		transmute([]u8)string("format = 6\ngeneration = 1\nage = 0\npacks = testpack\n"),
	)
	pack := game.test_asset_pack()
	write_pack_dir(src, pack)
	// A server-only file travels too (an export is the universe's own backup).
	structure_path := fmt.tprintf("%s/%s/testpack/server/structures/x.vxs", src, PACKS_DIR)
	for f in game.base_pack_source(context.temp_allocator).files {
		if strings.has_prefix(f.path, "server/structures/") {
			_ = os.make_directory_all(filepath_dir(structure_path))
			_ = os.write_entire_file(structure_path, f.data)
			break
		}
	}
	disk := base.Disk{}
	testing.expect_value(t, export_write(src, file, &disk), "")
	// The header names the pack and its hash (as a player would be sent it).
	bytes, _ := os.read_entire_file_from_path(file, context.temp_allocator)
	sent := game.pack_hash_hex(
		game.pack_hash(game.pack_archive_make(pack, context.temp_allocator)),
	)
	testing.expect(
		t,
		strings.contains(string(bytes[:300]), sent) &&
		strings.contains(string(bytes[:300]), "testpack"),
		"the header does not list the pack and its hash",
	)
	testing.expect_value(t, universe_import(file, dest, &disk), "")
	testing.expect(
		t,
		os.exists(fmt.tprintf("%s/%s/testpack/server/structures/x.vxs", dest, PACKS_DIR)),
	)
	exported := registry_for_dir(src)
	imported := registry_for_dir(dest)
	defer game.registry_destroy(exported)
	defer game.registry_destroy(imported)
	if !testing.expect(t, exported != nil && imported != nil) {return}
	testing.expect_value(t, imported.hash, exported.hash)
	_, has := game.registry_block(imported, "testpack:marble")
	testing.expect(t, has, "the imported universe lacks the pack's block")
}

@(test)
test_import_refuses_broken_packs :: proc(t: ^testing.T) {
	good := game.test_asset_pack()
	files := make([dynamic]Test_File, context.temp_allocator)
	append(&files, Test_File{"universe.cfg", "format = 6\npacks = testpack\n"})
	for f in good.files {
		data := string(f.data)
		if f.path == "data/blocks/marble.json" {data = `{"marble": {"light": "bright"}}`}
		append(&files, Test_File{fmt.tprintf("%s/testpack/%s", PACKS_DIR, f.path), data})
	}
	broken := make([dynamic]game.Pack_File, context.temp_allocator)
	for f in good.files {
		data := f.data
		if f.path ==
		   "data/blocks/marble.json" {data = transmute([]u8)string(`{"marble": {"light": "bright"}}`)}
		append(&broken, game.Pack_File{f.path, data})
	}
	hash_text := game.pack_hash_hex(
		game.pack_hash(game.pack_archive_make({"testpack", broken[:]}, context.temp_allocator)),
	)
	problem, left := import_of(
		"broken_pack",
		vxu_bytes(files[:], packs = {{"testpack", hash_text}}),
	)
	testing.expect(
		t,
		strings.has_prefix(problem, "the packs of this universe do not load:"),
		problem,
	)
	testing.expect(t, strings.contains(problem, "marble"), problem)
	testing.expect(t, !left, "something of the import was left")
	// A header that lists another hash: refused too.
	files[1] = Test_File{files[1].path, files[1].data}
	for &f in files {
		if f.path == "packs/testpack/data/blocks/marble.json" {f.data = string(good.files[1].data)}
	}
	problem, left = import_of(
		"hash_differs",
		vxu_bytes(files[:], packs = {{"testpack", "0123456789abcdef"}}),
	)
	testing.expect(t, strings.contains(problem, "not the one its header lists"), problem)
	testing.expect(t, !left)
}
