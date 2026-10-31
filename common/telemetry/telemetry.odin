package telemetry

import "common:base"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Telemetry: one stream of events for everything that measures play. A
// kind is an entry of the Kind enum with a row in KIND_INFO that says what it
// is called and what its fields mean, so a kind cannot be emitted with
// other fields than it documents. emit is a push into a ring buffer under a
// mutex that is held for a copy, nothing else: the tick never waits for a
// disk. A writer thread drains the ring every 100 ms and appends JSON lines
// to <dir>/YYYY-MM-DD.jsonl (a size cap per day). When the ring is full the
// new event is dropped and counted, and the count is written as an event of
// its own (Events_Dropped), so a loss is always visible.
//
// Anonymisation, uploading and the collector are M27's: events carry the
// actor as a player id in a world, never a name.

// Kind: append-only (the numbers are in no file, but the names are in every log).
Kind :: enum u16 {
	Events_Dropped, // n0: how many
	Session_Start, // a player joined; n0: players online
	Session_End, // n0: seconds played this session
	Block_Mined, // text: block; n0: 1
	Block_Placed, // text: block
	Item_Picked, // text: item; n0: count
	Item_Dropped, // text: item; n0: count
	Item_Used, // text: item (fed, planted, tilled)
	Entity_Hit, // text: kind
	Entity_Killed, // text: kind
	Explosion, // n0: radius
	Rocket_Fired,
	Chat_Line,
	Chat_Whisper,
	Command, // text: name
	Teleport, // text: how (tp, home, warp, spawn, back, travel, gate)
	Gate_Dial, // text: result
	Sheep_Fed,
	Sheep_Sheared,
	Sheep_Born,
	Position_Sample, // text: state (walking, flying, swimming, falling); every 10 s
	Tick_Summary, // n0: players online, n1: tick time p50 in us, n2: worst in us; every minute
	Client_Info, // from a client at join: text: OS; n0: view distance, n1: fov, n2: ms from launch to playing
	Client_Overlay, // from a client: text: overlay; n0: ms it was open
	Client_Perf, // from a client every minute: n0: frame p50 us, n1: p99 us, n2: frames
	Damage, // text: cause (fall, explosion); n0: tenths of a health point; n1: health left in tenths
	Death, // text: cause
	Level_Up, // n0: the new level; n1: total xp
	Item_Created, // text: item; n0: count; n1: the reason (server/ledger.odin)
	Item_Destroyed, // text: item; n0: count; n1: the reason
	Audit_Failed, // text: item; n0: held; n1: the ledger says; n2: difference
	Respawned, // text: the game mode
	Shot_Fired, // text: the weapon; n0: 1 when it hit
	Mode_Changed, // text: the new game mode; n0: 1 when a command did it (the journal says who)
	// The session recording's (issue #65): what a LAN party's analytics needs.
	Ping_Sample, // n0: round trip in ms; every 10 s for each player
	Damage_Dealt, // text: the weapon; n0: tenths of a health point; n1: the victim's player id
	Kill, // text: the weapon; n0: ms from the first damage to the death; n1: the victim's player id
	Grapple_Used, // the hook attached
	Jump, // text: ground or air (a double jump)
	Client_Hardware, // from a client at joining: text: the GPU's name; n0, n1: the window's width and height
	Client_Driver, // from a client at joining: text: the GPU driver and its version
	Client_Frames, // from a client every minute: n0: frame p50 us, n1: p95 us, n2: worst us
	Server_Perf, // every minute: n0: tick time p50 in us, n1: p95, n2: worst
	Server_Net, // every minute: n0: desyncs so far, n1: checks judged, n2: checks skipped
	Bandwidth_Sample, // every minute for each player: n0: bytes sent, n1: bytes received, n2: records sent again
	Log_Line, // a warning or an error of the server's log: line: the text
	Server_Start, // n0: the most players
	Server_Stop, // a clean stop (a session that has none ended in a crash)
}

Kind_Info :: struct {
	name:         string, // in the log
	text_name:    string, // what its text is called ("" none)
	note_name:    string, // what its note (a long text) is called ("" none)
	n_names:      [3]string, // what its numbers are called ("" none)
	counter:      string, // the counter it adds to ("%t": the text; "": none); the amount is n0 (1 if none)
	client:       bool, // a client may report it
	session_only: bool, // only the session recording keeps it (never the day files, which may be uploaded)
	amount:       bool, // the counter grows by n0 (else by 1)
}

