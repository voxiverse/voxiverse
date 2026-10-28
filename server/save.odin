package server

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

import "../base"
import "../common/game"
import "../common/worldgen"

// Saving: a universe is a directory: universe.cfg (format, seed, the home
// world's address, the kit), characters/ and players/ (player_data.odin),
// permissions.cfg, community.cfg, and worlds/<address>/ for each world
// visited or edited: its world.cfg (generator, seed, time, spawn, rules,
// generator parameters), entities.cfg, and regions/ with its edited chunks
// (common/game/save.odin). The rest of a world is regenerated from its seed.
//
// While running, each world keeps edited chunks it has unloaded in `saved`
// (encoded), reads a region's file the first time one of its chunks is
// wanted, and rewrites the regions edits touched: every AUTOSAVE_SECONDS,
// on `save`, and when it stops. Files are replaced whole through a
// temporary file, so a crash mid-save leaves the previous save intact.
//
// A directory from before universes (a world.cfg at the top) becomes the
// universe's home world when opened: its regions and entities move to
// worlds/<home>/, its settings split between the two files.

AUTOSAVE_SECONDS :: 60

UNIVERSE_FILE :: "universe.cfg"
WORLDS_DIR :: "worlds"
WORLD_FILE :: "world.cfg"
ENTITIES_FILE :: "entities.cfg"
// 2: players by name (format 1's single player becomes LEGACY_PLAYER); 3:
// players in players/ (player_data.odin); 4: a universe of worlds; 5 (M46):
// regions with a checksum per chunk, saves as transactions (save_tx.odin),
// migrations in a registry (migrate.odin); 6 (M47a): regions name their
// blocks, universes list their packs. Older ones are refused (no migration
// before 1.0).
SAVE_FORMAT :: 6
LEGACY_PLAYER :: "Player"

Store :: struct {
	dir:            string, // the universe's ("" = not saved)
	players:        map[string]Player_Record, // by name: online, or not yet written (player_data.odin)
	characters:     map[string]game.Account, // every character's account, by name
	writer:         game.Writer,
	last_save:      u64, // the tick of the last save
	// M46 (save_tx.odin): the disk, the save worker, and the save in flight.
	disk:           base.Disk,
	jobs:           base.Jobs,
	jobs_ready:     bool,
	staging:        ^Save_Batch, // the save being collected
	inflight:       ^Save_Batch, // handed to the worker
	carry:          Carry, // what a failed save did not write
	generation:     u64, // the last committed save's
	format:         int, // the format universe.cfg had when opened
	saved_at:       u64, // its age
	backed_up:      bool, // a rolling backup was made this run
	backup_age:     u64, // ... at this age
	lock:           base.File_Lock, // held while the universe is open (UNIVERSE_LOCK)
	job:            ^Save_Job, // the save being captured and sliced (save_slice.odin)
	serial:         u32, // ids of saves, for copy-on-write marks
	slice_worst_us: i64, // the largest slice of the last save (save_slice.odin)
	slice_hold:     bool, // tests: the ticks do not encode (save_finish does)
	unknown_air:    bool, // universe.cfg's `unknown_blocks = air`: blocks the packs no longer define load as air (else the world is refused)
	kit_text:       string, // universe.cfg's `kit`, parsed when the registry exists
	packs:          []string, // universe.cfg's `packs`: the namespaces besides the base pack
}

// store_open reads the universe's files if dir has them (its seed and the
// home world's settings win over config), turns a directory from before
// universes into one, or starts a new universe there. False if the
// directory cannot be used.
store_open :: proc(s: ^Server, dir: string) -> bool {
	st := &s.store
	st.dir = strings.clone(dir)
	st.last_save = s.tick
	game.writer_init(&st.writer)
	home := s.home
	if dir == "" {
		home.address = game.address_derive(u64(s.config.seed))
		return true
	}
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		log.errorf("server cannot create the universe directory dir=%s error=%v", dir, err)
		return false
	}
	if !universe_lock(st, dir) {return false}
	if problem := store_recover(dir, &st.disk); problem != "" {
		log.errorf("server cannot open the save: %s", problem)
		return false
	}
	universe := filepath.join({dir, UNIVERSE_FILE}, context.temp_allocator) or_else UNIVERSE_FILE
	legacy := filepath.join({dir, WORLD_FILE}, context.temp_allocator) or_else WORLD_FILE
	switch {
	case os.exists(universe):
		data, err := os.read_entire_file_from_path(universe, context.temp_allocator)
		if err != nil {
			log.errorf("server cannot read path=%s error=%v", universe, err)
			return false
		}
		read_universe_file(s, string(data), universe) or_return
		home.seed, home.generator = s.config.seed, s.config.generator
	case os.exists(legacy):
		s.refusal = OLDER_BUILD
		log.errorf("server %s path=%s", OLDER_BUILD, legacy)
		return false
	case:
		log.infof("server new universe dir=%s seed=%d", dir, s.config.seed)
		home.address = game.address_derive(u64(s.config.seed))
		home.seed, home.generator = s.config.seed, s.config.generator
		write_universe_file(s) or_return
		st.format = SAVE_FORMAT
	}
	store_migrate(s) or_return
	return world_dir_open(home)
}

