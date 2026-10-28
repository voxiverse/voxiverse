package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../common/game"

// A universe's packs: universe.cfg's `packs` line lists their namespaces (the
// base pack, voxiverse, is always first and never listed), each is the
// directory <universe>/packs/<namespace>/. Fixed while the universe runs:
// the registry is built once at start and never grows.

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

// universe_registry builds s.registry: the base pack, the universe's listed
// packs, then config.extra_packs. Every problem is logged (and s.refusal says
// the first), and false means the universe does not start.
universe_registry :: proc(s: ^Server) -> bool {
	reg, sources, problems := packs_registry(s.store.dir, s.store.packs, s.config.extra_packs)
	for p in problems {
		log.errorf("server packs %s", p)
		if s.refusal == "" {s.refusal = strings.clone(p, context.temp_allocator)}
	}
	if reg == nil {return false}
	s.registry = reg
	pack_blobs_make(s, sources)
	log.infof("server packs loaded count=%d hash=%x", len(reg.packs), reg.hash)
	return true
}

// packs_registry: the registry of the base pack, the packs listed (the
// directories packs/<namespace> of the universe in dir) and extra; nil with
// the problems (temp allocator) if there is none. sources are the packs'
// files, the base pack first (temp allocator).
packs_registry :: proc(
	dir: string,
	listed: []string,
	extra: []game.Pack_Source = nil,
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
	append(&all, game.base_pack_source(context.temp_allocator))
	for name in listed {
		path := fmt.tprintf("%s/%s/%s", dir, PACKS_DIR, name)
		if dir == "" || !os.is_directory(path) {
			append(
				&list,
				fmt.tprintf("pack %s is listed in universe.cfg but %s is missing", name, path),
			)
			continue
		}
		src, errs := pack_read_dir(path, context.temp_allocator)
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
		if len(list) == 0 {append(&list, "the registry could not be built")}
		return nil, nil, list[:]
	}
	return built, all[:], nil
}

// packs_text: the packs as Welcome.packs and /packs show them,
// "namespace@version" in load order.
packs_text :: proc(reg: ^game.Registry, allocator := context.temp_allocator) -> string {
	parts := make([dynamic]string, allocator)
	for p in reg.packs {append(&parts, fmt.aprintf("%s@%s", p.namespace, p.version, allocator = allocator))}
	return strings.join(parts[:], ",", allocator)
}

// universe_blocks_check refuses a universe whose regions name blocks the
// packs no longer define (unless universe.cfg says `unknown_blocks = air`,
// which loads them as air). Every region's header is read once, at start.
universe_blocks_check :: proc(s: ^Server) -> bool {
	if s.store.dir == "" || s.store.unknown_air {return true}
	names := make([dynamic]string, context.temp_allocator)
	worlds, _ := os.read_all_directory_by_path(
		fmt.tprintf("%s/%s", s.store.dir, WORLDS_DIR),
		context.temp_allocator,
	)
	for wd in worlds {
		if wd.type != .Directory {continue}
		dir := fmt.tprintf("%s/%s/%s/regions", s.store.dir, WORLDS_DIR, wd.name)
		files, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for f in files {
			if !strings.has_suffix(f.name, ".vxr") {continue}
			parts := strings.split(f.name, ".", context.temp_allocator)
			if len(parts) != 4 {continue}
			x, ok1 := strconv.parse_int(parts[1])
			z, ok2 := strconv.parse_int(parts[2])
			if !ok1 || !ok2 {continue}
			data, err := os.read_entire_file_from_path(
				fmt.tprintf("%s/%s", dir, f.name),
				context.temp_allocator,
			)
			if err != nil {continue}
			r, open_err := game.region_open(s.registry, data, {i32(x), i32(z)})
			if open_err != .Unknown_Blocks {continue}
			for n in r.unknown {
				if !slice.contains(
					names[:],
					n,
				) {append(&names, strings.clone(n, context.temp_allocator))}
			}
		}
	}
	if len(names) == 0 {return true}
	s.refusal = fmt.aprintf(
		"this world has blocks its packs no longer define: %s (add the pack back, or set unknown_blocks = air in universe.cfg to load them as air)",
		strings.join(names[:], ", ", context.temp_allocator),
		allocator = context.temp_allocator,
	)
	log.errorf("server %s", s.refusal)
	return false
}

// registry_for_dir: a registry of its own for the universe in dir (as the
// server there builds it), for a client that plays it here. nil if the
// universe's packs do not load (the server says why when it starts).
registry_for_dir :: proc(dir: string, allocator := context.allocator) -> ^game.Registry {
	text := ""
	if dir != "" {
		data, err := os.read_entire_file_from_path(
			fmt.tprintf("%s/%s", dir, UNIVERSE_FILE),
			context.temp_allocator,
		)
		if err == nil {text = string(data)}
	}
	value, _ := text_value(text, "packs")
	reg, _, _ := packs_registry(dir, packs_parse(value, context.temp_allocator), nil)
	return reg
}
