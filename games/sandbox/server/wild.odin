package sandbox_server

import "core:math"
import "core:slice"

import "common:base"
import "common:game"
import "server:core"
import "server:play"

// The home world's creatures but the sheep: its wildlife, the guards of their ground, its
// predators, the ancient remains' machines and a giant (the pack's data/entities:
// wildlife.json, predators.json, machines.json, which say what each is, where and when it
// comes and what it leaves). Each kind's mind is a few of server/play's minds on the Mind
// the game keeps in its record on the creature (Creature.mind); what a player sees of one
// (asleep, warning, winding up a blow, aloft) is the look named after its state, shown here
// (wild_show) and drawn by its pack's model. A creature with no player within WILD_NEAR
// thinks once in play.FAR_THINK ticks; no more come by themselves round a player who has
// WILD_MOST of them within WILD_CROWD blocks. The machines keep to the remains
// (remains_machines.odin).

Wild :: enum u8 {
	Loper, // a herd grazer
	Twitchet, // a small runner
	Wheelwing, // a bird
	Glassfin, // a fish
	Domeback, // a shelled browser
	Hacklebird, // a tall bird that guards its ground
	Snouter, // a tusked digger that guards its ground
	Pitmaw, // an ambusher of the caves
	Barbcaster, // a shooter of the shore by night
	Duskrunner, // a pack hunter of the woods by night
	Cragmaul, // a heavy brute of the hills by night
	Sentry, // a machine asleep at its post
	Tender, // a machine that mends the remains
	Watcher, // a machine that follows from afar
	Bulwark, // the great ruin's guardian
	Longstrider, // the giant
}

WILD_KINDS :: [Wild]string {
	.Loper       = "sandbox:loper",
	.Twitchet    = "sandbox:twitchet",
	.Wheelwing   = "sandbox:wheelwing",
	.Glassfin    = "sandbox:glassfin",
	.Domeback    = "sandbox:domeback",
	.Hacklebird  = "sandbox:hacklebird",
	.Snouter     = "sandbox:snouter",
	.Pitmaw      = "sandbox:pitmaw",
	.Barbcaster  = "sandbox:barbcaster",
	.Duskrunner  = "sandbox:duskrunner",
	.Cragmaul    = "sandbox:cragmaul",
	.Sentry      = "sandbox:sentry",
	.Tender      = "sandbox:tender",
	.Watcher     = "sandbox:watcher",
	.Bulwark     = "sandbox:bulwark",
	.Longstrider = "sandbox:longstrider",
}

// Wild_Group: some of the roster, as /creatures names them.
Wild_Group :: struct {
	name:  string,
	kinds: bit_set[Wild],
}

// WILD_GROUPS: the roster by group.
WILD_GROUPS :: [?]Wild_Group {
	{"wildlife", {.Loper, .Twitchet, .Wheelwing, .Glassfin, .Domeback}},
	{"guards", {.Hacklebird, .Snouter}},
	{"predators", {.Pitmaw, .Barbcaster, .Duskrunner, .Cragmaul}},
	{"machines", {.Sentry, .Tender, .Watcher, .Bulwark}},
	{"giant", {.Longstrider}},
}

WILD_NEAR :: 48 // blocks: a player this near has a creature think every tick
WILD_MOST :: 24 // wild creatures round a player before no more come by themselves
WILD_CROWD :: 64 // blocks round the new one they are counted over
WILD_FLEE_TICKS :: game.TICK_RATE * 5

