package play

import "core:math"

import "common:game"
import "server:core"

// What the server parts of games share, built on what a game may call of server:core
// alone (docs/games.md; the `import` lint holds this package to the same list). A game
// imports it as `server:play`: its phases and their clocks, its walled arena built from
// a seed, where it puts the players it is not playing with, and the rules its admin sets.

// Phase: where a game's round, match or run is (P: the game's own enum: Waiting,
// Playing, Results...) and since when, so its clock is one field: phase_seconds and
// phase_left take a ^Phase as its Clock.
Phase :: struct($P: typeid) {
	now:         P,
	using clock: Clock,
}

// Clock: the server tick a phase began.
Clock :: struct {
	since: u64,
}

// phase_set: the phase is now `to`, its clock from this tick (again, when it already
// was: a phase can start over).
phase_set :: proc(s: ^core.Server, p: ^Phase($P), to: P) {
	p.now, p.since = to, s.tick
}

// phase_seconds: seconds since the phase began.
phase_seconds :: proc(s: ^core.Server, c: ^Clock) -> f64 {
	return f64(s.tick - c.since) / f64(game.TICK_RATE)
}

// phase_left: whole seconds left of a phase that lasts `seconds` (rounded up, never
// less than 0): what a countdown on a player's screen shows.
phase_left :: proc(s: ^core.Server, c: ^Clock, seconds: f64) -> u16 {
	return u16(math.ceil(max(seconds - phase_seconds(s, c), 0)))
}
