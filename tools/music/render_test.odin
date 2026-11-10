package music_tool

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

// CI refuses a stale render: for every assets/music/*.score, the .json beside it
// has the score's current SHA-256 (source_sha256) and the fonts' (soundfont_sha256);
// a mismatch fails with "render it: build music".
@(test)
test_rendered_music_is_fresh :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	files, err := os.read_all_directory_by_path(MUSIC_DIR, context.allocator)
	testing.expect(t, err == nil, "read assets/music")
	checked := 0
	for f in files {
		if !strings.has_suffix(f.name, ".score") {continue}
		stem := f.name[:len(f.name) - len(".score")]
		if contains(UNRENDERED, stem) {continue}
		checked += 1
		score_path := strings.concatenate({MUSIC_DIR, "/", f.name})
		json_path := strings.concatenate({MUSIC_DIR, "/", stem, ".json"})
		ogg_path := strings.concatenate({MUSIC_DIR, "/", stem, ".ogg"})

		testing.expectf(t, os.exists(json_path), "%s has no .json: render it: build music", stem)
		testing.expectf(t, os.exists(ogg_path), "%s has no .ogg: render it: build music", stem)

		src, rerr := os.read_entire_file_from_path(score_path, context.allocator)
		if !testing.expectf(t, rerr == nil, "cannot read %s", score_path) {continue}
		text := text_lf(string(src))
		src_sha := sha256_hex(transmute([]u8)text)

		piece, _, pok := score_parse(text, score_path)
		if !testing.expectf(t, pok, "cannot parse %s", score_path) {continue}
		expected_sf := fonts_expected_sha256(&piece)

		data, jerr := os.read_entire_file_from_path(json_path, context.allocator)
		if !testing.expectf(t, jerr == nil, "cannot read %s", json_path) {continue}
		d: Done
		if !testing.expectf(
			t,
			json.unmarshal(data, &d) == nil,
			"cannot parse %s",
			json_path,
		) {continue}

		testing.expectf(
			t,
			d.source_sha256 == src_sha,
			"%s.score changed (got %s, json has %s): render it: build music",
			stem,
			src_sha,
			d.source_sha256,
		)
		testing.expectf(
			t,
			d.soundfont_sha256 == expected_sf,
			"%s font changed (expected %s, json has %s): render it: build music",
			stem,
			expected_sf,
			d.soundfont_sha256,
		)
	}
	testing.expect(t, checked >= 7, "checked at least 7 scores")
}

@(test)
test_stale_score_fails_freshness_check :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	fake_score := "title \"Fake\"\ntempo 120\n"
	fake_sha := sha256_hex(transmute([]u8)fake_score)
	d := Done {
		source_sha256    = "0000000000000000000000000000000000000000000000000000000000000000",
		soundfont_sha256 = SOUNDFONT_SHA256,
	}
	testing.expect(t, d.source_sha256 != fake_sha, "stale score detected")
}