// The tempers of the creatures that fight (play.Temper): how near rouses them, how long
// they warn or wake, how long each blow or shot is wound up, how far they go from home.
HACKLE_TEMPER :: play.Temper {
	notice   = 9,
	near     = 5,
	warn     = game.TICK_RATE * 2,
	leash    = 16,
	patience = game.TICK_RATE * 6,
	wind     = 8,
	may      = wild_prey,
}
SNOUTER_TEMPER :: play.Temper {
	notice   = 6,
	near     = 4,
	warn     = game.TICK_RATE * 3 / 2,
	leash    = 14,
	patience = game.TICK_RATE * 8,
	wind     = 10,
	may      = wild_prey,
}
PITMAW_TEMPER :: play.Temper {
	notice   = 5,
	warn     = game.TICK_RATE,
	leash    = 12,
	patience = game.TICK_RATE * 5,
	wind     = 8,
	may      = wild_prey,
}
BARB_TEMPER :: play.Temper {
	notice   = 14,
	warn     = game.TICK_RATE / 2,
	leash    = 24,
	patience = game.TICK_RATE * 6,
	wind     = 24,
	may      = wild_prey,
}
CRAG_TEMPER :: play.Temper {
	notice   = 12,
	warn     = game.TICK_RATE / 2,
	leash    = 30,
	patience = game.TICK_RATE * 8,
	wind     = 36,
	may      = wild_prey,
}
SENTRY_TEMPER :: play.Temper {
	notice   = 10,
	warn     = game.TICK_RATE * 3 / 2,
	leash    = 20,
	patience = game.TICK_RATE * 10,
	wind     = 18,
	post     = true,
	may      = wild_prey,
}
BULWARK_TEMPER :: play.Temper {
	notice   = 7,
	warn     = game.TICK_RATE * 5 / 2,
	leash    = 16,
	patience = game.TICK_RATE * 10,
	wind     = 45,
	post     = true,
	may      = wild_prey,
}
DUSK_WIND :: 15 // ticks a duskrunner's markings flare before it darts in
DUSK_RING :: 6 // blocks a pack circles its prey at

// STATE_LOOKS: the look each state of a mind shows (a kind draws those its model names).
STATE_LOOKS :: [play.Mind_State]string {
	.Idle    = "idle",
	.Wander  = "wander",
	.Rest    = "rest",
	.Watch   = "watch",
	.Flee    = "flee",
	.Warn    = "warn",
	.Dormant = "dormant",
	.Hidden  = "hidden",
	.Wake    = "wake",
	.Fight   = "fight",
	.Return  = "return",
	.Follow  = "follow",
	.Leave   = "leave",
}

// wild_start: the roster's kinds, from the session's registry.
wild_start :: proc(s: ^core.Server) -> bool {
	g := state(s)
	names := WILD_KINDS
	for name, which in names {
		g.wild[which] = game.registry_kind(s.registry, name) or_return
	}
	return true
}

// wild_of: which of the roster a kind is.
wild_of :: proc(s: ^core.Server, kind: game.Kind_Id) -> (Wild, bool) {
	if kind == 0 {return {}, false}
	for k, which in state(s).wild {if k == kind {return which, true}}
	return {}, false
}

// creature: the game's record on a creature of its own kinds (nil for another).
creature :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) -> ^Creature {
	return core.entity_data(w, h, Creature)
}

// wild_prey: a player the creatures go for: one who can be hurt (play.prey_fair) and is
// not fighting at the ruin (its fight is the ruin's).
wild_prey :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	return play.prey_fair(s, c) && !ruin_fighting(s, c)
}

// seen: the player nearest p within radius blocks that a creature sees (play.player_seen).
seen :: proc(s: ^core.Server, w: ^core.World, p: [3]f64, radius: f64) -> ^core.Client {
	return play.prey_nearest(s, w, p, radius, play.player_seen)
}

