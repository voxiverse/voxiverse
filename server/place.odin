package server

import "core:math"

import "common:game"
import "common:worldgen"

// The place record (M44): the biome under the player's feet and the world's
// warmth and wetness, for the client's music. Put every PLACE_TICKS ticks; the
// sender sends it only when it differs from what the client has.

PLACE_TICKS :: 15

#assert(len(worldgen.Biome) <= game.MAX_BIOMES)

// music_place_of: where a player standing at feet is, in w.
music_place_of :: proc(w: ^World, feet: [3]f64) -> game.Place {
	gen := &w.chunks.gen
	if gen.kind != .Earth {return {biome = game.NO_BIOME}}
	percent :: proc(v: f32) -> i8 {return i8(clamp(math.round(v * 100), -100, 100))}
	x, z := i32(math.floor(feet.x)), i32(math.floor(feet.z))
	return {
		biome = u8(worldgen.earth_biome(gen, x, z)),
		warmth = percent(w.params.warmth),
		wetness = percent(w.params.wetness),
	}
}

// place_tick: once a tick for each playing client.
place_tick :: proc(s: ^Server, c: ^Client) {
	if s.tick % PLACE_TICKS != 0 {return}
	place := music_place_of(c.world, c.player.position)
	state_put(s, c, .Place, &place)
}
