package core

import "base:runtime"

import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "common:base"
import "common:game"
import "common:intervention"
import "common:planet"
import "common:worldgen"

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
// players in players/ (player_data.odin); 4: a universe of worlds; 5:
// regions with a checksum per chunk, saves as transactions (save_tx.odin),
// migrations in a registry (migrate.odin); 6: regions name their
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
	// The disk (save_tx.odin): the disk, the save worker, and the save in flight.
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
		home.address = home_address(s)
		world_set_planet(home)
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
		home.address = home_address(s)
		world_set_planet(home)
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
	lock, holder, ok := base.file_lock(path, fmt.tprintf("%d", base.boot_info().pid))
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
	waiting := make([dynamic]game.Saved_Update, context.temp_allocator)
	layers := make([dynamic]game.Saved_Channel, context.temp_allocator)
	uniform, is_uniform := game.read_chunk_payload(&r, scratch, &entities, &waiting, &layers)
	chunks_insert(&w.chunks, pos, uniform, nil if is_uniform else scratch, entities[:], layers[:])
	origin := game.chunk_origin(pos)
	if chunk := chunks_get(&w.chunks, pos); chunk != nil {
		ledger_entities(w, chunk.block_entities[:], .Scope_In)
		entities_reconcile(w, chunk)
	}
	sim_restore(w, pos, waiting[:]) // (what was waiting when it was saved, as due then)
	sim_wake_box(w, origin, origin + game.CHUNK_SIZE - 1, 0) // flowing again where it was
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
	game.chunk_compact(&c.blocks, &w.chunks.arrays)
	game.layers_compact(&c.layers, &w.chunks.pools)
	layers := chunk_saved_layers(&w.chunks, c, context.temp_allocator)
	game.write_chunk_payload(wr, &c.blocks, c.block_entities[:], sim_take_chunk(w, c.pos), layers)
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
	if w.interventions_dirty && !interventions_write(w) {ok = false}
	if w.economy != nil && w.economy.dirty && !economy_write(w) {ok = false}
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
	waiting := make([dynamic]game.Saved_Update, context.temp_allocator)
	layers := make([dynamic]game.Saved_Channel, context.temp_allocator)
	unknown := make([dynamic]string, context.temp_allocator)
	wr := &w.server.store.writer
	for ok {
		pos, uniform, is_uniform, got := game.region_next_chunk(
			&r,
			scratch,
			&entities,
			&waiting,
			&layers,
			&unknown,
		)
		if !got {
			ok = r.reader.ok
			break
		}
		clear(&wr.buf)
		blocks := game.Chunk_Blocks {
			uniform = uniform,
			array   = nil if is_uniform else scratch,
		}
		game.write_chunk_payload(wr, &blocks, entities[:], waiting[:], layers[:])
		w.saved[pos] = transmute([]u8)strings.clone(string(wr.buf[:]))
		append(&loaded, pos)
	}
	ok = ok && game.region_tops(&r, &tops)
	slice.sort(unknown[:])
	for name, i in unknown {
		if i > 0 && unknown[i - 1] == name {continue}
		log.warnf(
			"server dropped channel %q from a saved region: this world's packs no longer have it path=%s",
			name,
			path,
		)
	}
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
write_universe_file :: proc(s: ^Server) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "# Voxiverse universe (written by the server)")
	fmt.sbprintfln(&b, "format = %d", SAVE_FORMAT)
	fmt.sbprintfln(&b, "seed = %d", s.config.seed)
	fmt.sbprintfln(&b, "home = %s", game.address_dir(s.home.address))
	fmt.sbprintfln(&b, "mode = %s", mode_config_text(s.config.mode))
	if s.config.mode_changed {fmt.sbprintfln(&b, "mode_changed = true")}
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
		case key == "mode":
			if mode_text_valid(
				value,
			) {s.config.mode = strings.clone(value, virtual.arena_allocator(&s.arena))}
		case key == "mode_changed":
			s.config.mode_changed = value == "true"
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
write_world_file :: proc(w: ^World) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "# Voxiverse world (written by the server)")
	fmt.sbprintfln(&b, "format = %d", SAVE_FORMAT)
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
	it := entities_each(w)
	for e in entities_next(&it) {
		info := game.kind_info(w.server.registry, entity_kind(w, e))
		if !info.saved {continue}
		fmt.sbprintf(
			&b,
			"%s %.4f %.4f %.4f %.4f %d %v",
			info.id, // (a save before kinds were data wrote the bare name: load_entities reads both)
			entity_pos(w, e).x,
			entity_pos(w, e).y,
			entity_pos(w, e).z,
			entity_yaw(w, e),
			entity_health_of(w, e),
			entity_is_natural(w, e),
		)
		if entity_kind(w, e) == w.server.registry.engine.item { 	// (and the action that dropped it: a rollback takes it back after a restart)
			fmt.sbprintf(
				&b,
				" %s %d %d",
				game.item_id(w.server.registry, entity_stack(w, e).item),
				entity_stack(w, e).count,
				entity_owner(w, e).action,
			)
		}
		if entity_kind(w, e) == w.server.registry.engine.sheep {
			fmt.sbprintf(
				&b,
				" %v %d %d %d %d",
				entity_wool(w, e).shorn,
				transmute(u8)entity_genes(w, e).genes,
				entity_breeding(w, e).growth,
				entity_breeding(w, e).love,
				entity_breeding(w, e).wait,
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
	unknown := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		f := strings.fields(l, context.temp_allocator)
		ok := len(f) >= 7 && len(f) <= 12
		reg := w.server.registry
		sheep, item := reg.engine.sheep, reg.engine.item
		kind: game.Kind_Id
		found := false
		if ok {
			// (a bare name is a base pack kind: the saves before kinds were data)
			if k, has := game.registry_kind(reg, f[0]); has && game.kind_info(reg, k).saved {
				kind, found = k, true
			}
			if f[0] == "critter" {kind, found = sheep, true} 	// (before it was a sheep)
			if !found {append(&unknown, f[0])}
			// An item has its stack after, a sheep whether it is shorn; no other has more.
			// An item has its stack after; a sheep whether it is shorn (and, with
			// its genes, growth, love and wait); no other has more.
			if found && kind == item && len(f) != 9 && len(f) != 10 {ok = false}
			if found && kind == sheep && len(f) != 7 && len(f) != 8 && len(f) != 12 {ok = false}
			if found && kind != item && kind != sheep && len(f) != 7 {ok = false}
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
		action: u32
		if ok && found && kind == item {
			// A dropped stack: what it is.
			item, known := game.item_by_name(w.server.registry, f[7] if len(f) >= 9 else "")
			n, counted := strconv.parse_int(f[8] if len(f) >= 9 else "")
			if len(f) == 10 {
				a, has := strconv.parse_u64(f[9], 10)
				ok = has && a <= u64(max(u32))
				action = u32(a)
			}
			ok = ok && known && counted && n > 0
			stack = {item, min(n, game.item_stack_size(w.server.registry, item)), 0}
		}
		if !ok || !found {
			skipped += 1
			continue
		}
		if e := entity_spawn(w, kind, pos, f[6] == "true"); e != 0 {
			entity_set_yaw(w, e, yaw)
			entity_set_health(w, e, min(health, game.kind_info(reg, kind).health))
			entity_stack(w, e)^, entity_owner(w, e).action = stack, action
			if kind == sheep && len(f) >= 8 {entity_wool(w, e).shorn = f[7] == "true"}
			if kind == sheep && len(f) == 12 {
				genes, ok1 := strconv.parse_int(f[8])
				growth, ok2 := strconv.parse_int(f[9])
				love, ok3 := strconv.parse_int(f[10])
				wait, ok4 := strconv.parse_int(f[11])
				if ok1 && ok2 && ok3 && ok4 && genes >= 0 && genes < 16 {
					entity_genes(w, e).genes = transmute(game.Genes)u8(genes)
					br := entity_breeding(w, e)
					br.growth = i32(clamp(growth, 0, game.LAMB_TICKS))
					br.love = i32(clamp(love, 0, game.BREED_READY_TICKS))
					br.wait = i32(clamp(wait, 0, game.BREED_WAIT_TICKS))
				}
			}
			loaded += 1
		}
	}
	slice.sort(unknown[:])
	for name, i in unknown {
		if i > 0 && unknown[i - 1] == name {continue}
		log.warnf(
			"server dropped saved entities of kind %q: this world's packs no longer have it (or do not save it) path=%s",
			name,
			path,
		)
	}
	if skipped > 0 {log.warnf("server entities skipped lines=%d path=%s", skipped, path)}
	log.infof("server entities loaded count=%d", loaded)
}

// home_address: the address of a new universe's home world: Earth's, or one
// made from the seed (the alien start).
home_address :: proc(s: ^Server) -> game.Address {
	if s.config.earth {return game.earth_address()}
	return game.address_derive(u64(s.config.seed))
}

// interventions.vxi: the world's interventions log (common/intervention), in the save
// transaction beside entities.cfg.
INTERVENTIONS_FILE :: "interventions.vxi"

interventions_write :: proc(w: ^World) -> bool {
	if w.dir == "" {return true}
	data := intervention.encode(&w.interventions, context.temp_allocator)
	path :=
		filepath.join(
			{w.dir, INTERVENTIONS_FILE},
			context.temp_allocator,
		) or_else INTERVENTIONS_FILE
	ok := store_write(w.server, path, data)
	w.interventions_dirty = !ok
	return ok
}

// interventions_record adds an intervention to the world's log, to be saved with it.
interventions_record :: proc(w: ^World, iv: intervention.Intervention) -> bool {
	if !intervention.record(&w.interventions, iv) {return false}
	w.interventions_dirty = true
	return true
}

// interventions_load reads the log of a world's directory. A damaged file is moved aside
// (like a damaged region) and the world starts with an empty log; the file is never
// half-read.
interventions_load :: proc(w: ^World) {
	if w.dir == "" {return}
	path :=
		filepath.join(
			{w.dir, INTERVENTIONS_FILE},
			context.temp_allocator,
		) or_else INTERVENTIONS_FILE
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return} 	// none saved (a new world)
	l, ok := intervention.decode(data)
	if !ok {
		aside := fmt.tprintf("%s.bad", path)
		log.errorf("server interventions file is damaged, moved aside path=%s", path)
		os.rename(path, aside)
		return
	}
	w.interventions = l
	if len(l.list) > 0 {log.infof("server loaded interventions count=%d", len(l.list))}
}

// admin_interventions: /interventions [radius]: the world's interventions, newest last
// (no radius: the last 20; a radius in blocks: those within it of the player, the last 20).
@(private)
admin_interventions :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	l := &c.world.interventions
	found := l.list[:]
	if len(args) == 1 {
		radius, ok := strconv.parse_int(args[0])
		if !ok || radius < 0 || radius > 2 * game.WORLD_LIMIT {return false}
		p := c.player.position
		place := [3]i32{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
		found = intervention.interventions_near(l, place, i32(radius), 0, context.temp_allocator)
	}
	if len(found) == 0 {
		notice(s, c, "No interventions")
		return true
	}
	for iv in found[max(0, len(found) - 20):] {
		notice(
			s,
			c,
			fmt.tprintf(
				"day %.2f %v at %d %d %d by %s",
				iv.day,
				iv.kind,
				iv.place.x,
				iv.place.y,
				iv.place.z,
				iv.actor if iv.actor != "" else "(none)",
			),
		)
	}
	return true
}

// The economy of a world (docs/world.md, the economy; docs/saves.md, economy.vxe): the server
// holds the markets of the settlements near its observers (the players) and steps them on the
// world clock, a market month being MONTH_DAYS world days. The towns are those the world's
// history implies (`planet.settlements_at`, placed on arrival and cached); towns within
// ECONOMY_RADIUS_KM of an observer are in detail (`planet.Market`, with news and caravans:
// `planet.convoy_step`), all others are lazy (`planet.lazy_price`). A town that leaves every
// observer's reach is handed back to the lazy model (`market_leave`), and priced again from
// the history function when perceived again (`market_enter`), so nothing jumps.
// Only worlds built on the planet have an economy.

MONTH_DAYS :: 30 // world days in a market month
ECONOMY_RADIUS_KM :: 600.0 // a town this near an observer is in detail
ECONOMY_CATCH_UP :: 120 // months a resident market is stepped to catch up; more and it is entered again
ECONOMY_PRESENT :: i64(6000 * planet.DAYS_PER_YEAR) // the history's day at world day 0
ECONOMY_FILE :: "economy.vxe"

@(private = "file")
ECONOMY_MAGIC :: "VXEC"
@(private = "file")
ECONOMY_VERSION :: 1
@(private = "file")
GOODS :: len(planet.Good)

// Saved_Market is a town's detailed state as the file holds it.
@(private = "file")
Saved_Market :: struct {
	cell:    u32,
	stock:   [planet.Good]f32,
	inbound: [planet.Good]f32,
}

@(private = "file")
Saved_Lazy :: struct {
	cell: u32,
	dev:  [planet.Good]f32,
	left: f64,
}

// Saved_Economy is what a file holds, kept until the economy is built to take it.
Saved_Economy :: struct {
	key:    u64, // the placement it was made for
	month:  f64,
	market: [dynamic]Saved_Market,
	lazy:   [dynamic]Saved_Lazy,
}

saved_destroy :: proc(s: ^Saved_Economy) {
	delete(s.market)
	delete(s.lazy)
	s^ = {}
}

World_Economy :: struct {
	cache:     planet.Settlement_Cache,
	key:       u64, // the placement the economy was built for
	built:     bool,
	economy:   planet.Economy,
	kernel:    planet.Kernel,
	mem:       []planet.Lazy_State,
	market:    planet.Market,
	resident:  bool, // `market` holds towns
	news:      planet.News,
	convoy:    planet.Convoy,
	droughts:  [dynamic]planet.Drought, // none yet: no system causes one
	pending:   Saved_Economy, // read from the file, not yet applied
	has_saved: bool,
	dirty:     bool,
	// Building it takes seconds (the history to today, its settlements and roads,
	// the economy and its kernel): a thread of its own does it, the tick goes on.
	job:       ^thread.Thread,
	job_done:  bool, // (atomic) the job's results are in `next`
	next:      Economy_Job,
	alloc:     runtime.Allocator, // what the builds allocate with (their history, settlements, economy): what frees them
	decade:    i64, // the history's decade the economy was built for
	ivn:       int, // and its number of interventions
}

// Economy_Job: what an economy build is given and what it makes.
Economy_Job :: struct {
	address, seed: u64,
	day, decade:   i64,
	interventions: []planet.Intervention, // (the job's own copy)
	allocator:     runtime.Allocator, // the world's: what frees the economy later
	economy:       planet.Economy,
	kernel:        planet.Kernel,
}

// economy_job builds the economy for we.next (on its own thread, or inline on a
// stepped server).
@(private = "file")
economy_job :: proc(data: rawptr) {
	we := (^World_Economy)(data)
	j := &we.next
	context.allocator = we.alloc // (the cache's history and the economy: freed with it)
	p := worldgen.planet_model()
	list := planet.settlements_at(&we.cache, p, j.address, j.seed, j.day, j.interventions)
	roads := planet.roads_at(&we.cache, p, j.address, j.seed, j.day, j.interventions)
	j.economy = planet.economy_build(p, list, roads, j.allocator)
	j.kernel = planet.kernel_measure(j.economy)
	sync.atomic_store(&we.job_done, true)
}

@(private = "file")
economy_job_thread :: proc(t: ^thread.Thread) {
	base.thread_register("economy")
	defer base.thread_unregister()
	economy_job(t.data)
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
}

// economy_install takes a finished build in place of the economy before it.
@(private = "file")
economy_install :: proc(we: ^World_Economy) {
	if we.job != nil {
		thread.join(we.job)
		thread.destroy(we.job)
		we.job = nil
	}
	if we.built {
		economy_drop(we)
		we.dirty = true
	}
	we.economy, we.kernel = we.next.economy, we.next.kernel
	we.mem = make([]planet.Lazy_State, len(we.economy.towns), we.alloc)
	we.key, we.decade, we.ivn, we.built =
		we.cache.key, we.next.decade, len(we.next.interventions), true
	delete(we.next.interventions, we.next.allocator)
	we.next = {}
	sync.atomic_store(&we.job_done, false)
}

economy_free :: proc(w: ^World) {
	we := w.economy
	if we == nil {return}
	if we.job != nil {economy_install(we)} 	// (a build under way: wait for it, then free it with the rest)
	economy_drop(we)
	{
		context.allocator = we.alloc if we.alloc != {} else context.allocator
		planet.settlement_cache_destroy(&we.cache)
	}
	saved_destroy(&we.pending)
	delete(we.droughts)
	free(we)
	w.economy = nil
}

// economy_drop frees the built economy and everything held on it.
@(private = "file")
economy_drop :: proc(we: ^World_Economy) {
	if we.resident {
		planet.market_destroy(&we.market)
		planet.news_destroy(&we.news)
		planet.convoy_destroy(&we.convoy)
		we.resident = false
	}
	if we.built {
		context.allocator = we.alloc if we.alloc != {} else context.allocator
		planet.economy_destroy(&we.economy)
		delete(we.mem)
		we.mem = nil
		we.built = false
	}
}

// economy_month is the market month at a world clock (whole months).
economy_month :: proc(clock: f64) -> f64 {
	return f64(i64(clock / MONTH_DAYS))
}

// economy_observer is where a player stands on the planet, degrees.
economy_observer :: proc(c: ^Client) -> [2]f64 {
	lat, lon := worldgen.planet_lat_lon(i32(c.player.position.x), i32(c.player.position.z))
	return {lat, lon}
}

// economy_tick runs once a second: the economy of every planet world a player is in.
economy_tick :: proc(s: ^Server) {
	if s.tick % game.TICK_RATE != 0 {return}
	for w in s.worlds {
		if w.params.planet == 0 || !w.started {continue}
		observers := make([dynamic][2]f64, context.temp_allocator)
		for &c in s.clients {
			if c.state == .Playing && c.world == w {append(&observers, economy_observer(&c))}
		}
		if len(observers) == 0 && w.economy == nil {continue}
		economy_sync(w, observers[:])
		for &c in s.clients {
			if c.state == .Playing && c.world == w {
				trader_visit(w, &c)
				market_update(s, &c)
			}
		}
	}
}

// economy_interventions turns the world's log into what the history takes: a settlement
// founded at a place.
@(private = "file")
economy_interventions :: proc(w: ^World) -> []planet.Intervention {
	out := make([dynamic]planet.Intervention, context.temp_allocator)
	for iv in w.interventions.list {
		if iv.kind != .Founded_Settlement {continue}
		lat, lon := worldgen.planet_lat_lon(iv.place.x, iv.place.z)
		append(
			&out,
			planet.Intervention {
				day = ECONOMY_PRESENT + i64(iv.day),
				lat = lat,
				lon = lon,
				kind = planet.INTERVENTION_SETTLEMENT,
			},
		)
	}
	return out[:]
}

// economy_sync brings the world's economy up to date: the towns near the observers are in
// detail, stepped to the world clock's month; the rest are lazy.
economy_sync :: proc(w: ^World, observers: [][2]f64) {
	if w.params.planet == 0 {return}
	if w.economy == nil {w.economy = new(World_Economy)}
	we := w.economy
	if we.job != nil && sync.atomic_load(&we.job_done) {economy_install(we)}
	day := ECONOMY_PRESENT + i64(w.clock)
	decade := day / (10 * planet.DAYS_PER_YEAR)
	ivs := economy_interventions(w)
	if we.job == nil && (!we.built || decade != we.decade || len(ivs) != we.ivn) {
		// The history changed (a new decade, an intervention) or there is none yet:
		// build again. Until the new one is in, the old one (if any) serves.
		// A build on a thread allocates from the heap (the main thread's allocator
		// may be a tracking one, for this thread alone); in the tick, the world's.
		// Everything a build makes is allocated and freed with we.alloc.
		if we.alloc == {} {
			we.alloc = context.allocator if w.server.config.stepped else runtime.heap_allocator()
		}
		we.next = Economy_Job {
			address       = game.address_hash(w.address),
			seed          = u64(w.seed),
			day           = day,
			decade        = decade,
			interventions = slice.clone(ivs, we.alloc),
			allocator     = we.alloc,
		}
		if w.server.config.stepped {
			economy_job(we) // (a stepped server stays deterministic: built in the tick)
			economy_install(we)
		} else {
			we.job = thread.create(economy_job_thread)
			we.job.data = we
			thread.start(we.job)
		}
	}
	if !we.built {return} 	// (the first build is under way: no market yet)
	if len(observers) == 0 && !we.resident {return}
	month := economy_month(w.clock)
	if we.has_saved {
		economy_apply_saved(we)
		we.has_saved = false
	}
	if we.resident && month - we.market.month > ECONOMY_CATCH_UP {
		economy_leave(we)
	}

	// The towns to hold in detail.
	want := make([dynamic]int, context.temp_allocator)
	for t, i in we.economy.towns {
		for o in observers {
			if planet.km_between(t.lat, t.lon, f32(o.x), f32(o.y)) < ECONOMY_RADIUS_KM {
				append(&want, i)
				break
			}
		}
	}
	if !we.resident || !slice.equal(want[:], we.market.town) {
		economy_hold(we, want[:], month)
	}
	for we.resident && we.market.month < month {
		planet.convoy_step(we.economy, &we.market, we.news, &we.convoy, we.droughts[:])
		we.dirty = true
	}
}

// economy_leave hands the detailed towns back to the lazy model.
@(private = "file")
economy_leave :: proc(we: ^World_Economy) {
	if !we.resident {return}
	planet.market_leave(we.economy, we.kernel, we.market, we.mem, we.droughts[:])
	planet.market_destroy(&we.market)
	planet.news_destroy(&we.news)
	planet.convoy_destroy(&we.convoy)
	we.resident = false
	we.dirty = true
}

// economy_hold makes `towns` the detailed ones at a month: the towns that stay keep their
// stocks, those that leave go to the lazy model, those that come are priced from it.
@(private = "file")
economy_hold :: proc(we: ^World_Economy, towns: []int, month: f64) {
	old := we.market
	was := we.resident
	if was {
		planet.market_leave(we.economy, we.kernel, old, we.mem, we.droughts[:])
		planet.news_destroy(&we.news)
		planet.convoy_destroy(&we.convoy)
		we.resident = false
	}
	if len(towns) == 0 {
		if was {planet.market_destroy(&old)}
		we.dirty = true
		return
	}
	at := old.month if was else month
	m := planet.market_make(we.economy, towns, at)
	planet.market_enter(we.economy, we.kernel, &m, we.mem, we.droughts[:])
	if was {
		for ti, i in m.town {
			if j := old.local[ti]; j >= 0 {
				m.stock[i], m.inbound[i] = old.stock[j], old.inbound[j]
			}
		}
		planet.market_destroy(&old)
	}
	we.market = m
	we.news = planet.news_make(we.economy, we.market)
	we.resident = true
	we.dirty = true
}

// economy_apply_saved restores the market and the memories a file held, when it was made for
// this placement; otherwise they are recomputed from the history.
@(private = "file")
economy_apply_saved :: proc(we: ^World_Economy) {
	s := &we.pending
	defer saved_destroy(s)
	if s.key != we.key {return}
	by_cell := make(map[u32]int, len(we.economy.towns), context.temp_allocator)
	for t, i in we.economy.towns {by_cell[u32(t.cell)] = i}
	for l in s.lazy {
		if i, ok := by_cell[l.cell]; ok {
			we.mem[i] = planet.Lazy_State {
				dev  = l.dev,
				left = l.left,
			}
		}
	}
	towns := make([dynamic]int, context.temp_allocator)
	for m in s.market {
		if i, ok := by_cell[m.cell]; ok {append(&towns, i)}
	}
	if len(towns) == 0 {return}
	slice.sort(towns[:])
	m := planet.market_make(we.economy, towns[:], s.month)
	planet.market_enter(we.economy, we.kernel, &m, we.mem, we.droughts[:])
	for sm in s.market {
		i, ok := by_cell[sm.cell]
		if !ok {continue}
		j := m.local[i]
		m.stock[j], m.inbound[j] = sm.stock, sm.inbound
	}
	we.market = m
	we.news = planet.news_make(we.economy, we.market)
	we.resident = true
}

// economy_price is a town's price now, by its index in the economy: the detailed one where it
// is in detail, else the lazy one (0 where it has no market).
economy_price :: proc(w: ^World, town: int, g: planet.Good) -> f32 {
	we := w.economy
	if we == nil || !we.built {return 0}
	if we.resident {
		if i := we.market.local[town]; i >= 0 {
			return planet.market_price(we.economy, we.market, i, g)
		}
	}
	month := economy_month(w.clock)
	return planet.lazy_price(we.economy, we.kernel, we.mem[town], town, g, month, we.droughts[:])
}

// ---- the file ----

@(private = "file")
ENTRY_MARKET :: 4 + 2 * 4 * GOODS
@(private = "file")
ENTRY_LAZY :: 4 + 4 * GOODS + 8
@(private = "file")
ECONOMY_HEADER :: 4 + 4 + 8 + 8 + 4 + 4

// economy_encode: "VXEC", u32 version, u64 placement key, f64 month, u32 market count, u32
// lazy count, the market towns (cell u32, stock and inbound per good as f32), the lazy
// memories (cell u32, dev per good as f32, left f64), the CRC-32 of all before it.
economy_encode :: proc(we: ^World_Economy, allocator := context.allocator) -> []u8 {
	nm := len(we.market.town) if we.resident else 0
	lazy := make([dynamic]int, context.temp_allocator)
	for m, i in we.mem {
		if m.left != 0 || m.dev != {} {append(&lazy, i)}
	}
	size := ECONOMY_HEADER + nm * ENTRY_MARKET + len(lazy) * ENTRY_LAZY + 4
	out := make([]u8, size, allocator)
	copy(out, ECONOMY_MAGIC)
	endian.put_u32(out[4:], .Little, ECONOMY_VERSION)
	endian.put_u64(out[8:], .Little, we.key)
	endian.put_f64(out[16:], .Little, we.market.month if we.resident else 0)
	endian.put_u32(out[24:], .Little, u32(nm))
	endian.put_u32(out[28:], .Little, u32(len(lazy)))
	at := ECONOMY_HEADER
	if we.resident {
		for ti, i in we.market.town {
			endian.put_u32(out[at:], .Little, u32(we.economy.towns[ti].cell))
			at += 4
			for g in planet.Good {
				endian.put_f32(out[at:], .Little, we.market.stock[i][g])
				endian.put_f32(out[at + 4 * GOODS:], .Little, we.market.inbound[i][g])
				at += 4
			}
			at += 4 * GOODS
		}
	}
	for i in lazy {
		endian.put_u32(out[at:], .Little, u32(we.economy.towns[i].cell))
		at += 4
		for g in planet.Good {
			endian.put_f32(out[at:], .Little, we.mem[i].dev[g])
			at += 4
		}
		endian.put_f64(out[at:], .Little, we.mem[i].left)
		at += 8
	}
	endian.put_u32(out[at:], .Little, hash.crc32(out[:at]))
	return out
}

// economy_decode reads a file; ok is false for anything damaged (magic, version, CRC, a
// length that does not match the counts, a non-finite or negative number).
economy_decode :: proc(data: []u8) -> (s: Saved_Economy, ok: bool) {
	if len(data) < ECONOMY_HEADER + 4 || string(data[:4]) != ECONOMY_MAGIC {return}
	version, _ := endian.get_u32(data[4:], .Little)
	if version != ECONOMY_VERSION {return}
	end := len(data) - 4
	crc, _ := endian.get_u32(data[end:], .Little)
	if crc != hash.crc32(data[:end]) {return}
	s.key, _ = endian.get_u64(data[8:], .Little)
	s.month, _ = endian.get_f64(data[16:], .Little)
	nm, _ := endian.get_u32(data[24:], .Little)
	nl, _ := endian.get_u32(data[28:], .Little)
	defer if !ok {saved_destroy(&s)}
	if !(s.month >= 0 && s.month <= game.MAX_WORLD_TIME) {return}
	if u64(nm) * ENTRY_MARKET + u64(nl) * ENTRY_LAZY + ECONOMY_HEADER != u64(end) {return}
	sane :: proc(v: f32) -> bool {return v >= 0 && v < 1e6}
	at := ECONOMY_HEADER
	for _ in 0 ..< nm {
		e: Saved_Market
		e.cell, _ = endian.get_u32(data[at:], .Little)
		at += 4
		for g in planet.Good {
			e.stock[g], _ = endian.get_f32(data[at:], .Little)
			e.inbound[g], _ = endian.get_f32(data[at + 4 * GOODS:], .Little)
			if !sane(e.stock[g]) || !sane(e.inbound[g]) {return}
			at += 4
		}
		at += 4 * GOODS
		append(&s.market, e)
	}
	for _ in 0 ..< nl {
		e: Saved_Lazy
		e.cell, _ = endian.get_u32(data[at:], .Little)
		at += 4
		for g in planet.Good {
			d, _ := endian.get_f32(data[at:], .Little)
			if !(d > -1 && d < 1e6) {return}
			e.dev[g] = d
			at += 4
		}
		e.left, _ = endian.get_f64(data[at:], .Little)
		at += 8
		if !(e.left >= 0 && e.left <= game.MAX_WORLD_TIME) {return}
		append(&s.lazy, e)
	}
	return s, true
}

// economy_write stages economy.vxe (the save transaction calls it when the economy changed).
economy_write :: proc(w: ^World) -> bool {
	we := w.economy
	if w.dir == "" || we == nil || !we.built {return true}
	data := economy_encode(we, context.temp_allocator)
	path := filepath.join({w.dir, ECONOMY_FILE}, context.temp_allocator) or_else ECONOMY_FILE
	ok := store_write(w.server, path, data)
	we.dirty = !ok
	return ok
}

// economy_load reads the world's file; it is applied when the economy is first built. A
// damaged file is moved aside and the economy starts from the history.
economy_load :: proc(w: ^World) {
	if w.dir == "" || w.params.planet == 0 {return}
	path := filepath.join({w.dir, ECONOMY_FILE}, context.temp_allocator) or_else ECONOMY_FILE
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return}
	s, ok := economy_decode(data)
	if !ok {
		log.errorf("server economy file is damaged, moved aside path=%s", path)
		os.rename(path, path_aside(path))
		return
	}
	w.economy = new(World_Economy)
	w.economy.pending, w.economy.has_saved = s, true
}

@(private = "file")
path_aside :: proc(path: string) -> string {
	return fmt.tprintf("%s.bad", path)
}

// economy_check: is the file whole? (for --check)
economy_check :: proc(data: []u8) -> bool {
	s, ok := economy_decode(data)
	if ok {saved_destroy(&s)}
	return ok
}
