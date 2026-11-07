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

Music_Font_Def :: struct {
	name:        string,
	base:        string,
	felt:        bool,
	font_sha256: string,
}

MUSIC_FONTS := []Music_Font_Def {
	{
		name = "piano",
		font_sha256 = "cf2a98eb38a32c4954b4b6e2caae4112d62dd8e892eceefdd7942b0e7d01ac2f",
	},
	{name = "felt", base = "piano", felt = true},
	{
		name = "freepats_harp",
		font_sha256 = "1796607b3c7dc9ce0d98473c33068ea4c20ab3dfda38a44f157ee10bfed6ccb4",
	},
	{
		name = "freepats_bells",
		font_sha256 = "c65f95fa73d881aaaf317029b749abb8b99efb1c1838fb0f34855c5a7188a9eb",
	},
	{
		name = "freepats_timpani",
		font_sha256 = "f4f133d63bca297c98143e95c1f3fe5418a2a51d7b1f4d5470971eec7885d87b",
	},
	{
		name = "freepats_choir",
		font_sha256 = "8688e074a15a40f2d9a251f9a642f67f91b1667ba6f4a1e765b9ee7347260c2d",
	},
	{
		name = "freepats_sweep",
		font_sha256 = "5a09a1d8ab60d236907572a46af8b4211881e2f8c7325e75f782ad5d7acce433",
	},
	{
		name = "freepats_bowed",
		font_sha256 = "d20b2c26757c58665f83850515d68a7ecee11a87103f849be2406f026f9cf52a",
	},
	{
		name = "freepats_synthstrings",
		font_sha256 = "7df5074a9ca497adfc3b63a3501a9244495dbb3334b05bba00789bf83cfe6cd4",
	},
	{
		name = "freepats_recorder",
		font_sha256 = "fb89e90e6b8b40e6463c7edab8cbf4583abbd8fa2d3e32a9250ce7b91d480722",
	},
	{
		name = "freepats_ocarina",
		font_sha256 = "e92c42a68cb738663748ce512dfbc7f18c3c3ea38d12df9ce165b249e6da6bc6",
	},
	{
		name = "freepats_glass",
		font_sha256 = "c86204d29aa2cb660b00d074468dbfc642cd9b93bdfe639555ba008a6c283968",
	},
}

music_font_def :: proc(name: string) -> (Music_Font_Def, bool) {
	n := name if name != "" else "piano"
	for f in MUSIC_FONTS {
		if f.name == n {return f, true}
	}
	return {}, false
}

music_font_source :: proc(def: Music_Font_Def) -> Music_Font_Def {
	if def.base == "" {return def}
	d, _ := music_font_def(def.base)
	return d
}

music_score_fonts_sha256 :: proc(score_text: string) -> string {
	used := make([dynamic]string, context.temp_allocator)
	lines := strings.split_lines(score_text, context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "instrument ") {
			fields := strings.fields(trimmed, context.temp_allocator)
			font_name := "piano"
			for i := 0; i < len(fields) - 1; i += 1 {
				if fields[i] == "font" {
					font_name = fields[i + 1]
					break
				}
			}
			if !slice.contains(used[:], font_name) {append(&used, font_name)}
		}
	}
	if len(used) == 0 {
		append(&used, "piano")
	}
	if len(used) == 1 && used[0] == "piano" {
		piano, _ := music_font_def("piano")
		return piano.font_sha256
	}
	slice.sort(used[:])
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for name in used {
		def, ok := music_font_def(name)
		if !ok {continue}
		src := music_font_source(def)
		fmt.sbprintf(&b, "%s=%s\n", name, src.font_sha256)
		if def.felt {strings.write_string(&b, "felt=1\n")}
	}
	h := hash.hash_string(.SHA256, strings.to_string(b), context.temp_allocator)
	return string(hex.encode(h[:], context.temp_allocator))
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
		sh := hash.hash_bytes(.SHA256, score_bytes, context.temp_allocator)
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
		expected_sf := music_score_fonts_sha256(string(score_bytes))
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
		fmt.eprintln(
			"warning: cannot render music (offline or no 7z/bsdtar); running with old audio",
		)
		return true
	}
	cmd := slice.concatenate([][]string{{exe}, names[:]}, context.temp_allocator)
	if !run(cmd) {
		fmt.eprintln(
			"warning: cannot render music (offline or no 7z/bsdtar); running with old audio",
		)
		return true
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
