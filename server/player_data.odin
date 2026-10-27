package server

import "core:encoding/json"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../common/game"

// What is kept about each character: their own file in the universe,
// characters/<account>/<name>.json (where they are, where they look,
// whether they fly, what they carry; statistics later). Loaded when they
// join; written, whole and atomically, at the next save after it changed;
// only characters online (or not yet written) are in memory. Names are the
// universe's: one account each (Store.characters, read from the
// directories at start). The universe's view of a character (homes, bans,
// nickname) is community.cfg's.
//
// Before accounts, players' files were players/<name>.json: such a name is
// free for the first account that joins with it, which takes its file.

CHARACTERS_DIR :: "characters"
PLAYERS_DIR :: "players"
PLAYER_FILE_FORMAT :: 1

Player_Record :: struct {
	account:   Maybe(game.Account), // whose (none: from before accounts, unclaimed)
	world:     Maybe(game.Address), // where they are (none: the home world)
	state:     game.Player_State,
	look:      [2]f32, // yaw, pitch
	inventory: game.Inventory,
	dirty:     bool, // changed since its file was written
	stats:     Counters, // its counters (heap; stats.odin)
	overflow:  [MAX_OVERFLOW]game.Stack, // read but with no room (an older, bigger inventory): dropped at their feet on joining
}

MAX_OVERFLOW :: 16

// Player_File: the JSON of players/<name>.json (items by name: their ids
// are the wire's).
@(private = "file")
Player_File :: struct {
	format:   int,
	world:    string, // its address (directory form); "": the home world
	position: [3]f64,
	look:     [2]f32,
	flying:   bool,
	selected: int,
	items:    []File_Stack,
	stats:    map[string]u64, // counters (stats.odin)
}

@(private = "file")
// EQUIPMENT_FILE_SLOT: the slot number equipment is kept under in a file
// (Head, then the rest), clear of any inventory's.
EQUIPMENT_FILE_SLOT :: 100

File_Stack :: struct {
	slot:  int, // CURSOR_SLOT: on the cursor when saved
	item:  string,
	count: int,
}

// character_path: where name's file is (its account's directory, or
// before accounts players/).
@(private)
character_path :: proc(s: ^Server, name: string, account: Maybe(game.Account)) -> string {
	file := strings.concatenate({name, ".json"}, context.temp_allocator)
	if a, ok := account.?; ok {
		return(
			filepath.join(
				{s.store.dir, CHARACTERS_DIR, game.account_text(a), file},
				context.temp_allocator,
			) or_else file \
		)
	}
	return filepath.join({s.store.dir, PLAYERS_DIR, file}, context.temp_allocator) or_else file
}

// characters_open reads which account each character name belongs to
// (characters/<account>/<name>.json).
characters_open :: proc(s: ^Server) {
	if s.store.dir == "" {return}
	root :=
		filepath.join({s.store.dir, CHARACTERS_DIR}, context.temp_allocator) or_else CHARACTERS_DIR
	accounts, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil {return} 	// none yet
	for a in accounts {
		account, ok := game.account_parse(a.name)
		if a.type != .Directory || !ok {continue}
		files, _ := os.read_all_directory_by_path(
			filepath.join({root, a.name}, context.temp_allocator) or_else root,
			context.temp_allocator,
		)
		for f in files {
			name := strings.trim_suffix(f.name, ".json")
			if f.type == .Regular && len(name) < len(f.name) && game.name_valid(name) {
				s.store.characters[strings.clone(name)] = account
			}
		}
	}
	log.infof("server characters known=%d", len(s.store.characters))
}

// characters_of: account's character names here, sorted.
characters_of :: proc(s: ^Server, account: game.Account) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for name, a in s.store.characters {if a == account {append(&names, name)}}
	slice.sort(names[:])
	return names[:]
}

// character_claim: name is account's from now on.
character_claim :: proc(s: ^Server, name: string, account: game.Account) {
	if _, known := s.store.characters[name]; known {return}
	s.store.characters[strings.clone(name)] = account
	log.infof("server character made name=%s account=%s", name, game.account_text(account))
}

