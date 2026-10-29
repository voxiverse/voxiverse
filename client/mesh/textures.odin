package mesh

import "core:math"
import "core:slice"

import "../../common/game"

// Block textures: one layer per Texture_Generator in a texture array, made by
// code (see generate_texture). The registry says which generator each texture
// of each block face uses (game.TEXTURE_GENERATOR_NAMES is this enum, in order).

Texture_Generator :: enum u32 {
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
}

// block_texture: the layer of the client's texture array that b's face f
// uses: its texture's generator (a pack's texture of the same generator is the
// same picture).
block_texture :: proc(reg: ^game.Registry, b: game.Block, f: Face) -> u32 {
	faces := reg.blocks.defs[b].faces // side, top, bottom: texture numbers
	k := 0
	#partial switch f {
	case .Pos_Y:
		k = 1
	case .Neg_Y:
		k = 2
	}
	return reg.textures[faces[k]].layer
}

// texture_layer_pixels fills pixels (TEXTURE_SIZE²) with a layer of the
// texture array: a generator's, or a pack's image (level 0, as the pack made
// it; it is not palette-quantized).
texture_layer_pixels :: proc(reg: ^game.Registry, layer: u32, pixels: []Rgba) {
	if int(layer) < len(game.TEXTURE_GENERATOR_NAMES) {
		generate_texture(Texture_Generator(layer), pixels)
		return
	}
	image := reg.images[int(layer) - len(game.TEXTURE_GENERATOR_NAMES)]
	for p, i in image {pixels[i] = p}
}

// block_average_colour: the average of the opaque pixels of b's face f, one
// colour (grey where there are none).
block_average_colour :: proc(reg: ^game.Registry, b: game.Block, f: Face) -> Rgba {
	pixels: [TEXTURE_SIZE * TEXTURE_SIZE]Rgba
	texture_layer_pixels(reg, block_texture(reg, b, f), pixels[:])
	sum: [3]u32
	n: u32
	for c in pixels {
		if c.a == 0 {continue}
		sum += {u32(c.r), u32(c.g), u32(c.b)}
		n += 1
	}
	if n == 0 {return {128, 128, 128, 255}}
	return {u8(sum.r / n), u8(sum.g / n), u8(sum.b / n), 255}
}

// texture_array makes the bytes of the whole texture array for reg: every
// layer's mips, one layer after another (what render.world_init takes).
texture_array :: proc(reg: ^game.Registry, allocator := context.temp_allocator) -> []u8 {
	pixels := make([dynamic]u8, allocator)
	level := make([]Rgba, TEXTURE_SIZE * TEXTURE_SIZE, context.temp_allocator)
	for layer in 0 ..< game.registry_texture_layers(reg) {
		texture_layer_pixels(reg, u32(layer), level)
		size := TEXTURE_SIZE
		current := level
		for _ in 0 ..< TEXTURE_MIPS {
			append(&pixels, ..slice.to_bytes(current))
			if size == 1 {break}
			next := make([]Rgba, (size / 2) * (size / 2), context.temp_allocator)
			generate_mip(current, size, next)
			current, size = next, size / 2
		}
	}
	return pixels[:]
}

// Generated pixels: TEXTURE_SIZE² RGBA8 (sRGB) per layer, plus mip levels
// down to 1×1 averaged in linear light.

TEXTURE_SIZE :: game.TEXTURE_SIZE
TEXTURE_MIPS :: 5 // 16, 8, 4, 2, 1

Rgba :: [4]u8

