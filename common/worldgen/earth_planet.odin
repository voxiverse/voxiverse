package worldgen

import "base:runtime"
import "core:math"
import "core:sync"

import "common:base"
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
shared_rivers: planet.Rivers
@(private = "file")
model_once: sync.Once
// model_builds counts how many times the model was made (decoded or built): once per process.
model_builds: int

// model_load: Earth's climate grid and rivers, decoded from assets/planet/earth_climate.bin
// (written by `build planet climate`, a test keeps it fresh). A file that does not match the
// relief falls back to building the model: seconds, not milliseconds.
@(private = "file")
model_load :: proc() {
	sync.once_do(&model_once, proc() {
		sync.atomic_add(&model_builds, 1)
		r, _ := planet_relief()
		p, rv, ok := planet.climate_decode(
			#load("../../assets/planet/earth_climate.bin"),
			r,
			runtime.heap_allocator(),
		)
		if !ok {
			p = planet.planet_build(r, runtime.heap_allocator())
			rv = planet.rivers_build(p.land, p.precip, runtime.heap_allocator())
		}
		shared_model, shared_rivers = p, rv
	})
}

// planet_model: Earth's climate grid, for the process (any thread), loaded on first use.
planet_model :: proc() -> planet.Planet {
	model_load()
	return shared_model
}

// planet_rivers: the relief's rivers, for the process (any thread), loaded on first use.
planet_rivers :: proc() -> planet.Rivers {
	model_load()
	return shared_rivers
}

// PLANET_BANK: blocks of bank on each side of a river, rising to the land.
PLANET_BANK :: 4
// PLANET_LAKE_BANK: the lake share (0 to 1) where a lake's bank begins to rise.
PLANET_LAKE_BANK :: 0.2

// planet_river_near: the nearest river to block (x, z) as the distance from its
// centre line, its width there and the point on the line nearest to (x, z).
// Rivers run as straight reaches between the centres of the climate cells,
// bent a little by noise.
planet_river_near :: proc(x, z: f64) -> (dist, width: f32, nearest: [2]f64, found: bool) {
	rv := planet_rivers()
	w, h := rv.width, rv.height
	cell := f64(PLANET_CIRCUMFERENCE) / f64(w)
	at := [2]f64{x, z}
	at += {f64(fbm2(0x52a1, at / 90, 2)), f64(fbm2(0x52a2, at / 90, 2))} * 24
	ci := int(math.floor((at.x + PLANET_CIRCUMFERENCE / 2) / cell))
	cj := int(math.floor((at.y + PLANET_CIRCUMFERENCE / 4) / cell))
	best := max(f32)
	for dj in -1 ..= 1 {
		j := cj + dj
		if j < 0 || j >= h {continue}
		for di in -1 ..= 1 {
			i := (ci + di + w) % w
			k := j * w + i
			nx := int(rv.next[k])
			if nx < 0 || planet.river_width(rv.flow[k]) == 0 {continue}
			ni, nj := nx % w, nx / w
			ddi := ((ni - i + w + w / 2) % w) - w / 2 // longitude wraps
			a := [2]f64 {
				(f64(ci + di) + 0.5) * cell - PLANET_CIRCUMFERENCE / 2,
				(f64(j) + 0.5) * cell - PLANET_CIRCUMFERENCE / 4,
			}
			b := a + [2]f64{f64(ddi), f64(nj - j)} * cell
			ab := b - a
			t := clamp(linalg_dot(at - a, ab) / linalg_dot(ab, ab), 0, 1)
			p := a + ab * t
			d := f32(math.sqrt(linalg_dot(at - p, at - p)))
			f := rv.flow[k]
			if rv.flow[nx] > f {f = rv.flow[k] + (rv.flow[nx] - rv.flow[k]) * f32(t)}
			wd := planet.river_width(f)
			if d - wd / 2 < best {
				best, dist, width, nearest, found = d - wd / 2, d, wd, p, true
			}
		}
	}
	return
}

@(private = "file")
linalg_dot :: proc(a, b: [2]f64) -> f64 {
	return a.x * b.x + a.y * b.y
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
	case .Af, .Am:
		return .Rainforest
	case .Aw:
		return .Savanna
	case .Cfa, .Cwa, .Cwb, .Cwc:
		return .Subtropical_Forest
	case .Cfb, .Cfc:
		return .Forest // temperate forest
	case .Csa, .Csb, .Csc:
		return .Mediterranean
	case .BSh, .BSk:
		return .Steppe
	case .BWh:
		return .Desert
	case .BWk:
		return .Cold_Desert
	case .Dsa, .Dsb, .Dwa, .Dwb, .Dfa, .Dfb:
		return .Mixed_Forest
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
// noise's detail (hills, overhangs) scaled by the local ruggedness, and the
// relief's rivers and lakes cut into it.
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
		planet_carve_lake(p, c, x, z)
		if c.river < 0.5 {planet_carve_river(p, c, x, z)}
	}
}

