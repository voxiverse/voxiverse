package analytics

import "core:strings"
import "core:testing"

import "common:game"
import "common:telemetry"

// A small recorded run: two senders, a few days, the kinds the questions use.
@(private = "file")
recorded :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	DAY :: i64(86_400_000)
	T0 :: i64(1_700_000_000_000)
	add :: proc(b: ^strings.Builder, pid: string, e: telemetry.Event) {
		line := strings.builder_make(context.temp_allocator)
		telemetry.write_event(&line, e)
		text := strings.to_string(line)
		strings.write_string(b, `{"pid":"`)
		strings.write_string(b, pid)
		strings.write_string(b, `",`)
		strings.write_string(b, text[1:])
	}
	add(&b, "aaaa", {time_ms = T0, kind = .Session_Start, actor = 0, n = {1, 0, 0}})
	add(
		&b,
		"aaaa",
		{
			time_ms = T0 + 10,
			kind = .Client_Info,
			actor = 0,
			text = telemetry.short("linux"),
			n = {16, 70, 3000},
		},
	)
	add(
		&b,
		"aaaa",
		{
			time_ms = T0 + 35,
			kind = .Item_Created,
			actor = 0,
			text = telemetry.short("stone"),
			n = {64, i64(game.Reason.Give), 0},
		},
	)
	add(
		&b,
		"aaaa",
		{
			time_ms = T0 + 36,
			kind = .Item_Destroyed,
			actor = 0,
			text = telemetry.short("stone"),
			n = {1, i64(game.Reason.Place), 0},
		},
	)
	add(
		&b,
		"aaaa",
		{time_ms = T0 + 20, kind = .Block_Mined, actor = 0, text = telemetry.short("stone")},
	)
	add(
		&b,
		"aaaa",
		{time_ms = T0 + 30, kind = .Block_Mined, actor = 0, text = telemetry.short("stone")},
	)
	add(
		&b,
		"aaaa",
		{
			time_ms = T0 + 40,
			kind = .Item_Picked,
			actor = 0,
			text = telemetry.short("stone"),
			n = {2, 0, 0},
		},
	)
	add(
		&b,
		"aaaa",
		{
			time_ms = T0 + 50,
			kind = .Position_Sample,
			actor = 0,
			has_pos = true,
			pos = {0, 5, 0},
			text = telemetry.short("walking"),
		},
	)
	add(
		&b,
		"aaaa",
		{
			time_ms = T0 + 60,
			kind = .Position_Sample,
			actor = 0,
			has_pos = true,
			pos = {0, 5, 0},
			text = telemetry.short("walking"),
		},
	)
	add(
		&b,
		"aaaa",
		{
			time_ms = T0 + 70,
			kind = .Position_Sample,
			actor = 0,
			has_pos = true,
			pos = {160, 5, -160},
			text = telemetry.short("flying"),
		},
	)
	add(&b, "aaaa", {time_ms = T0 + 80, kind = .Session_End, actor = 0, n = {600, 0, 0}})
	add(&b, "aaaa", {time_ms = T0 + DAY, kind = .Session_Start, actor = 0, n = {1, 0, 0}})
	add(&b, "aaaa", {time_ms = T0 + DAY + 5, kind = .Session_End, actor = 0, n = {60, 0, 0}})
	add(&b, "bbbb", {time_ms = T0 + 90, kind = .Session_Start, actor = 0, n = {1, 0, 0}})
	add(
		&b,
		"bbbb",
		{
			time_ms = T0 + 95,
			kind = .Client_Info,
			actor = 0,
			text = telemetry.short("windows"),
			n = {12, 70, 5000},
		},
	)
	add(
		&b,
		"bbbb",
		{
			time_ms = T0 + 100,
			kind = .Tick_Summary,
			actor = telemetry.NO_ACTOR,
			n = {1, 1500, 9000},
		},
	)
	add(&b, "bbbb", {time_ms = T0 + 110, kind = .Client_Perf, actor = 0, n = {8000, 25000, 3600}})
	add(
		&b,
		"bbbb",
		{time_ms = T0 + 120, kind = .Block_Placed, actor = 0, text = telemetry.short("dirt")},
	)
	add(&b, "bbbb", {time_ms = T0 + 130, kind = .Session_End, actor = 0, n = {30, 0, 0}})
	strings.write_string(&b, "not json at all\n")
	strings.write_string(&b, "{\"hello\":1}\n")
	return strings.to_string(b)
}

@(test)
test_the_questions_asked_most :: proc(t: ^testing.T) {
	events := parse_events(recorded())
	testing.expect_value(t, len(events), 19) // (two lines that are no events skipped)
	s := summary(events)
	testing.expect(t, strings.contains(s, "events 19 from 2 senders"), s)
	testing.expect(t, strings.contains(s, "block_mined") && strings.contains(s, "tick_summary"))

	rows, returning := sessions(events)
	testing.expect_value(t, len(rows), 2)
	testing.expect(t, rows[0].pid == "aaaa" && rows[0].sessions == 2 && rows[0].seconds == 660)
	testing.expect(t, rows[1].pid == "bbbb" && rows[1].sessions == 1 && rows[1].seconds == 30)
	testing.expect_value(t, returning, 1) // aaaa came back on another day

	e := economy(events)
	testing.expect(t, strings.contains(e, "stone"), e)
	testing.expect(t, strings.contains(e, "mined:\n  stone            2"), e)
	testing.expect(t, strings.contains(e, "placed:\n  dirt             1"), e)

	f := faucets(events)
	testing.expect(t, strings.contains(f, "stone            created   give             64"), f)
	testing.expect(t, strings.contains(f, "stone            destroyed place            1"), f)

	slow := slowest(events)
	testing.expect(
		t,
		strings.contains(slow, "frame p99 us") && strings.contains(slow, "25000"),
		slow,
	)
	testing.expect(t, strings.index(slow, "25000") < strings.index(slow, "9000"), "worst first")

	median, worst, n := launch_to_playing(events)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, median, 5000) // (of 3000 and 5000: the upper middle)
	testing.expect_value(t, worst, 5000)

	grid := heat(events, 16, 16)
	testing.expect_value(t, grid[8 * 16 + 8], 2) // two at the origin
	total := 0
	for v in grid {total += v}
	testing.expect_value(t, total, 2) // (the far sample is off a 16 x 16 grid of 16-block cells)
	free_all(context.temp_allocator)
}
