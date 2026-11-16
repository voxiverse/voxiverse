package rally_server

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"

import "common:game"
import "common:protocol"
import "games:rally"
import "server:core"
import "server:play"

// Rally's server part (the game: games/rally): it runs the races in the home world. The
// course is the universe's (laid out from its seed, course.odin); each race is counted
// down with the racers on the start, timed through the gates in order, and its times
// shown. A fall or a hazard sends a racer back to its last gate. The personal bests (with
// their splits) and the course record are kept with the universe.

GAME :: core.Game {
	info         = rally.INFO,
	kinds        = rally.KINDS,
	pack         = rally.PACK,
	server_state = Rally,
	client_state = Runner,
	configure    = configure,
	start        = start,
	stop         = stop,
	tick         = tick,
	joined       = joined,
	left         = left,
	command      = command,
	editing      = editing,
	save         = save,
	load         = load,
}

MAX_KEPT :: 64 // racers' bests kept, by name

// Rally: the races.
Rally :: struct {
	phase:     play.Phase(rally.Phase),
	race:      u16,
	seed:      u32, // the course's (the universe's)
	course:    rally.Course,
	built:     bool,
	countdown: f64, // this race's count, seconds
	record:    Best, // the course record (ticks 0: none)
	kept:      play.By_Name(Run, MAX_KEPT), // each racer's personal best, by name
	pad, gate: game.Block,
	hazard:    game.Block,
}

// Run: a run kept: its time and its splits at each gate (ticks); a Best is whose it is too.
Run :: struct {
	ticks:  u32,
	splits: [rally.CHECKPOINTS + 1]u32,
}

Best :: play.Named(Run)

best_name :: proc(b: ^Best) -> string {return play.named_name(b)}

// Runner: a player's part in the race now.
Runner :: struct {
	race:   u16, // the race it races (0: none)
	racing: bool, // ... and races it (else watches)
	next:   int, // the checkpoint it makes for (CHECKPOINTS + 1: finished)
	time:   u32, // its finish's ticks
	splits: [rally.CHECKPOINTS + 1]u32,
	resets: int,
}

state :: proc(s: ^core.Server) -> ^Rally {return core.game_state(s, Rally)}
runner :: proc(s: ^core.Server, c: ^core.Client) -> ^Runner {return core.game_client_state(
		s,
		c,
		Runner,
	)}

NODE_ADMIN :: "rally.admin"

configure :: proc(config: ^core.Config) {
	play.configure_flat(config, {3.5, rally.TOP + 1, 0.5}, rally.WATCHER_MODE)
}

// start: the home world stands at noon, still, with nothing dropped and no friendly fire
// (a rocket pushes, it does not hurt another racer); the course's names are looked up and
// its area kept loaded.
start :: proc(s: ^core.Server) -> bool {
	d := state(s)
	d.seed = u32(s.config.seed)
	d.course = rally.course_plan(d.seed)
	w := s.home
	play.world_still(s, w)
	core.game_rule(s, w, "pvp", "false")
	reg := s.registry
	d.pad = game.registry_block(reg, rally.PAD_BLOCK) or_return
	d.gate = game.registry_block(reg, rally.GATE_BLOCK) or_return
	d.hazard = game.registry_block(reg, rally.HAZARD_BLOCK) or_return
	core.world_keep(w, play.arena_area(COURSE))
	log.infof("rally started seed=%d", d.seed)
	return true
}

stop :: proc(s: ^core.Server) {
	log.infof("rally stopped races=%d record=%d", state(s).race, state(s).record.ticks)
}

seconds :: proc(s: ^core.Server) -> f64 {return play.phase_seconds(s, &state(s).phase)}

set_phase :: proc(s: ^core.Server, p: rally.Phase) {play.phase_set(s, &state(s).phase, p)}

// race_ticks: the race's clock.
race_ticks :: proc(s: ^core.Server) -> u32 {
	d := state(s)
	if d.phase.now != .Racing {return 0}
	return u32(s.tick - d.phase.since)
}

