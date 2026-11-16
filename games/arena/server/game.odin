package arena_server

import "core:fmt"
import "core:log"
import "core:strings"

import "common:base"
import "common:game"
import "games:arena"
import "server:core"
import "server:play"

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
	phase:      play.Phase(arena.Phase),
	match:      u16, // 0: the warm-up before the first
	seed:       u32, // the courtyard's
	rng:        base.Rng, // the courtyards' seeds (from the universe's seed)
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

// NODE_ADMIN: the permission the match's settings and its start need (/arena frags,
// time, respawn, start, restart; the host has it).
NODE_ADMIN :: "arena.admin"

// OVERLOOK: where watchers float between matches, above the north wall looking down
// at the keep, side by side (each its seat's place along the wall).
OVERLOOK :: [3]f64{arena.SIZE / 2 + 0.5, arena.HEIGHT - 2, 2.5}
KEEP :: [3]f64{arena.SIZE / 2, 2, arena.SIZE / 2}

// LAUNCHER: what a fighter holds when it comes in.
LAUNCHER :: "voxiverse:rocket_launcher"

// configure: a flat world with nothing wandering in it, arriving above the keep.
configure :: proc(config: ^core.Config) {
	play.configure_flat(
		config,
		{arena.SIZE / 2 + 0.5, 4, arena.SIZE / 2 + 0.5},
		arena.WATCHING_MODE,
	)
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
	play.world_still(s, w)
	core.game_rule(s, w, "pvp", "true")
	core.game_rule(s, w, "respawn_auto", "true")
	play.world_rule(s, w, "spawn_protection", arena.SPAWN_PROTECTION)
	rules_apply(s)
	core.world_keep(w, play.arena_area(COURTYARD))
	set_phase(s, .Warmup)
	log.infof("arena started seed=%d", s.config.seed)
	return true
}

// rules_apply: the settings the world's rules carry (the respawn delay).
rules_apply :: proc(s: ^core.Server) {
	play.world_rule(s, s.home, "respawn_delay", state(s).settings.respawn)
}

stop :: proc(s: ^core.Server) {
	log.infof("arena stopped matches=%d", state(s).match)
}

here :: play.here

seconds :: proc(s: ^core.Server) -> f32 {return f32(play.phase_seconds(s, &state(s).phase))}

set_phase :: proc(s: ^core.Server, phase: arena.Phase) {play.phase_set(s, &state(s).phase, phase)}

joined :: proc(s: ^core.Server, c: ^core.Client) {
	a := state(s)
	fighter(s, c)^ = {
		match = a.match,
	}
	core.notice(s, c, "Arena: every kill is a frag; hold P for the scoreboard")
	switch a.phase.now {
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
	play.hold(s, c, LAUNCHER)
	place(s, c)
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
	core.teleport(s, c, at, {play.look_at(at, {KEEP.x, at.y, KEEP.z}).x, 0})
}

// watch: c floats above the courtyard between matches, unharmed, looking at the keep.
watch :: proc(s: ^core.Server, c: ^core.Client) {
	play.watch(s, c, arena.WATCHING_MODE, OVERLOOK, KEEP)
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
			a.settings.frags,
			a.settings.time / 60,
			a.settings.time % 60,
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
	present := play.present(s)
	needed := arena.players_needed(s.listening)
	t := seconds(s)
	switch a.phase.now {
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
		if t >= f32(a.settings.time) {end(s)}
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
	if a.phase.now == .Warmup || a.phase.now == .Playing {
		for &c in s.clients {if here(s, &c) && !c.dead && outside(&c) {place(s, &c)}}
	}
	match_put(s, present, needed)
}

// outside: c has left the courtyard (over the walls, or under the floor).
outside :: proc(c: ^core.Client) -> bool {
	return !play.arena_holds(COURTYARD, c.player.position, above = 4, below = 2)
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
	if a.phase.now != .Playing || !counted(s, c) {return}
	fighter(s, c).deaths += 1
	if !by_another {
		fighter(s, c).frags -= 1
	} else if counted(s, by) {
		f := fighter(s, by)
		f.frags += 1
		if f.frags >= a.settings.frags {end(s)}
	}
}

// respawned: the engine stood c up at the world's spawn with the kit; in a fight it
// goes to the spawn point farthest from the others, between matches it watches.
respawned :: proc(s: ^core.Server, c: ^core.Client) {
	if !here(s, c) {return}
	switch state(s).phase.now {
	case .Warmup, .Playing:
		play.hold(s, c, LAUNCHER)
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
		phase      = a.phase.now,
		match      = a.match,
		seed       = a.seed,
		seconds    = u16(t),
		frag_limit = u16(a.settings.frags),
		time_limit = u16(a.settings.time),
		players    = u8(present),
		needed     = u8(needed),
		winner     = string(a.winner[:a.winner_len]),
		top_frags  = i16(a.top_frags),
	}
	#partial switch a.phase.now {
	case .Countdown:
		m.left = play.phase_left(s, &a.phase, arena.COUNTDOWN) if a.built else u16(arena.COUNTDOWN)
	case .Playing:
		m.left = play.phase_left(s, &a.phase, f64(a.settings.time))
	case .Results:
		m.left = play.phase_left(s, &a.phase, arena.RESULTS)
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

// command: /arena shows the match and its settings; /arena <setting> <value> sets one
// (frags, time in seconds, respawn in seconds), /arena start begins a match now, /arena
// restart begins a new one.
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name != "arena" {return false}
	a := state(s)
	table := arena.settings_table()
	if len(args) == 0 {
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Arena match %d, %v, seed %d: %s",
				a.match,
				a.phase.now,
				a.seed,
				play.settings_text(table, &a.settings),
			),
		)
		return true
	}
	if handled, changed := play.settings_command(s, c, table, &a.settings, NODE_ADMIN, args);
	   handled {
		if changed {rules_apply(s)}
		return true
	}
	if !core.allowed(s, c, NODE_ADMIN) {
		core.notice(s, c, "You may not change the match (arena.admin)")
		return true
	}
	switch {
	case len(args) == 1 && (args[0] == "start" || args[0] == "restart"):
		if args[0] == "start" && a.phase.now != .Warmup {
			core.notice(s, c, "Arena: a match is on already (restart begins a new one)")
			return true
		}
		countdown(s)
		core.notice(s, c, "Arena: a new match")
	case:
		core.notice(
			s,
			c,
			fmt.tprintf("Usage: arena [%s | start | restart]", play.settings_usage(table)),
		)
	}
	return true
}

// save: the match's settings, kept with the universe.
save :: proc(s: ^core.Server, out: ^strings.Builder) {
	play.settings_save(arena.settings_table(), &state(s).settings, out)
}

// load: the settings the universe kept (a line Arena does not know, or a value out of
// its bounds, is not Arena's).
load :: proc(s: ^core.Server, text: string) -> bool {
	play.settings_load(arena.settings_table(), &state(s).settings, text) or_return
	rules_apply(s)
	return true
}