// UNIVERSE_LOCK: the file an open universe holds a lock on (its text is the
// owner's process id, for the message only).
UNIVERSE_LOCK :: "lock"

// universe_lock: one process has a universe open at a time. False (logged)
// if another has it.
universe_lock :: proc(st: ^Store, dir: string) -> bool {
	path := filepath.join({dir, UNIVERSE_LOCK}, context.temp_allocator) or_else UNIVERSE_LOCK
	lock, holder, ok := base.file_lock(path, fmt.tprintf("%d", os.get_pid()))
	defer delete(holder)
	if !ok {
		log.errorf(
			"server the universe is open in another process (%s)%s",
			path,
			fmt.tprintf(" pid %s", holder) if holder != "" else "",
		)
		return false
	}
	st.lock = lock
	return true
}

// world_dir_open: w's directory (made if new); its world.cfg read, or
// written for a new world.
world_dir_open :: proc(w: ^World) -> bool {
	s := w.server
	if s.store.dir == "" {return true}
	w.dir = strings.clone(
		filepath.join(
			{s.store.dir, WORLDS_DIR, game.address_dir(w.address)},
			context.temp_allocator,
		) or_else "",
	)
	if err := os.make_directory_all(
		filepath.join({w.dir, "regions"}, context.temp_allocator) or_else w.dir,
	); err != nil && err != .Exist {
		log.errorf("server cannot create the world directory dir=%s error=%v", w.dir, err)
		return false
	}
	path := filepath.join({w.dir, WORLD_FILE}, context.temp_allocator) or_else WORLD_FILE
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err == .Not_Exist {return write_world_file(w)}
	if err != nil {
		log.errorf("server cannot read path=%s error=%v", path, err)
		return false
	}
	return read_world_file(w, string(data), path)
}


store_close :: proc(s: ^Server) {
	st := &s.store
	store_workers_stop(s)
	base.file_unlock(&st.lock)
	delete(st.carry.files)
	delete(st.carry.deletes)
	for name, &r in st.players {
		counters_free(&r.stats)
		delete(name)
	}
	delete(st.players)
	for name in st.characters {delete(name)}
	delete(st.characters)
	game.writer_destroy(&st.writer)
	delete(st.dir)
	st^ = {}
}

// request_chunk makes pos loaded: from the save if it was edited (at once),
// else generated (false while the workers are busy).
request_chunk :: proc(w: ^World, pos: game.Chunk_Pos) -> bool {
	if w.dir != "" {load_region(w, game.region_of(pos))}
	bytes, edited := w.saved[pos]
	if !edited {return chunks_request(&w.chunks, pos)}
	scratch := new(game.Block_Array, context.temp_allocator)
	r := game.reader_make(bytes, w.server.registry)
	entities := make([dynamic]game.Block_Entity, context.temp_allocator)
	uniform, is_uniform := game.read_chunk_payload(&r, scratch, &entities)
	chunks_insert(&w.chunks, pos, uniform, nil if is_uniform else scratch, entities[:])
	origin := game.chunk_origin(pos)
	if chunk := chunks_get(&w.chunks, pos); chunk != nil {
		entities_validate(w, chunk)
		ledger_entities(w, chunk.block_entities[:], .Scope_In)
	}
	wake_water_box(w, origin, origin + game.CHUNK_SIZE - 1, 0) // flowing again where it was
	delete(bytes)
	delete_key(&w.saved, pos)
	return true
}

