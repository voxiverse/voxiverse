package collector

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "common:base"
import "common:game"
import "common:netcode"

// The game's side of developer chat (docs/telemetry.md, "Developer chat"): a
// conversation kept in one file (devchat.jsonl beside the settings), messages
// the player wrote waiting there until a collector takes them, and the
// developers' replies fetched into it. A pass connects only when there is
// something to send or a fetch is due: every FETCH_ACTIVE while the chat
// screen is open, every FETCH_IDLE otherwise. Like the uploader, it proves the
// account's key as joining does; nothing is sent before that.

FETCH_ACTIVE :: 30 * time.Second
FETCH_IDLE :: 5 * time.Minute

Chat_Status :: enum u8 {
	Unknown, // no pass has run yet
	Connected, // the last pass reached the collector
	Offline, // the last pass could not
}

// Chat_Entry: one line of the conversation.
Chat_Entry :: struct {
	from_me:  bool,
	id:       string, // mine: the message id in hex; a reply: its id
	time:     i64, // unix ms
	text:     string,
	link:     string, // a reply's link ("": none)
	sent:     bool, // mine: a collector took it
	refused:  string, // mine: the collector refused it, and why (it is not sent again)
	// mine: where the player was ("" / false when not attached)
	version:  string,
	universe: string,
	world:    string,
	has_pos:  bool,
	pos:      [3]i32,
	has_tick: bool,
	tick:     u64,
}

// Chat_Context: what a message carries besides its text.
Chat_Context :: struct {
	version:  string,
	universe: string,
	world:    string,
	has_pos:  bool,
	pos:      [3]i32,
	has_tick: bool,
	tick:     u64,
}

Chat :: struct {
	path:        string, // the conversation's file
	server:      net.Endpoint,
	key:         game.Account_Key,
	thread:      ^thread.Thread,
	stop:        bool, // (atomic)
	active:      bool, // (atomic) the chat screen is open: fetch often
	wake:        bool, // (atomic) something was written: pass now
	mutex:       sync.Mutex, // guards entries, status, changed
	entries:     [dynamic]Chat_Entry, // oldest first; strings owned
	status:      Chat_Status,
	changed:     u64, // bumped on every change (for the screen and the toast)
	new_replies: u64, // replies fetched since start (for the toast)
	link:        netcode.Link,
	writer:      game.Writer,
	scratch:     ^game.Block_Array,
	last_fetch:  time.Tick,
	fetched:     bool, // a fetch has run
	sim:         ^netcode.Simnet, // the simulated network (nil: UDP)
	idle:        proc(data: rawptr), // what a wait does instead of sleeping (tests)
	idle_data:   rawptr,
}

chat_open :: proc(
	c: ^Chat,
	path: string,
	server: net.Endpoint,
	key: game.Account_Key,
	sim: ^netcode.Simnet = nil,
) {
	c^ = {}
	c.path = strings.clone(path)
	c.server, c.key, c.sim = server, key, sim
	game.writer_init(&c.writer)
	c.scratch = new(game.Block_Array)
	chat_load(c)
}

// chat_start opens the chat and runs its passes on a thread.
chat_start :: proc(c: ^Chat, path: string, server: net.Endpoint, key: game.Account_Key) {
	chat_open(c, path, server, key)
	c.thread = thread.create_and_start_with_poly_data(
		c,
		chat_main,
		base.thread_context(),
		self_cleanup = false,
	)
}

chat_stop :: proc(c: ^Chat) {
	if c.thread != nil {
		sync.atomic_store(&c.stop, true)
		thread.join(c.thread)
		thread.destroy(c.thread)
	}
	chat_close(c)
}

chat_close :: proc(c: ^Chat) {
	for &e in c.entries {entry_free(&e)}
	delete(c.entries)
	game.writer_destroy(&c.writer)
	free(c.scratch)
	delete(c.path)
	c^ = {}
}

// chat_set_active: the chat screen opened (fetch now, then often) or closed.
chat_set_active :: proc(c: ^Chat, active: bool) {
	sync.atomic_store(&c.active, active)
	if active {sync.atomic_store(&c.wake, true)}
}

