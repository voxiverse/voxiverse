package main

import "core:slice"
import "core:testing"

import "client:engine"
import "client:screen"
import "client:ui"

Holiday_Date :: struct {
	y, m, d: int,
	holiday: engine.Holiday,
}
SECONDS :: [3]i64{0, 1, 12345}

@(test)
test_easter_computus :: proc(t: ^testing.T) {
	dates := [][2]int {
		{3, 31},
		{4, 20},
		{4, 5},
		{3, 28},
		{4, 16},
		{4, 1},
		{4, 21},
		{4, 13},
		{3, 28},
	}
	years := []int{2024, 2025, 2026, 2027, 2028, 2029, 2030, 2031, 2032}
	for y, i in years {
		m, d := engine.easter_date(y)
		testing.expectf(t, m == dates[i][0] && d == dates[i][1], "Easter %d: got %d-%d", y, m, d)
	}
}

@(test)
test_holiday_windows :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, y, m, d: int, want_holiday: engine.Holiday, want_greeting: bool) {
		h, g := engine.holiday_for(y, m, d)
		testing.expectf(
			t,
			h == want_holiday && g == want_greeting,
			"%d-%d-%d: got (%v, %v)",
			y,
			m,
			d,
			h,
			g,
		)
	}
	check(t, 2026, 12, 31, .New_Year, false)
	check(t, 2027, 1, 1, .New_Year, true)
	check(t, 2027, 1, 2, .New_Year, false)
	check(t, 2027, 1, 3, .None, false)
	check(t, 2027, 2, 14, .Valentines, true)
	check(t, 2027, 2, 15, .None, false)
	check(t, 2027, 3, 17, .St_Patricks, true)
	check(t, 2027, 10, 25, .Halloween, false)
	check(t, 2027, 10, 31, .Halloween, true)
	check(t, 2027, 11, 1, .None, false)
	check(t, 2027, 12, 20, .Christmas, false)
	check(t, 2027, 12, 25, .Christmas, true)
	check(t, 2027, 12, 26, .Christmas, false)
	check(t, 2027, 12, 27, .None, false)
	// Easter 2026 (April 5): Good Friday to Easter Monday.
	check(t, 2026, 4, 3, .Easter, false)
	check(t, 2026, 4, 4, .Easter, false)
	check(t, 2026, 4, 5, .Easter, true)
	check(t, 2026, 4, 6, .Easter, false)
	check(t, 2026, 4, 7, .None, false)
	// Easter 2027 (March 28): Good Friday to Easter Monday.
	check(t, 2027, 3, 26, .Easter, false)
	check(t, 2027, 3, 28, .Easter, true)
	check(t, 2027, 3, 29, .Easter, false)
	check(t, 2027, 3, 30, .None, false)
}

@(test)
test_splashes_parse_sections :: proc(t: ^testing.T) {
	text :=
		"# everyday first\n" +
		"Day one\nDay two\n\n" +
		"[christmas]\n" +
		"Merry Christmas!\nMerry Christmas! Reindeers\n\n" +
		"[not_a_holiday]\n" +
		"Skipped text\n\n" +
		"[halloween]\n" +
		"Happy Halloween!\nHappy Halloween! Something\n"
	got := screen.splashes_parse_file(text)
	testing.expect_value(t, len(got.all), 6)
	testing.expect_value(t, got.sets[.None][0], "Day one")
	testing.expect_value(t, got.sets[.None][1], "Day two")
	testing.expect_value(t, got.sets[.Christmas][0], "Merry Christmas!")
	testing.expect_value(t, got.sets[.Halloween][1], "Happy Halloween! Something")
	// The unknown section's texts are skipped, not everyday.
	for entry in got.all {
		testing.expect(t, entry != "Skipped text")
	}
	// The shipped file parses and every holiday has its texts.
	shipped := screen.splashes_parse_file(screen.SPLASHES)
	greeting_texts := engine.HOLIDAY_GREETING
	testing.expect(t, len(shipped.all) >= 12 + 6 * 8)
	for h in ([]engine.Holiday{engine.Holiday.New_Year, engine.Holiday.Valentines, engine.Holiday.St_Patricks, engine.Holiday.Easter, engine.Holiday.Halloween, engine.Holiday.Christmas}) {
		testing.expectf(
			t,
			len(shipped.sets[h]) >= 8,
			"holiday %v: %d texts",
			h,
			len(shipped.sets[h]),
		)
		testing.expect_value(t, shipped.sets[h][0], greeting_texts[h])
	}
}

