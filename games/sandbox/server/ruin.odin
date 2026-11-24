package sandbox_server

import "core:fmt"
import "core:log"
import "core:math"

import "common:base"
import "common:game"
import "common:wave"
import "games:sandbox"
import "server:core"
import "server:play"

// The ruined site: Horde's waves as an encounter in the sandbox's open world. Every home
// world has one ruin, placed from its seed a few minutes' walk from the spawn on dry, level
// ground where there is some (ruin_site), with a tower whose lamps show it from afar
// (ruin_template). It is built when a player first comes near it in a session (so a blast's
// scars and a ward left standing by a crash are gone), on ground it levels first, so it is
// never buried or perched, and its blocks and its apron are not the players' to change.
//
// Using the altar in its middle wakes it: every player inside its walls who can be hurt is
// locked in to fight. Each has its own things set aside (core.inventory_set_aside: untouched
// by death, saved with the character) and is put in the encounter's mode (its pack's
// `sandbox:encounter`: the base pack's guns as Horde tunes them, loading the ruin's rounds,
// for those in that mode alone), a ward rises round the walls, and RUIN_WAVES waves of the
// base pack's hostile creatures come out of its four lairs (play.Crowd, common:wave's plan,
// as Horde's do). Between waves the fighters are given rounds and a little health. Nobody
// gets out while it is awake and nobody gets in: a fighter outside the walls is put back,
// anyone else inside is put out, and a creature that gets out is gone and comes again.
//
// The fight ends when the last wave is dead (every fighter standing gets its things back
// and the altar gives each its reward: RUIN_REWARD), or when no fighter is left: one who
// dies is out (the sandbox's death: back at the world's spawn; its things are given back
// when it stands again, so it loses nothing it brought), and one who leaves the server gets
// its things back when it next joins. Then the ward falls and the ruin sleeps until woken
// again.

RUIN_WAVES :: 5 // the waves of a fight (the fifth brings the matriarch: wave.BOSS_EVERY)
RUIN_SIDE :: 27 // the site's square, walls and all (x and z)
RUIN_MID :: RUIN_SIDE / 2 // the altar's column (local)
RUIN_DEPTH :: 3 // layers of foundation under the floor
RUIN_HEIGHT :: 36 // the template's height: the foundation, the floor and the air to the tower's top
RUIN_WARD :: 6 // blocks the ward stands over the floor
RUIN_DISTANCE :: 240 // blocks from the spawn to the site's middle, at the least
RUIN_RINGS :: 10 // rings of candidate sites, RUIN_RING_STEP blocks apart from RUIN_DISTANCE out
RUIN_RING_STEP :: 24
RUIN_PER_RING :: 16 // candidates on a ring
RUIN_LEVEL :: 5 // blocks between the land's highest and lowest under a site that is level
RUIN_APRON :: 4 // blocks of levelled ground round the walls, so every gate opens on ground
RUIN_CLEAR :: 12 // blocks cleared over the land's highest under a levelled site (its trees)
RUIN_NEAR :: 160 // a player this near the site's middle has it built (and its ground kept loaded)
RUIN_COUNTDOWN :: 3.0 // seconds from the ruin woken to the first wave
RUIN_BREAK :: 10.0 // seconds between waves
RUIN_SPAWN_EVERY :: 0.6 // seconds between two creatures of a wave
RUIN_BREAK_ROUNDS :: 30 // rounds each fighter is given between waves
RUIN_BREAK_HEAL :: 10 // health each fighter is given between waves

// RUIN_LAIRS: where the creatures come out, inside each corner but the tower's (local x, z).
RUIN_LAIRS :: [4][2]i32 {
	{5, 5},
	{RUIN_SIDE - 6, 5},
	{5, RUIN_SIDE - 6},
	{RUIN_SIDE - 6, RUIN_SIDE - 6},
}

// RUIN_REWARD: what the altar gives each fighter standing when the last wave dies.
RUIN_REWARD :: [3]string{"voxiverse:sniper", "voxiverse:jump_boots", "voxiverse:feather_charm"}
RUIN_ENCOUNTER :: "sandbox:ruin" // the fight's name in a quest's win step (pack/data/quests)