// wild_think: one creature of the roster's tick, unless it stands still for a picture.
wild_think :: proc(s: ^core.Server, w: ^core.World, which: Wild, h: game.Entity_Handle) {
	d := creature(s, w, h)
	if d == nil || d.still {return}
	m := &d.mind
	play.mind_settle(w, h, m)
	near := seen(s, w, core.entity_pos(w, h), WILD_NEAR) != nil
	if !play.mind_due(s, w, h, m, near) {return}
	switch which {
	case .Loper:
		loper_think(s, w, h, m)
	case .Twitchet:
		twitchet_think(s, w, h, m)
	case .Wheelwing:
		wheelwing_think(s, w, h, m)
	case .Glassfin:
		glassfin_think(s, w, h, m)
	case .Domeback:
		domeback_think(s, w, h, m)
	case .Hacklebird:
		guard_think(s, w, h, m, HACKLE_TEMPER, 6, 1.6)
	case .Snouter:
		guard_think(s, w, h, m, SNOUTER_TEMPER, 5, 0.6)
		if m.state == .Fight {core.entity_set_speed(w, h, run_speed(s, w, h))}
	case .Pitmaw:
		sleeper_think(s, w, h, m, PITMAW_TEMPER, .Hidden)
	case .Barbcaster:
		guard_think(s, w, h, m, BARB_TEMPER, 4, 0.5)
	case .Duskrunner:
		duskrunner_think(s, w, h, m)
	case .Cragmaul:
		guard_think(s, w, h, m, CRAG_TEMPER, 5, 2)
	case .Sentry:
		sleeper_think(s, w, h, m, SENTRY_TEMPER, .Dormant)
	case .Tender:
		tender_think(s, w, h, m)
	case .Watcher:
		if watcher_think(s, w, h, m) {return} 	// (gone)
	case .Bulwark:
		sleeper_think(s, w, h, m, BULWARK_TEMPER, .Dormant)
	case .Longstrider:
		if !fleeing(w, h, m) {graze(s, w, h, m, 24, 0, 0, 9)}
	}
	wild_show(w, h, d)
}

// wild_show: what a player sees of a creature: the look of its mind's state, and
// "winding" while it winds up a blow or a shot, set when they change.
wild_show :: proc(w: ^core.World, h: game.Entity_Handle, d: ^Creature) {
	m := &d.mind
	winding := m.wind > 0
	if d.showing && d.shown == m.state && d.winding == winding {return}
	looks := STATE_LOOKS
	if d.showing {core.entity_show(w, h, looks[d.shown], false)}
	core.entity_show(w, h, looks[m.state], true)
	core.entity_show(w, h, "winding", winding)
	d.shown, d.winding, d.showing = m.state, winding, true
}

// run_speed: the creature's kind's running pace.
run_speed :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) -> f32 {
	return game.kind_info(s.registry, core.entity_kind(w, h)).walker.run_speed
}

// fleeing: a fleeing walker runs its time out; true while it does (then it stands, at its
// walking pace again).
fleeing :: proc(w: ^core.World, h: game.Entity_Handle, m: ^play.Mind) -> bool {
	if m.state != .Flee {return false}
	m.timer -= 1
	if m.timer > 0 {return true}
	core.entity_stand(w, h)
	core.entity_set_speed(w, h, 0)
	play.mind_set(m, .Idle, 20)
	return false
}

// graze: a walker's calm: it stands and looks about, wanders within range blocks of its
// home (or of its herd's middle, for one with herd blocks), and rests, its head down to
// graze or root; it watches a player within watch blocks (its eyes eye blocks up).
graze :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	m: ^play.Mind,
	range, herd, watch, eye: f64,
) {
	r := &state(s).rng
	m.timer -= 1
	#partial switch m.state {
	case .Wander:
		if core.entity_arrived(w, h) || m.timer <= 0 {
			core.entity_stand(w, h)
			play.mind_set(m, .Idle, i32(base.rng_int_range(r, 30, 90)))
		}
		return
	case .Rest:
		play.head_to(w, h, -1.1)
		if m.timer <= 0 {play.mind_set(m, .Idle, i32(base.rng_int_range(r, 20, 60)))}
		return
	}
	if c := seen(s, w, core.entity_pos(w, h), watch); c != nil && watch > 0 {
		m.state = .Watch
		play.face(w, h, c.player.position + {0, game.PLAYER_EYE, 0}, eye)
	} else {
		m.state = .Idle
		play.head_to(w, h, 0)
	}
	if m.timer > 0 {return}
	switch roll := base.rng_f32(r); {
	case roll < 0.5:
		if herd > 0 {
			play.herd_wander(w, h, m, r, range, herd)
		} else {
			play.wander(w, h, r, play.home_point(m), range)
		}
		play.mind_set(m, .Wander, game.TICK_RATE * 12)
	case roll < 0.8:
		core.entity_stand(w, h)
		play.mind_set(m, .Rest, i32(base.rng_int_range(r, 40, 120)))
	case:
		m.timer = i32(base.rng_int_range(r, 30, 90))
	}
}

