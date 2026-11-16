package delve_server

import "core:math"

import "common:base"
import "common:game"
import "games:delve"
import "server:core"

// The creatures: walkers of the pack's kinds, each with a slot here (its kind, its rank,
// its name, whether it is awake and whom it hunts). Asleep, a creature stands where it
// was made and looks about every half second for a delver within its aggro that it can
// see; awake, it keeps its band of distances from its prey (the engine's steering) and
// strikes or spits when its attack is ready. A creature hurt wakes on its attacker; one
// whose prey died, left or got too far looks for another, or sleeps again.

// Foe_Slot: a creature the game made.
Foe_Slot :: struct {
	id:       u32, // its entity id
	foe:      delve.Foe,
	elite:    bool,
	level:    int, // the depth it was made for
	name:     [16]u8, // an elite's or the warden's
	name_len: int,
	awake:    bool,
	prey:     core.Player_Ref,
}

LOOK_EVERY :: game.TICK_RATE / 2 // ticks between an asleep creature's looks

// foe_spawn: a creature of a kind at p, as tough as the dungeon's depth (an elite more,
// and named); 0 when the slots or the world are full.
foe_spawn :: proc(s: ^core.Server, f: delve.Foe, p: [3]f64, elite: bool) -> game.Entity_Handle {
	d := state(s)
	if d.foe_count >= MAX_FOES {return 0}
	w := s.home
	h := core.entity_spawn(w, d.kinds[f], p, false)
	if h == 0 {return 0}
	health := f32(core.entity_max_health(w, h)) * delve.depth_toughness(d.depth)
	if elite {health *= delve.ELITE_HEALTH}
	core.entity_set_max_health(w, h, int(math.round(health)))
	slot := &d.foes[d.foe_count]
	d.foe_count += 1
	slot^ = {
		id    = core.entity_id(w, h),
		foe   = f,
		elite = elite,
		level = d.depth,
	}
	switch {
	case f == .Warden:
		slot.name_len = copy(slot.name[:], "The Warden")
	case elite:
		slot.name_len = copy(slot.name[:], delve.elite_name(&d.rng))
	}
	return h
}

// foe_of: the slot of a creature by its entity id (nil: none of the game's).
foe_of :: proc(s: ^core.Server, id: u32) -> ^Foe_Slot {
	d := state(s)
	for &f in d.foes[:d.foe_count] {if f.id == id {return &f}}
	return nil
}

// foe_forget: a creature's slot goes (it died, or is gone).
foe_forget :: proc(s: ^core.Server, id: u32) {
	d := state(s)
	for f, i in d.foes[:d.foe_count] {
		if f.id != id {continue}
		d.foes[i] = d.foes[d.foe_count - 1]
		d.foe_count -= 1
		return
	}
}

foes_alive :: proc(s: ^core.Server) -> int {
	return state(s).foe_count
}

// foes_clear: every creature, chest and dropped stack goes (a new dungeon).
foes_clear :: proc(s: ^core.Server) {
	d := state(s)
	w := s.home
	it := core.entities_each(w)
	for h in core.entities_next(&it) {core.entity_gone(w, h)}
	d.foe_count = 0
}

// foes_tick: every creature looks, hunts and attacks.
foes_tick :: proc(s: ^core.Server) {
	d := state(s)
	w := s.home
	for i := 0; i < d.foe_count; i += 1 {
		f := &d.foes[i]
		h, there := core.entity_find(w, f.id)
		if !there {
			foe_forget(s, f.id)
			i -= 1
			continue
		}
		info := delve.FOES[f.foe]
		if !f.awake {
			if (s.tick + u64(f.id)) % LOOK_EVERY != 0 {continue}
			if c := nearest_seen(s, h, info.aggro); c != nil {
				f.awake, f.prey = true, core.player_ref(s, c)
			}
			continue
		}
		c := core.player_of(s, f.prey)
		if c == nil ||
		   c.dead ||
		   !here(s, c) ||
		   flat_distance(core.entity_pos(w, h), c.player.position) > delve.LEASH {
			c = nearest_seen(s, h, info.aggro)
			if c == nil {
				f.awake = false
				core.entity_stand(w, h)
				continue
			}
			f.prey = core.player_ref(s, c)
		}
		hunt(s, f, h, c)
	}
	if d.warden != 0 && s.tick >= d.warden_call {warden_calls(s)}
}

