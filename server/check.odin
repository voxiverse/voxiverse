package server

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "../common/game"

// universe_check: is the universe in dir whole? Read-only; run it after
// store_recover (the dedicated server's --check does). It reads every file the
// way the loaders do and says what does not read: the crash tests' oracle.

Check_Report :: struct {
	ok:         bool,
	format:     int,
	generation: u64,
	problems:   [dynamic]string, // (temp allocator)
	reg:        ^game.Registry, // the universe's packs, built to read its files
}

@(private = "file")
problem :: proc(r: ^Check_Report, format: string, args: ..any) {
	append(&r.problems, fmt.tprintf(format, ..args))
}

// text_keys: the "key = value" lines of a config text.
text_value :: proc(text, key: string) -> (value: string, found: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		if eq := strings.index_byte(l, '='); eq > 0 && strings.trim_space(l[:eq]) == key {
			return strings.trim_space(l[eq + 1:]), true
		}
	}
	return
}

universe_check :: proc(dir: string) -> (r: Check_Report) {
	r.problems = make([dynamic]string, context.temp_allocator)
	check_universe(&r, dir)
	if r.reg != nil {game.registry_destroy(r.reg)}
	r.ok = len(r.problems) == 0
	return
}

@(private = "file")
check_universe :: proc(r: ^Check_Report, dir: string) {
	files := make([dynamic]string, context.temp_allocator)
	walk_files(dir, "", &files)
	for rel in files {
		if strings.has_suffix(rel, ".new") || strings.has_suffix(rel, ".tmp") || rel == TX_FILE {
			problem(r, "an unfinished save left %s", rel)
		}
	}
	data, err := os.read_entire_file_from_path(
		full_path(dir, UNIVERSE_FILE),
		context.temp_allocator,
	)
	if err != nil {
		problem(r, "%s does not read (%v)", UNIVERSE_FILE, err)
		return
	}
	text := string(data)
	if v, ok := text_value(text, "format"); ok {r.format, _ = strconv.parse_int(v)} else {
		problem(r, "%s has no format", UNIVERSE_FILE)
	}
	if v, ok := text_value(text, "generation"); ok {r.generation, _ = strconv.parse_u64(v, 10)}
	if r.format > SAVE_FORMAT {problem(r, "format %d is newer than this game's", r.format)}
	if r.format < SAVE_FORMAT {problem(r, "format %d: %s", r.format, OLDER_BUILD)}
	packs_text, _ := text_value(text, "packs")
	reg, why := packs_registry(dir, packs_parse(packs_text, context.temp_allocator))
	if reg == nil {
		for p in why {problem(r, "packs: %s", p)}
		return
	}
	r.reg = reg
	if _, ok := text_value(text, "home"); !ok {problem(r, "%s has no home world", UNIVERSE_FILE)}
	worlds, _ := os.read_all_directory_by_path(full_path(dir, WORLDS_DIR), context.temp_allocator)
	for e in worlds {
		if e.type == .Directory {check_world(r, dir, fmt.tprintf("%s/%s", WORLDS_DIR, e.name))}
	}
	for rel in files {
		if strings.has_suffix(rel, ".json") &&
		   (strings.has_prefix(rel, CHARACTERS_DIR + "/") ||
				   strings.has_prefix(rel, PLAYERS_DIR + "/")) {
			check_json(r, dir, rel)
		}
	}
	return
}

@(private = "file")
check_json :: proc(r: ^Check_Report, dir, rel: string) {
	data, err := os.read_entire_file_from_path(full_path(dir, rel), context.temp_allocator)
	if err != nil {
		problem(r, "%s does not read (%v)", rel, err)
		return
	}
	if _, jerr := json.parse(data, allocator = context.temp_allocator); jerr != .None {
		problem(r, "%s is not valid JSON (%v)", rel, jerr)
	}
}