// LOPER_FRIGHT: blocks within which a player frightens a loper's herd.
LOPER_FRIGHT :: 5

// loper_think: a herd grazer keeps with its herd and grazes, watches a player within 10
// blocks, and runs with its herd from one within LOPER_FRIGHT.
loper_think :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle, m: ^play.Mind) {
	if fleeing(w, h, m) {return}
	if c := seen(s, w, core.entity_pos(w, h), LOPER_FRIGHT); c != nil {
		herd_fright(s, w, h, c.player.position)
		return
	}
	graze(s, w, h, m, 6, 16, 10, 1.3)
}

// herd_fright: a creature takes fright at `from`, and so do the others of its kind within
// 12 blocks: they run 14 blocks from it.
herd_fright :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle, from: [3]f64) {
	r := &state(s).rng
	run := run_speed(s, w, h)
	if d := creature(s, w, h);
	   d != nil {play.scare(w, h, &d.mind, r, from, 14, run, WILD_FLEE_TICKS)}
	for o in play.herd_mates(w, h, 12) {
		if d := creature(s, w, o); d != nil {
			play.scare(w, o, &d.mind, r, from, 14, run, WILD_FLEE_TICKS)
		}
	}
}

// twitchet_think: a small runner freezes, ears up, facing a player within 9 blocks, and
// bolts from one within 5; else it nibbles and wanders.
twitchet_think :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle, m: ^play.Mind) {
	if fleeing(w, h, m) {return}
	pos := core.entity_pos(w, h)
	if c := seen(s, w, pos, 9); c != nil {
		if play.distance_to(pos, c.player.position) <= 5 {
			play.scare(
				w,
				h,
				m,
				&state(s).rng,
				c.player.position,
				12,
				run_speed(s, w, h),
				game.TICK_RATE * 3,
			)
			return
		}
		core.entity_stand(w, h)
		m.state = .Watch
		play.face(w, h, c.player.position + {0, game.PLAYER_EYE, 0}, 0.25)
		return
	}
	graze(s, w, h, m, 5, 0, 0, 0.25)
}

// wheelwing_think: a bird on the ground pecks about and takes off from a player within 7
// blocks; after a while it flies, wheeling over its ground 6 to 12 blocks up, and then
// lands somewhere near it again.
wheelwing_think :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle, m: ^play.Mind) {
	r := &state(s).rng
	home := play.home_point(m)
	m.timer -= 1
	#partial switch m.state {
	case .Flee, .Wander:
		if !core.entity_arrived(w, h) {return}
		if m.timer > 0 {
			if !play.fly_circle(s, w, h, r, home, 10, 0.9, 6, 12, 4) {
				play.fly_wander(s, w, h, r, home, 8, 6, 12, 4)
			}
		} else if play.land(s, w, h, r, home, 6) {
			play.mind_set(m, .Return, game.TICK_RATE * 15)
		}
		return
	case .Return:
		if core.entity_arrived(w, h) || m.timer <= 0 {
			play.mind_set(m, .Rest, i32(base.rng_int_range(r, 10, 30)) * game.TICK_RATE)
		}
		return
	}
	pos := core.entity_pos(w, h)
	if c := seen(s, w, pos, 7); c != nil {
		if play.fly_flee(s, w, h, r, c.player.position, 12, 5, 9, run_speed(s, w, h)) {
			play.mind_set(m, .Flee, game.TICK_RATE * 20)
		}
		return
	}
	m.state = .Rest
	play.head_to(w, h, -0.9 if (s.tick / 20 + u64(core.entity_id(w, h))) % 3 == 0 else 0, 0.4)
	if m.timer <= 0 {
		if play.fly_wander(s, w, h, r, home, 8, 6, 12, 4) {
			play.mind_set(m, .Wander, i32(base.rng_int_range(r, 15, 30)) * game.TICK_RATE)
		} else {
			m.timer = game.TICK_RATE
		}
	}
}

