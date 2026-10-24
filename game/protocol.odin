package game

import "core:math"

import "../base"

// Messages between client and server. Every message travels as bytes, also
// in-process, so singleplayer exercises the same encoding and validation as
// a remote connection. A message is one u8 kind followed by its fields;
// decoders accept only fully valid messages with nothing left over, so
// handlers get validated values only.
//
// Authority: the client sends inputs, never positions; the server moves the
// player and sends back its state, and decides interest: it sends the
// chunks around the player (nearest first) and tells the client which to
// drop.

PROTOCOL_VERSION :: 11
MAX_MESSAGE_SIZE :: 64 * 1024
MAX_NAME_LENGTH :: 16
MAX_PLAYERS :: 32 // a server's seats at most

// Positions and chunk coordinates are kept far from integer overflow: block
// coordinates stay within ±2^28 (chunk coordinates within ±2^24).
WORLD_LIMIT :: 1 << 28
CHUNK_LIMIT :: WORLD_LIMIT >> CHUNK_SHIFT

// Client -> server.

Hello :: struct {
	protocol: u32,
	name:     string, // view into the message; name_valid
}

// Input is one tick of the player's controls, numbered so the server can
// say which it has applied. The client never sends where it is: the server
// moves the player with these (and the client predicts the same).
Input :: struct {
	sequence: u32,
	input:    Player_Input,
}

// Ping asks the server to answer with a Pong carrying the same id (round
// trip time, including the wait for the server's next tick).
Ping :: struct {
	id: u32,
}

// Teleport and Set_Rule need permission (teleport.tp; world.rules,
// world.gen): the server refuses them otherwise (Grants says what a player
// may do).
Teleport :: struct {
	position:   [3]f64,
	yaw, pitch: f32,
}

Set_Rule :: struct {
	name:  string, // a rules.* variable
	value: string,
}

// Command runs a server command (server/admin.odin), each needing its own
// permission.
Command :: struct {
	command: string,
}

// Inventory_Request: something done in the inventory (game/inventory.odin),
// numbered so the client can replay what the server has not answered
// (Inventory says how far it got).
Inventory_Request :: struct {
	sequence: u32,
	action:   Inventory_Action,
}

// Chat: a line the player says (formatting codes kept only where they may:
// the server decides).
Chat :: struct {
	text: string,
}

MAX_CHAT_TEXT :: 256

// Edit asks to put block at pos (Air: break). The client has already
// applied it (predicted); Edit_Result says what became of it. The server
// applies it right after input `after`, where the client was when it made
// the edit, so reach is judged the same however late it arrives.
Edit :: struct {
	id:    u32,
	after: u32,
	pos:   Block_Pos,
	block: Block,
}

// Attack hits an entity (left click on it). Like an Edit it follows input
// `after`, so reach is judged from where the player was.
Attack :: struct {
	entity: u32,
	after:  u32,
}

// Fire: the creative rocket launcher, aimed yaw/pitch, after input `after`.
Fire :: struct {
	after:      u32,
	yaw, pitch: f32,
}

Client_Message :: union {
	Hello,
	Input,
	Ping,
	Teleport,
	Set_Rule,
	Edit,
	Command,
	Attack,
	Fire,
	Chat,
	Inventory_Request,
}

// Server -> client.

Welcome :: struct {
	protocol:    u32,
	tick_rate:   u32,
	player:      u16, // this client's player id
	spawn:       [3]f64,
	view_radius: u32, // the interest area, in chunks (see interest.odin)
	view_height: u32,
	rules:       Rules,
}

// Reject ends the connection.
Reject :: struct {
	reason: string,
}

// Chunk_Message carries a chunk's blocks: is_uniform with uniform, or the
// array the decoder was given.
Chunk_Message :: struct {
	pos:        Chunk_Pos,
	uniform:    Block,
	is_uniform: bool,
}

Unload_Chunk :: struct {
	pos: Chunk_Pos,
}

Pong :: struct {
	id: u32,
}

// Player_Update is the player's authoritative state after the server
// applied inputs up to and including acked (every tick). teleported: the
// state did not come from inputs; the client should not smooth towards it.
Player_Update :: struct {
	acked:      u32,
	state:      Player_State,
	teleported: bool,
	yaw, pitch: f32, // after a teleport: where to look
}

Rules_Changed :: struct {
	rules: Rules,
}

// Time: the world time (time.odin), after Welcome, every second and when
// it is set. Clients advance it themselves in between.
Time :: struct {
	time: f64,
}

// Player_Joined: someone is in the world (sent for everyone already there
// after Welcome, and for each newcomer).
Player_Joined :: struct {
	player: u16,
	name:   string, // view into the message
}

Player_Left :: struct {
	player: u16,
}

// Players: where the other players near you are, every tick (the newest
// wins; tick orders them for interpolation).
Players :: struct {
	tick:    u32,
	count:   int,
	entries: [MAX_PLAYERS]Player_Entry,
}

