package collector

import "core:crypto"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../../base"
import "../../common/game"
import "../../common/netcode"
import "../../common/telemetry"

// The collector: the end of M27's pipe. Servers (a player's singleplayer
// world, a dedicated server) send their event logs to it in batches over the
// game's own netcode, authenticated as joining is (Hello, Challenge, Proof:
// an account's key); it validates every line, tells the sender apart from
// others only by an anonymous id (pid: a salted hash of the account's public
// key; the salt lives beside the lake), and appends to the lake:
//
//	<dir>/lake/dt=YYYY-MM-DD/source=server/<HH>.jsonl   events, a pid added to each
//	<dir>/lake/dt=YYYY-MM-DD/source=report/<pid>-<ms>.txt   reports
//
// Files are append-only and partitioned by the event's date and hour, so
// DuckDB (or jq) reads them in place. A batch says where in the sender's
// day-file it begins: the collector remembers how far each (pid, day) got
// (cursors.jsonl, replayed at start), so a batch sent twice is written once.
// Source addresses are never logged.

BATCH_LINE_MAX :: 2048
BATCH_LINES_MAX :: 400
// A peer may send this many batches in a window of BATCH_WINDOW before it is dropped.
BATCHES_PER_WINDOW :: 12
BATCH_WINDOW :: 10 * time.Second

Peer_State :: enum u8 {
	Connected, // waiting for its Hello
	Proving, // sent the Challenge
	Ready, // proved: batches are taken
	Dropped, // refused and kicked: what still arrives is ignored
}

Collector_Peer :: struct {
	state:   Peer_State,
	nonce:   game.Nonce,
	account: game.Account,
	pid:     string, // (heap)
	window:  time.Tick,
	count:   int,
}

Collector_Stats :: struct {
	accepted_batches: u64,
	accepted_lines:   u64,
	duplicates:       u64,
	refused:          u64, // batches refused for a bad line, size, order, or rate
	forged:           u64, // proofs that did not verify
	reports:          u64,
}

Collector :: struct {
	host:    netcode.Host,
	dir:     string,
	salt:    [16]u8,
	peers:   map[netcode.Peer_Id]Collector_Peer,
	cursors: map[string]u64, // "pid|day" -> offset after what was written
	stats:   Collector_Stats,
	mutex:   sync.Mutex, // for stats and port (the thread writes them)
	thread:  ^thread.Thread,
	stop:    bool, // (atomic)
	writer:  game.Writer,
	port:    int,
}

// collector_start opens the collector in dir on a UDP port (0: any) and runs it on a thread.
collector_start :: proc(c: ^Collector, dir: string, port: int) -> bool {
	c^ = {}
	c.dir = strings.clone(dir)
	os.make_directory_all(dir)
	if err := netcode.host_open(&c.host, port, 64); err != nil {
		log.errorf("collector cannot open its port=%d error=%v", port, err)
		return false
	}
	c.port = c.host.socket.port
	game.writer_init(&c.writer)
	load_salt(c)
	load_cursors(c)
	c.thread = thread.create_and_start_with_poly_data(
		c,
		collector_main,
		base.thread_context(), // the caller's allocator: what the thread makes, stop frees
		self_cleanup = false,
	)
	log.infof("collector listening port=%d dir=%s", c.port, dir)
	return true
}

collector_stop :: proc(c: ^Collector) {
	sync.atomic_store(&c.stop, true)
	thread.join(c.thread)
	thread.destroy(c.thread)
	netcode.host_close(&c.host, "the collector stopped")
	game.writer_destroy(&c.writer)
	for _, p in c.peers {delete(p.pid)}
	delete(c.peers)
	for k in c.cursors {delete(k)}
	delete(c.cursors)
	delete(c.dir)
	c^ = {}
}

collector_stats :: proc(c: ^Collector) -> Collector_Stats {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	return c.stats
}

@(private)
collector_main :: proc(c: ^Collector) {
	for !sync.atomic_load(&c.stop) {
		now := time.tick_now()
		netcode.host_update(&c.host, now)
		for e in c.host.events {
			switch v in e {
			case netcode.Peer_Connected:
				// A kick's Peer_Disconnected can be missed (it is appended while this loop
				// runs), and the slot reused: the old peer's pid is freed here then.
				if old, ok := c.peers[v.peer]; ok {delete(old.pid)}
				c.peers[v.peer] = {}
			case netcode.Peer_Message:
				handle(c, v.peer, v.data)
			case netcode.Peer_Disconnected:
				if p, ok := c.peers[v.peer]; ok {delete(p.pid)}
				delete_key(&c.peers, v.peer)
			}
		}
		netcode.host_flush(&c.host, now)
		time.sleep(5 * time.Millisecond)
	}
}