// generate_texture fills pixels (TEXTURE_SIZE² values, row by row) for t.
// Deterministic: the same on every machine and every run.
//
// The look is crunchy pixel art: each material has a ramp of five hand-
// picked shades, and noise only chooses among them, so pixels form crisp
// clusters instead of smooth gradients.
generate_texture :: proc(t: Texture_Generator, pixels: []Rgba) {
	assert(len(pixels) == TEXTURE_SIZE * TEXTURE_SIZE)
	seed := u32(t) * 0x9e37_79b9
	for y in 0 ..< TEXTURE_SIZE {
		for x in 0 ..< TEXTURE_SIZE {
			// Pixel noise and a 4-pixel cell noise, both tiling.
			fine := hash01(seed, x, y)
			coarse := value_noise(seed ~ 0x5bd1_e995, x, y, 4)
			c: Rgba
			switch t {
			case .Stone:
				v := 0.25 + 0.45 * coarse + 0.30 * fine
				if hash01(seed ~ 7, x, y) > 0.92 {v = 0} 	// dark specks
				c = shade(STONE, v)
			case .Dirt:
				c = dirt(seed, x, y, fine, coarse)
			case .Grass_Top:
				c = shade(GRASS, 0.15 + 0.45 * coarse + 0.45 * fine)
			case .Grass_Side:
				// Grass hangs 2-4 pixels over the dirt, with a ragged, shadowed edge.
				edge := 2 + int(hash01(seed ~ 3, x, 0) * 2.99)
				switch {
				case y < edge:
					c = shade(GRASS, 0.2 + 0.4 * coarse + 0.45 * fine)
				case y == edge:
					c = GRASS[0]
				case:
					c = dirt(seed, x, y, fine, coarse)
				}
			case .Sand:
				c = shade(SAND, 0.2 + 0.3 * coarse + 0.55 * fine)
			case .Gravel:
				// Pebbles: cells of one tone each, with dark gaps.
				v := value_noise(seed ~ 11, x, y, 3) * 0.8 + 0.25 * fine
				if hash01(seed ~ 13, x, y) > 0.82 {v = 0}
				c = shade(GRAVEL, v)
			case .Bedrock:
				// Dark, coarse, cracked: obviously the end of the world.
				v := value_noise(seed ~ 17, x, y, 2) * 0.9 + 0.2 * fine
				if hash01(seed ~ 19, x, y) > 0.8 {v = 0}
				c = shade(BEDROCK, v)
			case .Lamp:
				// A framed panel: dark rim, a grid of warm cells, hot centres.
				edge := x == 0 || y == 0 || x == TEXTURE_SIZE - 1 || y == TEXTURE_SIZE - 1
				seam := x % 5 == 0 || y % 5 == 0
				switch {
				case edge:
					c = LAMP[0]
				case seam:
					c = LAMP[1]
				case (x % 5 == 2 || x % 5 == 3) && (y % 5 == 2 || y % 5 == 3):
					c = LAMP[4]
				case:
					c = shade(LAMP, 0.45 + 0.3 * fine)
				}
			case .Water:
				// Ripples: soft horizontal bands; see-through (alpha).
				band := value_noise(seed ~ 23, x + y / 3, y, 4)
				c = shade(WATER, 0.25 + 0.5 * band + 0.25 * fine)
			case .Snow:
				c = shade(SNOW, 0.45 + 0.25 * coarse + 0.3 * fine)
			case .Ice:
				c = shade(ICE, 0.35 + 0.3 * coarse + 0.2 * fine)
				if (x + y) % 7 == 0 && hash01(seed ~ 29, x / 3, y / 3) > 0.5 {c = ICE[4]} 	// cracks
			case .Clay:
				c = shade(CLAY, 0.3 + 0.35 * coarse + 0.3 * fine)
			case .Sandstone_Side:
				// Layers, a darker seam every few rows.
				v := 0.35 + 0.25 * value_noise(seed ~ 31, 0, y, 2) + 0.25 * fine
				if y % 5 == 4 {v = 0.1}
				c = shade(SAND, v)
			case .Sandstone_Top:
				c = shade(SAND, 0.3 + 0.25 * coarse + 0.3 * fine)
				if x == 0 || y == 0 {c = SAND[1]}
			case .Log_Side, .Spruce_Log_Side:
				// Bark: vertical ridges.
				ridge := value_noise(seed ~ 37, x, y / 4, 2)
				ramp := BARK if t == .Log_Side else SPRUCE_BARK
				c = shade(ramp, 0.15 + 0.6 * ridge + 0.3 * fine)
			case .Log_Top:
				// Rings round the middle, bark at the rim.
				dx, dy := f32(x) - 7.5, f32(y) - 7.5
				r := int(math.sqrt(dx * dx + dy * dy))
				c = shade(WOOD, 0.35 + 0.25 * f32(r % 2) + 0.2 * fine)
				if r >= 7 {c = shade(BARK, 0.3 + 0.4 * fine)}
			case .Leaves, .Spruce_Leaves:
				ramp := LEAVES if t == .Leaves else SPRUCE_LEAVES
				c = shade(ramp, 0.1 + 0.55 * coarse + 0.4 * fine)
				if hash01(seed ~ 41, x, y) > 0.78 {c = {}} 	// gaps to see through
			case .Coal_Ore, .Iron_Ore, .Copper_Ore:
				c = shade(STONE, 0.25 + 0.45 * coarse + 0.30 * fine)
				if value_noise(seed ~ 43, x, y, 3) > 0.62 {
					ramp := COAL if t == .Coal_Ore else (IRON if t == .Iron_Ore else COPPER)
					c = shade(ramp, 0.2 + 0.7 * fine)
				}
			case .Tall_Grass:
				// Blades of different heights from the bottom edge.
				height := int(6 + hash01(seed ~ 47, x, 0) * 10)
				c = {}
				if hash01(seed ~ 53, x, 0) > 0.2 && y >= TEXTURE_SIZE - height {
					// Darker at the root, lighter towards the tip.
					c = shade(
						GRASS,
						0.15 + 0.7 * f32(TEXTURE_SIZE - y) / f32(height) + 0.15 * fine,
					)
				}
			case .Poppy, .Dandelion:
				c = flower(t, x, y, fine)
			case .Cactus_Side:
				// Ribs with pale spines.
				c = shade(CACTUS, 0.25 + 0.3 * f32(x % 4 == 1 ? 1 : 0) + 0.25 * fine)
				if x % 4 == 3 && y % 4 == 1 {c = SAND[4]}
				if x == 0 || x == TEXTURE_SIZE - 1 {c = CACTUS[0]}
			case .Cobblestone:
				// Rounded stones of their own tones, dark mortar between.
				cell := value_noise(seed ~ 59, x, y, 4)
				v := 0.25 + 0.6 * hash01(seed ~ 61, int(cell * 7), 0) + 0.2 * fine
				if cell > 0.45 && cell < 0.52 {v = 0}
				c = shade(STONE, v)
			case .Stone_Bricks:
				// Courses of four rows, the joints staggered course to course.
				course := y / 4
				offset := 4 if course % 2 == 1 else 0
				brick := (x + offset) / 8
				v := 0.35 + 0.35 * hash01(seed ~ 67, brick, course) + 0.2 * fine
				if y % 4 == 3 || (x + offset) % 8 == 7 {v = 0.05}
				c = shade(STONE, v)
			case .Planks:
				// Boards four rows wide, end joints here and there.
				board := y / 4
				v :=
					0.35 +
					0.3 * hash01(seed ~ 71, 0, board) +
					0.25 * value_noise(seed ~ 73, x, y, 2) +
					0.1 * fine
				if y % 4 == 3 {v = 0.05}
				if x == int(hash01(seed ~ 79, board, 1) * 15) {v = 0.1}
				c = shade(WOOD, v)
			case .Glass:
				// A pale frame and two streaks; clear between.
				edge := x == 0 || y == 0 || x == TEXTURE_SIZE - 1 || y == TEXTURE_SIZE - 1
				streak := (x + y == 9 || x + y == 10) && x > 2 && x < 9
				c = {}
				if edge {c = ICE[3]}
				if streak {c = ICE[4]}
			case .Gate_Ring:
				// Dark metal plates, grooves between, a few engraved strokes.
				seam := x % 8 == 0 || y % 8 == 0
				v := 0.3 + 0.3 * coarse + 0.2 * fine
				if seam {v = 0}
				if hash01(seed ~ 29, x / 2, y) > 0.93 {v = 1}
				c = shade(GATE, v)
			case .Gate_Chevron, .Gate_Chevron_Lit:
				// A V on the ring's metal: dim, or glowing.
				ramp := CHEVRON_LIT if t == .Gate_Chevron_Lit else CHEVRON
				dx := abs(x - TEXTURE_SIZE / 2)
				in_v := y >= 3 + dx / 2 && y <= 6 + dx / 2 && dx < 7
				c = shade(ramp, 0.5 + 0.4 * fine) if in_v else shade(GATE, 0.2 + 0.3 * coarse)
			case .Gate_Horizon:
				// Rippling blue light; see-through.
				ripple := value_noise(seed ~ 31, x + y / 2, y + x / 3, 3)
				c = shade(HORIZON, 0.3 + 0.5 * ripple + 0.2 * fine)
			case .Farmland_Top, .Farmland_Moist_Top:
				// Furrows: rows of tilled earth, darker where it is wet.
				ramp := FARMLAND_WET if t == .Farmland_Moist_Top else FARMLAND
				v := 0.45 + 0.25 * coarse + 0.2 * fine
				if y % 4 == 0 {v -= 0.3}
				if y % 4 == 1 {v += 0.1}
				c = shade(ramp, clamp(v, 0, 1))
			case .Wheat_0, .Wheat_1, .Wheat_2, .Wheat_3, .Wheat_4, .Wheat_5, .Wheat_6, .Wheat_7:
				c = wheat_pixel(int(t) - int(Texture_Generator.Wheat_0), seed, x, y)
			case .Chest_Side, .Chest_Top:
				// Boards, banded with iron at the rim; the side has a latch.
				board := y / 4
				v := 0.3 + 0.25 * hash01(seed ~ 83, 0, board) + 0.2 * fine
				if y % 4 == 3 {v = 0.05}
				c = shade(WOOD, v)
				rim := x < 2 || x >= TEXTURE_SIZE - 2 || y < 2 || y >= TEXTURE_SIZE - 2
				latch := t == .Chest_Side && abs(x - TEXTURE_SIZE / 2) < 2 && y >= 5 && y < 9
				if rim || latch {c = shade(IRON, 0.3 + 0.4 * fine)}
			case .Wool_Black:
				v := 0.45 + 0.3 * coarse + 0.25 * fine
				if y % 4 == 3 {v -= 0.2}
				if (x + (y / 4) * 2) % 4 == 3 {v -= 0.12}
				c = shade(WOOL_BLACK, clamp(v, 0, 1))
			case .Wool:
				// Woven: soft cream tufts in rows, a thread's shadow between.
				v := 0.45 + 0.3 * coarse + 0.25 * fine
				if y % 4 == 3 {v -= 0.2}
				if (x + (y / 4) * 2) % 4 == 3 {v -= 0.12}
				c = shade(WOOL, clamp(v, 0, 1))
			case .Ladder:
				// Two rails and four rungs; clear between.
				rail := (x >= 2 && x <= 3) || (x >= 12 && x <= 13)
				rung := x >= 4 && x <= 11 && (y % 4 == 1 || y % 4 == 2)
				c = {}
				if rail ||
				   rung {c = shade(WOOD, 0.3 + 0.35 * hash01(seed ~ 89, x / 2, y / 2) + 0.2 * fine)}
			case .Door_Lower, .Door_Upper:
				// Planks in a frame; the upper half has a window.
				board := x / 4
				v := 0.3 + 0.25 * hash01(seed ~ 97, board, 0) + 0.2 * fine
				if x % 4 == 3 {v = 0.05}
				c = shade(WOOD, v)
				frame := x < 2 || x >= TEXTURE_SIZE - 2 || y < 2 || y >= TEXTURE_SIZE - 2
				if frame {c = shade(WOOD, 0.1 + 0.2 * fine)}
				if t == .Door_Upper && x >= 4 && x < 12 && y >= 4 && y < 11 {
					c = shade(WINDOW, 0.4 + 0.4 * coarse)
				}
				knob := t == .Door_Lower && x >= 11 && x < 13 && y >= 7 && y < 9
				if knob {c = shade(IRON, 0.5 + 0.4 * fine)}
			case .Cactus_Top:
				c = shade(CACTUS, 0.35 + 0.25 * coarse + 0.25 * fine)
				if x == 0 ||
				   y == 0 ||
				   x == TEXTURE_SIZE - 1 ||
				   y == TEXTURE_SIZE - 1 {c = CACTUS[0]}
			}
			pixels[y * TEXTURE_SIZE + x] = c
		}
	}
}

