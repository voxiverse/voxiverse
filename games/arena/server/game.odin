package arena_server

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"

import "common:base"
import "common:game"
import "games:arena"
import "server:core"

// Arena's server part (the game: games/arena): it runs the matches in the home world. A
// warm-up waits for enough players; a match is built (courtyard.odin), counted down,
// fought to the frag limit or the time limit, and its winner shown; then the next
// begins in a new courtyard. The engine's damage pipeline does the fighting and says
// who killed whom (the died hook); the respawn rules bring the dead back, and the
// respawned hook puts them at the spawn point farthest from everyone else.

GAME :: core.Game {
	info         = arena.INFO,
	kinds        = arena.KINDS,
	pack         = arena.PACK,
	server_state = Arena,
	client_state = Fighter,
	configure    = configure,
	start        = start,
	stop         = stop,
	tick         = tick,
	joined       = joined,
	command      = command,
	died         = died,
	respawned    = respawned,
	save         = save,
	load         = load,
}

// Arena: the matches.
Arena :: struct {
	settings:   arena.Settings,
	phase:      arena.Phase,
	match:      u16, // 0: the warm-up before the first
	seed:       u32, // the courtyard's
	rng:        base.Rng, // the courtyards' seeds (from the universe's seed)
	phase_tick: u64, // the server tick the phase began
	built:      bool, // the phase's courtyard is there
	spawns:     [arena.SPAWNS][3]f64,
	turn:       int, // the spawn point tried first next (equal choices take turns)
	winner:     [game.MAX_NAME_LENGTH]u8, // the last match's ("": a draw)
	winner_len: int,
	top_frags:  int,
}

// Fighter: a player's score in the match it was counted in.
Fighter :: struct {
	match:  u16,
	frags:  int,
	deaths: int,
}

state :: proc(s: ^core.Server) -> ^Arena {return core.game_state(s, Arena)}
fighter :: proc(s: ^core.Server, c: ^core.Client) -> ^Fighter {return core.game_client_state(
		s,
		c,
		Fighter,
	)}

// NODE_ADMIN: the permission the match's rules need (/arena frags, time, respawn,
// start, restart; the host has it).
NODE_ADMIN :: "arena.admin"

// OVERLOOK: where watchers float between matches, above the north wall looking down
// into the courtyard, side by side (each its seat's place along the wall).
OVERLOOK :: [3]f64{arena.SIZE / 2 + 0.5, arena.HEIGHT - 2, 2.5}
OVERLOOK_SPACING :: 2.0

// LAUNCHER: what a fighter holds when it comes in.
LAUNCHER :: "voxiverse:rocket_launcher"

// configure: a flat world with nothing wandering in it, arriving above the keep.
configure :: proc(config: ^core.Config) {
	config.generator = .Flat
	config.no_natural_spawns = true
	config.spawn = {arena.SIZE / 2 + 0.5, 4, arena.SIZE / 2 + 0.5}
	if config.mode == "" {config.mode = arena.WATCHING_MODE}
}

// start: the home world stands at noon with nothing changing by itself and nothing
// dropped, fights (pvp) and brings the dead back by itself; the courtyard is kept
// loaded and built for the warm-up.
start :: proc(s: ^core.Server) -> bool {
	a := state(s)
	a.settings = arena.DEFAULT_SETTINGS
	a.rng = base.rng_make(u64(s.config.seed) ~ 0xa7e4a)
	a.seed = base.rng_u32(&a.rng)
	w := s.home
	core.game_rule(s, w, "daylight_cycle", "false")
	core.game_rule(s, w, "drops", "false")
	core.game_rule(s, w, "random_tick_speed", "0")
	core.game_rule(s, w, "pvp", "true")
	core.game_rule(s, w, "respawn_auto", "true")
	core.game_rule(s, w, "spawn_protection", fmt.tprint(arena.SPAWN_PROTECTION))
	rules_apply(s)
	w.clock = 0.5
	core.world_keep(w, AREA)
	set_phase(s, .Warmup)
	log.infof("arena started seed=%d", s.config.seed)
	return true
}

// rules_apply: the settings the world's rules carry (the respawn delay).
rules_apply :: proc(s: ^core.Server) {
	core.game_rule(s, s.home, "respawn_delay", fmt.tprint(state(s).settings.respawn_delay))
}

stop :: proc(s: ^core.Server) {
	log.infof("arena stopped matches=%d", state(s).match)
}

// here: c is playing in the home world, where the matches are.
here :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	return c.state == .Playing && c.world == s.home
}