// Ruin: the home world's ruined site and its fight (the session's: a fight does not outlive
// it, while what a fighter set aside does).
Ruin :: struct {
	site:        Site,
	placed:      bool, // site is worked out
	built:       bool, // built this session
	kept:        bool, // its ground is kept loaded
	phase:       play.Phase(sandbox.Ruin_Phase),
	fight:       u32, // the fight on now, or the last (0: none yet): a fighter's seat names it
	wave:        int, // on now, or the last of the fight
	crowd:       play.Crowd, // the creatures of the fight
	// What the names are in this session's registry.
	altar, ward: game.Block,
	round:       game.Item,
	reward:      [len(RUIN_REWARD)]game.Item,
	floor, wall: game.Block,
	moss, tile:  game.Block,
	dark, rune:  game.Block,
}

// Ruin_Seat: a player's part in the ruin's fight (the game's client_state).
Ruin_Seat :: struct {
	fighting: u32, // the fight it is locked in (Ruin.fight while it is on; 0: none)
}

ruin_of :: proc(s: ^core.Server) -> ^Ruin {return &state(s).ruin}
ruin_seat :: proc(s: ^core.Server, c: ^core.Client) -> ^Ruin_Seat {
	return core.game_client_state(s, c, Ruin_Seat)
}

// ruin_start: the names the ruin uses, from the session's registry (the game's start).
ruin_start :: proc(s: ^core.Server) -> bool {
	r := ruin_of(s)
	reg := s.registry
	play.crowd_start(s, &r.crowd) or_return
	r.altar = game.registry_block(reg, sandbox.ALTAR_BLOCK) or_return
	r.ward = game.registry_block(reg, sandbox.WARD_BLOCK) or_return
	r.round = game.registry_item(reg, sandbox.ROUND_ITEM) or_return
	reward := RUIN_REWARD
	for &item, i in r.reward {item = game.registry_item(reg, reward[i]) or_return}
	r.floor = game.registry_block(reg, "sandbox:stone_tiles") or_return
	r.wall = game.registry_block(reg, "sandbox:mossy_bricks") or_return
	r.moss = game.registry_block(reg, "sandbox:moss") or_return
	r.tile = game.registry_block(reg, "sandbox:polished_stone") or_return
	r.dark = game.registry_block(reg, "sandbox:dark_bricks") or_return
	r.rune = game.registry_block(reg, "sandbox:rune_stone") or_return
	_, encounter := game.mode_find(reg, sandbox.ENCOUNTER_MODE)
	return encounter
}

// ruin_tick: the site worked out, built and kept as players come near it; the fight run.
ruin_tick :: proc(s: ^core.Server) {
	r := ruin_of(s)
	w := s.home
	if !r.placed {
		r.site, r.placed = ruin_site(w), true
		log.infof("ruin site at %v floor %d", ruin_middle(r.site), r.site.floor)
	}
	near := r.phase.now != .Asleep
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		d := c.player.position - ruin_middle(r.site)
		near ||= d.x * d.x + d.z * d.z <= RUIN_NEAR * RUIN_NEAR
	}
	area := ruin_area(r.site)
	switch {
	case near && !r.kept:
		core.world_keep(w, area)
		r.kept = true
	case !near && r.kept:
		core.world_release(w) // (the sandbox keeps nothing else)
		r.kept = false
	}
	if near && !r.built && core.world_ready(w, area) {ruin_build(s, w)}

	t := play.phase_seconds(s, &r.phase)
	switch r.phase.now {
	case .Asleep:
	case .Countdown:
		if ruin_fighters(s) == 0 {
			ruin_end(s, false)
		} else if t >= RUIN_COUNTDOWN {
			ruin_wave(s)
		}
	case .Wave:
		lairs: [len(RUIN_LAIRS)][3]f64
		for l, i in RUIN_LAIRS {lairs[i] = ruin_point(r.site, l)}
		play.crowd_spawn_due(s, &r.crowd, w, lairs[:], RUIN_SPAWN_EVERY)
		play.crowd_tick(s, &r.crowd, w, ruin_fighting)
		ruin_hold_creatures(s, w)
		switch {
		case ruin_fighters(s) == 0:
			ruin_end(s, false)
		case play.crowd_waiting(&r.crowd) == 0 && r.crowd.foe_count == 0:
			if r.wave >= RUIN_WAVES {ruin_end(s, true)} else {ruin_break(s)}
		}
	case .Break:
		if ruin_fighters(s) == 0 {
			ruin_end(s, false)
		} else if t >= RUIN_BREAK {
			ruin_wave(s)
		}
	}
	if r.phase.now != .Asleep {ruin_hold_players(s, w)}
	ruin_put(s)
}