// Ramps, darkest first (sRGB).
@(private = "file", rodata)
STONE := [5]Rgba {
	{74, 76, 84, 255},
	{101, 103, 110, 255},
	{124, 126, 132, 255},
	{146, 148, 153, 255},
	{170, 171, 176, 255},
}
@(private = "file", rodata)
DIRT := [5]Rgba {
	{74, 50, 34, 255},
	{99, 68, 45, 255},
	{121, 85, 57, 255},
	{143, 103, 70, 255},
	{166, 124, 86, 255},
}
@(private = "file", rodata)
GRASS := [5]Rgba {
	{52, 92, 38, 255},
	{68, 117, 45, 255},
	{86, 140, 52, 255},
	{104, 160, 60, 255},
	{128, 182, 74, 255},
}
@(private = "file", rodata)
SAND := [5]Rgba {
	{196, 172, 120, 255},
	{212, 190, 138, 255},
	{224, 204, 152, 255},
	{234, 217, 167, 255},
	{244, 230, 186, 255},
}
@(private = "file", rodata)
GRAVEL := [5]Rgba {
	{70, 66, 64, 255},
	{104, 99, 95, 255},
	{128, 122, 116, 255},
	{150, 144, 136, 255},
	{176, 170, 160, 255},
}

@(private = "file", rodata)
BEDROCK := [5]Rgba {
	{22, 22, 26, 255},
	{40, 40, 46, 255},
	{58, 58, 64, 255},
	{80, 80, 86, 255},
	{104, 104, 110, 255},
}

