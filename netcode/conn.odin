package netcode

import "core:mem"
import "core:time"

// A connection's reliability layer over an unreliable datagram link (UDP,
// or a simulated one in tests). It knows nothing of sockets or addresses:
// conn_packet takes what arrived, conn_flush hands out what to send.
//
// Every datagram is one packet: a header with this connection's token, a
// packet sequence number, acknowledgements of the last 33 packets received
// (ack + 32 bits) and of every reliable message received in order so far
// (a burst of more than 33 packets is still acknowledged at once), then
// message records. Two kinds of message:
//
// - Reliable, ordered: numbered; resent until a packet carrying it is
//   acknowledged; delivered exactly once, in order. Messages too big for
//   one packet go as consecutive fragments, reassembled on arrival (in
//   order, so no fragment table is needed).
// - Unreliable: sent once, in the next packet; delivered at most once, and
//   only if nothing newer has arrived (latest state wins).
//
// The sender keeps to a byte rate, and the game can see how much reliable
// data is waiting (conn_backlog) to hold back what it streams.

MAGIC :: u32(0x31565856) // "VXV1" on the wire: every packet starts with it
MTU :: 1200 // bytes of UDP payload per packet: fits any real path
DATA_HEADER :: 4 + 1 + 4 + 2 + 2 + 4 + 2 // magic, kind, token, seq, ack, ack bits, reliable ack
RECORD_HEADER :: 1 + 2 + 2 // flags, message id, length
FRAGMENT_SIZE :: MTU - DATA_HEADER - RECORD_HEADER // largest record payload
MAX_MESSAGE :: 64 * 1024
RECORDS_PER_PACKET :: 64
RELIABLE_WINDOW :: 1024 // reliable messages in flight (sender) / buffered (receiver)
SENT_RING :: 256 // packets remembered for their acks
KEEPALIVE :: 100 * time.Millisecond // send at least this often (acks ride along)
TIMEOUT :: 10 * time.Second // silent this long: gone
DEFAULT_RATE :: 2 * 1024 * 1024 // bytes per second

Packet_Kind :: enum u8 {
	Data = 1,
	Connect, // client: may I? (padded: anti-amplification)
	Challenge, // server: prove you are at that address (cookie)
	Response, // client: the cookie back, and the password proof
	Accept, // server: you are in; here is your token
	Deny, // server: no (why)
	Disconnect, // either: goodbye (why)
	Discover, // client, broadcast: who is serving here?
	Discover_Reply, // server: me (info)
}

@(private)
FLAG_RELIABLE :: 1
@(private)
FLAG_MORE :: 2 // a fragment with more to follow

Conn :: struct {
	token:       u32, // in every data packet: tells our packets from strays and forgeries
	allocator:   mem.Allocator,
	rate:        f32, // bytes per second we may send
	// Sending.
	next_seq:    u16,
	sent:        [SENT_RING]Sent_Packet,
	out:         [dynamic]Out_Message, // reliable, unacknowledged: out[i] has id out_base + i
	out_base:    u16,
	backlog:     int, // bytes in out
	unreliable:  [dynamic][]u8, // for the next flush only
	allowance:   f32, // bytes we may still send now
	last_flush:  time.Tick,
	last_send:   time.Tick,
	ack_owed:    bool,
	// Receiving.
	recv_latest: u16,
	recv_bits:   u32, // bit i: packet recv_latest - 1 - i arrived
	recv_any:    bool,
	slots:       [RELIABLE_WINDOW]In_Slot,
	expected:    u16, // the next reliable id to deliver
	partial:     [dynamic]u8, // fragments of the message being reassembled
	inbox:       [dynamic][]u8, // complete messages for conn_receive
	last_recv:   time.Tick,
	// Measured.
	rtt_ms:      f32,
	stats:       Conn_Stats,
}

Conn_Stats :: struct {
	packets_sent, packets_received: int,
	bytes_sent, bytes_received:     int,
	resent:                         int, // reliable records sent again
	duplicates:                     int, // packets that had arrived before
}

@(private)
Out_Message :: struct {
	data:    []u8,
	more:    bool,
	acked:   bool,
	sends:   int,
	sent_at: time.Tick,
}

@(private)
Sent_Packet :: struct {
	seq:   u16,
	valid: bool,
	at:    time.Tick,
	ids:   [RECORDS_PER_PACKET]u16, // reliable records it carried
	count: int,
}

@(private)
In_Slot :: struct {
	present: bool,
	more:    bool,
	data:    []u8,
}

conn_init :: proc(c: ^Conn, token: u32, now: time.Tick, allocator := context.allocator) {
	c^ = {
		token       = token,
		allocator   = allocator,
		rate        = DEFAULT_RATE,
		rtt_ms      = 100,
		// Until a packet arrives, acknowledge none: 0 would claim our peer's
		// first packet (lost, its messages would never be resent).
		recv_latest = 0xffff,
		allowance   = DEFAULT_RATE * 0.05 + 4 * MTU,
		last_flush  = now,
		last_send   = now,
		last_recv   = now,
	}
	c.out = make([dynamic]Out_Message, allocator)
	c.unreliable = make([dynamic][]u8, allocator)
	c.partial = make([dynamic]u8, allocator)
	c.inbox = make([dynamic][]u8, allocator)
}

