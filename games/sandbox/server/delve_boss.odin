package sandbox_server

import "core:fmt"
import "core:log"

import "common:game"
import "games:sandbox"
import "server:core"
import "server:play"

// The custodian's fight, in the boss's chamber at the bottom of each delve (delve.odin). The
// custodian kneels at its post, whole, and takes no harm while it kneels. A player who can be
// hurt stepping into its hall wakes it, and the chamber's doorway is sealed with the ruin's
// ward: everyone who can be hurt inside the hall fights (whoever is in it at any tick: there
// is no seat to keep), nobody gets in or out. It fights in three phases (BOSS_PHASES, by the
// share of its health left): its fists (play.fight_fair: each blow wound up); a slam that
// hurts everyone round it, its core blazing and its arms raised for a second and more first;
// after each slam its casing stands open a while, still, when blows get through it best and
// at other times only a part; and as it weakens it calls scuttlers out of the hall's corners.
//
// It ends when the custodian dies (won: every fighter in the hall has the win, `sandbox:delve`
// for its quests, and the reward vault's ward falls and its reward drops in it for each, its
// caches inside) or when no fighter is left in the hall (lost: one who died stands again where
// any death in the sandbox does, one who left is out). Either way the seal falls; lost, the
// custodian is set down whole at its post again and what it called is gone. Nothing of a fight
// outlives the session: as a built delve is first loaded in one (delve_ready: boss_reset) its
// chamber is open, its vault shut and the custodian whole at its post, so a server stopped
// mid-fight, or a player who left in it, finds no seal; one who joins standing in the hall or
// the shut vault is set down outside the chamber's door. Won, the vault stays open the rest of
// the session and the custodian comes again in the next.

// Boss_Phase: what the custodian does in a phase, from when its health falls to `from` of its
// most: its pace and blows' wind-up, its slam (every so many ticks, shown so long, how far
// and how hard), how long its casing stays open after one, how often it calls scuttlers and
// how many, and the share of a harm its casing lets through shut and open.
Boss_Phase :: struct {
	from:         f32,
	speed:        f32,
	wind:         i16,
	slam_every:   i32,
	slam_wind:    i32,
	slam_reach:   f64,
	slam_harm:    f32,
	vent:         i32,
	summon_every: i32,
	summon:       int,
	shut, open:   f32,
	told:         string, // what the fighters are told as it begins
}

@(rodata)
BOSS_PHASES := [3]Boss_Phase {
	{
		from = 1,
		speed = 1.4,
		wind = 24,
		slam_every = 9 * game.TICK_RATE,
		slam_wind = 45,
		slam_reach = 5,
		slam_harm = 7,
		vent = 3 * game.TICK_RATE,
		shut = 0.5,
		open = 1.5,
		told = "The custodian rises. The way out is sealed behind you.",
	},
	{
		from = 0.66,
		speed = 1.6,
		wind = 20,
		slam_every = 8 * game.TICK_RATE,
		slam_wind = 40,
		slam_reach = 5.5,
		slam_harm = 8,
		vent = 3 * game.TICK_RATE,
		summon_every = 14 * game.TICK_RATE,
		summon = 2,
		shut = 0.4,
		open = 1.5,
		told = "Its casing cracks: the custodian calls on the walls.",
	},
	{
		from = 0.33,
		speed = 2,
		wind = 16,
		slam_every = 6 * game.TICK_RATE,
		slam_wind = 30,
		slam_reach = 6.5,
		slam_harm = 9,
		vent = 4 * game.TICK_RATE,
		summon_every = 18 * game.TICK_RATE,
		summon = 1,
		shut = 0.35,
		open = 2,
		told = "The custodian burns hot: its slams come quicker and reach further.",
	},
}