// glassfin_think: a fish swims with its school (or about its home, alone) and darts from
// a player within 5 blocks, always in the water.
glassfin_think :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle, m: ^play.Mind) {
	r := &state(s).rng
	m.timer -= 1
	if m.state == .Flee && m.timer > 0 && !core.entity_arrived(w, h) {return}
	if c := seen(s, w, core.entity_pos(w, h), 5); c != nil && m.state != .Flee {
		if play.swim_flee(s, w, h, r, c.player.position, 6, run_speed(s, w, h)) {
			play.mind_set(m, .Flee, game.TICK_RATE * 3)
			return
		}
	}
	if m.state == .Wander && !core.entity_arrived(w, h) && m.timer > 0 {return}
	center, n := play.herd_center(w, h, 8)
	if play.swim_wander(s, w, h, r, center if n > 0 else play.home_point(m), 4) {
		play.mind_set(m, .Wander, i32(base.rng_int_range(r, 20, 60)))
	} else {
		play.mind_set(m, .Idle, 10)
	}
}

// domeback_think: a shelled browser wanders and grazes, minding no one; shut in its shell
// (hurt: wild_hurt), it stays shut a while.
domeback_think :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle, m: ^play.Mind) {
	if m.state == .Hidden {
		core.entity_stand(w, h)
		m.timer -= 1
		if m.timer <= 0 {play.mind_set(m, .Idle, 30)}
		return
	}
	graze(s, w, h, m, 4, 0, 0, 0.5)
}

// guard_think: a creature that fights when roused (its temper), and at rest wanders and
// grazes within range blocks of its home.
guard_think :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	m: ^play.Mind,
	t: play.Temper,
	range, eye: f64,
) {
	if _, roused := play.temper_tick(s, w, h, m, t, .Idle); roused {return}
	graze(s, w, h, m, range, 0, 0, eye)
}

// sleeper_think: a creature that sleeps (asleep: Dormant, Hidden) until roused (its
// temper), and is whole again once it sleeps.
sleeper_think :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	m: ^play.Mind,
	t: play.Temper,
	asleep: play.Mind_State,
) {
	if _, roused := play.temper_tick(s, w, h, m, t, asleep); roused {return}
	if m.state != asleep {play.mind_set(m, asleep, 0)}
	core.entity_stand(w, h)
	if most := core.entity_max_health(w, h); core.entity_health_of(w, h) < most {
		core.entity_heal(w, h, most)
	}
}