@(private = "file")
check_world :: proc(r: ^Check_Report, dir, world: string) {
	cfg := fmt.tprintf("%s/%s", world, WORLD_FILE)
	data, err := os.read_entire_file_from_path(full_path(dir, cfg), context.temp_allocator)
	if err != nil {
		problem(r, "%s does not read (%v)", cfg, err)
		return
	}
	text := string(data)
	for key in ([]string{"format", "address", "seed", "generator"}) {
		if _, ok := text_value(text, key); !ok {problem(r, "%s has no %s", cfg, key)}
	}
	// Regions: every header and every chunk.
	regions, _ := os.read_all_directory_by_path(
		full_path(dir, fmt.tprintf("%s/regions", world)),
		context.temp_allocator,
	)
	for e in regions {
		if !strings.has_suffix(e.name, ".vxr") {continue}
		check_region(r, dir, fmt.tprintf("%s/regions/%s", world, e.name), e.name)
	}
	// Text files: their lines have the shape the loaders read.
	check_lines(r, dir, fmt.tprintf("%s/%s", world, ENTITIES_FILE), 7, 12, false)
	check_lines(
		r,
		dir,
		fmt.tprintf("%s/%s", world, CONTAINERS_FILE),
		3,
		3 + game.CHEST_SLOTS,
		true,
	)
	check_lines(
		r,
		dir,
		fmt.tprintf("%s/%s", world, PROTECTIONS_FILE),
		8,
		1 << 10,
		false,
		"protect",
	)
	stats := fmt.tprintf("%s/%s", world, STATS_FILE)
	if os.exists(full_path(dir, stats)) {check_json(r, dir, stats)}
	// The journal, up to where the save says it ends.
	segment, have_segment := text_value(text, "journal.segment")
	offset_text, _ := text_value(text, "journal.offset")
	if have_segment {
		seq, _ := strconv.parse_int(segment)
		offset, _ := strconv.parse_int(offset_text)
		if seq > 0 {
			rel := fmt.tprintf("%s/%s/%08d.vxj", world, JOURNAL_DIR, seq)
			seg, serr := os.read_entire_file_from_path(full_path(dir, rel), context.temp_allocator)
			switch {
			case serr != nil:
				problem(r, "%s does not read (%v)", rel, serr)
			case len(seg) < offset:
				problem(r, "%s is shorter (%d) than the save says (%d)", rel, len(seg), offset)
			case:
				read := game.journal_read_segment(r.reg, seg[:offset], nil)
				if read.status != .Whole {problem(r, "%s is damaged before byte %d", rel, offset)}
			}
		}
	}
}

@(private = "file")
check_region :: proc(r: ^Check_Report, dir, rel, name: string) {
	data, err := os.read_entire_file_from_path(full_path(dir, rel), context.temp_allocator)
	if err != nil {
		problem(r, "%s does not read (%v)", rel, err)
		return
	}
	parts := strings.split(name, ".", context.temp_allocator)
	x, ok1 := strconv.parse_int(parts[1] if len(parts) == 4 else "")
	z, ok2 := strconv.parse_int(parts[2] if len(parts) == 4 else "")
	if !ok1 || !ok2 {
		problem(r, "%s has an odd name", rel)
		return
	}
	region := game.Region_Pos{i32(x), i32(z)}
	rr, rerr := game.region_open(r.reg, data, region, true)
	if rerr != .None {
		problem(r, "%s is damaged (%v)", rel, rerr)
		return
	}
	scratch := new(game.Block_Array, context.temp_allocator)
	for {
		_, _, _, got := game.region_next_chunk(&rr, scratch)
		if !got {break}
	}
	for pos in rr.dropped {problem(r, "%s: chunk %v is damaged", rel, pos)}
}

@(private = "file")
check_lines :: proc(r: ^Check_Report, dir, rel: string, lo, hi: int, chest: bool, first := "") {
	data, err := os.read_entire_file_from_path(full_path(dir, rel), context.temp_allocator)
	if err != nil {return} 	// (not written yet: fine)
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		f := strings.fields(l, context.temp_allocator)
		if len(f) < lo || len(f) > hi || (first != "" && f[0] != first) {
			problem(r, "%s has a line that does not read: %q", rel, l)
			continue
		}
		if chest {
			for i in 0 ..< 3 {
				if _, ok := strconv.parse_int(f[i]);
				   !ok {problem(r, "%s has a line that does not read: %q", rel, l)}
			}
		}
	}
}
