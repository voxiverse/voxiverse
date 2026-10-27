package music_tool

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import "../../client/audio"

MUSIC_DIR :: "assets/music"
WORK_DIR :: "build/music-out" // (build/music is the tool itself)

// Renders the scores and MIDI files of assets/music to Ogg Vorbis through a
// soundfont, with a metadata file beside each:
//
//	build music [<name>...] [--force] [--wav <dir>] [--midi]
//	build music --audition <name> [--from <seconds>]
//
//	--force     render every piece, not only those whose source or soundfont changed
//	--wav <dir> keep each piece's float master as a WAV
//	--midi      write build/music-out/<name>.mid from each score, to open in a notation editor
//	--audition  play assets/music/<name>.ogg on the default device (looping if its .json says
//	            so) until Enter is pressed; --from starts that many seconds in
//
// VX_SOUNDFONT=/path/file.sf2 renders with that soundfont.
main :: proc() {
	context.allocator = context.temp_allocator
	force, midi := false, false
	wav_dir: string
	names: [dynamic]string
	audition: string
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

	sf: Soundfont
	sf_sha: string
	if !midi {
		path := soundfont_path() or_return
		data, rerr := os.read_entire_file_from_path(path, context.allocator)
		if rerr != nil {
			fmt.eprintfln("music: cannot read %s", path)
			return false
		}
		sf_sha = sha256_hex(data)
		msg: string
		ok: bool
		sf, msg, ok = sf2_read(data)
		if !ok {
			fmt.eprintfln("music: %s: %s", path, msg)
			return false
		}
	}
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
		src_sha := sha256_hex(src)
		json_path := strings.concatenate({MUSIC_DIR, "/", stem, ".json"})
		ogg_path := strings.concatenate({MUSIC_DIR, "/", stem, ".ogg"})
		if !force && up_to_date(json_path, ogg_path, src_sha, sf_sha) {
			fmt.printfln("music: %s is up to date", stem)
			continue
		}
		fmt.printfln("music: rendering %s", stem)
		stereo := render(&piece, &sf)
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