// duskrunner_think: a pack hunter wanders with its pack; with prey within 16 blocks the
// pack circles it DUSK_RING blocks off, and one at a time (none of its mates darting),
// once its own wait ran out, one darts in to bite (play.fight_fair: its markings flare
// first) and goes back to the ring.
duskrunner_think :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle, m: ^play.Mind) {
	if fleeing(w, h, m) {return}
	r := &state(s).rng
	pos := core.entity_pos(w, h)
	prey := play.prey_within(s, w, pos, 16, wild_prey)
	if prey == nil {
		if m.state == .Watch || m.state == .Fight {
			m.wind = 0
			play.mind_set(m, .Idle, 0)
		}
		graze(s, w, h, m, 6, 16, 0, 0.6)
		return
	}
	m.timer -= 1
	if m.state == .Fight {
		play.fight_fair(s, w, h, m, prey, DUSK_WIND)
		if (m.ready > 0 && m.wind == 0) || m.timer <= 0 {
			m.wind = 0
			play.mind_set(m, .Watch, i32(base.rng_int_range(r, 60, 120)))
		}
		return
	}
	if m.state != .Watch {play.mind_set(m, .Watch, i32(base.rng_int_range(r, 30, 90)))}
	darting := false
	for o in play.herd_mates(w, h, 16) {
		if d := creature(s, w, o); d != nil && d.mind.state == .Fight {darting = true}
	}
	if m.timer <= 0 && !darting {
		play.mind_set(m, .Fight, game.TICK_RATE * 4)
		m.ready = 0
		return
	}
	if (s.tick + u64(core.entity_id(w, h))) % 10 == 0 {
		feet := prey.player.position
		a := math.atan2(pos.z - feet.z, pos.x - feet.x) + 0.6
		core.entity_set_speed(w, h, 0)
		core.entity_go(w, h, feet + {base.cos(a) * DUSK_RING, 0, base.sin(a) * DUSK_RING})
	}
}

// tender_think: a mending drone hovers from stone to stone of its remains, 1 to 3 blocks
// up, stopping a while at each to mend it (its sparks); hurt, it is off up and away for a
// while (wild_hurt).
tender_think :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle, m: ^play.Mind) {
	r := &state(s).rng
	m.timer -= 1
	#partial switch m.state {
	case .Flee, .Wander:
		if core.entity_arrived(w, h) || m.timer <= 0 {
			play.mind_set(m, .Rest, i32(base.rng_int_range(r, 60, 150)))
		}
		return
	case .Rest:
		if m.timer > 0 {return}
	}
	if play.fly_wander(s, w, h, r, play.home_point(m), 8, 1, 3, 2) {
		play.mind_set(m, .Wander, game.TICK_RATE * 20)
	} else {
		play.mind_set(m, .Idle, game.TICK_RATE)
	}
}

// watcher_think: a watcher keeps the player nearest it within 48 blocks in sight, 10 to 16
// blocks off and 5 up, for its time (spawned: wild_begin), and then, or with nobody left
// to watch, rises and goes; true once it is gone.
watcher_think :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	m: ^play.Mind,
) -> bool {
	r := &state(s).rng
	pos := core.entity_pos(w, h)
	if m.state == .Leave {return play.leave(s, w, h, m, r, pos, 40)}
	m.timer -= 1
	c := seen(s, w, pos, 48)
	if c == nil || m.timer <= 0 {
		from := pos
		if c != nil {from = c.player.position}
		return play.leave(s, w, h, m, r, from, 40)
	}
	m.state = .Follow
	play.follow_at(s, w, h, c, 10, 16, 5, 5)
	return false
}

// wild_begin: a creature of the roster as it first comes: its home where it stands, a
// cave's ambusher buried, a bird on the ground a while, a watcher's time to watch, a
// machine asleep, the giant grown.
wild_begin :: proc(s: ^core.Server, w: ^core.World, which: Wild, h: game.Entity_Handle) {
	d := creature(s, w, h)
	if d == nil {return}
	r := &state(s).rng
	m := &d.mind
	play.mind_settle(w, h, m)
	#partial switch which {
	case .Pitmaw:
		play.mind_set(m, .Hidden, 0)
	case .Wheelwing:
		play.mind_set(m, .Rest, i32(base.rng_int_range(r, 5, 20)) * game.TICK_RATE)
	case .Watcher:
		play.mind_set(m, .Follow, i32(base.rng_int_range(r, 40, 60)) * game.TICK_RATE)
	case .Sentry, .Bulwark:
		play.mind_set(m, .Dormant, 0)
	case .Longstrider:
		core.entity_show(w, h, "grown", true)
	}
	wild_show(w, h, d)
}

