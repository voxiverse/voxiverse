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