// planet_lake_at: how much of block (x, z) is lake, 0 to 1, from the lake mask
// of the four climate cells around it (interpolated, so the shore has no steps),
// and the filled level (metres) of the lake cell that weighs most.
planet_lake_at :: proc(x, z: i32) -> (share, level: f32) {
	rv := planet_rivers()
	w, h := rv.width, rv.height
	cell := f64(PLANET_CIRCUMFERENCE) / f64(w)
	fx := (f64(x) + PLANET_CIRCUMFERENCE / 2) / cell - 0.5
	fz := (f64(z) + PLANET_CIRCUMFERENCE / 4) / cell - 0.5
	i0, j0 := int(math.floor(fx)), int(math.floor(fz))
	tx, tz := f32(fx - f64(i0)), f32(fz - f64(j0))
	best: f32
	for dj in 0 ..= 1 {
		j := clamp(j0 + dj, 0, h - 1)
		wz := tz if dj == 1 else 1 - tz
		for di in 0 ..= 1 {
			k := j * w + (i0 + di + w) % w
			if !rv.lake[k] {continue}
			wt := wz * (tx if di == 1 else 1 - tx)
			share += wt
			if wt > best {best, level = wt, rv.filled[k]}
		}
	}
	return
}

// planet_carve_lake sinks a lake's bed under water that stands at the lake's
// spill level (its filled level), with banks rising to the land at its edge.
@(private = "file")
planet_carve_lake :: proc(p: ^Params, c: ^Column, x, z: i32) {
	share, level := planet_lake_at(x, z)
	if share <= PLANET_LAKE_BANK {return}
	sea := f32(p.sea_level)
	surface := math.floor(level / PLANET_METRES_PER_BLOCK_Y) + sea
	c.rough = 0
	if share < 0.5 {
		if c.height > surface {
			c.height = mix(surface, c.height, smooth(PLANET_LAKE_BANK, 0.5, share))
		}
		return
	}
	c.height = surface - 0.5 - 3 * smooth(0.5, 0.9, share)
	c.river = 1
	c.lift = i32(surface - sea)
}

// planet_carve_river cuts the relief's river through a land column: a bed
// under water that stands at the river's own level, banks rising to the land.
@(private = "file")
planet_carve_river :: proc(p: ^Params, c: ^Column, x, z: i32) {
	d, width, near, ok := planet_river_near(f64(x), f64(z))
	if !ok {return}
	half := width / 2
	bank := half + PLANET_BANK
	if d >= bank {return}
	lat, lon := planet_lat_lon(i32(math.round(near.x)), i32(math.round(near.y)))
	r, _ := planet_relief()
	level := planet.planet_relief_at(planet.Planet{relief = r}, lat, lon)
	sea := f32(p.sea_level)
	surface := max(math.floor(level / PLANET_METRES_PER_BLOCK_Y + sea) - 1, sea)
	c.rough = 0
	if d >= half {
		if c.height > surface {c.height = mix(surface, c.height, smooth(half, bank, d))}
		return
	}
	across := d / half
	c.height = surface - 0.5 - 3 * (1 - across * across)
	c.river = 1
	c.lift = i32(surface - sea)
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
	case c.river > 0.5:
		c.biome = .River
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

// planet_spawn_pick: where a universe begins on Earth, chosen by its seed:
// habitable land between 55 degrees south and 62 north (not sea, ice, desert,
// tundra, bare mountains, a beach or a river), so players of different
// universes begin in different places. The Earth itself is the same in all.
planet_spawn_pick :: proc(p: ^Params, terrain_seed: i64, universe_seed: u64) -> (lat, lon: f32) {
	r := base.rng_make(universe_seed ~ 0x5a17_0b5e_7a27_c0de)
	for _ in 0 ..< 400 {
		la := base.rng_f32_range(&r, -55, 62)
		lo := base.rng_f32_range(&r, -180, 180)
		x, z := planet_block_of(f64(la), f64(lo))
		c := column_at(p, terrain_seed, x, z)
		if c.rough > 0 || c.height < f32(p.sea_level) + 3 {continue}
		#partial switch c.biome {
		case .Ocean,
		     .Frozen_Ocean,
		     .Beach,
		     .River,
		     .Desert,
		     .Cold_Desert,
		     .Ice_Sheet,
		     .Tundra,
		     .Mountains:
			continue
		}
		return la, lo
	}
	return p.spawn_lat, p.spawn_lon
}