// wild_spawned: a creature of the roster that came by itself (the spawned hook): refused
// round a player who has WILD_MOST of them near, a barbcaster away from the water, a
// duskrunner or a snouter away from the trees and a watcher away from the remains; else
// it begins (wild_begin).
wild_spawned :: proc(s: ^core.Server, w: ^core.World, which: Wild, h: game.Entity_Handle) -> bool {
	g := state(s)
	pos := core.entity_pos(w, h)
	if play.crowded(w, pos, WILD_CROWD, WILD_MOST + 1, slice.enumerated_array(&g.wild)) {
		return false
	}
	#partial switch which {
	case .Barbcaster:
		if !near_water(w, pos, 6) {return false}
	case .Duskrunner, .Snouter:
		if !near_trees(w, pos, 8) {return false}
	case .Watcher:
		if !remains_near(s, w, pos, REMAINS_WATCHED) {return false}
	}
	wild_begin(s, w, which, h)
	return true
}

// near_water: water within radius blocks of p (across), at its level or a block or two
// under it.
near_water :: proc(w: ^core.World, p: [3]f64, radius: i32) -> bool {
	at := play.block_of(p)
	for dz in -radius ..= radius {
		for dx in -radius ..= radius {
			for dy in i32(-2) ..= 0 {
				b, _ := core.block_at(w, at + {dx, dy, dz})
				if _, water := game.water_level(b); water {return true}
			}
		}
	}
	return false
}

// near_trees: a tree's leaves 3 to 8 blocks over p's level within radius blocks (across,
// every other block): the woods.
near_trees :: proc(w: ^core.World, p: [3]f64, radius: i32) -> bool {
	at := play.block_of(p)
	for dz := -radius; dz <= radius; dz += 2 {
		for dx := -radius; dx <= radius; dx += 2 {
			for dy in i32(3) ..= 8 {
				b, _ := core.block_at(w, at + {dx, dy, dz})
				if b == .Leaves || b == .Spruce_Leaves {return true}
			}
		}
	}
	return false
}

// wild_hurt: a creature of the roster was hurt (the entity_hurt hook): the timid run (a
// loper's herd with it), a bird or a mender takes to the air, a fish darts, a domeback
// shuts itself in, the guards and sleepers are roused, a duskrunner badly hurt runs and a
// watcher goes.
wild_hurt :: proc(
	s: ^core.Server,
	w: ^core.World,
	which: Wild,
	h: game.Entity_Handle,
	harm: core.Entity_Harm,
) {
	d := creature(s, w, h)
	if d == nil {return}
	r := &state(s).rng
	m := &d.mind
	from := harm.from
	switch which {
	case .Loper:
		herd_fright(s, w, h, from)
	case .Twitchet:
		play.scare(w, h, m, r, from, 12, run_speed(s, w, h), WILD_FLEE_TICKS)
	case .Longstrider:
		play.scare(w, h, m, r, from, 20, run_speed(s, w, h), WILD_FLEE_TICKS * 2)
	case .Wheelwing, .Tender:
		if play.fly_flee(s, w, h, r, from, 12, 6, 10, run_speed(s, w, h)) {
			play.mind_set(m, .Flee, WILD_FLEE_TICKS)
		}
	case .Glassfin:
		if play.swim_flee(s, w, h, r, from, 6, run_speed(s, w, h)) {
			play.mind_set(m, .Flee, game.TICK_RATE * 3)
		}
	case .Domeback:
		core.entity_stand(w, h)
		play.mind_set(m, .Hidden, game.TICK_RATE * 6)
	case .Hacklebird:
		play.provoke(m, HACKLE_TEMPER)
	case .Snouter:
		play.provoke(m, SNOUTER_TEMPER)
	case .Pitmaw:
		play.provoke(m, PITMAW_TEMPER)
	case .Barbcaster:
		play.provoke(m, BARB_TEMPER)
	case .Cragmaul:
		play.provoke(m, CRAG_TEMPER)
	case .Sentry:
		play.provoke(m, SENTRY_TEMPER)
	case .Bulwark:
		play.provoke(m, BULWARK_TEMPER)
	case .Duskrunner:
		if core.entity_health_of(w, h) * 2 <= core.entity_max_health(w, h) {
			m.wind = 0
			play.scare(w, h, m, r, from, 16, run_speed(s, w, h), WILD_FLEE_TICKS)
		}
	case .Watcher:
		play.leave(s, w, h, m, r, from, 40)
	}
	wild_show(w, h, d)
}

