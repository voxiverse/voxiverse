package towers_server

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"

import "common:base"
import "common:game"
import "common:protocol"
import "games:towers"
import "server:core"
import "server:play"

// Towers' server part (the game: games/towers): it runs the runs in the home world. A
// run's field is built from its seed (field.odin); a build phase, then the waves, each
// sent along the creeps' routes to the core (the engine's walkers: core.route_make,
// core.entity_follow), and between them more building. Players build with blocks the
// game charges for (the editing and block_changed hooks; defence.odin), towers shoot by
// themselves, and kills pay (entity_died). Lives at nought lose the run; the last wave
// survived wins it; the results stand, and a new run begins on a new field.

GAME :: core.Game {
	info          = towers.INFO,
	kinds         = towers.KINDS,
	pack          = towers.PACK,
	server_state  = Defence,
	client_state  = Purse,
	configure     = configure,
	start         = start,
	stop          = stop,
	tick          = tick,
	joined        = joined,
	command       = command,
	editing       = editing,
	block_changed = block_changed,
	entity_died   = entity_died,
	save          = save,
	load          = load,
}

MAX_PIECES :: 512 // towers and walls on the field at once (more are refused)

// Defence: the run.
Defence :: struct {
	settings:   towers.Settings,
	phase:      play.Phase(towers.Phase),
	outcome:    towers.Outcome,
	run:        u16,
	wave:       int, // on now, or the last (0: none yet)
	lives:      int,
	seed:       u32, // the field's
	rng:        base.Rng, // the fields' seeds (from the universe's seed)
	built:      bool, // the run's field is there
	// What the pack's names are in this session's registry.
	kinds:      [towers.Creep]game.Kind_Id,
	blocks:     [towers.Piece]game.Block,
	coin:       game.Item,
	core_block: game.Block,
	gate_block: game.Block,
	routes:     [towers.Creep]core.Route_Handle, // gate to core, for each creep's body
	// The wave on its way out of the gate.
	coming:     [towers.Creep]int, // still to come, of each kind
	health:     f64, // its creeps' health, times their kind's
	next_spawn: u64, // the tick the next one comes out
	// The pieces on the field (defence.odin).
	pieces:     [MAX_PIECES]Placed,
	count:      int,
}

// Purse: a player's tally in the run (its coins are its inventory's).
Purse :: struct {
	run:   u16, // the run it was given its coins for
	kills: int,
	spent: int,
}

state :: proc(s: ^core.Server) -> ^Defence {return core.game_state(s, Defence)}
purse :: proc(s: ^core.Server, c: ^core.Client) -> ^Purse {return core.game_client_state(
		s,
		c,
		Purse,
	)}

// NODE_ADMIN: the permission the run's rules need (/towers coins, lives, waves, wave,
// restart; the host has it).
NODE_ADMIN :: "towers.admin"

// OVERLOOK: where a builder arrives, flying high over the field's south border, the gate
// on its left and the core on its right, looking down at the middle.
OVERLOOK :: [3]f64{towers.SIZE_X / 2, 22, -12}

// configure: a flat world with nothing wandering in it, arriving over the field.
configure :: proc(config: ^core.Config) {
	play.configure_flat(config, OVERLOOK, towers.BUILDER_MODE)
}

// start: the home world stands at noon with nothing changing by itself and nothing
// dropped; the field is kept loaded, the pack's names are looked up, the routes made.
start :: proc(s: ^core.Server) -> bool {
	d := state(s)
	d.settings = towers.DEFAULT_SETTINGS
	d.rng = base.rng_make(u64(s.config.seed) ~ 0x70e75)
	w := s.home
	play.world_still(s, w)
	core.game_rule(s, w, "pvp", "false")
	reg := s.registry
	ok := true
	for &k, c in d.kinds {
		k, ok = game.registry_kind(reg, fmt.tprintf("towers:%s", towers.CREEPS[c].kind))
		if !ok {return false}
	}
	for &b, p in d.blocks {
		b, ok = game.registry_block(reg, fmt.tprintf("towers:%s", towers.PIECES[p].block))
		if !ok {return false}
	}
	d.core_block = game.registry_block(reg, towers.CORE_BLOCK) or_return
	d.gate_block = game.registry_block(reg, towers.GATE_BLOCK) or_return
	d.coin = game.registry_item(reg, towers.COIN) or_return
	for &r, c in d.routes {
		r = core.route_make(w, ROUTE_AREA, towers.GATE, towers.GOAL, d.kinds[c]) or_return
	}
	core.world_keep(w, AREA)
	new_run(s)
	log.infof("towers started seed=%d", s.config.seed)
	return true
}

