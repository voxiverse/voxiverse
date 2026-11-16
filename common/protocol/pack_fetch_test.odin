package protocol

import "core:fmt"
import "core:os"
import "core:testing"

import "common:game"

// A pack with a byte flipped on the way is caught by its hash, and one whole
// goes to the cache and is found there.
@(test)
test_pack_fetch_checks_and_caches :: proc(t: ^testing.T) {
	archive := game.pack_archive_make(game.archive_files({0, 1, 2}), context.temp_allocator)
	sha := game.pack_hash(archive)
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
			game.pack_hash_text(game.pack_hash(damaged)),
			game.pack_hash_text(sha),
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