BOSS_WAKE :: 2 * game.TICK_RATE // ticks it takes to rise
BOSS_ADDS :: 4 // scuttlers it has out at once, at the most
BOSS_ENCOUNTER :: "sandbox:delve" // the fight's name in a quest's win step (pack/data/quests)
// BOSS_REWARD: what the vault gives each fighter in the hall as the custodian dies (beside
// what the custodian leaves, its kind's drops, and the vault's caches).
BOSS_REWARD :: [?]string{"sandbox:keeper_key", "sandbox:restorer", "sandbox:servo_spring"}
// BOSS_TEMPER: the custodian's temper set down outside a delve (`/creatures`): a sleeper's.
BOSS_TEMPER :: play.Temper {
	notice   = 10,
	warn     = BOSS_WAKE,
	leash    = 16,
	patience = 10 * game.TICK_RATE,
	wind     = 24,
	post     = true,
	may      = wild_prey,
}

Boss_Step :: enum u8 {
	Asleep, // kneeling at its post
	Waking,
	Fighting,
	Charging, // a slam shown coming
	Venting, // its casing open after a slam
}

// Boss_Fight: a delve's fight (the session's): the custodian (its id; 0: none), whether a
// fight is on and whether one was won this session, its step and phase, the ticks left of
// the step, to its next slam and its next call, and the scuttlers it called.
Boss_Fight :: struct {
	boss:                          u32,
	on, won:                       bool,
	step:                          Boss_Step,
	phase:                         int,
	timer:                         i32,
	slam_due:                      i32,
	summon_due:                    i32,
	adds:                          [BOSS_ADDS]u32,
	add_count:                     int,
	charging_shown, venting_shown: bool,
}

// boss_cell: the boss's chamber's depth, room and cell.
@(private = "file")
boss_room :: proc(d: ^Delve) -> (^Delve_Depth, ^Delve_Room, [2]i32) {
	deep := &d.plan.depths[DELVE_DEPTHS - 1]
	return deep, &deep.rooms[deep.down], delve_cell(deep.down)
}

// boss_seal_box: the chamber's doorway, where its seal rises (world blocks).
boss_seal_box :: proc(d: ^Delve) -> core.Box {
	deep, room, cell := boss_room(d)
	lo, hi := delve_doorway(deep, room, cell, d.plan.boss_from)
	return {d.origin + lo, d.origin + hi}
}

// boss_ward_box: the ward between the hall and its vault (world blocks).
boss_ward_box :: proc(d: ^Delve) -> core.Box {
	deep, _, cell := boss_room(d)
	v := BOSS_VAULT
	lo, hi := boss_box(cell, d.plan.boss_from, v[0], BOSS_WARD_V, v[2], BOSS_WARD_V)
	f := deep.floor
	return {d.origin + {lo.x, f + 1, lo.y}, d.origin + {hi.x, f + DELVE_HALL_AIR, hi.y}}
}

// boss_inside: p (feet) stands over the columns lo..hi (delve-local) of the third depth.
@(private = "file")
boss_inside :: proc(d: ^Delve, p: [3]f64, lo, hi: [2]i32) -> bool {
	deep, _, _ := boss_room(d)
	l := p - {f64(d.origin.x), f64(d.origin.y), f64(d.origin.z)}
	return(
		l.x >= f64(lo.x) &&
		l.z >= f64(lo.y) &&
		l.x < f64(hi.x + 1) &&
		l.z < f64(hi.y + 1) &&
		l.y >= f64(deep.floor) &&
		l.y <= f64(deep.floor + DELVE_BOSS_AIR + 1) \
	)
}

// boss_in_hall: p (feet) stands in the chamber's hall.
boss_in_hall :: proc(d: ^Delve, p: [3]f64) -> bool {
	_, room, _ := boss_room(d)
	return boss_inside(d, p, room.lo, room.hi)
}

// boss_in_vault: p (feet) stands in the chamber's vault.
boss_in_vault :: proc(d: ^Delve, p: [3]f64) -> bool {
	_, _, cell := boss_room(d)
	v := BOSS_VAULT
	lo, hi := boss_box(cell, d.plan.boss_from, v[0], v[1], v[2], v[3])
	return boss_inside(d, p, lo, hi)
}

// boss_post_point: where the custodian kneels (its feet).
boss_post_point :: proc(d: ^Delve) -> [3]f64 {
	deep, _, cell := boss_room(d)
	spot := BOSS_POST
	c := boss_place(cell, d.plan.boss_from, spot.x, spot.y)
	return play.place_point(d.origin + {c.x, deep.floor + 1, c.y})
}