// chunk_load_saved loads pos from the save if it was edited (false: it was
// not, or is loaded already).
chunk_load_saved :: proc(w: ^World, pos: game.Chunk_Pos) -> bool {
	if w.dir == "" {return false}
	load_region(w, game.region_of(pos))
	if pos not_in w.saved {return false}
	return request_chunk(w, pos)
}

// keep_edits stores an edited chunk that is being unloaded.
keep_edits :: proc(w: ^World, c: ^Chunk) {
	if !c.modified {return}
	ledger_entities(w, c.block_entities[:], .Scope_Out)
	wr := &w.server.store.writer
	clear(&wr.buf)
	game.write_chunk_payload(wr, &c.blocks, c.block_entities[:])
	if old, had := w.saved[c.pos]; had {delete(old)}
	w.saved[c.pos] = transmute([]u8)strings.clone(string(wr.buf[:])) // an owned copy
}

// mark_edited notes that pos's region must be written at the next save.
mark_edited :: proc(w: ^World, pos: game.Chunk_Pos) {
	w.regions[game.region_of(pos)] = true
}

// save writes the universe's files and every loaded world's (its settings,
// entities and changed regions) as one transaction (save_tx.odin), by the save
// worker. The save describes this tick (save_slice.odin captures it at once and
// encodes the big parts over the next ticks); with wait, returns when it is
// committed (false if it failed: logged, and the next save writes the files
// again). An autosave does not wait, and does nothing while the last one is
// still being written.
save :: proc(s: ^Server, wait := true) -> bool {
	st := &s.store
	if st.dir == "" {
		st.last_save = s.tick
		return true
	}
	if st.job != nil {
		if !wait {return true}
		save_finish(s) // (the save running is whole before the next begins)
	}
	if !wait {
		save_poll(s)
		if st.inflight != nil {return true}
	}
	st.last_save = s.tick
	if !save_begin(s) {return false}
	if wait {return save_finish(s)}
	save_slice(s)
	return true
}

// world_save writes w's files on their own (a world being unloaded): its own
// transaction, finished when it returns.
world_save :: proc(w: ^World) -> bool {
	s := w.server
	if w.dir == "" {return true}
	if s.store.job != nil {save_finish(s)}
	if !save_begin(s, w) {return false}
	return save_finish(s)
}

// world_stage adds w's world.cfg, entities and the rest of its small state
// (not its regions: save_slice.odin) to the save being collected.
world_stage :: proc(w: ^World) -> bool {
	if w.dir == "" {return true}
	journal_save_point(w) // (what the world.cfg names as the journal's end)
	ok := write_world_file(w)
	if w.protections_dirty && !protections_write(w) {ok = false}
	journal_maintain(w)
	if !write_entities(w) {ok = false}
	if !write_stats(w) {ok = false}
	return ok
}

@(private)
region_path :: proc(dir: string, r: game.Region_Pos) -> string {
	name := fmt.tprintf("r.%d.%d.vxr", r.x, r.y)
	return filepath.join({dir, "regions", name}, context.temp_allocator) or_else name
}

// load_region reads a region's file once (its edited chunks into saved,
// its tops into tops). A damaged file is moved aside, never loaded.
@(private = "file")
load_region :: proc(w: ^World, region: game.Region_Pos) {
	if region in w.regions {return}
	w.regions[region] = false
	path := region_path(w.dir, region)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err == .Not_Exist {return}
	if err != nil {
		log.errorf("server cannot read region path=%s error=%v", path, err)
		return
	}
	open_err, ok := region_ingest(w, data, region, path)
	if open_err == .Unknown_Blocks {
		// (not damage: the packs changed; start refused this unless it says air)
		log.errorf("server region names blocks the packs do not define, not loaded path=%s", path)
		return
	}
	if !ok {
		aside := fmt.tprintf("%s.damaged-%d", path, time.time_to_unix(time.now()))
		os.rename(path, aside)
		log.errorf(
			"server region file damaged, moved aside path=%s problem=%v moved_to=%s",
			path,
			open_err,
			aside,
		)
		region_from_backup(w, region, path)
	}
}

