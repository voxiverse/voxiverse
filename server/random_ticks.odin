package server

import "common:base"
import "common:game"

// Random ticks (Minecraft's): every tick, in each loaded chunk, a few blocks
// (rules.random_tick_speed, 3 by default) are picked at random, and one that
// has a random tick runs it: grass spreads to dirt beside it, or dies under
// something solid; farmland dries and wets and reverts; wheat grows. What
// they change goes through set_block like any change (clients told, column
// tops, plants above checked).
//
// There is no stored light on the server (light is worked out where it is
// drawn): "lit" for grass is open sky above a block (above its column's top)
// or a lamp near it; time of day does not matter.

// random_ticks picks blocks in w's chunks and ticks them.
random_ticks :: proc(w: ^World) {
	speed := int(w.rules.random_tick_speed)
	if speed <= 0 {return}
	it: base.Pool_Iterator
	for c in base.pool_next(&w.chunks.chunks, &it) { 	// (slot order: map order would change what grows)
		if c.state != .Ready || c.blocks.array == nil {continue} 	// (uniform: nothing grows)
		origin := game.chunk_origin(c.pos)
		for _ in 0 ..< speed {
			i := int(base.rng_u32(&w.tick_rng)) & (game.CHUNK_VOLUME - 1)
			b := c.blocks.array[i]
			if !has_random_tick(b) {continue}
			random_tick(w, origin + game.local_from_index(i), b)
		}
	}
}

// has_random_tick: blocks that change by themselves.
has_random_tick :: proc(b: game.Block) -> bool {
	if _, wheat := game.wheat_stage(b); wheat {return true}
	return b == .Grass || game.block_is_farmland(b)
}

// random_tick runs the random tick of block b at p.
random_tick :: proc(w: ^World, p: game.Block_Pos, b: game.Block) {
	r := &w.tick_rng
	up := p + {0, 1, 0}
	above, loaded := chunks_block(&w.chunks, up)
	if !loaded {return}
	switch {
	case b == .Grass:
		if game.block_opaque(&w.server.registry.blocks, above) {
			set_block(w, p, .Dirt, world_act(w, .Random_Tick)) // buried
			return
		}
		// Spread: a few tries at dirt in the 3 x 5 x 3 around (lit, nothing solid on it).
		for _ in 0 ..< 4 {
			t :=
				p +
				{
						i32(base.rng_int_max(r, 3)) - 1,
						i32(base.rng_int_max(r, 5)) - 3,
						i32(base.rng_int_max(r, 3)) - 1,
					}
			tb, t_loaded := chunks_block(&w.chunks, t)
			if !t_loaded || tb != .Dirt {continue}
			over, over_loaded := chunks_block(&w.chunks, t + {0, 1, 0})
			if !over_loaded ||
			   game.block_opaque(&w.server.registry.blocks, over) ||
			   light_above(w, t + {0, 1, 0}) < 9 {continue}
			set_block(w, t, .Grass, world_act(w, .Random_Tick))
		}
	case game.block_is_farmland(b):
		wet := farmland_wet(w, p)
		switch {
		case wet && b == .Farmland:
			set_block(w, p, .Farmland_Moist, world_act(w, .Random_Tick))
		case !wet && b == .Farmland_Moist:
			set_block(w, p, .Farmland, world_act(w, .Random_Tick))
		case !wet && b == .Farmland:
			// Dry and nothing planted: back to dirt.
			if _, planted := game.wheat_stage(above);
			   !planted {set_block(w, p, .Dirt, world_act(w, .Random_Tick))}
		}
	case:
		stage, _ := game.wheat_stage(b)
		if stage >= game.WHEAT_STAGES - 1 {return}
		below, _ := chunks_block(&w.chunks, p + {0, -1, 0})
		chance := i32(3) if below == .Farmland_Moist else 6
		if i32(base.rng_int_max(r, int(chance))) ==
		   0 {set_block(w, p, game.wheat_block(stage + 1), world_act(w, .Random_Tick))}
	}
}

// farmland_wet: water within 4 blocks across, on the farmland's level or the
// one above.
farmland_wet :: proc(w: ^World, p: game.Block_Pos) -> bool {
	for y in i32(0) ..= 1 {
		for z in i32(-4) ..= 4 {
			for x in i32(-4) ..= 4 {
				b, _ := chunks_block(&w.chunks, p + {x, y, z})
				if _, water := game.water_level(b); water {return true}
			}
		}
	}
	return false
}

// light_above: the light at q for grass to spread by: 15 under open sky,
// else what the nearest lamp gives (15 less its distance), else 0.
light_above :: proc(w: ^World, q: game.Block_Pos) -> int {
	if column_top(w, q.x, q.z) < q.y {return 15}
	best := 0
	for y in i32(-6) ..= 6 {
		for z in i32(-6) ..= 6 {
			for x in i32(-6) ..= 6 {
				d := int(abs(x) + abs(y) + abs(z))
				if d > 6 {continue}
				b, _ := chunks_block(&w.chunks, q + {x, y, z})
				if b == .Lamp {best = max(best, 15 - d)}
			}
		}
	}
	return best
}
