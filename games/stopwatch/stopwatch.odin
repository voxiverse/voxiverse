package stopwatch

import "core:fmt"
import "core:log"

import "common:game"
import "server:core"

// Stopwatch: the smallest game, and the model for the next (docs/games.md). It is
// played in survival: every player's time in the world runs from when they join,
// the longest stay of anyone who left is the record to beat, and /stopwatch tells a
// player their time and the record.

GAME :: core.Game {
	id           = "stopwatch",
	server_state = Watch,
	client_state = Lap,
	configure    = configure,
	start        = start,
	stop         = stop,
	tick         = tick,
	joined       = joined,
	left         = left,
	command      = command,
}

// Watch: the game's state for the session.
Watch :: struct {
	started: u64, // the server tick it started at
	ticks:   u64, // ticks it has run
	joins:   int, // players who have joined
	record:  u64, // the longest stay of a player who left, in ticks
}

// Lap: a player's state.
Lap :: struct {
	ticks: u64, // ticks it has been playing
}

watch :: proc(s: ^core.Server) -> ^Watch {return core.game_state(s, Watch)}
lap :: proc(s: ^core.Server, c: ^core.Client) -> ^Lap {return core.game_client_state(s, c, Lap)}

// seconds: ticks as seconds of play.
seconds :: proc(ticks: u64) -> f64 {return f64(ticks) / game.TICK_RATE}

// configure: a new universe is played in survival (staying is only a feat where one can
// die); a mode asked for stays.
configure :: proc(config: ^core.Config) {
	if config.mode == "" {config.mode = "survival"}
}

start :: proc(s: ^core.Server) -> bool {
	watch(s).started = s.tick
	log.infof("stopwatch started tick=%d", s.tick)
	return true
}

stop :: proc(s: ^core.Server) {
	w := watch(s)
	log.infof(
		"stopwatch stopped ticks=%d joins=%d record=%.1fs",
		w.ticks,
		w.joins,
		seconds(w.record),
	)
}

tick :: proc(s: ^core.Server) {
	watch(s).ticks += 1
	for &c in s.clients {
		if c.state == .Playing {lap(s, &c).ticks += 1}
	}
}

joined :: proc(s: ^core.Server, c: ^core.Client) {
	watch(s).joins += 1
	core.notice(s, c, "Stopwatch: your time runs from now (/stopwatch shows it)")
}

left :: proc(s: ^core.Server, c: ^core.Client) {
	w := watch(s)
	w.record = max(w.record, lap(s, c).ticks)
}

// command: /stopwatch shows the player's time and the record; /stopwatch reset starts
// their time again.
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name != "stopwatch" {return false}
	switch {
	case len(args) == 0:
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Your time: %.1f s. The record: %.1f s",
				seconds(lap(s, c).ticks),
				seconds(watch(s).record),
			),
		)
	case len(args) == 1 && args[0] == "reset":
		lap(s, c).ticks = 0
		core.notice(s, c, "Your time runs from zero again")
	case:
		core.notice(s, c, "Usage: stopwatch [reset]")
	}
	return true
}