@(rodata)
KIND_INFO := [Kind]Kind_Info {
	.Events_Dropped = {name = "events_dropped", n_names = {"n", "", ""}},
	.Session_Start = {name = "session_start", n_names = {"online", "", ""}, counter = "sessions"},
	.Session_End = {name = "session_end", n_names = {"seconds", "", ""}},
	.Block_Mined = {name = "block_mined", text_name = "block", counter = "blocks.mined.%t"},
	.Block_Placed = {name = "block_placed", text_name = "block", counter = "blocks.placed.%t"},
	.Item_Picked = {
		name = "item_picked",
		text_name = "item",
		n_names = {"count", "", ""},
		counter = "items.picked.%t",
		amount = true,
	},
	.Item_Dropped = {
		name = "item_dropped",
		text_name = "item",
		n_names = {"count", "", ""},
		counter = "items.dropped.%t",
		amount = true,
	},
	.Item_Used = {name = "item_used", text_name = "item", counter = "items.used.%t"},
	.Entity_Hit = {name = "entity_hit", text_name = "entity", counter = "entities.hit.%t"},
	.Entity_Killed = {
		name = "entity_killed",
		text_name = "entity",
		counter = "entities.killed.%t",
	},
	.Explosion = {name = "explosion", n_names = {"radius", "", ""}, counter = "explosions"},
	.Rocket_Fired = {name = "rocket_fired", counter = "rockets.fired"},
	.Chat_Line = {name = "chat_line", counter = "chat.lines"},
	.Chat_Whisper = {name = "chat_whisper", counter = "chat.whispers"},
	.Command = {name = "command", text_name = "name", counter = "commands.%t"},
	.Teleport = {name = "teleport", text_name = "how", counter = "teleports.%t"},
	.Gate_Dial = {name = "gate_dial", text_name = "result", counter = "gates.dials"},
	.Sheep_Fed = {name = "sheep_fed", counter = "sheep.fed"},
	.Sheep_Sheared = {name = "sheep_sheared", counter = "sheep.sheared"},
	.Sheep_Born = {name = "sheep_born", counter = "sheep.born"},
	.Position_Sample = {name = "position_sample", text_name = "state"},
	.Tick_Summary = {name = "tick_summary", n_names = {"online", "p50_us", "worst_us"}},
	.Client_Info = {
		name = "client_info",
		text_name = "os",
		n_names = {"view_distance", "fov", "launch_ms"},
		client = true,
	},
	.Client_Overlay = {
		name = "client_overlay",
		text_name = "overlay",
		n_names = {"open_ms", "", ""},
		client = true,
	},
	.Damage = {
		name = "damage",
		text_name = "cause",
		n_names = {"tenths", "left", ""},
		counter = "damage.%t",
		amount = true,
	},
	.Death = {name = "death", text_name = "cause", counter = "deaths.%t"},
	.Level_Up = {name = "level_up", n_names = {"level", "xp", ""}},
	.Item_Created = {name = "item_created", text_name = "item", n_names = {"count", "reason", ""}},
	.Item_Destroyed = {
		name = "item_destroyed",
		text_name = "item",
		n_names = {"count", "reason", ""},
	},
	.Audit_Failed = {
		name = "audit_failed",
		text_name = "item",
		n_names = {"held", "expected", "difference"},
	},
	.Respawned = {name = "respawned", text_name = "mode", counter = "respawns"},
	.Shot_Fired = {
		name = "shot_fired",
		text_name = "weapon",
		n_names = {"hit", "", ""},
		counter = "shots.fired",
	},
	.Mode_Changed = {
		name = "mode_changed",
		text_name = "mode",
		n_names = {"command", "", ""},
		counter = "mode_changes",
	},
	.Client_Perf = {name = "client_perf", n_names = {"p50_us", "p99_us", "frames"}, client = true},
	.Ping_Sample = {session_only = true, name = "ping_sample", n_names = {"rtt_ms", "", ""}},
	.Damage_Dealt = {
		session_only = true,
		name = "damage_dealt",
		text_name = "weapon",
		n_names = {"tenths", "victim", ""},
		counter = "weapon_damage.%t",
		amount = true,
	},
	.Kill = {
		session_only = true,
		name = "kill",
		text_name = "weapon",
		n_names = {"ttk_ms", "victim", ""},
		counter = "weapon_kills.%t",
	},
	.Grapple_Used = {session_only = true, name = "grapple_used", counter = "grapple.uses"},
	.Jump = {session_only = true, name = "jump", text_name = "kind", counter = "jump.%t"},
	.Client_Hardware = {
		session_only = true,
		name = "client_hardware",
		text_name = "gpu",
		n_names = {"width", "height", ""},
		client = true,
	},
	.Client_Driver = {
		session_only = true,
		name = "client_driver",
		text_name = "driver",
		client = true,
	},
	.Client_Frames = {
		session_only = true,
		name = "client_frames",
		n_names = {"p50_us", "p95_us", "worst_us"},
		client = true,
	},
	.Server_Perf = {
		session_only = true,
		name = "server_perf",
		n_names = {"p50_us", "p95_us", "worst_us"},
	},
	.Server_Net = {
		session_only = true,
		name = "server_net",
		n_names = {"desyncs", "judged", "skipped"},
	},
	.Bandwidth_Sample = {
		session_only = true,
		name = "bandwidth_sample",
		n_names = {"sent", "received", "resent"},
	},
	.Log_Line = {session_only = true, name = "log_line", note_name = "line"},
	.Server_Start = {
		session_only = true,
		name = "server_start",
		n_names = {"max_players", "", ""},
	},
	.Server_Stop = {session_only = true, name = "server_stop"},
}