// boss_toward_door: the way from the custodian's post to the chamber's door (a unit step).
boss_toward_door :: proc(d: ^Delve) -> [2]f64 {
	steps := DIR_STEP
	s := steps[d.plan.boss_from]
	return {f64(s.x), f64(s.y)}
}

// boss_vault_point: where the vault's reward drops.
boss_vault_point :: proc(d: ^Delve) -> [3]f64 {
	deep, _, cell := boss_room(d)
	v := BOSS_VAULT
	c := boss_place(cell, d.plan.boss_from, DELVE_MID, v[1])
	return play.place_point(d.origin + {c.x, deep.floor + 1, c.y}) + {0, 0.5, 0}
}

// boss_put_out: c set down in the corridor outside the chamber's door, facing away from it.
boss_put_out :: proc(s: ^core.Server, d: ^Delve, c: ^core.Client) {
	b := boss_seal_box(d)
	door := boss_toward_door(d)
	mid := [3]f64{f64(b.lo.x + b.hi.x) / 2 + 0.5, f64(b.lo.y), f64(b.lo.z + b.hi.z) / 2 + 0.5}
	at := mid + {door.x * 2, 0, door.y * 2}
	core.teleport(s, c, at, play.look_at(at, at + {door.x, 0, door.y}))
	core.notice(s, c, "You stand outside the keepers' deepest chamber")
}

// boss_ward: blocks of a box raised to the ward (or lowered to air).
@(private = "file")
boss_ward :: proc(s: ^core.Server, w: ^core.World, b: core.Box, up: bool) {
	ward := delves_of(s).kit.ward
	e := core.Bulk_Edit {
		shape   = b,
		op      = .Replace,
		from    = .Air if up else ward,
		block   = ward if up else .Air,
		partial = true,
	}
	core.bulk_edit(w, e, core.game_act(s, w, .Structure))
}

// boss_reset: the chamber as a session first finds it (or as a fight is lost): the seal down,
// the vault shut unless won this session (anyone in it set down outside the door first), the
// custodians and scuttlers in the hall gone and the custodian set down whole at its post,
// asleep.
boss_reset :: proc(s: ^core.Server, w: ^core.World, d: ^Delve) {
	f := &d.fight
	boss_ward(s, w, boss_seal_box(d), false)
	if !f.won {
		for &c in s.clients {
			if c.state == .Playing && c.world == w && boss_in_vault(d, c.player.position) {
				boss_put_out(s, d, &c)
			}
		}
		boss_ward(s, w, boss_ward_box(d), true)
	}
	g := state(s)
	post := boss_post_point(d)
	for which in ([2]Wild{.Custodian, .Scuttler}) {
		for h in core.entities_of(w, g.wild[which], post, 12) {
			if boss_in_hall(d, core.entity_pos(w, h)) {core.entity_gone(w, h)}
		}
	}
	f^ = {
		won = f.won,
	}
	h := core.entity_spawn(w, g.wild[.Custodian], post, false)
	if h == 0 {return}
	core.entity_set_look(w, h, boss_yaw(d), 0)
	wild_begin(s, w, .Custodian, h)
	f.boss = core.entity_id(w, h)
	if cr := creature(s, w, h); cr != nil && d.still {
		cr.still, cr.mind.state = true, .Idle // (on its feet for a picture: /delve here ... still)
		wild_show(w, h, cr)
	}
}

// boss_yaw: the custodian faces its chamber's door.
@(private = "file")
boss_yaw :: proc(d: ^Delve) -> f32 {
	door := boss_toward_door(d)
	l := play.look_at({}, {door.x, 0, door.y})
	return l[0]
}

// boss_fighters: the players fighting in the chamber: those who can be hurt in its hall.
@(private = "file")
boss_fighters :: proc(s: ^core.Server, w: ^core.World, d: ^Delve) -> (n: int) {
	for &c in s.clients {if boss_fighting(s, w, d, &c) {n += 1}}
	return
}