// chat_send keeps a message (in the file at once: it survives a restart) and
// wakes the pass that sends it. Returns false for an empty or oversized text.
chat_send :: proc(c: ^Chat, text: string, ctx: Chat_Context) -> bool {
	if len(strings.trim_space(text)) == 0 || len(text) > game.MAX_DEV_TEXT {return false}
	sync.mutex_lock(&c.mutex)
	id: [4]u8
	crypto.rand_bytes(id[:])
	e := Chat_Entry {
		from_me  = true,
		id       = fmt.aprintf("%02x%02x%02x%02x", id[0], id[1], id[2], id[3]),
		time     = time.to_unix_nanoseconds(time.now()) / 1_000_000,
		text     = strings.clone(text),
		version  = strings.clone(clip(ctx.version)),
		universe = strings.clone(clip(ctx.universe)),
		world    = strings.clone(clip(ctx.world)),
		has_pos  = ctx.has_pos,
		pos      = ctx.pos,
		has_tick = ctx.has_tick,
		tick     = ctx.tick,
	}
	append(&c.entries, e)
	c.changed += 1
	chat_save(c)
	sync.mutex_unlock(&c.mutex)
	sync.atomic_store(&c.wake, true)
	return true
}

// chat_view: a copy of the conversation (in `allocator`), the status, how many
// of the player's messages wait to be sent, and the change counter.
chat_view :: proc(
	c: ^Chat,
	allocator := context.temp_allocator,
) -> (
	entries: []Chat_Entry,
	status: Chat_Status,
	waiting: int,
	changed: u64,
) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	out := make([]Chat_Entry, len(c.entries), allocator)
	for e, i in c.entries {
		out[i] = e
		out[i].id = strings.clone(e.id, allocator)
		out[i].text = strings.clone(e.text, allocator)
		out[i].link = strings.clone(e.link, allocator)
		out[i].refused = strings.clone(e.refused, allocator)
		out[i].version = strings.clone(e.version, allocator)
		out[i].universe = strings.clone(e.universe, allocator)
		out[i].world = strings.clone(e.world, allocator)
		if e.from_me && !e.sent && e.refused == "" {waiting += 1}
	}
	return out, c.status, waiting, c.changed
}

// chat_replies: how many replies were fetched since the chat started (the toast).
chat_replies :: proc(c: ^Chat) -> u64 {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	return c.new_replies
}

@(private)
clip :: proc(s: string) -> string {return s[:min(len(s), game.MAX_DEV_FIELD)]}

@(private)
entry_free :: proc(e: ^Chat_Entry) {
	delete(e.id)
	delete(e.text)
	delete(e.link)
	delete(e.refused)
	delete(e.version)
	delete(e.universe)
	delete(e.world)
}

@(private)
chat_now :: proc(c: ^Chat) -> time.Tick {
	if c.sim != nil {return c.sim.now}
	return time.tick_now()
}

@(private)
chat_wait :: proc(c: ^Chat) {
	if c.idle != nil {c.idle(c.idle_data)} else {time.sleep(2 * time.Millisecond)}
}

@(private)
chat_main :: proc(c: ^Chat) {
	base.thread_register("devchat")
	defer base.thread_unregister()
	for !sync.atomic_load(&c.stop) {
		time.sleep(20 * time.Millisecond)
		if chat_due(c) {chat_pass(c)}
	}
}

// chat_due: is there something to send, or a fetch due?
@(private)
chat_due :: proc(c: ^Chat) -> bool {
	if sync.atomic_exchange(&c.wake, false) {return true}
	if !c.fetched {return true}
	every := FETCH_ACTIVE if sync.atomic_load(&c.active) else FETCH_IDLE
	return time.tick_diff(c.last_fetch, chat_now(c)) >= every
}

// chat_pass: connect, send what waits, fetch the replies, close. A pass that
// cannot reach the collector leaves everything waiting for the next.
chat_pass :: proc(c: ^Chat) {
	c.last_fetch, c.fetched = chat_now(c), true
	if !chat_connect(c) {
		chat_set_status(c, .Offline)
		return
	}
	defer netcode.link_close(&c.link, "done")
	chat_set_status(c, .Connected)
	if !chat_send_waiting(c) {return}
	chat_fetch(c)
}

@(private)
chat_set_status :: proc(c: ^Chat, s: Chat_Status) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	if c.status != s {c.status = s; c.changed += 1}
}