kind_by_name :: proc(name: string) -> (Kind, bool) {
	for info, k in KIND_INFO {if info.name == name {return k, true}}
	return {}, false
}

SHORT_MAX :: 31

// Short: a small string kept in the event (names of blocks, items, commands).
Short :: struct {
	n: u8,
	b: [SHORT_MAX]u8,
}

short :: proc(s: string) -> (r: Short) {
	r.n = u8(min(len(s), SHORT_MAX))
	copy(r.b[:], s[:r.n])
	return
}

short_string :: proc(s: Short) -> string {
	s := s
	return strings.clone(string(s.b[:s.n]), context.temp_allocator)
}

NOTE_MAX :: 119

// Note: a long text in an event (a log line), cut to NOTE_MAX bytes.
Note :: struct {
	n: u8,
	b: [NOTE_MAX]u8,
}

note :: proc(s: string) -> (r: Note) {
	r.n = u8(min(len(s), NOTE_MAX))
	copy(r.b[:], s[:r.n])
	return
}

note_string :: proc(n: Note) -> string {
	n := n
	return strings.clone(string(n.b[:n.n]), context.temp_allocator)
}

Event :: struct {
	time_ms: i64, // wall clock, ms since the Unix epoch
	tick:    u32, // the server's tick
	session: u32, // this server run
	actor:   u16, // the player (id in the world); NO_ACTOR for the server
	kind:    Kind,
	has_pos: bool,
	pos:     [3]i32, // block coordinates
	world:   Short, // address, directory form
	text:    Short,
	note:    Note,
	n:       [3]i64,
}

NO_ACTOR :: max(u16)

RING_SIZE :: 1 << 14
DEFAULT_DAY_CAP :: 64 * 1024 * 1024 // bytes written per day

// Sink: where events go.
Sink :: struct {
	mutex:         sync.Mutex,
	ring:          []Event, // RING_SIZE of them (heap)
	head:          u64, // next to write
	tail:          u64, // next to drain
	dropped:       u64, // events refused since the writer last said so
	dropped_total: u64,
	written:       u64, // events written (the writer's)
	busy:          bool, // a batch is taken from the ring and not yet written
	capped:        u64, // events not written for the day cap
	session:       u32,
	dir:           string, // "": nothing is written (events still counted)
	file_name:     string, // not "": every event goes to this one file in dir (a session's), not to a file a day
	day_cap:       int,
	thread:        ^thread.Thread,
	stop:          bool, // (atomic)
	stepped:       bool, // no thread: the owner calls sink_drain (tests)
	// the writer's, thread-private
	day:           i64, // days since the epoch of the open file
	day_bytes:     int,
	file:          ^os.File,
	file_open:     bool,
}