Player_Entry :: struct {
	player:     u16,
	position:   [3]f64, // feet
	yaw, pitch: f32,
	flying:     bool,
}

// Notice: something the server wants the player to read (chat and the
// console), formatted (game/format.odin).
Notice :: struct {
	text: string, // view into the message
}

MAX_NOTICE_TEXT :: 1024

// Chat_Line: a line of chat, as everyone sees it (the sender's tag, name
// and words, formatted), numbered so a moderator can take it back.
Chat_Line :: struct {
	id:     u32,
	sender: u16, // the player who said it; NO_PLAYER: the server
	text:   string, // view into the message
}

NO_PLAYER :: 0xffff
MAX_CHAT_LINE :: 1024

// Chat_Delete: a moderator took line id back.
Chat_Delete :: struct {
	id: u32,
}

// Entity_Spawn: an entity is near you now (it came into your area, or into
// being). Entities say where they are every tick after (Entities).
Entity_Spawn :: struct {
	entity:   u32,
	kind:     Entity_Kind,
	position: [3]f64,
	yaw:      f32,
	stack:    Stack, // a dropped item's (else empty)
}

// Inventory_Update: the player's inventory as the server has it, having
// applied their Inventory_Requests up to `acked` (and whatever else changed
// it: placing, picking up, commands). Sent when it changes.
Inventory_Update :: struct {
	acked:     u32,
	inventory: Inventory,
}

// Entity_Despawn: forget it (out of your area, gone, or died: show it).
Entity_Despawn :: struct {
	entity: u32,
	died:   bool,
}

// Entities: where the entities near you are, every tick (the newest wins),
// a batch of at most ENTITIES_PER_MESSAGE (more go in more messages).
Entities :: struct {
	tick:    u32,
	count:   int,
	entries: [ENTITIES_PER_MESSAGE]Entity_Entry,
}

ENTITIES_PER_MESSAGE :: 28 // fits one packet

Entity_Entry :: struct {
	entity:     u32,
	position:   [3]f64,
	yaw, pitch: f32, // body turn; head up/down
}

// Entity_Hurt: it was hit (flash, sound).
Entity_Hurt :: struct {
	entity: u32,
}

// Bulk_Begin: the next `count` Chunk messages are one bulk edit's (show
// them together, so no face goes missing for a frame in between).
Bulk_Begin :: struct {
	count: u16,
}

// Explosion: something blew up here (flash, debris, sound); the blocks it
// took come as a bulk edit after.
Explosion :: struct {
	position: [3]f64,
	radius:   f32,
}

// Grants: what this player may do (game/permissions.odin), as
// grants_text's lines, and the server commands they may use (names, space
// apart: for Tab): when they join and whenever it changes.
Grants :: struct {
	text:     string, // view into the message
	commands: string, // view into the message
}

MAX_GRANTS_TEXT :: 16384

// Blocks_Changed: blocks the world changed in a chunk this tick (flowing
// water; players' edits come as Block_Changed, heard), by local index.
Blocks_Changed :: struct {
	chunk:   Chunk_Pos,
	count:   int,
	entries: [MAX_BLOCKS_CHANGED]Changed_Entry,
}

Changed_Entry :: struct {
	index: u16, // game.local_index in the chunk
	block: Block,
}

MAX_BLOCKS_CHANGED :: 64 // in one message (a chunk with more is sent whole)

// Variables: some of the server's variables (worldgen.*), as `name = value`
// lines: sent when a player joins and when they change. As text, so this
// package needs no knowledge of what they are.
Variables :: struct {
	text: string, // view into the message
}

// Column: the y of the highest solid block in each block column of a chunk
// column (x fastest). Sky light needs it: the client cannot see above what
// it has loaded. Sent before a column's first chunk, and again when an edit
// changes it.
Column :: struct {
	pos:     [2]i32, // chunk x, z
	heights: [CHUNK_SIZE * CHUNK_SIZE]i32,
}

// Edit_Result answers an Edit: accepted or not, and the block now at pos
// either way (the client sets it, undoing a rejected prediction).
Edit_Result :: struct {
	id:       u32,
	accepted: bool,
	pos:      Block_Pos,
	block:    Block,
}

// Block_Changed: a block changed for some other reason (another player).
Block_Changed :: struct {
	pos:   Block_Pos,
	block: Block,
}

Server_Message :: union {
	Welcome,
	Reject,
	Chunk_Message,
	Unload_Chunk,
	Pong,
	Player_Update,
	Rules_Changed,
	Edit_Result,
	Block_Changed,
	Column,
	Time,
	Player_Joined,
	Player_Left,
	Players,
	Notice,
	Entity_Spawn,
	Entity_Despawn,
	Entities,
	Entity_Hurt,
	Bulk_Begin,
	Explosion,
	Variables,
	Blocks_Changed,
	Grants,
	Chat_Line,
	Chat_Delete,
	Inventory_Update,
}

