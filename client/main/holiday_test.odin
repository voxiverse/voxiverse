package main

import "core:fmt"
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
	check :: proc(t: ^testing.T, y, m, d: int, want: engine.Holiday) {
		got := engine.holiday_for(y, m, d)
		testing.expectf(t, got == want, "%d-%d-%d: got %v", y, m, d, got)
	}
	check(t, 2026, 12, 31, .New_Year)
	check(t, 2027, 1, 1, .New_Year)
	check(t, 2027, 1, 2, .New_Year)
	check(t, 2027, 1, 3, .None)
	check(t, 2027, 2, 14, .Valentines)
	check(t, 2027, 2, 15, .None)
	check(t, 2027, 3, 17, .St_Patricks)
	check(t, 2027, 10, 24, .None)
	check(t, 2027, 10, 25, .Halloween)
	check(t, 2027, 10, 31, .Halloween)
	check(t, 2027, 11, 1, .None)
	check(t, 2027, 12, 19, .None)
	check(t, 2027, 12, 20, .Christmas)
	check(t, 2027, 12, 26, .Christmas)
	check(t, 2027, 12, 27, .None)
	// Easter 2026 (April 5): Good Friday to Easter Monday.
	check(t, 2026, 4, 2, .None)
	check(t, 2026, 4, 3, .Easter)
	check(t, 2026, 4, 6, .Easter)
	check(t, 2026, 4, 7, .None)
	// Easter 2027 (March 28).
	check(t, 2027, 3, 26, .Easter)
	check(t, 2027, 3, 29, .Easter)
	check(t, 2027, 3, 30, .None)
}

// The file's sections: a game's lines join the everyday ones, a holiday's are its own, an
// unknown section's are skipped. The shipped file gives each holiday exactly one line
// (the greeting is written there and nowhere else) and has everyday lines.
@(test)
test_splashes_parse_sections :: proc(t: ^testing.T) {
	text :=
		"# everyday first\n" +
		"Day one\nDay two\n\n" +
		"[game flood]\nWet\n\n" +
		"[christmas]\n" +
		"Merry Christmas!\n\n" +
		"[not_a_holiday]\n" +
		"Skipped text\n\n" +
		"[Halloween]\n" +
		"Happy Halloween!\n"
	got := screen.splashes_parse_file(text)
	testing.expect_value(t, len(got.all), 5)
	testing.expect_value(
		t,
		fmt.tprint(got.everyday),
		fmt.tprint([]string{"Day one", "Day two", "Wet"}),
	)
	testing.expect_value(t, fmt.tprint(got.games), fmt.tprint([]string{"flood"}))
	testing.expect_value(
		t,
		fmt.tprint(got.holidays[.Christmas]),
		fmt.tprint([]string{"Merry Christmas!"}),
	)
	testing.expect_value(
		t,
		fmt.tprint(got.holidays[.Halloween]),
		fmt.tprint([]string{"Happy Halloween!"}),
	)
	testing.expect(
		t,
		!slice.contains(got.all, "Skipped text"),
		"an unknown section's line was kept",
	)

	shipped := screen.splashes_parse_file(screen.SPLASHES)
	testing.expect(t, len(shipped.everyday) >= 12)
	testing.expect(t, len(shipped.games) >= 1, "no game's lines")
	for h in engine.Holiday {
		if h == .None {continue}
		testing.expectf(
			t,
			len(shipped.holidays[h]) == 1,
			"[%s] has %d lines: a holiday has exactly one",
			engine.HOLIDAY_SECTION[h],
			len(shipped.holidays[h]),
		)
	}
}

// Every day of a holiday's dates shows its one line, whatever the second; any other
// day an everyday line (a game's among them), picked by the second.
@(test)
test_splash_for :: proc(t: ^testing.T) {
	parsed := screen.splashes_parse_file(screen.SPLASHES)
	days := []Holiday_Date {
		{2026, 12, 31, .New_Year},
		{2027, 1, 1, .New_Year},
		{2027, 1, 2, .New_Year},
		{2027, 2, 14, .Valentines},
		{2027, 3, 17, .St_Patricks},
		{2026, 4, 3, .Easter},
		{2026, 4, 5, .Easter},
		{2026, 4, 6, .Easter},
		{2027, 10, 25, .Halloween},
		{2027, 10, 31, .Halloween},
		{2026, 12, 20, .Christmas},
		{2026, 12, 25, .Christmas},
		{2026, 12, 26, .Christmas},
	}
	for c in days {
		for s in SECONDS {
			got := screen.splash_for(parsed, c.y, c.m, c.d, s)
			testing.expectf(t, got == parsed.holidays[c.holiday][0], "%v: %q", c, got)
		}
	}
	testing.expect_value(t, screen.splash_for(parsed, 2026, 12, 20, 0), "Merry Christmas!")
	for s in SECONDS {
		got := screen.splash_for(parsed, 2027, 6, 15, s)
		testing.expectf(t, slice.contains(parsed.everyday, got), "an ordinary day: %q", got)
	}
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