// sink_start opens the sink; dir "" writes nothing. session identifies this run.
// file_name: every event goes to that one file (a session's), not to a file a day.
// A `stepped` sink has no writer thread: sink_drain is the writer's pass.
sink_start :: proc(
	s: ^Sink,
	dir: string,
	session: u32,
	day_cap := DEFAULT_DAY_CAP,
	stepped := false,
	file_name := "",
) {
	s^ = {}
	s.session = session
	s.day_cap = day_cap
	s.stepped = stepped
	s.file_name = strings.clone(file_name)
	s.ring = make([]Event, RING_SIZE)
	if dir != "" {
		s.dir = strings.clone(dir)
		os.make_directory_all(dir)
		if stepped {return}
		s.thread = thread.create_and_start_with_poly_data(
			s,
			writer_main,
			base.thread_context(),
			self_cleanup = false,
		)
	}
}

// sink_stop drains what is left and closes the file.
sink_stop :: proc(s: ^Sink) {
	if s.stepped {
		sink_drain(s)
		if s.file_open {os.close(s.file)}
	} else if s.thread != nil {
		sync.atomic_store(&s.stop, true)
		thread.join(s.thread)
		thread.destroy(s.thread)
	}
	delete(s.dir)
	delete(s.file_name)
	delete(s.ring)
	s^ = {}
}

// sink_flush waits until everything emitted so far is written (tests).
sink_flush :: proc(s: ^Sink) {
	if s.stepped {
		sink_drain(s)
		return
	}
	if s.thread == nil {return}
	for {
		sync.mutex_lock(&s.mutex)
		done := s.tail == s.head && s.dropped == 0 && !s.busy
		sync.mutex_unlock(&s.mutex)
		if done {break}
		time.sleep(5 * time.Millisecond)
	}
}

now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

// emit records e (its time and session filled in if not set). It never blocks
// for long and never fails: a full ring drops the event and counts it.
emit :: proc(s: ^Sink, e: Event) {
	e := e
	if e.time_ms == 0 {e.time_ms = now_ms()}
	e.session = s.session
	sync.mutex_lock(&s.mutex)
	if s.head - s.tail >= RING_SIZE {
		s.dropped += 1
		s.dropped_total += 1
	} else {
		s.ring[s.head % RING_SIZE] = e
		s.head += 1
	}
	sync.mutex_unlock(&s.mutex)
}

// stats of the sink: what was written, dropped and refused for the cap.
Sink_Stats :: struct {
	written, dropped, capped: u64,
}

sink_stats :: proc(s: ^Sink) -> Sink_Stats {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	return {s.written, s.dropped_total, s.capped}
}

// sink_drain is the writer's work on the caller's thread: everything emitted
// so far is written, as the thread would write it.
sink_drain :: proc(s: ^Sink) {
	if s.tail == s.head && s.dropped == 0 {return}
	batch := make([]Event, 2048)
	defer delete(batch)
	text := strings.builder_make()
	defer strings.builder_destroy(&text)
	for writer_pass(s, batch, &text) == len(batch) {}
}

// writer_pass drains up to a batch from the ring and writes it; the count.
@(private)
writer_pass :: proc(s: ^Sink, batch: []Event, text: ^strings.Builder) -> int {
	n := 0
	dropped: u64
	sync.mutex_lock(&s.mutex)
	for s.tail < s.head && n < len(batch) {
		batch[n] = s.ring[s.tail % RING_SIZE]
		s.tail += 1
		n += 1
	}
	if n < len(batch) {dropped, s.dropped = s.dropped, 0}
	s.busy = n > 0 || dropped > 0
	sync.mutex_unlock(&s.mutex)
	strings.builder_reset(text)
	if dropped > 0 {
		write_event(
			text,
			{
				time_ms = now_ms(),
				session = s.session,
				actor = NO_ACTOR,
				kind = .Events_Dropped,
				n = {i64(dropped), 0, 0},
			},
		)
	}
	for i in 0 ..< n {write_event(text, batch[i])}
	if text.buf != nil && len(text.buf) > 0 {write_out(s, string(text.buf[:]), batch[:n], n)}
	sync.mutex_lock(&s.mutex)
	s.busy = false
	sync.mutex_unlock(&s.mutex)
	return n
}

