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
	Iron_Plate,
	Riveted_Iron,
	Iron_Grating,
	Rusted_Iron,
	Dark_Steel,
	Copper,
	Verdigris_Copper,
	Brass,
	Hazard_Stripes,
	Pipes,
	Concrete,
	Stained_Concrete,
	Concrete_Tiles,
	Asphalt,
	Red_Bricks,
	Painted_Red,
	Painted_Blue,
	Painted_Yellow,
	Painted_White,
	Tinted_Glass,
	Screen,
	Vent,
	Conveyor_Top,
	Conveyor_Side,
	Thatch,
	White_Plaster,
	Cream_Plaster,
	Ochre_Plaster,
	Clay_Roof,
	Slate_Roof,
	Red_Wool,
	Blue_Wool,
	Green_Wool,
	Yellow_Wool,
	Carpet,
	Bookshelf,
	Mud,
	Dry_Earth,
	Dry_Grass_Top,
	Dry_Grass_Side,
	Snowy_Grass_Side,
	Red_Sand,
	Moss,
	Birch_Leaves,
	Autumn_Leaves,
	Packed_Ice,
	Dark_Bricks,
	Mossy_Bricks,
	Rune_Stone,
	Bone,
	Crystal,
	Magma,
	Obsidian,
	// The world classes' (worlds.odin).
	Red_Rock,
	Ash,
	Regolith,
	Mycelium_Top,
	Mycelium_Side,
	Fungus_Stem,
	Fungus_Cap,
	Glow_Cap,
	Spore_Sprout,
	Amber_Ore,
	Opal_Ore,
	Cryolite_Ore,
	Sulfur_Ore,
	Ilmenite_Ore,
	Jade_Ore,
	Nacre,
}

