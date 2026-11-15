package flood_server

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"

import "common:base"
import "common:game"
import "games:flood"
import "server:core"

// Flood's server part (the game: games/flood): it runs the rounds in the home world. A
// round is built (arena.odin), counted down, played while the water rises under its
// rule, and revealed; then the next begins while anyone is there. Each player is told
// the round (flood.Round) every tick it changes.

GAME :: core.Game {
	id           = "flood",
	kinds        = flood.KINDS,
	pack         = flood.PACK,
	server_state = Flood,
	client_state = Runner,
	configure    = configure,
	start        = start,
	stop         = stop,
	tick         = tick,
	joined       = joined,
	command      = command,
}

// Flood: the rounds.
Flood :: struct {
	phase:      flood.Phase,
	rule:       flood.Rule,
	forced:     Maybe(flood.Rule), // the next round's (/flood rule)
	result:     flood.Result,
	round:      u16,
	seed:       u32, // the arena's
	rng:        base.Rng, // the rounds' seeds and rules (from the universe's seed)
	phase_tick: u64, // the server tick the phase began
	built:      bool, // the round's arena is there
	level:      i32, // the water's top layer (0: the floor's, none)
	goal:       [2]i32, // the goal platform's corner (x, z)
	wet_at:     [flood.HEIGHT]f32, // Rot: seconds into play each layer got wet (-1: dry)
	rot_last:   f32, // Rot: seconds into play of the last pass
	rotted:     int, // Rot: blocks crumbled this round
	made_it:    int,
}

// Runner: a player's part in the rounds.
Runner :: struct {
	round:   u16, // the round it was placed in (0: none yet)
	playing: bool, // ... and plays it (else arrived during it, and watches)
	out:     bool, // out of it: watching
	under:   int, // ticks its head has been under water (or it has been outside the walls)
}

state :: proc(s: ^core.Server) -> ^Flood {return core.game_state(s, Flood)}
runner :: proc(s: ^core.Server, c: ^core.Client) -> ^Runner {return core.game_client_state(
		s,
		c,
		Runner,
	)}

// NODE_ROUND: the permission /flood restart, rule and goal need (the host has it).
NODE_ROUND :: "flood.round"

// configure: a flat world with nothing wandering in it, arriving at the arena's spawn,
// watching until the next round places a player.
configure :: proc(config: ^core.Config) {
	config.generator = .Flat
	config.no_natural_spawns = true
	config.spawn = flood.SPAWN
	if config.mode == "" {config.mode = flood.OUT_MODE}
}

// start: the home world stands at noon with nothing changing by itself and nothing
// dropped (no pillaring up with what is broken), and keeps the arena loaded.
start :: proc(s: ^core.Server) -> bool {
	f := state(s)
	f.rng = base.rng_make(u64(s.config.seed) ~ 0xf100d)
	w := s.home
	w.rules.daylight_cycle = false
	w.rules.drops = false
	w.rules.random_tick_speed = 0
	w.clock = 0.5
	core.world_keep(w, ARENA)
	log.infof("flood started seed=%d", s.config.seed)
	return true
}

stop :: proc(s: ^core.Server) {
	f := state(s)
	log.infof("flood stopped rounds=%d", f.round)
}

joined :: proc(s: ^core.Server, c: ^core.Client) {
	core.notice(s, c, "Flood: climb to the glowing platform before the water reaches you")
}

// seconds: whole and part seconds into the phase.
seconds :: proc(s: ^core.Server) -> f32 {
	return f32(s.tick - state(s).phase_tick) / f32(game.TICK_RATE)
}

set_phase :: proc(s: ^core.Server, phase: flood.Phase) {
	f := state(s)
	f.phase, f.phase_tick = phase, s.tick
}

// new_round: a new seed and rule (the forced one, if any); the arena is built in the
// countdown. Under Heavy the world's explosions are larger and throw harder.
new_round :: proc(s: ^core.Server) {
	f := state(s)
	f.round += 1
	f.seed = base.rng_u32(&f.rng)
	if rule, forced := f.forced.?; forced {
		f.rule, f.forced = rule, nil
	} else {
		f.rule = flood.Rule(base.rng_int_max(&f.rng, len(flood.Rule)))
	}
	heavy := f.rule == .Heavy
	s.home.rules.explosion_size = flood.HEAVY_SIZE if heavy else 1
	s.home.rules.explosion_throw = flood.HEAVY_THROW if heavy else 1
	f.result, f.made_it, f.built = .None, 0, false
	set_phase(s, .Countdown)
	log.infof("flood round=%d seed=%d rule=%s", f.round, f.seed, flood.RULE_NAMES[f.rule])
}