@(private)
writer_main :: proc(s: ^Sink) {
	base.thread_register("telemetry")
	defer base.thread_unregister()
	batch := make([]Event, 2048)
	defer delete(batch)
	text := strings.builder_make()
	defer strings.builder_destroy(&text)
	for {
		stopping := sync.atomic_load(&s.stop)
		n := writer_pass(s, batch, &text)
		if stopping && n == 0 {break}
		if n < len(batch) {time.sleep(100 * time.Millisecond)}
	}
	if s.file_open {os.close(s.file)}
}

// write_out appends text (lines of the events in batch, in order) to the
// day's file, per event so the cap and the day boundary are exact.
@(private)
write_out :: proc(s: ^Sink, text: string, batch: []Event, count: int) {
	rest := text
	// A leading dropped-events line is not an event of the batch: it goes with the first one.
	for line in strings.split_lines_iterator(&rest) {
		if len(line) == 0 {continue}
		day := day_of(line_time(line))
		if s.file_name != "" {day = 0} 	// (a session's file spans days)
		if !s.file_open || day != s.day {
			if s.file_open {os.close(s.file)}
			s.day, s.day_bytes, s.file_open = day, 0, false
			path := fmt.tprintf("%s/%s.jsonl", s.dir, day_name(day))
			if s.file_name != "" {path = fmt.tprintf("%s/%s", s.dir, s.file_name)}
			f, err := os.open(path, {.Write, .Create, .Append})
			if err != nil {continue}
			s.file, s.file_open = f, true
			if info, e := os.fstat(f, context.temp_allocator);
			   e == nil {s.day_bytes = int(info.size)}
		}
		if s.day_bytes + len(line) + 1 > s.day_cap {
			sync.mutex_lock(&s.mutex)
			s.capped += 1
			sync.mutex_unlock(&s.mutex)
			continue
		}
		os.write_string(s.file, line)
		os.write_string(s.file, "\n")
		s.day_bytes += len(line) + 1
		sync.mutex_lock(&s.mutex)
		s.written += 1
		sync.mutex_unlock(&s.mutex)
	}
}

@(private)
line_time :: proc(line: string) -> i64 {
	// {"t":1234,...
	n: i64
	for c in line[5:] {
		if c < '0' || c > '9' {break}
		n = n * 10 + i64(c - '0')
	}
	return n
}

@(private)
day_of :: proc(ms: i64) -> i64 {
	return ms / 86_400_000
}

// day_name: the UTC date of a day number (days since 1970-01-01).
day_name :: proc(day: i64) -> string {
	// Civil from days (Howard Hinnant's algorithm).
	z := day + 719468
	era := (z if z >= 0 else z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d := doy - (153 * mp + 2) / 5 + 1
	m := mp + 3 if mp < 10 else mp - 9
	if m <= 2 {y += 1}
	return fmt.tprintf("%04d-%02d-%02d", y, m, d)
}

// write_event appends e as one JSON line (no newline) to b.
write_event :: proc(b: ^strings.Builder, e: Event) {
	info := KIND_INFO[e.kind]
	fmt.sbprintf(b, `{{"t":%d,"tick":%d,"sid":%d,"actor":`, e.time_ms, e.tick, e.session)
	if e.actor == NO_ACTOR {strings.write_string(b, "null")} else {fmt.sbprintf(b, "%d", e.actor)}
	fmt.sbprintf(b, `,"k":"%s"`, info.name)
	if e.world.n > 0 {
		strings.write_string(b, `,"world":`)
		write_string(b, short_string(e.world))
	}
	if e.has_pos {fmt.sbprintf(b, `,"pos":[%d,%d,%d]`, e.pos.x, e.pos.y, e.pos.z)}
	if info.text_name != "" && e.text.n > 0 {
		fmt.sbprintf(b, `,"%s":`, info.text_name)
		write_string(b, short_string(e.text))
	}
	if info.note_name != "" && e.note.n > 0 {
		fmt.sbprintf(b, `,"%s":`, info.note_name)
		write_string(b, note_string(e.note))
	}
	for name, i in info.n_names {
		if name != "" {fmt.sbprintf(b, `,"%s":%d`, name, e.n[i])}
	}
	strings.write_string(b, "}\n")
}

@(private)
write_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in transmute([]u8)s {
		switch {
		case c == '"' || c == '\\':
			strings.write_byte(b, '\\')
			strings.write_byte(b, c)
		case c < 0x20:
			strings.write_byte(b, '?')
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}
