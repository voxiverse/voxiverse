package server

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

import "../base"
import "../game"

// Saving: a world directory holds world.cfg (name, seed, time, player, rules) and
// regions/ with the edited chunks (game/save.odin). The rest of the world
// is regenerated from the seed.
//
// While running, the server keeps edited chunks it has unloaded in `saved`
// (encoded), reads a region's file the first time one of its chunks is
// wanted, and rewrites the regions edits touched: every AUTOSAVE_SECONDS,
// on `save`, and when it stops. Files are replaced whole through a
// temporary file, so a crash mid-save leaves the previous save intact.

AUTOSAVE_SECONDS :: 60

Saved_Player :: struct {
	state:      game.Player_State,
	yaw, pitch: f32, // where they were looking
}
WORLD_FILE :: "world.cfg"
WORLD_FORMAT :: 1

Store :: struct {
	dir:       string, // "" = this world is not saved
	saved:     map[game.Chunk_Pos][]u8, // edited chunks not loaded: encoded blocks
	regions:   map[game.Region_Pos]bool, // read from disk; true = changed since written
	player:    Maybe(Saved_Player), // from world.cfg, for the next join
	writer:    game.Writer,
	last_save: time.Tick,
}

// store_open reads world.cfg if dir has one (the world's seed and rules win
// over config); a new world gets one written now. False if the directory
// cannot be used.
store_open :: proc(s: ^Server, dir: string) -> bool {
	st := &s.store
	st.dir = strings.clone(dir)
	st.last_save = time.tick_now()
	game.writer_init(&st.writer)
	if dir == "" {return true}
	if err := os.make_directory_all(
		filepath.join({dir, "regions"}, context.temp_allocator) or_else dir,
	); err != nil && err != .Exist {
		log.errorf("server cannot create the world directory dir=%s error=%v", dir, err)
		return false
	}
	path := filepath.join({dir, WORLD_FILE}, context.temp_allocator) or_else WORLD_FILE
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err == .Not_Exist {
		log.infof("server new world dir=%s seed=%d", dir, s.config.seed)
		return write_world_file(s)
	}
	if err != nil {
		log.errorf("server cannot read path=%s error=%v", path, err)
		return false
	}
	return read_world_file(s, string(data), path)
}

store_close :: proc(s: ^Server) {
	st := &s.store
	for _, bytes in st.saved {delete(bytes)}
	delete(st.saved)
	delete(st.regions)
	game.writer_destroy(&st.writer)
	delete(st.dir)
	st^ = {}
}

// request_chunk makes pos loaded: from the save if it was edited (at once),
// else generated (false while the workers are busy).
request_chunk :: proc(s: ^Server, pos: game.Chunk_Pos) -> bool {
	st := &s.store
	if st.dir != "" {load_region(s, game.region_of(pos))}
	bytes, edited := st.saved[pos]
	if !edited {return world_request(&s.world, pos)}
	scratch := new(game.Block_Array, context.temp_allocator)
	r := game.reader_make(bytes)
	uniform, is_uniform := game.read_chunk_blocks(&r, scratch)
	world_insert(&s.world, pos, uniform, nil if is_uniform else scratch)
	delete(bytes)
	delete_key(&st.saved, pos)
	return true
}

// keep_edits stores an edited chunk that is being unloaded.
keep_edits :: proc(s: ^Server, c: ^Chunk) {
	if !c.modified {return}
	w := &s.store.writer
	clear(&w.buf)
	game.write_chunk_blocks(w, &c.blocks)
	if old, had := s.store.saved[c.pos]; had {delete(old)}
	s.store.saved[c.pos] = transmute([]u8)strings.clone(string(w.buf[:])) // an owned copy
}

// mark_edited notes that pos's region must be written at the next save.
mark_edited :: proc(s: ^Server, pos: game.Chunk_Pos) {
	s.store.regions[game.region_of(pos)] = true
}

