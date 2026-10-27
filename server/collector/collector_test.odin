package collector

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../../common/game"
import "../../common/netcode"
import "../../common/telemetry"

@(private = "file")
loopback :: proc(port: int) -> net.Endpoint {
	return {net.IP4_Address{127, 0, 0, 1}, port}
}

// events: n log lines for 2023-11-14, in the sink's own format.
@(private = "file")
events :: proc(n: int, kind := telemetry.Kind.Block_Mined) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< n {
		telemetry.write_event(
			&b,
			{
				time_ms = 1_700_000_000_000 + i64(i) * 60_000,
				tick = u32(i),
				session = 9,
				actor = 0,
				kind = kind,
				text = telemetry.short("stone"),
			},
		)
	}
	return strings.to_string(b)
}

@(private = "file")
read_lake :: proc(dir: string) -> (text: string, files: int) {
	b := strings.builder_make(context.temp_allocator)
	walk :: proc(dir: string, b: ^strings.Builder, files: ^int) {
		infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for info in infos {
			if info.type == .Directory {
				walk(info.fullpath, b, files)
			} else if strings.has_suffix(info.name, ".jsonl") {
				data, _ := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
				strings.write_string(b, string(data))
				files^ += 1
			}
		}
	}
	walk(fmt.tprintf("%s/lake", dir), &b, &files)
	return strings.to_string(b), files
}

@(private = "file")
fresh :: proc(name: string) -> (lake, logs: string) {
	lake = fmt.tprintf("build/test/%s_lake", name)
	logs = fmt.tprintf("build/test/%s_log", name)
	os.remove_all(lake)
	os.remove_all(logs)
	os.make_directory_all(logs)
	return
}

@(private = "file")
wait_for :: proc(seconds: f64, done: proc() -> bool) -> bool {
	end := time.tick_add(time.tick_now(), time.Duration(seconds * f64(time.Second)))
	for time.tick_diff(time.tick_now(), end) > 0 {
		if done() {return true}
		time.sleep(10 * time.Millisecond)
	}
	return done()
}

// A log is uploaded, whole lines in the right partitions with an anonymous pid
// and nothing else about who; sent again (the cursor lost), it is written once.
@(test)
test_a_log_reaches_the_lake_once :: proc(t: ^testing.T) {
	lake, logs := fresh("upload")
	defer os.remove_all(lake)
	defer os.remove_all(logs)
	text := events(50)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/2023-11-14.jsonl", logs), transmute([]u8)text) == nil,
	)
	c: Collector
	if !testing.expect(t, collector_start(&c, lake, 0)) {return}
	key := game.account_key_make()
	u: Uploader
	uploader_start(&u, logs, loopback(c.port), key, 100 * time.Millisecond)
	@(static) up: ^Uploader
	@(static) col: ^Collector
	up, col = &u, &c
	ok := wait_for(
		10,
		proc() -> bool {a, _ := uploader_counts(up); return(
				a >= 1 &&
				collector_stats(col).accepted_lines == 50 \
			)},
	)
	testing.expect(t, ok, "the log never arrived")
	uploader_stop(&u)
	got, files := read_lake(lake)
	testing.expect_value(t, strings.count(got, "\n"), 50)
	testing.expect(t, files >= 1)
	testing.expect(t, strings.has_prefix(got, `{"pid":"`), "no pid")
	pid_end := strings.index(got, `",`)
	testing.expect(t, pid_end == 8 + 16, "the pid is 16 hex digits")
	testing.expect(
		t,
		!strings.contains(got, game.account_text(key.account)),
		"the account itself is in the lake",
	)
	testing.expect(
		t,
		strings.contains(got, `"k":"block_mined"`) && strings.contains(got, `"block":"stone"`),
	)
	// The same pid for the same account, not another's.
	cursor, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/upload.cursor", logs),
		context.temp_allocator,
	)
	testing.expect(
		t,
		strings.contains(string(cursor), fmt.tprintf("2023-11-14 %d", len(text))),
		"the cursor did not advance",
	)

	// The cursor is lost: everything is sent again, and written once.
	os.remove(fmt.tprintf("%s/upload.cursor", logs))
	u2: Uploader
	uploader_start(&u2, logs, loopback(c.port), key, 100 * time.Millisecond)
	up = &u2
	ok = wait_for(10, proc() -> bool {return collector_stats(col).duplicates >= 1})
	testing.expect(t, ok, "a second send was not recognised")
	uploader_stop(&u2)
	again, _ := read_lake(lake)
	testing.expect_value(t, strings.count(again, "\n"), 50)
	collector_stop(&c)

	// A restarted collector remembers (its cursors are on disk).
	c2: Collector
	if !testing.expect(t, collector_start(&c2, lake, 0)) {return}
	os.remove(fmt.tprintf("%s/upload.cursor", logs))
	u3: Uploader
	uploader_start(&u3, logs, loopback(c2.port), key, 100 * time.Millisecond)
	col, up = &c2, &u3
	ok = wait_for(10, proc() -> bool {return collector_stats(col).duplicates >= 1})
	testing.expect(t, ok, "a restarted collector wrote a batch twice")
	uploader_stop(&u3)
	final, _ := read_lake(lake)
	testing.expect_value(t, strings.count(final, "\n"), 50)
	collector_stop(&c2)
	free_all(context.temp_allocator)
}

