package music_tool

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// ear_main is `build music ear [<name>...] [--json]`: the ear's measures and
// critique for each score or MIDI file of assets/music, on stdout.
ear_main :: proc(args: []string) -> bool {
	as_json := false
	names: [dynamic]string
	for a in args {
		switch {
		case a == "--json":
			as_json = true
		case strings.has_prefix(a, "--"):
			fmt.eprintfln("music ear: unknown option '%s' (--json)", a)
			return false
		case:
			append(&names, a)
		}
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
		append(&ears, listen(&piece, stem, path))
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
