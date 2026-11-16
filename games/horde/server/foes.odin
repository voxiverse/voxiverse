package horde_server

import "core:math"

import "common:game"
import "games:horde"
import "server:core"
import "server:play"

// The horde: walkers of the pack's kinds, each with a slot here (its kind and whom it
// hunts). A creature goes for the nearest survivor standing, looking again every
// RETARGET ticks or when its prey goes down or leaves, keeps its band of distances from
// it (the engine's steering) and strikes or spits when its attack is ready.

MAX_FOES :: 160 // creatures alive at once (a wave's later ones wait their turn)
RETARGET :: game.TICK_RATE / 2

// Foe_Slot: a creature the game made.
Foe_Slot :: struct {
	id:   u32, // its entity id
	foe:  horde.Foe,
	prey: core.Player_Ref,
}

// foe_spawn: a creature of a kind at p, as tough as the wave; 0 when the slots or the
// world are full.
foe_spawn :: proc(s: ^core.Server, f: horde.Foe, p: [3]f64) -> game.Entity_Handle {
	d := state(s)
	if d.foe_count >= MAX_FOES {return 0}
	w := s.home
	h := core.entity_spawn(w, d.kinds[f], p, false)
	if h == 0 {return 0}
	health := f32(core.entity_max_health(w, h)) * d.toughness
	core.entity_set_max_health(w, h, max(int(math.round(health)), 1))
	d.foes[d.foe_count] = {
		id  = core.entity_id(w, h),
		foe = f,
	}
	d.foe_count += 1
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

// foes_clear: every creature goes (a run's end, everyone gone).
foes_clear :: proc(s: ^core.Server) {
	d := state(s)
	for f in d.foes[:d.foe_count] {
		if h, there := core.entity_find(s.home, f.id); there {core.entity_gone(s.home, h)}
	}
	d.foe_count = 0
}

// foes_tick: every creature finds its prey, closes in and attacks.
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
		c := core.player_of(s, f.prey)
		if c == nil || !standing(s, c) || (s.tick + u64(f.id)) % RETARGET == 0 {
			c = nearest_standing(s, core.entity_pos(w, h))
			if c == nil {
				core.entity_stand(w, h)
				continue
			}
			f.prey = core.player_ref(s, c)
		}
		hunt(s, f, h, c)
	}
}

// hunt: a creature keeps its band from its prey and attacks when it can.
hunt :: proc(s: ^core.Server, f: ^Foe_Slot, h: game.Entity_Handle, c: ^core.Client) {
	w := s.home
	info := horde.FOES[f.foe]
	feet := c.player.position
	chest := feet + {0, 1.1, 0}
	d := core.entity_pos(w, h) - feet
	distance := math.sqrt(d.x * d.x + d.z * d.z)
	core.entity_keep(w, h, feet, info.keep[0], info.keep[1])
	switch f.foe {
	case .Spitter:
		if distance <= horde.SPIT_RANGE && core.entity_sees(w, h, chest) {
			core.entity_shoot(w, h, chest)
		}
	case .Matriarch:
		if distance > horde.MATRIARCH_SPIT_FROM && core.entity_sees(w, h, chest) {
			core.entity_shoot(w, h, chest)
		} else {
			core.entity_strike(w, h, c)
		}
	case .Shambler, .Skitter, .Hulk:
		core.entity_strike(w, h, c)
	}
}

// nearest_standing: the survivor standing nearest p (nil: none).
nearest_standing :: proc(s: ^core.Server, p: [3]f64) -> ^core.Client {
	best: ^core.Client
	best_d := max(f64)
	for &c in s.clients {
		if !standing(s, &c) {continue}
		d := c.player.position - p
		dist := d.x * d.x + d.z * d.z
		if dist < best_d {best, best_d = &c, dist}
	}
	return best
}

// standing: c plays the run and is not down.
standing :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	return play.here(s, c) && !c.dead && !survivor(s, c).down && survivor(s, c).run == state(s).run
}
