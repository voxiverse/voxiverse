package core

import "core:encoding/json"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "common:base"
import "common:game"
import "common:planet"

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
PLAYER_FILE_FORMAT :: 3 // 3: the trader; a file before has an empty one and the starting purse. 2: a weapon's magazine (`ammo`); a file of 1 has none: full

Player_Record :: struct {
	account:   Maybe(game.Account), // whose (none: from before accounts, unclaimed)
	world:     Maybe(game.Address), // where they are (none: the home world)
	state:     game.Player_State,
	look:      [2]f32, // yaw, pitch
	mode:      base.Var_Text, // their game mode's id ("": none yet: the world's default)
	inventory: game.Inventory,
	trader:    Trader_Record, // silver, cargo and seen prices (trading.odin)
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
	mode:     string, // their game mode's id (absent in a file from before modes)
	items:    []File_Stack,
	trader:   Trader_File, // format 3
}

@(private = "file")
Trader_File :: struct {
	cash:  f64,
	cargo: [len(planet.Good)]f32,
	seen:  []Seen_File,
}

@(private = "file")
Seen_File :: struct {
	cell:  u32,
	good:  int,
	price: f32,
	month: f64,
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
		r, ok := player_parse(s.registry, data)
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
player_parse :: proc(reg: ^game.Registry, data: []u8) -> (r: Player_Record, ok: bool) {
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
		if a, valid := game.address_parse(f.world, {}); valid {r.world = a}
	}
	base.var_text_set(&r.mode, f.mode) // (too long: none)
	r.inventory.selected = clamp(f.selected, 0, game.HOTBAR_SLOTS - 1)
	r.stats = stats
	r.trader.cash = STARTING_PURSE
	if f.format >= 3 {
		tf := f.trader
		r.trader.cash = tf.cash if tf.cash >= 0 && tf.cash < 1e15 else STARTING_PURSE
		for v, i in tf.cargo {
			r.trader.cargo[planet.Good(i)] = v if v >= 0 && v < 1e9 else 0
		}
		for sf in tf.seen {
			if sf.good < 0 || sf.good >= len(planet.Good) {continue}
			if !(sf.price >= 0 && sf.price < 1e9) || !(abs(sf.month) < 1e9) {continue}
			seen_put(&r.trader, Seen{sf.cell, sf.price, f32(sf.month), planet.Good(sf.good)})
		}
	}
	late := make([dynamic]game.Stack, context.temp_allocator)
	for st in f.items {
		item, known := game.item_by_name(reg, st.item)
		if !known || st.count <= 0 {
			log.warnf("server player file item dropped item=%q", st.item)
			continue
		}
		stack := game.Stack{item, min(st.count, game.item_stack_size(reg, item)), 0}
		stack.ammo = game.new_ammo(reg, item) // (a file of format 1 has no magazines: full)
		if f.format >= 2 {stack.ammo = u8(clamp(st.ammo, 0, int(stack.ammo)))}
		switch {
		case st.slot >= 0 && st.slot < game.INVENTORY_SLOTS:
			r.inventory.slots[st.slot] = stack
		case st.slot >= EQUIPMENT_FILE_SLOT &&
		     st.slot < EQUIPMENT_FILE_SLOT + game.EQUIP_SLOTS &&
		     game.item_fits(reg, stack, game.Equip_Slot(st.slot - EQUIPMENT_FILE_SLOT)) &&
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
		left := game.inventory_add(reg, &r.inventory, st)
		if !game.stack_empty(left) && n < MAX_OVERFLOW {
			r.overflow[n] = left
			n += 1
		}
	}
	return r, true
}

// player_json: a player file's text.
player_json :: proc(reg: ^game.Registry, r: ^Player_Record) -> []u8 {
	items := make([dynamic]File_Stack, context.temp_allocator)
	for st, i in r.inventory.slots {
		if !game.stack_empty(
			st,
		) {append(&items, File_Stack{i, game.item_id(reg, st.item), st.count, int(st.ammo)})}
	}
	for st, e in r.inventory.equipment {
		if !game.stack_empty(st) {
			append(
				&items,
				File_Stack {
					EQUIPMENT_FILE_SLOT + int(e),
					game.item_id(reg, st.item),
					st.count,
					int(st.ammo),
				},
			)
		}
	}
	if c := r.inventory.cursor; !game.stack_empty(c) {
		append(
			&items,
			File_Stack{game.CURSOR_SLOT, game.item_id(reg, c.item), c.count, int(c.ammo)},
		)
	}
	seen := make([dynamic]Seen_File, context.temp_allocator)
	for i in 0 ..< r.trader.count {
		e := r.trader.seen[i]
		append(&seen, Seen_File{e.cell, int(e.good), e.price, f64(e.month)})
	}
	world := ""
	if a, has := r.world.?; has {world = game.address_dir(a)}
	f := Player_File {
		format = PLAYER_FILE_FORMAT,
		world = world,
		position = r.state.position,
		look = r.look,
		flying = r.state.flying,
		selected = r.inventory.selected,
		mode = base.var_text(&r.mode),
		items = items[:],
		trader = {cash = r.trader.cash, seen = seen[:]},
	}
	for g in planet.Good {f.trader.cargo[int(g)] = r.trader.cargo[g]}
	data, _ := json.marshal(
		f,
		{pretty = true, use_spaces = true, spaces = 2},
		context.temp_allocator,
	)
	// The counters go in by hand, last (counters_write): thousands of them
	// are too many for the reflecting marshaller.
	b := strings.builder_make(0, len(data) + 64 * len(r.stats) + 32, context.temp_allocator)
	strings.write_bytes(&b, data[:len(data) - 1]) // (without the closing brace)
	strings.write_string(&b, ",\n  \"stats\": ")
	counters_write(&b, r.stats, "    ")
	strings.write_string(&b, "\n}")
	return b.buf[:]
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
		trader    = c.trader,
		mode      = mode_record_text(s, c),
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

// The starter kit: what a player new to the world is given (world.cfg's
// `kit`, "stone 64, dirt 64, ..."). By default the rocket launcher alone, in
// hotbar slot 1 (blocks are reached by creative's catalog; how
// survival gathers is the owner's to decide). Items a player may not use
// (the launcher without world.fire) are left out.
DEFAULT_KIT_TEXT :: "rocket_launcher 1"

// default_kit_override: the tests start worlds with a kit of blocks to place
// (kit_test.odin sets it at start-up); a game never sets it. A world's own
// kit (world.cfg) or a Config's comes first either way.
default_kit_override: string

kit_default :: proc(reg: ^game.Registry, kit: ^[dynamic]game.Stack) {
	clear(kit)
	text := default_kit_override if default_kit_override != "" else DEFAULT_KIT_TEXT
	if stacks, ok := kit_parse(reg, text); ok {append(kit, ..stacks)}
}

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

// ---- the player as a trader ----
// The player as a trader (docs/world.md, the economy). Each player carries silver, cargo and
// the prices they have seen; the server is the authority: `trade` checks where they stand, what
// they hold and what the market holds, and moves goods and silver through the same
// `planet.trader_buy` and `trader_sell` that move the market's price as a caravan does.
// What a player knows of a town's prices is what they saw standing in it (or were told there),
// kept by the town's climate cell (stable between saves) with the month the price was true.

STARTING_PURSE :: 20.0 // silver of a new player (and of an old file's)
TRADE_RADIUS_KM :: 15.0 // a player this near a town may trade in it
MAX_SEEN :: 192 // prices a player remembers: the oldest are forgotten first

Seen :: struct {
	cell:  u32,
	price: f32,
	month: f32, // (whole months: exact)
	good:  planet.Good,
}

// Trader_Record is what a player carries as a trader; it holds no pointers (records copy).
Trader_Record :: struct {
	cash:  f64,
	cargo: [planet.Good]f32,
	seen:  [MAX_SEEN]Seen,
	count: int,
}

Trade_Side :: enum {
	Buy,
	Sell,
}

Trade_Result :: enum {
	Done,
	No_Economy, // the world has no detailed market there
	Bad_Quantity,
	Away, // not within the town's radius
	No_Market, // the town does not trade in the good
	No_Cash,
	No_Cargo,
	No_Stock, // the market has too little to sell
}

// seen_put remembers a price unless a newer one of that town and good is kept.
seen_put :: proc(t: ^Trader_Record, s: Seen) {
	oldest := 0
	for i in 0 ..< t.count {
		e := &t.seen[i]
		if e.cell == s.cell && e.good == s.good {
			if s.month >= e.month {e^ = s}
			return
		}
		if e.month < t.seen[oldest].month {oldest = i}
	}
	if t.count < MAX_SEEN {
		t.seen[t.count] = s
		t.count += 1
	} else if s.month >= t.seen[oldest].month {
		t.seen[oldest] = s
	}
}

// trader_known: what a trader remembers of a town's price of a good.
trader_known :: proc(t: ^Trader_Record, cell: u32, g: planet.Good) -> (Seen, bool) {
	for i in 0 ..< t.count {
		if t.seen[i].cell == cell && t.seen[i].good == g {return t.seen[i], true}
	}
	return {}, false
}

// trader_where: the town (an index in the economy) the player stands within the radius of,
// the nearest one in detail.
trader_where :: proc(w: ^World, c: ^Client) -> (town: int, ok: bool) {
	we := w.economy
	if we == nil || !we.built || !we.resident {return}
	o := economy_observer(c)
	best := f64(TRADE_RADIUS_KM)
	for i in we.market.town {
		tw := we.economy.towns[i]
		if d := planet.km_between(tw.lat, tw.lon, f32(o.x), f32(o.y)); d < best {
			best, town, ok = d, i, true
		}
	}
	return
}

// trader_open makes the planet's trader of a player's, standing in market town `local` with
// what they know of the towns in detail, and what the town tells.
@(private = "file")
trader_open :: proc(we: ^World_Economy, rec: ^Trader_Record, local: int) -> planet.Trader {
	t := planet.trader_make(we.market, rec.cash, local)
	t.cargo = rec.cargo
	for j in 0 ..< len(we.market.town) {
		cell := u32(we.economy.towns[we.market.town[j]].cell)
		for g in planet.Good {
			if s, ok := trader_known(rec, cell, g); ok {
				planet.knowledge_see(&t.know, j, g, s.price, f64(s.month))
			}
		}
	}
	planet.trader_arrive(&t, we.economy, we.market, we.news, local)
	return t
}

// trader_close takes a planet trader's cash, cargo and knowledge back into the record.
@(private = "file")
trader_close :: proc(we: ^World_Economy, rec: ^Trader_Record, t: ^planet.Trader) {
	rec.cash, rec.cargo = t.cash, t.cargo
	// Only what they saw where they stand is theirs to keep (what the town told is not).
	cell := u32(we.economy.towns[we.market.town[t.at]].cell)
	for g in planet.Good {
		if r := t.know.at[t.at][g]; r.known {
			seen_put(rec, Seen{cell, r.price, f32(r.month), g})
		}
	}
	planet.trader_destroy(t)
}

// trader_visit: a player standing in a town sees its prices and is told what it knows.
trader_visit :: proc(w: ^World, c: ^Client) {
	town, ok := trader_where(w, c)
	if !ok {return}
	we := w.economy
	t := trader_open(we, &c.trader, we.market.local[town])
	trader_close(we, &c.trader, &t)
}

// trade: the player buys or sells `quantity` units (a person's month of the good) in a town
// (an index in the economy). A buy may be filled in part when the stock or the silver runs out;
// a sell is of the whole quantity or refused. Returns what was done and the units moved.
trade :: proc(
	w: ^World,
	c: ^Client,
	town: int,
	g: planet.Good,
	quantity: f32,
	side: Trade_Side,
) -> (
	Trade_Result,
	f32,
) {
	we := w.economy
	if we == nil || !we.built || !we.resident || town < 0 || town >= len(we.economy.towns) {
		return .No_Economy, 0
	}
	local := we.market.local[town]
	if local < 0 {return .No_Economy, 0}
	if !(quantity > 0) || math.is_inf(quantity) {return .Bad_Quantity, 0}
	tw := we.economy.towns[town]
	o := economy_observer(c)
	if planet.km_between(tw.lat, tw.lon, f32(o.x), f32(o.y)) >= TRADE_RADIUS_KM {return .Away, 0}
	if !tw.market[g] {return .No_Market, 0}
	rec := &c.trader
	if side == .Sell && rec.cargo[g] < quantity {return .No_Cargo, 0}

	t := trader_open(we, rec, local)
	moved: f32
	result := Trade_Result.Done
	switch side {
	case .Buy:
		moved = planet.trader_buy(&t, we.economy, &we.market, g, quantity)
		if moved <= 0 {
			step := f32(planet.IMPACT_STEP) * tw.size
			if we.market.stock[local][g] - step / tw.size <= planet.RESERVE {
				result = .No_Stock
			} else {
				result = .No_Cash
			}
		}
	case .Sell:
		moved = planet.trader_sell(&t, we.economy, &we.market, g, quantity)
	}
	trader_close(we, rec, &t)
	if moved > 0 {we.dirty = true}
	return result, moved
}
