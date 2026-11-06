package collector

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "common:game"
import "common:netcode"
import "common:telemetry"

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

// Everything here runs on one simulated network (netcode.Simnet): the collector
// is stepped by the test, the uploader's waits step it, nothing sleeps or reads
// a clock. The real-UDP round trips are in smoke/.
@(private = "file")
STEP :: 5 * time.Millisecond

@(private = "file")
COLLECTOR_PORT :: 40_000

@(private = "file")
Rig :: struct {
	net: netcode.Simnet,
	c:   Collector,
	up:  bool, // the collector is open
}

@(private = "file")
rig_open :: proc(r: ^Rig, lake: string) -> bool {
	netcode.simnet_init(&r.net)
	r.up = collector_open(&r.c, lake, COLLECTOR_PORT, &r.net)
	return r.up
}

@(private = "file")
rig_close :: proc(r: ^Rig) {
	if r.up {collector_close(&r.c)}
	r.up = false
	netcode.simnet_destroy(&r.net)
}

// rig_step: 5 ms of the network's time, and the collector's pass.
@(private = "file")
rig_step :: proc(r: ^Rig) {
	r.net.now = time.tick_add(r.net.now, STEP)
	if r.up {collector_step(&r.c, r.net.now)}
}

@(private = "file")
rig_idle :: proc(data: rawptr) {rig_step((^Rig)(data))}

// rig_run steps for `seconds` of the network's time.
@(private = "file")
rig_run :: proc(r: ^Rig, seconds: f64) {
	for _ in 0 ..< int(seconds * f64(time.Second) / f64(STEP)) {rig_step(r)}
}

@(private = "file")
rig_uploader :: proc(r: ^Rig, u: ^Uploader, logs: string, key: game.Account_Key) {
	uploader_open(u, logs, loopback(COLLECTOR_PORT), key, 100 * time.Millisecond, &r.net)
	u.idle, u.idle_data = rig_idle, r
}

// rig_stats: the collector's counters.
@(private = "file")
rig_stats :: proc(r: ^Rig) -> Collector_Stats {return collector_stats(&r.c)}

// Steps until the collector has refused `n` more batches than `before`.
@(private = "file")
wait_refused :: proc(r: ^Rig, before, n: u64) -> bool {
	for _ in 0 ..< 4000 {
		if rig_stats(r).refused >= before + n {return true}
		rig_step(r)
	}
	return rig_stats(r).refused >= before + n
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
	r: Rig
	if !testing.expect(t, rig_open(&r, lake)) {return}
	defer rig_close(&r)
	key := game.account_key_make()
	u: Uploader
	rig_uploader(&r, &u, logs, key)
	upload_pass(&u)
	acked, _ := uploader_counts(&u)
	testing.expect(t, acked >= 1, "the log never arrived")
	testing.expect_value(t, rig_stats(&r).accepted_lines, 50)
	uploader_close(&u)
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
	rig_uploader(&r, &u2, logs, key)
	upload_pass(&u2)
	testing.expect(t, rig_stats(&r).duplicates >= 1, "a second send was not recognised")
	uploader_close(&u2)
	again, _ := read_lake(lake)
	testing.expect_value(t, strings.count(again, "\n"), 50)

	// A restarted collector remembers (its cursors are on disk).
	collector_close(&r.c)
	r.up = collector_open(&r.c, lake, COLLECTOR_PORT, &r.net)
	if !testing.expect(t, r.up) {return}
	os.remove(fmt.tprintf("%s/upload.cursor", logs))
	u3: Uploader
	rig_uploader(&r, &u3, logs, key)
	upload_pass(&u3)
	testing.expect(t, rig_stats(&r).duplicates >= 1, "a restarted collector wrote a batch twice")
	uploader_close(&u3)
	final, _ := read_lake(lake)
	testing.expect_value(t, strings.count(final, "\n"), 50)
	free_all(context.temp_allocator)
}