// save writes every changed region and world.cfg; false if anything could
// not be written (logged; the next save tries again).
save :: proc(s: ^Server) -> bool {
	st := &s.store
	st.last_save = time.tick_now()
	if st.dir == "" {return true}
	ok := write_world_file(s)
	regions := 0
	for region, changed in st.regions {
		if !changed {continue}
		if write_region(s, region) {
			st.regions[region] = false
			regions += 1
		} else {
			ok = false
		}
	}
	log.infof("server saved regions=%d dir=%s", regions, st.dir)
	return ok
}

@(private = "file")
region_path :: proc(dir: string, r: game.Region_Pos) -> string {
	name := fmt.tprintf("r.%d.%d.vxr", r.x, r.y)
	return filepath.join({dir, "regions", name}, context.temp_allocator) or_else name
}

// load_region reads a region's file once (its edited chunks into saved,
// its tops into s.tops). A damaged file is moved aside, never loaded.
@(private = "file")
load_region :: proc(s: ^Server, region: game.Region_Pos) {
	st := &s.store
	if region in st.regions {return}
	st.regions[region] = false
	path := region_path(st.dir, region)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err == .Not_Exist {return}
	if err != nil {
		log.errorf("server cannot read region path=%s error=%v", path, err)
		return
	}
	r, open_err := game.region_open(data, region)
	scratch := new(game.Block_Array, context.temp_allocator)
	tops := make([dynamic]game.Saved_Top, context.temp_allocator)
	ok := open_err == .None
	loaded := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for ok {
		pos, uniform, is_uniform, got := game.region_next_chunk(&r, scratch)
		if !got {
			ok = r.reader.ok
			break
		}
		w := &st.writer
		clear(&w.buf)
		blocks := game.Chunk_Blocks {
			uniform = uniform,
			array   = nil if is_uniform else scratch,
		}
		game.write_chunk_blocks(w, &blocks)
		st.saved[pos] = transmute([]u8)strings.clone(string(w.buf[:]))
		append(&loaded, pos)
	}
	ok = ok && game.region_tops(&r, &tops)
	if !ok {
		for pos in loaded {
			delete(st.saved[pos])
			delete_key(&st.saved, pos)
		}
		aside := fmt.tprintf("%s.damaged-%d", path, time.time_to_unix(time.now()))
		os.rename(path, aside)
		log.errorf(
			"server region file damaged, moved aside (its edits are lost) path=%s problem=%v moved_to=%s",
			path,
			open_err,
			aside,
		)
		return
	}
	for t in tops {s.tops[{t.x, t.z}] = t.top}
}

@(private = "file")
write_region :: proc(s: ^Server, region: game.Region_Pos) -> bool {
	st := &s.store
	chunks := make([dynamic]game.Saved_Chunk, context.temp_allocator)
	// Edited chunks that are loaded...
	it: base.Pool_Iterator
	for c in base.pool_next(&s.world.chunks, &it) {
		if c.modified && c.state == .Ready && game.region_of(c.pos) == region {
			append(&chunks, game.Saved_Chunk{c.pos, &c.blocks})
		}
	}
	// ... and those that are not.
	for pos, bytes in st.saved {
		if game.region_of(pos) != region {continue}
		r := game.reader_make(bytes)
		blocks := new(game.Chunk_Blocks, context.temp_allocator)
		array := new(game.Block_Array, context.temp_allocator)
		uniform, is_uniform := game.read_chunk_blocks(&r, array)
		blocks^ = {
			uniform = uniform,
			array   = nil if is_uniform else array,
		}
		append(&chunks, game.Saved_Chunk{pos, blocks})
	}
	tops := make([dynamic]game.Saved_Top, context.temp_allocator)
	for column, top in s.tops {
		if game.region_of({column.x >> game.CHUNK_SHIFT, 0, column.y >> game.CHUNK_SHIFT}) ==
		   region {
			append(&tops, game.Saved_Top{column.x, column.y, top})
		}
	}
	w := &st.writer
	game.region_encode(w, region, chunks[:], tops[:])
	return write_atomically(region_path(st.dir, region), w.buf[:])
}

