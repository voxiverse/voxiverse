package game

import "core:fmt"
import "core:os"
import "core:testing"

// The pack archive (M47b): canonical bytes, no server/ files, and every
// malformed archive refused with a message.

@(private = "file")
archive_files :: proc(order: []int) -> Pack_Source {
	all := [?]Pack_File {
		{
			"pack.json",
			transmute([]u8)string(
				`{"format": 1, "namespace": "farmfix", "version": "1.0.0", "title": "F", "requires": ["voxiverse"]}`,
			),
		},
		{
			"data/blocks/peat.json",
			transmute([]u8)string(
				`{"peat": {"textures": {"all": "voxiverse:dirt"}, "light": 0, "sound": "voxiverse:dirt"}}`,
			),
		},
		{"assets/textures/x.json", transmute([]u8)string(`{}`)},
		{"server/structures/a.vxs", transmute([]u8)string(`xyz`)},
	}
	files := make([]Pack_File, len(order), context.temp_allocator)
	for o, i in order {files[i] = all[o]}
	return {"farmfix", files}
}

@(test)
test_pack_archive_is_canonical :: proc(t: ^testing.T) {
	a := pack_archive_make(archive_files({0, 1, 2}), context.temp_allocator)
	b := pack_archive_make(archive_files({2, 1, 0}), context.temp_allocator)
	c := pack_archive_make(archive_files({3, 1, 0, 2}), context.temp_allocator) // (with a server/ file)
	testing.expect(t, string(a) == string(b), "file order changed the archive")
	testing.expect(t, string(a) == string(c), "a server/ file changed the archive")
	testing.expect_value(t, pack_hash(a), pack_hash(c))
	src, errs := pack_archive_read("farmfix", a, context.temp_allocator)
	testing.expect_value(t, len(errs), 0)
	testing.expect_value(t, len(src.files), 3)
	again := pack_archive_make(src, context.temp_allocator)
	testing.expect(t, string(again) == string(a), "read then made again differs")
	testing.expect_value(t, len(pack_hash_text(pack_hash(a))), 16)
}

@(private = "file")
refused :: proc(t: ^testing.T, name: string, data: []u8, want: string) {
	_, errs := pack_archive_read("farmfix", data, context.temp_allocator)
	if !testing.expectf(t, len(errs) == 1, "%s: not refused", name) {return}
	testing.expect_value(t, pack_error_text(errs[0]), want)
}

@(test)
test_pack_archive_refuses_malformed :: proc(t: ^testing.T) {
	good := pack_archive_make(archive_files({0, 1, 2}), context.temp_allocator)
	// Every truncation is refused.
	for n in 0 ..< len(good) {
		_, errs := pack_archive_read("farmfix", good[:n], context.temp_allocator)
		testing.expectf(t, len(errs) == 1, "a truncation to %d bytes was accepted", n)
	}
	refused(
		t,
		"magic",
		transmute([]u8)string("NOPE\x01\x00\x00\x00\x00"),
		"farmfix: not a pack archive; it does not begin with VXPK",
	)
	trailing := make([]u8, len(good) + 1, context.temp_allocator)
	copy(trailing, good)
	refused(t, "trailing", trailing, "farmfix: the archive has bytes after its last file")

	build :: proc(files: []Pack_File) -> []u8 {
		w: Writer
		writer_init(&w, context.temp_allocator)
		append(&w.buf, PACK_ARCHIVE_MAGIC)
		write_u32(&w, PACK_ARCHIVE_VERSION)
		write_varint(&w, u32(len(files)))
		for f in files {
			write_string(&w, f.path)
			write_varint(&w, u32(len(f.data)))
			append(&w.buf, ..f.data)
		}
		return w.buf[:]
	}
	refused(
		t,
		"server file",
		build({{"server/quests/a.json", {1}}}),
		"farmfix/server/quests/a.json: a sent pack has no server/ files; the server keeps them",
	)
	refused(
		t,
		"bad path",
		build({{"data/Blocks.json", {1}}}),
		"farmfix/data/Blocks.json: path has a character outside a-z, 0-9 and _./-",
	)
	refused(
		t,
		"order",
		build({{"data/b.json", {1}}, {"data/a.json", {1}}}),
		"farmfix/data/a.json: paths are not in order, or one is repeated",
	)
	refused(
		t,
		"repeat",
		build({{"data/a.json", {1}}, {"data/a.json", {1}}}),
		"farmfix/data/a.json: paths are not in order, or one is repeated",
	)
	long := make([]u8, 129, context.temp_allocator)
	for &c in long {c = 'a'}
	_, errs := pack_archive_read("farmfix", build({{string(long), {1}}}), context.temp_allocator)
	testing.expect_value(t, len(errs), 1)
	// An oversize file.
	w: Writer
	writer_init(&w, context.temp_allocator)
	append(&w.buf, PACK_ARCHIVE_MAGIC)
	write_u32(&w, PACK_ARCHIVE_VERSION)
	write_varint(&w, 1)
	write_string(&w, "data/a.json")
	write_varint(&w, u32(JSON_MAX_FILE + 1))
	refused(
		t,
		"oversize",
		w.buf[:],
		fmt.tprintf(
			"farmfix/data/a.json: file is over the limits (%d for a file, %d for a pack)",
			JSON_MAX_FILE,
			MAX_PACK_BYTES,
		),
	)
}

