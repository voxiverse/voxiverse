package horde_server

import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"

import "common:base"
import "common:game"
import "common:protocol"
import "games:horde"
import "server:core"
import "server:play"

// Horde's server part (the game: games/horde): it runs the runs in the home world. A
// run's yard is built from its seed (yard.odin) and counted down; then the waves come
// out of the lairs (foes.odin), with the shop open between them. A survivor who goes
// down watches until the wave ends; the run ends when all are down at once, and the best
// wave reached is kept with the universe.

GAME :: core.Game {
	info         = horde.INFO,
	kinds        = horde.KINDS,
	pack         = horde.PACK,
	server_state = Horde,
	client_state = Survivor,
	configure    = configure,
	start        = start,
	stop         = stop,
	tick         = tick,
	joined       = joined,
	command      = command,
	died         = died,
	respawned    = respawned,
	entity_died  = entity_died,
	action       = action,
	editing      = editing,
	save         = save,
	load         = load,
}

// Horde: the run.
Horde :: struct {
	settings:   horde.Settings,
	phase:      play.Phase(horde.Phase),
	run:        u16,
	wave:       int, // on now, or the last (0: none yet)
	best:       int, // the best wave any run reached (kept with the universe)
	seed:       u32, // the yard's
	rng:        base.Rng, // the yards' seeds (from the universe's seed)
	built:      bool, // the run's yard is there
	// The wave on its way out of the lairs.
	coming:     [horde.Foe]int, // still to come, of each kind
	toughness:  f32, // its creatures' health, times their kind's
	next_spawn: u64, // the tick the next one comes out
	next_lair:  int, // the lair the next one comes out of
	foes:       [MAX_FOES]Foe_Slot,
	foe_count:  int,
	// What the pack's names are in this session's registry.
	kinds:      [horde.Foe]game.Kind_Id,
	round:      game.Item,
	guns:       [len(horde.GUNS)]game.Item,
	shop, lair: game.Block,
}

// Survivor: a player's part in a run.
Survivor :: struct {
	run:   u16, // the run it was given its coins for (0: none yet)
	coins: int,
	kills: int,
	downs: int,
	guns:  int, // guns bought this run
	down:  bool, // down: watching until the wave ends
}

state :: proc(s: ^core.Server) -> ^Horde {return core.game_state(s, Horde)}
survivor :: proc(s: ^core.Server, c: ^core.Client) -> ^Survivor {
	return core.game_client_state(s, c, Survivor)
}

// NODE_ADMIN: the permission the run's settings and its commands need (the host has it).
NODE_ADMIN :: "horde.admin"

// OVERLOOK: where watchers float, over the south wall, looking at the shop.
OVERLOOK :: [3]f64{horde.MID, horde.HEIGHT + 5, horde.SIZE - 2}
MIDDLE :: [3]f64{horde.MID, 1, horde.MID}

configure :: proc(config: ^core.Config) {
	play.configure_flat(config, {horde.MID + 3.5, 1, horde.MID + 0.5}, horde.WATCHER_MODE)
}

// start: the home world stands at noon, still, with nothing dropped and no friendly
// fire; the dead come back by themselves (to watch, or to fight on); the pack's names
// are looked up and the yard is kept loaded.
start :: proc(s: ^core.Server) -> bool {
	d := state(s)
	d.settings = horde.DEFAULT_SETTINGS
	d.rng = base.rng_make(u64(s.config.seed) ~ 0x40de)
	w := s.home
	play.world_still(s, w)
	core.game_rule(s, w, "pvp", "false")
	core.game_rule(s, w, "respawn_auto", "true")
	core.game_rule(s, w, "respawn_delay", "1")
	reg := s.registry
	ok := true
	for &k, f in d.kinds {
		k, ok = game.registry_kind(reg, horde.FOES[f].kind)
		if !ok {return false}
	}
	d.round = game.registry_item(reg, horde.ROUND_ITEM) or_return
	guns := horde.GUNS
	for &gun, i in d.guns {gun = game.registry_item(reg, guns[i]) or_return}
	d.shop = game.registry_block(reg, horde.SHOP_BLOCK) or_return
	d.lair = game.registry_block(reg, horde.LAIR_BLOCK) or_return
	core.world_keep(w, play.arena_area(YARD))
	log.infof("horde started seed=%d", s.config.seed)
	return true
}

stop :: proc(s: ^core.Server) {
	d := state(s)
	log.infof("horde stopped runs=%d best=%d", d.run, d.best)
}

seconds :: proc(s: ^core.Server) -> f64 {return play.phase_seconds(s, &state(s).phase)}

set_phase :: proc(s: ^core.Server, p: horde.Phase) {play.phase_set(s, &state(s).phase, p)}