// region_ingest: a region file's chunks into w.saved and its tops into w.tops.
// False (nothing kept) if the file does not read whole; a chunk with a bad
// checksum is only dropped (logged).
@(private = "file")
region_ingest :: proc(
	w: ^World,
	data: []u8,
	region: game.Region_Pos,
	path: string,
) -> (
	open_err: game.Region_Error,
	ok: bool,
) {
	r: game.Region_Reader
	r, open_err = game.region_open(w.server.registry, data, region, w.server.store.unknown_air)
	scratch := new(game.Block_Array, context.temp_allocator)
	tops := make([dynamic]game.Saved_Top, context.temp_allocator)
	ok = open_err == .None
	loaded := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	entities := make([dynamic]game.Block_Entity, context.temp_allocator)
	wr := &w.server.store.writer
	for ok {
		pos, uniform, is_uniform, got := game.region_next_chunk(&r, scratch, &entities)
		if !got {
			ok = r.reader.ok
			break
		}
		clear(&wr.buf)
		blocks := game.Chunk_Blocks {
			uniform = uniform,
			array   = nil if is_uniform else scratch,
		}
		game.write_chunk_payload(wr, &blocks, entities[:])
		w.saved[pos] = transmute([]u8)strings.clone(string(wr.buf[:]))
		append(&loaded, pos)
	}
	ok = ok && game.region_tops(&r, &tops)
	for pos in r.dropped {
		log.errorf(
			"server chunk damaged in its region file, not loaded (its edits are lost) path=%s chunk=%v",
			path,
			pos,
		)
	}
	if !ok {
		for pos in loaded {
			delete(w.saved[pos])
			delete_key(&w.saved, pos)
		}
		return
	}
	for t in tops {w.tops[{t.x, t.z}] = t.top}
	return
}

// region_from_backup: a damaged region's copy in the newest backup that has a
// whole one; the region is saved again with the next save.
@(private = "file")
region_from_backup :: proc(w: ^World, region: game.Region_Pos, path: string) {
	st := &w.server.store
	rel := relative_path(st.dir, path)
	names := backup_names(st.dir)
	#reverse for name in names {
		data, err := os.read_entire_file_from_path(
			full_path(st.dir, fmt.tprintf("%s/%s/%s", BACKUPS_DIR, name, rel)),
			context.temp_allocator,
		)
		if err != nil {continue}
		if _, ok := region_ingest(w, data, region, path); ok {
			w.regions[region] = true
			log.errorf(
				"server region %d.%d damaged: loaded from backup %s (its later edits are lost)",
				region.x,
				region.y,
				name,
			)
			return
		}
	}
	log.errorf(
		"server region %d.%d damaged and no backup has it whole (its edits are lost)",
		region.x,
		region.y,
	)
}

// universe.cfg: "key = value" lines.
@(private)
write_universe_file :: proc(s: ^Server, format := SAVE_FORMAT) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "# Voxiverse universe (written by the server)")
	fmt.sbprintfln(&b, "format = %d", format)
	fmt.sbprintfln(&b, "seed = %d", s.config.seed)
	fmt.sbprintfln(&b, "home = %s", game.address_dir(s.home.address))
	fmt.sbprintfln(&b, "kit = %s", kit_text(s.registry, s.kit[:]))
	if len(s.store.packs) >
	   0 {fmt.sbprintfln(&b, "packs = %s", strings.join(s.store.packs, ", ", context.temp_allocator))}
	if s.store.unknown_air {fmt.sbprintfln(&b, "unknown_blocks = air")}
	fmt.sbprintfln(&b, "generation = %d", s.store.generation + 1) // (the save this file belongs to)
	fmt.sbprintfln(&b, "age = %d", age_of(s)) // ticks of the universe, across runs
	return store_write(
		s,
		filepath.join({s.store.dir, UNIVERSE_FILE}, context.temp_allocator) or_else UNIVERSE_FILE,
		b.buf[:],
	)
}