@(private)
send :: proc(c: ^Collector, peer: netcode.Peer_Id, m: game.Server_Message) {
	clear(&c.writer.buf)
	game.encode_server(&c.writer, m, nil)
	netcode.host_send(&c.host, peer, c.writer.buf[:], true)
}

@(private)
refuse :: proc(c: ^Collector, peer: netcode.Peer_Id, why: string) {
	sync.mutex_lock(&c.mutex)
	c.stats.refused += 1
	sync.mutex_unlock(&c.mutex)
	log.warnf("collector refused a batch why=%s", why)
	if p, known := &c.peers[peer]; known {p.state = .Dropped}
	netcode.host_kick(&c.host, peer, why, time.tick_now())
}

@(private)
handle :: proc(c: ^Collector, id: netcode.Peer_Id, data: []u8) {
	p, known := &c.peers[id]
	if !known || p.state == .Dropped {return}
	m, ok := game.decode_client(data)
	if !ok {
		refuse(c, id, "invalid message")
		return
	}
	switch v in m {
	case game.Hello:
		if p.state != .Connected || v.protocol != game.PROTOCOL_VERSION {
			refuse(c, id, "unexpected hello or protocol")
			return
		}
		p.account = v.account
		p.nonce = game.nonce_make()
		p.state = .Proving
		send(c, id, game.Challenge{p.nonce})
	case game.Proof:
		if p.state != .Proving {
			refuse(c, id, "unexpected proof")
			return
		}
		if !game.account_verify(p.account, p.nonce, v.signature) {
			sync.mutex_lock(&c.mutex)
			c.stats.forged += 1
			sync.mutex_unlock(&c.mutex)
			refuse(c, id, "the proof did not verify")
			return
		}
		p.pid = pid_of(c, p.account)
		p.state = .Ready
		p.window = time.tick_now()
	case game.Telemetry_Batch:
		if p.state != .Ready {
			refuse(c, id, "a batch before a proof")
			return
		}
		if time.tick_diff(p.window, time.tick_now()) > BATCH_WINDOW {
			p.window, p.count = time.tick_now(), 0
		}
		p.count += 1
		if p.count > BATCHES_PER_WINDOW {
			refuse(c, id, "too many batches")
			return
		}
		take_batch(c, id, p, v)
	case game.Input,
	     game.Ping,
	     game.Teleport,
	     game.Set_Rule,
	     game.Edit,
	     game.Command,
	     game.Attack,
	     game.Use_Entity,
	     game.Use_Block,
	     game.Prediction_Check,
	     game.Pack_Want,
	     game.Packs_Ready,
	     game.Respawn,
	     game.Shoot,
	     game.Reload,
	     game.Fire,
	     game.Chat,
	     game.Inventory_Request,
	     game.Choose,
	     game.Dial,
	     game.Stats_Request,
	     game.Telemetry_Report:
		refuse(c, id, "this is a telemetry collector")
	}
}

// pid_of: the anonymous id of an account: the first 8 bytes of the salted hash, in hex.
@(private)
pid_of :: proc(c: ^Collector, a: game.Account) -> string {
	input := make([]u8, len(c.salt) + len(a), context.temp_allocator)
	copy(input, c.salt[:])
	acc := a
	copy(input[len(c.salt):], acc[:])
	digest: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, input, digest[:])
	return strings.clone(string(hex.encode(digest[:8], context.temp_allocator)))
}