@(private = "file", rodata)
LAMP := [5]Rgba {
	{58, 44, 30, 255},
	{150, 104, 52, 255},
	{232, 176, 92, 255},
	{250, 214, 140, 255},
	{255, 246, 214, 255},
}

@(private = "file", rodata)
WATER := [5]Rgba {
	{28, 62, 128, 170},
	{36, 78, 150, 170},
	{46, 96, 170, 170},
	{62, 116, 188, 170},
	{96, 148, 210, 170},
}
@(private = "file", rodata)
SNOW := [5]Rgba {
	{196, 206, 220, 255},
	{214, 222, 234, 255},
	{228, 234, 242, 255},
	{238, 242, 248, 255},
	{250, 252, 255, 255},
}
@(private = "file", rodata)
GATE := [5]Rgba {
	{22, 24, 30, 255},
	{40, 43, 52, 255},
	{58, 62, 72, 255},
	{78, 82, 94, 255},
	{120, 126, 140, 255},
}
@(private = "file", rodata)
CHEVRON := [5]Rgba {
	{60, 30, 18, 255},
	{84, 42, 22, 255},
	{104, 54, 26, 255},
	{126, 66, 30, 255},
	{150, 80, 36, 255},
}
@(private = "file", rodata)
CHEVRON_LIT := [5]Rgba {
	{220, 110, 30, 255},
	{240, 140, 40, 255},
	{255, 170, 60, 255},
	{255, 200, 100, 255},
	{255, 230, 170, 255},
}
@(private = "file", rodata)
HORIZON := [5]Rgba {
	{40, 90, 200, 150},
	{60, 120, 230, 150},
	{90, 150, 245, 160},
	{140, 190, 255, 170},
	{210, 235, 255, 180},
}
@(private = "file", rodata)
ICE := [5]Rgba {
	{120, 160, 206, 255},
	{140, 178, 220, 255},
	{160, 194, 232, 255},
	{182, 210, 240, 255},
	{214, 232, 250, 255},
}
@(private = "file", rodata)
CLAY := [5]Rgba {
	{120, 124, 138, 255},
	{136, 140, 154, 255},
	{150, 154, 168, 255},
	{164, 168, 180, 255},
	{180, 184, 194, 255},
}
@(private = "file", rodata)
BARK := [5]Rgba {
	{52, 38, 24, 255},
	{72, 54, 34, 255},
	{92, 70, 44, 255},
	{110, 86, 56, 255},
	{130, 104, 70, 255},
}
@(private = "file", rodata)
SPRUCE_BARK := [5]Rgba {
	{38, 26, 18, 255},
	{54, 38, 26, 255},
	{70, 50, 34, 255},
	{86, 62, 42, 255},
	{102, 76, 52, 255},
}
@(private = "file", rodata)
WOOD := [5]Rgba {
	{120, 92, 54, 255},
	{148, 116, 70, 255},
	{170, 136, 86, 255},
	{190, 156, 102, 255},
	{208, 176, 120, 255},
}
@(private = "file", rodata)
LEAVES := [5]Rgba {
	{34, 74, 28, 255},
	{46, 94, 34, 255},
	{60, 114, 40, 255},
	{76, 134, 48, 255},
	{98, 154, 60, 255},
}
@(private = "file", rodata)
SPRUCE_LEAVES := [5]Rgba {
	{22, 50, 38, 255},
	{30, 64, 48, 255},
	{40, 80, 58, 255},
	{52, 96, 68, 255},
	{68, 112, 80, 255},
}
@(private = "file", rodata)
COAL := [5]Rgba {
	{16, 16, 18, 255},
	{28, 28, 32, 255},
	{40, 40, 44, 255},
	{54, 54, 58, 255},
	{70, 70, 74, 255},
}
@(private = "file", rodata)
WINDOW := [5]Rgba {
	{52, 78, 104, 255},
	{70, 102, 132, 255},
	{92, 128, 160, 255},
	{118, 154, 184, 255},
	{150, 184, 210, 255},
}
@(private = "file", rodata)
IRON := [5]Rgba {
	{150, 110, 88, 255},
	{176, 134, 108, 255},
	{198, 156, 128, 255},
	{216, 178, 150, 255},
	{232, 200, 174, 255},
}
@(private = "file", rodata)
COPPER := [5]Rgba {
	{150, 80, 40, 255},
	{182, 102, 52, 255},
	{206, 124, 64, 255},
	{96, 160, 120, 255}, // a little verdigris
	{230, 150, 86, 255},
}
@(private = "file", rodata)
WOOL := [5]Rgba {
	{176, 170, 160, 255},
	{200, 195, 186, 255},
	{220, 216, 208, 255},
	{236, 233, 226, 255},
	{248, 246, 240, 255},
}
@(private = "file", rodata)
WOOL_BLACK := [5]Rgba {
	{14, 14, 18, 255},
	{26, 26, 32, 255},
	{40, 40, 48, 255},
	{56, 56, 66, 255},
	{74, 74, 86, 255},
}
@(private = "file", rodata)
FARMLAND := [5]Rgba {
	{58, 38, 26, 255},
	{78, 52, 34, 255},
	{96, 64, 42, 255},
	{114, 78, 52, 255},
	{134, 94, 62, 255},
}
@(private = "file", rodata)
FARMLAND_WET := [5]Rgba {
	{36, 24, 18, 255},
	{50, 33, 24, 255},
	{62, 42, 30, 255},
	{76, 52, 36, 255},
	{90, 62, 44, 255},
}
@(private = "file", rodata)
WHEAT_GREEN := [5]Rgba {
	{40, 96, 36, 255},
	{56, 124, 44, 255},
	{78, 150, 52, 255},
	{104, 172, 62, 255},
	{132, 192, 76, 255},
}
@(private = "file", rodata)
WHEAT_GOLD := [5]Rgba {
	{150, 110, 40, 255},
	{184, 140, 52, 255},
	{208, 166, 64, 255},
	{226, 188, 84, 255},
	{240, 208, 112, 255},
}
@(private = "file", rodata)
CACTUS := [5]Rgba {
	{30, 84, 40, 255},
	{40, 104, 48, 255},
	{52, 124, 58, 255},
	{66, 142, 68, 255},
	{86, 162, 82, 255},
}