// here: c is playing in the home world, where the rounds are.
here :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	return c.state == .Playing && c.world == s.home
}

// enlist: c plays this round: a runner with the kit, at the spawn (a step apart from
// the next player).
enlist :: proc(s: ^core.Server, c: ^core.Client, seat: int) {
	r := runner(s, c)
	r^ = {
		round   = state(s).round,
		playing = true,
	}
	core.game_mode(s, c, flood.RUNNER_MODE)
	core.kit_give(s, c)
	jitter := [3]f64{f64(seat % 3) - 1, 0, f64(seat / 3 % 3) - 1}
	core.teleport(s, c, flood.SPAWN + jitter, {0, 0})
}

// spectate: c watches the rest of the round (out, or arrived during it), flying above
// the arena and looking down into it.
spectate :: proc(s: ^core.Server, c: ^core.Client) {
	r := runner(s, c)
	r.round, r.out, r.under = state(s).round, true, 0
	core.game_mode(s, c, flood.OUT_MODE)
	core.teleport(s, c, flood.SPECTATE, {0, -1.2}, flying = true)
}

// on_goal: c stands on the goal platform.
on_goal :: proc(f: ^Flood, c: ^core.Client) -> bool {
	p := c.player.position
	return(
		p.x >= f64(f.goal.x) &&
		p.x < f64(f.goal.x + flood.GOAL_SIZE) &&
		p.z >= f64(f.goal.y) &&
		p.z < f64(f.goal.y + flood.GOAL_SIZE) &&
		p.y >= flood.GOAL_Y + 0.9 &&
		p.y < flood.GOAL_Y + 4 \
	)
}

// outside: c is outside the arena's walls (or above them).
outside :: proc(c: ^core.Client) -> bool {
	p := c.player.position
	return p.x < 0 || p.z < 0 || p.x >= flood.SIZE || p.z >= flood.SIZE || p.y > flood.WALL_TOP
}

// in_round: c plays the round now running.
in_round :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	r := runner(s, c)
	return here(s, c) && r.round == state(s).round && r.playing
}

end_round :: proc(s: ^core.Server, result: flood.Result, made_it: int) {
	f := state(s)
	f.result, f.made_it = result, made_it
	played := seconds(s)
	set_phase(s, .Reveal)
	players := 0
	for &c in s.clients {if in_round(s, &c) {players += 1}}
	head: string
	switch result {
	case .Won:
		head = "&aROUND WON"
	case .Lost:
		head = "&cEVERYONE DROWNED"
	case .Time_Up:
		head = "&eTIME UP"
	case .None:
	}
	core.announce(
		s,
		fmt.tprintf(
			"%s&r: %d of %d made it. The rule was &l%s",
			head,
			made_it,
			players,
			strings.to_upper(flood.RULE_NAMES[f.rule], context.temp_allocator),
		),
	)
	log.infof(
		"flood round over round=%d result=%v made_it=%d players=%d rule=%s level=%d seconds=%.0f",
		f.round,
		result,
		made_it,
		players,
		flood.RULE_NAMES[f.rule],
		f.level,
		played,
	)
}

// tick: once a tick, after the players moved and the entities ran.
tick :: proc(s: ^core.Server) {
	f := state(s)
	present := 0
	for &c in s.clients {if here(s, &c) {present += 1}}
	t := seconds(s)
	switch f.phase {
	case .Waiting:
		if present > 0 {new_round(s)}
	case .Countdown:
		if !f.built {
			if !build(s, force = t >= flood.BUILD_WAIT) {break}
			set_phase(s, .Countdown) // (counted from the build)
			for &c, seat in s.clients {if here(s, &c) {enlist(s, &c, seat)}}
			core.announce(
				s,
				fmt.tprintf(
					"&bRound %d&r: climb to the glowing platform. Something is different.",
					f.round,
				),
			)
			break
		}
		for &c, seat in s.clients {
			if here(s, &c) && runner(s, &c).round != f.round {enlist(s, &c, seat)}
		}
		if present == 0 {
			set_phase(s, .Waiting)
		} else if t >= flood.COUNTDOWN {
			set_phase(s, .Playing)
		}
	case .Playing:
		play(s, t)
	case .Reveal:
		if t >= flood.REVEAL {
			if present > 0 {new_round(s)} else {set_phase(s, .Waiting)}
		}
	}
	round_put(s)
}