MAX_VIEW_RADIUS :: 32
MAX_VARIABLES_TEXT :: 4096
MAX_REASON_LENGTH :: 256
MAX_RULE_TEXT :: 64
MAX_ADMIN_TEXT :: 256
MAX_SPEED :: 1000 // blocks/s: anything faster in a message is invalid

@(private = "file")
Client_Kind :: enum u8 {
	Hello = 1,
	Input,
	Ping,
	Teleport,
	Set_Rule,
	Edit,
	Command,
	Attack,
	Fire,
	Chat,
	Inventory_Request,
}

@(private = "file")
Server_Kind :: enum u8 {
	Welcome = 1,
	Reject,
	Chunk,
	Unload_Chunk,
	Pong,
	Player_Update,
	Rules_Changed,
	Edit_Result,
	Block_Changed,
	Column,
	Time,
	Player_Joined,
	Player_Left,
	Players,
	Notice,
	Entity_Spawn,
	Entity_Despawn,
	Entities,
	Entity_Hurt,
	Bulk_Begin,
	Explosion,
	Variables,
	Blocks_Changed,
	Grants,
	Chat_Line,
	Chat_Delete,
	Inventory_Update,
}

// message_reliable: whether messages of a kind (from sender) must arrive,
// in order; the rest are states sent every tick or so, where only the
// newest matters (a remote connection may drop them).
message_reliable :: proc(sender: Side, kind: u8) -> bool {
	if sender == .Client {
		return kind != u8(Client_Kind.Ping)
	}
	switch kind {
	case u8(Server_Kind.Player_Update),
	     u8(Server_Kind.Players),
	     u8(Server_Kind.Pong),
	     u8(Server_Kind.Time),
	     u8(Server_Kind.Entities):
		return false
	}
	return true
}

// name_valid: a player name is 1..MAX_NAME_LENGTH letters, digits, '_' or '-'.
name_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > MAX_NAME_LENGTH {return false}
	for c in transmute([]u8)name {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		case:
			return false
		}
	}
	return true
}

// message_kind_name names a message kind (its first byte) sent by sender,
// for tools and statistics; "" if there is no such kind.
message_kind_name :: proc(sender: Side, kind: u8) -> string {
	if sender == .Client {
		switch kind {
		case u8(Client_Kind.Hello):
			return "hello"
		case u8(Client_Kind.Input):
			return "input"
		case u8(Client_Kind.Ping):
			return "ping"
		case u8(Client_Kind.Teleport):
			return "teleport"
		case u8(Client_Kind.Set_Rule):
			return "set_rule"
		case u8(Client_Kind.Edit):
			return "edit"
		case u8(Client_Kind.Command):
			return "command"
		case u8(Client_Kind.Attack):
			return "attack"
		case u8(Client_Kind.Fire):
			return "fire"
		case u8(Client_Kind.Chat):
			return "chat"
		case u8(Client_Kind.Inventory_Request):
			return "inventory_request"
		}
	} else {
		switch kind {
		case u8(Server_Kind.Welcome):
			return "welcome"
		case u8(Server_Kind.Reject):
			return "reject"
		case u8(Server_Kind.Chunk):
			return "chunk"
		case u8(Server_Kind.Unload_Chunk):
			return "unload"
		case u8(Server_Kind.Pong):
			return "pong"
		case u8(Server_Kind.Player_Update):
			return "player"
		case u8(Server_Kind.Rules_Changed):
			return "rules"
		case u8(Server_Kind.Edit_Result):
			return "edit_result"
		case u8(Server_Kind.Block_Changed):
			return "block"
		case u8(Server_Kind.Column):
			return "column"
		case u8(Server_Kind.Time):
			return "time"
		case u8(Server_Kind.Player_Joined):
			return "joined"
		case u8(Server_Kind.Player_Left):
			return "left"
		case u8(Server_Kind.Players):
			return "players"
		case u8(Server_Kind.Notice):
			return "notice"
		case u8(Server_Kind.Entity_Spawn):
			return "spawn"
		case u8(Server_Kind.Entity_Despawn):
			return "despawn"
		case u8(Server_Kind.Entities):
			return "entities"
		case u8(Server_Kind.Entity_Hurt):
			return "hurt"
		case u8(Server_Kind.Bulk_Begin):
			return "bulk"
		case u8(Server_Kind.Explosion):
			return "explosion"
		case u8(Server_Kind.Variables):
			return "variables"
		case u8(Server_Kind.Blocks_Changed):
			return "blocks"
		case u8(Server_Kind.Grants):
			return "grants"
		case u8(Server_Kind.Chat_Line):
			return "chat_line"
		case u8(Server_Kind.Chat_Delete):
			return "chat_delete"
		case u8(Server_Kind.Inventory_Update):
			return "inventory"
		}
	}
	return ""
}

