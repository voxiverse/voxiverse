package game

// Messages between client and server. Every message travels as bytes, also
// in-process, so singleplayer exercises the same encoding and validation as
// a remote connection. A message is one u8 kind followed by its fields;
// decoders accept only fully valid messages with nothing left over, so
// handlers get validated values only.
//
// Interest is decided by the server: the client reports where it is, the
// server sends the chunks around it (nearest first) and tells it which ones
// to drop.

PROTOCOL_VERSION :: 1
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

// Move reports the client's camera position (M4 replaces this with
// tick-stamped input commands).
Move :: struct {
	position: [3]f64,
}

// Ping asks the server to answer with a Pong carrying the same id (round
// trip time, including the wait for the server's next tick).
Ping :: struct {
	id: u32,
}

Client_Message :: union {
	Hello,
	Move,
	Ping,
}

// Server -> client.

Welcome :: struct {
	protocol:    u32,
	tick_rate:   u32,
	spawn:       [3]f64,
	view_radius: u32, // the interest area, in chunks (see interest.odin)
	view_height: u32,
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

Server_Message :: union {
	Welcome,
	Reject,
	Chunk_Message,
	Unload_Chunk,
	Pong,
}

MAX_VIEW_RADIUS :: 32
MAX_REASON_LENGTH :: 256

@(private = "file")
Client_Kind :: enum u8 {
	Hello = 1,
	Move,
	Ping,
}

@(private = "file")
Server_Kind :: enum u8 {
	Welcome = 1,
	Reject,
	Chunk,
	Unload_Chunk,
	Pong,
}

// message_kind_name names a message kind (its first byte) sent by sender,
// for tools and statistics; "" if there is no such kind.
message_kind_name :: proc(sender: Side, kind: u8) -> string {
	if sender == .Client {
		switch kind {
		case u8(Client_Kind.Hello):
			return "hello"
		case u8(Client_Kind.Move):
			return "move"
		case u8(Client_Kind.Ping):
			return "ping"
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
	case Move:
		write_u8(w, u8(Client_Kind.Move))
		write_position(w, v.position)
	case Ping:
		write_u8(w, u8(Client_Kind.Ping))
		write_u32(w, v.id)
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
	case u8(Client_Kind.Move):
		m = Move {
			position = read_position(&r),
		}
	case u8(Client_Kind.Ping):
		m = Ping {
			id = read_u32(&r),
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
	case:
		return
	}
	return m, reader_finish(&r)
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
read_chunk_pos :: proc(r: ^Reader) -> (c: Chunk_Pos) {
	for &v in c {v = read_i32(r)}
	if !in_world(c) {reader_fail(r)}
	return
}