// ruin_use: the altar used (the machine_use hook): the ruin wakes, and every player inside
// its walls who can be hurt fights. Refused at an altar not the ruin's, while it is awake,
// from outside its walls or by one who cannot be hurt.
ruin_use :: proc(s: ^core.Server, c: ^core.Client, at: game.Block_Pos) -> string {
	r := ruin_of(s)
	switch {
	case c.world != s.home || !r.built || at != ruin_altar(r.site):
		return "The altar is cold: it wakes only in its ruin"
	case r.phase.now != .Asleep:
		return "The ruin is awake already"
	case !play.prey_fair(s, c) || !ruin_inside(r.site, c.player.position):
		return "The ruin wakes only for those inside its walls who can be hurt"
	case c.aside != nil:
		return "You carry things set aside already"
	}
	r.fight += 1
	r.wave = 0
	for &o in s.clients {
		if o.state != .Playing || o.world != s.home || o.aside != nil {continue}
		if !play.prey_fair(s, &o) || !ruin_inside(r.site, o.player.position) {continue}
		ruin_enlist(s, &o)
	}
	ruin_ward(s, s.home, true)
	play.phase_set(s, &r.phase, .Countdown)
	log.infof(
		"ruin woken fight=%d by %s fighters=%d",
		r.fight,
		core.client_name(c),
		ruin_fighters(s),
	)
	return ""
}

// ruin_enlist: c fights: its things set aside (and the mode it was in, with its character),
// the encounter's mode and kit, full health.
ruin_enlist :: proc(s: ^core.Server, c: ^core.Client) {
	r := ruin_of(s)
	label := game.mode_label(s.registry, c.mode)
	t := trader(s, c)
	t.ruin_mode = {}
	copy(t.ruin_mode[:], label)
	core.inventory_set_aside(s, c)
	core.game_mode(s, c, sandbox.ENCOUNTER_MODE)
	core.kit_give(s, c)
	core.heal_player(c, 1000)
	play.hold(s, c, "voxiverse:rifle")
	ruin_seat(s, c).fighting = r.fight
	core.notice(
		s,
		c,
		fmt.tprintf(
			"The ruin wakes: hold out for %d waves. Your things are kept for you.",
			RUIN_WAVES,
		),
	)
}

// ruin_release: c's things back, in place of the encounter's, and the mode it was in before
// (survival when its character does not say). Nothing to give back: nothing changes.
ruin_release :: proc(s: ^core.Server, c: ^core.Client) {
	if c.aside == nil {return}
	t := trader(s, c)
	n := 0
	for n < len(t.ruin_mode) && t.ruin_mode[n] != 0 {n += 1}
	if n == 0 || core.game_mode(s, c, string(t.ruin_mode[:n])) == .Unknown_Mode {
		core.game_mode(s, c, "survival")
	}
	t.ruin_mode = {}
	core.inventory_give_back(s, c)
	ruin_seat(s, c).fighting = 0
}

// ruin_wave: the next wave sets out of the lairs.
ruin_wave :: proc(s: ^core.Server) {
	r := ruin_of(s)
	r.wave += 1
	play.crowd_send(s, &r.crowd, r.wave)
	play.phase_set(s, &r.phase, .Wave)
	text := fmt.tprintf("Wave %d of %d: %d creatures", r.wave, RUIN_WAVES, wave.size(r.wave))
	if wave.plan(r.wave).count[.Matriarch] >
	   0 {text = fmt.tprintf("%s, the matriarch with them", text)}
	ruin_tell(s, text)
}

// ruin_break: a wave held: the fighters get rounds and a little health.
ruin_break :: proc(s: ^core.Server) {
	r := ruin_of(s)
	for &c in s.clients {
		if !ruin_fighting(s, &c) {continue}
		core.item_give(s, &c, r.round, RUIN_BREAK_ROUNDS)
		core.heal_player(&c, RUIN_BREAK_HEAL)
	}
	play.phase_set(s, &r.phase, .Break)
	ruin_tell(s, fmt.tprintf("Wave %d held: rounds and a breath before the next", r.wave))
}

