package worldgen

import "base:runtime"
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
	c.river = 0
	c.rough = 0
	if elevation > 0 {
		c.rough = p.overhang * smooth(0.5, 0.9, spread) * smooth(0.35, 0.85, ridge)
	}
}