// player_record: what is kept about the character name (from memory, else
// its file, else its file from before accounts); false for a new one.
player_record :: proc(s: ^Server, name: string) -> (Player_Record, bool) {
	if r, ok := s.store.players[name]; ok {return r, true}
	if s.store.dir == "" {return {}, false}
	account, claimed := s.store.characters[name]
	paths := [2]string {
		character_path(s, name, account) if claimed else "",
		character_path(s, name, nil),
	}
	for path in paths {
		if path == "" {continue}
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {
			if err != .Not_Exist {log.errorf("server cannot read path=%s error=%v", path, err)}
			continue
		}
		r, ok := player_parse(data)
		if !ok {
			log.errorf("server character file not understood, starting afresh path=%s", path)
			return {}, false
		}
		if claimed {r.account = account}
		r.dirty = path != paths[0] // (from players/: to be written where it belongs)
		return r, true
	}
	return {}, false
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
	if f.world != "" {
		if a, valid := game.address_parse(f.world, {}); valid {r.world = a}
	}
	r.inventory.selected = clamp(f.selected, 0, game.HOTBAR_SLOTS - 1)
	r.stats = counters_clone(f.stats)
	late := make([dynamic]game.Stack, context.temp_allocator)
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
		case st.slot >= EQUIPMENT_FILE_SLOT &&
		     st.slot < EQUIPMENT_FILE_SLOT + game.EQUIP_SLOTS &&
		     game.item_fits(stack, game.Equip_Slot(st.slot - EQUIPMENT_FILE_SLOT)) &&
		     game.stack_empty(
			     r.inventory.equipment[game.Equip_Slot(st.slot - EQUIPMENT_FILE_SLOT)],
		     ):
			r.inventory.equipment[game.Equip_Slot(st.slot - EQUIPMENT_FILE_SLOT)] = stack
		case st.slot == game.CURSOR_SLOT:
			r.inventory.cursor = stack
		case:
			append(&late, stack) // a slot the inventory no longer has
		}
	}
	// What was in slots there are no more: wherever there is room, the rest
	// to be dropped.
	n := 0
	for st in late {
		left := game.inventory_add(&r.inventory, st)
		if !game.stack_empty(left) && n < MAX_OVERFLOW {
			r.overflow[n] = left
			n += 1
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
	for st, e in r.inventory.equipment {
		if !game.stack_empty(st) {
			append(
				&items,
				File_Stack{EQUIPMENT_FILE_SLOT + int(e), game.item_name(st.item), st.count},
			)
		}
	}
	if c := r.inventory.cursor; !game.stack_empty(c) {
		append(&items, File_Stack{game.CURSOR_SLOT, game.item_name(c.item), c.count})
	}
	world := ""
	if a, has := r.world.?; has {world = game.address_dir(a)}
	f := Player_File {
		format   = PLAYER_FILE_FORMAT,
		world    = world,
		position = r.state.position,
		look     = r.look,
		flying   = r.state.flying,
		selected = r.inventory.selected,
		items    = items[:],
		stats    = r.stats,
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
	r := Player_Record {
		account   = c.account,
		world     = c.world.address,
		state     = c.player,
		look      = c.look,
		inventory = c.inventory,
		dirty     = true,
		stats     = counters_clone(c.stats),
	}
	if old, had := &s.store.players[name]; had {
		counters_free(&old.stats)
		old^ = r
	} else {
		s.store.players[strings.clone(name)] = r
	}
}

// players_save writes the files of the players that changed, and forgets
// those who are gone (their files have them).
players_save :: proc(s: ^Server) -> bool {
	for &c in s.clients {if c.state == .Playing {keep_player(s, &c)}}
	if s.store.dir == "" {return true}
	ok := true
	gone := make([dynamic]string, context.temp_allocator)
	for name, &r in s.store.players {
		if r.dirty {
			path := character_path(s, name, r.account)
			if err := os.make_directory_all(filepath.dir(path)); err != nil && err != .Exist {
				log.errorf("server cannot create the directory of path=%s error=%v", path, err)
				ok = false
				continue
			}
			if !store_write(s, path, player_json(&r)) {
				ok = false
				continue
			}
			r.dirty = false
			if _, claimed := r.account.?; claimed {
				// Its file from before accounts is this one now.
				old := character_path(s, name, nil)
				if os.exists(old) {store_delete(s, old)}
			}
		}
		if client_by_name(s, name) == nil {append(&gone, name)}
	}
	for name in gone {
		if r, present := &s.store.players[name]; present {counters_free(&r.stats)}
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
		left := game.inventory_add(&c.inventory, st)
		ledger(s, c.world, .Kit, st.item, st.count - left.count)
	}
}