seconds :: proc(s: ^core.Server) -> f32 {
	return f32(s.tick - state(s).phase_tick) / f32(game.TICK_RATE)
}

set_phase :: proc(s: ^core.Server, phase: arena.Phase) {
	a := state(s)
	a.phase, a.phase_tick = phase, s.tick
}

joined :: proc(s: ^core.Server, c: ^core.Client) {
	a := state(s)
	fighter(s, c)^ = {
		match = a.match,
	}
	core.notice(s, c, "Arena: every kill is a frag; hold P for the scoreboard")
	switch a.phase {
	case .Warmup, .Playing:
		if a.built {enlist(s, c)} else {watch(s, c)}
	case .Countdown, .Results:
		watch(s, c)
	}
}

// enlist: c fights: a fighter with the kit, the launcher in hand, at a spawn point.
enlist :: proc(s: ^core.Server, c: ^core.Client) {
	core.game_mode(s, c, arena.FIGHTER_MODE)
	core.kit_give(s, c)
	hold_launcher(s, c)
	place(s, c)
}

hold_launcher :: proc(s: ^core.Server, c: ^core.Client) {
	launcher, known := game.registry_item(s.registry, LAUNCHER)
	if !known {return}
	for st, slot in c.inventory.slots[:game.HOTBAR_SLOTS] {
		if st.item == launcher {
			core.hotbar_select(s, c, slot)
			return
		}
	}
}

// place: c stands at the spawn point farthest from every other fighter, looking at the
// keep.
place :: proc(s: ^core.Server, c: ^core.Client) {
	a := state(s)
	others := make([dynamic][3]f64, context.temp_allocator)
	for &o in s.clients {
		if &o != c && here(s, &o) && !o.dead {append(&others, o.player.position)}
	}
	i := arena.farthest(a.spawns[:], others[:], a.turn)
	a.turn = i + 1
	at := a.spawns[i]
	d := [2]f64{arena.SIZE / 2 - at.x, arena.SIZE / 2 - at.z}
	core.teleport(s, c, at, {f32(math.atan2(-d.x, -d.y)), 0})
}

// watch: c floats above the courtyard between matches, unharmed, looking into it.
watch :: proc(s: ^core.Server, c: ^core.Client) {
	core.game_mode(s, c, arena.WATCHING_MODE)
	seat := f64(core.player_id(s, c) % 16)
	along := (seat - 7.5) * OVERLOOK_SPACING // (16 seats fit the wall)
	core.teleport(s, c, OVERLOOK + {along, 0, 0}, {math.PI, -0.6}, flying = true)
}

// countdown: the next match: a new courtyard, built while everyone watches.
countdown :: proc(s: ^core.Server) {
	a := state(s)
	a.match += 1
	a.seed = base.rng_u32(&a.rng)
	a.built = false
	set_phase(s, .Countdown)
	for &c in s.clients {if here(s, &c) {watch(s, &c)}}
	log.infof("arena countdown match=%d seed=%d", a.match, a.seed)
}

// begin: the match is on: every score starts at nought, everyone fights.
begin :: proc(s: ^core.Server) {
	a := state(s)
	set_phase(s, .Playing)
	for &c in s.clients {
		if !here(s, &c) {continue}
		fighter(s, &c)^ = {
			match = a.match,
		}
		enlist(s, &c)
	}
	core.announce(
		s,
		fmt.tprintf(
			"&bMatch %d&r: first to %d frags, %d:%02d on the clock",
			a.match,
			a.settings.frag_limit,
			a.settings.time_limit / 60,
			a.settings.time_limit % 60,
		),
	)
}

// end: the match is over: the most frags win (fewer deaths break a tie; still tied, a
// draw), everyone watches the results.
end :: proc(s: ^core.Server) {
	a := state(s)
	best: ^core.Client
	draw := false
	for &c in s.clients {
		if !counted(s, &c) {continue}
		if best == nil {
			best = &c
			continue
		}
		f, b := fighter(s, &c), fighter(s, best)
		switch {
		case f.frags > b.frags || (f.frags == b.frags && f.deaths < b.deaths):
			best, draw = &c, false
		case f.frags == b.frags && f.deaths == b.deaths:
			draw = true
		}
	}
	a.winner_len, a.top_frags = 0, 0
	if best != nil {
		a.top_frags = fighter(s, best).frags
		if !draw {a.winner_len = copy(a.winner[:], core.client_name(best))}
	}
	set_phase(s, .Results)
	winner := string(a.winner[:a.winner_len])
	if winner != "" {
		core.announce(
			s,
			fmt.tprintf(
				"&e%s wins match %d&r with %s",
				winner,
				a.match,
				arena.frags_text(a.top_frags),
			),
		)
	} else {
		core.announce(
			s,
			fmt.tprintf("&eMatch %d is a draw&r at %s", a.match, arena.frags_text(a.top_frags)),
		)
	}
	log.infof("arena match over match=%d winner=%q frags=%d", a.match, winner, a.top_frags)
	for &c in s.clients {if here(s, &c) {watch(s, &c)}}
}

