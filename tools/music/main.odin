package music_tool

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import "client:audio"

MUSIC_DIR :: "assets/music"
WORK_DIR :: "build/music-out" // (build/music is the tool itself)

// Renders the scores and MIDI files of assets/music to Ogg Vorbis through a
// soundfont, with a metadata file beside each:
//
//	build music [<name>...] [--force] [--wav <dir>] [--midi]
//	build music --audition <name> [--from <seconds>]
//	build music ear [<name>...] [--json]
//	build music ear --calibrate [<dir>]
//	build music --audition-instruments [--wav <dir>]
//	build music corpus
//
//	--force     render every piece, not only those whose source or soundfont changed
//	--wav <dir> keep each piece's float master as a WAV
//	--midi      write build/music-out/<name>.mid from each score, to open in a notation editor
//	--audition-instruments  render each instrument's C2-C7 scale at pp, mf and ff to a WAV per
//	            instrument (build/music-out/instruments, or --wav <dir>)
//	--audition  play assets/music/<name>.ogg on the default device (looping if its .json says
//	            so) until Enter is pressed; --from starts that many seconds in
//
// `corpus` downloads the public-domain MIDI files of tools/music/corpus.txt into
// build/tools/music-corpus, each pinned by its SHA-256 (docs/audio.md, "The ear").
// `ear` prints the measures and the critique of each score (docs/audio.md, "The ear").
//
// VX_SOUNDFONT=/path/file.sf2 renders with that soundfont.
main :: proc() {
	context.allocator = context.temp_allocator
	if len(os.args) > 1 && os.args[1] == "ear" {
		if !ear_main(os.args[2:]) {os.exit(1)}
		return
	}
	if len(os.args) > 1 && os.args[1] == "corpus" {
		if !corpus_download() {os.exit(1)}
		return
	}
	force, midi := false, false
	wav_dir: string
	names: [dynamic]string
	audition: string
	instruments := false
	from: f32
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--audition", "--from":
			i += 1
			if i >= len(args) {
				fmt.eprintfln("music: %s needs a value", args[i - 1])
				os.exit(2)
			}
			if args[i - 1] == "--audition" {
				audition = args[i]
			} else if v, ok := strconv.parse_f32(args[i]); ok && v >= 0 {
				from = v
			} else {
				fmt.eprintfln("music: --from wants seconds, not '%s'", args[i])
				os.exit(2)
			}
		case "--audition-instruments":
			instruments = true
		case "--force":
			force = true
		case "--midi":
			midi = true
		case "--wav":
			i += 1
			if i >= len(args) {
				fmt.eprintln("music: --wav needs a directory")
				os.exit(2)
			}
			wav_dir = args[i]
		case:
			if strings.has_prefix(args[i], "--") {
				fmt.eprintfln("music: unknown option '%s' (--force, --wav <dir>, --midi)", args[i])
				os.exit(2)
			}
			append(&names, args[i])
		}
	}
	if instruments {
		if !audition_instruments(wav_dir) {os.exit(1)}
		return
	}
	if audition != "" {
		if !play_audition(audition, from) {os.exit(1)}
		return
	}
	if !run(names[:], force, midi, wav_dir) {os.exit(1)}
}

Done :: struct {
	source_sha256:    string,
	soundfont_sha256: string,
}

