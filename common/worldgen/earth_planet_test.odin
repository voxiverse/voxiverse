package worldgen

import "core:testing"

import "common:game"

@(private = "file")
block_at :: proc(lat, lon: f64) -> (x, z: i32) {
	return i32(lon * 32768 / 180), i32(-lat * 16384 / 90)
}

@(private = "file")
planet_generator :: proc(seed: i64) -> Generator {
	p := PARAMS_DEFAULTS
	p.planet = 1
	return generator_make(.Earth, seed, test_reg(), p)
}

@(test)
test_planet_height_is_the_relief :: proc(t: ^testing.T) {
	g := planet_generator(1)
	x, z := block_at(27.99, 86.93) // Everest's range
	top := column_top(&g, x, z)
	testing.expectf(t, top > 100, "the Himalaya stand high: %d", top)
	x, z = block_at(0, -150) // the open Pacific
	testing.expect_value(t, column_top(&g, x, z), 0) // the sea's surface
	testing.expect(
		t,
		column_at(&g.params, g.seed, x, z).height < -30,
		"the Pacific floor lies deep",
	)
	x, z = block_at(47, 2) // France: lowland
	top = column_top(&g, x, z)
	testing.expect(t, top > 0 && top < 60, "France is land at low height")
	// The relief's own numbers: Everest's cell is the highest land.
	testing.expect(t, planet_elevation(block_at(27.99, 86.93)) > 4000)
}

@(test)
test_planet_ignores_the_universe_seed_for_height :: proc(t: ^testing.T) {
	// The relief fixes the broad shape; the noise only adds detail to it.
	a, b := planet_generator(1), planet_generator(2)
	x, z := block_at(0, -150)
	testing.expect_value(t, column_top(&a, x, z), column_top(&b, x, z))
}

@(test)
test_planet_off_is_the_noise_world :: proc(t: ^testing.T) {
	a := generator_make(.Earth, 7, test_reg())
	b := a
	b.params.planet = 0
	for x in i32(0) ..< 6 {
		testing.expect_value(t, column_top(&a, x * 91, x * 53), column_top(&b, x * 91, x * 53))
	}
	testing.expect(t, game.WORLD_MAX_Y > 221)
}

@(test)
test_planet_block_of_inverts_lat_lon :: proc(t: ^testing.T) {
	for lat in ([]f64{-60, 0, 43.3, 80}) {
		for lon in ([]f64{-120, 0, 5.4, 150}) {
			x, z := planet_block_of(lat, lon)
			la, lo := planet_lat_lon(x, z)
			testing.expectf(t, abs(la - lat) < 0.01 && abs(lo - lon) < 0.01, "%v %v", la, lo)
		}
	}
}

@(test)
test_planet_places_are_on_the_map :: proc(t: ^testing.T) {
	for p in PLANET_PLACES {
		testing.expectf(t, abs(p.lat) < 90 && abs(p.lon) < 180, "%s is off the map", p.name)
		_, ok := planet_place(p.name)
		testing.expectf(t, ok, "%s not found", p.name)
	}
	e, _ := planet_place("everest")
	testing.expect(t, planet_elevation(planet_block_of(e.lat, e.lon)) > 4000)
}

@(test)
test_planet_world_ends_at_an_ice_wall :: proc(t: ^testing.T) {
	g := planet_generator(1)
	for at in ([][2]i32{{0, -16385}, {0, 16385}, {32769, 0}, {-32769, 100}}) {
		testing.expect(t, planet_past_the_edge(at.x, at.y))
		c := column_at(&g.params, g.seed, at.x, at.y)
		testing.expect_value(t, c.biome, Biome.Ice_Sheet)
		testing.expect_value(t, column_top(&g, at.x, at.y), PLANET_WALL_HEIGHT)
	}
	testing.expect(t, !planet_past_the_edge(32768, -16384))
	testing.expect(t, column_at(&g.params, g.seed, 0, 0).biome != .Ice_Sheet)
}

@(test)
test_planet_biome_follows_koppen :: proc(t: ^testing.T) {
	g := planet_generator(1)
	checked := 0
	for i in i32(0) ..< 1000 {
		h := hash(5, i, 1)
		x := i32(h % 60000) - 30000
		z := i32(hash(5, i, 2) % 30000) - 15000
		c := column_at(&g.params, g.seed, x, z)
		if c.height < 4 || c.river > 0 || c.biome == .Beach || c.biome == .Mountains {continue}
		k, _ := planet_climate(x, z)
		testing.expectf(t, c.biome == planet_biome_of(k), "%d %d: %v is %v", x, z, k, c.biome)
		checked += 1
	}
	testing.expectf(t, checked > 100, "only %d land columns", checked)
	// Greenland's interior is ice, Siberia's forest is taiga.
	for place in ([]struct {
			name:  string,
			biome: Biome,
		}{{"greenland", .Ice_Sheet}, {"siberia", .Taiga}}) {
		pl, _ := planet_place(place.name)
		x, z := planet_block_of(pl.lat, pl.lon)
		testing.expect_value(t, earth_biome(&g, x, z), place.biome)
	}
	// Everest's summit climbs through the zones: mountains or ice, never forest.
	x, z := planet_block_of(27.99, 86.93)
	b := earth_biome(&g, x, z)
	testing.expect(t, b == .Mountains || b == .Ice_Sheet, "Everest's summit is not forest")
	// The open Pacific is sea; the Arctic's is frozen.
	x, z = planet_block_of(0, -150)
	testing.expect_value(t, earth_biome(&g, x, z), Biome.Ocean)
	x, z = planet_block_of(88, 0)
	testing.expect_value(t, earth_biome(&g, x, z), Biome.Frozen_Ocean)
}