stop :: proc(s: ^core.Server) {
	d := state(s)
	for r in d.routes {core.route_free(s.home, r)}
	log.infof("towers stopped runs=%d", d.run)
}

here :: play.here

seconds :: proc(s: ^core.Server) -> f64 {return play.phase_seconds(s, &state(s).phase)}

set_phase :: proc(s: ^core.Server, phase: towers.Phase) {play.phase_set(s, &state(s).phase, phase)}

// new_run: a new field, every builder's purse full, the lives back, no wave yet.
new_run :: proc(s: ^core.Server) {
	d := state(s)
	clear_creeps(s)
	d.run += 1
	d.seed = base.rng_u32(&d.rng)
	d.wave, d.lives, d.outcome, d.built, d.count = 0, d.settings.lives, .None, false, 0
	d.coming = {}
	set_phase(s, .Building)
	for &c in s.clients {if here(s, &c) {enlist(s, &c)}}
	log.infof("towers run=%d seed=%d", d.run, d.seed)
}

joined :: proc(s: ^core.Server, c: ^core.Client) {
	core.notice(s, c, "Towers: build walls and towers; hold P for the builders")
	enlist(s, c)
}

// enlist: c builds in this run: the builder's mode and kit, the run's coins (once a run),
// over the field.
enlist :: proc(s: ^core.Server, c: ^core.Client) {
	d := state(s)
	core.game_mode(s, c, towers.BUILDER_MODE)
	core.kit_give(s, c)
	if purse(s, c).run != d.run {
		purse(s, c)^ = {
			run = d.run,
		}
		core.item_clear(s, c, d.coin)
		core.item_give(s, c, d.coin, d.settings.coins)
	}
	core.hotbar_select(s, c, 0)
	look := play.look_at(OVERLOOK, {towers.SIZE_X / 2, 0, towers.MID_Z})
	core.teleport(s, c, OVERLOOK, look, flying = true)
}

// tick: once a tick, after the players moved and the entities ran.
tick :: proc(s: ^core.Server) {
	d := state(s)
	t := seconds(s)
	if !d.built {
		if build(s, force = t >= towers.BUILD_WAIT) {
			d.built = true
			set_phase(s, .Building) // (the time to build counts from the field)
		}
		run_put(s)
		return
	}
	switch d.phase.now {
	case .Building:
		if t >= build_time(d) {wave_begin(s)}
	case .Wave:
		spawn_due(s)
		arrivals(s)
		if d.lives <= 0 {
			run_end(s, .Lost)
		} else if waiting(d) == 0 && alive(s) == 0 {
			wave_end(s)
		}
	case .Results:
		if t >= towers.RESULTS {new_run(s)}
	}
	if d.phase.now != .Results {towers_fire(s)}
	run_put(s)
}

// build_time: seconds of building before the next wave.
build_time :: proc(d: ^Defence) -> f64 {
	return f64(d.settings.build) if d.wave == 0 else towers.BETWEEN
}

// waiting: creeps of the wave still to come out of the gate.
waiting :: proc(d: ^Defence) -> int {
	n := 0
	for c in d.coming {n += c}
	return n
}

// wave_begin: the next wave sets out.
wave_begin :: proc(s: ^core.Server) {
	d := state(s)
	d.wave += 1
	plan := towers.wave_plan(d.wave)
	d.coming, d.health = plan.count, plan.health
	d.next_spawn = s.tick
	set_phase(s, .Wave)
	size := towers.wave_size(d.wave)
	event := towers.Wave{u8(d.wave), false, u16(size)}
	for &c in s.clients {if here(s, &c) {core.game_event(s, &c, &event)}}
	core.announce(s, fmt.tprintf("&cWave %d of %d&r: %d creeps", d.wave, d.settings.waves, size))
	log.infof("towers wave=%d size=%d run=%d", d.wave, size, d.run)
}