joined :: proc(s: ^core.Server, c: ^core.Client) {
	core.notice(
		s,
		c,
		"Rally: through every gate in order; /rally reset takes you back to your last",
	)
	d := state(s)
	if d.phase.now == .Countdown && d.built {
		line_up(s, c)
	} else {
		watch(s, c)
	}
}

left :: proc(s: ^core.Server, c: ^core.Client) {
	runner(s, c)^ = {}
}

// line_up: c races the next race: the racer's mode and kit, on the start.
line_up :: proc(s: ^core.Server, c: ^core.Client) {
	d := state(s)
	runner(s, c)^ = {
		race   = d.race,
		racing = true,
		next   = 1,
	}
	core.game_mode(s, c, rally.RACER_MODE)
	core.kit_give(s, c)
	play.hold(s, c, "voxiverse:grappling_hook")
	core.teleport(s, c, place_at(&d.course, 0, int(core.player_id(s, c))), EAST)
}

// watch: c watches the race from over the start.
watch :: proc(s: ^core.Server, c: ^core.Client) {
	runner(s, c).racing = false
	at := [3]f64{-6, rally.TOP + 10, 0.5}
	play.watch(s, c, rally.WATCHER_MODE, at, {40, rally.TOP, 0.5})
}

// countdown: the next race: everyone here on the start.
countdown :: proc(s: ^core.Server) {
	d := state(s)
	d.race += 1
	set_phase(s, .Countdown)
	for &c in s.clients {if play.here(s, &c) {line_up(s, &c)}}
	log.infof("rally race=%d racers=%d", d.race, play.present(s))
}

// racing: c races the race on now (not finished, or finished: still counted).
racing :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	r := runner(s, c)
	return play.here(s, c) && r.racing && r.race == state(s).race
}

tick :: proc(s: ^core.Server) {
	d := state(s)
	present := play.present(s)
	t := seconds(s)
	switch d.phase.now {
	case .Waiting:
		if present == 0 {break}
		if !d.built && !build(s, force = t >= rally.BUILD_WAIT) {break}
		countdown(s)
	case .Countdown:
		if present == 0 {
			set_phase(s, .Waiting)
			break
		}
		// (the longer count while others are here to race: one who joins lengthens it)
		d.countdown = rally.COUNTDOWN_MANY if present > 1 else rally.COUNTDOWN
		for &c in s.clients {
			if !racing(s, &c) {continue}
			// (on the start until the off: a racer who steps off is put back)
			if !rally.at_checkpoint(&d.course, 0, c.player.position) {
				core.teleport(s, &c, place_at(&d.course, 0, int(core.player_id(s, &c))), EAST)
			}
		}
		if t >= d.countdown {
			set_phase(s, .Racing)
			core.announce(s, fmt.tprintf("&bRace %d&r: go!", d.race))
		}
	case .Racing:
		run(s)
		left, still := 0, 0
		for &c in s.clients {
			if !racing(s, &c) {continue}
			left += 1
			if runner(s, &c).next <= rally.CHECKPOINTS {still += 1}
		}
		if left == 0 || still == 0 || t >= rally.RACE_MAX {results(s)}
	case .Results:
		if t >= rally.RESULTS {
			if present > 0 {countdown(s)} else {set_phase(s, .Waiting)}
		}
	}
	put_records(s)
}

// run: a tick of the race for every racer still on the course: a fall or a hazard sends
// it back, a gate passed is a split, the last is its finish.
run :: proc(s: ^core.Server) {
	d := state(s)
	for &c in s.clients {
		r := runner(s, &c)
		if !racing(s, &c) || r.next > rally.CHECKPOINTS {continue}
		p := c.player.position
		feet := game.Block_Pos {
			i32(math.floor(p.x)),
			i32(math.floor(p.y - 0.05)),
			i32(math.floor(p.z)),
		}
		under, _ := core.block_at(s.home, feet)
		if p.y < rally.FALL || under == d.hazard {
			send_back(s, &c)
			continue
		}
		if rally.at_checkpoint(&d.course, r.next, p) {passed(s, &c)}
	}
}