// encode_client appends m to w.buf.
encode_client :: proc(w: ^Writer, m: Client_Message) {
	switch v in m {
	case Hello:
		write_u8(w, u8(Client_Kind.Hello))
		write_u32(w, v.protocol)
		write_string(w, v.name)
	case Input:
		write_u8(w, u8(Client_Kind.Input))
		write_u32(w, v.sequence)
		write_player_input(w, v.input)
	case Ping:
		write_u8(w, u8(Client_Kind.Ping))
		write_u32(w, v.id)
	case Teleport:
		write_u8(w, u8(Client_Kind.Teleport))
		write_position(w, v.position)
		write_f32(w, v.yaw)
		write_f32(w, v.pitch)
	case Set_Rule:
		write_u8(w, u8(Client_Kind.Set_Rule))
		write_string(w, v.name)
		write_string(w, v.value)
	case Edit:
		write_u8(w, u8(Client_Kind.Edit))
		write_u32(w, v.id)
		write_u32(w, v.after)
		write_block_pos(w, v.pos)
		write_u16(w, u16(v.block))
	case Command:
		write_u8(w, u8(Client_Kind.Command))
		write_string(w, v.command)
	case Chat:
		write_u8(w, u8(Client_Kind.Chat))
		write_string(w, v.text)
	case Inventory_Request:
		write_u8(w, u8(Client_Kind.Inventory_Request))
		write_u32(w, v.sequence)
		write_u8(w, u8(v.action.kind))
		write_u8(w, u8(i8(v.action.slot)))
		write_u16(w, u16(v.action.arg))
	case Attack:
		write_u8(w, u8(Client_Kind.Attack))
		write_u32(w, v.entity)
		write_u32(w, v.after)
	case Fire:
		write_u8(w, u8(Client_Kind.Fire))
		write_u32(w, v.after)
		write_f32(w, v.yaw)
		write_f32(w, v.pitch)
	}
	assert(len(w.buf) <= MAX_MESSAGE_SIZE)
}

// encode_server appends m to w.buf; blocks are a Chunk_Message's blocks.
encode_server :: proc(w: ^Writer, m: Server_Message, blocks: ^Chunk_Blocks = nil) {
	switch v in m {
	case Welcome:
		write_u8(w, u8(Server_Kind.Welcome))
		write_u32(w, v.protocol)
		write_u32(w, v.tick_rate)
		write_u16(w, v.player)
		write_position(w, v.spawn)
		write_u32(w, v.view_radius)
		write_u32(w, v.view_height)
		rules := v.rules
		write_vars(w, rules_table(), &rules)
	case Reject:
		write_u8(w, u8(Server_Kind.Reject))
		write_string(w, v.reason)
	case Chunk_Message:
		write_u8(w, u8(Server_Kind.Chunk))
		write_chunk_pos(w, v.pos)
		write_chunk_blocks(w, blocks)
	case Unload_Chunk:
		write_u8(w, u8(Server_Kind.Unload_Chunk))
		write_chunk_pos(w, v.pos)
	case Pong:
		write_u8(w, u8(Server_Kind.Pong))
		write_u32(w, v.id)
	case Player_Update:
		write_u8(w, u8(Server_Kind.Player_Update))
		write_u32(w, v.acked)
		write_player_state(w, v.state)
		write_u8(w, 1 if v.teleported else 0)
		write_f32(w, v.yaw)
		write_f32(w, v.pitch)
	case Rules_Changed:
		write_u8(w, u8(Server_Kind.Rules_Changed))
		rules := v.rules
		write_vars(w, rules_table(), &rules)
	case Edit_Result:
		write_u8(w, u8(Server_Kind.Edit_Result))
		write_u32(w, v.id)
		write_u8(w, 1 if v.accepted else 0)
		write_block_pos(w, v.pos)
		write_u16(w, u16(v.block))
	case Block_Changed:
		write_u8(w, u8(Server_Kind.Block_Changed))
		write_block_pos(w, v.pos)
		write_u16(w, u16(v.block))
	case Column:
		write_u8(w, u8(Server_Kind.Column))
		write_i32(w, v.pos.x)
		write_i32(w, v.pos.y)
		previous: i32
		for h in v.heights {
			write_svarint(w, h - previous)
			previous = h
		}
	case Time:
		write_u8(w, u8(Server_Kind.Time))
		write_f64(w, v.time)
	case Player_Joined:
		write_u8(w, u8(Server_Kind.Player_Joined))
		write_u16(w, v.player)
		write_string(w, v.name)
	case Player_Left:
		write_u8(w, u8(Server_Kind.Player_Left))
		write_u16(w, v.player)
	case Players:
		write_u8(w, u8(Server_Kind.Players))
		write_u32(w, v.tick)
		write_u8(w, u8(v.count))
		for i in 0 ..< v.count {
			e := v.entries[i]
			write_u16(w, e.player)
			write_position(w, e.position)
			write_f32(w, e.yaw)
			write_f32(w, e.pitch)
			write_u8(w, 1 if e.flying else 0)
		}
	case Notice:
		write_u8(w, u8(Server_Kind.Notice))
		write_string(w, v.text)
	case Entity_Spawn:
		write_u8(w, u8(Server_Kind.Entity_Spawn))
		write_u32(w, v.entity)
		write_u8(w, u8(v.kind))
		write_position(w, v.position)
		write_f32(w, v.yaw)
		write_stack(w, v.stack)
	case Entity_Despawn:
		write_u8(w, u8(Server_Kind.Entity_Despawn))
		write_u32(w, v.entity)
		write_u8(w, 1 if v.died else 0)
	case Entities:
		write_u8(w, u8(Server_Kind.Entities))
		write_u32(w, v.tick)
		write_u8(w, u8(v.count))
		for i in 0 ..< v.count {
			e := v.entries[i]
			write_u32(w, e.entity)
			write_position(w, e.position)
			write_f32(w, e.yaw)
			write_f32(w, e.pitch)
		}
	case Entity_Hurt:
		write_u8(w, u8(Server_Kind.Entity_Hurt))
		write_u32(w, v.entity)
	case Bulk_Begin:
		write_u8(w, u8(Server_Kind.Bulk_Begin))
		write_u16(w, v.count)
	case Explosion:
		write_u8(w, u8(Server_Kind.Explosion))
		write_position(w, v.position)
		write_f32(w, v.radius)
	case Variables:
		write_u8(w, u8(Server_Kind.Variables))
		write_string(w, v.text)
	case Grants:
		write_u8(w, u8(Server_Kind.Grants))
		write_string(w, v.text)
		write_string(w, v.commands)
	case Chat_Line:
		write_u8(w, u8(Server_Kind.Chat_Line))
		write_u32(w, v.id)
		write_u16(w, v.sender)
		write_string(w, v.text)
	case Chat_Delete:
		write_u8(w, u8(Server_Kind.Chat_Delete))
		write_u32(w, v.id)
	case Inventory_Update:
		write_u8(w, u8(Server_Kind.Inventory_Update))
		write_u32(w, v.acked)
		inv := v.inventory
		for st in inv.slots {write_stack(w, st)}
		write_stack(w, inv.cursor)
		write_u8(w, u8(inv.selected))
	case Blocks_Changed:
		write_u8(w, u8(Server_Kind.Blocks_Changed))
		write_chunk_pos(w, v.chunk)
		write_u8(w, u8(v.count))
		for i in 0 ..< v.count {
			e := v.entries[i]
			write_u16(w, e.index)
			write_u16(w, u16(e.block))
		}
	}
	assert(len(w.buf) <= MAX_MESSAGE_SIZE)
}