// wave_end: every creep of the wave is dead: a bonus for everyone, then the next build,
// or the run is won.
wave_end :: proc(s: ^core.Server) {
	d := state(s)
	event := towers.Wave{u8(d.wave), true, u16(towers.wave_size(d.wave))}
	bonus := towers.WAVE_BONUS + towers.WAVE_BONUS_STEP * d.wave
	for &c in s.clients {
		if !here(s, &c) {continue}
		core.game_event(s, &c, &event)
		core.item_give(s, &c, d.coin, bonus)
	}
	if d.wave >= d.settings.waves {
		run_end(s, .Won)
		return
	}
	core.announce(s, fmt.tprintf("&aWave %d held&r: %s each", d.wave, towers.coins_text(bonus)))
	set_phase(s, .Building)
}

// run_end: won or lost; the creeps left go.
run_end :: proc(s: ^core.Server, outcome: towers.Outcome) {
	d := state(s)
	d.outcome = outcome
	d.coming = {}
	clear_creeps(s)
	set_phase(s, .Results)
	if outcome == .Won {
		core.announce(s, fmt.tprintf("&eThe core stands&r: all %d waves held", d.settings.waves))
	} else {
		core.announce(s, fmt.tprintf("&cThe core has fallen&r in wave %d", d.wave))
	}
	log.infof("towers run=%d over outcome=%v wave=%d lives=%d", d.run, outcome, d.wave, d.lives)
}

// spawn_due: the next creep of the wave comes out of the gate when its time is due: of
// the kind with the most still to come, so a wave mixes them.
spawn_due :: proc(s: ^core.Server) {
	d := state(s)
	if waiting(d) == 0 || s.tick < d.next_spawn {return}
	d.next_spawn = s.tick + u64(towers.SPAWN_EVERY * f64(game.TICK_RATE))
	most := towers.Creep.Runner
	for k in towers.Creep {if d.coming[k] > d.coming[most] {most = k}}
	if spawn_creep(s, most) {d.coming[most] -= 1}
}

// spawn_creep: one creep of kind k at the gate, on its way to the core.
spawn_creep :: proc(s: ^core.Server, k: towers.Creep) -> bool {
	d := state(s)
	w := s.home
	g := towers.GATE
	h := core.entity_spawn(w, d.kinds[k], {f64(g.x) + 0.5, f64(g.y), f64(g.z) + 0.5}, false)
	if h == 0 {return false}
	base_health := core.entity_max_health(w, h)
	core.entity_set_max_health(w, h, int(math.round(f64(base_health) * d.health)))
	core.entity_follow(w, h, d.routes[k])
	return true
}

// creep_of: which creep kind an entity is (false: none of the game's).
creep_of :: proc(d: ^Defence, kind: game.Kind_Id) -> (towers.Creep, bool) {
	for k, c in d.kinds {if k == kind {return c, true}}
	return {}, false
}

// alive: creeps on the field.
alive :: proc(s: ^core.Server) -> int {
	d := state(s)
	n := 0
	it := core.entities_each(s.home)
	for h in core.entities_next(&it) {
		if _, ok := creep_of(d, core.entity_kind(s.home, h)); ok {n += 1}
	}
	return n
}

// arrivals: a creep at the core costs its lives and goes.
arrivals :: proc(s: ^core.Server) {
	d := state(s)
	w := s.home
	it := core.entities_each(w)
	for h in core.entities_next(&it) {
		k, ok := creep_of(d, core.entity_kind(w, h))
		if !ok || !core.entity_arrived(w, h) {continue}
		d.lives = max(d.lives - towers.CREEPS[k].lives, 0)
		core.entity_gone(w, h)
	}
}

