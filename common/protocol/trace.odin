package protocol

import "common:game"
import "core:os"
import "core:time"

// Network traces: every message either side sent, with when and by whom,
// as raw bytes. Tools decode them with the game's own decoders (netdump
// prints and summarises, replay feeds the client's messages to a fresh
// server), so a trace never disagrees with what the game did.
//
// File: "VXNT", u32 trace version, the header fields (u8 for the bool),
// then records:
// u64 nanoseconds since the session started, u8 sender (0 client, 1
// server), u32 length, the message bytes. Little-endian.

TRACE_MAGIC :: "VXNT"
TRACE_VERSION :: 2

Trace_Header :: struct {
	protocol:     u32,
	seed:         i64,
	view_radius:  u32,
	view_height:  u32,
	allow_cheats: bool, // the server honoured Teleport and Set_Rule
}

Trace_Record :: struct {
	time:   time.Duration, // since the session started
	sender: Side,
	data:   []u8, // view into the trace
}

Trace_Writer :: struct {
	file:   ^os.File,
	writer: game.Writer, // reused per record
}

trace_open :: proc(t: ^Trace_Writer, path: string, h: Trace_Header) -> bool {
	f, err := os.open(path, {.Write, .Create, .Trunc})
	if err != nil {return false}
	t.file = f
	game.writer_init(&t.writer)
	w := &t.writer
	append(&w.buf, TRACE_MAGIC)
	game.write_u32(w, TRACE_VERSION)
	game.write_u32(w, h.protocol)
	game.write_u32(w, u32(h.seed))
	game.write_u32(w, u32(h.seed >> 32))
	game.write_u32(w, h.view_radius)
	game.write_u32(w, h.view_height)
	game.write_u8(w, 1 if h.allow_cheats else 0)
	os.write(f, w.buf[:])
	return true
}

trace_write :: proc(t: ^Trace_Writer, at: time.Duration, sender: Side, data: []u8) {
	w := &t.writer
	clear(&w.buf)
	ns := u64(at)
	game.write_u32(w, u32(ns))
	game.write_u32(w, u32(ns >> 32))
	game.write_u8(w, u8(sender))
	game.write_u32(w, u32(len(data)))
	append(&w.buf, ..data)
	os.write(t.file, w.buf[:])
}

trace_close :: proc(t: ^Trace_Writer) {
	if t.file == nil {return}
	os.close(t.file)
	game.writer_destroy(&t.writer)
	t^ = {}
}

// trace_read parses a whole trace; records point into data. ok is false
// for anything malformed (including a truncated last record, e.g. from a
// crash: the records before it are still returned).
trace_read :: proc(
	data: []u8,
	allocator := context.allocator,
) -> (
	header: Trace_Header,
	records: [dynamic]Trace_Record,
	ok: bool,
) {
	records = make([dynamic]Trace_Record, allocator)
	if len(data) < 4 || string(data[:4]) != TRACE_MAGIC {return}
	r := game.reader_make(data[4:])
	if game.read_u32(&r) != TRACE_VERSION {return}
	header.protocol = game.read_u32(&r)
	lo, hi := u64(game.read_u32(&r)), u64(game.read_u32(&r))
	header.seed = i64(lo | hi << 32)
	header.view_radius = game.read_u32(&r)
	header.view_height = game.read_u32(&r)
	header.allow_cheats = game.read_u8(&r) == 1
	if !r.ok {return}
	for r.pos < len(r.data) {
		lo, hi = u64(game.read_u32(&r)), u64(game.read_u32(&r))
		sender := game.read_u8(&r)
		n := game.read_u32(&r)
		if !r.ok ||
		   sender > 1 ||
		   n == 0 ||
		   n > MAX_MESSAGE_SIZE ||
		   int(n) > len(r.data) - r.pos {return}
		append(
			&records,
			Trace_Record{time.Duration(lo | hi << 32), Side(sender), r.data[r.pos:][:n]},
		)
		r.pos += int(n)
	}
	return header, records, true
}

// trace_game: the game the traced session played, as the server's Welcome named it ("":
// the trace holds no Welcome), so a tool that reads a trace reads the game's records and
// replays its rules (tools/netdump, tools/replay; they find the game by its id among
// the lists of games).
trace_game :: proc(
	records: []Trace_Record,
	scratch: ^game.Block_Array,
	reg: ^game.Registry,
) -> string {
	for r in records {
		if r.sender != .Server ||
		   len(r.data) == 0 ||
		   message_kind_name(.Server, r.data[0]) != "welcome" {
			continue
		}
		m, ok := decode_server(r.data, scratch, reg)
		if w, is := m.(Welcome); ok && is {return w.game}
	}
	return ""
}
