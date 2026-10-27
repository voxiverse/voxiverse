package server

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../common/game"
import "../common/telemetry"

@(private = "file")
Snapshot :: struct {
	name:     string,
	counters: Counters, // a copy (heap)
}

// counters_of: client name's counters, copied on the server's thread.
@(private = "file")
counters_of :: proc(srv: ^Server, name: string) -> Counters {
	snap := Snapshot {
		name = name,
	}
	call(srv, proc(s: ^Server, data: rawptr) {
			snap := (^Snapshot)(data)
			if c := client_by_name(s, snap.name);
			   c != nil {snap.counters = counters_clone(c.stats)}
		}, &snap)
	return snap.counters
}

@(private = "file")
config :: proc(dir: string, cheats := true) -> Config {
	return {
		seed = 26,
		generator = .Classic,
		rules = quiet_rules(),
		view_radius = 3,
		view_height = 2,
		workers = 2,
		max_players = 4,
		listen = true,
		everyone_cheats = cheats,
		save_dir = dir,
		no_sheep = true,
	}
}

@(private = "file")
pause :: proc(t: ^testing.T, a: ^Net_Client, seconds: f64) {
	net_wait(t, {a}, proc(cs: []^Net_Client) -> bool {return false}, seconds)
}

// flush_events waits until the sink has written what was emitted.
@(private = "file")
flush_events :: proc(srv: ^Server) {
	call(srv, proc(s: ^Server, data: rawptr) {telemetry.sink_flush(&s.sink)}, nil)
}