run :: proc(names: []string, force, midi: bool, wav_dir: string) -> bool {
	files, err := os.read_all_directory_by_path(MUSIC_DIR, context.allocator)
	if err != nil {
		fmt.eprintfln("music: cannot read %s: %v", MUSIC_DIR, err)
		return false
	}
	sources: [dynamic]string
	for f in files {
		ext := filepath.ext(f.name)
		if ext != ".score" && ext != ".mid" {continue}
		stem := f.name[:len(f.name) - len(ext)]
		if len(names) > 0 && !contains(names, stem) && !contains(names, f.name) {continue}
		append(&sources, f.name)
	}
	if len(sources) == 0 {
		fmt.eprintln("music: nothing to render")
		return len(names) == 0
	}
	os.make_directory_all(WORK_DIR)
	if wav_dir != "" {os.make_directory_all(wav_dir)}

	cache: map[string]^Loaded_Font
	all_ok := true
	for name in sources {
		ext := filepath.ext(name)
		stem := name[:len(name) - len(ext)]
		path := strings.concatenate({MUSIC_DIR, "/", name})
		src, rerr := os.read_entire_file_from_path(path, context.allocator)
		if rerr != nil {
			fmt.eprintfln("music: cannot read %s", path)
			all_ok = false
			continue
		}
		piece: Piece
		if ext == ".score" {
			p, msg, ok := score_parse(string(src), path)
			if !ok {
				fmt.eprintln(msg)
				all_ok = false
				continue
			}
			piece = p
		} else {
			p, msg, ok := midi_read(src)
			if !ok {
				fmt.eprintfln("%s: %s", path, msg)
				all_ok = false
				continue
			}
			piece = p
		}
		if piece.title == "" {piece.title = stem}
		if midi {
			out := strings.concatenate({WORK_DIR, "/", stem, ".mid"})
			if os.write_entire_file(out, midi_write(&piece)) != nil {
				fmt.eprintfln("music: cannot write %s", out)
				all_ok = false
				continue
			}
			fmt.printfln("music: wrote %s", out)
			continue
		}
		fonts: map[string]^Soundfont
		sf_sha: string
		fonts_ok: bool
		if fonts, fonts_ok = fonts_load(&piece, &cache); !fonts_ok {
			all_ok = false
			continue
		}
		sf_sha = fonts_sha256(&piece, cache)
		src_sha := sha256_hex(src)
		json_path := strings.concatenate({MUSIC_DIR, "/", stem, ".json"})
		ogg_path := strings.concatenate({MUSIC_DIR, "/", stem, ".ogg"})
		if !force && up_to_date(json_path, ogg_path, src_sha, sf_sha) {
			fmt.printfln("music: %s is up to date", stem)
			continue
		}
		fmt.printfln("music: rendering %s", stem)
		stereo := render_with(&piece, fonts)
		m, ok := master(&piece, stereo)
		if !ok {
			fmt.eprintfln(
				"music: %s renders to silence or has a loop longer than its render",
				stem,
			)
			all_ok = false
			continue
		}
		if m.shortfall_db > 0.05 {
			fmt.eprintfln(
				"warning: %s is %.1f LU under the target to keep its peaks under -1 dBTP",
				stem,
				m.shortfall_db,
			)
		}
		if wav_dir != "" {
			audio.wav_write(strings.concatenate({wav_dir, "/", stem, ".wav"}), m.stereo, RATE)
		}
		wav := strings.concatenate({WORK_DIR, "/", stem, ".wav"})
		if os.write_entire_file(wav, wav24_encode(m.stereo, RATE)) != nil {
			fmt.eprintfln("music: cannot write %s", wav)
			all_ok = false
			continue
		}
		if !encode(wav, ogg_path) {
			all_ok = false
			continue
		}
		meta := Meta{name, src_sha, sf_sha, RATE}
		js := metadata_json(&piece, m, meta)
		if os.write_entire_file(json_path, transmute([]u8)js) != nil {
			fmt.eprintfln("music: cannot write %s", json_path)
			all_ok = false
			continue
		}
		fmt.printfln(
			"music: %s: %d frames, %.1f LUFS, %.1f dBTP",
			stem,
			m.frames,
			m.lufs,
			m.true_peak_db,
		)
	}
	return all_ok
}

contains :: proc(list: []string, s: string) -> bool {
	for x in list {
		if x == s {return true}
	}
	return false
}

up_to_date :: proc(json_path, ogg_path, src_sha, sf_sha: string) -> bool {
	if !os.exists(ogg_path) {return false}
	data, err := os.read_entire_file_from_path(json_path, context.allocator)
	if err != nil {return false}
	d: Done
	if json.unmarshal(data, &d) != nil {return false}
	return d.source_sha256 == src_sha && d.soundfont_sha256 == sf_sha
}

