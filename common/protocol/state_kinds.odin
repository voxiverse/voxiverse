package protocol

import "common:game"
import "common:starmap"
import "core:math"
import "core:slice"

// What the server replicates to clients: the engine's state kinds and
// event kinds, as tables the schema (schema.odin) is derived from. A new
// replicated value is a struct, an entry here, and the code that puts it; the
// codec, the dissector's table and the tests of the wire follow from the types.
// A game (games/) declares its own as data (Game_Kinds), and they follow these:
// the engine's kinds keep their ids whatever game a session runs.
//
// Records are views of what the server wants the client to see now. Kinds
// with a key (a player, an entity) are rebuilt every tick: what is not put is
// removed. Values travel exactly.

MAX_TEAMS :: 8 // the sides a world's players and entities may be on (server/core/sides.odin)
MAX_KNOWN_ENTITIES :: 1024 // entities a client is told about at a time (the nearest)
MAX_HUM_SOURCES :: 16 // hum sources a client is told about at a time (the nearest)

State_Kind :: enum u8 {
	Own_Player,
	Health,
	Mode,
	Inventory,
	Rules,
	Clock,
	Grants,
	Variables,
	Selection,
	Player,
	Player_Motion,
	Entity,
	Entity_Motion,
	Block,
	Place,
	Tally,
	Channel,
	Island,
	Machine,
	Belt,
	Logbook,
	Quests,
	Weather,
	Hum,
	Progress,
}

Event_Kind :: enum u8 {
	Notice,
	Chat_Line,
	Chat_Delete,
	Entity_Hurt,
	Entity_Died,
	Explosion,
	Player_Died,
	Damage_Hit,
	Shot,
	Hit_Confirm,
	// A player swung (attack or use): the arm arc anyone near sees (avatars.odin).
	Swung,
}

// Own_Player: the player's authoritative state after the server applied
// inputs up to and including acked. teleports counts the teleports (it wraps):
// when it changes the state did not come from inputs and the client snaps.
Own_Player :: struct {
	acked:     u32 `net:"acked"`,
	state:     game.Player_State,
	teleports: u8,
	yaw:       f32, // after a teleport: where to look
	pitch:     f32,
}

// Mode_Record: the player's own game mode, by id ("base:creative"): what the
// client derives its abilities from (derive_abilities), with the inventory.
Mode_Record :: struct {
	mode: string `net:"max=64"`,
}

// Inventory_State: the player's inventory as the server has it, having applied
// their Inventory_Requests up to `acked` (and whatever else changed it).
Inventory_State :: struct {
	acked:     u32 `net:"acked"`,
	inventory: game.Inventory,
}

// Clock: the world time at server tick `tick`. An anchor, not the time: the
// client advances it with advance_time and the rules.
Clock :: struct {
	time: f64,
	tick: u32,
}

// Weather_Record: what the client needs to work the weather out itself from the clock
// (game.weather_at): the world's weather seed, the kind it was set to (0: none, else
// the game.Weather_Kind + 1) and the climate where the player stands (a game.Climate).
Weather_Record :: struct {
	seed:    u64,
	forced:  u8,
	climate: u8,
}

// Hum_Source: a place a game marked as humming (core.world_hum: ancient machinery, a
// gate), heard as a low hum near it; the key is its block. strength 0..1.
Hum_Source :: struct {
	strength: f32,
}

// Player_Record: someone is in the world (the key is their player id).
Player_Record :: struct {
	name:   string `net:"max=16"`,
	worn:   [game.WORN_SLOTS]game.Item, // head to feet; NO_ITEM: nothing
	held:   game.Item, // the hotbar item in hand (NO_ITEM: none), for the avatar's raised arm
	kills:  u32, // the counters `kills` and `deaths`, for the player list
	deaths: u32,
}

// Island: the simulation island the player is in (id 0: none) and how many chunks
// it holds (F3 shows them; common/island).
Island :: struct {
	id:     u32,
	chunks: u32,
}

// Tally: our own kills and deaths (the others' are in their Player_Record).
Tally :: struct {
	kills:  u32,
	deaths: u32,
}

Player_Motion :: struct {
	position:   [3]f64, // feet
	yaw, pitch: f32,
	flying:     bool,
	crouched:   bool, // sneaking: drawn lower
}

Entity_Record :: struct {
	kind:       game.Kind_Id, // the registry's (a pack hash match makes it the same on both sides)
	stack:      game.Stack, // a dropped item's (else empty)
	health:     u16, // what it has left (a game draws it as a bar: engine.entity_bars)
	max_health: u16, // its most (0: it has no health)
	team:       u8, // its side (0: none; server/core/sides.odin)
	vision:     u8, // blocks it sees for its side in a world with fog (0: none)
}

