package sandbox_server

import "core:fmt"
import "core:os"
import "core:testing"

import "server:core"
import "server:playtest"

@(private = "file")
interventions_sample :: proc(l: ^Intervention_Log) {
	// Recorded out of order on purpose: the log keeps time order.
	intervention_record(l, {day = 5, place = {100, 64, 100}, kind = .Built, actor = "ada"})
	intervention_record(
		l,
		{
			day = 2,
			place = {0, 70, 0},
			kind = .Founded_Settlement,
			actor = "bob",
			data = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
		},
	)
	intervention_record(l, {day = 5, place = {-100, 64, 7}, kind = .Destroyed, actor = "cy"})
	intervention_record(l, {day = 9.5, place = {3, 4, 5}, kind = .Taught, actor = ""})
	intervention_record(
		l,
		{day = 7, place = {-2000000000, 0, 2000000000}, kind = .Traded, actor = "ada"},
	)
}

@(test)
test_intervention_record_keeps_time_order :: proc(t: ^testing.T) {
	l: Intervention_Log
	defer interventions_destroy(&l)
	interventions_sample(&l)
	want := []f64{2, 5, 5, 7, 9.5}
	testing.expect_value(t, len(l.list), len(want))
	for d, i in want {testing.expect_value(t, l.list[i].day, d)}
	// Equal days stay in the order recorded.
	testing.expect_value(t, l.list[1].actor, "ada")
	testing.expect_value(t, l.list[2].actor, "cy")
}

@(test)
test_intervention_record_refuses_invalid :: proc(t: ^testing.T) {
	l: Intervention_Log
	defer interventions_destroy(&l)
	zero: f64
	testing.expect(t, !intervention_record(&l, {day = -1}))
	testing.expect(t, !intervention_record(&l, {day = 0 / zero}))
	testing.expect(t, !intervention_record(&l, {day = 1 / zero}))
	testing.expect(t, !intervention_record(&l, {day = 1, kind = Intervention_Kind(200)}))
	long := "0123456789012345678901234567890123456789012345678901234567890123x"
	testing.expect(t, !intervention_record(&l, {day = 1, actor = long}))
	testing.expect_value(t, len(l.list), 0)
	testing.expect(t, intervention_record(&l, {day = 1, actor = long[:MAX_ACTOR]}))
}

@(test)
test_intervention_query_by_time :: proc(t: ^testing.T) {
	l: Intervention_Log
	defer interventions_destroy(&l)
	interventions_sample(&l)
	testing.expect_value(t, len(interventions_since(&l, 0)), 5)
	testing.expect_value(t, len(interventions_since(&l, 2)), 5) // on the day counts
	testing.expect_value(t, len(interventions_since(&l, 2.5)), 4)
	testing.expect_value(t, len(interventions_since(&l, 5)), 4)
	testing.expect_value(t, len(interventions_since(&l, 9.5)), 1)
	testing.expect_value(t, len(interventions_since(&l, 9.6)), 0)
}

@(test)
test_intervention_query_by_place_is_exact :: proc(t: ^testing.T) {
	l: Intervention_Log
	defer interventions_destroy(&l)
	intervention_record(&l, {day = 1, place = {10, 0, 0}, kind = .Built})
	intervention_record(&l, {day = 2, place = {0, 6, 8}, kind = .Built}) // distance 10
	intervention_record(&l, {day = 3, place = {7, 7, 7}, kind = .Built}) // 12.12: out of 12, in 13
	intervention_record(&l, {day = 4, place = {10, 1, 0}, kind = .Built}) // 10.05
	centre := [3]i32{0, 0, 0}
	got := interventions_near(&l, centre, 10, 0, context.temp_allocator)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0].day, 1)
	testing.expect_value(t, got[1].day, 2)
	testing.expect_value(t, len(interventions_near(&l, centre, 12, 0, context.temp_allocator)), 3)
	testing.expect_value(t, len(interventions_near(&l, centre, 13, 0, context.temp_allocator)), 4)
	testing.expect_value(
		t,
		len(interventions_near(&l, centre, 13, 2.5, context.temp_allocator)),
		2,
	)
	testing.expect_value(t, len(interventions_near(&l, centre, 0, 0, context.temp_allocator)), 0)
	testing.expect_value(t, len(interventions_near(&l, centre, -1, 0, context.temp_allocator)), 0)
	// Far coordinates do not overflow.
	far := [3]i32{max(i32), max(i32), max(i32)}
	testing.expect_value(
		t,
		len(interventions_near(&l, far, max(i32), 0, context.temp_allocator)),
		0,
	)
}

