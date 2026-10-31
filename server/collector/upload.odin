package collector

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "common:base"
import "common:game"
import "common:netcode"

// The uploader: what a server (a player's singleplayer world, a dedicated
// server) does to get its event log to a collector. Every interval, and a
// last time at stop, it looks in <dir> (the server's telemetry directory) for
// what has not been sent: the day files' lines past a cursor (kept in
// upload.cursor), and any report (reports/*.txt). If there is something it
// connects, proves its account as joining does, sends batches of whole lines
// of at most BATCH_SIZE bytes and waits for each to be acknowledged before
// the cursor moves; unacknowledged, it tries again next time (the collector
// writes a batch once however often it arrives). With nothing to send it
// sends nothing: no connection, no packet.

BATCH_SIZE :: 30_000
ACK_TIMEOUT :: 5 * time.Second
CONNECT_TIMEOUT :: 5 * time.Second

Uploader :: struct {
	dir:       string,
	server:    net.Endpoint,
	key:       game.Account_Key,
	interval:  time.Duration,
	thread:    ^thread.Thread,
	stop:      bool, // (atomic)
	mutex:     sync.Mutex,
	acked:     u64, // batches acknowledged (for tests and the log)
	passes:    u64, // passes that connected
	link:      netcode.Link,
	writer:    game.Writer,
	scratch:   ^game.Block_Array,
	cursors:   map[string]u64, // day -> bytes sent
	sim:       ^netcode.Simnet, // the simulated network it runs on (nil: UDP)
	idle:      proc(data: rawptr), // what a wait does instead of sleeping (nil: sleep)
	idle_data: rawptr,
}

uploader_open :: proc(
	u: ^Uploader,
	dir: string,
	server: net.Endpoint,
	key: game.Account_Key,
	interval := 30 * time.Second,
	sim: ^netcode.Simnet = nil,
) {
	u^ = {}
	u.dir = strings.clone(dir)
	u.server, u.key, u.interval, u.sim = server, key, interval, sim
	game.writer_init(&u.writer)
	u.scratch = new(game.Block_Array)
	load_upload_cursors(u)
}

// uploader_start opens the uploader and runs its passes on a thread.
uploader_start :: proc(
	u: ^Uploader,
	dir: string,
	server: net.Endpoint,
	key: game.Account_Key,
	interval := 30 * time.Second,
) {
	uploader_open(u, dir, server, key, interval)
	u.thread = thread.create_and_start_with_poly_data(
		u,
		uploader_main,
		base.thread_context(), // the caller's allocator: what the thread makes, stop frees
		self_cleanup = false,
	)
}

// uploader_stop does a last pass (what was written up to now) and stops.
uploader_stop :: proc(u: ^Uploader) {
	sync.atomic_store(&u.stop, true)
	thread.join(u.thread)
	thread.destroy(u.thread)
	uploader_close(u)
}

// uploader_close frees an uploader that is not running on a thread.
uploader_close :: proc(u: ^Uploader) {
	game.writer_destroy(&u.writer)
	free(u.scratch)
	for k in u.cursors {delete(k)}
	delete(u.cursors)
	delete(u.dir)
	u^ = {}
}

// uploader_now: the time on the uploader's network.
@(private)
uploader_now :: proc(u: ^Uploader) -> time.Tick {
	if u.sim != nil {return u.sim.now}
	return time.tick_now()
}

// uploader_wait: between two looks at the link, a sleep, or what the owner
// of a simulated network does to move it on.
@(private)
uploader_wait :: proc(u: ^Uploader) {
	if u.idle != nil {u.idle(u.idle_data)} else {time.sleep(2 * time.Millisecond)}
}

uploader_counts :: proc(u: ^Uploader) -> (acked, passes: u64) {
	sync.mutex_lock(&u.mutex)
	defer sync.mutex_unlock(&u.mutex)
	return u.acked, u.passes
}

// uploader_wake: send what there is now (tests).
@(private)
uploader_main :: proc(u: ^Uploader) {
	base.thread_register("uploader")
	defer base.thread_unregister()
	last := time.tick_now()
	for !sync.atomic_load(&u.stop) {
		time.sleep(20 * time.Millisecond)
		if time.tick_diff(last, time.tick_now()) >= u.interval {
			upload_pass(u)
			last = time.tick_now()
		}
	}
	upload_pass(u)
}

@(private)
pending :: proc(u: ^Uploader) -> (days: []string, reports: []string) {
	d := make([dynamic]string, context.temp_allocator)
	r := make([dynamic]string, context.temp_allocator)
	infos, _ := os.read_all_directory_by_path(u.dir, context.temp_allocator)
	for info in infos {
		if strings.has_suffix(info.name, ".jsonl") &&
		   len(info.name) == 16 &&
		   info.size > i64(u.cursors[info.name[:10]] or_else 0) {
			append(&d, info.name[:10])
		}
	}
	rinfos, _ := os.read_all_directory_by_path(
		fmt.tprintf("%s/reports", u.dir),
		context.temp_allocator,
	)
	for info in rinfos {if strings.has_suffix(info.name, ".txt") {append(&r, info.fullpath)}}
	slice.sort(d[:])
	return d[:], r[:]
}