// M26's exit check, over UDP and the save: a scripted session (chat,
// commands, a teleport, placing and breaking, a sheep sheared and hit, an item
// dropped, walking) gives exactly the expected counters and the events in
// order, kept through save and load, and shown over UDP.
@(test)
test_a_scripted_session_counts_and_logs :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "stats"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	srv: Server
	if !testing.expect(t, start(&srv, config(dir), {})) {return}
	stopped := false
	defer if !stopped {stop(&srv)}
	a: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	defer net_close(&a)
	ok := net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	if !testing.expect(t, ok, "never landed") {return}
	pause(t, &a, 0.2)

	net_send(&a, game.Chat{"hello"})
	net_send(&a, game.Chat{"again"})
	net_send(&a, game.Command{"time noon"})
	net_send(&a, game.Command{"spawn"})
	pause(t, &a, 0.5)
	// Place dirt beside, break it.
	net_send(&a, game.Inventory_Request{1, {.Select, 0, 1}})
	feet := a.update.state.position
	beside := game.Block_Pos {
		i32(math.floor(feet.x)) + 1,
		i32(math.floor(feet.y)),
		i32(math.floor(feet.z)),
	}
	net_send(&a, game.Edit{1, a.seq, beside, .Dirt})
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return 1 in cs[0].results})
	testing.expect(t, ok && a.results[1].accepted, "the dirt was not placed")
	net_send(&a, game.Edit{2, a.seq, beside, .Air})
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return 2 in cs[0].results})
	testing.expect(t, ok && a.results[2].accepted, "the dirt was not broken")
	// A sheep: sheared, then hit once.
	net_send(&a, game.Command{"summon sheep"})
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return len(cs[0].entities) == 1})
	testing.expect(t, ok, "no sheep")
	id: u32
	for k in a.entities {id = k}
	net_send(&a, game.Use_Entity{id, a.seq})
	pause(t, &a, 0.3)
	net_send(&a, game.Attack{id, a.seq})
	pause(t, &a, 0.3)
	// One stone dropped; some walking.
	net_send(&a, game.Inventory_Request{2, {.Drop, 0, 0}})
	a.move = {0, 1}
	pause(t, &a, 1.5)
	a.move = {0, 0}
	pause(t, &a, 0.2)
	// A position sample is due every 10 s: make it due now.
	call(&srv, proc(s: ^Server, data: rawptr) {
			c := client_by_name(s, "a")
			s.tick = (s.tick / 300 + 1) * 300 - u64(player_id(s, c)) * 7
			stats_tick(s, c)
		}, nil)
	flush_events(&srv)

	check :: proc(t: ^testing.T, m: Counters, when_: string) {
		expect :: proc(t: ^testing.T, m: Counters, name: string, want: u64, when_: string) {
			got := stats_total(m, name)
			testing.expectf(t, got == want, "%s: %s is %d, expected %d", when_, name, got, want)
		}
		expect(t, m, "chat.lines", 2, when_)
		expect(t, m, "commands", 3, when_) // time, spawn, summon
		expect(t, m, "commands.time", 1, when_)
		expect(t, m, "teleports.spawn", 1, when_)
		expect(t, m, "blocks.placed", 1, when_)
		expect(t, m, "blocks.placed.dirt", 1, when_)
		expect(t, m, "blocks.mined.dirt", 1, when_)
		expect(t, m, "sheep.sheared", 1, when_)
		expect(t, m, "entities.hit.sheep", 1, when_)
		expect(t, m, "items.dropped.stone", 1, when_)
		testing.expectf(
			t,
			stats_total(m, "distance.walked") > 100,
			"%s: walked %d cm",
			when_,
			stats_total(m, "distance.walked"),
		)
		testing.expectf(
			t,
			stats_total(m, "time.played") >= 2,
			"%s: played %d s",
			when_,
			stats_total(m, "time.played"),
		)
	}
	mine := counters_of(&srv, "a")
	defer counters_free(&mine)
	check(t, mine, "live")
	sessions_before := stats_total(mine, "sessions")
	testing.expect_value(t, sessions_before, 1)

	// The log has the events, in the order they happened.
	text := read_log(dir)
	order := []string {
		`"k":"session_start"`,
		`"k":"chat_line"`,
		`"k":"command"`,
		`"k":"teleport"`,
		`"k":"block_placed"`,
		`"k":"block_mined"`,
	}
	for what in ([]string{`"k":"item_dropped"`, `"k":"sheep_sheared"`, `"k":"entity_hit"`}) {
		testing.expectf(t, strings.contains(text, what), "the log lacks %s", what)
	}
	// (shearing and the hit wait for their inputs, the drop does not: their order is not fixed)
	at := 0
	for what in order {
		i := strings.index(text[at:], what)
		if !testing.expectf(t, i >= 0, "the log lacks (or has out of order) %s", what) {break}
		at += i + len(what)
	}

	testing.expect(
		t,
		strings.contains(text, `"name":"time"`) && strings.contains(text, `"how":"spawn"`),
	)
	testing.expect(
		t,
		strings.contains(text, `"block":"dirt"`) && strings.contains(text, `"entity":"sheep"`),
	)

	// Over UDP: the stats page shows the server's numbers.
	net_send(&a, game.Stats_Request{filter = "chat", page = 0})
	ok = net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return len(cs[0].stats_text) > 0})
	testing.expectf(
		t,
		ok && strings.contains(a.stats_text, "chat.lines 2"),
		"the stats page said %q",
		a.stats_text,
	)

	// Kept: save and load.
	net_close(&a)
	a = {}
	time.sleep(100 * time.Millisecond)
	testing.expect(t, stop(&srv))
	stopped = true
	world_stats, _ := os.read_entire_file_from_path(
		filepath.join({home_dir(dir, 26), STATS_FILE}, context.temp_allocator) or_else "",
		context.temp_allocator,
	)
	testing.expect(
		t,
		strings.contains(string(world_stats), `"chat.lines": 2`),
		"the world's totals were not written",
	)
	if !testing.expect(t, start(&srv, config(dir), {})) {return}
	stopped = false
	again: Net_Client
	net_connect(&again, srv.host.socket.port, "a")
	defer net_close(&again)
	ok = net_wait(t, {&again}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	testing.expect(t, ok)
	loaded := counters_of(&srv, "a")
	defer counters_free(&loaded)
	testing.expect_value(t, stats_total(loaded, "sessions"), 2)
	testing.expect_value(t, stats_total(loaded, "chat.lines"), 2)
	testing.expect_value(t, stats_total(loaded, "blocks.mined.dirt"), 1)
	testing.expect(
		t,
		stats_total(loaded, "distance.walked") >= stats_total(mine, "distance.walked"),
	)
}

// read_log: the day files of dir/telemetry, joined.
@(private = "file")
read_log :: proc(dir: string) -> string {
	infos, _ := os.read_all_directory_by_path(
		filepath.join({dir, "telemetry"}, context.temp_allocator) or_else "",
		context.temp_allocator,
	)
	b := strings.builder_make(context.temp_allocator)
	for info in infos {
		data, _ := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
		strings.write_string(&b, string(data))
	}
	return strings.to_string(b)
}