@(private = "file")
boss_fighting :: proc(s: ^core.Server, w: ^core.World, d: ^Delve, c: ^core.Client) -> bool {
	return(
		c.state == .Playing &&
		c.world == w &&
		!c.dead &&
		wild_prey(s, c) &&
		boss_in_hall(d, c.player.position) \
	)
}

// boss_fighting_any: c fights a custodian in its hall (any delve's, the fight on).
boss_fighting_any :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	if c.world != s.home {return false}
	dv := delves_of(s)
	for &d in dv.all[:dv.count] {
		if d.built && d.fight.on && boss_fighting(s, s.home, &d, c) {return true}
	}
	return false
}

// boss_tell: every fighter is told.
@(private = "file")
boss_tell :: proc(s: ^core.Server, w: ^core.World, d: ^Delve, text: string) {
	for &c in s.clients {if boss_fighting(s, w, d, &c) {core.notice(s, &c, text)}}
}

// boss_tick: a ready delve's fight: woken by a fighter in its hall (the seal up), its phase
// by the custodian's health, lost when no fighter is left; each player told the fight it is
// in, or none.
boss_tick :: proc(s: ^core.Server, w: ^core.World, d: ^Delve) {
	f := &d.fight
	if !d.ready {return}
	h, there := core.entity_find(w, f.boss)
	fighters := boss_fighters(s, w, d)
	switch {
	case !f.on && there && fighters > 0:
		f.on = true
		f.step, f.timer, f.phase = .Waking, BOSS_WAKE, 0
		phases := BOSS_PHASES
		f.slam_due = phases[0].slam_every / 2
		boss_ward(s, w, boss_seal_box(d), true)
		boss_tell(s, w, d, phases[0].told)
		log.infof("delve fight on middle=%v fighters=%d", d.site.middle, fighters)
	case f.on && fighters == 0:
		boss_end(s, w, d, false)
	case f.on && there:
		phases := BOSS_PHASES
		share := f32(core.entity_health_of(w, h)) / f32(max(core.entity_max_health(w, h), 1))
		for f.phase + 1 < len(phases) && share <= phases[f.phase + 1].from {
			f.phase += 1
			f.summon_due = phases[f.phase].summon_every / 2
			boss_tell(s, w, d, phases[f.phase].told)
		}
	}
	boss_put(s, w, d)
}

// boss_put: each fighter is shown the fight; any other player in the home world none (a
// player fights in one chamber at the most).
@(private = "file")
boss_put :: proc(s: ^core.Server, w: ^core.World, d: ^Delve) {
	f := &d.fight
	shown := sandbox.Delve_Fight {
		phase  = u8(f.phase + 1),
		phases = len(BOSS_PHASES),
		open   = f.step == .Venting,
	}
	if h, there := core.entity_find(w, f.boss); there {
		shown.health = u16(max(core.entity_health_of(w, h), 0))
		shown.most = u16(core.entity_max_health(w, h))
	}
	none := sandbox.Delve_Fight{}
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		if f.on && boss_fighting(s, w, d, &c) {
			core.game_put(s, &c, &shown)
		} else if !delve_fights_elsewhere(s, d, &c) {
			core.game_put(s, &c, &none)
		}
	}
}

// delve_fights_elsewhere: c fights in another delve's chamber (whose put stands).
@(private = "file")
delve_fights_elsewhere :: proc(s: ^core.Server, d: ^Delve, c: ^core.Client) -> bool {
	dv := delves_of(s)
	for &o in dv.all[:dv.count] {
		if &o != d && o.fight.on && boss_in_hall(&o, c.player.position) {return true}
	}
	return false
}