// play_audition plays a rendered piece on the default device, on the Music
// bus, until Enter is pressed.
play_audition :: proc(name: string, from: f32) -> bool {
	ogg, err := os.read_entire_file_from_path(
		strings.concatenate({MUSIC_DIR, "/", name, ".ogg"}),
		context.allocator,
	)
	if err != nil {
		fmt.eprintfln("music: no %s/%s.ogg (build music %s first)", MUSIC_DIR, name, name)
		return false
	}
	Info :: struct {
		loop: bool,
	}
	info: Info
	if js, jerr := os.read_entire_file_from_path(
		strings.concatenate({MUSIC_DIR, "/", name, ".json"}),
		context.allocator,
	); jerr == nil {
		json.unmarshal(js, &info)
	}
	m := new(audio.Mixer)
	audio.mixer_init(m, audio.DEVICE_RATE)
	id, ok := audio.add_stream(m, ogg, loop = info.loop, start = from)
	if !ok {
		fmt.eprintfln("music: %s.ogg does not decode", name)
		return false
	}
	dev: audio.Device
	if !audio.device_open(&dev, m) {
		fmt.eprintln("music: no audio device")
		return false
	}
	audio.play(m, {sound = id, gain = {1, 1}, pitch = 1, bus = .Music})
	fmt.printfln(
		"music: playing %s%s from %.1f s; press Enter to stop",
		name,
		" (looping)" if info.loop else "",
		from,
	)
	key: [1]u8
	os.read(os.stdin, key[:])
	audio.device_close(&dev)
	audio.streams_close(m)
	return true
}

// audition_instruments renders the C2-C7 scale (C major, a note of half a
// second, then pp, mf and ff one after the other) of every preset of every
// font to build/music-out/instruments/<font>.<preset>.wav, or into --wav <dir>.
audition_instruments :: proc(wav_dir: string) -> bool {
	dir := wav_dir if wav_dir != "" else strings.concatenate({WORK_DIR, "/instruments"})
	os.make_directory_all(dir)
	cache: map[string]^Loaded_Font
	all_ok := true
	for def in FONTS {
		p := piece_defaults()
		append(&p.parts, Part{name = "a", font = def.name})
		fonts, ok := fonts_load(&p, &cache)
		if !ok {all_ok = false; continue}
		sf := fonts[def.name]
		for preset in sf.presets {
			q := scale_piece(def.name, preset)
			x := render_with(&q, fonts)
			name := strings.concatenate({dir, "/", def.name, ".", sanitize(preset.name), ".wav"})
			if !audio.wav_write(name, x, RATE) {
				fmt.eprintfln("music: cannot write %s", name)
				all_ok = false
				continue
			}
			fmt.printfln("music: wrote %s", name)
		}
	}
	return all_ok
}

@(private = "file")
sanitize :: proc(s: string) -> string {
	b := transmute([]u8)strings.clone(s)
	for &c in b {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {c = '_'}
	}
	return string(b)
}

// scale_piece: the audition's notes for one preset, one part.
scale_piece :: proc(font: string, preset: Sf_Preset) -> Piece {
	p := piece_defaults()
	p.reverb_wet = 0
	p.humanize_ms, p.humanize_vel = 0, 0
	part := Part {
		name = "a",
		font = font,
	}
	if sf_is_named_font(
		font,
	) {part.preset = preset.name} else {part.bank, part.program = preset.bank, u8(preset.preset)}
	append(&p.parts, part)
	append(&p.tempos, Tempo{0, 120})
	append(&p.meters, Meter{0, 4, 4})
	steps := [?]int{0, 2, 4, 5, 7, 9, 11}
	tick := u32(0)
	for vel in ([]u8{32, 64, 110}) {
		for octave in 2 ..= 6 {
			for s in steps {
				append(&p.notes, Note{tick, PPQ / 2 * 2 - 1, u8(12 * (octave + 1) + s), vel, 0})
				tick += PPQ
			}
		}
		append(&p.notes, Note{tick, PPQ * 2 - 1, 96, vel, 0}) // C7
		tick += PPQ * 3
	}
	p.end = tick
	return p
}

@(private = "file")
sf_is_named_font :: proc(font: string) -> bool {
	def, _ := font_def(font)
	return font_source(def).kind == .Sfz
}