Entity_Motion :: struct {
	position:   [3]f64,
	yaw, pitch: f32, // body turn; head up/down
	looks:      u16, // bit i: the kind's i-th look (Kind_Info.looks)
}

// Block_Record: a block that changed. heard: another player's edit (a sound);
// else the world's own change (flowing water), quietly.
Block_Record :: struct {
	block: u16, // a block number (any pack's): check_block_record asks the registry
	heard: bool,
}

// Machine_Record: what a game's machine shows (key: its block), as the game's own type
// (server/core/machines.odin): sent when it changes and with its chunk.
Machine_Record :: struct {
	shown: [game.MAX_MACHINE_SHOWN]u8,
}

// Belt_Record: a belt's items (key: its block), when the game or a player put or took one,
// and with its chunk; between them the client moves them as the server does
// (common/game/belt.odin).
Belt_Record :: struct {
	lane: game.Lane,
}

// Channel_Record: a replicated channel's value at a cell (key: the cell and the channel).
Channel_Record :: struct {
	value: u16, // at most the channel's max: the client's apply asks the registry
}

// MAX_BIOMES: the most biomes a generator may have (a Place's biome is below it).
MAX_BIOMES :: 32

NO_BIOME :: 255 // Place.biome: not an Earth world

// Place: where the player is, for the music: the biome under their feet
// (the worldgen.Biome ordinal; NO_BIOME in a world that is not Earth's) and the
// world's warmth and wetness, a hundred times the generator's parameters.
Place :: struct {
	biome:   u8,
	warmth:  i8,
	wetness: i8,
}

// Logbook_State: the player's logbook (game.Logbook: the places found, the creatures met;
// kept with the character) and the world the player is in now (which of its places are
// here).
Logbook_State :: struct {
	here:    starmap.Address,
	logbook: game.Logbook,
}

// Quest_State: the player's quests (game.Quest_Log: how far it is in each quest of the
// registry; kept with the character), from which the Journal's Quests page, the HUD's
// tracker and the compass's quest mark read.
Quest_State :: struct {
	log: game.Quest_Log,
}

// Progress_State: the player's experience and its rank in each skill of the registry
// (kept with the character), from which the HUD's experience bar and level, the Character
// section's skills and the client's prediction of the rules a skill changes read (the
// level and the points are the registry's curve's: game.level_of, game.skill_points).
Progress_State :: struct {
	xp:     u32,
	skills: game.Skill_Ranks,
}

// Player_Died: the player died, of cause (sent before they land at the spawn): where it
// will stand again as its game says it ("": the world's spawn) and whether what it carried
// was dropped where it fell (its mode's and the world's rules).
Player_Died :: struct {
	cause:    string `net:"max=32"`, // a Source_Kind's name
	attacker: string `net:"max=16"`, // the player who did it ("" if none)
	weapon:   string `net:"max=32"`,
	respawn:  string `net:"max=64"`, // the game's words for where (Game.respawn_where; "": the world's spawn)
	dropped:  bool,
}

// Damage_Hit: the player was hurt by something at a place: the direction the
// hit came from, for the screen (an angle in radians, as a yaw: 0 is -z) and
// how much.
Damage_Hit :: struct {
	yaw:    f32,
	amount: f32,
	known:  bool, // the source had a place (a fall has none)
}

// Shot: a weapon was fired (the others' tracer, flash and sound): by whom, the
// weapon's item and where the shot started and ended. The shooter predicts
// its own and is not sent it.
Shot :: struct {
	shooter: u16,
	weapon:  game.Item,
	origin:  [3]f64,
	end:     [3]f64,
}

// Swung: a player swung (attack or use): the arm arc anyone near sees
// (avatars.odin). One-off; who swung.
Swung :: struct {
	player: u16,
}

// Hit_Confirm: the server says the shooter's shot hit someone (the hit marker
// and its sound; never predicted).
Hit_Confirm :: struct {
	kill:     bool,
	headshot: bool,
}

// Entity_Died: an entity the client knows died (sent before its record goes).
Entity_Died :: struct {
	entity: u32,
}

