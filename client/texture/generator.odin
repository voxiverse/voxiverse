package texture

// The block textures drawn by code: one generator per texture, each a pure
// procedure of the pixel. They run at build time (tools/atlas makes the
// atlas the client carries); the registry names them (game.
// TEXTURE_GENERATOR_NAMES is this enum, in order, in lower case) and a
// generator's number is its layer of the client's texture array.

Generator :: enum u32 {
	Stone,
	Dirt,
	Grass_Top,
	Grass_Side,
	Sand,
	Gravel,
	Bedrock,
	Lamp,
	Water,
	Snow,
	Ice,
	Clay,
	Sandstone_Side,
	Sandstone_Top,
	Log_Side,
	Log_Top,
	Leaves,
	Spruce_Log_Side,
	Spruce_Leaves,
	Coal_Ore,
	Iron_Ore,
	Copper_Ore,
	Tall_Grass,
	Poppy,
	Dandelion,
	Cactus_Side,
	Cactus_Top,
	Cobblestone,
	Stone_Bricks,
	Planks,
	Glass,
	Gate_Ring,
	Gate_Chevron,
	Gate_Chevron_Lit,
	Gate_Horizon,
	Wool,
	Farmland_Top,
	Farmland_Moist_Top,
	Wheat_0,
	Wheat_1,
	Wheat_2,
	Wheat_3,
	Wheat_4,
	Wheat_5,
	Wheat_6,
	Wheat_7,
	Wool_Black,
	Chest_Side,
	Chest_Top,
	Ladder,
	Door_Lower,
	Door_Upper,
	// The material kit's (game.MATERIALS), by family: kit_*.odin.
	Stone_Tiles,
	Polished_Stone,
	Basalt,
	Basalt_Cobble,
	Basalt_Bricks,
	Basalt_Tiles,
	Polished_Basalt,
	Sandstone_Cobble,
	Sandstone_Bricks,
	Sandstone_Tiles,
	Polished_Sandstone,
	Limestone,
	Limestone_Cobble,
	Limestone_Bricks,
	Limestone_Tiles,
	Polished_Limestone,
	Slate,
	Slate_Cobble,
	Slate_Bricks,
	Slate_Tiles,
	Polished_Slate,
	Oak_Panel,
	Birch_Log,
	Birch_Log_End,
	Birch_Planks,
	Birch_Panel,
	Spruce_Log_End,
	Spruce_Planks,
	Spruce_Panel,
	Redwood_Log,
	Redwood_Log_End,
	Redwood_Planks,
	Redwood_Panel,
	Weathered_Log,
	Weathered_Log_End,
	Weathered_Planks,
	Weathered_Panel,
}

// generate fills pixels (SIZE² values, row by row) for t.
// Deterministic: the same on every machine and every run.
//
// Each material is a ramp of five hand-picked shades (ramp.odin) and the
// toolkit (toolkit.odin) only says how light a pixel is, so pixels form
// crisp clusters of a few tones. The materials with form, the rock, soil,
// wood and masonry, are drawn in material.odin; the kit's, in kit_*.odin.
generate :: proc(t: Generator, pixels: []Rgba) {
	assert(len(pixels) == SIZE * SIZE)
	seed := u32(t) * 0x9e37_79b9
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			pixels[y * SIZE + x] = pixel(t, seed, x, y)
		}
	}
}

// seed_of: g's seed; an ore stands in the rock of stone's, so the two meet
// without a seam.
seed_of :: proc(g: Generator) -> u32 {
	return u32(g) * 0x9e37_79b9
}

