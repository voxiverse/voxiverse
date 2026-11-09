package engine

import "core:strconv"
import "core:strings"
import "core:time"
import "core:time/timezone"

// The holidays the title screen celebrates, picked from the player's local
// date. Dates (the player's local date):
//   New Year      Dec 31 to Jan 2        (greeting on Jan 1)
//   Valentines    Feb 14                 (greeting that day)
//   St Patrick    Mar 17                 (greeting that day)
//   Easter        Good Friday to Easter Monday, Western Easter by the
//                 Gregorian computus (greeting on Easter Sunday)
//   Halloween     Oct 25 to Oct 31       (greeting on Oct 31)
//   Christmas     Dec 20 to Dec 26       (greeting on Dec 25)
// A holiday's texts live in assets/splashes.txt under its section line,
// [<holiday>] (see screen/holiday.odin).

Holiday :: enum u8 {
	None,
	New_Year,
	Valentines,
	St_Patricks,
	Easter,
	Halloween,
	Christmas,
}

HOLIDAY_GREETING :: [Holiday]string {
	.None        = "",
	.New_Year    = "Happy New Year!",
	.Valentines  = "Happy Valentine's Day!",
	.St_Patricks = "Happy St Patrick's Day!",
	.Easter      = "Happy Easter!",
	.Halloween   = "Happy Halloween!",
	.Christmas   = "Merry Christmas!",
}

HOLIDAY_SECTIONS :: [?]Holiday {
	.New_Year,
	.Valentines,
	.St_Patricks,
	.Easter,
	.Halloween,
	.Christmas,
}

// The holidays' colours (interface colours come from the theme, these are
// artwork; like the menus' starfield tints). All zeros means the theme's text.
HOLIDAY_TINT :: [Holiday][4]u8 {
	.None        = {},
	.New_Year    = {}, // the fireworks carry it
	.Valentines  = {238, 132, 152, 255},
	.St_Patricks = {110, 220, 125, 255},
	.Easter      = {250, 205, 222, 255},
	.Halloween   = {250, 150, 40, 255},
	.Christmas   = {},
}
// holiday_tint: the theme's dye for the splash's text on that holiday, or nil for the theme's own.
holiday_tint :: proc(h: Holiday) -> (tint: [4]u8, ok: bool) {
	z: [4]u8 = {0, 0, 0, 0}
	tints := HOLIDAY_TINT
	if t := tints[h]; t != z {return t, true}
	return {}, false
}
HALLOWEEN_SHADOW :: [4]u8{93, 63, 150, 255}
BAT_COLOR :: [4]u8{26, 24, 34, 255}
SNOW_COLOR :: [4]u8{255, 255, 255, 235}
MOON_COLOR :: [4]u8{245, 230, 200, 255}
MOON_CRATER :: [4]u8{206, 192, 164, 255}
FIREWORK_PALETTE :: [?][4]u8 {
	{240, 96, 96, 255},
	{255, 209, 102, 255},
	{125, 211, 252, 255},
	{216, 163, 255, 255},
	{134, 239, 172, 255},
}

// easter_date: Western Easter Sunday for a Gregorian year (Anonymous
// Gregorian computus), as (month, day).
easter_date :: proc(year: int) -> (month, day: int) {
	a := year % 19
	b := year / 100
	c := year % 100
	d := b / 4
	e := b % 4
	f := (b + 8) / 25
	g := (b - f + 1) / 3
	h := (19 * a + b - d - g + 15) % 30
	i := c / 4
	k := c % 4
	l := (32 + 2 * e + 2 * i - h - k) % 7
	m := (a + 11 * h + 22 * l) / 451
	month = (h + l - 7 * m + 114) / 31
	day = ((h + l - 7 * m + 114) % 31) + 1
	return
}

