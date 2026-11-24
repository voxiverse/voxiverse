package core

import "core:fmt"
import "core:math"
import "core:slice"

import "common:game"
import "common:protocol"
import "common:starmap"
import "common:worldgen"

// The weather (common/game/weather.odin) is a function of a world's weather seed and
// its clock, so the server sends each client only that seed, the kind the world was
// set to (/weather, kept in world.cfg) and the climate where the player stands (the
// Weather record); the client works out the rest as the server would.
//
// Hum sources: places a game marks as humming (world_hum: ancient machinery, a dead
// gate), each client told of the nearest MAX_HUM_SOURCES within HUM_RANGE (the Hum
// record), which its ambience plays as a low hum near them.

HUM_RANGE :: 96 // blocks: hum sources this near a player are sent
CLIMATE_CELL :: 32 // blocks: a player's climate is worked out again when they cross a cell

// Hum_Place: a hum source of a world's.
Hum_Place :: struct {
	at:       game.Block_Pos,
	strength: f32,
}

// world_weather_seed: w's weather seed (its own in every universe and every world).
world_weather_seed :: proc(w: ^World) -> u64 {
	return game.weather_seed(w.seed, starmap.address_hash(w.address))
}

// world_weather: the weather in w now: for a game (rain puts out fires, a storm
// keeps creatures in), the same the players see.
world_weather :: proc(w: ^World) -> game.Weather {
	return game.weather_at(world_weather_seed(w), w.clock, w.weather_forced)
}

// world_weather_set: w's weather stands at kind (nil: the spells again), told to its
// players at the end of the tick and kept in world.cfg. For a game and /weather.
world_weather_set :: proc(w: ^World, kind: Maybe(game.Weather_Kind)) {
	w.weather_forced = kind
}

// world_hum: a game marks block `at` of w as humming at strength (0..1; 0 removes it).
// Not saved: a game marks its places again when its world opens.
world_hum :: proc(w: ^World, at: game.Block_Pos, strength: f32) {
	k := clamp(strength, 0, 1)
	for &h, i in w.hums {
		if h.at != at {continue}
		if k == 0 {unordered_remove(&w.hums, i)} else {h.strength = k}
		return
	}
	if k > 0 {append(&w.hums, Hum_Place{at, k})}
}

// climate_at: the climate of block column (x, z) of w, from its generator's biome
// (an Earth world's; the others are temperate).
climate_at :: proc(w: ^World, x, z: i32) -> game.Climate {
	gen := &w.chunks.gen
	if gen.kind != .Earth {return .Temperate}
	#partial switch worldgen.earth_biome(gen, x, z) {
	case .Frozen_Ocean, .Tundra, .Ice_Sheet, .Mountains, .Cold_Desert:
		return .Cold
	case .Desert:
		return .Dry
	}
	return .Temperate
}

// weather_put: c's Weather record and the hum sources near them.
@(private)
weather_put :: proc(s: ^Server, c: ^Client) {
	w := c.world
	p := c.player.position
	cell := [2]i32{i32(math.floor(p.x / CLIMATE_CELL)), i32(math.floor(p.z / CLIMATE_CELL))}
	if !c.climate_known || cell != c.climate_cell || w != c.climate_world {
		c.climate = climate_at(w, i32(math.floor(p.x)), i32(math.floor(p.z)))
		c.climate_cell, c.climate_world, c.climate_known = cell, w, true
	}
	rec := protocol.Weather_Record {
		seed    = world_weather_seed(w),
		climate = u8(c.climate),
	}
	if k, forced := w.weather_forced.?; forced {rec.forced = u8(k) + 1}
	state_put(s, c, .Weather, &rec)
	if len(w.hums) == 0 {return}
	Near :: struct {
		place: Hum_Place,
		d2:    f64,
	}
	near := make([dynamic]Near, 0, len(w.hums), context.temp_allocator)
	for h in w.hums {
		d := [3]f64{f64(h.at.x) + 0.5, f64(h.at.y) + 0.5, f64(h.at.z) + 0.5} - p
		d2 := d.x * d.x + d.y * d.y + d.z * d.z
		if d2 <= HUM_RANGE * HUM_RANGE {append(&near, Near{h, d2})}
	}
	slice.sort_by(near[:], proc(a, b: Near) -> bool {return a.d2 < b.d2})
	for n in near[:min(len(near), protocol.MAX_HUM_SOURCES)] {
		hum := protocol.Hum_Source{n.place.strength}
		state_put(s, c, .Hum, &hum, protocol.key_of_block(n.place.at))
	}
}

// admin_weather: /weather [clear|overcast|rain|storm|fog|auto]: says the weather, or sets it.
@(private)
admin_weather :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	w := c.world
	if len(args) == 0 {
		now := world_weather(w)
		how := "set" if w.weather_forced != nil else "by the sky's own spells"
		notice(
			s,
			c,
			fmt.tprintf(
				"The weather is %s (%s): cloud %.2f, rain %.2f, storm %.2f, fog %.2f, wind %.2f; here it is %v",
				game.WEATHER_NAMES[game.weather_kind_of(now)],
				how,
				now.cover,
				now.rain,
				now.storm,
				now.fog,
				now.wind,
				c.climate,
			),
		)
		return true
	}
	if args[0] == "auto" {
		world_weather_set(w, nil)
		notice(s, c, "The weather follows its own spells again")
		return true
	}
	kind := game.weather_kind_by_name(args[0]) or_return
	world_weather_set(w, kind)
	notice(s, c, fmt.tprintf("The weather is set to %s", game.WEATHER_NAMES[kind]))
	return true
}
