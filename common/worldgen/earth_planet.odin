package worldgen

import "base:runtime"
import "core:math"
import "core:sync"

import "common:planet"

// The planet parameter: an Earth world built on common/planet. Block x is
// longitude and z is latitude (north is -z); the height is the real relief.

// PLANET_CIRCUMFERENCE: blocks round the equator (about 611 m of Earth a block).
PLANET_CIRCUMFERENCE :: 65536
// PLANET_METRES_PER_BLOCK_Y: metres of elevation in one block of height.
PLANET_METRES_PER_BLOCK_Y :: 40
// PLANET_FLOOR: the deepest ocean floor, y.
PLANET_FLOOR :: -200
// PLANET_RELIEF_SPREAD: the spread of the surrounding relief (metres) at which
// the terrain is as rugged as the noise world.
PLANET_RELIEF_SPREAD :: 1500

@(private = "file")
shared_relief: planet.Relief
@(private = "file")
shared_once: sync.Once
@(private = "file")
shared_ok: bool

// planet_relief: Earth's relief, read once for the process (any thread).
planet_relief :: proc() -> (planet.Relief, bool) {
	sync.once_do(&shared_once, proc() {
		r, ok := planet.relief_decode(
			#load("../../assets/planet/earth_relief.bin"),
			runtime.heap_allocator(),
		)
		shared_relief, shared_ok = r, ok
	})
	return shared_relief, shared_ok
}

@(private = "file")
shared_model: planet.Planet
@(private = "file")
model_once: sync.Once

// planet_model: Earth's climate grid, built once for the process (any thread)
// from the relief, on first use.
planet_model :: proc() -> planet.Planet {
	sync.once_do(&model_once, proc() {
		r, _ := planet_relief()
		shared_model = planet.planet_build(r, runtime.heap_allocator())
	})
	return shared_model
}

// planet_climate: the Köppen class of the climate at block column (x, z), from
// its own monthly climate (corrected by the lapse rate for its height, so
// mountains climb through the zones), and the coldest month's temperature.
planet_climate :: proc(x, z: i32) -> (k: planet.Koppen, coldest: f32) {
	m := planet_model()
	lat, lon := planet_lat_lon(x, z)
	t, pr: [12]f64
	coldest = max(f32)
	for i in 0 ..< 12 {
		s := planet.planet_climate_at(m, lat, lon, f64(i) + 0.5)
		t[i], pr[i] = f64(s.temperature), f64(s.precipitation)
		coldest = min(coldest, s.temperature)
	}
	return planet.koppen_classify(t, pr, lat >= 0), coldest
}

// planet_biome_of: the biome a Köppen class gives (docs/world.md, Worlds).
planet_biome_of :: proc(k: planet.Koppen) -> Biome {
	#partial switch k {
	case .Af, .Am, .Cwa, .Cwb, .Cwc, .Cfa, .Cfb, .Cfc:
		return .Forest // rainforest, subtropical and temperate forest
	case .Aw, .BSh, .BSk, .Csa, .Csb, .Csc:
		return .Plains // savanna, steppe, Mediterranean scrub
	case .BWh, .BWk:
		return .Desert
	case .Dsa, .Dsb, .Dwa, .Dwb, .Dfa, .Dfb:
		return .Forest // mixed forest
	case .Dsc, .Dsd, .Dwc, .Dwd, .Dfc, .Dfd:
		return .Taiga
	case .ET:
		return .Tundra
	case .EF:
		return .Ice_Sheet
	}
	return .Plains
}

// planet_lat_lon: the latitude and longitude, degrees, of block column (x, z).
planet_lat_lon :: proc(x, z: i32) -> (lat, lon: f64) {
	return -90 * f64(z) / (PLANET_CIRCUMFERENCE / 4), 180 * f64(x) / (PLANET_CIRCUMFERENCE / 2)
}

// planet_elevation: the relief's elevation in metres at block column (x, z).
planet_elevation :: proc(x, z: i32) -> f32 {
	r, _ := planet_relief()
	lat, lon := planet_lat_lon(x, z)
	return planet.planet_relief_at(planet.Planet{relief = r}, lat, lon)
}

