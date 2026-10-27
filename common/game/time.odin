package game

import "core:math"
import "core:strconv"

// World time: days since the world began, as one f64. Its fraction is the
// time of day: 0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset. The server
// owns it: it advances it every tick (rules.day_length seconds per day,
// while rules.daylight_cycle), saves it and sends it to clients (Time), who
// carry it on between messages with the same rules.

NEW_WORLD_TIME :: 0.3 // a new world starts in the morning
MAX_WORLD_TIME :: 1e9 // days; anything later in a message or save is invalid

// time_of_day is t's fraction: 0..1 from midnight.
time_of_day :: proc(t: f64) -> f64 {
	return t - math.floor(t)
}

// advance_time moves t on by seconds of play.
advance_time :: proc(t: f64, seconds: f64, rules: ^Rules) -> f64 {
	if !rules.daylight_cycle {return t}
	return min(t + seconds / f64(rules.day_length), MAX_WORLD_TIME)
}

// set_time_of_day: the same day at time of day f (0..1); it may go back.
set_time_of_day :: proc(t: f64, f: f64) -> f64 {
	return math.floor(t) + f
}

// parse_time_of_day reads a time of day: a name (sunrise, day, noon,
// sunset, night, midnight) or a fraction 0..1.
parse_time_of_day :: proc(s: string) -> (f: f64, ok: bool) {
	switch s {
	case "midnight":
		return 0, true
	case "sunrise":
		return 0.25, true
	case "day":
		return 0.3, true
	case "noon":
		return 0.5, true
	case "sunset":
		return 0.75, true
	case "night":
		return 0.8, true
	}
	f, ok = strconv.parse_f64(s)
	if !ok || !(f >= 0 && f <= 1) {return 0, false}
	return f, true
}

// time_valid: a world time a message or save may carry.
time_valid :: proc(t: f64) -> bool {
	return t >= 0 && t <= MAX_WORLD_TIME // false for NaN too
}
