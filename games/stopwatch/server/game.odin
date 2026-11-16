package stopwatch_server

import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"

import "common:game"
import "games:stopwatch"
import "server:core"

// Stopwatch's server part (the game: games/stopwatch): it keeps every player's time
// and the record, tells each player theirs once a second (stopwatch.Times), tells
// everyone when a record is broken, and answers /stopwatch.

GAME :: core.Game {
	info         = stopwatch.INFO,
	kinds        = stopwatch.KINDS,
	server_state = Watch,
	client_state = Lap,
	configure    = configure,
	start        = start,
	stop         = stop,
	tick         = tick,
	joined       = joined,
	left         = left,
	command      = command,
	save         = save,
	load         = load,
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
		stopwatch.seconds(w.record),
	)
}

// tick counts every player's time, and tells each theirs once a second.
tick :: proc(s: ^core.Server) {
	watch(s).ticks += 1
	second := s.tick % game.TICK_RATE == 0
	for &c in s.clients {
		if c.state != .Playing {continue}
		lap(s, &c).ticks += 1
		if second {times_put(s, &c)}
	}
}

// times_put tells c its time and the record, in whole seconds.
times_put :: proc(s: ^core.Server, c: ^core.Client) {
	times := stopwatch.Times {
		time   = u32(lap(s, c).ticks / game.TICK_RATE),
		record = u32(watch(s).record / game.TICK_RATE),
	}
	core.game_put(s, c, &times)
}

joined :: proc(s: ^core.Server, c: ^core.Client) {
	watch(s).joins += 1
	times_put(s, c)
	core.notice(s, c, "Stopwatch: your time runs from now (/stopwatch shows it)")
}

// left: a stay longer than the record is the record, and everyone else still playing
// is told whose.
left :: proc(s: ^core.Server, c: ^core.Client) {
	w := watch(s)
	stayed := lap(s, c).ticks
	if stayed <= w.record {return}
	w.record = stayed
	broken := stopwatch.Record_Broken {
		name    = core.client_name(c),
		seconds = u32(stayed / game.TICK_RATE),
	}
	for &other in s.clients {
		if &other != c && other.state == .Playing {core.game_event(s, &other, &broken)}
	}
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
				stopwatch.seconds(lap(s, c).ticks),
				stopwatch.seconds(watch(s).record),
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

// save: the record is kept with the universe (game.cfg), so it is still there to beat
// after a restart: "record = <ticks>".
save :: proc(s: ^core.Server, out: ^strings.Builder) {
	fmt.sbprintfln(out, "record = %d", watch(s).record)
}

// load: the record the universe kept; any other line is not Stopwatch's.
load :: proc(s: ^core.Server, text: string) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.trim_space(line) == "" {continue}
		key, _, value := strings.partition(line, "=")
		if strings.trim_space(key) != "record" {return false}
		record, ok := strconv.parse_u64(strings.trim_space(value), 10)
		if !ok {return false}
		watch(s).record = record
	}
	return true
}