conn_destroy :: proc(c: ^Conn) {
	for m in c.out {delete(m.data, c.allocator)}
	for m in c.unreliable {delete(m, c.allocator)}
	for s in c.slots {if s.present {delete(s.data, c.allocator)}}
	for m in c.inbox {delete(m, c.allocator)}
	delete(c.out)
	delete(c.unreliable)
	delete(c.partial)
	delete(c.inbox)
	c^ = {}
}

// conn_send queues a message (copied). Reliable ones of any size up to
// MAX_MESSAGE; unreliable ones must fit one packet.
conn_send :: proc(c: ^Conn, data: []u8, reliable: bool) {
	assert(len(data) > 0 && len(data) <= MAX_MESSAGE)
	if !reliable {
		assert(len(data) <= FRAGMENT_SIZE)
		append(&c.unreliable, clone(c, data))
		return
	}
	for rest := data; len(rest) > 0; {
		n := min(len(rest), FRAGMENT_SIZE)
		append(&c.out, Out_Message{data = clone(c, rest[:n]), more = n < len(rest)})
		c.backlog += n
		rest = rest[n:]
	}
}

// conn_backlog: reliable bytes not yet acknowledged (sent or not).
conn_backlog :: proc(c: ^Conn) -> int {
	return c.backlog
}

// conn_receive moves the messages that arrived (in order, for reliable
// ones) to out; free each with conn_free.
conn_receive :: proc(c: ^Conn, out: ^[dynamic][]u8) {
	append(out, ..c.inbox[:])
	clear(&c.inbox)
}

conn_free :: proc(c: ^Conn, m: []u8) {
	delete(m, c.allocator)
}

conn_timed_out :: proc(c: ^Conn, now: time.Tick) -> bool {
	return time.tick_diff(c.last_recv, now) > TIMEOUT
}

// conn_packet takes a data packet that arrived for this connection (already
// known to start with MAGIC and Data). False if it is malformed or not ours.
conn_packet :: proc(c: ^Conn, packet: []u8, now: time.Tick) -> bool {
	r := reader(packet)
	if get_u32(&r) != MAGIC || Packet_Kind(get_u8(&r)) != .Data || get_u32(&r) != c.token {
		return false
	}
	seq, ack, ack_bits, before := get_u16(&r), get_u16(&r), get_u32(&r), get_u16(&r)
	if !r.ok {return false}

	// Which records are fresh: a duplicate packet adds nothing, and an
	// older one only its reliable records (its unreliable ones are stale).
	duplicate, newest := false, true
	switch {
	case !c.recv_any:
		c.recv_any, c.recv_latest, c.recv_bits = true, seq, 0
	case seq_newer(seq, c.recv_latest):
		shift := u32(seq - c.recv_latest)
		c.recv_bits = (c.recv_bits << shift | 1 << (shift - 1)) if shift <= 32 else 0
		c.recv_latest = seq
	case seq == c.recv_latest:
		duplicate = true
	case:
		newest = false
		back := u32(c.recv_latest - seq) - 1
		if back < 32 {
			duplicate = c.recv_bits & (1 << back) != 0
			c.recv_bits |= 1 << back
		}
	}
	c.stats.packets_received += 1
	c.stats.bytes_received += len(packet)
	c.last_recv = now
	c.ack_owed = true
	acknowledged(c, ack, now, true)
	for i in u16(0) ..< 32 {
		if ack_bits & (1 << i) != 0 {acknowledged(c, ack - 1 - i, now, false)}
	}
	// Every reliable message before `before` has arrived.
	if n := int(u16(before - c.out_base)); n <= len(c.out) {
		for &m in c.out[:n] {m.acked = true}
		pop_acked(c)
	}
	if duplicate {
		c.stats.duplicates += 1
		return true
	}

	for r.n < len(r.buf) {
		flags := get_u8(&r)
		id: u16
		if flags & FLAG_RELIABLE != 0 {id = get_u16(&r)}
		data := get_blob(&r, FRAGMENT_SIZE)
		if !r.ok || len(data) == 0 || flags > FLAG_RELIABLE | FLAG_MORE {return false}
		if flags & FLAG_RELIABLE == 0 {
			if flags & FLAG_MORE != 0 {return false}
			if newest {append(&c.inbox, clone(c, data))}
			continue
		}
		ahead := u16(id - c.expected)
		if ahead >= RELIABLE_WINDOW {continue} 	// delivered already (or nonsense)
		slot := &c.slots[id % RELIABLE_WINDOW]
		if slot.present {continue}
		slot^ = {true, flags & FLAG_MORE != 0, clone(c, data)}
	}
	deliver(c)
	return true
}

