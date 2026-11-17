package texture

// The material kit's textures (game.MATERIALS names them): each family in its own file,
// kit_<family>.odin, from patterns that take the material (a rock, a wood, a metal) and
// draw its form: courses, boards, plates, cracks, grain, with two or three steps of light
// from the top left and sparse detail. kit_pixel says which pattern draws which generator.

// kit_pixel: the pixel of a kit generator (false: g is not the kit's).
kit_pixel :: proc(g: Generator, seed: u32, x, y: int) -> (Rgba, bool) {
	#partial switch g {
	case .Stone_Tiles:
		return tiles(STONE_ROCK, seed, x, y), true
	case .Polished_Stone:
		return polished(STONE_ROCK, seed, x, y), true
	case .Basalt:
		return rough(BASALT_ROCK, seed, x, y), true
	case .Basalt_Cobble:
		return cobble_of(BASALT_ROCK, seed, x, y), true
	case .Basalt_Bricks:
		return bricks(BASALT_ROCK, seed, x, y, 8, 8), true
	case .Basalt_Tiles:
		return tiles(BASALT_ROCK, seed, x, y), true
	case .Polished_Basalt:
		return polished(BASALT_ROCK, seed, x, y), true
	case .Sandstone_Cobble:
		return cobble_of(SANDSTONE_ROCK, seed, x, y), true
	case .Sandstone_Bricks:
		return bricks(SANDSTONE_ROCK, seed, x, y, 16, 8), true
	case .Sandstone_Tiles:
		return tiles(SANDSTONE_ROCK, seed, x, y), true
	case .Polished_Sandstone:
		return polished(SANDSTONE_ROCK, seed, x, y), true
	case .Limestone:
		return rough(LIMESTONE_ROCK, seed, x, y), true
	case .Limestone_Cobble:
		return cobble_of(LIMESTONE_ROCK, seed, x, y), true
	case .Limestone_Bricks:
		return bricks(LIMESTONE_ROCK, seed, x, y, 8, 4), true
	case .Limestone_Tiles:
		return tiles(LIMESTONE_ROCK, seed, x, y), true
	case .Polished_Limestone:
		return polished(LIMESTONE_ROCK, seed, x, y), true
	case .Slate:
		return rough(SLATE_ROCK, seed, x, y), true
	case .Slate_Cobble:
		return cobble_of(SLATE_ROCK, seed, x, y), true
	case .Slate_Bricks:
		return bricks(SLATE_ROCK, seed, x, y, 16, 4), true
	case .Slate_Tiles:
		return tiles(SLATE_ROCK, seed, x, y), true
	case .Polished_Slate:
		return polished(SLATE_ROCK, seed, x, y), true
	}
	return {}, false
}

// step: the ramp's colour at step s, held to its five.
@(private)
step :: proc(ramp: Ramp, s: int) -> Rgba {
	return ramp[clamp(s, 0, 4)]
}