@(private = "file")
pixel :: proc(t: Generator, seed: u32, x, y: int) -> Rgba {
	if c, ok := kit_pixel(t, seed, x, y); ok {return c}
	// Pixel grit and a 4 x 4 noise, both tiling.
	fine := hash01(seed, x, y)
	coarse := noise(seed ~ 0x5bd1_e995, x, y, 4, 4)
	#partial switch t {
	case .Stone:
		return rock(STONE, seed, x, y)
	case .Clay:
		return clay(seed, x, y)
	case .Gravel:
		return gravel(seed, x, y)
	case .Bedrock:
		return bedrock(seed, x, y)
	case .Cobblestone:
		return cobble(seed, x, y)
	case .Stone_Bricks:
		return stone_brick(seed, x, y)
	case .Coal_Ore:
		c, _ := ore(COAL, seed, x, y, 4, 1.8, 0.4)
		return c
	case .Iron_Ore:
		c, _ := ore(IRON_ORE, seed, x, y, 4, 1.4, 0.35)
		return c
	case .Copper_Ore:
		c, inside := ore(COPPER, seed, x, y, 4, 1.5, 0.4)
		if inside && hash01(seed ~ 7, x, y) > 0.8 {return VERDIGRIS}
		return c
	case .Dirt:
		return dirt(seed, x, y)
	case .Grass_Top:
		return grass(seed, x, y)
	case .Grass_Side:
		// Grass hangs 2-4 pixels over the dirt, a blade further here and
		// there, with a shadow under it.
		edge := 2 + int(hash01(seed ~ 3, x, 0) * 2.99)
		if hash01(seed ~ 4, x, 0) > 0.8 {edge += 2}
		switch {
		case y < edge:
			return grass(seed, x, y)
		case y == edge:
			return GRASS[0]
		case y == edge + 1:
			return DIRT[0] if fine > 0.5 else DIRT[1]
		}
		return dirt(seed, x, y)
	case .Farmland_Top, .Farmland_Moist_Top:
		// Furrows: rows of tilled earth, lit on their tops, darker where wet.
		ramp := FARMLAND_WET if t == .Farmland_Moist_Top else FARMLAND
		v := 0.4 + 0.25 * coarse + 0.2 * (fine - 0.5)
		if y % 4 == 0 {v -= 0.3}
		if y % 4 == 1 {v += 0.2}
		return dither(ramp, v, x, y)
	case .Sand:
		return sand(seed, x, y)
	case .Sandstone_Side:
		return sandstone_side(seed, x, y)
	case .Sandstone_Top:
		// A cut face: smooth, its edges catching the light at the top left.
		v := 0.45 + 0.25 * fbm(seed, x, y, 2, 3) + 0.15 * (fine - 0.5)
		v += 0.22 * bevel(x, y, SIZE, SIZE)
		return dither(SANDSTONE, v, x, y)
	case .Snow:
		// Soft drifts, blue in their hollows, a glint here and there.
		v := 0.3 + 0.6 * fbm(seed, x, y, 2, 3)
		if fine > 0.97 {return SNOW[4]}
		return dither(SNOW, v, x, y)
	case .Ice:
		// Clear blue, cloudy patches, long white fracture lines here and there.
		crack := wrap(x - 2 * y) == 3 || wrap(2 * x + y) == 11
		if crack && noise(seed ~ 30, x, y, 4, 4) > 0.5 {return ICE[4]}
		return dither(ICE, 0.2 + 0.55 * fbm(seed, x, y, 2, 3), x, y)
	case .Water:
		// Ripples: soft horizontal bands; see-through (alpha).
		band := noise(seed ~ 23, x + y / 3, y, 4, 4)
		return pick(WATER, 0.25 + 0.5 * band + 0.25 * fine)
	case .Lamp:
		// A framed panel: dark rim, a grid of warm cells, hot centres.
		edge := x == 0 || y == 0 || x == SIZE - 1 || y == SIZE - 1
		seam := x % 5 == 0 || y % 5 == 0
		switch {
		case edge:
			return LAMP[0]
		case seam:
			return LAMP[1]
		case (x % 5 == 2 || x % 5 == 3) && (y % 5 == 2 || y % 5 == 3):
			return LAMP[4]
		}
		return pick(LAMP, 0.45 + 0.3 * fine)
	case .Log_Side:
		return bark(BARK, seed, x, y, 6, 3)
	case .Spruce_Log_Side:
		// Spruce: darker, finer furrows broken into scales.
		c := bark(SPRUCE_BARK, seed, x, y, 8, 5)
		if wrap(y + int(hash01(seed ~ 5, x / 2, 0) * 16)) % 5 == 0 && fine > 0.3 {
			return SPRUCE_BARK[0]
		}
		return c
	case .Log_Top:
		return rings(seed, x, y)
	case .Planks:
		return plank(seed, x, y)
	case .Leaves, .Spruce_Leaves:
		ramp := LEAVES if t == .Leaves else SPRUCE_LEAVES
		if hash01(seed ~ 41, x, y) > 0.78 {return {}} 	// gaps to see through
		return pick(ramp, 0.1 + 0.55 * coarse + 0.4 * fine)
	case .Tall_Grass:
		// Blades of different heights from the bottom edge.
		height := int(6 + hash01(seed ~ 47, x, 0) * 10)
		if hash01(seed ~ 53, x, 0) > 0.2 && y >= SIZE - height {
			// Darker at the root, lighter towards the tip.
			return pick(GRASS, 0.15 + 0.7 * f32(SIZE - y) / f32(height) + 0.15 * fine)
		}
		return {}
	case .Poppy, .Dandelion:
		return flower(t, x, y, fine)
	case .Cactus_Side:
		// Ribs with pale spines.
		if x == 0 || x == SIZE - 1 {return CACTUS[0]}
		if x % 4 == 3 && y % 4 == 1 {return SAND[4]}
		return pick(CACTUS, 0.25 + 0.3 * f32(x % 4 == 1 ? 1 : 0) + 0.25 * fine)
	case .Cactus_Top:
		if x == 0 || y == 0 || x == SIZE - 1 || y == SIZE - 1 {return CACTUS[0]}
		return pick(CACTUS, 0.35 + 0.25 * coarse + 0.25 * fine)
	case .Wheat_0, .Wheat_1, .Wheat_2, .Wheat_3, .Wheat_4, .Wheat_5, .Wheat_6, .Wheat_7:
		return wheat_pixel(int(t) - int(Generator.Wheat_0), seed, x, y)
	case .Glass:
		// A pale frame and two streaks; clear between.
		if x == 0 || y == 0 || x == SIZE - 1 || y == SIZE - 1 {return ICE[3]}
		if (x + y == 9 || x + y == 10) && x > 2 && x < 9 {return ICE[4]}
		return {}
	case .Gate_Ring:
		// Dark metal plates, grooves between, a few engraved strokes.
		if hash01(seed ~ 29, x / 2, y) > 0.93 {return GATE[4]}
		if x % 8 == 0 || y % 8 == 0 {return GATE[0]}
		return pick(GATE, 0.3 + 0.3 * coarse + 0.2 * fine)
	case .Gate_Chevron, .Gate_Chevron_Lit:
		// A V on the ring's metal: dim, or glowing.
		ramp := CHEVRON_LIT if t == .Gate_Chevron_Lit else CHEVRON
		dx := abs(x - SIZE / 2)
		in_v := y >= 3 + dx / 2 && y <= 6 + dx / 2 && dx < 7
		return pick(ramp, 0.5 + 0.4 * fine) if in_v else pick(GATE, 0.2 + 0.3 * coarse)
	case .Gate_Horizon:
		// Rippling blue light; see-through.
		ripple := noise(seed ~ 31, x + y / 2, y + x / 3, 5, 5)
		return pick(HORIZON, 0.3 + 0.5 * ripple + 0.2 * fine)
	case .Chest_Side, .Chest_Top:
		// Boards, banded with iron at the rim; the side has a latch.
		rim := x < 2 || x >= SIZE - 2 || y < 2 || y >= SIZE - 2
		latch := t == .Chest_Side && abs(x - SIZE / 2) < 2 && y >= 5 && y < 9
		if rim || latch {return pick(IRON, 0.3 + 0.4 * fine)}
		if y % 4 == 3 {return WOOD[0]}
		return pick(WOOD, 0.45 + 0.4 * (grain(seed, x, y) - 0.5) + 0.12 * bevel(x, y % 4, SIZE, 3))
	case .Wool, .Wool_Black:
		// Woven: soft tufts in rows, a thread's shadow between.
		ramp := WOOL_BLACK if t == .Wool_Black else WOOL
		v := 0.45 + 0.3 * coarse + 0.25 * fine
		if y % 4 == 3 {v -= 0.2}
		if (x + (y / 4) * 2) % 4 == 3 {v -= 0.12}
		return pick(ramp, clamp(v, 0, 1))
	case .Ladder:
		// Two rails and four rungs; clear between.
		rail := (x >= 2 && x <= 3) || (x >= 12 && x <= 13)
		rung := x >= 4 && x <= 11 && (y % 4 == 1 || y % 4 == 2)
		if !rail && !rung {return {}}
		lit: f32 = 0.15 if x == 2 || x == 12 || (rung && y % 4 == 1) else 0
		return pick(WOOD, 0.3 + 0.35 * hash01(seed ~ 89, x / 2, y / 2) + 0.15 * fine + lit)
	case .Door_Lower, .Door_Upper:
		// Planks in a frame; the upper half has a window.
		frame := x < 2 || x >= SIZE - 2 || y < 2 || y >= SIZE - 2
		if frame {return pick(WOOD, 0.1 + 0.2 * fine + (0.2 if x == 0 || y == 0 else 0))}
		if t == .Door_Upper && x >= 4 && x < 12 && y >= 4 && y < 11 {
			return pick(WINDOW, 0.4 + 0.4 * coarse)
		}
		if t == .Door_Lower && x >= 11 && x < 13 && y >= 7 && y < 9 {
			return pick(IRON, 0.5 + 0.4 * fine) // the knob
		}
		if x % 4 == 3 {return WOOD[0]}
		return pick(WOOD, 0.45 + 0.4 * (grain(seed, y, x) - 0.5) + 0.1 * bevel(x % 4, y, 3, SIZE))
	}
	return {}
}