// boss_end: the fight over, won (the custodian dead) or lost; the seal falls.
@(private = "file")
boss_end :: proc(s: ^core.Server, w: ^core.World, d: ^Delve, won: bool) {
	f := &d.fight
	winners := 0
	if won {
		reward := BOSS_REWARD
		at := boss_vault_point(d)
		for &c in s.clients {
			if !boss_fighting(s, w, d, &c) {continue}
			winners += 1
			core.notice(s, &c, "The custodian falls. Its vault stands open.")
			for name in reward {
				if item, ok := game.registry_item(s.registry, name); ok {
					core.item_drop(s, w, at, {item = item, count = 1})
				}
			}
			core.quest_note(s, &c, {goal = .Win, name = BOSS_ENCOUNTER, count = 1})
			mood_won(s, &c)
		}
		boss_ward(s, w, boss_ward_box(d), false)
	}
	for id in f.adds[:f.add_count] {
		if h, there := core.entity_find(w, id); there {core.entity_gone(w, h)}
	}
	f.add_count = 0
	log.infof("delve fight over middle=%v won=%v winners=%d", d.site.middle, won, winners)
	if won {
		f^ = {
			won = true,
		}
		boss_ward(s, w, boss_seal_box(d), false)
		return
	}
	boss_reset(s, w, d)
}

// boss_entity_died: the custodian killed wins its fight; a scuttler it called leaves its list.
boss_entity_died :: proc(s: ^core.Server, w: ^core.World, dead: core.Dead_Entity) {
	if w != s.home {return}
	dv := delves_of(s)
	for &d in dv.all[:dv.count] {
		f := &d.fight
		if f.boss != 0 && dead.id == f.boss {
			if f.on {boss_end(s, w, &d, true)} else {f.boss = 0}
			return
		}
		for i := 0; i < f.add_count; i += 1 {
			if f.adds[i] != dead.id {continue}
			f.adds[i] = f.adds[f.add_count - 1]
			f.add_count -= 1
			return
		}
	}
}

// boss_of: the delve whose custodian h is (nil: one set down elsewhere).
@(private = "file")
boss_of :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle) -> ^Delve {
	if w != s.home {return nil}
	id := core.entity_id(w, h)
	dv := delves_of(s)
	for &d in dv.all[:dv.count] {if d.fight.boss == id {return &d}}
	return nil
}

// boss_think: the custodian's mind (wild_think): outside a delve a sleeper's; in one, its
// fight's step.
boss_think :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle, cr: ^Creature) {
	m := &cr.mind
	d := boss_of(s, w, h)
	if d == nil {
		sleeper_think(s, w, h, m, BOSS_TEMPER, .Dormant)
		return
	}
	f := &d.fight
	phases := BOSS_PHASES
	p := phases[f.phase]
	prey := boss_prey(s, w, d, h)
	switch f.step {
	case .Asleep:
		play.mind_set(m, .Dormant, 0)
		core.entity_stand(w, h)
		if most := core.entity_max_health(w, h); core.entity_health_of(w, h) < most {
			core.entity_heal(w, h, most)
		}
	case .Waking:
		m.state = .Wake
		core.entity_stand(w, h)
		if prey != nil {play.face(w, h, prey.player.position, 2.5, 0.3)}
		f.timer -= 1
		if f.timer <= 0 {f.step = .Fighting}
	case .Fighting:
		m.state = .Fight
		core.entity_set_speed(w, h, p.speed)
		if prey != nil {play.fight_fair(s, w, h, m, prey, p.wind)}
		f.slam_due -= 1
		if f.slam_due <= 0 && m.wind == 0 {
			f.step, f.timer = .Charging, p.slam_wind
			core.entity_stand(w, h)
		}
		if p.summon_every > 0 {
			f.summon_due -= 1
			if f.summon_due <= 0 {
				boss_summon(s, w, d, p.summon)
				f.summon_due = p.summon_every
			}
		}
	case .Charging:
		core.entity_stand(w, h)
		if prey != nil {play.face(w, h, prey.player.position, 2.5, 0.3)}
		f.timer -= 1
		if f.timer <= 0 {
			boss_slam(s, w, d, h, p)
			f.step, f.timer = .Venting, p.vent
		}
	case .Venting:
		core.entity_stand(w, h)
		f.timer -= 1
		if f.timer <= 0 {
			f.step, f.slam_due = .Fighting, p.slam_every
		}
	}
	boss_show(w, h, f)
}