// conn_flush writes the packets to send now into packets (each a slice of
// one buffer that the next flush reuses), within the byte rate: queued
// unreliable messages, reliable ones never sent or due to be resent, and
// an empty packet when acknowledgements are owed or the link has been
// quiet for KEEPALIVE.
conn_flush :: proc(c: ^Conn, now: time.Tick, buffer: ^[dynamic]u8, packets: ^[dynamic][]u8) {
	clear(buffer)
	clear(packets)
	dt := f32(time.duration_seconds(time.tick_diff(c.last_flush, now)))
	c.last_flush = now
	c.allowance = min(c.allowance + c.rate * dt, c.rate * 0.05 + 4 * MTU)

	resend_after := time.Duration(clamp(c.rtt_ms * 1.5 + 10, 30, 1000) * f32(time.Millisecond))
	next := 0 // the next reliable message to consider
	window := min(len(c.out), RELIABLE_WINDOW)
	unreliable := 0
	ranges := make([dynamic][2]int, context.temp_allocator)
	for {
		start := len(buffer)
		resize(buffer, start + MTU)
		w := writer(buffer[start:])
		seq := c.next_seq
		put_u32(&w, MAGIC)
		put_u8(&w, u8(Packet_Kind.Data))
		put_u32(&w, c.token)
		put_u16(&w, seq)
		put_u16(&w, c.recv_latest)
		put_u32(&w, c.recv_bits)
		put_u16(&w, c.expected)
		sp := Sent_Packet {
			seq   = seq,
			valid = true,
			at    = now,
		}
		records := 0
		for unreliable < len(c.unreliable) && records < RECORDS_PER_PACKET {
			m := c.unreliable[unreliable]
			if w.n + RECORD_HEADER + len(m) > MTU {break}
			put_u8(&w, 0)
			put_blob(&w, m)
			unreliable += 1
			records += 1
		}
		for ; next < window && sp.count < RECORDS_PER_PACKET; next += 1 {
			m := &c.out[next]
			if m.acked || (m.sends > 0 && time.tick_diff(m.sent_at, now) < resend_after) {continue}
			if w.n + RECORD_HEADER + len(m.data) > MTU {break}
			put_u8(&w, FLAG_RELIABLE | (FLAG_MORE if m.more else 0))
			put_u16(&w, c.out_base + u16(next))
			put_blob(&w, m.data)
			if m.sends > 0 {c.stats.resent += 1}
			m.sends += 1
			m.sent_at = now
			sp.ids[sp.count] = c.out_base + u16(next)
			sp.count += 1
			records += 1
		}
		assert(w.ok)
		quiet := time.tick_diff(c.last_send, now) >= KEEPALIVE
		if records == 0 && !c.ack_owed && !quiet {
			resize(buffer, start)
			break
		}
		resize(buffer, start + w.n)
		append(&ranges, [2]int{start, start + w.n})
		c.sent[seq % SENT_RING] = sp
		c.next_seq += 1
		c.ack_owed = false
		c.last_send = now
		c.allowance -= f32(w.n)
		c.stats.packets_sent += 1
		c.stats.bytes_sent += w.n
		if c.allowance <= 0 || (records == 0) {break}
		if unreliable == len(c.unreliable) && next >= window {break}
	}
	for m in c.unreliable {delete(m, c.allocator)}
	clear(&c.unreliable) // what did not fit is dropped: a newer state will follow
	for r in ranges {append(packets, buffer[r[0]:r[1]])}
}

// acknowledged: the other side has packet seq; its reliable records are
// delivered.
@(private)
acknowledged :: proc(c: ^Conn, seq: u16, now: time.Tick, sample_rtt: bool) {
	sp := &c.sent[seq % SENT_RING]
	if !sp.valid || sp.seq != seq {return}
	sp.valid = false
	if sample_rtt {
		ms := f32(time.duration_milliseconds(time.tick_diff(sp.at, now)))
		c.rtt_ms += (ms - c.rtt_ms) * 0.1
	}
	for id in sp.ids[:sp.count] {
		i := int(u16(id - c.out_base))
		if i < len(c.out) {c.out[i].acked = true}
	}
	pop_acked(c)
}

// pop_acked drops acknowledged messages from the front of the queue.
@(private)
pop_acked :: proc(c: ^Conn) {
	n := 0
	for n < len(c.out) && c.out[n].acked {
		c.backlog -= len(c.out[n].data)
		delete(c.out[n].data, c.allocator)
		n += 1
	}
	remove_range(&c.out, 0, n)
	c.out_base += u16(n)
}

// deliver moves complete messages, in order, to the inbox.
@(private)
deliver :: proc(c: ^Conn) {
	for {
		slot := &c.slots[c.expected % RELIABLE_WINDOW]
		if !slot.present {return}
		if !slot.more && len(c.partial) == 0 {
			append(&c.inbox, slot.data) // whole: hand over as is
		} else {
			append(&c.partial, ..slot.data)
			delete(slot.data, c.allocator)
			if len(c.partial) > MAX_MESSAGE {
				clear(&c.partial) // nonsense from the other side; drop it
			} else if !slot.more {
				append(&c.inbox, clone(c, c.partial[:]))
				clear(&c.partial)
			}
		}
		slot^ = {}
		c.expected += 1
	}
}

@(private)
clone :: proc(c: ^Conn, data: []u8) -> []u8 {
	b := make([]u8, len(data), c.allocator)
	copy(b, data)
	return b
}