// read_universe_file: the universe's settings (and, from a world.cfg from
// before universes, its players).
@(private = "file")
read_universe_file :: proc(s: ^Server, text: string, path: string) -> bool {
	Partial :: struct {
		player: Player_Record,
		coords: int, // of x, y, z read
	}
	players := make(map[string]Partial, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		eq := strings.index_byte(l, '=')
		if eq < 0 {continue}
		key, value := strings.trim_space(l[:eq]), strings.trim_space(l[eq + 1:])
		switch {
		case key == "format":
			n, ok := strconv.parse_int(value)
			if !ok || n > SAVE_FORMAT {
				log.errorf(
					"server universe from a newer game, not loaded path=%s format=%s",
					path,
					value,
				)
				return false
			}
			s.store.format = n
		case key == "seed":
			if n, ok := strconv.parse_i64(value); ok {s.config.seed = n}
		case key == "home":
			a, ok := game.address_parse(value, {})
			if !ok {
				log.errorf(
					"server universe's home address not understood path=%s home=%q",
					path,
					value,
				)
				return false
			}
			s.home.address = a
		case key == "generation":
			if n, ok := strconv.parse_u64(value, 10); ok {s.store.generation = n}
		case key == "age":
			if n, ok := strconv.parse_u64(value, 10); ok {s.age_base = n}
		case key == "packs":
			s.store.packs = packs_parse(value, virtual.arena_allocator(&s.arena))
		case key == "unknown_blocks":
			s.store.unknown_air = value == "air"
		case key == "kit":
			s.store.kit_text = strings.clone(value, virtual.arena_allocator(&s.arena)) // (parsed once the packs are loaded)
		case strings.has_prefix(key, "player."):
			// player.<name>.<field>; format 1 had one player: player.<field>.
			after := key[len("player."):]
			name, field := LEGACY_PLAYER, after
			if dot := strings.last_index_byte(after, '.'); dot >= 0 {
				name, field = after[:dot], after[dot + 1:]
			}
			if !game.name_valid(name) {continue}
			p := players[name]
			switch field {
			case "x", "y", "z":
				if v, ok := strconv.parse_f64(value); ok && abs(v) < game.WORLD_LIMIT {
					p.player.state.position[int(field[0] - 'x')] = v
					p.coords += 1
				}
			case "yaw":
				if v, ok := strconv.parse_f32(value);
				   ok && !math.is_nan(v) && abs(v) < 1e6 {p.player.look[0] = v}
			case "pitch":
				if v, ok := strconv.parse_f32(value); ok && !math.is_nan(v) {
					p.player.look[1] = clamp(v, -game.PITCH_LIMIT, game.PITCH_LIMIT)
				}
			case "flying":
				p.player.state.flying = value == "true"
			}
			players[name] = p
		}
	}
	for name, p in players {
		// (Before format 3: moved to their files at the next save.)
		if p.coords == 3 {
			rec := p.player
			rec.dirty = true
			s.store.players[strings.clone(name)] = rec
		}
	}
	return true
}

// world.cfg: "key = value" lines, then the rules and generator parameters.
@(private = "file")
write_world_file :: proc(w: ^World, format := SAVE_FORMAT) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "# Voxiverse world (written by the server)")
	fmt.sbprintfln(&b, "format = %d", format)
	fmt.sbprintfln(&b, "address = %s", game.address_dir(w.address))
	fmt.sbprintfln(&b, "seed = %d", w.seed)
	fmt.sbprintfln(&b, "generator = %s", worldgen.KIND_NAMES[w.generator])
	fmt.sbprintfln(&b, "time = %.17f", w.clock) // (exact: reloaded, it may not run back)
	if w.spawn.known {
		sp := w.spawn
		fmt.sbprintfln(&b, "spawn.x = %.6f", sp.position.x)
		fmt.sbprintfln(&b, "spawn.y = %.6f", sp.position.y)
		fmt.sbprintfln(&b, "spawn.z = %.6f", sp.position.z)
		fmt.sbprintfln(&b, "spawn.yaw = %.6f", sp.look[0])
		fmt.sbprintfln(&b, "spawn.pitch = %.6f", sp.look[1])
		fmt.sbprintfln(&b, "spawn.exact = %v", sp.exact)
	}
	fmt.sbprintfln(&b, "journal.segment = %d", w.journal.seq)
	fmt.sbprintfln(&b, "journal.offset = %d", w.journal.file_bytes)
	fmt.sbprintfln(&b, "journal.next_action = %d", w.journal.next_action if w.started else 1)
	strings.write_string(&b, "\n")
	base.vars_write(game.rules_table(), &w.rules, &b)
	base.vars_write(worldgen.params_table(), &w.params, &b)
	return store_write(
		w.server,
		filepath.join({w.dir, WORLD_FILE}, context.temp_allocator) or_else WORLD_FILE,
		b.buf[:],
	)
}