// The collector down: the log waits and goes when it is up, exactly once;
// with nothing to send, nothing is sent (no connection at all).
@(test)
test_the_spool_survives_a_collector_that_is_down :: proc(t: ^testing.T) {
	lake, logs := fresh("down")
	defer os.remove_all(lake)
	defer os.remove_all(logs)
	r: Rig
	netcode.simnet_init(&r.net)
	defer rig_close(&r)
	key := game.account_key_make()
	u: Uploader
	rig_uploader(&r, &u, logs, key)
	defer uploader_close(&u)
	upload_pass(&u) // nothing to send: no pass
	_, passes := uploader_counts(&u)
	testing.expect_value(t, passes, 0)
	text := events(20)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/2023-11-14.jsonl", logs), transmute([]u8)text) == nil,
	)
	upload_pass(&u) // it tries and nobody answers
	acked, _ := uploader_counts(&u)
	testing.expect_value(t, acked, 0)
	// The collector comes up on that port: the log goes.
	r.up = collector_open(&r.c, lake, COLLECTOR_PORT, &r.net)
	if !testing.expect(t, r.up) {return}
	upload_pass(&u)
	testing.expect_value(t, rig_stats(&r).accepted_lines, 20)
	// More is written meanwhile: only the new lines go.
	more := events(5)
	f, _ := os.open(fmt.tprintf("%s/2023-11-14.jsonl", logs), {.Write, .Append})
	os.write_string(f, more)
	os.close(f)
	upload_pass(&u)
	testing.expect_value(t, rig_stats(&r).accepted_lines, 25)
	got, _ := read_lake(lake)
	testing.expect_value(t, strings.count(got, "\n"), 25)
	free_all(context.temp_allocator)
}

@(private = "file")
Raw :: struct {
	link:   netcode.Link,
	writer: game.Writer,
	rig:    ^Rig,
}

@(private = "file")
raw_connect :: proc(r: ^Raw, rig: ^Rig) -> bool {
	r.rig = rig
	game.writer_init(&r.writer)
	if netcode.link_connect(&r.link, loopback(COLLECTOR_PORT), "", rig.net.now, sim = &rig.net) !=
	   nil {return false}
	for r.link.state != .Connected {
		netcode.link_update(&r.link, rig.net.now)
		if r.link.state == .Failed {return false}
		rig_step(rig)
	}
	return true
}

@(private = "file")
raw_send :: proc(r: ^Raw, m: game.Client_Message) {
	clear(&r.writer.buf)
	game.encode_client(&r.writer, m)
	netcode.link_send(&r.link, r.writer.buf[:], true)
	netcode.link_flush(&r.link, r.rig.net.now)
}

// raw_challenge: Hello, and the nonce the collector answers with.
@(private = "file")
raw_challenge :: proc(r: ^Raw, account: game.Account) -> (nonce: game.Nonce, ok: bool) {
	raw_send(r, game.Hello{game.PROTOCOL_VERSION, account, "", 0})
	scratch := new(game.Block_Array)
	defer free(scratch)
	got := make([dynamic][]u8, context.temp_allocator)
	for _ in 0 ..< 600 { 	// 3 s of the network's time
		netcode.link_update(&r.link, r.rig.net.now)
		clear(&got)
		netcode.link_receive(&r.link, &got)
		for data in got {
			defer netcode.link_free(&r.link, data)
			if m, decoded := game.decode_server(data, scratch); decoded {
				if c, is_c := m.(game.Challenge); is_c {return c.nonce, true}
			}
		}
		netcode.link_flush(&r.link, r.rig.net.now)
		rig_step(r.rig)
	}
	return
}

@(private = "file")
raw_close :: proc(r: ^Raw) {
	netcode.link_close(&r.link, "done")
	game.writer_destroy(&r.writer)
}