// decode_client returns the message in data, or ok = false if it is not a
// valid one. Strings in the result point into data.
decode_client :: proc(data: []u8) -> (m: Client_Message, ok: bool) {
	if len(data) > MAX_MESSAGE_SIZE {return}
	r := reader_make(data)
	switch read_u8(&r) {
	case u8(Client_Kind.Hello):
		m = Hello {
			protocol = read_u32(&r),
			name     = read_string(&r, MAX_NAME_LENGTH),
		}
	case u8(Client_Kind.Input):
		m = Input {
			sequence = read_u32(&r),
			input    = read_player_input(&r),
		}
	case u8(Client_Kind.Ping):
		m = Ping {
			id = read_u32(&r),
		}
	case u8(Client_Kind.Teleport):
		t := Teleport {
			position = read_position(&r),
			yaw      = read_f32(&r),
			pitch    = read_f32(&r),
		}
		if abs(t.pitch) > PITCH_LIMIT {reader_fail(&r)}
		m = t
	case u8(Client_Kind.Set_Rule):
		m = Set_Rule {
			name  = read_string(&r, MAX_RULE_TEXT),
			value = read_string(&r, MAX_RULE_TEXT),
		}
	case u8(Client_Kind.Edit):
		m = Edit {
			id    = read_u32(&r),
			after = read_u32(&r),
			pos   = read_block_pos(&r),
			block = read_block(&r),
		}
	case u8(Client_Kind.Command):
		m = Command {
			command = read_string(&r, MAX_ADMIN_TEXT),
		}
	case u8(Client_Kind.Chat):
		m = Chat {
			text = read_string(&r, MAX_CHAT_TEXT),
		}
	case u8(Client_Kind.Inventory_Request):
		q := Inventory_Request {
			sequence = read_u32(&r),
		}
		kind := read_u8(&r)
		if int(kind) >= len(Inventory_Action_Kind) {reader_fail(&r)}
		q.action.kind =
			Inventory_Action_Kind(kind) if int(kind) < len(Inventory_Action_Kind) else {}
		q.action.slot = int(i8(read_u8(&r)))
		q.action.arg = int(read_u16(&r))
		if q.action.slot < CURSOR_SLOT || q.action.slot >= INVENTORY_SLOTS {reader_fail(&r)}
		m = q
	case u8(Client_Kind.Attack):
		m = Attack {
			entity = read_u32(&r),
			after  = read_u32(&r),
		}
	case u8(Client_Kind.Fire):
		f := Fire {
			after = read_u32(&r),
			yaw   = read_f32(&r),
			pitch = read_f32(&r),
		}
		if !(abs(f.yaw) <= 1e6) || !(abs(f.pitch) <= PITCH_LIMIT) {reader_fail(&r)}
		m = f
	case:
		return
	}
	return m, reader_finish(&r)
}

