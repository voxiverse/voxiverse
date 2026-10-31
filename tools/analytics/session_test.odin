package analytics

import "core:strings"
import "core:testing"

import "common:telemetry"

// A recorded session of two players: the file the server writes
// (server/session_log.odin) read as a report.
@(private = "file")
session_text :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	T0 :: i64(1_700_000_000_000)
	n := 0
	add :: proc(b: ^strings.Builder, n: ^int, e: telemetry.Event) {
		e := e
		e.time_ms = T0 + i64(n^) * 1000
		n^ += 1
		telemetry.write_event(b, e)
	}
	SERVER :: telemetry.NO_ACTOR
	add(&b, &n, {kind = .Server_Start, actor = SERVER, n = {8, 0, 0}})
	add(
		&b,
		&n,
		{kind = .Client_Info, actor = 0, text = telemetry.short("linux"), n = {8, 90, 3000}},
	)
	add(
		&b,
		&n,
		{
			kind = .Client_Hardware,
			actor = 0,
			text = telemetry.short("Test GPU 3000"),
			n = {1920, 1080, 0},
		},
	)
	add(&b, &n, {kind = .Client_Driver, actor = 0, text = telemetry.short("Mesa 99.1"), n = {}})
	add(&b, &n, {kind = .Client_Frames, actor = 0, n = {5000, 9000, 40000}})
	add(&b, &n, {kind = .Client_Frames, actor = 0, n = {7000, 12000, 60000}})
	add(
		&b,
		&n,
		{
			kind = .Client_Hardware,
			actor = 1,
			text = telemetry.short("Other GPU"),
			n = {1280, 720, 0},
		},
	)
	for ping in ([]i64{20, 25, 80}) {
		add(&b, &n, {kind = .Ping_Sample, actor = 0, n = {ping, 0, 0}})
	}
	// Player 0 fires the shotgun five times, three hit; kills player 1 once, 1.5 s after the first hit.
	for hit in ([]i64{1, 1, 0, 0, 1}) {
		add(
			&b,
			&n,
			{kind = .Shot_Fired, actor = 0, text = telemetry.short("shotgun"), n = {hit, 0, 0}},
		)
	}
	add(
		&b,
		&n,
		{kind = .Damage_Dealt, actor = 0, text = telemetry.short("shotgun"), n = {120, 1, 0}},
	)
	add(
		&b,
		&n,
		{kind = .Damage_Dealt, actor = 0, text = telemetry.short("shotgun"), n = {80, 1, 0}},
	)
	add(&b, &n, {kind = .Kill, actor = 0, text = telemetry.short("shotgun"), n = {1500, 1, 0}})
	add(&b, &n, {kind = .Death, actor = 1, text = telemetry.short("weapon"), n = {}})
	add(&b, &n, {kind = .Shot_Fired, actor = 1, text = telemetry.short("pistol"), n = {0, 0, 0}})
	add(&b, &n, {kind = .Grapple_Used, actor = 0})
	add(&b, &n, {kind = .Jump, actor = 0, text = telemetry.short("ground")})
	add(&b, &n, {kind = .Jump, actor = 0, text = telemetry.short("air")})
	add(&b, &n, {kind = .Bandwidth_Sample, actor = 0, n = {61440, 30720, 3}})
	add(&b, &n, {kind = .Server_Perf, actor = SERVER, n = {900, 2500, 31000}})
	add(&b, &n, {kind = .Server_Net, actor = SERVER, n = {2, 40, 5}})
	add(
		&b,
		&n,
		{
			kind = .Log_Line,
			actor = SERVER,
			note = telemetry.note("Warning server: chunk dropped pos=[1,2,3]"),
		},
	)
	return strings.to_string(b)
}

@(test)
test_session_report_prints_every_part :: proc(t: ^testing.T) {
	report := session_summary(parse_events(session_text()))
	for want in ([]string {
			"2 players",
			"weapon balance",
			"shotgun",
			"60%", // 3 of 5 hit
			"1.50 s", // the time to kill
			"player 0: 1 kills, 0 deaths, accuracy 60%",
			"1 grapples, 1 jumps, 1 double jumps",
			"killed by: shotgun 1",
			"Test GPU 3000",
			"Mesa 99.1",
			"1920 x 1080",
			"median 7.0 ms",
			"worst 60.0 ms",
			"ping median 25 ms",
			"worst 80 ms",
			"records resent",
			"tick time: median 0.90 ms",
			"desyncs: 2 of 40",
			"warnings and errors: 1",
			"chunk dropped",
			"+00:05  22:13:25  player 0: a frame took 60.0 ms that minute (p95 12.0 ms)",
		}) {
		testing.expectf(
			t,
			strings.contains(report, want),
			"the report lacks %q:\n%s",
			want,
			report,
		)
	}
	testing.expect(
		t,
		!strings.contains(report, "a frame took 40.0 ms"),
		"a frame under SLOW_US is not on the timeline",
	)
	testing.expect(
		t,
		strings.contains(report, "no clean stop"),
		"a session with no stop is a crash",
	)
}
