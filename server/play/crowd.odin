package play

import "core:math"

import "common:game"
import "common:wave"
import "server:core"

// A crowd: the creatures of a game's waves (common:wave) in one world, each with a slot
// here (its kind and whom it hunts). A wave sent (crowd_send) comes out of the game's
// lairs one creature at a time (crowd_spawn_due), each as much tougher than its kind as
// the wave says; each goes for the nearest player the game's rule lets it hunt, looking
// again every RETARGET ticks or when its prey may no longer be hunted, and hunts it as
// every game's creatures do (hunt). Horde's runs and the sandbox's ruined site are crowds;
// what a kill pays and when a wave is over is the game's.

MAX_FOES :: 160 // creatures of a crowd alive at once (a wave's later ones wait their turn)
RETARGET :: game.TICK_RATE / 2

// Foe_Slot: a creature of the crowd.
Foe_Slot :: struct {
	id:   u32, // its entity id
	foe:  wave.Foe,
	prey: core.Player_Ref,
}

// Crowd: a game's waves in one world: the kinds, the wave on its way out of the lairs and
// the creatures out.
Crowd :: struct {
	kinds:      [wave.Foe]game.Kind_Id, // each foe's kind in this session's registry
	coming:     [wave.Foe]int, // still to come, of each kind
	toughness:  f32, // the wave's creatures' health, times their kind's
	next_spawn: u64, // the tick the next one comes out
	next_lair:  int, // the lair the next one comes out of
	foes:       [MAX_FOES]Foe_Slot,
	foe_count:  int,
}

// crowd_start: the foes' kinds looked up in the session's registry (the game's start
// hook); false: the registry lacks one.
crowd_start :: proc(s: ^core.Server, c: ^Crowd) -> bool {
	for &k, f in c.kinds {k = game.registry_kind(s.registry, wave.KINDS[f]) or_return}
	return true
}

// crowd_send: wave n sets out: its creatures come out from this tick on (crowd_spawn_due).
crowd_send :: proc(s: ^core.Server, c: ^Crowd, n: int) {
	p := wave.plan(n)
	c.coming, c.toughness = p.count, p.health
	c.next_spawn = s.tick
}

// crowd_waiting: the creatures of the wave still to come out.
crowd_waiting :: proc(c: ^Crowd) -> (n: int) {
	for k in c.coming {n += k}
	return
}

// crowd_spawn_due: the next creature of the wave comes out of the next lair (lairs: the
// points they come out at, taken in turn) when due, `every` seconds after the last: the
// matriarch first, then of the kind with the most still to come, so a wave mixes them.
crowd_spawn_due :: proc(s: ^core.Server, c: ^Crowd, w: ^core.World, lairs: [][3]f64, every: f64) {
	if crowd_waiting(c) == 0 || s.tick < c.next_spawn || len(lairs) == 0 {return}
	c.next_spawn = s.tick + u64(every * game.TICK_RATE)
	pick := wave.Foe.Matriarch
	if c.coming[.Matriarch] == 0 {
		pick = .Shambler
		for k in wave.Foe {if c.coming[k] > c.coming[pick] {pick = k}}
	}
	at := lairs[c.next_lair % len(lairs)]
	c.next_lair += 1
	if crowd_spawn(s, c, w, pick, at) != 0 {c.coming[pick] -= 1}
}

// crowd_spawn: a creature of a kind at p in w, as tough as the wave; 0 when the crowd or
// the world is full.
crowd_spawn :: proc(
	s: ^core.Server,
	c: ^Crowd,
	w: ^core.World,
	f: wave.Foe,
	p: [3]f64,
) -> game.Entity_Handle {
	if c.foe_count >= MAX_FOES {return 0}
	h := core.entity_spawn(w, c.kinds[f], p, false)
	if h == 0 {return 0}
	health := f32(core.entity_max_health(w, h)) * c.toughness
	core.entity_set_max_health(w, h, max(int(math.round(health)), 1))
	c.foes[c.foe_count] = {
		id  = core.entity_id(w, h),
		foe = f,
	}
	c.foe_count += 1
	return h
}

// crowd_find: the slot of a creature by its entity id (nil: none of the crowd's).
crowd_find :: proc(c: ^Crowd, id: u32) -> ^Foe_Slot {
	for &f in c.foes[:c.foe_count] {if f.id == id {return &f}}
	return nil
}

// crowd_forget: a creature's slot goes (it died, or is gone).
crowd_forget :: proc(c: ^Crowd, id: u32) {
	for f, i in c.foes[:c.foe_count] {
		if f.id != id {continue}
		c.foes[i] = c.foes[c.foe_count - 1]
		c.foe_count -= 1
		return
	}
}

// crowd_clear: every creature of the crowd in w goes, and none is to come.
crowd_clear :: proc(c: ^Crowd, w: ^core.World) {
	for f in c.foes[:c.foe_count] {
		if h, there := core.entity_find(w, f.id); there {core.entity_gone(w, h)}
	}
	c.foe_count = 0
	c.coming = {}
}

// crowd_tick: every creature of the crowd in w finds its prey (the player nearest it that
// may says it hunts), closes in and attacks; one with none stands.
crowd_tick :: proc(
	s: ^core.Server,
	c: ^Crowd,
	w: ^core.World,
	may: proc(s: ^core.Server, c: ^core.Client) -> bool,
) {
	for i := 0; i < c.foe_count; i += 1 {
		f := &c.foes[i]
		h, there := core.entity_find(w, f.id)
		if !there {
			crowd_forget(c, f.id)
			i -= 1
			continue
		}
		prey := core.player_of(s, f.prey)
		if prey == nil || !may(s, prey) || (s.tick + u64(f.id)) % RETARGET == 0 {
			prey = prey_nearest(s, w, core.entity_pos(w, h), max(f64), may)
			if prey == nil {
				core.entity_stand(w, h)
				continue
			}
			f.prey = core.player_ref(s, prey)
		}
		hunt(s, w, h, prey)
	}
}