// flower: a stem with leaves, and a head (poppy red, dandelion yellow) on
// a transparent background.
@(private = "file")
flower :: proc(t: Texture_Generator, x, y: int, fine: f32) -> Rgba {
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

// shade picks the ramp entry for v in 0..1.
@(private = "file")
shade :: proc(ramp: [5]Rgba, v: f32) -> Rgba {
	return ramp[clamp(int(v * 5), 0, 4)]
}

// generate_mip halves src (size² pixels) into dst ((size/2)² pixels),
// averaging in linear light so distant surfaces keep their brightness.
generate_mip :: proc(src: []Rgba, size: int, dst: []Rgba) {
	half := size / 2
	assert(len(src) == size * size && len(dst) == half * half)
	for y in 0 ..< half {
		for x in 0 ..< half {
			sum: [4]f32
			for d in ([4][2]int{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
				p := src[(2 * y + d[1]) * size + 2 * x + d[0]]
				sum += {
					srgb_to_linear(p.r),
					srgb_to_linear(p.g),
					srgb_to_linear(p.b),
					f32(p.a) / 255,
				}
			}
			sum /= 4
			dst[y * half + x] = {
				linear_to_srgb(sum.r),
				linear_to_srgb(sum.g),
				linear_to_srgb(sum.b),
				u8(sum.a * 255 + 0.5),
			}
		}
	}
}

@(private = "file")
dirt :: proc(seed: u32, x, y: int, fine, coarse: f32) -> Rgba {
	v := 0.2 + 0.4 * coarse + 0.4 * fine
	if hash01(seed ~ 5, x, y) > 0.9 {v = 1} 	// small stones
	return shade(DIRT, v)
}

// hash01 is a well-mixed hash of (seed, x, y) in 0..1.
@(private = "file")
hash01 :: proc(seed: u32, x, y: int) -> f32 {
	h := seed ~ u32(x) * 0x27d4_eb2d ~ u32(y) * 0x1656_67b1
	h = (h ~ h >> 15) * 0x85eb_ca6b
	h = (h ~ h >> 13) * 0xc2b2_ae35
	h ~= h >> 16
	return f32(h >> 8) / f32(1 << 24)
}

// value_noise interpolates hash01 on a grid of cell pixels, wrapping at the
// texture size so the texture tiles.
@(private = "file")
value_noise :: proc(seed: u32, x, y, cell: int) -> f32 {
	cells := TEXTURE_SIZE / cell
	gx, gy := x / cell, y / cell
	fx, fy := f32(x % cell) / f32(cell), f32(y % cell) / f32(cell)
	at :: proc(seed: u32, gx, gy, cells: int) -> f32 {
		return hash01(seed, gx % cells, gy % cells)
	}
	a := at(seed, gx, gy, cells) * (1 - fx) + at(seed, gx + 1, gy, cells) * fx
	b := at(seed, gx, gy + 1, cells) * (1 - fx) + at(seed, gx + 1, gy + 1, cells) * fx
	return a * (1 - fy) + b * fy
}

@(private = "file")
to_u8 :: proc(v: f32) -> u8 {
	return u8(clamp(v, 0, 1) * 255 + 0.5)
}

@(private = "file")
srgb_to_linear :: proc(c: u8) -> f32 {
	v := f32(c) / 255
	return v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)
}

@(private = "file")
linear_to_srgb :: proc(v: f32) -> u8 {
	s := v * 12.92 if v <= 0.0031308 else 1.055 * math.pow(v, 1 / 2.4) - 0.055
	return to_u8(s)
}

// wheat_pixel: stage 0..7 of wheat on a crossed plane: rows of stalks that
// grow taller (2 pixels of sprout, up to 14), turn from green to gold, and
// carry a head of grain at the end.
@(private = "file")
wheat_pixel :: proc(stage: int, seed: u32, x, y: int) -> (c: Rgba) {
	height := 2 + stage * 12 / 7 // pixels tall
	if y < TEXTURE_SIZE - height {return}
	// Stalks stand every other column, a column of grain beside some.
	stalk := x % 4 == 1 || (x % 4 == 3 && stage >= 3)
	if !stalk {return}
	top := TEXTURE_SIZE - height
	ripeness := f32(stage) / 7
	fine := hash01(seed, x, y)
	if stage >= 4 && y < top + 3 + int(stage) / 3 && (x % 4 == 3 || y > top) {
		// The head of grain: gold once ripe.
		return(
			shade(WHEAT_GOLD, 0.3 + 0.5 * ripeness + 0.2 * fine) if stage >= 6 else shade(WHEAT_GREEN, 0.5 + 0.3 * fine) \
		)
	}
	if stage == 7 {return shade(WHEAT_GOLD, 0.2 + 0.4 * fine)}
	if stage >=
	   5 {return shade(WHEAT_GREEN, 0.3 + 0.3 * ripeness) if fine < 0.5 else shade(WHEAT_GOLD, 0.2 + 0.3 * fine)}
	return shade(WHEAT_GREEN, 0.25 + 0.5 * f32(y - top) / f32(max(height, 1)) + 0.2 * fine)
}