@(private)
upload_pass :: proc(u: ^Uploader) {
	days, reports := pending(u)
	if len(days) == 0 && len(reports) == 0 {return}
	if !connect(u) {return}
	defer netcode.link_close(&u.link, "done")
	sync.mutex_lock(&u.mutex)
	u.passes += 1
	sync.mutex_unlock(&u.mutex)
	for day in days {
		path := fmt.tprintf("%s/%s.jsonl", u.dir, day)
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {continue}
		offset := u.cursors[day] or_else 0
		if offset > u64(len(data)) {offset = 0} 	// (a file that was started again)
		for offset < u64(len(data)) {
			chunk := whole_lines(data[offset:], BATCH_SIZE)
			if len(chunk) == 0 {break}
			if !send_batch(
				u,
				{.Events, day, offset, string(chunk)},
				day,
				offset + u64(len(chunk)),
			) {return}
			offset += u64(len(chunk))
			set_upload_cursor(u, day, offset)
		}
	}
	for path in reports {
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {continue}
		text := string(data[:min(len(data), game.MAX_BATCH_TEXT)])
		if !send_batch(u, {.Report, "", 0, text}, "", u64(len(text))) {return}
		os.remove(path)
	}
}

// whole_lines: the longest prefix of data of whole lines within limit bytes.
@(private)
whole_lines :: proc(data: []u8, limit: int) -> []u8 {
	n := min(len(data), limit)
	for n > 0 && data[n - 1] != '\n' {n -= 1}
	return data[:n]
}

@(private)
connect :: proc(u: ^Uploader) -> bool {
	if err := netcode.link_connect(&u.link, u.server, "", uploader_now(u), sim = u.sim);
	   err != nil {return false}
	start := uploader_now(u)
	for u.link.state != .Connected {
		netcode.link_update(&u.link, uploader_now(u))
		if u.link.state == .Failed || time.tick_diff(start, uploader_now(u)) > CONNECT_TIMEOUT {
			netcode.link_close(&u.link, "no collector")
			return false
		}
		uploader_wait(u)
	}
	up_send(u, game.Hello{game.PROTOCOL_VERSION, u.key.account, "", 0})
	msg, ok := wait_message(u)
	challenge, is_challenge := msg.(game.Challenge)
	if !ok || !is_challenge {
		netcode.link_close(&u.link, "no challenge")
		return false
	}
	up_send(u, game.Proof{game.account_sign(&u.key, challenge.nonce)})
	return true
}

@(private)
up_send :: proc(u: ^Uploader, m: game.Client_Message) {
	clear(&u.writer.buf)
	game.encode_client(&u.writer, m)
	netcode.link_send(&u.link, u.writer.buf[:], true)
	netcode.link_flush(&u.link, uploader_now(u))
}

// wait_message: the next message from the collector, within the timeout.
@(private)
wait_message :: proc(u: ^Uploader) -> (m: game.Server_Message, ok: bool) {
	start := uploader_now(u)
	got := make([dynamic][]u8, context.temp_allocator)
	for time.tick_diff(start, uploader_now(u)) < ACK_TIMEOUT {
		now := uploader_now(u)
		netcode.link_update(&u.link, now)
		if u.link.state == .Failed {return}
		clear(&got)
		netcode.link_receive(&u.link, &got)
		for data in got {
			defer netcode.link_free(&u.link, data)
			if msg, decoded := game.decode_server(data, u.scratch); decoded && !ok {
				m, ok = msg, true
				if ack, is_ack := m.(game.Telemetry_Ack); is_ack { 	// (its day is a view into the packet)
					m = game.Telemetry_Ack{strings.clone(ack.day, context.temp_allocator), ack.end}
				}
			}
		}
		if ok {return}
		netcode.link_flush(&u.link, now)
		uploader_wait(u)
	}
	return
}

@(private)
send_batch :: proc(u: ^Uploader, batch: game.Telemetry_Batch, day: string, end: u64) -> bool {
	up_send(u, batch)
	for {
		m, ok := wait_message(u)
		if !ok {return false}
		if ack, is_ack := m.(game.Telemetry_Ack); is_ack && ack.day == day && ack.end == end {
			sync.mutex_lock(&u.mutex)
			u.acked += 1
			sync.mutex_unlock(&u.mutex)
			return true
		}
	}
}

@(private)
load_upload_cursors :: proc(u: ^Uploader) {
	data, err := os.read_entire_file_from_path(
		fmt.tprintf("%s/upload.cursor", u.dir),
		context.temp_allocator,
	)
	if err != nil {return}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		day, _, n := strings.partition(line, " ")
		if value, ok := strconv.parse_u64(n);
		   ok && len(day) == 10 {u.cursors[strings.clone(day)] = value}
	}
}

@(private)
set_upload_cursor :: proc(u: ^Uploader, day: string, offset: u64) {
	if _, had := &u.cursors[day];
	   had {u.cursors[day] = offset} else {u.cursors[strings.clone(day)] = offset}
	b := strings.builder_make(context.temp_allocator)
	for d, o in u.cursors {fmt.sbprintfln(&b, "%s %d", d, o)}
	_ = os.write_entire_file(fmt.tprintf("%s/upload.cursor", u.dir), b.buf[:])
}

// report_write leaves a report for the uploader: the text, in dir/reports.
report_write :: proc(dir: string, text: string) -> bool {
	os.make_directory_all(fmt.tprintf("%s/reports", dir))
	path := fmt.tprintf("%s/reports/%d.txt", dir, time.to_unix_nanoseconds(time.now()) / 1_000_000)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}