// play: a tick of play, t seconds in: the water, the rule, who is out, and whether the
// round is over.
play :: proc(s: ^core.Server, t: f32) {
	f := state(s)
	for &c in s.clients {
		if r := runner(s, &c); here(s, &c) && r.round != f.round {
			r.playing = false // (arrived during it: watches, and is not counted)
			spectate(s, &c)
		}
	}
	water_tick(s, flood.water_level(f.rule, t))
	if f.rule == .Rot {rot_tick(s, t)}
	if s.tick % (5 * game.TICK_RATE) == 0 {
		log.infof(
			"flood status round=%d rule=%s t=%.0f level=%d rotted=%d",
			f.round,
			flood.RULE_NAMES[f.rule],
			t,
			f.level,
			f.rotted,
		)
	}
	players, alive, goal := 0, 0, 0
	for &c in s.clients {
		if !in_round(s, &c) {continue}
		players += 1
		r := runner(s, &c)
		if r.out {continue}
		if outside(&c) || core.head_in_water(s, &c) {
			r.under += 1
		} else {
			r.under = 0
		}
		if r.under >= int(flood.DROWN * game.TICK_RATE) {
			core.announce(s, fmt.tprintf("&c%s is out", core.client_name(&c)))
			log.infof(
				"flood out name=%s at=%v level=%d",
				core.client_name(&c),
				c.player.position,
				f.level,
			)
			spectate(s, &c)
			continue
		}
		alive += 1
		if on_goal(f, &c) {goal += 1}
	}
	switch {
	case players == 0:
		set_phase(s, .Waiting) // (everyone left)
	case alive == 0:
		end_round(s, .Lost, 0)
	case goal == alive:
		end_round(s, .Won, goal)
	case t >= flood.ROUND_MAX:
		end_round(s, .Time_Up, goal)
	}
}

// round_put tells every player the round (only what changed is sent).
round_put :: proc(s: ^core.Server) {
	f := state(s)
	t := seconds(s)
	round := flood.Round {
		phase   = f.phase,
		rule    = f.rule,
		result  = f.result,
		round   = f.round,
		seed    = f.seed,
		seconds = u16(t),
		level   = i16(f.level),
		goal_x  = i16(f.goal.x),
		goal_z  = i16(f.goal.y),
		made_it = u8(f.made_it),
	}
	#partial switch f.phase {
	case .Countdown:
		round.countdown =
			u8(math.ceil(max(flood.COUNTDOWN - t, 0))) if f.built else u8(flood.COUNTDOWN)
	case .Reveal:
		round.countdown = u8(math.ceil(max(flood.REVEAL - t, 0)))
	}
	for &c in s.clients {
		if !in_round(s, &c) {continue}
		round.players += 1
		if !runner(s, &c).out {
			round.alive += 1
			if on_goal(f, &c) {round.on_goal += 1}
		}
	}
	for &c in s.clients {
		if c.state != .Playing {continue}
		r := runner(s, &c)
		mine := round
		mine.out = r.out && r.round == f.round
		mine.under = u8(min(r.under * 10 / game.TICK_RATE, 255))
		core.game_put(s, &c, &mine)
	}
}

// command: /flood shows the round; /flood restart starts a new one; /flood rule <name>
// starts one under that rule (random: any); /flood goal stands you on the goal (to try it).
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name != "flood" {return false}
	f := state(s)
	if len(args) == 0 {
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Flood round %d, %v, rule %s, seed %d, water at y=%d (rules: baseline tide rot heavy)",
				f.round,
				f.phase,
				flood.RULE_NAMES[f.rule],
				f.seed,
				f.level,
			),
		)
		return true
	}
	if !core.allowed(s, c, NODE_ROUND) {
		core.notice(s, c, "You may not change the round (flood.round)")
		return true
	}
	switch {
	case len(args) == 1 && args[0] == "restart":
		new_round(s)
		core.notice(s, c, "Flood: new round")
	case len(args) == 1 && args[0] == "goal":
		at := [3]f64{f64(f.goal.x) + 3.5, flood.GOAL_Y + 1, f64(f.goal.y) + 3.5}
		core.teleport(s, c, at, {0, 0})
	case len(args) == 2 && args[0] == "rule" && args[1] == "random":
		f.forced = nil
		new_round(s)
		core.notice(s, c, "Flood: new round under a rule of its own")
	case len(args) == 2 && args[0] == "rule":
		rule, known := flood.rule_parse(args[1])
		if !known {
			core.notice(s, c, "Flood rules: baseline tide rot heavy random")
			return true
		}
		f.forced = rule
		new_round(s)
		core.notice(s, c, fmt.tprintf("Flood: new round under %s", args[1]))
	case:
		core.notice(s, c, "Usage: flood [restart | rule <baseline|tide|rot|heavy|random> | goal]")
	}
	return true
}