// What a collector must refuse: a forged proof, batches before a proof, a line
// that is no event, an unknown kind, a bad day, a flood of batches.
@(test)
test_the_collector_refuses_what_it_should :: proc(t: ^testing.T) {
	lake, logs := fresh("refuse")
	defer os.remove_all(lake)
	defer os.remove_all(logs)
	rig: Rig
	if !testing.expect(t, rig_open(&rig, lake)) {return}
	defer rig_close(&rig)
	good := events(1)

	// A proof signed by another key.
	{
		r: Raw
		testing.expect(t, raw_connect(&r, &rig))
		mine, other := game.account_key_make(), game.account_key_make()
		nonce, ok := raw_challenge(&r, mine.account)
		testing.expect(t, ok)
		raw_send(&r, game.Proof{game.account_sign(&other, nonce)})
		raw_send(&r, game.Telemetry_Batch{.Events, "2023-11-14", 0, good})
		rig_run(&rig, 0.3)
		testing.expect_value(t, rig_stats(&rig).forged, 1)
		testing.expect_value(t, rig_stats(&rig).accepted_lines, 0)
		raw_close(&r)
	}
	// A batch before any proof.
	{
		r: Raw
		testing.expect(t, raw_connect(&r, &rig))
		raw_send(&r, game.Telemetry_Batch{.Events, "2023-11-14", 0, good})
		rig_run(&rig, 0.2)
		testing.expect_value(t, rig_stats(&rig).accepted_lines, 0)
		raw_close(&r)
	}
	// Proved: bad lines, an unknown kind, a bad day; then good ones; then a flood.
	{
		r: Raw
		testing.expect(t, raw_connect(&r, &rig))
		key := game.account_key_make()
		nonce, ok := raw_challenge(&r, key.account)
		testing.expect(t, ok)
		raw_send(&r, game.Proof{game.account_sign(&key, nonce)})
		before := rig_stats(&rig).refused
		raw_send(&r, game.Telemetry_Batch{.Events, "2023-11-14", 0, "this is not an event\n"})
		testing.expect(t, wait_refused(&rig, before, 1))
		testing.expect_value(t, rig_stats(&rig).refused, before + 1) // (and the peer is dropped)
		raw_close(&r)
	}
	for bad in ([]string{"{\"t\":1,\"k\":\"made_up_kind\"}\n", "{\"t\":1,\"tick\":0,\"k\":\"block_mined\",\"block\":\"x\x01y\"}\n", "{\"k\":\"block_mined\"}\n"}) {
		r: Raw
		testing.expect(t, raw_connect(&r, &rig))
		key := game.account_key_make()
		nonce, _ := raw_challenge(&r, key.account)
		raw_send(&r, game.Proof{game.account_sign(&key, nonce)})
		before := rig_stats(&rig).refused
		raw_send(&r, game.Telemetry_Batch{.Events, "2023-11-14", 0, bad})
		testing.expect(t, wait_refused(&rig, before, 1))
		testing.expectf(t, rig_stats(&rig).refused == before + 1, "%q was not refused", bad)
		raw_close(&r)
	}
	{
		r: Raw
		testing.expect(t, raw_connect(&r, &rig))
		key := game.account_key_make()
		nonce, _ := raw_challenge(&r, key.account)
		raw_send(&r, game.Proof{game.account_sign(&key, nonce)})
		before := rig_stats(&rig).refused
		raw_send(&r, game.Telemetry_Batch{.Events, "yesterday", 0, good})
		testing.expect(t, wait_refused(&rig, before, 1))
		testing.expect_value(t, rig_stats(&rig).refused, before + 1)
		raw_close(&r)
	}
	// A flood: more batches than a window allows are refused (the rest were taken).
	{
		r: Raw
		testing.expect(t, raw_connect(&r, &rig))
		key := game.account_key_make()
		nonce, _ := raw_challenge(&r, key.account)
		raw_send(&r, game.Proof{game.account_sign(&key, nonce)})
		before := rig_stats(&rig)
		for i in 0 ..< 30 {raw_send(&r, game.Telemetry_Batch{.Events, "2023-11-14", u64(i * len(good)), good})}
		testing.expect(t, wait_refused(&rig, before.refused, 1))
		after := rig_stats(&rig)
		testing.expect_value(
			t,
			after.accepted_batches - before.accepted_batches,
			BATCHES_PER_WINDOW,
		)
		testing.expect_value(t, after.refused - before.refused, 1)
		raw_close(&r)
	}
	free_all(context.temp_allocator)
}

