package build

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

MUSIC_DIR :: "assets/music"
MUSIC_UNRENDERED := []string{"ignite"}

SOUNDFONT_PATH :: "assets/music/voxiverse.sf2"
SOUNDFONT_SHA256 :: "e402377d330065a3c1db59d32ddc341184b7b0e8f990e08aa9f3db35e7ab8f78"

music_score_fonts_sha256 :: proc(score_text: string) -> string {
	return SOUNDFONT_SHA256
}

// music_text_lf drops CR so a Windows CRLF score matches the LF bytes hashed
// into its render metadata (same rule as tools/music text_lf). build run's
// stale check must use this or it re-renders on every Windows checkout rewrite.
music_text_lf :: proc(src: string, allocator := context.allocator) -> string {
	if strings.index_byte(src, '\r') < 0 {return src}
	out := make([]u8, len(src), allocator)
	n := 0
	for i in 0 ..< len(src) {
		if src[i] != '\r' {
			out[n] = src[i]
			n += 1
		}
	}
	return string(out[:n])
}

Music_Done :: struct {
	source_sha256:    string,
	soundfont_sha256: string,
}

Music_Stale_Piece :: struct {
	name:   string,
	reason: string,
}

music_check_stale :: proc(dir := MUSIC_DIR) -> (stale: [dynamic]Music_Stale_Piece) {
	stale = make([dynamic]Music_Stale_Piece, context.temp_allocator)
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return}
	for f in files {
		if !strings.has_suffix(f.name, ".score") {continue}
		stem := f.name[:len(f.name) - len(".score")]
		if slice.contains(MUSIC_UNRENDERED, stem) {continue}
		score_path := path_join({dir, f.name})
		json_path := path_join({dir, fmt.tprintf("%s.json", stem)})
		ogg_path := path_join({dir, fmt.tprintf("%s.ogg", stem)})

		if !os.exists(json_path) || !os.exists(ogg_path) {
			append(&stale, Music_Stale_Piece{name = stem, reason = "the score changed"})
			continue
		}
		score_bytes, rerr := os.read_entire_file_from_path(score_path, context.temp_allocator)
		if rerr != nil {continue}
		score_text := music_text_lf(string(score_bytes), context.temp_allocator)
		sh := hash.hash_bytes(.SHA256, transmute([]u8)score_text, context.temp_allocator)
		src_sha := string(hex.encode(sh[:], context.temp_allocator))

		jbytes, jerr := os.read_entire_file_from_path(json_path, context.temp_allocator)
		if jerr != nil {
			append(&stale, Music_Stale_Piece{name = stem, reason = "the score changed"})
			continue
		}
		done: Music_Done
		if json.unmarshal(jbytes, &done, allocator = context.temp_allocator) != nil {
			append(&stale, Music_Stale_Piece{name = stem, reason = "the score changed"})
			continue
		}
		if done.source_sha256 != src_sha {
			append(&stale, Music_Stale_Piece{name = stem, reason = "the score changed"})
			continue
		}
		expected_sf := music_score_fonts_sha256(score_text)
		if done.soundfont_sha256 != expected_sf {
			append(&stale, Music_Stale_Piece{name = stem, reason = "the font changed"})
			continue
		}
	}
	return
}

music_ensure_rendered :: proc() -> bool {
	stale := music_check_stale()
	if len(stale) == 0 {return true}

	names := make([dynamic]string, context.temp_allocator)
	for s in stale {
		append(&names, s.name)
	}

	exe, ok := build_tool("music")
	if !ok {
		fmt.eprintln("music: could not build music tool")
		return false
	}
	cmd := slice.concatenate([][]string{{exe}, names[:]}, context.temp_allocator)
	if !run(cmd) {
		fmt.eprintln("music: could not render music")
		return false
	}
	return true
}

// music_command runs the music tool; when it re-rendered a piece (an Ogg in
// assets/music changed), it updates everything a render touches in the same
// run, so a render cannot ship without them: the decoder's digests and
// reference windows (`ogg digests`, `ogg reference`) and the audio baseline
// that plays the music (`audio --accept music_session`).
music_command :: proc(args: []string) -> bool {
	before := music_ogg_stamps()
	if !run_tool("music", args, release = true) {return false}
	after := music_ogg_stamps()
	changed := make([dynamic]string, context.temp_allocator)
	for name, stamp in after {
		if old, had := before[name]; !had || old != stamp {append(&changed, name)}
	}
	if len(changed) == 0 {return true}
	slice.sort(changed[:])
	fmt.printfln(
		"music: %s re-rendered: updating the digests, reference windows and baseline",
		strings.join(changed[:], ", ", context.temp_allocator),
	)
	if !run_tool("ogg", {"digests"}, release = true) {return false}
	if !run_tool("ogg", {"reference"}, release = true) {return false}
	if !audio_baselines({"--accept", "music_session"}) {return false}
	fmt.println("music: digests, reference windows and baseline music_session updated")
	return true
}

// music_ogg_stamps: each rendered piece's size and modification time.
@(private = "file")
music_ogg_stamps :: proc() -> map[string][2]i64 {
	stamps := make(map[string][2]i64, context.temp_allocator)
	files, err := os.read_all_directory_by_path(MUSIC_DIR, context.temp_allocator)
	if err != nil {return stamps}
	for f in files {
		if !strings.has_suffix(f.name, ".ogg") {continue}
		stamps[f.name] = {f.size, f.modification_time._nsec}
	}
	return stamps
}