// ruin_end: the fight is over, held (won: the fighters standing get their things back and
// the reward) or lost (none left); the ward falls and the ruin sleeps.
ruin_end :: proc(s: ^core.Server, won: bool) {
	r := ruin_of(s)
	w := s.home
	winners := 0
	for &c in s.clients {
		if ruin_seat(s, &c).fighting != r.fight {continue}
		if c.dead {
			ruin_seat(s, &c).fighting = 0 // (its things come back as it stands: ruin_respawned)
			continue
		}
		ruin_release(s, &c)
		if !won {continue}
		winners += 1
		core.notice(s, &c, "The ruin is quiet: the altar gives you its reward")
		above := ruin_point(r.site, {RUIN_MID, RUIN_MID}) + {0, 1.5, 0}
		for item in r.reward {core.item_drop(s, w, above, {item = item, count = 1})}
		core.quest_note(s, &c, {goal = .Win, name = RUIN_ENCOUNTER, count = 1})
	}
	play.crowd_clear(&r.crowd, w)
	ruin_ward(s, w, false)
	play.phase_set(s, &r.phase, .Asleep)
	log.infof("ruin fight=%d over won=%v waves=%d winners=%d", r.fight, won, r.wave, winners)
}

// ruin_died: a fighter who dies is out of the fight (the sandbox's death stands it at the
// spawn; its things come back as it stands: ruin_respawned).
ruin_died :: proc(s: ^core.Server, c: ^core.Client, harm: core.Harm) {
	r := ruin_of(s)
	if ruin_seat(s, c).fighting == 0 {return}
	ruin_seat(s, c).fighting = 0
	if r.phase.now != .Asleep {
		ruin_tell(s, fmt.tprintf("%s fell; the ruin fights on", core.client_name(c)))
	}
}

// ruin_respawned: one who fell in the ruin stands again with its own things, in its own mode.
ruin_respawned :: proc(s: ^core.Server, c: ^core.Client) {
	if ruin_seat(s, c).fighting == 0 {ruin_release(s, c)}
}

// ruin_left: a fighter who leaves is out; its things stay set aside with its character
// until it next joins (ruin_joined).
ruin_left :: proc(s: ^core.Server, c: ^core.Client) {ruin_seat(s, c).fighting = 0}

// ruin_joined: one who left a fight (or the server stopped during one) gets its things back
// and its mode, and is put out of the ruin if it stands inside.
ruin_joined :: proc(s: ^core.Server, c: ^core.Client) {
	r := ruin_of(s)
	if c.aside == nil {return}
	ruin_release(s, c)
	if r.placed && c.world == s.home && ruin_inside(r.site, c.player.position) {
		ruin_put_out(s, c)
	}
}

// ruin_editing: the ruin's blocks are not the players' to change.
ruin_editing :: proc(s: ^core.Server, c: ^core.Client, at: game.Block_Pos) -> string {
	r := ruin_of(s)
	if !r.placed || c.world != s.home {return ""}
	a := ruin_area(r.site)
	if at.x < a.lo.x ||
	   at.y < a.lo.y ||
	   at.z < a.lo.z ||
	   at.x > a.hi.x ||
	   at.y > a.hi.y ||
	   at.z > a.hi.z {
		return ""
	}
	return "The ruin holds"
}

// ruin_picking: the ruin's rounds are for its fighters: anyone else who walks over one
// finds nothing.
ruin_picking :: proc(s: ^core.Server, c: ^core.Client, stack: game.Stack) -> core.Pickup {
	if stack.item == ruin_of(s).round && !ruin_fighting(s, c) {return .Taken}
	return .Take
}

// ruin_dropping: a fighter throws nothing away while it fights: what it holds is the ruin's
// kit, given back in exchange for its own things at the end, and not for anyone outside.
ruin_dropping :: proc(s: ^core.Server, c: ^core.Client, stack: game.Stack) -> string {
	if ruin_seat(s, c).fighting == 0 {return ""}
	return "The ruin keeps what it gave you until the fight is over"
}

// ruin_entity_died: a creature of the fight killed leaves its crowd.
ruin_entity_died :: proc(s: ^core.Server, w: ^core.World, dead: core.Dead_Entity) {
	if w == s.home {play.crowd_forget(&ruin_of(s).crowd, dead.id)}
}

// ruin_hunted: a creature the fight hunts with (not the night's: danger.odin leaves it).
ruin_hunted :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) -> bool {
	return w == s.home && play.crowd_find(&ruin_of(s).crowd, core.entity_id(w, h)) != nil
}

// ruin_fighting: c is locked in the fight on now, alive: what its creatures hunt.
ruin_fighting :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	r := ruin_of(s)
	return(
		r.phase.now != .Asleep &&
		c.state == .Playing &&
		c.world == s.home &&
		!c.dead &&
		ruin_seat(s, c).fighting == r.fight \
	)
}

