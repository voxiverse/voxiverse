package game

import "core:math"
import "core:slice"

// What the server replicates to clients (M39): the game's state kinds and
// event kinds, as tables the schema (schema.odin) is derived from. A new
// replicated value is a struct, an entry here, and the code that puts it; the
// codec, the dissector's table and the tests of the wire follow from the types.
//
// Records are views of what the server wants the client to see now. Kinds
// with a key (a player, an entity) are rebuilt every tick: what is not put is
// removed. Values travel exactly.

MAX_KNOWN_ENTITIES :: 256 // entities a client is told about at a time

State_Kind :: enum u8 {
	Own_Player,
	Health,
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
}

Event_Kind :: enum u8 {
	Notice,
	Chat_Line,
	Chat_Delete,
	Entity_Hurt,
	Entity_Died,
	Explosion,
}

// Own_Player: the player's authoritative state after the server applied
// inputs up to and including acked. teleports counts the teleports (it wraps):
// when it changes the state did not come from inputs and the client snaps.
Own_Player :: struct {
	acked:     u32 `net:"acked"`,
	state:     Player_State,
	teleports: u8,
	yaw:       f32, // after a teleport: where to look
	pitch:     f32,
}

// Inventory_State: the player's inventory as the server has it, having applied
// their Inventory_Requests up to `acked` (and whatever else changed it).
Inventory_State :: struct {
	acked:     u32 `net:"acked"`,
	inventory: Inventory,
}

// Clock: the world time at server tick `tick`. An anchor, not the time: the
// client advances it with advance_time and the rules.
Clock :: struct {
	time: f64,
	tick: u32,
}

// Player_Record: someone is in the world (the key is their player id).
Player_Record :: struct {
	name: string `net:"max=16"`,
	worn: [WORN_SLOTS]Item, // head to feet; NO_ITEM: nothing
}

Player_Motion :: struct {
	position:   [3]f64, // feet
	yaw, pitch: f32,
	flying:     bool,
	crouched:   bool, // sneaking: drawn lower
}

Entity_Record :: struct {
	kind:  Entity_Kind,
	stack: Stack, // a dropped item's (else empty)
}

Entity_Motion :: struct {
	position:   [3]f64,
	yaw, pitch: f32, // body turn; head up/down
	flags:      Sheep_Flags, // a sheep's looks (genetics.odin)
}

// Block_Record: a block that changed. heard: another player's edit (a sound);
// else the world's own change (flowing water), quietly.
Block_Record :: struct {
	block: Block,
	heard: bool,
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
	.Inventory = {
		name = "inventory",
		value = Inventory_State,
		predicted = .Requests,
		check = check_inventory,
	},
	.Rules = {name = "rules", value = Rules, check = check_rules},
	.Clock = {name = "clock", value = Clock, check = check_clock},
	.Grants = {name = "grants", value = Grants},
	.Variables = {name = "variables", value = Variables},
	.Selection = {name = "selection", value = Selection, check = check_selection},
	.Player = {
		name = "player",
		value = Player_Record,
		key = .Player,
		max_records = MAX_PLAYERS,
		check = check_player_record,
	},
	.Player_Motion = {
		name = "player_motion",
		value = Player_Motion,
		key = .Player,
		lane = .Snapshot,
		priority = 1,
		max_records = MAX_PLAYERS,
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
	.Block = {name = "block", value = Block_Record, key = .Block, write_through = true},
}

@(rodata)
EVENT_KINDS := [Event_Kind]Event_Kind_Info {
	.Notice = {name = "notice", value = Notice},
	.Chat_Line = {name = "chat_line", value = Chat_Line},
	.Chat_Delete = {name = "chat_delete", value = Chat_Delete},
	.Entity_Hurt = {name = "entity_hurt", value = Entity_Hurt},
	.Entity_Died = {name = "entity_died", value = Entity_Died},
	.Explosion = {name = "explosion", value = Explosion, check = check_explosion},
}

// game_schema builds the schema of the game's kinds. The server builds it when
// it starts, a client when it makes a session, tools where they decode: it is
// not a global.
game_schema :: proc(allocator := context.allocator) -> Schema {
	s, err := schema_make(
		slice.enumerated_array(&STATE_KINDS),
		slice.enumerated_array(&EVENT_KINDS),
		allocator,
	)
	assert(err.reason == "", schema_error_text(err))
	return s
}

kind_of_state :: #force_inline proc(k: State_Kind) -> int {return int(k)}

kind_of_event :: #force_inline proc(k: Event_Kind) -> int {return len(State_Kind) + int(k)}

// key_player, key_entity: the Keys of the keyed kinds.
key_player :: #force_inline proc(player: u16) -> Key {return {a = i32(player)}}

key_entity :: #force_inline proc(entity: u32) -> Key {return {a = i32(entity)}}

@(private = "file")
position_ok :: proc(p: [3]f64) -> bool {
	for v in p {if !(abs(v) < WORLD_LIMIT) {return false}}
	return true
}

@(private = "file")
look_ok :: proc(yaw, pitch: f32) -> bool {
	return abs(pitch) <= PITCH_LIMIT && abs(yaw) <= 1e6
}

@(private = "file")
check_own_player :: proc(v: rawptr) -> bool {
	o := (^Own_Player)(v)
	s := o.state
	for x in s.velocity {if !(abs(x) <= MAX_SPEED) {return false}}
	return position_ok(s.position) && s.air_jumps <= 3 && look_ok(o.yaw, o.pitch)
}

@(private = "file")
check_health :: proc(v: rawptr) -> bool {
	h := (^Health)(v)
	return h.max >= 1 && h.max <= 1000 && h.health >= 0 && h.health <= h.max
}

@(private = "file")
check_inventory :: proc(v: rawptr) -> bool {
	return inventory_valid(&(^Inventory_State)(v).inventory)
}

@(private = "file")
check_rules :: proc(v: rawptr) -> bool {
	return rules_valid((^Rules)(v))
}

@(private = "file")
check_clock :: proc(v: rawptr) -> bool {
	return time_valid((^Clock)(v).time)
}

@(private = "file")
check_selection :: proc(v: rawptr) -> bool {
	for corner in (^Selection)(v).corners {
		if p, set := corner.?; set && !in_world(chunk_of(p)) {return false}
	}
	return true
}

@(private = "file")
check_player_record :: proc(v: rawptr) -> bool {
	p := (^Player_Record)(v)
	if !name_valid(p.name) {return false}
	for item in p.worn {if item != NO_ITEM && !item_valid(item) {return false}}
	return true
}

@(private = "file")
check_player_motion :: proc(v: rawptr) -> bool {
	m := (^Player_Motion)(v)
	return position_ok(m.position) && look_ok(m.yaw, m.pitch)
}

@(private = "file")
check_entity_record :: proc(v: rawptr) -> bool {
	st := (^Entity_Record)(v).stack
	return st.count >= 0 && (st.item == NO_ITEM || item_valid(st.item))
}

@(private = "file")
check_entity_motion :: proc(v: rawptr) -> bool {
	m := (^Entity_Motion)(v)
	return position_ok(m.position) && look_ok(m.yaw, m.pitch)
}

@(private = "file")
check_explosion :: proc(v: rawptr) -> bool {
	x := (^Explosion)(v)
	return position_ok(x.position) && x.radius >= 0 && x.radius <= 64
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
