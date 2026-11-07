package music_tool

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

EXPECTATION_FILE :: "assets/music/expectation.bin"
CORPUS_DIR :: "tools/music/testdata/corpus"

// load_corpus reads every .mid in the directory, by name.
load_corpus :: proc(dir: string) -> (pieces: [dynamic]Piece, names: [dynamic]string, ok: bool) {
	files, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		fmt.eprintfln("music ear: cannot read %s: %v", dir, err)
		return
	}
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for f in files {
		if filepath.ext(f.name) != ".mid" {continue}
		path := strings.concatenate({dir, "/", f.name})
		src, rerr := os.read_entire_file_from_path(path, context.allocator)
		if rerr != nil {
			fmt.eprintfln("music ear: cannot read %s", path)
			return
		}
		p, msg, pok := midi_read(src)
		if !pok {
			fmt.eprintfln("%s: %s", path, msg)
			return
		}
		append(&pieces, p)
		append(&names, f.name[:len(f.name) - len(".mid")])
	}
	if len(pieces) == 0 {
		fmt.eprintfln("music ear: no .mid files in %s", dir)
		return
	}
	return pieces, names, true
}

// train_main is `build music ear --train [<dir>]`: it trains the expectation
// on every .mid in the directory and writes EXPECTATION_FILE.
train_main :: proc(dir: string) -> bool {
	pieces, names, ok := load_corpus(dir)
	if !ok {return false}
	m := expectation_train(pieces[:])
	m.names = names
	if werr := os.write_entire_file(EXPECTATION_FILE, expectation_write(&m)); werr != nil {
		fmt.eprintfln("music ear: cannot write %s: %v", EXPECTATION_FILE, werr)
		return false
	}
	fmt.printfln("trained on %d pieces: %s", len(pieces), EXPECTATION_FILE)
	return true
}

// calibrate_main is `build music ear --calibrate [<dir>]`: it prints the AUCs
// and writes BANDS_FILE; on the downloaded corpus it also retrains
// EXPECTATION_FILE.
calibrate_main :: proc(dir: string) -> bool {
	pieces, names, ok := load_corpus(dir)
	if !ok {return false}
	c := calibrate(pieces[:], names[:])
	b: strings.Builder
	calibration_report(c, len(pieces), &b)
	fmt.print(strings.to_string(b))
	text := bands_write(gating_bands(c))
	if werr := os.write_entire_file(BANDS_FILE, transmute([]byte)text); werr != nil {
		fmt.eprintfln("music ear: cannot write %s: %v", BANDS_FILE, werr)
		return false
	}
	fmt.printfln("bands: %s", BANDS_FILE)
	if dir != CORPUS_DIR {return train_main(dir)}
	return true
}

// ear_main is `build music ear [<name>...] [--json]` or `--train [<dir>]`: the
// ear's measures and critique for each score or MIDI file of assets/music, on
// stdout.
ear_main :: proc(args: []string) -> bool {
	as_json := false
	train, calibrating := false, false
	names: [dynamic]string
	for a in args {
		switch {
		case a == "--json":
			as_json = true
		case a == "--train":
			train = true
		case a == "--calibrate":
			calibrating = true
		case strings.has_prefix(a, "--"):
			fmt.eprintfln("music ear: unknown option '%s' (--json, --train, --calibrate)", a)
			return false
		case:
			append(&names, a)
		}
	}
	if calibrating {
		if train || len(names) > 1 {
			fmt.eprintln("music ear: --calibrate takes one directory and no --train")
			return false
		}
		if len(names) == 1 {return calibrate_main(names[0])}
		if os.is_dir(CORPUS_DOWNLOAD_DIR) {
			if _, _, found := load_corpus(CORPUS_DOWNLOAD_DIR); found {
				return calibrate_main(CORPUS_DOWNLOAD_DIR)
			}
		}
		return calibrate_main(CORPUS_DIR)
	}
	if train {
		if len(names) > 1 {
			fmt.eprintln("music ear: --train takes one directory")
			return false
		}
		return train_main(names[0] if len(names) == 1 else CORPUS_DIR)
	}
	bytes, derr := os.read_entire_file_from_path(EXPECTATION_FILE, context.allocator)
	model, mok := expectation_read(bytes)
	if derr != nil || !mok {
		fmt.eprintfln("music ear: cannot read %s (build music ear --train)", EXPECTATION_FILE)
		return false
	}
	files, err := os.read_all_directory_by_path(MUSIC_DIR, context.allocator)
	if err != nil {
		fmt.eprintfln("music: cannot read %s: %v", MUSIC_DIR, err)
		return false
	}
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	ears: [dynamic]Ear
	ok := true
	for f in files {
		ext := filepath.ext(f.name)
		if ext != ".score" && ext != ".mid" {continue}
		stem := f.name[:len(f.name) - len(ext)]
		if len(names) > 0 && !contains(names[:], stem) && !contains(names[:], f.name) {continue}
		path := strings.concatenate({MUSIC_DIR, "/", f.name})
		src, rerr := os.read_entire_file_from_path(path, context.allocator)
		if rerr != nil {
			fmt.eprintfln("music: cannot read %s", path)
			ok = false
			continue
		}
		piece: Piece
		if ext == ".score" {
			p, msg, pok := score_parse(string(src), path)
			if !pok {
				fmt.eprintln(msg)
				ok = false
				continue
			}
			piece = p
		} else {
			p, msg, pok := midi_read(src)
			if !pok {
				fmt.eprintfln("%s: %s", path, msg)
				ok = false
				continue
			}
			piece = p
		}
		append(&ears, listen(&piece, stem, path, &model))
	}
	if len(ears) == 0 {
		fmt.eprintln("music ear: nothing to listen to")
		return len(names) == 0 && ok
	}
	if as_json {
		data, jerr := json.marshal(ears[:], {pretty = true, use_spaces = true})
		if jerr != nil {
			fmt.eprintfln("music ear: %v", jerr)
			return false
		}
		fmt.println(string(data))
		return ok
	}
	b: strings.Builder
	for e, i in ears {
		if i > 0 {fmt.sbprintln(&b)}
		ear_report(e, &b)
	}
	fmt.print(strings.to_string(b))
	return ok
}