// wild_harming: harm about to be done to a creature of the roster (the harming hook): a
// domeback shut in its shell lets a quarter of it through, a machine asleep half.
wild_harming :: proc(s: ^core.Server, hm: ^core.Harming) {
	if hm.entity == 0 || hm.world == nil {return}
	which, ours := wild_of(s, core.entity_kind(hm.world, hm.entity))
	d := creature(s, hm.world, hm.entity)
	if !ours || d == nil {return}
	#partial switch which {
	case .Domeback:
		if d.mind.state == .Hidden {hm.amount *= 0.25}
	case .Sentry, .Bulwark:
		if d.mind.state == .Dormant {hm.amount *= 0.5}
	}
}

// creatures_command: `/creatures <group>|all [still]` sets the roster's creatures of a
// group (WILD_GROUPS) down in a row in front of the player (north of it), facing it; still,
// they stand for a picture, showing how each looks at its most telling (a bird aloft, a
// guard warning, the giant grown). The summoning permission.
creatures_command :: proc(s: ^core.Server, c: ^core.Client, args: []string) -> bool {
	USAGE :: "Usage: creatures wildlife|guards|predators|machines|giant|all [still]"
	if !core.allowed(s, c, "world.summon") {
		core.notice(s, c, "You may not summon here")
		return true
	}
	if len(args) < 1 || len(args) > 2 || (len(args) == 2 && args[1] != "still") {
		core.notice(s, c, USAGE)
		return true
	}
	kinds: bit_set[Wild]
	if args[0] == "all" {kinds = ~bit_set[Wild]{}}
	groups := WILD_GROUPS
	for group in groups {if group.name == args[0] {kinds = group.kinds}}
	if kinds == {} {
		core.notice(s, c, USAGE)
		return true
	}
	still := len(args) == 2
	g := state(s)
	w := c.world
	width := 0.0
	for which in kinds {width += f64(game.kind_info(s.registry, g.wild[which]).box[0]) + 0.5}
	x := c.player.position.x - width / 2
	for which in kinds {
		box := game.kind_info(s.registry, g.wild[which]).box
		at := [3]f64{x + f64(box[0]) / 2 + 0.25, c.player.position.y, c.player.position.z - 8}
		x += f64(box[0]) + 0.5
		h := core.entity_spawn(w, g.wild[which], at, false)
		if h == 0 {
			core.notice(s, c, "The world is full")
			return true
		}
		core.entity_set_look(w, h, math.PI, 0)
		wild_begin(s, w, which, h)
		if still {wild_pose(s, w, which, h)}
	}
	return true
}

// wild_pose: a creature set down for a picture stands still, as it looks at its most
// telling (a bird aloft, a guard roused; never a look that lets specks rise, which differ
// from one picture to the next); a flier or a swimmer holds where it is (a glide to its own
// block: no gravity).
wild_pose :: proc(s: ^core.Server, w: ^core.World, which: Wild, h: game.Entity_Handle) {
	d := creature(s, w, h)
	if d == nil {return}
	d.still = true
	pose := play.Mind_State.Idle
	#partial switch which {
	case .Wheelwing:
		pose = .Wander
	case .Hacklebird:
		pose = .Warn
	case .Snouter:
		pose = .Fight
	}
	d.mind.state = pose
	wild_show(w, h, d)
	#partial switch which {
	case .Wheelwing, .Tender, .Watcher, .Glassfin:
		up := core.entity_pos(w, h) + {0, 2 if which != .Glassfin else 0, 0}
		core.entity_glide(w, h, []game.Block_Pos{play.block_of(up)})
	}
}