@(private)
chat_connect :: proc(c: ^Chat) -> bool {
	if err := netcode.link_connect(&c.link, c.server, "", chat_now(c), sim = c.sim);
	   err != nil {return false}
	start := chat_now(c)
	for c.link.state != .Connected {
		netcode.link_update(&c.link, chat_now(c))
		if c.link.state == .Failed || time.tick_diff(start, chat_now(c)) > CONNECT_TIMEOUT {
			netcode.link_close(&c.link, "no collector")
			return false
		}
		chat_wait(c)
	}
	chat_out(c, game.Hello{game.PROTOCOL_VERSION, c.key.account, "", 0, 0, nil})
	msg, ok := chat_message(c)
	challenge, is_challenge := msg.(game.Challenge)
	if !ok || !is_challenge {
		netcode.link_close(&c.link, "no challenge")
		return false
	}
	chat_out(c, game.Proof{game.account_sign(&c.key, challenge.nonce)})
	return true
}

@(private)
chat_out :: proc(c: ^Chat, m: game.Client_Message) {
	clear(&c.writer.buf)
	game.encode_client(&c.writer, m)
	netcode.link_send(&c.link, c.writer.buf[:], true)
	netcode.link_flush(&c.link, chat_now(c))
}

// chat_message: the next message from the collector within the timeout, its
// strings cloned into the temp allocator (the packet is freed).
@(private)
chat_message :: proc(c: ^Chat) -> (m: game.Server_Message, ok: bool) {
	start := chat_now(c)
	got := make([dynamic][]u8, context.temp_allocator)
	for time.tick_diff(start, chat_now(c)) < ACK_TIMEOUT {
		now := chat_now(c)
		netcode.link_update(&c.link, now)
		if c.link.state == .Failed {return}
		clear(&got)
		netcode.link_receive(&c.link, &got)
		for data in got {
			defer netcode.link_free(&c.link, data)
			if msg, decoded := game.decode_server(data, c.scratch); decoded && !ok {
				m, ok = msg, true
				#partial switch v in msg {
				case game.Dev_Ack:
					m = game.Dev_Ack{v.id, v.ok, strings.clone(v.reason, context.temp_allocator)}
				case game.Dev_Replies:
					r := v
					for i in 0 ..< r.count {
						e := &r.entries[i]
						e.id = strings.clone(e.id, context.temp_allocator)
						e.text = strings.clone(e.text, context.temp_allocator)
						e.link = strings.clone(e.link, context.temp_allocator)
					}
					m = r
				}
			}
		}
		if ok {return}
		netcode.link_flush(&c.link, now)
		chat_wait(c)
	}
	return
}

// chat_send_waiting sends the player's waiting messages in order, each until
// it is acknowledged. False: the connection was lost (the rest waits).
@(private)
chat_send_waiting :: proc(c: ^Chat) -> bool {
	for {
		sync.mutex_lock(&c.mutex)
		index := -1
		m: game.Dev_Message
		for e, i in c.entries {
			if !e.from_me || e.sent || e.refused != "" {continue}
			index = i
			m = game.Dev_Message {
				id       = parse_id(e.id),
				text     = strings.clone(e.text, context.temp_allocator),
				version  = strings.clone(e.version, context.temp_allocator),
				universe = strings.clone(e.universe, context.temp_allocator),
				world    = strings.clone(e.world, context.temp_allocator),
				has_pos  = e.has_pos,
				pos      = e.pos,
				has_tick = e.has_tick,
				tick     = e.tick,
			}
			break
		}
		sync.mutex_unlock(&c.mutex)
		if index < 0 {return true}
		chat_out(c, m)
		for {
			reply, ok := chat_message(c)
			if !ok {return false}
			ack, is_ack := reply.(game.Dev_Ack)
			if !is_ack || ack.id != m.id {continue}
			sync.mutex_lock(&c.mutex)
			e := &c.entries[index]
			if ack.ok {e.sent = true} else {e.refused = strings.clone(ack.reason if ack.reason != "" else "refused")}
			c.changed += 1
			chat_save(c)
			sync.mutex_unlock(&c.mutex)
			break
		}
	}
}