// holiday_for: the holiday whose window contains (year, month, day), and
// whether it is the greeting day itself.
holiday_for :: proc(year, month, day: int) -> (holiday: Holiday, greeting_day: bool) {
	if month == 12 && day == 31 {return .New_Year, false}
	if month == 1 && day == 1 {return .New_Year, true}
	if month == 1 && day == 2 {return .New_Year, false}
	if month == 2 && day == 14 {return .Valentines, true}
	if month == 3 && day == 17 {return .St_Patricks, true}
	if month == 10 && day >= 25 && day <= 31 {return .Halloween, day == 31}
	if month == 12 && day >= 20 && day <= 26 {return .Christmas, day == 25}
	em, ed := easter_date(year)
	easter_yd := day_of_year(year, em, ed)
	today_yd := day_of_year(year, month, day)
	if today_yd >= easter_yd - 2 && today_yd <= easter_yd + 1 {
		return .Easter, today_yd == easter_yd
	}
	return .None, false
}

// day_of_year: days since January 1 (0-based).
day_of_year :: proc(year, month, day: int) -> int {
	mdays := [12]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	n := day - 1
	for m in 1 ..< month {
		n += mdays[m - 1]
		if m == 2 && is_leap_year(year) {n += 1}
	}
	return n
}

// is_leap_year: the Gregorian rule.
is_leap_year :: proc(year: int) -> bool {
	return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

// local_date_of: the local calendar date at time t (UTC if the platform's
// local zone cannot be loaded). The holidays are picked from the player's
// local date, as the issue says.
local_date_of :: proc(t: time.Time) -> (year, month, day: int, ok: bool) {
	utc, utc_ok := time.time_to_datetime(t)
	if !utc_ok {return 0, 0, 0, false}
	dt := utc
	if tz, tz_ok := timezone.region_load("local"); tz_ok {
		if local, local_ok := timezone.datetime_to_tz(utc, tz); local_ok {dt = local}
		timezone.region_destroy(tz)
	}
	return int(dt.year), int(dt.month), int(dt.day), true
}

// title_date_parse: a `title_date` argument ("12-25", "2027-03-28", "off").
// For "MM-DD" the current year is used; ok is false for anything else
// ("off" included), meaning the celebration follows the local date again.
title_date_parse :: proc(s: string, current_year: int) -> (year, month, day: int, ok: bool) {
	trimmed := strings.trim_space(s)
	if trimmed == "" || trimmed == "off" {return 0, 0, 0, false}
	fields := strings.split(trimmed, "-", context.temp_allocator)
	defer delete(fields, context.temp_allocator)
	if len(fields) != 2 && len(fields) != 3 {return 0, 0, 0, false}
	year = current_year
	if len(fields) == 3 {
		y, y_ok := strconv.parse_int(fields[0])
		if !y_ok {return 0, 0, 0, false}
		year = y
	}
	m, m_ok := strconv.parse_int(fields[len(fields) - 2])
	if !m_ok {return 0, 0, 0, false}
	d, d_ok := strconv.parse_int(fields[len(fields) - 1])
	if !d_ok {return 0, 0, 0, false}
	month, day = m, d
	if year < 1970 || year > 2200 || month < 1 || month > 12 || day < 1 || day > 31 {
		return 0, 0, 0, false
	}
	if day > days_in_month(year, month) {return 0, 0, 0, false}
	return year, month, day, true
}

@(private = "file")
days_in_month :: proc(year, month: int) -> int {
	mdays := [12]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if month == 2 && is_leap_year(year) {return 29}
	return mdays[month - 1]
}

// ---- the holiday backdrop's state (snow, bats, fireworks) ----

MAX_FLAKES :: 110
MAX_BATS :: 4
MAX_BURSTS :: 4
SPARKS_PER_BURST :: 16

Holiday_Fx :: struct {
	flakes:     [MAX_FLAKES]Fx_Flake,
	bats:       [MAX_BATS]Fx_Bat,
	bursts:     [MAX_BURSTS]Fx_Burst,
	next_burst: f32, // seconds until the next burst (New Year)
	random:     u32,
	running:    Holiday, // the holiday the fx is for (.None: idle)
}

Fx_Flake :: struct {
	x, y:   f32,
	size:   f32,
	speed:  f32,
	amount: f32, // sway amplitude
	phase:  f32,
}

Fx_Bat :: struct {
	x, y:   f32,
	speed:  f32, // pixels per second, left to right
	flap:   f32, // flap phase
	offset: f32, // vertical offset
}

Fx_Burst :: struct {
	active: bool,
	x, y:   f32,
	spark:  [SPARKS_PER_BURST][2]f32, // direction, unit vector
	age:    f32,
	color:  [4]u8,
}