// decode_server is decode_client's counterpart; a chunk's blocks go into
// blocks (left unchanged for a uniform chunk).
decode_server :: proc(data: []u8, blocks: ^Block_Array) -> (m: Server_Message, ok: bool) {
	if len(data) > MAX_MESSAGE_SIZE {return}
	r := reader_make(data)
	switch read_u8(&r) {
	case u8(Server_Kind.Welcome):
		w := Welcome {
			protocol  = read_u32(&r),
			tick_rate = read_u32(&r),
			player    = read_u16(&r),
		}
		w.spawn = read_position(&r)
		w.view_radius = read_u32(&r)
		w.view_height = read_u32(&r)
		read_vars(&r, rules_table(), &w.rules)
		if w.view_radius == 0 ||
		   w.view_radius > MAX_VIEW_RADIUS ||
		   w.view_height == 0 ||
		   w.view_height > MAX_VIEW_HEIGHT {
			reader_fail(&r)
		}
		m = w
	case u8(Server_Kind.Reject):
		m = Reject {
			reason = read_string(&r, MAX_REASON_LENGTH),
		}
	case u8(Server_Kind.Chunk):
		c := Chunk_Message {
			pos = read_chunk_pos(&r),
		}
		c.uniform, c.is_uniform = read_chunk_blocks(&r, blocks)
		m = c
	case u8(Server_Kind.Unload_Chunk):
		m = Unload_Chunk {
			pos = read_chunk_pos(&r),
		}
	case u8(Server_Kind.Pong):
		m = Pong {
			id = read_u32(&r),
		}
	case u8(Server_Kind.Player_Update):
		u := Player_Update {
			acked = read_u32(&r),
			state = read_player_state(&r),
		}
		flag := read_u8(&r)
		if flag > 1 {reader_fail(&r)}
		u.teleported = flag == 1
		u.yaw, u.pitch = read_f32(&r), read_f32(&r)
		if abs(u.pitch) > PITCH_LIMIT {reader_fail(&r)}
		m = u
	case u8(Server_Kind.Rules_Changed):
		c: Rules_Changed
		read_vars(&r, rules_table(), &c.rules)
		m = c
	case u8(Server_Kind.Edit_Result):
		e := Edit_Result {
			id = read_u32(&r),
		}
		flag := read_u8(&r)
		if flag > 1 {reader_fail(&r)}
		e.accepted = flag == 1
		e.pos = read_block_pos(&r)
		e.block = read_block(&r)
		m = e
	case u8(Server_Kind.Block_Changed):
		m = Block_Changed {
			pos   = read_block_pos(&r),
			block = read_block(&r),
		}
	case u8(Server_Kind.Column):
		c: Column
		c.pos = {read_i32(&r), read_i32(&r)}
		if !in_world({c.pos.x, 0, c.pos.y}) {reader_fail(&r)}
		previous: i32
		for &h in c.heights {
			h = previous + read_svarint(&r)
			previous = h
			if h < WORLD_MIN_Y || h >= WORLD_MAX_Y {reader_fail(&r)}
		}
		m = c
	case u8(Server_Kind.Time):
		t := Time {
			time = read_f64(&r),
		}
		if !time_valid(t.time) {reader_fail(&r)}
		m = t
	case u8(Server_Kind.Player_Joined):
		j := Player_Joined {
			player = read_u16(&r),
			name   = read_string(&r, MAX_NAME_LENGTH),
		}
		if r.ok && !name_valid(j.name) {reader_fail(&r)}
		m = j
	case u8(Server_Kind.Player_Left):
		m = Player_Left {
			player = read_u16(&r),
		}
	case u8(Server_Kind.Players):
		p := Players {
			tick  = read_u32(&r),
			count = int(read_u8(&r)),
		}
		if p.count > MAX_PLAYERS {reader_fail(&r)}
		for &e in p.entries[:min(p.count, MAX_PLAYERS)] {
			e.player = read_u16(&r)
			e.position = read_position(&r)
			e.yaw, e.pitch = read_f32(&r), read_f32(&r)
			flags := read_u8(&r)
			if flags > 1 || abs(e.pitch) > PITCH_LIMIT || !(abs(e.yaw) <= 1e6) {reader_fail(&r)}
			e.flying = flags == 1
		}
		m = p
	case u8(Server_Kind.Notice):
		m = Notice {
			text = read_string(&r, MAX_NOTICE_TEXT),
		}
	case u8(Server_Kind.Entity_Spawn):
		e := Entity_Spawn {
			entity = read_u32(&r),
		}
		kind := read_u8(&r)
		if !entity_kind_valid(kind) {reader_fail(&r)}
		e.kind = Entity_Kind(kind) if entity_kind_valid(kind) else {}
		e.position = read_position(&r)
		e.yaw = read_f32(&r)
		e.stack = read_stack(&r)
		if !(abs(e.yaw) <= 1e6) {reader_fail(&r)}
		m = e
	case u8(Server_Kind.Entity_Despawn):
		d := Entity_Despawn {
			entity = read_u32(&r),
		}
		flag := read_u8(&r)
		if flag > 1 {reader_fail(&r)}
		d.died = flag == 1
		m = d
	case u8(Server_Kind.Entities):
		e := Entities {
			tick  = read_u32(&r),
			count = int(read_u8(&r)),
		}
		if e.count > ENTITIES_PER_MESSAGE {reader_fail(&r)}
		for &x in e.entries[:min(e.count, ENTITIES_PER_MESSAGE)] {
			x.entity = read_u32(&r)
			x.position = read_position(&r)
			x.yaw, x.pitch = read_f32(&r), read_f32(&r)
			if !(abs(x.yaw) <= 1e6) || abs(x.pitch) > PITCH_LIMIT {reader_fail(&r)}
		}
		m = e
	case u8(Server_Kind.Entity_Hurt):
		m = Entity_Hurt {
			entity = read_u32(&r),
		}
	case u8(Server_Kind.Bulk_Begin):
		m = Bulk_Begin {
			count = read_u16(&r),
		}
	case u8(Server_Kind.Explosion):
		x := Explosion {
			position = read_position(&r),
			radius   = read_f32(&r),
		}
		if !(x.radius >= 0 && x.radius <= 64) {reader_fail(&r)}
		m = x
	case u8(Server_Kind.Variables):
		m = Variables {
			text = read_string(&r, MAX_VARIABLES_TEXT),
		}
	case u8(Server_Kind.Grants):
		m = Grants {
			text     = read_string(&r, MAX_GRANTS_TEXT),
			commands = read_string(&r, MAX_GRANTS_TEXT),
		}
	case u8(Server_Kind.Chat_Line):
		m = Chat_Line {
			id     = read_u32(&r),
			sender = read_u16(&r),
			text   = read_string(&r, MAX_CHAT_LINE),
		}
	case u8(Server_Kind.Chat_Delete):
		m = Chat_Delete {
			id = read_u32(&r),
		}
	case u8(Server_Kind.Inventory_Update):
		u := Inventory_Update {
			acked = read_u32(&r),
		}
		for &st in u.inventory.slots {st = read_stack(&r)}
		u.inventory.cursor = read_stack(&r)
		u.inventory.selected = int(read_u8(&r))
		if !inventory_valid(&u.inventory) {reader_fail(&r)}
		m = u
	case u8(Server_Kind.Blocks_Changed):
		c := Blocks_Changed {
			chunk = read_chunk_pos(&r),
			count = int(read_u8(&r)),
		}
		if c.count == 0 || c.count > MAX_BLOCKS_CHANGED {reader_fail(&r)}
		for &e in c.entries[:min(c.count, MAX_BLOCKS_CHANGED)] {
			e.index = read_u16(&r)
			id := read_u16(&r)
			if int(e.index) >= CHUNK_VOLUME || !block_valid(id) {reader_fail(&r)}
			e.block = Block(id) if block_valid(id) else .Air
		}
		m = c
	case:
		return
	}
	return m, reader_finish(&r)
}

