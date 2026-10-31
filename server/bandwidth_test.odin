package server

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

import "common:game"
import "common:netcode"

// M39's bandwidth benchmark. A stepped session is deterministic, so the bytes
// it moves are too, on every OS: the numbers are exact, not statistical. Two
// scenarios run on the stepped server with the mirror client of
// determinism_test.odin, counted by the pipe's traffic counters in both
// directions, and are compared with assets/baselines/net/bandwidth.txt.
// Rewrite the baseline with -define:VX_BANDWIDTH_ACCEPT=true.

BANDWIDTH_TICKS :: 6500 // past the water (2500), the farm (3000), the flight (4000) and the rocket (6000)
CROWD_TICKS :: 905 // five summons of 20 (the command's cap), then 900 ticks standing among 100 sheep
BANDWIDTH_ACCEPT :: #config(VX_BANDWIDTH_ACCEPT, false)
BANDWIDTH_FILE :: "assets/baselines/net/bandwidth.txt"

Bandwidth :: struct {
	name:             string,
	ticks:            int,
	root:             u64, // the stepped server's hash at the last tick
	server_to_client: int,
	client_to_server: int,
	kinds:            [dynamic]Kind_Bytes,
	inputs:           int, // Input messages the client sent
}

Kind_Bytes :: struct {
	name:     string,
	messages: int,
	bytes:    int,
}

bandwidth_destroy :: proc(b: ^Bandwidth) {
	for k in b.kinds {delete(k.name)}
	delete(b.kinds)
}

// bandwidth_run plays a scenario and returns what crossed the pipe.
bandwidth_run :: proc(t: ^testing.T, name: string) -> (b: Bandwidth, ok: bool) {
	sess := new(Session)
	defer free(sess)
	crowd := name == "crowd"
	if !testing.expect(t, session_start(sess, {}, false, no_sheep = crowd)) {return}
	defer session_stop(sess)
	if !session_land(t, sess) {return}
	sess.script_at = sess.h.srv.tick
	ticks := CROWD_TICKS if crowd else BANDWIDTH_TICKS
	h: State_Hash
	for i in 0 ..< ticks {
		if crowd && i >= 1 && i <= 5 {mirror_send(&sess.mirror, game.Command{"summon sheep 20"})}
		h = session_step(sess, !crowd)
	}
	traffic := game.pipe_traffic(&sess.h.pipe)
	b = {
		name  = name,
		ticks = ticks,
		root  = h.root,
	}
	for side in game.Side {
		for kind in 1 ..< 256 {
			n, bytes := traffic[side].messages[kind], traffic[side].bytes[kind]
			if n == 0 {continue}
			if side == .Server {b.server_to_client += bytes} else {b.client_to_server += bytes}
			label := game.message_kind_name(side, u8(kind))
			append(
				&b.kinds,
				Kind_Bytes{fmt.aprintf("%s:%s", "s" if side == .Server else "c", label), n, bytes},
			)
			if side == .Client && label == "input" {b.inputs = n}
		}
	}
	return b, true
}

bandwidth_text :: proc(runs: []Bandwidth) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&sb, "bandwidth 1")
	for r in runs {
		fmt.sbprintfln(&sb, "scenario %s ticks=%d root=%016x", r.name, r.ticks, r.root)
		fmt.sbprintfln(&sb, "server_to_client %d", r.server_to_client)
		fmt.sbprintfln(&sb, "client_to_server %d", r.client_to_server)
		fmt.sbprintfln(&sb, "inputs %d", r.inputs)
		for k in r.kinds {fmt.sbprintfln(&sb, "kind %s %d %d", k.name, k.messages, k.bytes)}
	}
	return strings.to_string(sb)
}

// Committed is one scenario of the baseline file.
Committed :: struct {
	root:             string,
	server_to_client: int,
	client_to_server: int,
	inputs:           int,
}

bandwidth_parse :: proc(text: string, name: string) -> (c: Committed, found: bool) {
	lines := strings.split_lines(text, context.temp_allocator)
	in_scenario := false
	for line in lines {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 {continue}
		switch f[0] {
		case "scenario":
			in_scenario = len(f) > 1 && f[1] == name
			if in_scenario {
				found = true
				for part in f[2:] {
					if strings.has_prefix(part, "root=") {c.root = part[5:]}
				}
			}
		case "server_to_client":
			if in_scenario {c.server_to_client, _ = strconv.parse_int(f[1])}
		case "client_to_server":
			if in_scenario {c.client_to_server, _ = strconv.parse_int(f[1])}
		case "inputs":
			if in_scenario {c.inputs, _ = strconv.parse_int(f[1])}
		}
	}
	return
}

@(private = "file")
compare :: proc(t: ^testing.T, name: string) {
	run, ok := bandwidth_run(t, name)
	if !ok {return}
	defer bandwidth_destroy(&run)
	data, err := os.read_entire_file_from_path(BANDWIDTH_FILE, context.temp_allocator)
	if !testing.expectf(
		t,
		err == nil,
		"%s is missing: run with -define:VX_BANDWIDTH_ACCEPT=true",
		BANDWIDTH_FILE,
	) {return}
	want, found := bandwidth_parse(string(data), name)
	if !testing.expectf(t, found, "no scenario %s in %s", name, BANDWIDTH_FILE) {return}
	testing.expectf(
		t,
		run.server_to_client <= want.server_to_client,
		"%s: server to client %d bytes, the baseline %d",
		name,
		run.server_to_client,
		want.server_to_client,
	)
	allowance := want.client_to_server + 5 * run.inputs + 8
	testing.expectf(
		t,
		run.client_to_server <= allowance,
		"%s: client to server %d bytes, the baseline %d plus the acks (allowing %d)",
		name,
		run.client_to_server,
		want.client_to_server,
		allowance,
	)
	root := fmt.tprintf("%016x", run.root)
	testing.expectf(
		t,
		root == want.root,
		"%s: the root is %s, the baseline %s: the protocol changed simulated state",
		name,
		root,
		want.root,
	)
}

@(test)
test_bandwidth_session :: proc(t: ^testing.T) {
	when !BANDWIDTH_ACCEPT {compare(t, "session")}
}

@(test)
test_bandwidth_crowd :: proc(t: ^testing.T) {
	when !BANDWIDTH_ACCEPT {compare(t, "crowd")}
}

// test_bandwidth_accept rewrites the file from both scenarios (run it alone:
// -define:VX_BANDWIDTH_ACCEPT=true -define:ODIN_TEST_NAMES=server.test_bandwidth_accept).
@(test)
test_bandwidth_accept :: proc(t: ^testing.T) {
	when BANDWIDTH_ACCEPT {
		a, ok_a := bandwidth_run(t, "session")
		b, ok_b := bandwidth_run(t, "crowd")
		if !ok_a || !ok_b {return}
		defer bandwidth_destroy(&a)
		defer bandwidth_destroy(&b)
		runs := [2]Bandwidth{a, b}
		text := bandwidth_text(runs[:])
		if err := os.write_entire_file(BANDWIDTH_FILE, text); err != nil {
			testing.expectf(t, false, "cannot write %s: %v", BANDWIDTH_FILE, err)
		}
	}
}

// A snapshot part is one unreliable packet: it must fit one netcode record.
@(test)
test_snapshot_part_fits :: proc(t: ^testing.T) {
	testing.expect(
		t,
		game.SNAPSHOT_PART_BYTES <= netcode.FRAGMENT_SIZE,
		"a snapshot part is longer than a netcode fragment",
	)
	testing.expect(t, game.SNAPSHOT_PARTS * game.SNAPSHOT_PART_BYTES <= 9500)
}
