package core

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "common:access"
import "common:base"
import "common:game"
import "common:starmap"

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
PLAYER_FILE_FORMAT :: 7 // 7: the logbook (`logbook`; before: none). 6: an inventory set aside (`aside`; before: none). 5: the game's record on the character (`game`; before: none). 4: an item's game data (`data`; before: 0). 3: the trader (the sandbox's now: read by the save migration from format 8, ignored here). 2: a weapon's magazine (`ammo`); a file of 1 has none: full

Player_Record :: struct {
	account:        Maybe(access.Account), // whose (none: from before accounts, unclaimed)
	world:          Maybe(starmap.Address), // where they are (none: the home world)
	state:          game.Player_State,
	look:           [2]f32, // yaw, pitch
	mode:           base.Var_Text, // their game mode's id ("": none yet: the world's default)
	inventory:      game.Inventory,
	aside:          Maybe(game.Inventory), // the inventory set aside (inventory_set_aside; none: nothing is)
	character_data: game.Character_Data, // the game's record on the character (Game.character_data)
	logbook:        game.Logbook, // the places it found and the creatures it met (logbook_place)
	dirty:          bool, // changed since its file was written
	stats:          Counters, // its counters (heap; stats.odin)
	overflow:       [MAX_OVERFLOW]game.Stack, // read but with no room (an older, bigger inventory): dropped at their feet on joining
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
	mode:     string, // their game mode's id (absent in a file from before modes)
	items:    []File_Stack,
	aside:    Maybe([]File_Stack) `json:"aside,omitempty"`, // format 6: the inventory set aside (inventory_set_aside), its stacks numbered as items'
	game:     json.Value `json:"game,omitempty"`, // format 5: the game's record, a field by its path (written by hand: player_json)
	logbook:  Maybe(File_Logbook) `json:"logbook,omitempty"`, // format 7: the places found (each in its world) and the creatures met, by name
}

// File_Logbook: a logbook as a player file keeps it (kinds by name: their numbers are the
// registry's of the day).
File_Logbook :: struct {
	places: []File_Place,
	met:    []string, // creature kinds' ids
}

File_Place :: struct {
	kind:  string, // "gate", "ruin", ...
	world: string, // its address (directory form)
	at:    [3]i32,
	name:  string `json:"name,omitempty"`,
}

@(rodata)
PLACE_KIND_NAMES := [game.Logbook_Place_Kind]string {
	.Gate    = "gate",
	.Ruin    = "ruin",
	.Town    = "town",
	.Outpost = "outpost",
	.Beacon  = "beacon",
}

@(private = "file")
// EQUIPMENT_FILE_SLOT: the slot number equipment is kept under in a file
// (Head, then the rest), clear of any inventory's.
EQUIPMENT_FILE_SLOT :: 100

File_Stack :: struct {
	slot:  int, // CURSOR_SLOT: on the cursor when saved
	item:  string,
	count: int,
	ammo:  int, // a weapon's magazine (format 2)
	data:  u32, // the game's number for it (format 4: Stack.data)
}