// Player inputs on the wire: movement quantized to 1/127 (the client
// predicts with the quantized value too: quantize_input), look angles exact.
@(private = "file")
write_player_input :: proc(w: ^Writer, in_: Player_Input) {
	q := quantize_input(in_)
	write_u8(w, u8(i8(math.round(q.move.x * 127))))
	write_u8(w, u8(i8(math.round(q.move.y * 127))))
	write_f32(w, q.yaw)
	write_f32(w, q.pitch)
	write_u8(w, transmute(u8)q.buttons)
}

@(private = "file")
read_player_input :: proc(r: ^Reader) -> (in_: Player_Input) {
	mx, my := i8(read_u8(r)), i8(read_u8(r))
	if mx == -128 || my == -128 {reader_fail(r)}
	in_.move = {f32(mx) / 127, f32(my) / 127}
	in_.yaw = read_f32(r)
	in_.pitch = read_f32(r)
	buttons := read_u8(r)
	if buttons >= 1 << len(Button) ||
	   abs(in_.pitch) > PITCH_LIMIT ||
	   abs(in_.yaw) > 1e6 {reader_fail(r)}
	in_.buttons = transmute(bit_set[Button;u8])buttons
	return
}

// quantize_input is the input as the server will see it after the trip.
quantize_input :: proc(in_: Player_Input) -> Player_Input {
	q := in_
	for &v in q.move {v = math.round(clamp(v, -1, 1) * 127) / 127}
	return q
}