@(rodata)
STATE_KINDS := [State_Kind]State_Kind_Info {
	.Own_Player = {
		name = "own_player",
		value = Own_Player,
		lane = .Snapshot,
		priority = 0,
		predicted = .Inputs,
		check = check_own_player,
	},
	.Health = {name = "health", value = Health, check = check_health},
	.Mode = {name = "mode", value = Mode_Record, check = check_mode},
	.Inventory = {
		name = "inventory",
		value = Inventory_State,
		predicted = .Requests,
		check = check_inventory,
	},
	.Rules = {name = "rules", value = game.Rules, check = check_rules},
	.Clock = {name = "clock", value = Clock, check = check_clock},
	.Grants = {name = "grants", value = Grants},
	.Variables = {name = "variables", value = Variables},
	.Selection = {name = "selection", value = Selection, check = check_selection},
	.Player = {
		name = "player",
		value = Player_Record,
		key = .Player,
		max_records = game.MAX_PLAYERS,
		check = check_player_record,
	},
	.Player_Motion = {
		name = "player_motion",
		value = Player_Motion,
		key = .Player,
		lane = .Snapshot,
		priority = 1,
		max_records = game.MAX_PLAYERS,
		locate = locate_player_motion,
		check = check_player_motion,
	},
	.Entity = {
		name = "entity",
		value = Entity_Record,
		key = .Entity,
		max_records = MAX_KNOWN_ENTITIES,
		check = check_entity_record,
	},
	.Entity_Motion = {
		name = "entity_motion",
		value = Entity_Motion,
		key = .Entity,
		lane = .Snapshot,
		priority = 2,
		max_records = MAX_KNOWN_ENTITIES,
		locate = locate_entity_motion,
		check = check_entity_motion,
	},
	.Block = {
		name = "block",
		value = Block_Record,
		key = .Block,
		write_through = true,
		check = check_block_record,
	},
	.Place = {name = "place", value = Place, check = check_place},
	.Tally = {name = "tally", value = Tally},
	.Channel = {name = "channel", value = Channel_Record, key = .Cell, write_through = true},
	.Island = {name = "island", value = Island},
	.Machine = {name = "machine", value = Machine_Record, key = .Block, write_through = true},
	.Belt = {
		name = "belt",
		value = Belt_Record,
		key = .Block,
		write_through = true,
		check = check_belt_record,
	},
	.Logbook = {name = "logbook", value = Logbook_State, check = check_logbook},
	.Quests = {name = "quests", value = Quest_State, check = check_quests},
	.Weather = {name = "weather", value = Weather_Record, check = check_weather},
	.Hum = {
		name = "hum",
		value = Hum_Source,
		key = .Block,
		max_records = MAX_HUM_SOURCES,
		check = check_hum,
	},
	.Progress = {name = "progress", value = Progress_State, check = check_progress},
}

@(rodata)
EVENT_KINDS := [Event_Kind]Event_Kind_Info {
	.Notice = {name = "notice", value = Notice},
	.Chat_Line = {name = "chat_line", value = Chat_Line},
	.Chat_Delete = {name = "chat_delete", value = Chat_Delete},
	.Entity_Hurt = {name = "entity_hurt", value = Entity_Hurt},
	.Entity_Died = {name = "entity_died", value = Entity_Died},
	.Explosion = {name = "explosion", value = Explosion, check = check_explosion},
	.Player_Died = {name = "player_died", value = Player_Died},
	.Damage_Hit = {name = "damage_hit", value = Damage_Hit},
	.Shot = {name = "shot", value = Shot, check = check_shot},
	.Hit_Confirm = {name = "hit_confirm", value = Hit_Confirm},
	.Swung = {name = "swung", value = Swung},
}

// game_schema builds the schema of the engine's kinds and, with a game (its id and
// its Game_Kinds), the game's after them. The server builds it when it starts, a
// client when it makes a session (again when Welcome names a game), tools where they
// decode: it is not a global. A game's kinds are named for it ("<id>.<name>").
game_schema :: proc(id := "", kinds := Game_Kinds{}, allocator := context.allocator) -> Schema {
	for k in kinds.states {assert(game_kind_named(id, k.name), "a game's kind is named <id>.<name>")}
	for k in kinds.events {assert(game_kind_named(id, k.name), "a game's kind is named <id>.<name>")}
	for k in kinds.requests {assert(game_kind_named(id, k.name), "a game's kind is named <id>.<name>")}
	s, err := schema_make(
		slice.enumerated_array(&STATE_KINDS),
		slice.enumerated_array(&EVENT_KINDS),
		kinds,
		allocator,
	)
	assert(err.reason == "", schema_error_text(err))
	return s
}

@(private = "file")
game_kind_named :: proc(id, name: string) -> bool {
	return id != "" && len(name) > len(id) + 1 && name[:len(id)] == id && name[len(id)] == '.'
}

kind_of_event :: #force_inline proc(k: Event_Kind) -> int {return len(State_Kind) + int(k)}

// key_player, key_entity: the Keys of the keyed kinds.
key_player :: #force_inline proc(player: u16) -> Key {return {a = i32(player)}}

key_entity :: #force_inline proc(entity: u32) -> Key {return {a = i32(entity)}}

@(private = "file")
position_ok :: proc(p: [3]f64) -> bool {
	for v in p {if !(abs(v) < game.WORLD_LIMIT) {return false}}
	return true
}

@(private = "file")
look_ok :: proc(yaw, pitch: f32) -> bool {
	return abs(pitch) <= game.PITCH_LIMIT && abs(yaw) <= 1e6
}