// The collector down: the log waits and goes when it is up, exactly once;
// with nothing to send, nothing is sent (no connection at all).
@(test)
test_the_spool_survives_a_collector_that_is_down :: proc(t: ^testing.T) {
	lake, logs := fresh("down")
	defer os.remove_all(lake)
	defer os.remove_all(logs)
	// A port: opened once to learn one, then closed.
	probe: Collector
	if !testing.expect(t, collector_start(&probe, lake, 0)) {return}
	port := probe.port
	collector_stop(&probe)
	key := game.account_key_make()
	u: Uploader
	uploader_start(&u, logs, loopback(port), key, 100 * time.Millisecond)
	time.sleep(400 * time.Millisecond) // (nothing to send: no pass)
	_, passes := uploader_counts(&u)
	testing.expect_value(t, passes, 0)
	text := events(20)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/2023-11-14.jsonl", logs), transmute([]u8)text) == nil,
	)
	time.sleep(800 * time.Millisecond) // (it tries and nobody answers)
	acked, _ := uploader_counts(&u)
	testing.expect_value(t, acked, 0)
	// The collector comes up on that port: the log goes.
	c: Collector
	if !testing.expect(t, collector_start(&c, lake, port)) {return}
	@(static) col: ^Collector
	col = &c
	ok := wait_for(12, proc() -> bool {return collector_stats(col).accepted_lines == 20})
	testing.expect(t, ok, "the waiting log never went")
	// More is written meanwhile: only the new lines go.
	more := events(5)
	f, _ := os.open(fmt.tprintf("%s/2023-11-14.jsonl", logs), {.Write, .Append})
	os.write_string(f, more)
	os.close(f)
	ok = wait_for(12, proc() -> bool {return collector_stats(col).accepted_lines == 25})
	testing.expect(t, ok, "the new lines did not go")
	uploader_stop(&u)
	got, _ := read_lake(lake)
	testing.expect_value(t, strings.count(got, "\n"), 25)
	collector_stop(&c)
	free_all(context.temp_allocator)
}

@(private = "file")
Raw :: struct {
	link:   netcode.Link,
	writer: game.Writer,
}

@(private = "file")
raw_connect :: proc(r: ^Raw, port: int) -> bool {
	game.writer_init(&r.writer)
	if netcode.link_connect(&r.link, loopback(port), "", time.tick_now()) != nil {return false}
	for r.link.state != .Connected {
		netcode.link_update(&r.link, time.tick_now())
		if r.link.state == .Failed {return false}
		time.sleep(2 * time.Millisecond)
	}
	return true
}