// A report goes through and is deleted when it is acknowledged.
@(test)
test_a_report_round_trips :: proc(t: ^testing.T) {
	lake, logs := fresh("report")
	defer os.remove_all(lake)
	defer os.remove_all(logs)
	r: Rig
	if !testing.expect(t, rig_open(&r, lake)) {return}
	defer rig_close(&r)
	testing.expect(t, report_write(logs, "the sheep ate my homework\nversion 0.26"))
	u: Uploader
	rig_uploader(&r, &u, logs, game.account_key_make())
	upload_pass(&u)
	testing.expect_value(t, rig_stats(&r).reports, 1)
	uploader_close(&u)
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

// ---- developer chat

// raw_prove: connects and proves `key`.
@(private = "file")
raw_prove :: proc(r: ^Raw, rig: ^Rig, key: ^game.Account_Key) -> bool {
	raw_connect(r, rig) or_return
	nonce := raw_challenge(r, key.account) or_return
	raw_send(r, game.Proof{game.account_sign(key, nonce)})
	return true
}

// raw_answer steps until the collector sends a message of the wanted kind; its
// strings are copied to the temp allocator (the packet is freed).
@(private = "file")
raw_answer :: proc(r: ^Raw, $T: typeid) -> (v: T, ok: bool) {
	scratch := new(game.Block_Array)
	defer free(scratch)
	got := make([dynamic][]u8, context.temp_allocator)
	for _ in 0 ..< 600 {
		netcode.link_update(&r.link, r.rig.net.now)
		clear(&got)
		netcode.link_receive(&r.link, &got)
		for data in got {
			defer netcode.link_free(&r.link, data)
			m, decoded := game.decode_server(data, scratch)
			if !decoded {continue}
			if x, is_t := m.(T); is_t {
				v, ok = x, true
				when T == game.Dev_Ack {
					v.reason = strings.clone(x.reason, context.temp_allocator)
				} else when T == game.Dev_Replies {
					for &e in v.entries[:v.count] {
						e.id = strings.clone(e.id, context.temp_allocator)
						e.text = strings.clone(e.text, context.temp_allocator)
						e.link = strings.clone(e.link, context.temp_allocator)
					}
				}
			}
		}
		if ok {return}
		netcode.link_flush(&r.link, r.rig.net.now)
		rig_step(r.rig)
	}
	return
}

@(private = "file")
count_files :: proc(dir: string) -> int {
	infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	return len(infos)
}

@(private = "file")
write_reply :: proc(dir, name, body: string) {
	os.make_directory_all(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, name), transmute([]u8)body)
}

