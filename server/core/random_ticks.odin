package core

import "common:base"
import "common:game"

// Random ticks (Minecraft's): every tick, in each loaded chunk, a few blocks
// (rules.random_tick_speed, 3 by default) are picked at random, and one that
// has random rules runs them (the base pack's data/sim/growth.json: grass
// spreads and dies, farmland wets and dries, wheat grows). What they change goes
// through set_block like any change (clients told, column tops, plants above checked).
//
// There is no stored light on the server (light is worked out where it is
// drawn): "lit" for grass is open sky above a block (above its column's top)
// or a lamp near it; time of day does not matter.

// random_ticks picks blocks in w's chunks and ticks them.
random_ticks :: proc(w: ^World) {
	speed := int(w.rules.random_tick_speed)
	if speed <= 0 {return}
	base.profile_scope("sampling")
	it: base.Pool_Iterator
	for c in base.pool_next(&w.chunks.chunks, &it) { 	// (slot order: map order would change what grows)
		if c.state != .Ready || c.blocks.array == nil {continue} 	// (uniform: nothing grows)
		if c.random_blocks == 0 {
			for _ in 0 ..< speed {
				base.rng_u32(&w.tick_rng)
			}
			continue
		}
		origin := game.chunk_origin(c.pos)
		for _ in 0 ..< speed {
			i := int(base.rng_u32(&w.tick_rng)) & (game.CHUNK_VOLUME - 1)
			b := c.blocks.array[i]
			if !has_random_tick(w, b) {continue}
			random_tick(w, origin + game.local_from_index(i), b)
		}
	}
}

// has_random_tick: blocks that change by themselves (they have a random rule).
has_random_tick :: proc(w: ^World, b: game.Block) -> bool {
	r := w.server.registry.sim.random
	return int(b) < len(r) && len(r[b]) > 0
}

// random_tick runs the random rules of block b at p, in rule order; once one changes the
// block at p, the rest are skipped. The act has no action: the tick's action is opened by the first
// write (set_block asks for it), as when this was code; opening it here would change the journal.
random_tick :: proc(w: ^World, p: game.Block_Pos, b: game.Block) {
	base.profile_scope("rules")
	sim := &w.server.registry.sim
	for ri in sim.random[b] {
		w.random_runs += 1
		if rule_run(w, p, &sim.rules[ri], Act{0, .Random_Tick}).changed_self {return}
	}
}