@(private = "file")
write_player_state :: proc(w: ^Writer, s: Player_State) {
	write_position(w, s.position)
	for v in s.velocity {write_f32(w, v)}
	write_u8(w, (1 if s.on_ground else 0) | (2 if s.flying else 0))
}

@(private = "file")
read_player_state :: proc(r: ^Reader) -> (s: Player_State) {
	s.position = read_position(r)
	for &v in s.velocity {
		v = read_f32(r)
		if abs(v) > MAX_SPEED {reader_fail(r)}
	}
	flags := read_u8(r)
	if flags > 3 {reader_fail(r)}
	s.on_ground, s.flying = flags & 1 != 0, flags & 2 != 0
	return
}

// write_vars / read_vars carry a variable table's struct field by field, in
// table order; numbers outside their range fail the reader.
@(private)
write_vars :: proc(w: ^Writer, t: base.Var_Table, data: rawptr) {
	for &v in t.vars {
		kind, _ := base.var_kind(t, &v)
		value := base.var_get_f64(t, data, &v)
		switch kind {
		case .Bool:
			write_u8(w, 1 if value != 0 else 0)
		case .Int:
			write_i32(w, i32(value))
		case .F32:
			write_f32(w, f32(value))
		case .Text:
			panic("game rules are numbers")
		}
	}
}

@(private)
read_vars :: proc(r: ^Reader, t: base.Var_Table, data: rawptr) {
	for &v in t.vars {
		kind, _ := base.var_kind(t, &v)
		value: f64
		switch kind {
		case .Bool:
			b := read_u8(r)
			if b > 1 {reader_fail(r)}
			value = f64(b)
		case .Int:
			value = f64(read_i32(r))
		case .F32:
			value = f64(read_f32(r))
		case .Text:
			panic("game rules are numbers")
		}
		if !r.ok {return}
		if kind != .Bool && (value < v.min || value > v.max) {
			reader_fail(r)
			return
		}
		base.var_set_f64(t, data, &v, value)
	}
}

@(private = "file")
write_position :: proc(w: ^Writer, p: [3]f64) {
	for v in p {write_f64(w, v)}
}

@(private = "file")
read_position :: proc(r: ^Reader) -> (p: [3]f64) {
	for &v in p {
		v = read_f64(r)
		if abs(v) >= WORLD_LIMIT {reader_fail(r)}
	}
	return
}

@(private = "file")
write_chunk_pos :: proc(w: ^Writer, c: Chunk_Pos) {
	for v in c {write_i32(w, v)}
}

@(private = "file")
write_block_pos :: proc(w: ^Writer, p: Block_Pos) {
	for v in p {write_i32(w, v)}
}

// read_block_pos accepts blocks inside the world only.
@(private = "file")
read_block_pos :: proc(r: ^Reader) -> (p: Block_Pos) {
	for &v in p {v = read_i32(r)}
	if !in_world(chunk_of(p)) {reader_fail(r)}
	return
}

@(private = "file")
read_block :: proc(r: ^Reader) -> Block {
	id := read_u16(r)
	if !block_valid(id) {
		reader_fail(r)
		return .Air
	}
	return Block(id)
}

@(private = "file")
read_chunk_pos :: proc(r: ^Reader) -> (c: Chunk_Pos) {
	for &v in c {v = read_i32(r)}
	if !in_world(c) {reader_fail(r)}
	return
}

// Server_Info: what a server tells LAN discovery about itself (netcode
// carries it as bytes).
Server_Info :: struct {
	protocol:    u32,
	name:        string, // view into the bytes when decoded
	players:     int,
	max_players: int,
	password:    bool,
}

encode_server_info :: proc(w: ^Writer, i: Server_Info) {
	write_u32(w, i.protocol)
	write_string(w, i.name)
	write_u8(w, u8(i.players))
	write_u8(w, u8(i.max_players))
	write_u8(w, 1 if i.password else 0)
}

decode_server_info :: proc(data: []u8) -> (i: Server_Info, ok: bool) {
	r := reader_make(data)
	i.protocol = read_u32(&r)
	i.name = read_string(&r, MAX_SERVER_NAME)
	i.players = int(read_u8(&r))
	i.max_players = int(read_u8(&r))
	i.password = read_u8(&r) == 1
	return i, reader_finish(&r)
}

MAX_SERVER_NAME :: 48

// A stack on the wire: its item (0: none) and count.
@(private = "file")
write_stack :: proc(w: ^Writer, st: Stack) {
	if stack_empty(st) {
		write_u16(w, 0)
		return
	}
	write_u16(w, u16(st.item))
	write_u16(w, u16(st.count))
}

@(private = "file")
read_stack :: proc(r: ^Reader) -> Stack {
	item := Item(read_u16(r))
	if item == NO_ITEM {return {}}
	count := int(read_u16(r))
	if !item_valid(item) || count <= 0 || count > item_stack_size(item) {
		reader_fail(r)
		return {}
	}
	return {item, count}
}