// clear_creeps: every creep goes.
clear_creeps :: proc(s: ^core.Server) {
	d := state(s)
	it := core.entities_each(s.home)
	for h in core.entities_next(&it) {
		if _, ok := creep_of(d, core.entity_kind(s.home, h)); ok {core.entity_gone(s.home, h)}
	}
}

// entity_died: a creep killed pays its bounty to whoever killed it (a tower's builder,
// a player's shot); nobody's kill pays nobody.
entity_died :: proc(
	s: ^core.Server,
	w: ^core.World,
	dead: core.Dead_Entity,
	harm: core.Entity_Harm,
) {
	d := state(s)
	k, ok := creep_of(d, dead.kind)
	if !ok || harm.by == nil || !here(s, harm.by) {return}
	purse(s, harm.by).kills += 1
	core.item_give(s, harm.by, d.coin, towers.CREEPS[k].bounty)
}

// run_put tells every player the run and every builder's purse (only what changed is
// sent).
run_put :: proc(s: ^core.Server) {
	d := state(s)
	r := towers.Run {
		phase   = d.phase.now,
		outcome = d.outcome,
		run     = d.run,
		wave    = u8(d.wave),
		waves   = u8(d.settings.waves),
		lives   = i16(d.lives),
		alive   = u16(alive(s)),
		to_come = u16(waiting(d)),
		seed    = d.seed,
	}
	#partial switch d.phase.now {
	case .Building:
		wait := build_time(d)
		r.left = play.phase_left(s, &d.phase, wait) if d.built else u16(wait)
	case .Results:
		r.left = play.phase_left(s, &d.phase, towers.RESULTS)
	}
	for &c in s.clients {
		if !here(s, &c) {continue}
		core.game_put(s, &c, &r)
		for &o in s.clients {
			if !here(s, &o) {continue}
			p := purse(s, &o)
			b := towers.Builder {
				name  = core.client_name(&o),
				coins = u32(core.item_count(&o, d.coin)),
				kills = u32(p.kills),
				spent = u32(max(p.spent, 0)),
			}
			core.game_put(s, &c, &b, protocol.key_player(core.player_id(s, &o)))
		}
	}
}

// command: /towers shows the run and its settings; /towers <setting> <value> sets one
// (coins, lives, waves, build: from the next run, the lives this one's too before its
// first wave), /towers wave sends the next wave now, /towers restart begins a new run.
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name != "towers" {return false}
	d := state(s)
	table := towers.settings_table()
	if len(args) == 0 {
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Towers run %d, %v, wave %d of %d, %d lives, seed %d: %s",
				d.run,
				d.phase.now,
				d.wave,
				d.settings.waves,
				d.lives,
				d.seed,
				play.settings_text(table, &d.settings),
			),
		)
		return true
	}
	if handled, changed := play.settings_command(s, c, table, &d.settings, NODE_ADMIN, args);
	   handled {
		if changed && d.wave == 0 {d.lives = d.settings.lives}
		return true
	}
	if !core.allowed(s, c, NODE_ADMIN) {
		core.notice(s, c, "You may not change the run (towers.admin)")
		return true
	}
	switch {
	case len(args) == 1 && args[0] == "wave":
		if d.phase.now != .Building || !d.built {
			core.notice(s, c, "Towers: a wave comes only after a build")
			return true
		}
		wave_begin(s)
	case len(args) == 1 && args[0] == "restart":
		new_run(s)
		core.notice(s, c, "Towers: a new run")
	case:
		core.notice(
			s,
			c,
			fmt.tprintf("Usage: towers [%s | wave | restart]", play.settings_usage(table)),
		)
	}
	return true
}

// save: the run's settings, kept with the universe.
save :: proc(s: ^core.Server, out: ^strings.Builder) {
	play.settings_save(towers.settings_table(), &state(s).settings, out)
}

// load: the settings the universe kept (a line Towers does not know, or a value out of
// its bounds, is not Towers'). They hold from the next run (this one's lives now, before
// its first wave).
load :: proc(s: ^core.Server, text: string) -> bool {
	d := state(s)
	play.settings_load(towers.settings_table(), &d.settings, text) or_return
	if d.wave == 0 {d.lives = d.settings.lives}
	return true
}