@(private)
take_batch :: proc(
	c: ^Collector,
	id: netcode.Peer_Id,
	p: ^Collector_Peer,
	b: game.Telemetry_Batch,
) {
	switch b.kind {
	case .Report:
		path := fmt.tprintf(
			"%s/lake/dt=%s/source=report/%s-%d.txt",
			c.dir,
			telemetry.day_name(telemetry.now_ms() / 86_400_000),
			p.pid,
			telemetry.now_ms(),
		)
		os.make_directory_all(filepath.dir(path))
		if len(b.text) == 0 || os.write_entire_file(path, transmute([]u8)b.text) != nil {
			refuse(c, id, "an empty or unwritable report")
			return
		}
		sync.mutex_lock(&c.mutex)
		c.stats.reports += 1
		sync.mutex_unlock(&c.mutex)
		send(c, id, game.Telemetry_Ack{"", u64(len(b.text))})
	case .Events:
		if !valid_day(b.day) {
			refuse(c, id, "a bad day")
			return
		}
		// Every line must be one of ours: an object with a time and a kind we know.
		lines := strings.split_lines(b.text, context.temp_allocator)
		count := 0
		for line in lines {
			if len(line) == 0 {continue}
			count += 1
			if len(line) > BATCH_LINE_MAX || count > BATCH_LINES_MAX || !valid_line(line) {
				refuse(c, id, "a line that is not an event")
				return
			}
		}
		key := fmt.tprintf("%s|%s", p.pid, b.day)
		end := b.offset + u64(len(b.text))
		if have, seen := c.cursors[key]; seen && end <= have {
			sync.mutex_lock(&c.mutex)
			c.stats.duplicates += 1
			sync.mutex_unlock(&c.mutex)
			send(c, id, game.Telemetry_Ack{b.day, end}) // (it was written before)
			return
		}
		for line in lines {
			if len(line) == 0 {continue}
			append_line(c, p.pid, line)
		}
		set_cursor(c, key, end)
		sync.mutex_lock(&c.mutex)
		c.stats.accepted_batches += 1
		c.stats.accepted_lines += u64(count)
		sync.mutex_unlock(&c.mutex)
		send(c, id, game.Telemetry_Ack{b.day, end})
	}
}

// valid_day: YYYY-MM-DD.
@(private)
valid_day :: proc(d: string) -> bool {
	if len(d) != 10 || d[4] != '-' || d[7] != '-' {return false}
	for ch, i in transmute([]u8)d {
		if i != 4 && i != 7 && (ch < '0' || ch > '9') {return false}
	}
	return true
}

// valid_line: {"t":<ms>,... "k":"<a kind>" ...}: the shape the sink writes.
@(private)
valid_line :: proc(line: string) -> bool {
	if !strings.has_prefix(line, `{"t":`) || line[len(line) - 1] != '}' {return false}
	kind_at := strings.index(line, `"k":"`)
	if kind_at < 0 {return false}
	rest := line[kind_at + 5:]
	end := strings.index_byte(rest, '"')
	if end < 0 {return false}
	if _, known := telemetry.kind_by_name(rest[:end]); !known {return false}
	for ch in transmute([]u8)line {
		if ch < 0x20 {return false}
	}
	return true
}

// append_line writes line (with the sender's pid) to its hour's file.
@(private)
append_line :: proc(c: ^Collector, pid: string, line: string) {
	ms := parse_time(line)
	day, hour := telemetry.day_name(ms / 86_400_000), ms / 3_600_000 % 24
	path := fmt.tprintf("%s/lake/dt=%s/source=server/%02d.jsonl", c.dir, day, hour)
	os.make_directory_all(filepath.dir(path))
	f, err := os.open(path, {.Write, .Create, .Append})
	if err != nil {return}
	defer os.close(f)
	os.write_string(f, fmt.tprintf(`{{"pid":"%s",%s`, pid, line[1:]))
	os.write_string(f, "\n")
}

@(private)
parse_time :: proc(line: string) -> i64 {
	n: i64
	for ch in line[5:] {
		if ch < '0' || ch > '9' {break}
		n = n * 10 + i64(ch - '0')
	}
	return n
}

@(private)
load_salt :: proc(c: ^Collector) {
	path := fmt.tprintf("%s/salt", c.dir)
	if data, err := os.read_entire_file_from_path(path, context.temp_allocator);
	   err == nil && len(data) == len(c.salt) {
		copy(c.salt[:], data)
		return
	}
	crypto.rand_bytes(c.salt[:])
	_ = os.write_entire_file(path, c.salt[:])
}

@(private)
load_cursors :: proc(c: ^Collector) {
	data, err := os.read_entire_file_from_path(
		fmt.tprintf("%s/cursors.txt", c.dir),
		context.temp_allocator,
	)
	if err != nil {return}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		key, _, n := strings.partition(line, " ")
		if value, ok := strconv.parse_u64(n); ok && key != "" {
			if old, had := c.cursors[key]; had {
				c.cursors[key] = value
				_ = old
			} else {
				c.cursors[strings.clone(key)] = value
			}
		}
	}
}

@(private)
set_cursor :: proc(c: ^Collector, key: string, end: u64) {
	if _, had := &c.cursors[key];
	   had {c.cursors[key] = end} else {c.cursors[strings.clone(key)] = end}
	if f, err := os.open(fmt.tprintf("%s/cursors.txt", c.dir), {.Write, .Create, .Append});
	   err == nil {
		os.write_string(f, fmt.tprintf("%s %d\n", key, end))
		os.close(f)
	}
}