@(private = "file")
read_world_file :: proc(w: ^World, text: string, path: string) -> bool {
	rules_text := strings.builder_make(context.temp_allocator)
	spawn_coords := 0
	w.generator = .Classic // a world from before generators were named
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		eq := strings.index_byte(l, '=')
		if eq < 0 {continue}
		key, value := strings.trim_space(l[:eq]), strings.trim_space(l[eq + 1:])
		switch {
		case key == "format":
			if n, ok := strconv.parse_int(value); !ok || n > SAVE_FORMAT {
				log.errorf(
					"server world from a newer game, not loaded path=%s format=%s",
					path,
					value,
				)
				return false
			}
		case key == "seed":
			if n, ok := strconv.parse_i64(value); ok {w.seed = n}
		case key == "generator":
			kind, known := worldgen.kind_by_name(value)
			if !known {
				log.errorf(
					"server world made by an unknown generator, not loaded path=%s generator=%s",
					path,
					value,
				)
				return false
			}
			w.generator = kind
		case strings.has_prefix(key, "spawn."):
			field := key[len("spawn."):]
			switch field {
			case "x", "y", "z":
				if v, ok := strconv.parse_f64(value); ok && abs(v) < game.WORLD_LIMIT {
					w.spawn.position[int(field[0] - 'x')] = v
					spawn_coords += 1
				}
			case "yaw":
				if v, ok := strconv.parse_f32(value);
				   ok && !math.is_nan(v) && abs(v) < 1e6 {w.spawn.look[0] = v}
			case "pitch":
				if v, ok := strconv.parse_f32(value); ok && !math.is_nan(v) {
					w.spawn.look[1] = clamp(v, -game.PITCH_LIMIT, game.PITCH_LIMIT)
				}
			case "exact":
				w.spawn.exact = value == "true"
			}
		case key == "time":
			if v, ok := strconv.parse_f64(value); ok && game.time_valid(v) {w.clock = v}
		case key == "journal.segment":
			if n, ok := strconv.parse_u64(value, 10); ok {
				w.journal_resume.known, w.journal_resume.segment = true, u32(n)
			}
		case key == "journal.offset":
			if n, ok := strconv.parse_u64(value, 10); ok {w.journal_resume.offset = n}
		case key == "journal.next_action":
			if n, ok := strconv.parse_u64(value, 10); ok {w.journal_resume.next_action = u32(n)}
		case strings.has_prefix(key, "rules."), strings.has_prefix(key, "worldgen."):
			fmt.sbprintfln(&rules_text, "%s = %s", key, value)
		}
	}
	// A world made before biomes blended keeps its hard edges (its saved
	// chunks were made that way; new ones must meet them).
	if !strings.contains(text, "worldgen.biome_blend") {w.params.biome_blend = 0}
	// One made before gates has none (its spawn's chunks may be saved).
	if !strings.contains(text, "worldgen.gates") {w.params.gates = 0}
	for p in base.vars_read(worldgen.params_table(), &w.params, strings.to_string(rules_text)) {
		if p.error == .Unknown_Name && strings.has_prefix(p.text, "rules.") {continue}
		log.warnf(
			"server world generator setting ignored or clamped path=%s problem=%v text=%q",
			path,
			p.error,
			p.text,
		)
	}
	for p in base.vars_read(game.rules_table(), &w.rules, strings.to_string(rules_text)) {
		if p.error == .Unknown_Name && strings.has_prefix(p.text, "worldgen.") {continue}
		log.warnf(
			"server world rule ignored or clamped path=%s problem=%v text=%q",
			path,
			p.error,
			p.text,
		)
	}
	w.spawn.known = spawn_coords == 3 // (else the generator's, chosen at start)
	log.infof("server world loaded path=%s seed=%d", path, w.seed)
	return true
}

// entities.cfg: one line per entity: kind x y z yaw health natural.
@(private = "file")
write_entities :: proc(w: ^World) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(
		&b,
		"# Voxiverse entities (written by the server): kind x y z yaw health natural [item count | shorn genes growth love wait]",
	)
	for e in w.entities.list {
		if !game.ENTITY_INFO[e.kind].saved {continue}
		fmt.sbprintf(
			&b,
			"%s %.4f %.4f %.4f %.4f %d %v",
			game.ENTITY_INFO[e.kind].name,
			e.body.position.x,
			e.body.position.y,
			e.body.position.z,
			e.yaw,
			e.health,
			e.natural,
		)
		if e.kind ==
		   .Item {fmt.sbprintf(&b, " %s %d", game.item_id(w.server.registry, e.stack.item), e.stack.count)}
		if e.kind == .Sheep {
			fmt.sbprintf(
				&b,
				" %v %d %d %d %d",
				e.shorn,
				transmute(u8)e.genes,
				e.growth,
				e.love,
				e.wait,
			)
		}
		strings.write_byte(&b, '\n')
	}
	return store_write(
		w.server,
		filepath.join({w.dir, ENTITIES_FILE}, context.temp_allocator) or_else ENTITIES_FILE,
		b.buf[:],
	)
}