// counted: c's score is this match's.
counted :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	return here(s, c) && fighter(s, c).match == state(s).match
}

// tick: once a tick, after the players moved and the entities ran.
tick :: proc(s: ^core.Server) {
	a := state(s)
	present := 0
	for &c in s.clients {if here(s, &c) {present += 1}}
	needed := arena.players_needed(s.listening)
	t := seconds(s)
	switch a.phase {
	case .Warmup:
		if !a.built {
			if build(s, force = t >= arena.BUILD_WAIT) {
				for &c in s.clients {if here(s, &c) {enlist(s, &c)}}
			}
			break
		}
		if present >= needed {countdown(s)}
	case .Countdown:
		if !a.built {
			if build(s, force = t >= arena.BUILD_WAIT) {set_phase(s, .Countdown)} 	// (counted from the build)
			break
		}
		if present < needed {
			a.match -= 1 // (it never began: the next countdown is its number again)
			set_phase(s, .Warmup)
			for &c in s.clients {if here(s, &c) {enlist(s, &c)}}
		} else if t >= arena.COUNTDOWN {
			begin(s)
		}
	case .Playing:
		if present == 0 {
			set_phase(s, .Warmup)
			break
		}
		if t >= f32(a.settings.time_limit) {end(s)}
	case .Results:
		if t >= arena.RESULTS {
			if present >= needed {
				countdown(s)
			} else {
				set_phase(s, .Warmup)
				for &c in s.clients {if here(s, &c) {enlist(s, &c)}}
			}
		}
	}
	if a.phase == .Warmup || a.phase == .Playing {
		for &c in s.clients {if here(s, &c) && !c.dead && outside(&c) {place(s, &c)}}
	}
	match_put(s, present, needed)
}

// outside: c has left the courtyard (over the walls, or under the floor).
outside :: proc(c: ^core.Client) -> bool {
	p := c.player.position
	return(
		p.x < 0 ||
		p.z < 0 ||
		p.x >= arena.SIZE ||
		p.z >= arena.SIZE ||
		p.y < -2 ||
		p.y > arena.WALL_TOP + 4 \
	)
}

// died: a frag to the killer, if another player; else one less to the one who died
// (by its own blast, or a fall). Counted in a match only; the feed tells everyone in
// the warm-up too. The frag limit ends the match at once.
died :: proc(s: ^core.Server, c: ^core.Client, harm: core.Harm) {
	a := state(s)
	by := harm.by
	by_another := by != nil && by != c && here(s, by)
	kill := arena.Kill {
		by     = core.client_name(by) if by_another else "",
		victim = core.client_name(c),
		kind   = harm.kind,
		weapon = harm.weapon,
	}
	for &o in s.clients {if here(s, &o) {core.game_event(s, &o, &kill)}}
	if a.phase != .Playing || !counted(s, c) {return}
	fighter(s, c).deaths += 1
	if !by_another {
		fighter(s, c).frags -= 1
	} else if counted(s, by) {
		f := fighter(s, by)
		f.frags += 1
		if f.frags >= a.settings.frag_limit {end(s)}
	}
}

// respawned: the engine stood c up at the world's spawn with the kit; in a fight it
// goes to the spawn point farthest from the others, between matches it watches.
respawned :: proc(s: ^core.Server, c: ^core.Client) {
	if !here(s, c) {return}
	switch state(s).phase {
	case .Warmup, .Playing:
		hold_launcher(s, c)
		place(s, c)
	case .Countdown, .Results:
		watch(s, c)
	}
}