// ruin_fighters: the players fighting now.
ruin_fighters :: proc(s: ^core.Server) -> (n: int) {
	for &c in s.clients {if ruin_fighting(s, &c) {n += 1}}
	return
}

// ruin_tell: every fighter is told.
ruin_tell :: proc(s: ^core.Server, text: string) {
	for &c in s.clients {if ruin_fighting(s, &c) {core.notice(s, &c, text)}}
}

// ruin_hold_players: while the ruin is awake, a fighter outside its walls is put back by
// the altar, and anyone else inside is put out by the south gate.
ruin_hold_players :: proc(s: ^core.Server, w: ^core.World) {
	r := ruin_of(s)
	for &c in s.clients {
		if c.state != .Playing || c.world != w || c.dead {continue}
		inside := ruin_inside(r.site, c.player.position)
		if ruin_fighting(s, &c) && !inside {
			at := ruin_point(r.site, {RUIN_MID, RUIN_MID + 2})
			core.teleport(s, &c, at, play.look_at(at, ruin_point(r.site, {RUIN_MID, RUIN_MID})))
			core.notice(s, &c, "The ward holds you in")
		} else if !ruin_fighting(s, &c) && inside {
			ruin_put_out(s, &c)
		}
	}
}

// ruin_put_out: c set down outside the south gate, facing away from the ruin.
ruin_put_out :: proc(s: ^core.Server, c: ^core.Client) {
	r := ruin_of(s)
	at := ruin_point(r.site, {RUIN_MID, RUIN_SIDE + 2})
	core.teleport(s, c, at, play.look_at(at, at + {0, 0, 1}))
	core.notice(s, c, "The ruin is awake: its ward keeps you out")
}

// ruin_hold_creatures: a creature of the fight that got out of the walls is gone, and
// comes out of a lair again.
ruin_hold_creatures :: proc(s: ^core.Server, w: ^core.World) {
	r := ruin_of(s)
	for i := 0; i < r.crowd.foe_count; i += 1 {
		f := r.crowd.foes[i]
		h, there := core.entity_find(w, f.id)
		if !there || ruin_inside(r.site, core.entity_pos(w, h)) {continue}
		core.entity_gone(w, h)
		play.crowd_forget(&r.crowd, f.id)
		r.crowd.coming[f.foe] += 1
		i -= 1
	}
}

// ruin_put: each player is told the fight, or that there is none; in the home world, once
// the site is built, it is a place in their logbook.
ruin_put :: proc(s: ^core.Server) {
	r := ruin_of(s)
	shown := sandbox.Ruin_Fight {
		phase   = r.phase.now,
		wave    = u8(r.wave),
		waves   = RUIN_WAVES,
		alive   = u16(r.crowd.foe_count),
		to_come = u16(play.crowd_waiting(&r.crowd)),
	}
	#partial switch r.phase.now {
	case .Countdown:
		shown.left = play.phase_left(s, &r.phase, RUIN_COUNTDOWN)
	case .Break:
		shown.left = play.phase_left(s, &r.phase, RUIN_BREAK)
	}
	none := sandbox.Ruin_Fight{}
	altar := ruin_altar(r.site)
	for &c in s.clients {
		if c.state != .Playing {continue}
		put := shown if ruin_fighting(s, &c) else none
		core.game_put(s, &c, &put)
		// Found (built: someone came near it): a place in the logbook of everyone there.
		if r.built &&
		   c.world == s.home {core.logbook_place(s, &c, .Ruin, {altar.x, altar.y, altar.z})}
	}
}

// ruin_middle: the site's middle, on its floor.
ruin_middle :: proc(site: Site) -> [3]f64 {return ruin_point(site, {RUIN_MID, RUIN_MID})}

// ruin_point: where one stands on the floor at local column l (the middle of its block).
ruin_point :: proc(site: Site, l: [2]i32) -> [3]f64 {
	return {f64(site.origin.x + l.x) + 0.5, f64(site.floor + 1), f64(site.origin.z + l.y) + 0.5}
}

// ruin_altar: the altar's block.
ruin_altar :: proc(site: Site) -> game.Block_Pos {
	return {site.origin.x + RUIN_MID, site.floor + 1, site.origin.z + RUIN_MID}
}