@(test)
test_splash_for :: proc(t: ^testing.T) {
	parsed := screen.splashes_parse_file(screen.SPLASHES)
	greeting_texts := engine.HOLIDAY_GREETING
	greeting_cases := []Holiday_Date {
		{2027, 1, 1, .New_Year},
		{2027, 2, 14, .Valentines},
		{2027, 3, 17, .St_Patricks},
		{2026, 4, 5, .Easter},
		{2027, 10, 31, .Halloween},
		{2026, 12, 25, .Christmas},
	}
	// On the greeting day itself the greeting shows, whatever the second.
	for c in greeting_cases {
		for s in SECONDS {
			got := screen.splash_for(parsed, c.y, c.m, c.d, s)
			testing.expectf(
				t,
				got == greeting_texts[c.holiday],
				"greeting day splash for %v: %q",
				c,
				got,
			)
		}
	}
	// On a holiday's other days the splash comes from its set.
	window_cases := []Holiday_Date {
		{2026, 12, 31, .New_Year},
		{2027, 10, 25, .Halloween},
		{2026, 12, 20, .Christmas},
		{2026, 4, 3, .Easter},
	}
	for c in window_cases {
		for s in SECONDS {
			got := screen.splash_for(parsed, c.y, c.m, c.d, s)
			testing.expectf(
				t,
				slice.contains(parsed.sets[c.holiday], got),
				"window day splash for %v: %q",
				c,
				got,
			)
		}
	}
	// Any other day: an everyday entry, picked by the second.
	got := screen.splash_for(parsed, 2027, 6, 15, 0)
	testing.expect(t, slice.contains(parsed.sets[.None], got))
	got = screen.splash_for(parsed, 2027, 6, 15, 12345)
	testing.expect(t, slice.contains(parsed.sets[.None], got))
	// The greeting is stable for a given second.
	testing.expect_value(
		t,
		screen.splash_for(parsed, 2027, 6, 15, 777),
		screen.splash_for(parsed, 2027, 6, 15, 777),
	)
}

@(test)
test_reduce_motion_gates_holiday_fx :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	app := f.app
	app.session = nil
	app.screen = .Title
	app.title_date_override = [3]int{2026, 12, 25}
	app.settings.reduce_motion = true
	ui.begin_frame(&app.ui, {}, SCREEN, 1)
	screen.title_screen(app, &app.ui)
	ui.end_frame(&app.ui)
	testing.expect_value(t, app.holiday_fx.running, engine.Holiday.None)
	testing.expect_value(t, app.splash, "Merry Christmas!")

	// Reduce motion off: the Christmas fx runs, and the splash re-picks.
	app.settings.reduce_motion = false
	app.splash = ""
	ui.begin_frame(&app.ui, {}, SCREEN, 1)
	screen.title_screen(app, &app.ui)
	ui.end_frame(&app.ui)
	testing.expect_value(t, app.holiday_fx.running, engine.Holiday.Christmas)
	testing.expect_value(t, app.splash, "Merry Christmas!")

	// New Year on the last day of December: the fx follow the date.
	app.title_date_override = [3]int{2026, 12, 31}
	app.splash = ""
	ui.begin_frame(&app.ui, {}, SCREEN, 1)
	screen.title_screen(app, &app.ui)
	ui.end_frame(&app.ui)
	testing.expect_value(t, app.holiday_fx.running, engine.Holiday.New_Year)
}

@(test)
test_title_date_parse :: proc(t: ^testing.T) {
	y, m, d, ok := engine.title_date_parse("12-25", 2026)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, [3]int{y, m, d}, [3]int{2026, 12, 25})
	y, m, d, ok = engine.title_date_parse("2027-03-28", 2026)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, [3]int{y, m, d}, [3]int{2027, 3, 28})
	y, m, d, ok = engine.title_date_parse("2024-02-29", 2026)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, [3]int{y, m, d}, [3]int{2024, 2, 29})
	y, m, d, ok = engine.title_date_parse("2026-02-29", 2026)
	testing.expect_value(t, ok, false)
	_, _, _, ok = engine.title_date_parse("13-01", 2026)
	testing.expect_value(t, ok, false)
	_, _, _, ok = engine.title_date_parse("02-30", 2026)
	testing.expect_value(t, ok, false)
	_, _, _, ok = engine.title_date_parse("off", 2026)
	testing.expect_value(t, ok, false)
	_, _, _, ok = engine.title_date_parse("hello", 2026)
	testing.expect_value(t, ok, false)
	_, _, _, ok = engine.title_date_parse("", 2026)
	testing.expect_value(t, ok, false)
	_, _, _, ok = engine.title_date_parse("12-32-2026", 2026)
	testing.expect_value(t, ok, false)
}