// planet_ruggedness: 0..1, how rugged the relief is around (x, z): the spread
// of the 3 x 3 relief cells there, so plains stay plains.
@(private = "file")
planet_ruggedness :: proc(r: planet.Relief, lat, lon: f64) -> f32 {
	ci, cj := planet.relief_cell_of(r, lat, lon)
	lo, hi := max(i16), min(i16)
	for dj in -1 ..= 1 {
		j := clamp(cj + dj, 0, r.height - 1)
		for di in -1 ..= 1 {
			e := planet.relief_at(r, (ci + di + r.width) % r.width, j)
			lo, hi = min(lo, e), max(hi, e)
		}
	}
	return clamp(f32(int(hi) - int(lo)) / PLANET_RELIEF_SPREAD, 0, 1)
}

// PLANET_WALL_HEIGHT: how far above sea level the ice wall at the world's end stands.
PLANET_WALL_HEIGHT :: 120

// planet_past_the_edge: block column (x, z) lies beyond the poles or past the
// date line, where the world ends at an ice wall.
planet_past_the_edge :: proc(x, z: i32) -> bool {
	return abs(z) > PLANET_CIRCUMFERENCE / 4 || abs(x) > PLANET_CIRCUMFERENCE / 2
}

// planet_shape sets a column's height and roughness from the relief, with the
// noise's detail (hills, overhangs) scaled by the local ruggedness. Rivers
// come from the relief in a later part, so none are carved here.
@(private)
planet_shape :: proc(p: ^Params, c: ^Column, x, z: i32, hills, ridge: f32) {
	r, _ := planet_relief()
	lat, lon := planet_lat_lon(x, z)
	elevation := planet.planet_relief_at(planet.Planet{relief = r}, lat, lon)
	spread := planet_ruggedness(r, lat, lon)
	height := max(elevation / PLANET_METRES_PER_BLOCK_Y, PLANET_FLOOR) + f32(p.sea_level)
	if elevation > 0 {
		height += hills * p.hill_height * spread
	}
	c.height = height
	if planet_past_the_edge(x, z) {
		c.height = f32(p.sea_level + PLANET_WALL_HEIGHT)
		c.river = 0
		c.rough = 0
		return
	}
	c.river = 0
	c.rough = 0
	if elevation > 0 {
		c.rough = p.overhang * smooth(0.5, 0.9, spread) * smooth(0.35, 0.85, ridge)
	}
}

// planet_block_of: the block column (x, z) at latitude and longitude, degrees
// (the inverse of planet_lat_lon, rounded to the nearest column).
planet_block_of :: proc(lat, lon: f64) -> (x, z: i32) {
	return i32(
		math.round(lon * (PLANET_CIRCUMFERENCE / 2) / 180),
	), i32(math.round(-lat * (PLANET_CIRCUMFERENCE / 4) / 90))
}

// Planet_Place: a named place on Earth, for /goto.
Planet_Place :: struct {
	name:     string,
	lat, lon: f64,
}

// PLANET_PLACES: the named places /goto knows, each a latitude and longitude.
PLANET_PLACES :: [?]Planet_Place {
	{"everest", 27.99, 86.93},
	{"k2", 35.88, 76.51},
	{"sahara", 23.0, 12.0},
	{"amazon", -3.1, -60.0},
	{"nile_delta", 31.0, 31.0},
	{"alps", 46.5, 8.0},
	{"greenland", 72.0, -40.0},
	{"antarctica", -82.0, 0.0},
	{"atacama", -24.5, -70.4},
	{"siberia", 62.0, 105.0},
	{"great_barrier_reef", -18.3, 147.7},
	{"grand_canyon", 36.1, -112.1},
}

// planet_place: the named place called name (lower case).
planet_place :: proc(name: string) -> (place: Planet_Place, ok: bool) {
	for p in PLANET_PLACES {
		if p.name == name {return p, true}
	}
	return {}, false
}

// planet_biome replaces a column's biome with the one its Köppen class gives:
// the sea (frozen where its coldest month is under -1.8 °C), the banks and
// the high mountains stay as the shape made them.
@(private)
planet_biome :: proc(p: ^Params, c: ^Column, x, z: i32, mountainous: f32) {
	sea := f32(p.sea_level)
	k, coldest := planet_climate(x, z)
	switch {
	case c.height < sea - 3 && c.river < 0.5:
		c.biome = .Frozen_Ocean if coldest < -1.8 else .Ocean
	case c.biome == .River || c.biome == .Beach:
	// the shape's coast and banks
	case k == .EF:
		c.biome = .Ice_Sheet
	case mountainous > 0.3 && c.height > sea + 45:
		c.biome = .Mountains
	case:
		c.biome = planet_biome_of(k)
	}
}