// ruin_area: the site's whole box: its apron and walls, from under the lowest land (or its
// foundation) to over the highest (or its tower's top): what it builds in, keeps loaded and
// keeps the players from changing.
ruin_area :: proc(site: Site) -> core.Box {
	o := site.origin
	lo_y := min(o.y, site.lo) - 2
	hi_y := max(o.y + RUIN_HEIGHT - 1, site.hi + RUIN_CLEAR)
	return {
		{o.x - RUIN_APRON, lo_y, o.z - RUIN_APRON},
		{o.x + RUIN_SIDE - 1 + RUIN_APRON, hi_y, o.z + RUIN_SIDE - 1 + RUIN_APRON},
	}
}

// ruin_inside: p (feet) is within the site's walls, from its floor to the ward's top.
ruin_inside :: proc(site: Site, p: [3]f64) -> bool {
	lo := site.origin + {1, 0, 1}
	hi := site.origin + {RUIN_SIDE - 1, 0, RUIN_SIDE - 1}
	return(
		p.x >= f64(lo.x) &&
		p.z >= f64(lo.z) &&
		p.x < f64(hi.x) &&
		p.z < f64(hi.z) &&
		p.y >= f64(site.floor) - 1 &&
		p.y <= f64(site.floor + RUIN_WARD + 3) \
	)
}

// ruin_site: where the home world's ruin stands (site.odin), from its seed alone: on RUIN_RINGS rings
// round its spawn, from RUIN_DISTANCE out, RUIN_PER_RING candidates each starting in a
// direction of the seed's, the first whose ground is dry and level; when none is, the dry one
// whose ground is the least uneven (any one, when none is dry), which the ruin levels as it is
// built (ruin_build).
ruin_site :: proc(w: ^core.World) -> Site {
	rng := base.rng_make(u64(w.seed) ~ 0x7e1c_0de5)
	angle := base.rng_f64(&rng) * math.TAU
	spawn := w.spawn.position
	land := land_of(w)
	best: Site
	best_score := max(i32)
	for ring in 0 ..< RUIN_RINGS {
		d := f64(RUIN_DISTANCE + ring * RUIN_RING_STEP)
		for k in 0 ..< RUIN_PER_RING {
			a := angle + (f64(k) + 0.5 * f64(ring % 2)) * math.TAU / RUIN_PER_RING
			cx := i32(math.floor(spawn.x + base.cos(a) * d))
			cz := i32(math.floor(spawn.z + base.sin(a) * d))
			floor, lo, hi, dry := site_ground(&land, cx, cz, RUIN_MID + RUIN_APRON)
			site := Site{{cx - RUIN_MID, floor - RUIN_DEPTH, cz - RUIN_MID}, floor, lo, hi, false}
			if dry && hi - lo <= RUIN_LEVEL {
				site.level = true
				return site
			}
			score := (hi - lo) + (0 if dry else 1000)
			if score < best_score {best, best_score = site, score}
		}
	}
	return best
}

// ruin_build: the ruin, whole, over whatever stood there, its altar's machine made with it.
ruin_build :: proc(s: ^core.Server, w: ^core.World) {
	r := ruin_of(s)
	site := r.site
	t := ruin_template(r, w.seed)
	act := core.game_act(s, w, .Structure)
	// The ground levelled, its apron too, so the ruin is neither buried nor perched and every
	// gate opens on ground (a level site's ground is nearly so already).
	site_level(w, ruin_area(site), site.floor, act)
	template_box := core.Box{site.origin, site.origin + {RUIN_SIDE, RUIN_HEIGHT, RUIN_SIDE} - 1}
	core.bulk_edit(w, {shape = template_box, op = .Paste, template = &t, partial = true}, act)
	ruin_posts(s, w)
	r.built = true
	log.infof("ruin built at %v", r.site.origin)
}