// send_back: c is back at its last gate, still.
send_back :: proc(s: ^core.Server, c: ^core.Client) {
	d := state(s)
	r := runner(s, c)
	r.resets += 1
	core.teleport(s, c, place_at(&d.course, r.next - 1, int(core.player_id(s, c))), EAST)
}

// passed: c passed the gate it made for: its split, told it against its best's; the
// last gate is its finish.
passed :: proc(s: ^core.Server, c: ^core.Client) {
	r := runner(s, c)
	ticks := race_ticks(s)
	k := r.next
	r.splits[k] = ticks
	r.next += 1
	split := rally.Split {
		checkpoint = u8(k),
		ticks      = ticks,
	}
	if b := kept(s, core.client_name(c)); b != nil && b.ticks > 0 {
		split.delta, split.compared = i32(ticks) - i32(b.splits[k]), true
	}
	core.game_event(s, c, &split)
	if k == rally.CHECKPOINTS {finish(s, c, ticks)}
}

// finish: c finished in ticks: a personal best kept with its splits, a course record
// told to everyone.
finish :: proc(s: ^core.Server, c: ^core.Client, ticks: u32) {
	d := state(s)
	r := runner(s, c)
	r.time = ticks
	name := core.client_name(c)
	news := rally.Finish {
		name  = name,
		ticks = ticks,
	}
	b := kept(s, name, make_it = true)
	if b != nil && (b.ticks == 0 || ticks < b.ticks) {
		b.ticks, b.splits = ticks, r.splits
		news.personal = true
	}
	if d.record.ticks == 0 || ticks < d.record.ticks {
		d.record = {}
		d.record.ticks, d.record.splits = ticks, r.splits
		d.record.name_len = copy(d.record.name[:], name)
		news.record = true
	}
	for &o in s.clients {if play.here(s, &o) {core.game_event(s, &o, &news)}}
	core.announce(
		s,
		fmt.tprintf(
			"&e%s&r finished in %s%s",
			name,
			rally.clock(ticks),
			", a course record" if news.record else (", a personal best" if news.personal else ""),
		),
	)
	log.infof("rally finish race=%d name=%s ticks=%d record=%v", d.race, name, ticks, news.record)
}

// results: the race is over: everyone watches the times.
results :: proc(s: ^core.Server) {
	set_phase(s, .Results)
}

// kept: the best kept for a racer's name (nil: none; make_it: a new one, while there is
// room).
kept :: proc(s: ^core.Server, name: string, make_it := false) -> ^Best {
	return play.by_name(&state(s).kept, name, make_it)
}

// editing: the course is not the racers' to change.
editing :: proc(
	s: ^core.Server,
	c: ^core.Client,
	at: game.Block_Pos,
	old, new: game.Block,
) -> string {
	return "The course stays as it is"
}

// put_records: the race to everyone, every racer's progress to every player.
put_records :: proc(s: ^core.Server) {
	d := state(s)
	race := rally.Race {
		phase       = d.phase.now,
		race        = d.race,
		seed        = d.seed,
		ticks       = race_ticks(s),
		record      = d.record.ticks,
		record_name = best_name(&d.record),
	}
	#partial switch d.phase.now {
	case .Countdown:
		race.left = play.phase_left(s, &d.phase, d.countdown)
	case .Results:
		race.left = play.phase_left(s, &d.phase, rally.RESULTS)
	}
	for &c in s.clients {
		if !racing(s, &c) {continue}
		race.racers += 1
		if runner(s, &c).time > 0 {race.finished += 1}
	}
	for &c in s.clients {
		if !play.here(s, &c) {continue}
		core.game_put(s, &c, &race)
		for &o in s.clients {
			if !play.here(s, &o) {continue}
			r := runner(s, &o)
			mine := racing(s, &o)
			v := rally.Racer {
				name   = core.client_name(&o),
				next   = u8(r.next) if mine else 0,
				time   = r.time if mine else 0,
				racing = mine,
				resets = u16(min(r.resets, 65535)),
			}
			if b := kept(s, v.name); b != nil {v.best = b.ticks}
			core.game_put(s, &c, &v, protocol.key_player(core.player_id(s, &o)))
		}
	}
}

