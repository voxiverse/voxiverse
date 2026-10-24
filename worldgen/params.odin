package worldgen

import "../base"

// The Earth generator's parameters as variables (worldgen.*): set from the
// console or F4 (the server's: a cheat, like rules), saved with the world.
// Chunks already made keep their blocks until `regen`.

@(rodata)
PARAMS_VARS := [?]base.Var {
	{field = "sea_level", help = "the sea's surface, y", min = -64, max = 64},
	{
		field = "warmth",
		help = "added to the climate's temperature (-1 cold .. 1 hot)",
		min = -1.5,
		max = 1.5,
		step = 0.1,
	},
	{
		field = "wetness",
		help = "added to the climate's humidity",
		min = -1.5,
		max = 1.5,
		step = 0.1,
	},
	{
		field = "palette",
		help = "the surface's blocks: 0 Earth, 1 ash, 2 frost, 3 clay, 4 dunes",
		min = 0,
		max = 4,
		step = 1,
	},
	{
		field = "biome_blend",
		help = "how wide the mixed band between biomes is, blocks each side (0: hard edges)",
		min = 0,
		max = 32,
		step = 1,
	},
	{
		field = "continent_scale",
		help = "size of continents and oceans, blocks",
		min = 200,
		max = 20000,
		step = 100,
	},
	{
		field = "climate_scale",
		help = "size of warm, cold, wet and dry regions, blocks",
		min = 200,
		max = 20000,
		step = 100,
	},
	{
		field = "mountain_height",
		help = "the highest ridges above the plains, blocks",
		min = 0,
		max = 200,
		step = 5,
	},
	{field = "hill_height", help = "hills on the plains, blocks", min = 0, max = 60, step = 1},
	{
		field = "ocean_depth",
		help = "the ocean floor below the sea, blocks",
		min = 4,
		max = 120,
		step = 2,
	},
	{
		field = "overhang",
		help = "how far cliffs lean out in the mountains, blocks",
		min = 0,
		max = 40,
		step = 1,
	},
	{
		field = "river_width",
		help = "how much land rivers take, 0..0.2",
		min = 0,
		max = 0.2,
		step = 0.005,
	},
	{field = "cave_size", help = "how wide caves are, 0..0.3", min = 0, max = 0.3, step = 0.01},
	{field = "tree_density", help = "trees: 1 as designed, 0 none", min = 0, max = 4, step = 0.1},
	{
		field = "plant_density",
		help = "grass and flowers: 1 as designed, 0 none",
		min = 0,
		max = 4,
		step = 0.1,
	},
}

params_table :: proc() -> base.Var_Table {
	return {"worldgen.", Params, PARAMS_VARS[:], &PARAMS_DEFAULTS}
}