@(private = "file")
raw_send :: proc(r: ^Raw, m: game.Client_Message) {
	clear(&r.writer.buf)
	game.encode_client(&r.writer, m)
	netcode.link_send(&r.link, r.writer.buf[:], true)
	netcode.link_flush(&r.link, time.tick_now())
}

// raw_challenge: Hello, and the nonce the collector answers with.
@(private = "file")
raw_challenge :: proc(r: ^Raw, account: game.Account) -> (nonce: game.Nonce, ok: bool) {
	raw_send(r, game.Hello{game.PROTOCOL_VERSION, account, "", 0})
	scratch := new(game.Block_Array)
	defer free(scratch)
	start := time.tick_now()
	got := make([dynamic][]u8, context.temp_allocator)
	for time.tick_diff(start, time.tick_now()) < 3 * time.Second {
		netcode.link_update(&r.link, time.tick_now())
		clear(&got)
		netcode.link_receive(&r.link, &got)
		for data in got {
			defer netcode.link_free(&r.link, data)
			if m, decoded := game.decode_server(data, scratch); decoded {
				if c, is_c := m.(game.Challenge); is_c {return c.nonce, true}
			}
		}
		time.sleep(2 * time.Millisecond)
	}
	return
}

// What a collector must refuse: a forged proof, batches before a proof, a line
// that is no event, an unknown kind, a bad day, a flood of batches.
@(test)
test_the_collector_refuses_what_it_should :: proc(t: ^testing.T) {
	lake, logs := fresh("refuse")
	defer os.remove_all(lake)
	defer os.remove_all(logs)
	c: Collector
	if !testing.expect(t, collector_start(&c, lake, 0)) {return}
	defer collector_stop(&c)
	good := events(1)

	// A proof signed by another key.
	{
		r: Raw
		testing.expect(t, raw_connect(&r, c.port))
		mine, other := game.account_key_make(), game.account_key_make()
		nonce, ok := raw_challenge(&r, mine.account)
		testing.expect(t, ok)
		raw_send(&r, game.Proof{game.account_sign(&other, nonce)})
		raw_send(&r, game.Telemetry_Batch{.Events, "2023-11-14", 0, good})
		time.sleep(300 * time.Millisecond)
		testing.expect_value(t, collector_stats(&c).forged, 1)
		testing.expect_value(t, collector_stats(&c).accepted_lines, 0)
		netcode.link_close(&r.link, "done")
		game.writer_destroy(&r.writer)
	}
	// A batch before any proof.
	{
		r: Raw
		testing.expect(t, raw_connect(&r, c.port))
		raw_send(&r, game.Telemetry_Batch{.Events, "2023-11-14", 0, good})
		time.sleep(200 * time.Millisecond)
		testing.expect_value(t, collector_stats(&c).accepted_lines, 0)
		netcode.link_close(&r.link, "done")
		game.writer_destroy(&r.writer)
	}
	// Proved: bad lines, an unknown kind, a bad day; then good ones; then a flood.
	{
		r: Raw
		testing.expect(t, raw_connect(&r, c.port))
		key := game.account_key_make()
		nonce, ok := raw_challenge(&r, key.account)
		testing.expect(t, ok)
		raw_send(&r, game.Proof{game.account_sign(&key, nonce)})
		before := collector_stats(&c).refused
		raw_send(&r, game.Telemetry_Batch{.Events, "2023-11-14", 0, "this is not an event\n"})
		time.sleep(150 * time.Millisecond)
		testing.expect_value(t, collector_stats(&c).refused, before + 1) // (and the peer is dropped)
		netcode.link_close(&r.link, "done")
		game.writer_destroy(&r.writer)
	}
	for bad in ([]string{"{\"t\":1,\"k\":\"made_up_kind\"}\n", "{\"t\":1,\"tick\":0,\"k\":\"block_mined\",\"block\":\"x\x01y\"}\n", "{\"k\":\"block_mined\"}\n"}) {
		r: Raw
		testing.expect(t, raw_connect(&r, c.port))
		key := game.account_key_make()
		nonce, _ := raw_challenge(&r, key.account)
		raw_send(&r, game.Proof{game.account_sign(&key, nonce)})
		before := collector_stats(&c).refused
		raw_send(&r, game.Telemetry_Batch{.Events, "2023-11-14", 0, bad})
		time.sleep(150 * time.Millisecond)
		testing.expectf(t, collector_stats(&c).refused == before + 1, "%q was not refused", bad)
		netcode.link_close(&r.link, "done")
		game.writer_destroy(&r.writer)
	}
	{
		r: Raw
		testing.expect(t, raw_connect(&r, c.port))
		key := game.account_key_make()
		nonce, _ := raw_challenge(&r, key.account)
		raw_send(&r, game.Proof{game.account_sign(&key, nonce)})
		before := collector_stats(&c).refused
		raw_send(&r, game.Telemetry_Batch{.Events, "yesterday", 0, good})
		time.sleep(150 * time.Millisecond)
		testing.expect_value(t, collector_stats(&c).refused, before + 1)
		netcode.link_close(&r.link, "done")
		game.writer_destroy(&r.writer)
	}
	// A flood: more batches than a window allows are refused (the rest were taken).
	{
		r: Raw
		testing.expect(t, raw_connect(&r, c.port))
		key := game.account_key_make()
		nonce, _ := raw_challenge(&r, key.account)
		raw_send(&r, game.Proof{game.account_sign(&key, nonce)})
		before := collector_stats(&c)
		for i in 0 ..< 30 {raw_send(&r, game.Telemetry_Batch{.Events, "2023-11-14", u64(i * len(good)), good})}
		time.sleep(500 * time.Millisecond)
		after := collector_stats(&c)
		testing.expect_value(
			t,
			after.accepted_batches - before.accepted_batches,
			BATCHES_PER_WINDOW,
		)
		testing.expect_value(t, after.refused - before.refused, 1)
		netcode.link_close(&r.link, "done")
		game.writer_destroy(&r.writer)
	}
	free_all(context.temp_allocator)
}