@(private = "file")
check_own_player :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	o := (^Own_Player)(v)
	s := o.state
	for x in s.velocity {if !(abs(x) <= MAX_SPEED) {return false}}
	return(
		position_ok(s.position) &&
		s.air_jumps <= 3 &&
		position_ok(s.anchor) &&
		look_ok(o.yaw, o.pitch) \
	)
}

@(private = "file")
check_health :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	h := (^Health)(v)
	if h.effect != game.NO_ITEM && !game.item_valid(reg, h.effect) {return false}
	return(
		h.max >= 1 &&
		h.max <= 1000 &&
		h.health >= 0 &&
		h.health <= h.max &&
		h.effect_left <= MAX_EFFECT_SECONDS \
	)
}

@(private = "file")
check_mode :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	_, ok := game.mode_find(reg, (^Mode_Record)(v).mode)
	return ok
}

@(private = "file")
check_inventory :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	return game.inventory_valid(reg, &(^Inventory_State)(v).inventory)
}

@(private = "file")
check_logbook :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	return game.logbook_valid(reg, &(^Logbook_State)(v).logbook)
}

@(private = "file")
check_quests :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	return game.quest_log_valid(reg, &(^Quest_State)(v).log)
}

@(private = "file")
check_progress :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	return game.skill_ranks_valid(reg, &(^Progress_State)(v).skills)
}

@(private = "file")
check_shot :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	s := (^Shot)(v)
	return position_ok(s.origin) && position_ok(s.end) && game.item_valid(reg, s.weapon)
}

@(private = "file")
check_rules :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	return game.rules_valid((^game.Rules)(v))
}

@(private = "file")
check_clock :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	return game.time_valid((^Clock)(v).time)
}

@(private = "file")
check_weather :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	w := (^Weather_Record)(v)
	return int(w.forced) <= len(game.Weather_Kind) && int(w.climate) < len(game.Climate)
}

@(private = "file")
check_hum :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	k := (^Hum_Source)(v).strength
	return k >= 0 && k <= 1 // (false for NaN too)
}

// weather_forced: a Weather_Record's forced kind, if it has one.
weather_forced :: proc(w: Weather_Record) -> Maybe(game.Weather_Kind) {
	if w.forced == 0 {return nil}
	return game.Weather_Kind(w.forced - 1)
}

@(private = "file")
check_selection :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	for corner in (^Selection)(v).corners {
		if p, set := corner.?; set && !game.in_world(game.chunk_of(p)) {return false}
	}
	return true
}

@(private = "file")
check_player_record :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	p := (^Player_Record)(v)
	if !game.name_valid(p.name) {return false}
	for item in p.worn {if item != game.NO_ITEM && !game.item_valid(reg, item) {return false}}
	return p.held == game.NO_ITEM || game.item_valid(reg, p.held)
}

@(private = "file")
check_player_motion :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	m := (^Player_Motion)(v)
	return position_ok(m.position) && look_ok(m.yaw, m.pitch)
}

@(private = "file")
check_entity_record :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	r := (^Entity_Record)(v)
	st := r.stack
	return(
		game.kind_info(reg, r.kind) != nil &&
		st.count >= 0 &&
		(st.item == game.NO_ITEM || game.item_valid(reg, st.item)) &&
		int(r.team) <= MAX_TEAMS \
	)
}

@(private = "file")
check_entity_motion :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	m := (^Entity_Motion)(v)
	return position_ok(m.position) && look_ok(m.yaw, m.pitch)
}

@(private = "file")
check_explosion :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	x := (^Explosion)(v)
	return position_ok(x.position) && x.radius >= 0 && x.radius <= 64
}

@(private = "file")
check_block_record :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	return game.block_valid(&reg.blocks, (^Block_Record)(v).block)
}

@(private = "file")
check_belt_record :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	l := &(^Belt_Record)(v).lane
	if l.count > game.LANE_ITEMS {return false}
	last := u32(game.LANE_END)
	for it in l.items[:l.count] {
		if !game.item_valid(reg, it.item) ||
		   it.item == game.NO_ITEM ||
		   u32(it.at) > last {return false}
		last = u32(it.at)
	}
	return true
}

@(private = "file")
check_place :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	p := (^Place)(v)
	return(
		(p.biome < MAX_BIOMES || p.biome == NO_BIOME) &&
		abs(i32(p.warmth)) <= 100 &&
		abs(i32(p.wetness)) <= 100 \
	)
}

@(private = "file")
locate_player_motion :: proc(v: rawptr) -> [3]i32 {
	return block_of_position((^Player_Motion)(v).position)
}

@(private = "file")
locate_entity_motion :: proc(v: rawptr) -> [3]i32 {
	return block_of_position((^Entity_Motion)(v).position)
}

block_of_position :: proc(p: [3]f64) -> [3]i32 {
	return {i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
}