// An admin's message is stored once however often it is sent; a non-admin's is
// refused and nothing is written; an oversized one is refused.
@(test)
test_devchat_messages :: proc(t: ^testing.T) {
	lake, logs := fresh("devchat_in")
	defer os.remove_all(lake)
	defer os.remove_all(logs)
	rig: Rig
	// The admins file exists before the collector starts, and changes later.
	admin, other := game.account_key_make(), game.account_key_make()
	os.make_directory_all(lake)
	_ = os.write_entire_file(
		fmt.tprintf("%s/admins.cfg", lake),
		transmute([]u8)fmt.tprintf(
			"# the owner\n%s  # me\nnot a key\n",
			game.account_text(admin.account),
		),
	)
	if !testing.expect(t, rig_open(&rig, lake)) {return}
	defer rig_close(&rig)
	inbox := fmt.tprintf("%s/devchat/%s/in", lake, game.account_text(admin.account))

	r: Raw
	if !testing.expect(t, raw_prove(&r, &rig, &admin)) {return}
	msg := game.Dev_Message {
		id       = 0xabcd1234,
		text     = "the sky is square \"here\"\nüber",
		version  = "0.26",
		universe = "Home",
		world    = "A1",
		has_pos  = true,
		pos      = {1, -2, 3},
		has_tick = true,
		tick     = 99,
	}
	raw_send(&r, msg)
	ack, ok := raw_answer(&r, game.Dev_Ack)
	testing.expect(t, ok && ack.ok && ack.id == msg.id, "the message was not acknowledged")
	raw_send(&r, msg) // the ack was "lost": sent again
	ack, ok = raw_answer(&r, game.Dev_Ack)
	testing.expect(t, ok && ack.ok, "the resend was not acknowledged")
	testing.expect_value(t, count_files(inbox), 1)
	testing.expect_value(t, rig_stats(&rig).dev_stored, 1)
	testing.expect_value(t, rig_stats(&rig).dev_duplicates, 1)
	infos, _ := os.read_all_directory_by_path(inbox, context.temp_allocator)
	if len(infos) == 1 {
		testing.expect(t, strings.has_suffix(infos[0].name, "-abcd1234.json"), infos[0].name)
		data, _ := os.read_entire_file_from_path(infos[0].fullpath, context.temp_allocator)
		for want in ([]string{`"text":"the sky is square \"here\"\nüber"`, `"version":"0.26"`, `"universe":"Home"`, `"world":"A1"`, `"position":[1,-2,3]`, `"tick":99`}) {
			testing.expectf(
				t,
				strings.contains(string(data), want),
				"missing %s in %s",
				want,
				data,
			)
		}
	}
	// A second message is a second file.
	msg.id = 7
	raw_send(&r, msg)
	_, ok = raw_answer(&r, game.Dev_Ack)
	testing.expect(t, ok)
	testing.expect_value(t, count_files(inbox), 2)
	raw_close(&r)

	// Not an admin: refused with a reason, nothing written.
	r2: Raw
	if !testing.expect(t, raw_prove(&r2, &rig, &other)) {return}
	raw_send(&r2, msg)
	ack, ok = raw_answer(&r2, game.Dev_Ack)
	testing.expect(
		t,
		ok && !ack.ok && ack.reason != "",
		"a non-admin was not refused with a reason",
	)
	testing.expect_value(t, count_files(fmt.tprintf("%s/devchat", lake)), 1) // (the admin's only)
	testing.expect_value(t, rig_stats(&rig).dev_refused, 1)
	// ... until the file names it.
	f, _ := os.open(fmt.tprintf("%s/admins.cfg", lake), {.Write, .Append})
	os.write_string(f, fmt.tprintf("%s\n", game.account_text(other.account)))
	os.close(f)
	rig_run(&rig, 1.5)
	raw_send(&r2, msg)
	ack, ok = raw_answer(&r2, game.Dev_Ack)
	testing.expect(t, ok && ack.ok, "a newly listed admin was not heard")
	raw_close(&r2)

	// Over the limit: refused (the message is invalid on the wire), nothing written.
	r3: Raw
	if !testing.expect(t, raw_prove(&r3, &rig, &admin)) {return}
	before := rig_stats(&rig).refused
	big := game.Dev_Message {
		id   = 1,
		text = strings.repeat("x", game.MAX_DEV_TEXT + 1, context.temp_allocator),
	}
	clear(&r3.writer.buf)
	// (encoded by hand: the encoder does not stop an oversized text)
	game.encode_client(&r3.writer, big)
	netcode.link_send(&r3.link, r3.writer.buf[:], true)
	netcode.link_flush(&r3.link, rig.net.now)
	testing.expect(t, wait_refused(&rig, before, 1), "an oversized message was not refused")
	testing.expect_value(t, count_files(inbox), 2)
	raw_close(&r3)
	// ... and exactly the limit is taken.
	r4: Raw
	if !testing.expect(t, raw_prove(&r4, &rig, &admin)) {return}
	raw_send(
		&r4,
		game.Dev_Message {
			id = 2,
			text = strings.repeat("y", game.MAX_DEV_TEXT, context.temp_allocator),
		},
	)
	ack, ok = raw_answer(&r4, game.Dev_Ack)
	testing.expect(t, ok && ack.ok, "a message of the limit's size was refused")
	raw_close(&r4)
	free_all(context.temp_allocator)
}