// write_atomically replaces path with data through a temporary file.
@(private = "file")
write_atomically :: proc(path: string, data: []u8) -> bool {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, data); err != nil {
		log.errorf("server cannot write path=%s error=%v", tmp, err)
		return false
	}
	if err := os.rename(tmp, path); err != nil {
		log.errorf("server cannot replace path=%s error=%v", path, err)
		return false
	}
	return true
}

// world.cfg: "key = value" lines, then the rules (rules.* variables).
@(private = "file")
write_world_file :: proc(s: ^Server) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "# Voxiverse world (written by the server)")
	fmt.sbprintfln(&b, "format = %d", WORLD_FORMAT)
	fmt.sbprintfln(&b, "seed = %d", s.config.seed)
	fmt.sbprintfln(&b, "time = %.9f", s.clock)
	if s.client.state == .Playing || s.store.player != nil {
		p :=
			Saved_Player{s.client.player, s.client.look[0], s.client.look[1]} if s.client.state == .Playing else s.store.player.?
		fmt.sbprintfln(&b, "player.x = %.6f", p.state.position.x)
		fmt.sbprintfln(&b, "player.y = %.6f", p.state.position.y)
		fmt.sbprintfln(&b, "player.z = %.6f", p.state.position.z)
		fmt.sbprintfln(&b, "player.yaw = %.6f", p.yaw)
		fmt.sbprintfln(&b, "player.pitch = %.6f", p.pitch)
		fmt.sbprintfln(&b, "player.flying = %v", p.state.flying)
	}
	strings.write_string(&b, "\n")
	base.vars_write(game.rules_table(), &s.rules, &b)
	return write_atomically(
		filepath.join({s.store.dir, WORLD_FILE}, context.temp_allocator) or_else WORLD_FILE,
		b.buf[:],
	)
}

@(private = "file")
read_world_file :: proc(s: ^Server, text: string, path: string) -> bool {
	rules_text := strings.builder_make(context.temp_allocator)
	player: Saved_Player
	have_player := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		eq := strings.index_byte(l, '=')
		if eq < 0 {continue}
		key, value := strings.trim_space(l[:eq]), strings.trim_space(l[eq + 1:])
		switch {
		case key == "format":
			if n, ok := strconv.parse_int(value); !ok || n > WORLD_FORMAT {
				log.errorf(
					"server world from a newer game, not loaded path=%s format=%s",
					path,
					value,
				)
				return false
			}
		case key == "seed":
			if n, ok := strconv.parse_i64(value); ok {s.config.seed = n}
		case key == "time":
			if v, ok := strconv.parse_f64(value); ok && game.time_valid(v) {s.clock = v}
		case key == "player.x", key == "player.y", key == "player.z":
			if v, ok := strconv.parse_f64(value); ok && abs(v) < game.WORLD_LIMIT {
				player.state.position[int(key[len(key) - 1] - 'x')] = v
				have_player += 1
			}
		case key == "player.yaw":
			if v, ok := strconv.parse_f32(value);
			   ok && !math.is_nan(v) && abs(v) < 1e6 {player.yaw = v}
		case key == "player.pitch":
			if v, ok := strconv.parse_f32(value);
			   ok && !math.is_nan(v) {player.pitch = clamp(v, -game.PITCH_LIMIT, game.PITCH_LIMIT)}
		case key == "player.flying":
			player.state.flying = value == "true"
		case strings.has_prefix(key, "rules."):
			fmt.sbprintfln(&rules_text, "%s = %s", key, value)
		}
	}
	for p in base.vars_read(game.rules_table(), &s.rules, strings.to_string(rules_text)) {
		log.warnf(
			"server world rule ignored or clamped path=%s problem=%v text=%q",
			path,
			p.error,
			p.text,
		)
	}
	if have_player == 3 {s.store.player = player}
	log.infof("server world loaded dir=%s seed=%d", s.store.dir, s.config.seed)
	return true
}