// ruin_template: the ruin's blocks (temp memory), the same for a seed every time: a
// foundation and a floor of worn tiles, patched with moss; a ring of broken walls with a
// gate in the middle of each side; a tower in one corner, lamps at its top; four stumps of
// pillars; a dais in the middle with the altar on it; the lairs' cracked ground in the
// other corners. Everything above the floor that is not the ruin is air.
ruin_template :: proc(r: ^Ruin, seed: i64) -> game.Template {
	S :: RUIN_SIDE
	M :: RUIN_MID
	F :: RUIN_DEPTH // the floor's layer, local
	t := game.template_make({S, RUIN_HEIGHT, S}, context.temp_allocator)
	box :: game.template_fill
	rng := base.rng_make(u64(seed) ~ 0x7e1c_0de5)
	box(&t, {0, 0, 0}, {S - 1, F - 1, S - 1}, .Cobblestone)
	box(&t, {0, F, 0}, {S - 1, F, S - 1}, r.floor)
	for _ in 0 ..< 40 {
		x, z := base.rng_roll(&rng, i32(1), S - 3), base.rng_roll(&rng, i32(1), S - 3)
		box(&t, {x, F, z}, {x + 1, F, z}, r.moss if base.rng_int_max(&rng, 3) > 0 else .Gravel)
	}
	// The walls: broken to a height between 2 and 5, the gates three wide in the middle.
	for k in i32(0) ..< S {
		for side in 0 ..< 4 {
			x, z: i32
			switch side {
			case 0:
				x, z = k, 0
			case 1:
				x, z = k, S - 1
			case 2:
				x, z = 0, k
			case:
				x, z = S - 1, k
			}
			if abs(k - M) <= 1 {continue} 	// (a gate)
			h := ruin_wall_height(seed, x, z)
			box(&t, {x, F + 1, z}, {x, F + h, z}, r.wall if (x + z) % 3 != 0 else r.dark)
		}
	}
	for d in ([2]i32{-2, 2}) { 	// (each gate's posts, whole)
		posts := [4][2]i32{{M + d, 0}, {M + d, S - 1}, {0, M + d}, {S - 1, M + d}}
		for p in posts {box(&t, {p.x, F + 1, p.y}, {p.x, F + RUIN_WARD, p.y}, r.dark)}
	}
	// The tower, hollow, in the corner at the lowest x and z, lamps at its top.
	top := i32(RUIN_HEIGHT - 3)
	box(&t, {1, F + 1, 1}, {3, top, 3}, r.dark)
	box(&t, {2, F + 1, 2}, {2, top - 1, 2}, .Air)
	box(&t, {1, top + 1, 1}, {3, top + 1, 3}, .Lamp)
	box(&t, {2, top + 2, 2}, {2, top + 2, 2}, r.rune)
	// The stumps of pillars.
	for p in ([4][2]i32{{8, 8}, {S - 9, 8}, {8, S - 9}, {S - 9, S - 9}}) {
		box(&t, {p.x, F + 1, p.y}, {p.x, F + base.rng_roll(&rng, i32(2), 5), p.y}, .Stone_Bricks)
	}
	// The lairs: cracked ground.
	for l in RUIN_LAIRS {box(&t, {l.x - 1, F, l.y - 1}, {l.x + 1, F, l.y + 1}, .Gravel)}
	// The dais and the altar.
	box(&t, {M - 2, F, M - 2}, {M + 2, F, M + 2}, r.tile)
	box(&t, {M, F + 1, M}, {M, F + 1, M}, r.altar)
	return t
}

// ruin_wall_height: how high the broken wall stands at local column (x, z), 2 to 5.
ruin_wall_height :: proc(seed: i64, x, z: i32) -> i32 {
	h := u32(x) * 73_856_093 ~ u32(z) * 19_349_663 ~ u32(seed)
	return 2 + i32((h >> 7) % 4)
}

// ruin_ward: the ward raised round the walls (filling the gates and topping the walls to
// RUIN_WARD over the floor), or lowered again.
ruin_ward :: proc(s: ^core.Server, w: ^core.World, up: bool) {
	r := ruin_of(s)
	o := r.site.origin
	lo_y, hi_y := r.site.floor + 1, r.site.floor + RUIN_WARD
	S :: RUIN_SIDE
	rings := [4]core.Box {
		{{o.x, lo_y, o.z}, {o.x + S - 1, hi_y, o.z}},
		{{o.x, lo_y, o.z + S - 1}, {o.x + S - 1, hi_y, o.z + S - 1}},
		{{o.x, lo_y, o.z}, {o.x, hi_y, o.z + S - 1}},
		{{o.x + S - 1, lo_y, o.z}, {o.x + S - 1, hi_y, o.z + S - 1}},
	}
	act := core.game_act(s, w, .Structure)
	for b in rings {
		e := core.Bulk_Edit {
			shape   = b,
			op      = .Replace,
			from    = .Air if up else r.ward,
			block   = r.ward if up else .Air,
			partial = true,
		}
		core.bulk_edit(w, e, act)
	}
}
