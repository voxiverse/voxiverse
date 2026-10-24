package server

import "core:encoding/json"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../game"

// What is kept about each player: their own file in the world,
// players/<name>.json (where they are, where they look, whether they fly,
// what they carry; statistics later). Loaded when they join; written,
// whole and atomically, at the next save after it changed; only players
// online (or not yet written) are in memory. The world's view of a player
// (homes, bans, nickname) is community.cfg's.

PLAYERS_DIR :: "players"
PLAYER_FILE_FORMAT :: 1

Player_Record :: struct {
	state:     game.Player_State,
	look:      [2]f32, // yaw, pitch
	inventory: game.Inventory,
	dirty:     bool, // changed since its file was written
}

// Player_File: the JSON of players/<name>.json (items by name: their ids
// are the wire's).
@(private = "file")
Player_File :: struct {
	format:   int,
	position: [3]f64,
	look:     [2]f32,
	flying:   bool,
	selected: int,
	items:    []File_Stack,
}

@(private = "file")
File_Stack :: struct {
	slot:  int, // CURSOR_SLOT: on the cursor when saved
	item:  string,
	count: int,
}

@(private = "file")
player_path :: proc(s: ^Server, name: string) -> string {
	file := strings.concatenate({name, ".json"}, context.temp_allocator)
	return filepath.join({s.store.dir, PLAYERS_DIR, file}, context.temp_allocator) or_else file
}

// player_record: what is kept about name (from memory, else their file);
// false for someone new.
player_record :: proc(s: ^Server, name: string) -> (Player_Record, bool) {
	if r, ok := s.store.players[name]; ok {return r, true}
	if s.store.dir == "" {return {}, false}
	path := player_path(s, name)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		if err != .Not_Exist {log.errorf("server cannot read path=%s error=%v", path, err)}
		return {}, false
	}
	r, ok := player_parse(data)
	if !ok {log.errorf("server player file not understood, starting afresh path=%s", path)}
	return r, ok
}

// player_parse reads a player file's JSON.
player_parse :: proc(data: []u8) -> (r: Player_Record, ok: bool) {
	f: Player_File
	if err := json.unmarshal(data, &f, allocator = context.temp_allocator); err != nil {return}
	if f.format < 1 || f.format > PLAYER_FILE_FORMAT {return}
	for v in f.position {if !(abs(v) < game.WORLD_LIMIT) {return}}
	if math.is_nan(f.look[0]) || math.is_nan(f.look[1]) {return}
	r.state = {
		position = f.position,
		flying   = f.flying,
	}
	r.look = {f.look[0], clamp(f.look[1], -game.PITCH_LIMIT, game.PITCH_LIMIT)}
	r.inventory.selected = clamp(f.selected, 0, game.HOTBAR_SLOTS - 1)
	for st in f.items {
		item, known := game.item_by_name(st.item)
		if !known || st.count <= 0 {
			log.warnf("server player file item dropped item=%q", st.item)
			continue
		}
		stack := game.Stack{item, min(st.count, game.item_stack_size(item))}
		switch {
		case st.slot >= 0 && st.slot < game.INVENTORY_SLOTS:
			r.inventory.slots[st.slot] = stack
		case st.slot == game.CURSOR_SLOT:
			r.inventory.cursor = stack
		}
	}
	return r, true
}

// player_json: a player file's text.
player_json :: proc(r: ^Player_Record) -> []u8 {
	items := make([dynamic]File_Stack, context.temp_allocator)
	for st, i in r.inventory.slots {
		if !game.stack_empty(st) {append(&items, File_Stack{i, game.item_name(st.item), st.count})}
	}
	if c := r.inventory.cursor; !game.stack_empty(c) {
		append(&items, File_Stack{game.CURSOR_SLOT, game.item_name(c.item), c.count})
	}
	f := Player_File {
		format   = PLAYER_FILE_FORMAT,
		position = r.state.position,
		look     = r.look,
		flying   = r.state.flying,
		selected = r.inventory.selected,
		items    = items[:],
	}
	data, _ := json.marshal(
		f,
		{pretty = true, use_spaces = true, spaces = 2},
		context.temp_allocator,
	)
	return data
}