// hunt: an awake creature keeps its band from its prey and attacks when it can.
hunt :: proc(s: ^core.Server, f: ^Foe_Slot, h: game.Entity_Handle, c: ^core.Client) {
	w := s.home
	info := delve.FOES[f.foe]
	feet := c.player.position
	chest := feet + {0, 1.1, 0}
	distance := flat_distance(core.entity_pos(w, h), feet)
	switch f.foe {
	case .Spitter:
		core.entity_keep(w, h, feet, info.keep[0], info.keep[1])
		if distance <= delve.SPIT_RANGE && core.entity_sees(w, h, chest) {
			core.entity_shoot(w, h, chest)
		}
	case .Warden:
		if distance > delve.WARDEN_SPIT_FROM && core.entity_sees(w, h, chest) {
			core.entity_keep(w, h, feet, 0, info.keep[1])
			core.entity_shoot(w, h, chest)
		} else {
			core.entity_keep(w, h, feet, 0, info.keep[1])
			core.entity_strike(w, h, c)
		}
	case .Biter, .Husk, .Brute:
		core.entity_keep(w, h, feet, info.keep[0], info.keep[1])
		core.entity_strike(w, h, c)
	}
}

// warden_calls: the awake warden calls two biters to its side.
warden_calls :: proc(s: ^core.Server) {
	d := state(s)
	d.warden_call = s.tick + u64(delve.WARDEN_CALL_SECONDS * game.TICK_RATE)
	f := foe_of(s, d.warden)
	if f == nil || !f.awake {return}
	h, there := core.entity_find(s.home, d.warden)
	if !there {return}
	p := core.entity_pos(s.home, h)
	for side in ([2]f64{-1.5, 1.5}) {
		if b := foe_spawn(s, .Biter, p + {side, 0, 0}, false); b != 0 {
			slot := foe_of(s, core.entity_id(s.home, b))
			slot.awake, slot.prey = true, f.prey
		}
	}
}

// nearest_seen: the nearest delver within radius that the creature sees (nil: none).
nearest_seen :: proc(s: ^core.Server, h: game.Entity_Handle, radius: f64) -> ^core.Client {
	w := s.home
	p := core.entity_pos(w, h)
	best: ^core.Client
	best_d := radius
	for &c in s.clients {
		if !here(s, &c) || c.dead {continue}
		dist := flat_distance(p, c.player.position)
		if dist > best_d || abs(c.player.position.y - p.y) > 4 {continue}
		if !core.entity_sees(w, h, c.player.position + {0, 1.5, 0}) {continue}
		best, best_d = &c, dist
	}
	return best
}

flat_distance :: proc(a, b: [3]f64) -> f64 {
	d := a - b
	return math.sqrt(d.x * d.x + d.z * d.z)
}

// entity_hurt: a creature hurt by a delver wakes on it.
entity_hurt :: proc(
	s: ^core.Server,
	w: ^core.World,
	h: game.Entity_Handle,
	harm: core.Entity_Harm,
) {
	if harm.by == nil {return}
	if f := foe_of(s, core.entity_id(w, h)); f != nil {
		f.awake, f.prey = true, core.player_ref(s, harm.by)
	}
}

// foe_damage: what the game makes of a creature's blow or spit: its depth's toughness,
// an elite's more.
foe_damage :: proc(s: ^core.Server, id: u32, amount: f32) -> f32 {
	f := foe_of(s, id)
	if f == nil {return amount}
	k := delve.depth_toughness(f.level)
	if f.elite {k *= delve.ELITE_DAMAGE}
	return amount * k
}

// crit: a delver's blow lands a critical hit (the run's dice: the same every run).
crit :: proc(s: ^core.Server) -> bool {
	return base.rng_f64(&state(s).rng) < delve.CRIT_CHANCE
}