// match_put tells every player the match and every fighter's score (only what changed
// is sent).
match_put :: proc(s: ^core.Server, present, needed: int) {
	a := state(s)
	t := seconds(s)
	m := arena.Match {
		phase      = a.phase,
		match      = a.match,
		seed       = a.seed,
		seconds    = u16(t),
		frag_limit = u16(a.settings.frag_limit),
		time_limit = u16(a.settings.time_limit),
		players    = u8(present),
		needed     = u8(needed),
		winner     = string(a.winner[:a.winner_len]),
		top_frags  = i16(a.top_frags),
	}
	#partial switch a.phase {
	case .Countdown:
		m.left = u16(math.ceil(max(arena.COUNTDOWN - t, 0))) if a.built else u16(arena.COUNTDOWN)
	case .Playing:
		m.left = u16(math.ceil(max(f32(a.settings.time_limit) - t, 0)))
	case .Results:
		m.left = u16(math.ceil(max(arena.RESULTS - t, 0)))
	}
	for &c in s.clients {
		if !here(s, &c) {continue}
		core.game_put(s, &c, &m)
		for &o in s.clients {
			if !here(s, &o) {continue}
			f := fighter(s, &o)
			score := arena.Score{core.client_name(&o), 0, 0}
			if counted(s, &o) {score.frags, score.deaths = i16(f.frags), u16(f.deaths)}
			core.game_put(s, &c, &score, game.key_player(core.player_id(s, &o)))
		}
	}
}

// command: /arena shows the match and its rules; /arena frags|time|respawn <n> sets one
// (time in seconds), /arena start begins a match now, /arena restart begins a new one.
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name != "arena" {return false}
	a := state(s)
	r := &a.settings
	if len(args) == 0 {
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Arena match %d, %v, seed %d: first to %d frags, %d s, back after %.1f s",
				a.match,
				a.phase,
				a.seed,
				r.frag_limit,
				r.time_limit,
				r.respawn_delay,
			),
		)
		return true
	}
	if !core.allowed(s, c, NODE_ADMIN) {
		core.notice(s, c, "You may not change the match (arena.admin)")
		return true
	}
	USAGE :: "Usage: arena [frags <1..200> | time <30..3600 s> | respawn <0..30 s> | start | restart]"
	switch {
	case len(args) == 1 && (args[0] == "start" || args[0] == "restart"):
		if args[0] == "start" && a.phase != .Warmup {
			core.notice(s, c, "Arena: a match is on already (restart begins a new one)")
			return true
		}
		countdown(s)
		core.notice(s, c, "Arena: a new match")
	case len(args) == 2 && args[0] == "frags":
		n, ok := strconv.parse_int(args[1])
		if !ok || n < 1 || n > arena.FRAG_LIMIT_MAX {
			core.notice(s, c, USAGE)
			return true
		}
		r.frag_limit = n
		core.notice(s, c, fmt.tprintf("Arena: first to %d frags", n))
	case len(args) == 2 && args[0] == "time":
		n, ok := strconv.parse_int(args[1])
		if !ok || n < arena.TIME_LIMIT_MIN || n > arena.TIME_LIMIT_MAX {
			core.notice(s, c, USAGE)
			return true
		}
		r.time_limit = n
		core.notice(s, c, fmt.tprintf("Arena: %d s a match", n))
	case len(args) == 2 && args[0] == "respawn":
		n, ok := strconv.parse_f32(args[1])
		if !ok || !(n >= 0 && n <= arena.RESPAWN_DELAY_MAX) {
			core.notice(s, c, USAGE)
			return true
		}
		r.respawn_delay = n
		rules_apply(s)
		core.notice(s, c, fmt.tprintf("Arena: back %.1f s after a death", n))
	case:
		core.notice(s, c, USAGE)
	}
	return true
}

// save: the match's rules, kept with the universe ("frags = 15" a line).
save :: proc(s: ^core.Server, out: ^strings.Builder) {
	r := state(s).settings
	fmt.sbprintfln(out, "frags = %d", r.frag_limit)
	fmt.sbprintfln(out, "time = %d", r.time_limit)
	fmt.sbprintfln(out, "respawn = %.2f", r.respawn_delay)
}

// load: the rules the universe kept; a line Arena does not know, or a value out of its
// bounds, is not Arena's.
load :: proc(s: ^core.Server, text: string) -> bool {
	r := &state(s).settings
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.trim_space(line) == "" {continue}
		key, _, value := strings.partition(line, "=")
		key, value = strings.trim_space(key), strings.trim_space(value)
		switch key {
		case "frags":
			n, ok := strconv.parse_int(value)
			if !ok || n < 1 || n > arena.FRAG_LIMIT_MAX {return false}
			r.frag_limit = n
		case "time":
			n, ok := strconv.parse_int(value)
			if !ok || n < arena.TIME_LIMIT_MIN || n > arena.TIME_LIMIT_MAX {return false}
			r.time_limit = n
		case "respawn":
			n, ok := strconv.parse_f32(value)
			if !ok || !(n >= 0 && n <= arena.RESPAWN_DELAY_MAX) {return false}
			r.respawn_delay = n
		case:
			return false
		}
	}
	rules_apply(s)
	return true
}