// character_path: where name's file is (its account's directory, or
// before accounts players/).
@(private)
character_path :: proc(s: ^Server, name: string, account: Maybe(access.Account)) -> string {
	file := strings.concatenate({name, ".json"}, context.temp_allocator)
	if a, ok := account.?; ok {
		return(
			filepath.join(
				{s.store.dir, CHARACTERS_DIR, access.account_text(a), file},
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
		account, ok := access.account_parse(a.name)
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
characters_of :: proc(s: ^Server, account: access.Account) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for name, a in s.store.characters {if a == account {append(&names, name)}}
	slice.sort(names[:])
	return names[:]
}

// character_claim: name is account's from now on.
character_claim :: proc(s: ^Server, name: string, account: access.Account) {
	if _, known := s.store.characters[name]; known {return}
	s.store.characters[strings.clone(name)] = account
	log.infof("server character made name=%s account=%s", name, access.account_text(account))
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
		r, ok := player_parse(s.registry, data, s.config.game.character_data)
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

// player_parse reads a player file's JSON; character is the type of the game's record on a
// character (Game.character_data; nil: none).
player_parse :: proc(
	reg: ^game.Registry,
	data: []u8,
	character: typeid,
) -> (
	r: Player_Record,
	ok: bool,
) {
	rest, stats, found, read := split_stats(data)
	if !read {return}
	f: Player_File
	if err := json.unmarshal(rest, &f, allocator = context.temp_allocator); err != nil {
		if found {counters_free(&stats)}
		return
	}
	defer if !ok {counters_free(&stats)}
	if f.format < 1 || f.format > PLAYER_FILE_FORMAT {return}
	for v in f.position {if !(abs(v) < game.WORLD_LIMIT) {return}}
	if math.is_nan(f.look[0]) || math.is_nan(f.look[1]) {return}
	r.state = {
		position = f.position,
		flying   = f.flying,
	}
	r.look = {f.look[0], clamp(f.look[1], -game.PITCH_LIMIT, game.PITCH_LIMIT)}
	if f.world != "" {
		if a, valid := starmap.address_parse(f.world, {}); valid {r.world = a}
	}
	base.var_text_set(&r.mode, f.mode) // (too long: none)
	r.inventory.selected = clamp(f.selected, 0, game.HOTBAR_SLOTS - 1)
	r.stats = stats
	if record, is_record := f.game.(json.Object); is_record && character != nil {
		character_data_read(character, &r.character_data, record)
	}
	if lb, has := f.logbook.?; has {logbook_read(reg, lb, &r.logbook)}
	n := stacks_read(reg, f.format, f.items, &r.inventory, r.overflow[:])
	if stacks, set_aside := f.aside.?; set_aside {
		aside: game.Inventory
		stacks_read(reg, f.format, stacks, &aside, r.overflow[n:])
		r.aside = aside
	}
	return r, true
}

// stacks_read puts a player file's stacks (of a file of format) into inv, each in its
// slot. What was in slots there are no more goes wherever there is room, and the rest
// into overflow, to be dropped (as far as it holds): how many went there.
@(private = "file")
stacks_read :: proc(
	reg: ^game.Registry,
	format: int,
	stacks: []File_Stack,
	inv: ^game.Inventory,
	overflow: []game.Stack,
) -> int {
	late := make([dynamic]game.Stack, context.temp_allocator)
	for st in stacks {
		item, known := game.item_by_name(reg, st.item)
		if !known || st.count <= 0 {
			log.warnf("server player file item dropped item=%q", st.item)
			continue
		}
		stack := game.Stack{item, min(st.count, game.item_stack_size(reg, item)), 0, 0}
		stack.ammo = game.new_ammo(reg, item) // (a file of format 1 has no magazines: full)
		if format >= 2 {stack.ammo = u8(clamp(st.ammo, 0, int(stack.ammo)))}
		stack.data = st.data
		switch {
		case st.slot >= 0 && st.slot < game.INVENTORY_SLOTS:
			inv.slots[st.slot] = stack
		case st.slot >= EQUIPMENT_FILE_SLOT &&
		     st.slot < EQUIPMENT_FILE_SLOT + game.EQUIP_SLOTS &&
		     game.item_fits(reg, stack, game.Equip_Slot(st.slot - EQUIPMENT_FILE_SLOT)) &&
		     game.stack_empty(inv.equipment[game.Equip_Slot(st.slot - EQUIPMENT_FILE_SLOT)]):
			inv.equipment[game.Equip_Slot(st.slot - EQUIPMENT_FILE_SLOT)] = stack
		case st.slot == game.CURSOR_SLOT:
			inv.cursor = stack
		case:
			append(&late, stack) // a slot the inventory no longer has
		}
	}
	n := 0
	for st in late {
		left := game.inventory_add(reg, inv, st)
		if !game.stack_empty(left) && n < len(overflow) {
			overflow[n] = left
			n += 1
		}
	}
	return n
}

// player_json: a player file's text; character is the type of the game's record on a
// character (Game.character_data; nil: none).
player_json :: proc(reg: ^game.Registry, r: ^Player_Record, character: typeid) -> []u8 {
	world := ""
	if a, has := r.world.?; has {world = starmap.address_dir(a)}
	f := Player_File {
		format   = PLAYER_FILE_FORMAT,
		world    = world,
		position = r.state.position,
		look     = r.look,
		flying   = r.state.flying,
		selected = r.inventory.selected,
		mode     = base.var_text(&r.mode),
		items    = file_stacks(reg, &r.inventory),
	}
	if aside, set_aside := r.aside.?; set_aside {f.aside = file_stacks(reg, &aside)}
	if r.logbook.place_count > 0 ||
	   r.logbook.met_count > 0 {f.logbook = logbook_file(reg, &r.logbook)}
	data, _ := json.marshal(
		f,
		{pretty = true, use_spaces = true, spaces = 2},
		context.temp_allocator,
	)
	// The counters go in by hand, last (counters_write): thousands of them
	// are too many for the reflecting marshaller.
	b := strings.builder_make(0, len(data) + 64 * len(r.stats) + 32, context.temp_allocator)
	strings.write_bytes(&b, data[:len(data) - 1]) // (without the closing brace)
	if character != nil {character_data_write(&b, character, &r.character_data)}
	strings.write_string(&b, ",\n  \"stats\": ")
	counters_write(&b, r.stats, "    ")
	strings.write_string(&b, "\n}")
	return b.buf[:]
}

// file_stacks: an inventory's stacks as a player file has them (temporary memory), each
// numbered by its slot.
@(private = "file")
file_stacks :: proc(reg: ^game.Registry, inv: ^game.Inventory) -> []File_Stack {
	items := make([dynamic]File_Stack, context.temp_allocator)
	put :: proc(reg: ^game.Registry, items: ^[dynamic]File_Stack, slot: int, st: game.Stack) {
		if game.stack_empty(st) {return}
		append(
			items,
			File_Stack{slot, game.item_id(reg, st.item), st.count, int(st.ammo), st.data},
		)
	}
	for st, i in inv.slots {put(reg, &items, i, st)}
	for st, e in inv.equipment {put(reg, &items, EQUIPMENT_FILE_SLOT + int(e), st)}
	put(reg, &items, game.CURSOR_SLOT, inv.cursor)
	return items[:]
}

// split_stats takes the "stats" member out of a player file's JSON: the
// counters, read by hand (counters_read), and the rest of the text, to be read
// as the struct it is. found is false when there is no such member; read when
// the file is JSON as far as it was looked at.
split_stats :: proc(data: []u8) -> (rest: []u8, stats: Counters, found, read: bool) {
	t := json.make_tokenizer(string(data), parse_integers = true)
	depth := 0
	prev := json.Token_Kind.Invalid
	for {
		tok, err := json.get_token(&t)
		if tok.kind == .EOF {return data, {}, false, depth == 0}
		if err != .None {return}
		#partial switch tok.kind {
		case .Open_Brace, .Open_Bracket:
			depth += 1
		case .Close_Brace, .Close_Bracket:
			depth -= 1
		case .String:
			if depth == 1 && (prev == .Open_Brace || prev == .Comma) && tok.text == `"stats"` {
				from := tok.offset
				if colon, cerr := json.get_token(&t);
				   cerr != .None || colon.kind != .Colon {return}
				end: int
				stats, end, read = counters_read(&t)
				if !read {return}
				// The text without the member, and the comma that went with it.
				before := strings.trim_right_space(string(data[:from]))
				after := strings.trim_left_space(string(data[end:]))
				if strings.has_suffix(before, ",") && strings.has_prefix(after, "}") {
					before = before[:len(before) - 1]
				} else if strings.has_suffix(before, "{") && strings.has_prefix(after, ",") {
					after = after[1:]
				}
				return transmute([]u8)strings.concatenate(
						{before, " ", after},
						context.temp_allocator,
					),
					stats,
					true,
					true
			}
		}
		prev = tok.kind
	}
}

// character_data: the game's record on c's character, as the type it declared
// (Game.character_data). Zero for a character new to the universe; kept with the character
// (its file's `game` member) and given back when it joins again.
character_data :: proc(s: ^Server, c: ^Client, $T: typeid) -> ^T {
	assert(s.config.game.character_data == T, "not the game's character_data")
	return (^T)(&c.character_data.bytes)
}

// character_data_write: the `game` member of a character file, a field by its path (only
// those not zero), its value a JSON number or boolean where it is one, else a string (an
// enum's name).
@(private = "file")
character_data_write :: proc(b: ^strings.Builder, T: typeid, data: ^game.Character_Data) {
	strings.write_string(b, ",\n  \"game\": {")
	for f, i in game.data_fields(T, &data.bytes) {
		strings.write_string(b, "," if i > 0 else "")
		strings.write_string(b, "\n    ")
		json_string(b, f.path)
		strings.write_string(b, ": ")
		if _, number := strconv.parse_f64(f.text);
		   number || f.text == "true" || f.text == "false" {
			strings.write_string(b, f.text)
		} else {
			json_string(b, f.text)
		}
	}
	strings.write_string(b, "\n  }")
}

@(private = "file")
json_string :: proc(b: ^strings.Builder, text: string) {
	data, _ := json.marshal(text, allocator = context.temp_allocator)
	strings.write_bytes(b, data)
}

// character_data_read: the game's record from a character file's `game` member. A field the
// type no longer has, or a value it cannot hold, is skipped and logged; the rest is read.
@(private = "file")
character_data_read :: proc(T: typeid, data: ^game.Character_Data, record: json.Object) {
	fields := make([dynamic]game.Data_Field, 0, len(record), context.temp_allocator)
	for path, value in record {
		text: string
		switch v in value {
		case json.Null, json.Array, json.Object:
			text = "" // (no field's value: skipped as bad)
		case json.Integer:
			text = fmt.tprintf("%d", v)
		case json.Float:
			text = fmt.tprintf("%v", v)
		case json.Boolean:
			text = "true" if v else "false"
		case json.String:
			text = v
		}
		append(&fields, game.Data_Field{path, text})
	}
	if bad := game.data_fields_read(T, &data.bytes, fields[:]); bad != "" {
		log.warnf("server character file's game field skipped field=%s", bad)
	}
}

// keep_player stores a playing client's player under its name (when it
// leaves, and before each save).
keep_player :: proc(s: ^Server, c: ^Client) {
	name := client_name(c)
	r := Player_Record {
		account        = c.account,
		world          = c.world.address,
		state          = c.player,
		look           = c.look,
		inventory      = c.inventory,
		aside          = c.aside,
		character_data = c.character_data,
		logbook        = c.logbook,
		mode           = mode_record_text(s, c),
		dirty          = true,
		stats          = counters_clone(c.stats),
	}
	if old, had := &s.store.players[name]; had {
		counters_free(&old.stats)
		old^ = r
	} else {
		s.store.players[strings.clone(name)] = r
	}
}

// The starter kit: what a player new to the world is given (universe.cfg's
// `kit`, "stone 64, dirt 64, ..."): the universe's own, else the Config's,
// which is the game's to choose (its configure: the sandbox gives the rocket
// launcher); by default nothing. Items a player may not use (the launcher
// without world.fire) are left out.

kit_text :: proc(reg: ^game.Registry, kit: []game.Stack) -> string {
	b := strings.builder_make(context.temp_allocator)
	for st, i in kit {
		if i > 0 {strings.write_string(&b, ", ")}
		strings.write_string(&b, game.item_id(reg, st.item))
		strings.write_byte(&b, ' ')
		strings.write_int(&b, st.count)
	}
	return strings.to_string(b)
}

kit_parse :: proc(reg: ^game.Registry, text: string) -> ([]game.Stack, bool) {
	kit := make([dynamic]game.Stack, context.temp_allocator)
	rest := text
	for part in strings.split_iterator(&rest, ",") {
		f := strings.fields(part, context.temp_allocator)
		if len(f) == 0 {continue}
		if len(f) > 2 {return nil, false}
		item, ok := game.item_by_name(reg, f[0])
		if !ok {return nil, false}
		count := 1
		if len(f) == 2 {
			n, counted := parse_count(f[1])
			if !counted {return nil, false}
			count = n
		}
		append(
			&kit,
			game.Stack {
				item,
				min(count, game.item_stack_size(reg, item) * game.INVENTORY_SLOTS),
				0,
				0,
			},
		)
	}
	return kit[:], true
}

// give_kit fills a new player's inventory from the world's kit.
give_kit :: proc(s: ^Server, c: ^Client) {
	for st in s.kit {
		info, _ := game.item_info(s.registry, st.item)
		if t, tool := info.tool.?;
		   tool && t == .Launcher && !allowed(s, c, "world.fire") {continue}
		if game.inventory_count(&c.inventory, st.item) >= st.count {continue} 	// (the mode's kit gave it)
		left := game.inventory_add(s.registry, &c.inventory, st)
		ledger(s, c.world, .Kit, st.item, st.count - left.count)
	}
}

// logbook_file: a logbook as a player file keeps it (temporary memory).
@(private = "file")
logbook_file :: proc(reg: ^game.Registry, lb: ^game.Logbook) -> File_Logbook {
	places := make([]File_Place, lb.place_count, context.temp_allocator)
	for &p, i in lb.places[:lb.place_count] {
		places[i] = {
			PLACE_KIND_NAMES[p.kind],
			starmap.address_dir(p.world),
			p.at,
			strings.clone(game.place_name(&p), context.temp_allocator),
		}
	}
	met := make([dynamic]string, context.temp_allocator)
	for k in lb.met[:lb.met_count] {
		if info := game.kind_info(reg, k); info != nil {append(&met, info.id)}
	}
	return {places, met[:]}
}

// logbook_read: a player file's logbook into lb; a place of a kind or world it cannot
// read, or a creature kind the registry no longer has, is left out (and logged).
@(private = "file")
logbook_read :: proc(reg: ^game.Registry, f: File_Logbook, lb: ^game.Logbook) {
	for p in f.places {
		kind, known := game.Logbook_Place_Kind(0), false
		for name, k in PLACE_KIND_NAMES {if name == p.kind {kind, known = k, true}}
		world, valid := starmap.address_parse(p.world, {})
		if !known || !valid || !game.in_world(game.chunk_of(p.at)) {
			log.warnf("server player file logbook place skipped kind=%q world=%q", p.kind, p.world)
			continue
		}
		game.logbook_place(lb, kind, world, p.at, p.name[:min(len(p.name), game.PLACE_NAME_MAX)])
	}
	for id in f.met {
		kind, found := game.registry_kind(reg, id)
		if !found {
			log.warnf("server player file logbook creature skipped kind=%q", id)
			continue
		}
		game.logbook_meet(lb, kind)
	}
}

// logbook_place notes a place in c's logbook (a gate it opened; a game's places, such as
// the sandbox's ruin once found): kept with its character and sent to it, its journal
// lists it, the compass marks it and the map shows it. One of the same kind within
// game.PLACE_SAME blocks in the same world is that one (named anew by a name). name: ""
// for the kind's own.
logbook_place :: proc(
	s: ^Server,
	c: ^Client,
	kind: game.Logbook_Place_Kind,
	at: [3]i32,
	name := "",
) {
	game.logbook_place(&c.logbook, kind, c.world.address, at, name)
}
