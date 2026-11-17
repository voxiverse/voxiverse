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
	// Wood.
	case .Oak_Panel:
		return panel_of(OAK, seed, x, y), true
	case .Birch_Log:
		return bark_of(BIRCH, seed, x, y), true
	case .Birch_Log_End:
		return rings_of(BIRCH, seed, x, y), true
	case .Birch_Planks:
		return planks_of(BIRCH, seed, x, y), true
	case .Birch_Panel:
		return panel_of(BIRCH, seed, x, y), true
	case .Spruce_Log_End:
		return rings_of(SPRUCE, seed, x, y), true
	case .Spruce_Planks:
		return planks_of(SPRUCE, seed, x, y), true
	case .Spruce_Panel:
		return panel_of(SPRUCE, seed, x, y), true
	case .Redwood_Log:
		return bark_of(REDWOOD, seed, x, y), true
	case .Redwood_Log_End:
		return rings_of(REDWOOD, seed, x, y), true
	case .Redwood_Planks:
		return planks_of(REDWOOD, seed, x, y), true
	case .Redwood_Panel:
		return panel_of(REDWOOD, seed, x, y), true
	case .Weathered_Log:
		return bark_of(WEATHERED, seed, x, y), true
	case .Weathered_Log_End:
		return rings_of(WEATHERED, seed, x, y), true
	case .Weathered_Planks:
		return planks_of(WEATHERED, seed, x, y), true
	case .Weathered_Panel:
		return panel_of(WEATHERED, seed, x, y), true
	// Metal.
	case .Iron_Plate:
		return plate(STEEL, seed, x, y, .Quarters), true
	case .Riveted_Iron:
		return plate(STEEL, seed, x, y, .Riveted), true
	case .Iron_Grating:
		return grating(STEEL, x, y), true
	case .Rusted_Iron:
		return rusted(seed, x, y), true
	case .Dark_Steel:
		return plate(DARK_STEEL, seed, x, y, .Halves), true
	case .Copper:
		return plate(COPPER, seed, x, y, .Quarters), true
	case .Verdigris_Copper:
		return verdigris(seed, x, y), true
	case .Brass:
		return brass(seed, x, y), true
	case .Hazard_Stripes:
		return hazard(seed, x, y), true
	case .Pipes:
		return pipes(seed, x, y), true
	// Built and industrial.
	case .Concrete:
		return concrete(seed, x, y), true
	case .Stained_Concrete:
		return stained(seed, x, y), true
	case .Concrete_Tiles:
		return slabs(seed, x, y), true
	case .Asphalt:
		return asphalt(seed, x, y), true
	case .Red_Bricks:
		return bricks(RED_BRICK_ROCK, seed, x, y, 8, 4), true
	case .Painted_Red:
		return painted(PAINT_RED, seed, x, y), true
	case .Painted_Blue:
		return painted(PAINT_BLUE, seed, x, y), true
	case .Painted_Yellow:
		return painted(PAINT_YELLOW, seed, x, y), true
	case .Painted_White:
		return painted(PAINT_WHITE, seed, x, y), true
	case .Tinted_Glass:
		return tinted(x, y), true
	case .Screen:
		return screen(seed, x, y), true
	case .Vent:
		return vent(x, y), true
	case .Conveyor_Top:
		return conveyor_top(seed, x, y), true
	case .Conveyor_Side:
		return conveyor_side(seed, x, y), true
	// Soft and domestic.
	case .Thatch:
		return thatch(seed, x, y), true
	case .White_Plaster:
		return plaster(WHITE_PLASTER, seed, x, y), true
	case .Cream_Plaster:
		return plaster(CREAM_PLASTER, seed, x, y), true
	case .Ochre_Plaster:
		return plaster(OCHRE_PLASTER, seed, x, y), true
	case .Clay_Roof:
		return roof(CLAY_TILE, seed, x, y, round = true), true
	case .Slate_Roof:
		return roof(SLATE, seed, x, y, round = false), true
	case .Red_Wool:
		return woven(WOOL_RED, seed, x, y), true
	case .Blue_Wool:
		return woven(WOOL_BLUE, seed, x, y), true
	case .Green_Wool:
		return woven(WOOL_GREEN, seed, x, y), true
	case .Yellow_Wool:
		return woven(WOOL_YELLOW, seed, x, y), true
	case .Carpet:
		return carpet(seed, x, y), true
	case .Bookshelf:
		return bookshelf(seed, x, y), true
	// Natural.
	case .Mud:
		return mud(seed, x, y), true
	case .Dry_Earth:
		return dry_earth(seed, x, y), true
	case .Dry_Grass_Top:
		return turf(DRY_GRASS, seed, x, y), true
	case .Dry_Grass_Side:
		return turf_side(DRY_GRASS, seed, x, y), true
	case .Snowy_Grass_Side:
		return snow_side(seed, x, y), true
	case .Red_Sand:
		return dunes(RED_SAND, seed, x, y), true
	case .Moss:
		return moss(seed, x, y), true
	case .Birch_Leaves:
		return foliage(BIRCH_LEAVES, seed, x, y), true
	case .Autumn_Leaves:
		return foliage(AUTUMN_LEAVES, seed, x, y), true
	case .Packed_Ice:
		return ice_of(PACKED_ICE, seed, x, y, 3), true
	// Fantasy and dungeon.
	case .Dark_Bricks:
		return bricks(DUNGEON_ROCK, seed, x, y, 8, 4), true
	case .Mossy_Bricks:
		return mossy_bricks(seed, x, y), true
	case .Rune_Stone:
		return rune_stone(seed, x, y), true
	case .Bone:
		return bone(seed, x, y), true
	case .Crystal:
		return crystal(seed, x, y), true
	case .Magma:
		return magma(seed, x, y), true
	case .Obsidian:
		return obsidian(seed, x, y), true
	}
	return {}, false
}

// step: the ramp's colour at step s, held to its five.
@(private)
step :: proc(ramp: Ramp, s: int) -> Rgba {
	return ramp[clamp(s, 0, 4)]
}