joined :: proc(s: ^core.Server, c: ^core.Client) {
	core.notice(s, c, "Horde: hold out; between waves, Z, X and B buy at the shop")
	#partial switch state(s).phase.now {
	case .Countdown, .Break:
		if state(s).built {enlist(s, c)}
	case .Wave:
		go_down(s, c) // (in during a wave: watches it)
	}
}

// new_run: a new yard, the waves from the first, every survivor's purse full.
new_run :: proc(s: ^core.Server) {
	d := state(s)
	foes_clear(s)
	d.run += 1
	d.seed = base.rng_u32(&d.rng)
	d.wave, d.built, d.coming = 0, false, {}
	set_phase(s, .Countdown)
	log.infof("horde run=%d seed=%d", d.run, d.seed)
}

// enlist: c holds out in this run: the survivor's mode and kit, its purse (once a run),
// standing round the counter.
enlist :: proc(s: ^core.Server, c: ^core.Client) {
	d := state(s)
	r := survivor(s, c)
	if r.run != d.run {
		r^ = {
			run   = d.run,
			coins = d.settings.coins,
		}
		core.item_clear(s, c, d.round)
		for gun in d.guns {core.item_clear(s, c, gun)}
	}
	r.down = false
	core.game_mode(s, c, horde.SURVIVOR_MODE)
	core.kit_give(s, c)
	core.heal_player(c, 1000)
	play.hold(s, c, "horde:pistol")
	at, look := stand_point(int(core.player_id(s, c)))
	core.teleport(s, c, at, look)
}

// go_down: c watches until the wave ends.
go_down :: proc(s: ^core.Server, c: ^core.Client) {
	survivor(s, c).down = true
	play.watch(s, c, horde.WATCHER_MODE, OVERLOOK, MIDDLE)
}

tick :: proc(s: ^core.Server) {
	d := state(s)
	present := play.present(s)
	t := seconds(s)
	switch d.phase.now {
	case .Waiting:
		if present > 0 {new_run(s)}
	case .Countdown:
		switch {
		case present == 0:
			set_phase(s, .Waiting)
		case !d.built:
			if build(s, force = t >= horde.BUILD_WAIT) {
				set_phase(s, .Countdown) // (counted from the build)
				for &c in s.clients {if play.here(s, &c) {enlist(s, &c)}}
			}
		case t >= horde.COUNTDOWN:
			wave_begin(s)
		}
	case .Wave:
		spawn_due(s)
		foes_tick(s)
		switch {
		case present == 0:
			foes_clear(s)
			set_phase(s, .Waiting)
		case standing_count(s) == 0:
			run_over(s)
		case waiting(d) == 0 && d.foe_count == 0:
			wave_end(s)
		}
	case .Break:
		if present == 0 {
			set_phase(s, .Waiting)
		} else if t >= f64(d.settings.break_for) {
			wave_begin(s)
		}
	case .Over:
		if t >= horde.OVER {
			if present > 0 {new_run(s)} else {set_phase(s, .Waiting)}
		}
	}
	put_records(s)
}

waiting :: proc(d: ^Horde) -> (n: int) {
	for c in d.coming {n += c}
	return
}

// standing_count: the survivors of the run not down.
standing_count :: proc(s: ^core.Server) -> (n: int) {
	for &c in s.clients {if standing(s, &c) {n += 1}}
	return
}

// wave_begin: the next wave sets out of the lairs.
wave_begin :: proc(s: ^core.Server) {
	d := state(s)
	d.wave += 1
	plan := horde.wave_plan(d.wave)
	d.coming, d.toughness = plan.count, plan.health
	d.next_spawn = s.tick
	set_phase(s, .Wave)
	news := horde.Wave_News {
		u16(d.wave),
		u16(horde.wave_size(d.wave)),
		plan.count[.Matriarch] > 0,
		false,
	}
	for &c in s.clients {if play.here(s, &c) {core.game_event(s, &c, &news)}}
	log.infof("horde wave=%d size=%d run=%d", d.wave, news.size, d.run)
}

// wave_end: every creature of the wave is dead: the shop opens, and those down stand
// again.
wave_end :: proc(s: ^core.Server) {
	d := state(s)
	news := horde.Wave_News{u16(d.wave), u16(horde.wave_size(d.wave)), false, true}
	for &c in s.clients {
		if !play.here(s, &c) {continue}
		core.game_event(s, &c, &news)
		if survivor(s, &c).down || survivor(s, &c).run != d.run {enlist(s, &c)}
	}
	if d.wave > d.best {d.best = d.wave}
	set_phase(s, .Break)
}