// Replies arrive in name order, only after after_id, and a malformed file is skipped.
@(test)
test_devchat_replies :: proc(t: ^testing.T) {
	lake, logs := fresh("devchat_out")
	defer os.remove_all(lake)
	defer os.remove_all(logs)
	rig: Rig
	admin, other := game.account_key_make(), game.account_key_make()
	os.make_directory_all(lake)
	_ = os.write_entire_file(
		fmt.tprintf("%s/admins.cfg", lake),
		transmute([]u8)game.account_text(admin.account),
	)
	if !testing.expect(t, rig_open(&rig, lake)) {return}
	defer rig_close(&rig)
	out := fmt.tprintf("%s/devchat/%s/out", lake, game.account_text(admin.account))
	write_reply(out, "0003.json", `{"id":"0003","time":3000,"text":"third"}`)
	write_reply(
		out,
		"0001.json",
		`{"id":"0001","time":1000,"text":"first","link":"https://example.org/a"}`,
	)
	write_reply(out, "0002.json", `{"id":"0002","time":2000,"text":"second ü"}`)
	write_reply(out, "0002b.json", `{"id":"0002b","time":2500,`) // cut off
	write_reply(out, "0002c.json", `{"id":"wrong","time":2600,"text":"id is not the name"}`)
	write_reply(out, "0002d.json", `{"id":"0002d","time":2700,"text":""}`)
	write_reply(out, "notes.txt", "not a reply")

	r: Raw
	if !testing.expect(t, raw_prove(&r, &rig, &admin)) {return}
	raw_send(&r, game.Dev_Fetch{""})
	all, ok := raw_answer(&r, game.Dev_Replies)
	if testing.expect(t, ok) && testing.expect_value(t, all.count, 3) {
		testing.expect_value(t, all.entries[0].id, "0001")
		testing.expect_value(t, all.entries[0].link, "https://example.org/a")
		testing.expect_value(t, all.entries[0].time, 1000)
		testing.expect_value(t, all.entries[1].text, "second ü")
		testing.expect_value(t, all.entries[2].id, "0003")
	}
	raw_send(&r, game.Dev_Fetch{"0001"})
	rest, ok2 := raw_answer(&r, game.Dev_Replies)
	if testing.expect(t, ok2) && testing.expect_value(t, rest.count, 2) {
		testing.expect_value(t, rest.entries[0].id, "0002")
		testing.expect_value(t, rest.entries[1].id, "0003")
	}
	raw_send(&r, game.Dev_Fetch{"0003"})
	none, ok3 := raw_answer(&r, game.Dev_Replies)
	testing.expect(t, ok3 && none.count == 0, "replies came after the last one")
	raw_close(&r)

	// Another account sees none of them.
	r2: Raw
	if !testing.expect(t, raw_prove(&r2, &rig, &other)) {return}
	raw_send(&r2, game.Dev_Fetch{""})
	nobody, ok4 := raw_answer(&r2, game.Dev_Replies)
	testing.expect(t, ok4 && nobody.count == 0, "a non-admin was sent replies")
	raw_close(&r2)
	free_all(context.temp_allocator)
}

// The game's chat (devchat_client.odin) on the simulated network: what the
// player writes is delivered once, also when it was written offline; replies
// arrive and are kept in the file across a restart.
@(private = "file")
rig_chat :: proc(r: ^Rig, c: ^Chat, path: string, key: game.Account_Key) {
	chat_open(c, path, loopback(COLLECTOR_PORT), key, &r.net)
	c.idle, c.idle_data = rig_idle, r
}

@(private = "file")
chat_admin_lake :: proc(name: string) -> (lake, file: string, admin: game.Account_Key) {
	lake, _ = fresh(name)
	file = fmt.tprintf("build/test/%s_devchat.jsonl", name)
	os.remove(file)
	admin = game.account_key_make()
	os.make_directory_all(lake)
	_ = os.write_entire_file(
		fmt.tprintf("%s/admins.cfg", lake),
		transmute([]u8)game.account_text(admin.account),
	)
	return
}

@(test)
test_chat_delivers_once :: proc(t: ^testing.T) {
	lake, file, admin := chat_admin_lake("chat_once")
	defer os.remove_all(lake)
	defer os.remove(file)
	rig: Rig
	if !testing.expect(t, rig_open(&rig, lake)) {return}
	defer rig_close(&rig)
	c: Chat
	rig_chat(&rig, &c, file, admin)
	defer chat_close(&c)
	inbox := fmt.tprintf("%s/devchat/%s/in", lake, game.account_text(admin.account))

	testing.expect(t, !chat_send(&c, "   ", {}), "an empty message was taken")
	testing.expect(
		t,
		chat_send(
			&c,
			"the sky is square",
			{version = "0.26", world = "A1", has_pos = true, pos = {1, 2, 3}},
		),
	)
	chat_pass(&c)
	entries, status, waiting, _ := chat_view(&c)
	testing.expect_value(t, status, Chat_Status.Connected)
	testing.expect_value(t, waiting, 0)
	testing.expect(t, len(entries) == 1 && entries[0].sent, "the message was not marked sent")
	testing.expect_value(t, count_files(inbox), 1)
	chat_pass(&c) // nothing waits: nothing is sent again
	testing.expect_value(t, count_files(inbox), 1)
	free_all(context.temp_allocator)
}