// load_entities brings back a saved world's entities (they wait, frozen,
// until their ground is loaded). Lines that do not read are skipped.
load_entities :: proc(w: ^World) {
	if w.dir == "" {return}
	path := filepath.join({w.dir, ENTITIES_FILE}, context.temp_allocator) or_else ENTITIES_FILE
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return} 	// none saved (a new world, or an older one)
	rest := string(data)
	loaded, skipped := 0, 0
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		f := strings.fields(l, context.temp_allocator)
		ok := len(f) >= 7 && len(f) <= 12
		kind: game.Entity_Kind
		found := false
		if ok {
			for k in game.Entity_Kind {
				info := &game.ENTITY_INFO[k]
				if info.saved && info.name == f[0] {kind, found = k, true}
			}
			if f[0] == "critter" {kind, found = .Sheep, true} 	// (before it was a sheep)
			// An item has its stack after, a sheep whether it is shorn; no other has more.
			// An item has its stack after; a sheep whether it is shorn (and, from
			// M25, its genes, growth, love and wait); no other has more.
			if found && kind == .Item && len(f) != 9 {ok = false}
			if found && kind == .Sheep && len(f) != 7 && len(f) != 8 && len(f) != 12 {ok = false}
			if found && kind != .Item && kind != .Sheep && len(f) != 7 {ok = false}
		}
		pos: [3]f64
		yaw: f32
		health: int
		if ok && found {
			x, ok1 := strconv.parse_f64(f[1])
			y, ok2 := strconv.parse_f64(f[2])
			z, ok3 := strconv.parse_f64(f[3])
			w, ok4 := strconv.parse_f32(f[4])
			h, ok5 := strconv.parse_int(f[5])
			ok =
				ok1 &&
				ok2 &&
				ok3 &&
				ok4 &&
				ok5 &&
				abs(x) < game.WORLD_LIMIT &&
				abs(z) < game.WORLD_LIMIT &&
				y > game.WORLD_MIN_Y &&
				y < game.WORLD_MAX_Y &&
				h > 0 &&
				!math.is_nan(w)
			pos, yaw, health = {x, y, z}, w, h
		}
		stack: game.Stack
		if ok && found && kind == .Item {
			// A dropped stack: what it is.
			item, known := game.item_by_name(w.server.registry, f[7] if len(f) == 9 else "")
			n, counted := strconv.parse_int(f[8] if len(f) == 9 else "")
			ok = known && counted && n > 0
			stack = {item, min(n, game.item_stack_size(w.server.registry, item))}
		}
		if !ok || !found {
			skipped += 1
			continue
		}
		if e := entity_spawn(w, kind, pos, f[6] == "true"); e != nil {
			e.yaw, e.health = yaw, min(health, game.ENTITY_INFO[kind].health)
			e.stack = stack
			if kind == .Sheep && len(f) >= 8 {e.shorn = f[7] == "true"}
			if kind == .Sheep && len(f) == 12 {
				genes, ok1 := strconv.parse_int(f[8])
				growth, ok2 := strconv.parse_int(f[9])
				love, ok3 := strconv.parse_int(f[10])
				wait, ok4 := strconv.parse_int(f[11])
				if ok1 && ok2 && ok3 && ok4 && genes >= 0 && genes < 16 {
					e.genes = transmute(game.Genes)u8(genes)
					e.growth = clamp(growth, 0, game.LAMB_TICKS)
					e.love, e.wait =
						clamp(love, 0, game.BREED_READY_TICKS),
						clamp(wait, 0, game.BREED_WAIT_TICKS)
				}
			}
			loaded += 1
		}
	}
	if skipped > 0 {log.warnf("server entities skipped lines=%d path=%s", skipped, path)}
	log.infof("server entities loaded count=%d", loaded)
}