// run_over: everyone is down: the run ends at this wave.
run_over :: proc(s: ^core.Server) {
	d := state(s)
	reached := d.wave - 1 // (the waves held)
	record := reached > d.best
	d.best = max(d.best, reached)
	d.coming = {}
	foes_clear(s)
	set_phase(s, .Over)
	if record {
		core.announce(s, fmt.tprintf("&eThe horde wins&r: %d waves held, a new best", reached))
	} else {
		core.announce(
			s,
			fmt.tprintf("&cThe horde wins&r: %d waves held (best %d)", reached, d.best),
		)
	}
	log.infof("horde run=%d over waves=%d best=%d", d.run, reached, d.best)
}

// spawn_due: the next creature of the wave comes out of the next lair when due: the
// matriarch first, then of the kind with the most still to come, so a wave mixes them.
spawn_due :: proc(s: ^core.Server) {
	d := state(s)
	if waiting(d) == 0 || s.tick < d.next_spawn {return}
	d.next_spawn = s.tick + u64(horde.SPAWN_EVERY * game.TICK_RATE)
	pick := horde.Foe.Matriarch
	if d.coming[.Matriarch] == 0 {
		pick = .Shambler
		for k in horde.Foe {if d.coming[k] > d.coming[pick] {pick = k}}
	}
	lairs := horde.LAIRS
	l := lairs[d.next_lair % len(lairs)]
	d.next_lair += 1
	if foe_spawn(s, pick, {f64(l.x) + 0.5, 1, f64(l.y) + 0.5}) != 0 {d.coming[pick] -= 1}
}

// died: a survivor who dies in a wave is down for the rest of it (the engine brings it
// back by itself, to watch: respawned).
died :: proc(s: ^core.Server, c: ^core.Client, harm: core.Harm) {
	d := state(s)
	if !play.here(s, c) || survivor(s, c).run != d.run {return}
	survivor(s, c).downs += 1
	if d.phase.now == .Wave {survivor(s, c).down = true}
}

// respawned: one down watches; one who died outside a wave fights on.
respawned :: proc(s: ^core.Server, c: ^core.Client) {
	if !play.here(s, c) {return}
	if survivor(s, c).down || state(s).phase.now == .Over {
		go_down(s, c)
	} else {
		enlist(s, c)
	}
}

// entity_died: a creature killed pays its bounty to whoever killed it.
entity_died :: proc(
	s: ^core.Server,
	w: ^core.World,
	dead: core.Dead_Entity,
	harm: core.Entity_Harm,
) {
	f := foe_of(s, dead.id)
	if f == nil {return}
	foe := f.foe
	foe_forget(s, dead.id)
	if harm.by == nil || !play.here(s, harm.by) {return}
	r := survivor(s, harm.by)
	r.kills += 1
	r.coins += horde.FOES[foe].bounty
}

// editing: the yard is not the survivors' to change.
editing :: proc(
	s: ^core.Server,
	c: ^core.Client,
	at: game.Block_Pos,
	old, new: game.Block,
) -> string {
	return "The yard holds"
}

// action: the game's actions buy at the shop: between waves, standing at the counter,
// paid for.
action :: proc(s: ^core.Server, c: ^core.Client, index: int) {
	if index < 0 || index >= len(horde.Ware) {return}
	buy(s, c, horde.Ware(index))
}

// buy: c buys a ware, or is told why not; true: bought.
buy :: proc(s: ^core.Server, c: ^core.Client, w: horde.Ware) -> bool {
	d := state(s)
	r := survivor(s, c)
	switch {
	case d.phase.now != .Break && d.phase.now != .Countdown:
		core.notice(s, c, "Horde: the shop opens between waves")
		return false
	case r.down || r.run != d.run:
		core.notice(s, c, "Horde: watchers do not shop")
		return false
	case !at_shop(c):
		core.notice(s, c, "Horde: go to the shop in the middle to buy")
		return false
	case w == .Gun && r.guns >= len(d.guns):
		core.notice(s, c, "Horde: you have every gun the shop sells")
		return false
	}
	cost := horde.price(d.settings, w, r.guns)
	if r.coins < cost {
		core.notice(
			s,
			c,
			fmt.tprintf("Horde: a %s costs %s", horde.WARE_NAMES[w], horde.coins_text(cost)),
		)
		return false
	}
	switch w {
	case .Rounds:
		if core.item_give(s, c, d.round, horde.ROUNDS_PACK) == 0 {
			core.notice(s, c, "Horde: no room for more rounds")
			return false
		}
	case .Medkit:
		core.heal_player(c, horde.MEDKIT_HEAL)
	case .Gun:
		gun := d.guns[r.guns]
		if core.item_give(s, c, gun, 1) == 0 {
			core.notice(s, c, "Horde: no room for the gun")
			return false
		}
		r.guns += 1
		guns := horde.GUNS
		play.hold(s, c, guns[r.guns - 1])
	}
	r.coins -= cost
	return true
}