// A report goes through and is deleted when it is acknowledged.
@(test)
test_a_report_round_trips :: proc(t: ^testing.T) {
	lake, logs := fresh("report")
	defer os.remove_all(lake)
	defer os.remove_all(logs)
	c: Collector
	if !testing.expect(t, collector_start(&c, lake, 0)) {return}
	defer collector_stop(&c)
	testing.expect(t, report_write(logs, "the sheep ate my homework\nversion 0.26"))
	u: Uploader
	uploader_start(&u, logs, loopback(c.port), game.account_key_make(), 100 * time.Millisecond)
	@(static) col: ^Collector
	col = &c
	ok := wait_for(10, proc() -> bool {return collector_stats(col).reports == 1})
	testing.expect(t, ok, "the report never arrived")
	uploader_stop(&u)
	infos, _ := os.read_all_directory_by_path(
		fmt.tprintf("%s/reports", logs),
		context.temp_allocator,
	)
	testing.expect_value(t, len(infos), 0)
	found := false
	walk :: proc(dir: string, found: ^bool) {
		infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for info in infos {
			if info.type ==
			   .Directory {walk(info.fullpath, found)} else if strings.has_suffix(info.name, ".txt") {
				data, _ := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
				if strings.contains(string(data), "sheep ate my homework") {found^ = true}
			}
		}
	}
	walk(fmt.tprintf("%s/lake", lake), &found)
	testing.expect(t, found, "the report is not in the lake")
	free_all(context.temp_allocator)
}