// generate fills pixels (SIZE² values, row by row) for t.
// Deterministic: the same on every machine and every run.
//
// Each material is a ramp of five hand-picked shades (ramp.odin) and the
// toolkit (toolkit.odin) only says how light a pixel is, so pixels form
// crisp clusters of a few tones. The materials with form, the rock, soil,
// wood and masonry, are drawn in material.odin; the kit's, in kit_*.odin.
//
// The style rule, from the gate's slab (the reference: plain, calm, read at
// once). Every texture follows it:
//
//   - Few tones: the body is two neighbouring steps of the ramp, in broad
//     soft patches (noise of two to four points across, never per pixel); a
//     third step lights edges, a fourth shades grooves. The ends of the ramp
//     are for structure and for sparse accents only.
//   - Low contrast between neighbours: next to each other, pixels differ by
//     one step; a jump of two only where the structure is (a joint, a gap).
//   - Features of three pixels and more; one clear structure per material
//     (dirt a few soft clods, stone a few cracks that run and stop, grass
//     short blades over two greens, bark furrows up the trunk).
//   - Structure drawn with light, not outlined: a lit edge on the top left,
//     a step of shade at the foot or in the groove, never a dark line drawn
//     all round a piece.
//   - Almost no per-pixel variation: a fleck here and there at most (a pixel
//     unlike all eight round it is grit: test_textures_have_no_speckle).
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
	if c, ok := worlds_pixel(t, seed, x, y); ok {return c}
	// Pixel grit and a 4 x 4 noise, both tiling.
	fine := hash01(seed, x, y)
	coarse := noise(seed ~ 0x5bd1_e995, x, y, 4, 4)
	#partial switch t {
	case .Stone:
		return rough(STONE_ROCK, seed, x, y)
	case .Clay:
		return clay(seed, x, y)
	case .Gravel:
		return gravel(seed, x, y)
	case .Bedrock:
		return bedrock(seed, x, y)
	case .Cobblestone:
		return cobble_of(STONE_ROCK, seed, x, y)
	case .Stone_Bricks:
		return bricks(STONE_ROCK, seed, x, y, 8, 4)
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
		return turf(GRASS, seed, x, y)
	case .Grass_Side:
		return turf_side(GRASS, seed, x, y)
	case .Farmland_Top, .Farmland_Moist_Top:
		// Furrows: rows of tilled earth, lit on their tops, darker where wet.
		ramp := FARMLAND_WET if t == .Farmland_Moist_Top else FARMLAND
		s := 2 + int(coarse > 0.6)
		if y % 4 == 0 {s = 1}
		if y % 4 == 1 {s += 1}
		return step(ramp, s)
	case .Sand:
		return dunes(SAND, seed, x, y)
	case .Sandstone_Side:
		return sandstone_side(seed, x, y)
	case .Sandstone_Top:
		// A cut face: a slab, smooth, its edges catching the light at the top left.
		return polished(SANDSTONE_ROCK, seed, x, y)
	case .Snow:
		// Soft drifts in broad patches, blue in their hollows, a glint here and there.
		f := fbm(seed, x, y, 2, 3)
		if fine > 0.97 {return SNOW[4]}
		return step(SNOW, 1 + int(f > 0.4) + int(f > 0.6))
	case .Ice:
		// Clear blue in broad facets, their edges fractured white, a bubble here and there.
		return ice_of(ICE, seed, x, y, 2)
	case .Water:
		// Ripples: soft horizontal bands; see-through (alpha).
		band := noise(seed ~ 23, x + y / 3, y, 4, 4)
		return step(WATER, 1 + int(band > 0.45) + int(band > 0.75))
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
		return bark_of(OAK, seed, x, y)
	case .Spruce_Log_Side:
		return bark_of(SPRUCE, seed, x, y)
	case .Log_Top:
		return rings_of(OAK, seed, x, y)
	case .Planks:
		return planks_of(OAK, seed, x, y)
	case .Leaves:
		return foliage(LEAVES, seed, x, y)
	case .Spruce_Leaves:
		return foliage(SPRUCE_LEAVES, seed, x, y)
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
		return step(CACTUS, 2 + int(x % 4 == 1))
	case .Cactus_Top:
		if x == 0 || y == 0 || x == SIZE - 1 || y == SIZE - 1 {return CACTUS[0]}
		return step(CACTUS, 2 + int(coarse > 0.55))
	case .Wheat_0, .Wheat_1, .Wheat_2, .Wheat_3, .Wheat_4, .Wheat_5, .Wheat_6, .Wheat_7:
		return wheat_pixel(int(t) - int(Generator.Wheat_0), seed, x, y)
	case .Glass:
		// A pale frame and two streaks; clear between.
		if x == 0 || y == 0 || x == SIZE - 1 || y == SIZE - 1 {return ICE[3]}
		if (x + y == 9 || x + y == 10) && x > 2 && x < 9 {return ICE[4]}
		return {}
	case .Gate_Ring, .Gate_Chevron, .Gate_Chevron_Lit:
		// A heavy slab of dark stone: a plain face, its edges bevelled, a faint
		// grain. (The chevrons of the ring gates before, still in a chunk saved
		// with one, are the slab too; the server sets none lit any more.)
		edge := bevel(x, y, SIZE, SIZE)
		if edge > 0 {return GATE[3]}
		if edge < 0 {return GATE[0]}
		return pick(GATE, 0.2 + 0.25 * coarse + 0.1 * fine)
	case .Gate_Horizon:
		// A dark void, a mote here and there: the open surface's stand-in (the
		// translucent pass draws its depth and drifting motes itself, water.frag).
		if hash01(seed ~ 31, x, y) > 0.97 {return HORIZON[4]}
		return pick(HORIZON, 0.3 * fine)
	case .Chest_Side, .Chest_Top:
		// Boards, banded with iron at the rim; the side has a latch.
		rim := x < 2 || x >= SIZE - 2 || y < 2 || y >= SIZE - 2
		latch := t == .Chest_Side && abs(x - SIZE / 2) < 2 && y >= 5 && y < 9
		if rim || latch {return pick(IRON, 0.3 + 0.4 * fine)}
		if y % 4 == 3 {return WOOD[0]}
		return pick(WOOD, 0.45 + 0.4 * (grain(seed, x, y) - 0.5) + 0.12 * bevel(x, y % 4, SIZE, 3))
	case .Wool:
		return woven(WOOL, seed, x, y)
	case .Wool_Black:
		return woven(WOOL_BLACK, seed, x, y)
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
