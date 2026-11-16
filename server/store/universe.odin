package store

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

import "common:game"
import "server:packs"

// The universe's files as files: their names, the packs a universe lists and the
// registry built from them, and reading a config text, whatever server runs.

PACKS_DIR :: "packs"

// packs_parse: universe.cfg's `packs` value, "a, b" -> a, b.
packs_parse :: proc(value: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := value
	for part in strings.split_iterator(&rest, ",") {
		name := strings.trim_space(part)
		if name != "" {append(&out, strings.clone(name, allocator))}
	}
	return out[:]
}

// Pack_Candidate: a pack the client found outside the universe (its local packs folder,
// the Workshop), read but not yet checked. problems are what reading it found; a universe
// that lists the pack does not open on them.
Pack_Candidate :: struct {
	source:   game.Pack_Source,
	origin:   string, // where it came from, for the message ("Workshop item 123")
	problems: []string,
}


// packs_registry: the registry of the base pack, the packs listed (the
// directories packs/<namespace> of the universe in dir) and extra; nil with
// the problems (temp allocator) if there is none. sources are the packs'
// files, the base pack first (temp allocator).
packs_registry :: proc(
	dir: string,
	listed: []string,
	extra: []game.Pack_Source = nil,
	base_dir := "", // development: the base pack's files here, not the compiled-in ones
	available: []Pack_Candidate = nil, // where a listed pack not in the universe is looked for, in order
) -> (
	reg: ^game.Registry,
	sources: []game.Pack_Source,
	problems: []string,
) {
	list := make([dynamic]string, context.temp_allocator)
	if len(listed) > game.MAX_PACKS - 1 {
		append(
			&list,
			fmt.tprintf(
				"universe.cfg lists %d packs; the limit is %d besides the base pack",
				len(listed),
				game.MAX_PACKS - 1,
			),
		)
		return nil, nil, list[:]
	}
	all := make([dynamic]game.Pack_Source, context.temp_allocator)
	if base_dir != "" {
		src, errs := packs.pack_read_dir(base_dir, context.temp_allocator)
		for e in errs {append(&list, game.pack_error_text(e))}
		append(&all, src)
	} else {
		append(&all, game.base_pack_source(context.temp_allocator))
	}
	for name in listed {
		path := fmt.tprintf("%s/%s/%s", dir, PACKS_DIR, name)
		if dir == "" || !os.is_directory(path) {
			found := false
			for c in available {
				if c.source.namespace != name {continue}
				found = true
				for p in c.problems {append(&list, fmt.tprintf("%s (%s): %s", name, c.origin, p))}
				append(&all, c.source)
				break
			}
			if !found {
				append(
					&list,
					fmt.tprintf("pack %s is listed in universe.cfg but %s is missing", name, path),
				)
			}
			continue
		}
		src, errs := packs.pack_read_dir(path, context.temp_allocator)
		for e in errs {append(&list, game.pack_error_text(e))}
		append(&all, src)
	}
	// Packs that are there but not listed are not loaded (said, not refused).
	if dir != "" {
		entries, _ := os.read_all_directory_by_path(
			fmt.tprintf("%s/%s", dir, PACKS_DIR),
			context.temp_allocator,
		)
		for e in entries {
			if e.type == .Directory && !slice.contains(listed, e.name) {
				log.warnf(
					"server packs %s/%s/%s is not listed in universe.cfg, so it is not loaded",
					dir,
					PACKS_DIR,
					e.name,
				)
			}
		}
	}
	if len(list) > 0 {return nil, nil, list[:]}
	append(&all, ..extra)
	built, errs := game.registry_build(all[:])
	if built == nil {
		for e in errs {append(&list, game.pack_error_text(e))}
		game.pack_errors_destroy(errs)
		if len(list) == 0 {append(&list, "the registry could not be built")}
		return nil, nil, list[:]
	}
	return built, all[:], nil
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

UNIVERSE_FILE :: "universe.cfg"

WORLDS_DIR :: "worlds"

WORLD_FILE :: "world.cfg"

// 2: players by name (format 1's single player becomes LEGACY_PLAYER); 3:
// players in players/ (player_data.odin); 4: a universe of worlds; 5:
// regions with a checksum per chunk, saves as transactions (save_tx.odin),
// migrations in a registry (migrate.odin); 6: regions name their
// blocks, universes list their packs. Older ones are refused (no migration
// before 1.0).
SAVE_FORMAT :: 7

// UNIVERSE_LOCK: the file an open universe holds a lock on (its text is the
// owner's process id, for the message only).
UNIVERSE_LOCK :: "lock"