@(test)
test_chat_waits_while_offline :: proc(t: ^testing.T) {
	lake, file, admin := chat_admin_lake("chat_offline")
	defer os.remove_all(lake)
	defer os.remove(file)
	rig: Rig
	netcode.simnet_init(&rig.net) // the collector is down
	defer rig_close(&rig)
	c: Chat
	rig_chat(&rig, &c, file, admin)
	testing.expect(t, chat_send(&c, "written offline", {}))
	chat_pass(&c)
	_, status, waiting, _ := chat_view(&c)
	testing.expect_value(t, status, Chat_Status.Offline)
	testing.expect_value(t, waiting, 1)
	chat_close(&c) // the game is closed while offline...

	rig.up = collector_open(&rig.c, lake, COLLECTOR_PORT, &rig.net)
	if !testing.expect(t, rig.up) {return}
	rig_chat(&rig, &c, file, admin) // ... and started again later
	defer chat_close(&c)
	_, _, waiting, _ = chat_view(&c)
	testing.expect_value(t, waiting, 1)
	chat_pass(&c)
	entries, status2, waiting2, _ := chat_view(&c)
	testing.expect_value(t, status2, Chat_Status.Connected)
	testing.expect_value(t, waiting2, 0)
	testing.expect(t, len(entries) == 1 && entries[0].text == "written offline")
	testing.expect_value(
		t,
		count_files(fmt.tprintf("%s/devchat/%s/in", lake, game.account_text(admin.account))),
		1,
	)
	free_all(context.temp_allocator)
}

@(test)
test_chat_replies_survive_a_restart :: proc(t: ^testing.T) {
	lake, file, admin := chat_admin_lake("chat_replies")
	defer os.remove_all(lake)
	defer os.remove(file)
	rig: Rig
	if !testing.expect(t, rig_open(&rig, lake)) {return}
	defer rig_close(&rig)
	out := fmt.tprintf("%s/devchat/%s/out", lake, game.account_text(admin.account))
	// More than one page (MAX_DEV_REPLIES), to see the fetch go on.
	for i in 0 ..< game.MAX_DEV_REPLIES + 2 {
		write_reply(
			out,
			fmt.tprintf("%04d.json", i),
			fmt.tprintf(
				`{{"id":"%04d","time":%d,"text":"reply %d","link":"https://example.org/%d"}}`,
				i,
				1000 + i,
				i,
				i,
			),
		)
	}
	c: Chat
	rig_chat(&rig, &c, file, admin)
	chat_pass(&c)
	entries, _, _, _ := chat_view(&c)
	testing.expect_value(t, len(entries), game.MAX_DEV_REPLIES + 2)
	testing.expect_value(t, chat_replies(&c), u64(game.MAX_DEV_REPLIES + 2))
	if len(entries) > 0 {
		testing.expect_value(t, entries[0].text, "reply 0")
		testing.expect_value(t, entries[0].link, "https://example.org/0")
		testing.expect(t, !entries[0].from_me)
	}
	chat_close(&c)

	rig_chat(&rig, &c, file, admin) // a restart: read back from the file
	defer chat_close(&c)
	entries, _, _, _ = chat_view(&c)
	testing.expect_value(t, len(entries), game.MAX_DEV_REPLIES + 2)
	write_reply(out, "9999.json", `{"id":"9999","time":5000,"text":"newest"}`)
	chat_pass(&c) // only what came after
	entries, _, _, _ = chat_view(&c)
	testing.expect_value(t, len(entries), game.MAX_DEV_REPLIES + 3)
	if len(entries) > 0 {testing.expect_value(t, entries[len(entries) - 1].text, "newest")}
	free_all(context.temp_allocator)
}