// command: /rally shows the race and the record; /rally reset takes you back to your
// last gate; the admin's: /rally restart counts a new race now, /rally gate <n> stands
// you at gate n (to try the course).
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name != "rally" {return false}
	d := state(s)
	switch {
	case len(args) == 0:
		record := "none yet"
		if d.record.ticks >
		   0 {record = fmt.tprintf("%s by %s", rally.clock(d.record.ticks), best_name(&d.record))}
		mine := "none yet"
		if b := kept(s, core.client_name(c)); b != nil && b.ticks > 0 {mine = rally.clock(b.ticks)}
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Rally race %d, %v, course %d: record %s, yours %s",
				d.race,
				d.phase.now,
				d.seed,
				record,
				mine,
			),
		)
		return true
	case len(args) == 1 && args[0] == "reset":
		if d.phase.now != .Racing || !racing(s, c) || runner(s, c).next > rally.CHECKPOINTS {
			core.notice(s, c, "Rally: you are not on the course")
			return true
		}
		send_back(s, c)
		return true
	}
	if !core.allowed(s, c, NODE_ADMIN) {
		core.notice(s, c, "You may not change the race (rally.admin)")
		return true
	}
	switch {
	case len(args) == 1 && args[0] == "restart":
		if !d.built {
			core.notice(s, c, "Rally: the course is not built yet")
			return true
		}
		countdown(s)
	case len(args) == 2 && args[0] == "gate":
		n, ok := strconv.parse_int(args[1])
		if !ok || n < 0 || n > rally.CHECKPOINTS {
			core.notice(s, c, fmt.tprintf("Usage: rally gate <0..%d>", rally.CHECKPOINTS))
			return true
		}
		core.teleport(s, c, place_at(&d.course, n, 0) - {2, 0, 0}, EAST)
	case:
		core.notice(s, c, "Usage: rally [reset | restart | gate <n>]")
	}
	return true
}

// save: the course record and every racer's best with its splits, by name:
// "record <ticks> <name>", "best = <ticks> <split>... <name>" (play.by_name_save).
save :: proc(s: ^core.Server, out: ^strings.Builder) {
	d := state(s)
	if d.record.ticks >
	   0 {fmt.sbprintfln(out, "record %d %s", d.record.ticks, best_name(&d.record))}
	play.by_name_save(&d.kept, "best", out, proc(b: ^strings.Builder, run: ^Run) -> bool {
		if run.ticks == 0 {return false}
		fmt.sbprintf(b, "%d", run.ticks)
		for split in run.splits[1:] {fmt.sbprintf(b, " %d", split)}
		return true
	})
}

// load: what the universe kept (a best's line as before by_name, `best <numbers> <name>`,
// reads as one written by it); a line Rally does not know is not Rally's.
load :: proc(s: ^core.Server, text: string) -> bool {
	d := state(s)
	for l in play.saved_lines(text) {
		switch l.key {
		case "record":
			f := strings.fields(l.value, context.temp_allocator)
			if len(f) != 2 {return false}
			ticks, ok := strconv.parse_u64(f[0])
			if !ok ||
			   ticks == 0 ||
			   ticks > u64(max(u32)) ||
			   len(f[1]) > game.MAX_NAME_LENGTH {return false}
			d.record = {}
			d.record.ticks = u32(ticks)
			d.record.name_len = copy(d.record.name[:], f[1])
			if b := kept(s, f[1]); b != nil {d.record.splits = b.splits}
		case "best":
			play.by_name_read(&d.kept, "best", l, proc(fields: []string, run: ^Run) -> bool {
				if len(fields) != 1 + rally.CHECKPOINTS {return false}
				for n, i in fields {
					v, ok := strconv.parse_u64(n)
					if !ok || v > u64(max(u32)) {return false}
					if i == 0 {run.ticks = u32(v)} else {run.splits[i] = u32(v)}
				}
				return true
			}) or_return
		case:
			return false
		}
	}
	return true
}