// A pack with a byte flipped on the way is caught by its hash, and one whole
// goes to the cache and is found there.
@(test)
test_pack_fetch_checks_and_caches :: proc(t: ^testing.T) {
	archive := pack_archive_make(archive_files({0, 1, 2}), context.temp_allocator)
	sha := pack_hash(archive)
	p := Packs {
		content = 7,
		count   = 1,
	}
	p.entries[0] = {"farmfix", "1.0.0", u32(len(archive)), sha}
	cache := "build/test_pack_fetch_cache"
	os.remove_all(cache)
	defer os.remove_all(cache)

	f: Pack_Fetch
	want, err := pack_fetch_begin(&f, p, cache)
	testing.expect_value(t, err, "")
	testing.expect_value(t, want.count, 1)
	damaged := make([]u8, len(archive), context.temp_allocator)
	copy(damaged, archive)
	damaged[len(damaged) / 2] ~= 1
	got := ""
	for off := 0; off < len(damaged); off += MAX_PACK_PART {
		n := min(MAX_PACK_PART, len(damaged) - off)
		got = pack_fetch_part(&f, {0, u32(off), damaged[off:][:n]})
	}
	testing.expect_value(
		t,
		got,
		fmt.tprintf(
			"pack farmfix arrived damaged (hash %s vs %s)",
			pack_hash_text(pack_hash(damaged)),
			pack_hash_text(sha),
		),
	)
	files, _ := os.read_all_directory_by_path(cache, context.temp_allocator)
	testing.expect_value(t, len(files), 0) // (nothing damaged is kept)
	// Out of order is refused too.
	testing.expect(t, pack_fetch_part(&f, {0, 5, archive[:10]}) != "")
	pack_fetch_destroy(&f)

	// Whole: kept, and the next join wants nothing.
	g: Pack_Fetch
	_, err = pack_fetch_begin(&g, p, cache)
	for off := 0; off < len(archive); off += MAX_PACK_PART {
		n := min(MAX_PACK_PART, len(archive) - off)
		got = pack_fetch_part(&g, {0, u32(off), archive[off:][:n]})
	}
	testing.expect_value(t, got, "")
	testing.expect(t, pack_fetch_complete(&g))
	pack_fetch_destroy(&g)
	h: Pack_Fetch
	want, err = pack_fetch_begin(&h, p, cache)
	testing.expect_value(t, want.count, 0)
	testing.expect(t, pack_fetch_complete(&h))
	sources, errs := pack_fetch_sources(&h)
	testing.expect_value(t, len(errs), 0)
	testing.expect_value(t, len(sources), 1)
	pack_fetch_destroy(&h)
}

// The client builds its registry without server/ files, refuses one, and the
// content hash ignores what only the server has.
@(test)
test_registry_sides :: proc(t: ^testing.T) {
	src := base_pack_source(context.temp_allocator)
	_, errs := registry_build({src}, .Client, context.temp_allocator)
	testing.expect(t, len(errs) > 0, "a client registry took server/ files")
	if len(errs) > 0 {
		testing.expect_value(
			t,
			pack_error_text(errs[0]),
			fmt.tprintf(
				"voxiverse/%s: a client has no server/ files; the server does not send them",
				errs[0].file,
			),
		)
	}
	server, e1 := registry_build({src}, .Server, context.temp_allocator)
	client, e2 := registry_build({pack_source_sent(src)}, .Client, context.temp_allocator)
	testing.expect(t, server != nil && client != nil && len(e1) == 0 && len(e2) == 0)
	if server == nil || client == nil {return}
	testing.expect_value(t, client.hash, server.hash)
	testing.expect_value(t, len(client.structures), 0)
	testing.expect(t, len(server.structures) > 0)
}