// keep_player stores a playing client's player under its name (when it
// leaves, and before each save).
keep_player :: proc(s: ^Server, c: ^Client) {
	name := client_name(c)
	r := Player_Record{c.player, c.look, c.inventory, true}
	if _, had := s.store.players[name]; had {
		s.store.players[name] = r
	} else {
		s.store.players[strings.clone(name)] = r
	}
}

// players_save writes the files of the players that changed, and forgets
// those who are gone (their files have them).
players_save :: proc(s: ^Server) -> bool {
	for &c in s.clients {if c.state == .Playing {keep_player(s, &c)}}
	if s.store.dir == "" {return true}
	dir := filepath.join({s.store.dir, PLAYERS_DIR}, context.temp_allocator) or_else PLAYERS_DIR
	if err := os.make_directory_all(dir); err != nil && err != .Exist {
		log.errorf("server cannot create path=%s error=%v", dir, err)
		return false
	}
	ok := true
	gone := make([dynamic]string, context.temp_allocator)
	for name, &r in s.store.players {
		if r.dirty {
			if write_atomically(
				player_path(s, name),
				player_json(&r),
			) {r.dirty = false} else {ok = false}
		}
		if !r.dirty && client_by_name(s, name) == nil {append(&gone, name)}
	}
	for name in gone {
		key, _ := delete_key(&s.store.players, name)
		delete(key)
	}
	return ok
}

// The starter kit: what a player new to the world is given (world.cfg's
// `kit`, "stone 64, dirt 64, ..."). Items a player may not use (the rocket
// launcher without world.fire) are left out.
@(private = "file", rodata)
DEFAULT_KIT := [?]struct {
	name:  string,
	count: int,
} {
	{"stone", 64},
	{"dirt", 64},
	{"grass", 64},
	{"sand", 64},
	{"log", 64},
	{"leaves", 64},
	{"water", 64},
	{"lamp", 64},
	{"rocket_launcher", 1},
}

kit_default :: proc(kit: ^[dynamic]game.Stack) {
	clear(kit)
	for k in DEFAULT_KIT {
		if item, ok := game.item_by_name(k.name); ok {append(kit, game.Stack{item, k.count})}
	}
}

kit_text :: proc(kit: []game.Stack) -> string {
	b := strings.builder_make(context.temp_allocator)
	for st, i in kit {
		if i > 0 {strings.write_string(&b, ", ")}
		strings.write_string(&b, game.item_name(st.item))
		strings.write_byte(&b, ' ')
		strings.write_int(&b, st.count)
	}
	return strings.to_string(b)
}

kit_parse :: proc(text: string) -> ([]game.Stack, bool) {
	kit := make([dynamic]game.Stack, context.temp_allocator)
	rest := text
	for part in strings.split_iterator(&rest, ",") {
		f := strings.fields(part, context.temp_allocator)
		if len(f) == 0 {continue}
		if len(f) > 2 {return nil, false}
		item, ok := game.item_by_name(f[0])
		if !ok {return nil, false}
		count := 1
		if len(f) == 2 {
			n, counted := parse_count(f[1])
			if !counted {return nil, false}
			count = n
		}
		append(
			&kit,
			game.Stack{item, min(count, game.item_stack_size(item) * game.INVENTORY_SLOTS)},
		)
	}
	return kit[:], true
}

// give_kit fills a new player's inventory from the world's kit.
give_kit :: proc(s: ^Server, c: ^Client) {
	for st in s.kit {
		info, _ := game.item_info(st.item)
		if t, tool := info.tool.?;
		   tool && t == .Launcher && !allowed(s, c, "world.fire") {continue}
		game.inventory_add(&c.inventory, st)
	}
}