// flower: a stem with leaves, and a head (poppy red, dandelion yellow) on
// a transparent background.
@(private = "file")
flower :: proc(t: Generator, x, y: int, fine: f32) -> Rgba {
	head: [3]Rgba = {{150, 24, 24, 255}, {204, 40, 36, 255}, {236, 70, 56, 255}}
	if t == .Dandelion {head = {{196, 150, 20, 255}, {236, 196, 36, 255}, {252, 228, 90, 255}}}
	dx, dy := f32(x) - 7.5, f32(y) - 5.5
	r := dx * dx + dy * dy
	switch {
	case r < 1.5 && t == .Poppy:
		return {30, 24, 20, 255} // the poppy's dark eye
	case r < 9:
		return head[clamp(int(fine * 3), 0, 2)]
	case (x == 7 || x == 8) && y > 8:
		return GRASS[1] // the stem
	case y == 12 && (x == 6 || x == 9), y == 11 && (x == 5 || x == 10):
		return GRASS[2] // two leaves
	}
	return {}
}

// wheat_pixel: stage 0..7 of wheat on a crossed plane: rows of stalks that
// grow taller (2 pixels of sprout, up to 14), turn from green to gold, and
// carry a head of grain at the end.
@(private = "file")
wheat_pixel :: proc(stage: int, seed: u32, x, y: int) -> (c: Rgba) {
	height := 2 + stage * 12 / 7 // pixels tall
	if y < SIZE - height {return}
	// Stalks stand every other column, a column of grain beside some.
	stalk := x % 4 == 1 || (x % 4 == 3 && stage >= 3)
	if !stalk {return}
	top := SIZE - height
	ripeness := f32(stage) / 7
	fine := hash01(seed, x, y)
	if stage >= 4 && y < top + 3 + int(stage) / 3 && (x % 4 == 3 || y > top) {
		// The head of grain: gold once ripe.
		if stage >= 6 {return pick(WHEAT_GOLD, 0.3 + 0.5 * ripeness + 0.2 * fine)}
		return pick(WHEAT_GREEN, 0.5 + 0.3 * fine)
	}
	if stage == 7 {return pick(WHEAT_GOLD, 0.2 + 0.4 * fine)}
	if stage >= 5 {
		if fine < 0.5 {return pick(WHEAT_GREEN, 0.3 + 0.3 * ripeness)}
		return pick(WHEAT_GOLD, 0.2 + 0.3 * fine)
	}
	return pick(WHEAT_GREEN, 0.25 + 0.5 * f32(y - top) / f32(max(height, 1)) + 0.2 * fine)
}