// chat_fetch asks for the replies after the newest one held, until a page
// comes back short.
@(private)
chat_fetch :: proc(c: ^Chat) {
	for {
		sync.mutex_lock(&c.mutex)
		after := ""
		for i := len(c.entries) - 1; i >= 0; i -= 1 {
			if !c.entries[i].from_me {after = strings.clone(c.entries[i].id, context.temp_allocator); break}
		}
		sync.mutex_unlock(&c.mutex)
		chat_out(c, game.Dev_Fetch{after})
		count := 0
		for {
			reply, ok := chat_message(c)
			if !ok {return}
			page, is_page := reply.(game.Dev_Replies)
			if !is_page {continue}
			count = page.count
			sync.mutex_lock(&c.mutex)
			for r in page.entries[:page.count] {
				append(
					&c.entries,
					Chat_Entry {
						id = strings.clone(r.id),
						time = r.time,
						text = strings.clone(r.text),
						link = strings.clone(r.link),
					},
				)
				c.new_replies += 1
			}
			if page.count > 0 {c.changed += 1; chat_save(c)}
			sync.mutex_unlock(&c.mutex)
			break
		}
		if count < game.MAX_DEV_REPLIES {return}
	}
}

@(private)
parse_id :: proc(hex: string) -> (id: u32) {
	for ch in hex {
		d: u32
		switch ch {
		case '0' ..= '9':
			d = u32(ch - '0')
		case 'a' ..= 'f':
			d = u32(ch - 'a' + 10)
		case:
			return
		}
		id = id << 4 | d
	}
	return
}

// The file: one JSON object per line, oldest first.
@(private)
Chat_Line :: struct {
	from:     string `json:"from"`, // "me" or "dev"
	id:       string `json:"id"`,
	time:     i64 `json:"time"`,
	text:     string `json:"text"`,
	link:     string `json:"link,omitempty"`,
	sent:     bool `json:"sent,omitempty"`,
	refused:  string `json:"refused,omitempty"`,
	version:  string `json:"version,omitempty"`,
	universe: string `json:"universe,omitempty"`,
	world:    string `json:"world,omitempty"`,
	position: Maybe([3]i32) `json:"position,omitempty"`,
	tick:     Maybe(u64) `json:"tick,omitempty"`,
}

// chat_save rewrites the file (called with the mutex held). Written beside and
// renamed, so a crash leaves the old file or the new one.
@(private)
chat_save :: proc(c: ^Chat) {
	b := strings.builder_make(context.temp_allocator)
	for e in c.entries {
		line := Chat_Line {
			from     = "me" if e.from_me else "dev",
			id       = e.id,
			time     = e.time,
			text     = e.text,
			link     = e.link,
			sent     = e.sent,
			refused  = e.refused,
			version  = e.version,
			universe = e.universe,
			world    = e.world,
		}
		if e.has_pos {line.position = e.pos}
		if e.has_tick {line.tick = e.tick}
		data, err := json.marshal(line, allocator = context.temp_allocator)
		if err != nil {continue}
		strings.write_bytes(&b, data)
		strings.write_byte(&b, '\n')
	}
	tmp := fmt.tprintf("%s.tmp", c.path)
	if os.write_entire_file(tmp, b.buf[:]) == nil {_ = os.rename(tmp, c.path)}
}

@(private)
chat_load :: proc(c: ^Chat) {
	data, err := os.read_entire_file_from_path(c.path, context.temp_allocator)
	if err != nil {return}
	rest := string(data)
	for text in strings.split_lines_iterator(&rest) {
		if strings.trim_space(text) == "" {continue}
		line: Chat_Line
		if json.unmarshal_string(text, &line, allocator = context.temp_allocator) != nil {continue}
		if line.from != "me" && line.from != "dev" {continue}
		e := Chat_Entry {
			from_me  = line.from == "me",
			id       = strings.clone(line.id),
			time     = line.time,
			text     = strings.clone(line.text),
			link     = strings.clone(line.link),
			sent     = line.sent,
			refused  = strings.clone(line.refused),
			version  = strings.clone(line.version),
			universe = strings.clone(line.universe),
			world    = strings.clone(line.world),
		}
		if p, has := line.position.?; has {e.has_pos, e.pos = true, p}
		if t, has := line.tick.?; has {e.has_tick, e.tick = true, t}
		append(&c.entries, e)
	}
}