// boss_show: the custodian's looks of its step: charging (its core blazing, arms up) and
// venting (its casing open, steam rising).
@(private = "file")
boss_show :: proc(w: ^core.World, h: game.Entity_Handle, f: ^Boss_Fight) {
	charging, venting := f.step == .Charging, f.step == .Venting
	if charging != f.charging_shown {core.entity_show(w, h, "charging", charging)}
	if venting != f.venting_shown {core.entity_show(w, h, "venting", venting)}
	f.charging_shown, f.venting_shown = charging, venting
}

// boss_prey: the fighter nearest the custodian.
@(private = "file")
boss_prey :: proc(
	s: ^core.Server,
	w: ^core.World,
	d: ^Delve,
	h: game.Entity_Handle,
) -> ^core.Client {
	pos := core.entity_pos(w, h)
	best: ^core.Client
	nearest := max(f64)
	for &c in s.clients {
		if !boss_fighting(s, w, d, &c) {continue}
		if far := play.distance_to(pos, c.player.position); far < nearest {best, nearest = &c, far}
	}
	return best
}

// boss_slam: the slam lands: every fighter within its reach is hurt (core.player_harm, from
// the custodian), the nearer the harder (half at its edge).
@(private = "file")
boss_slam :: proc(
	s: ^core.Server,
	w: ^core.World,
	d: ^Delve,
	h: game.Entity_Handle,
	p: Boss_Phase,
) {
	pos := core.entity_pos(w, h)
	for &c in s.clients {
		if !boss_fighting(s, w, d, &c) {continue}
		far := play.distance_to(pos, c.player.position)
		if far > p.slam_reach {continue}
		core.player_harm(s, &c, p.slam_harm * f32(1 - 0.5 * far / p.slam_reach), h, pos)
	}
}

// boss_summon: n scuttlers out of the hall's corners (BOSS_ADDS out at once at the most),
// awake and fighting.
@(private = "file")
boss_summon :: proc(s: ^core.Server, w: ^core.World, d: ^Delve, n: int) {
	f := &d.fight
	deep, room, _ := boss_room(d)
	corners := [4][2]i32{room.lo, room.hi, {room.lo.x, room.hi.y}, {room.hi.x, room.lo.y}}
	kind := state(s).wild[.Scuttler]
	for i in 0 ..< n {
		if f.add_count == BOSS_ADDS {return}
		c := corners[(int(s.tick) + i) % len(corners)]
		at := play.place_point(d.origin + {c.x, deep.floor + 1, c.y})
		h := core.entity_spawn(w, kind, at, false)
		if h == 0 {return}
		wild_begin(s, w, .Scuttler, h)
		if cr := creature(s, w, h); cr != nil {play.provoke(&cr.mind, SCUTTLER_TEMPER)}
		f.adds[f.add_count] = core.entity_id(w, h)
		f.add_count += 1
	}
	if n > 0 {boss_tell(s, w, d, fmt.tprintf("Scuttlers pour from the walls"))}
}

// boss_hurt: the custodian outside a delve is roused by harm as a sleeper is; in one, its
// fight wakes only by a fighter in its hall.
boss_hurt :: proc(s: ^core.Server, w: ^core.World, h: game.Entity_Handle, harm: core.Entity_Harm) {
	if boss_of(s, w, h) != nil {return}
	if cr := creature(s, w, h); cr != nil {play.provoke(&cr.mind, BOSS_TEMPER)}
}

// boss_harming: what of a harm gets through the custodian's casing: in a delve, none while it
// kneels (its fight begins in its hall), its phase's share shut and open; outside one, half
// while it sleeps.
boss_harming :: proc(s: ^core.Server, hm: ^core.Harming) {
	d := boss_of(s, hm.world, hm.entity)
	if d == nil {
		if cr := creature(s, hm.world, hm.entity); cr != nil && cr.mind.state == .Dormant {
			hm.amount *= 0.5
		}
		return
	}
	f := &d.fight
	phases := BOSS_PHASES
	switch {
	case !f.on || f.step == .Asleep:
		hm.amount = 0
	case f.step == .Venting:
		hm.amount *= phases[f.phase].open
	case:
		hm.amount *= phases[f.phase].shut
	}
}