// at_shop: c stands within reach of the counter.
at_shop :: proc(c: ^core.Client) -> bool {
	d := c.player.position - {f64(horde.MID), 1, f64(horde.MID)}
	return d.x * d.x + d.z * d.z <= horde.SHOP_REACH * horde.SHOP_REACH && abs(d.y) < 2
}

// put_records: the run to everyone (its prices their own), every survivor's purse to
// every player (only what changed is sent).
put_records :: proc(s: ^core.Server) {
	d := state(s)
	run := horde.Run {
		phase    = d.phase.now,
		run      = d.run,
		wave     = u16(d.wave),
		alive    = u16(d.foe_count),
		to_come  = u16(waiting(d)),
		best     = u16(d.best),
		standing = u8(standing_count(s)),
		seed     = d.seed,
	}
	#partial switch d.phase.now {
	case .Countdown:
		run.left =
			play.phase_left(s, &d.phase, horde.COUNTDOWN) if d.built else u16(horde.COUNTDOWN)
	case .Break:
		run.left = play.phase_left(s, &d.phase, f64(d.settings.break_for))
	case .Over:
		run.left = play.phase_left(s, &d.phase, horde.OVER)
	}
	for &c in s.clients {if play.here(s, &c) && survivor(s, &c).run == d.run {run.players += 1}}
	for &c in s.clients {
		if !play.here(s, &c) {continue}
		mine := run
		for w in horde.Ware {mine.prices[w] = u16(horde.price(d.settings, w, survivor(s, &c).guns))}
		core.game_put(s, &c, &mine)
		for &o in s.clients {
			if !play.here(s, &o) {continue}
			r := survivor(s, &o)
			counted := r.run == d.run
			v := horde.Survivor {
				name  = core.client_name(&o),
				coins = u32(r.coins) if counted else 0,
				kills = u32(r.kills) if counted else 0,
				downs = u16(r.downs) if counted else 0,
				down  = r.down,
				guns  = u8(r.guns),
			}
			core.game_put(s, &c, &v, protocol.key_player(core.player_id(s, &o)))
		}
	}
}

// command: /horde shows the run and its settings; /horde set <setting> <value> sets one;
// /horde wave sends the next wave now, /horde restart begins a new run, /horde purse
// <n> gives you coins, /horde shop stands you at the counter (an admin's, for trying).
command :: proc(s: ^core.Server, c: ^core.Client, name: string, args: []string) -> bool {
	if name != "horde" {return false}
	d := state(s)
	table := horde.settings_table()
	if len(args) == 0 {
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Horde run %d, %v, wave %d, best %d, seed %d: %s",
				d.run,
				d.phase.now,
				d.wave,
				d.best,
				d.seed,
				play.settings_text(table, &d.settings),
			),
		)
		return true
	}
	if handled, _ := play.settings_command(s, c, table, &d.settings, NODE_ADMIN, args); handled {
		return true
	}
	if !core.allowed(s, c, NODE_ADMIN) {
		core.notice(s, c, "You may not change the run (horde.admin)")
		return true
	}
	switch {
	case len(args) == 1 && args[0] == "wave":
		if (d.phase.now != .Break && d.phase.now != .Countdown) || !d.built {
			core.notice(s, c, "Horde: a wave comes only after the last one")
			return true
		}
		wave_begin(s)
	case len(args) == 1 && args[0] == "restart":
		new_run(s)
		core.notice(s, c, "Horde: a new run")
	case len(args) == 1 && args[0] == "shop":
		core.teleport(s, c, {f64(horde.MID) - 1.5, 1, f64(horde.MID) + 0.5}, {-1.5708, 0})
	case len(args) == 2 && args[0] == "purse":
		n, ok := strconv.parse_int(args[1])
		if !ok || n < 0 || n > 99999 {
			core.notice(s, c, "Usage: horde purse <0..99999>")
			return true
		}
		survivor(s, c).coins += n
	case:
		core.notice(
			s,
			c,
			fmt.tprintf(
				"Usage: horde [%s | wave | restart | shop | purse <n>]",
				play.settings_usage(table),
			),
		)
	}
	return true
}

// save: the best wave and the settings, kept with the universe.
save :: proc(s: ^core.Server, out: ^strings.Builder) {
	d := state(s)
	fmt.sbprintfln(out, "best = %d", d.best)
	play.settings_save(horde.settings_table(), &d.settings, out)
}

// load: what the universe kept; a line Horde does not know, or a value out of its
// bounds, is not Horde's.
load :: proc(s: ^core.Server, text: string) -> bool {
	d := state(s)
	own := play.settings_read(horde.settings_table(), &d.settings, text) or_return
	for l in own {
		if l.key != "best" {return false}
		best, ok := strconv.parse_int(l.value)
		if !ok || best < 0 || best > 65535 {return false}
		d.best = best
	}
	return true
}
