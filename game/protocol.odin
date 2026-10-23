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

PROTOCOL_VERSION :: 2
MAX_MESSAGE_SIZE :: 64 * 1024
MAX_NAME_LENGTH :: 32

// Positions and chunk coordinates are kept far from integer overflow: block
// coordinates stay within ±2^28 (chunk coordinates within ±2^24).
WORLD_LIMIT :: 1 << 28
CHUNK_LIMIT :: WORLD_LIMIT >> CHUNK_SHIFT

// Client -> server.

Hello :: struct {
	protocol: u32,
	name:     string, // view into the message
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

// Teleport and Set_Rule are cheats: honoured only by servers that allow
// them (singleplayer).
Teleport :: struct {
	position:   [3]f64,
	yaw, pitch: f32,
}

Set_Rule :: struct {
	name:  string, // a rules.* variable
	value: string,
}

// Edit asks to put block at pos (Air: break). The client has already
// applied it (predicted); Edit_Result says what became of it.
Edit :: struct {
	id:    u32,
	pos:   Block_Pos,
	block: Block,
}

Client_Message :: union {
	Hello,
	Input,
	Ping,
	Teleport,
	Set_Rule,
	Edit,
}

// Server -> client.

Welcome :: struct {
	protocol:    u32,
	tick_rate:   u32,
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
}

MAX_VIEW_RADIUS :: 32
MAX_REASON_LENGTH :: 256
MAX_RULE_TEXT :: 64
MAX_SPEED :: 1000 // blocks/s: anything faster in a message is invalid

@(private = "file")
Client_Kind :: enum u8 {
	Hello = 1,
	Input,
	Ping,
	Teleport,
	Set_Rule,
	Edit,
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
		write_block_pos(w, v.pos)
		write_u16(w, u16(v.block))
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
			pos   = read_block_pos(&r),
			block = read_block(&r),
		}
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
			protocol    = read_u32(&r),
			tick_rate   = read_u32(&r),
			spawn       = read_position(&r),
			view_radius = read_u32(&r),
			view_height = read_u32(&r),
		}
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
