package build

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:testing"

// The clean repository has all music up to date.
@(test)
test_music_check_stale_clean_tree :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	stale := music_check_stale(MUSIC_DIR)
	testing.expectf(t, len(stale) == 0, "expected 0 stale pieces, got %d", len(stale))
}

// A CRLF working copy of a score whose LF form matches the metadata is not stale:
// Windows editors rewrite eol=lf files; that must not force build run to re-render.
@(test)
test_music_check_stale_ignores_crlf_on_score :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	dir := "build/tmp/music_crlf_stale_test"
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)

	lf := "title \"Test\"\ntempo 100\n"
	crlf := "title \"Test\"\r\ntempo 100\r\n"
	h := hash.hash_bytes(.SHA256, transmute([]u8)lf, context.temp_allocator)
	src_sha := hex.encode(h[:], context.temp_allocator)

	_ = os.write_entire_file(path_join({dir, "testpiece.score"}), crlf)
	_ = os.write_entire_file(path_join({dir, "testpiece.ogg"}), []u8{0})
	_ = os.write_entire_file(
		path_join({dir, "testpiece.json"}),
		fmt.tprintf(
			"{{\n  \"source_sha256\": %q,\n  \"soundfont_sha256\": %q\n}}\n",
			src_sha,
			SOUNDFONT_SHA256,
		),
	)

	stale := music_check_stale(dir)
	testing.expectf(
		t,
		len(stale) == 0,
		"CRLF score matching LF hash must not be stale, got %d",
		len(stale),
	)
}

// A score changed locally is detected by the build tool's check with reason "the score changed".
@(test)
test_music_check_stale_detects_changed_score :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	dir := "build/tmp/music_stale_test"
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)

	score_path := path_join({dir, "testpiece.score"})
	json_path := path_join({dir, "testpiece.json"})
	ogg_path := path_join({dir, "testpiece.ogg"})

	_ = os.write_entire_file(score_path, "title \"Test\"\ntempo 100\n")
	_ = os.write_entire_file(ogg_path, []u8{0})

	json_content := fmt.tprintf(
		"{{\n  \"source_sha256\": \"0000000000000000000000000000000000000000000000000000000000000000\",\n  \"soundfont_sha256\": %q\n}}\n",
		SOUNDFONT_SHA256,
	)
	_ = os.write_entire_file(json_path, json_content)

	stale := music_check_stale(dir)
	if testing.expect_value(t, len(stale), 1) {
		testing.expect_value(t, stale[0].name, "testpiece")
		testing.expect_value(t, stale[0].reason, "the score changed")
	}
}

// A font change is detected by the build tool's check with reason "the font changed".
@(test)
test_music_check_stale_detects_changed_font :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	dir := "build/tmp/music_font_stale_test"
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)

	score_path := path_join({dir, "testpiece.score"})
	json_path := path_join({dir, "testpiece.json"})
	ogg_path := path_join({dir, "testpiece.ogg"})

	score_content := "title \"Test\"\ntempo 100\n"
	_ = os.write_entire_file(score_path, score_content)
	_ = os.write_entire_file(ogg_path, []u8{0})

	score_bytes, _ := os.read_entire_file_from_path(score_path, context.temp_allocator)
	h := hash.hash_bytes(.SHA256, score_bytes, context.temp_allocator)
	src_sha := hex.encode(h[:], context.temp_allocator)

	json_content := fmt.tprintf(
		"{{\n  \"source_sha256\": %q,\n  \"soundfont_sha256\": \"wrong_font_hash\"\n}}\n",
		src_sha,
	)
	_ = os.write_entire_file(json_path, json_content)

	stale := music_check_stale(dir)
	if testing.expect_value(t, len(stale), 1) {
		testing.expect_value(t, stale[0].name, "testpiece")
		testing.expect_value(t, stale[0].reason, "the font changed")
	}
}

// A missing render (.json or .ogg missing) is detected as stale.
@(test)
test_music_check_stale_detects_missing_render :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	dir := "build/tmp/music_missing_test"
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)

	score_path := path_join({dir, "testpiece.score"})
	_ = os.write_entire_file(score_path, "title \"Test\"\n")

	stale := music_check_stale(dir)
	if testing.expect_value(t, len(stale), 1) {
		testing.expect_value(t, stale[0].name, "testpiece")
	}
}

// In a clean tree, music_ensure_rendered succeeds immediately.
@(test)
test_music_ensure_rendered_clean_returns_true :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	testing.expect(t, music_ensure_rendered(), "clean tree returns true")
}