// Others' stats need info.stats.others (not the default role's): an ordinary
// player asking for another's gets an empty page.
@(test)
test_others_stats_need_permission :: proc(t: ^testing.T) {
	srv: Server
	if !testing.expect(t, start(&srv, config("", cheats = false), {})) {return}
	defer stop(&srv)
	a, b: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	net_connect(&b, srv.host.socket.port, "b")
	defer net_close(&a)
	defer net_close(&b)
	ok := net_wait(
		t,
		{&a, &b},
		proc(cs: []^Net_Client) -> bool {return landed(cs[0]) && landed(cs[1])},
	)
	if !testing.expect(t, ok, "never landed") {return}
	net_send(&a, game.Stats_Request{filter = "", page = 0, of = "b"})
	net_send(&b, game.Stats_Request{filter = "", page = 0})
	ok = net_wait(t, {&a, &b}, proc(cs: []^Net_Client) -> bool {return len(cs[1].stats_text) > 0})
	testing.expect(
		t,
		ok && strings.contains(b.stats_text, "sessions 1"),
		"a player's own stats were not sent",
	)
	pause(t, &a, 0.3)
	testing.expectf(t, a.stats_text == "", "a saw b's stats: %q", a.stats_text)
}

// What a client reports is validated and rate-capped: a good entry is
// logged; a kind a client may not report, odd text, big numbers and a flood
// are refused and counted.
@(test)
test_client_reports_are_validated :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "reports"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	srv: Server
	if !testing.expect(t, start(&srv, config(dir), {})) {return}
	defer stop(&srv)
	a: Net_Client
	net_connect(&a, srv.host.socket.port, "a")
	defer net_close(&a)
	ok := net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	if !testing.expect(t, ok, "never landed") {return}
	report :: proc(kind: telemetry.Kind, text: string, n: [3]u32) -> game.Telemetry_Report {
		r := game.Telemetry_Report {
			count = 1,
		}
		r.entries[0] = {u8(kind), text, n}
		return r
	}
	net_send(&a, report(.Client_Info, "linux", {16, 70, 4000})) // good
	net_send(&a, report(.Block_Mined, "stone", {1, 0, 0})) // a kind the server alone reports
	net_send(&a, report(.Client_Overlay, "inv\x01entory", {5, 0, 0})) // a control character
	net_send(&a, report(.Client_Overlay, "inventory", {1 << 31, 0, 0})) // an absurd number
	for _ in 0 ..< 10 {net_send(&a, report(.Client_Info, "flood", {1, 1, 1}))}
	pause(t, &a, 0.5)
	refused := u64(0)
	call(&srv, proc(s: ^Server, data: rawptr) {
			if c := client_by_name(s, "a");
			   c != nil {(^u64)(data)^ = c.world.stats["telemetry.refused"] or_else 0}
		}, &refused)
	// Messages 1-6 are taken (3 bad entries refused among them); 7-14 are refused whole: 3 + 8.
	testing.expect_value(t, refused, 3 + 8)
	flush_events(&srv)
	text := read_log(dir)
	testing.expect_value(t, strings.count(text, `"k":"client_info"`), 1 + 2) // the good one and two of the flood
	testing.expect(
		t,
		strings.contains(text, `"os":"linux","view_distance":16,"fov":70,"launch_ms":4000`),
	)
	testing.expect(t, !strings.contains(text, "inv\x01"), "odd text got into the log")
}

// Many players with thousands of counters each save and load within budget.
@(test)
test_many_counters_save_and_load_fast :: proc(t: ^testing.T) {
	PLAYERS :: 200
	COUNTERS :: 3000
	records := make([]Player_Record, PLAYERS, context.temp_allocator)
	for &r, i in records {
		for k in 0 ..< COUNTERS {
			counter_add(&r.stats, fmt.tprintf("blocks.mined.block_%d_%d", i % 7, k), u64(k + 1))
		}
	}
	start := time.tick_now()
	total := 0
	for &r in records {
		json := player_json(&r)
		total += len(json)
		back, ok := player_parse(json)
		testing.expect(t, ok)
		testing.expect_value(t, len(back.stats), COUNTERS)
		counters_free(&back.stats)
	}
	elapsed := time.duration_seconds(time.tick_since(start))
	testing.expectf(
		t,
		elapsed < 8,
		"%d players of %d counters took %.1f s (%d MiB of JSON)",
		PLAYERS,
		COUNTERS,
		elapsed,
		total >> 20,
	)
	for &r in records {counters_free(&r.stats)}
	free_all(context.temp_allocator)
}