@(test)
test_intervention_save_and_load :: proc(t: ^testing.T) {
	l: Intervention_Log
	defer interventions_destroy(&l)
	interventions_sample(&l)
	data := interventions_encode(&l)
	defer delete(data)
	back, ok := interventions_decode(data)
	defer interventions_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, len(back.list), len(l.list))
	for iv, i in l.list {
		testing.expect_value(t, back.list[i], iv)
	}
	// An empty log round-trips too, and encoding is stable.
	empty: Intervention_Log
	e := interventions_encode(&empty)
	defer delete(e)
	e_back, e_ok := interventions_decode(e)
	testing.expect(t, e_ok && len(e_back.list) == 0)
	interventions_destroy(&e_back)
	again := interventions_encode(&back)
	defer delete(again)
	testing.expect_value(t, string(again), string(data))
}

@(test)
test_intervention_damaged_file_is_refused :: proc(t: ^testing.T) {
	l: Intervention_Log
	defer interventions_destroy(&l)
	interventions_sample(&l)
	data := interventions_encode(&l)
	defer delete(data)
	// Every cut is refused.
	for n in 0 ..< len(data) {
		_, ok := interventions_decode(data[:n])
		testing.expect(t, !ok)
	}
	// Every flipped byte is refused (the CRC covers the whole file).
	bad := make([]u8, len(data))
	defer delete(bad)
	for i in 0 ..< len(data) {
		copy(bad, data)
		bad[i] ~= 0x40
		_, ok := interventions_decode(bad)
		testing.expect(t, !ok)
	}
	// Extra bytes are refused.
	more := make([]u8, len(data) + 1)
	defer delete(more)
	copy(more, data)
	_, ok := interventions_decode(more)
	testing.expect(t, !ok)
}

@(test)
test_intervention_decode_refuses_valid_crc_but_bad_content :: proc(t: ^testing.T) {
	// A file whose CRC is right but whose records are out of order is refused.
	l: Intervention_Log
	defer interventions_destroy(&l)
	intervention_record(&l, {day = 1, actor = "a"})
	intervention_record(&l, {day = 2, actor = "b"})
	l.list[0].day, l.list[1].day = 2, 1 // (bypassing record)
	data := interventions_encode(&l)
	defer delete(data)
	_, ok := interventions_decode(data)
	testing.expect(t, !ok)
	// A newer version is refused.
	l.list[0].day, l.list[1].day = 1, 2
	good := interventions_encode(&l)
	defer delete(good)
	good[4] = INTERVENTIONS_VERSION + 1
	_, ok = interventions_decode(good)
	testing.expect(t, !ok)
}

// A world's interventions log is kept with the world (sandbox.interventions.vxi), listed by
// /interventions, read back when the world opens; a damaged file is moved aside, never
// half-read, and --check finds it.
@(test)
test_interventions_kept_with_the_world :: proc(t: ^testing.T) {
	dir :: "build/tmp/sandbox_interventions"
	os.remove_all(dir)
	defer os.remove_all(dir)
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
	s := playtest.srv(rig)
	w := s.home
	testing.expect(
		t,
		interventions_add(w, {day = 4, place = {1, 2, 3}, kind = .Built, actor = "ada"}),
	)
	testing.expect(
		t,
		interventions_add(
			w,
			{day = 1, place = {0, 0, 0}, kind = .Founded_Settlement, actor = "bob"},
		),
	)
	testing.expect(t, !interventions_add(w, {day = -3}))
	testing.expect(t, command(s, playtest.host(rig), "interventions", nil))
	testing.expect(t, playtest.told(rig, "day 1.00 Founded_Settlement at 0 0 0 by bob"))
	path := fmt.tprintf("%s/sandbox.%s", w.dir, INTERVENTIONS_FILE)
	playtest.stop(rig)
	testing.expect(t, os.exists(path), "the save has no interventions file")
	testing.expect(t, core.universe_check(dir, {GAME}).ok)

	rig2 := new(playtest.Rig)
	defer free(rig2)
	if !playtest.start(t, rig2, GAME, {save_dir = dir}) {return}
	l := &world_of(playtest.srv(rig2).home).interventions
	testing.expect_value(t, len(l.list), 2)
	if len(l.list) == 2 {
		testing.expect_value(t, l.list[0].actor, "bob")
		testing.expect_value(t, l.list[1].kind, Intervention_Kind.Built)
	}
	playtest.stop(rig2)

	// Damaged: --check says so, and the world moves it aside and starts with an empty log.
	data, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	data[len(data) / 2] ~= 0xff
	_ = os.write_entire_file(path, data)
	testing.expect(t, !core.universe_check(dir, {GAME}).ok, "--check passed a damaged log")
	quiet := context.logger // (opening reports it as an error, quieted here)
	quiet.lowest_level = .Fatal
	context.logger = quiet
	rig3 := new(playtest.Rig)
	defer free(rig3)
	if !playtest.start(t, rig3, GAME, {save_dir = dir}) {return}
	defer playtest.stop(rig3)
	testing.expect_value(t, len(world_of(playtest.srv(rig3).home).interventions.list), 0)
	testing.expect(t, os.exists(fmt.tprintf("%s.bad", path)))
}
