package texture

// The world classes' textures (common/worldgen/classes.odin): a canyon's red rock, a
// volcano's ash, a moon's dust, a fungal world's ground, fungi and sprouts, and each
// class's rare resource. Drawn as the rest are: ramps of five shades from what the real
// thing (or its nearest kin in nature) looks like, the toolkit saying how light a pixel is.

@(private, rodata)
RED_ROCK := Ramp {
	{92, 38, 26, 255},
	{122, 52, 34, 255},
	{150, 70, 44, 255},
	{176, 92, 58, 255},
	{202, 122, 82, 255},
}
@(private, rodata)
ASH := Ramp {
	{30, 29, 30, 255},
	{44, 42, 42, 255},
	{58, 55, 54, 255},
	{74, 70, 67, 255},
	{96, 90, 85, 255},
}
@(private, rodata)
REGOLITH := Ramp {
	{96, 96, 98, 255},
	{120, 120, 121, 255},
	{142, 141, 140, 255},
	{163, 162, 159, 255},
	{186, 184, 180, 255},
}
@(private, rodata)
MYCELIUM := Ramp {
	{66, 48, 82, 255},
	{90, 66, 108, 255},
	{114, 88, 132, 255},
	{140, 112, 152, 255},
	{170, 146, 178, 255},
}
@(private, rodata)
STEM := Ramp {
	{146, 136, 116, 255},
	{174, 164, 142, 255},
	{198, 190, 168, 255},
	{218, 212, 192, 255},
	{236, 232, 214, 255},
}
@(private, rodata)
CAP := Ramp {
	{26, 70, 82, 255},
	{34, 94, 106, 255},
	{46, 118, 126, 255},
	{64, 142, 144, 255},
	{96, 170, 164, 255},
}
@(private, rodata)
GLOW := Ramp {
	{96, 122, 40, 255},
	{136, 170, 52, 255},
	{178, 206, 74, 255},
	{214, 234, 112, 255},
	{242, 252, 172, 255},
}
@(private, rodata)
AMBER := Ramp {
	{118, 62, 10, 255},
	{168, 94, 20, 255},
	{208, 132, 34, 255},
	{236, 170, 62, 255},
	{252, 208, 122, 255},
}
@(private, rodata)
OPAL := Ramp {
	{150, 160, 172, 255},
	{182, 192, 202, 255},
	{208, 216, 224, 255},
	{226, 232, 238, 255},
	{244, 246, 250, 255},
}
@(private, rodata)
CRYOLITE := Ramp {
	{146, 172, 192, 255},
	{176, 200, 216, 255},
	{202, 222, 234, 255},
	{222, 238, 246, 255},
	{242, 250, 254, 255},
}
@(private, rodata)
SULFUR := Ramp {
	{146, 126, 18, 255},
	{194, 172, 28, 255},
	{224, 204, 50, 255},
	{242, 226, 94, 255},
	{252, 244, 160, 255},
}
@(private, rodata)
ILMENITE := Ramp {
	{18, 18, 22, 255},
	{34, 34, 40, 255},
	{54, 54, 62, 255},
	{88, 88, 98, 255},
	{140, 140, 152, 255},
}
@(private, rodata)
JADE := Ramp {
	{22, 76, 50, 255},
	{32, 102, 68, 255},
	{48, 128, 86, 255},
	{76, 154, 108, 255},
	{118, 182, 138, 255},
}
@(private, rodata)
NACRE := Ramp {
	{170, 164, 178, 255},
	{196, 190, 202, 255},
	{216, 212, 222, 255},
	{232, 230, 238, 255},
	{248, 246, 252, 255},
}

// (Not rodata: a Rock is made from the ramps, which are variables.)
@(private)
RED_ROCK_ROCK := Rock{RED_ROCK, {70, 30, 22, 255}, .Bedded}

// worlds_pixel: the pixel of a world class's generator (false: g is not one).
@(private)
worlds_pixel :: proc(g: Generator, seed: u32, x, y: int) -> (Rgba, bool) {
	fine := hash01(seed, x, y)
	#partial switch g {
	case .Red_Rock:
		// A canyon wall's rock: sandstone's beds, rust red.
		return rough(RED_ROCK_ROCK, seed, x, y), true
	case .Ash:
		// Fine dark powder in soft drifts, a pale fleck of pumice here and there.
		if fine > 0.985 {return ASH[4], true}
		return step(ASH, 1 + int(fbm(seed, x, y, 3, 2) > 0.58)), true
	case .Regolith:
		// Grey dust, fine and even, pitted by small craters: a dark rim lit on its
		// lower right, where the light falls in.
		c := cells(seed, x, y, 5)
		if hash01(c.id, 4, 0) < 0.2 && c.d1 < 1.7 {
			return step(REGOLITH, 3 if c.dx + c.dy > 0.3 else 1), true
		}
		return step(REGOLITH, 2 + int(fbm(seed ~ 1, x, y, 2, 2) > 0.55)), true
	case .Mycelium_Top:
		return mycelium(seed, x, y), true
	case .Mycelium_Side:
		// The fuzz hanging over the earth, threads further down here and there.
		edge := 3 + int(noise(seed ~ 3, x, 0, 6, 1) > 0.5)
		if hash01(seed ~ 4, x, 0) > 0.8 {edge += 2}
		v := wrap(y)
		switch {
		case v < edge - 1:
			return mycelium(seed, x, y), true
		case v == edge - 1:
			return MYCELIUM[1], true
		case v == edge:
			return DIRT[1], true
		}
		return dirt(seed_of(.Dirt), x, y), true
	case .Fungus_Stem:
		// Pale fibres running up the stem, a darker one here and there.
		s := 2 + int(noise(seed, x, y, 8, 2) > 0.6)
		if hash01(seed ~ 1, x, 0) > 0.85 {s = 1}
		return step(STEM, s), true
	case .Fungus_Cap:
		return cap_of(CAP, STEM, seed, x, y), true
	case .Glow_Cap:
		return cap_of(GLOW, GLOW, seed, x, y), true
	case .Spore_Sprout:
		return sprout(seed, x, y), true
	case .Amber_Ore:
		c, _ := ore_in(STONE_ROCK, .Stone, AMBER, seed, x, y, 4, 1.7, 0.4)
		return c, true
	case .Opal_Ore:
		c, inside := ore_in(RED_ROCK_ROCK, .Red_Rock, OPAL, seed, x, y, 4, 1.5, 0.35)
		if inside && hash01(seed ~ 5, x, y) > 0.7 {
			// The play of colour: a fleck of another hue.
			FIRE := [4]Rgba {
				{236, 120, 116, 255},
				{116, 214, 160, 255},
				{120, 166, 238, 255},
				{236, 214, 116, 255},
			}
			return FIRE[int(hash01(seed ~ 6, x, y) * 3.99)], true
		}
		return c, true
	case .Cryolite_Ore:
		c, _ := ore_in(SLATE_ROCK, .Slate, CRYOLITE, seed, x, y, 4, 1.8, 0.4)
		return c, true
	case .Sulfur_Ore:
		c, _ := ore_in(BASALT_ROCK, .Basalt, SULFUR, seed, x, y, 4, 1.6, 0.45)
		return c, true
	case .Ilmenite_Ore:
		c, inside := ore_in(STONE_ROCK, .Stone, ILMENITE, seed, x, y, 4, 1.5, 0.45)
		if inside && hash01(seed ~ 5, x, y) > 0.85 {return ILMENITE[4], true} 	// a metallic glint
		return c, true
	case .Jade_Ore:
		c, _ := ore_in(STONE_ROCK, .Stone, JADE, seed, x, y, 4, 1.9, 0.35)
		return c, true
	case .Nacre:
		// Mother-of-pearl: curved growth lines, pale, each band with a faint tint of
		// its own (rose, green, blue) as the light catches it.
		dx, dy := f32(x) + 4, f32(y) + 12
		band := int((dx * dx + dy * dy) / 40 + 2 * noise(seed, x, y, 4, 4))
		TINTS := [3][3]i32{{10, -6, 4}, {-6, 8, 0}, {-4, 2, 12}}
		c := step(NACRE, 2 + int(band % 3 == 1))
		if band % 4 == 0 {c = NACRE[1]}
		t := TINTS[band % 3]
		return {
				u8(clamp(i32(c.r) + t[0], 0, 255)),
				u8(clamp(i32(c.g) + t[1], 0, 255)),
				u8(clamp(i32(c.b) + t[2], 0, 255)),
				255,
			},
			true
	}
	return {}, false
}

// mycelium: a mat of fine threads, violet, in tufts lit at their tips, a pale strand here
// and there.
@(private = "file")
mycelium :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 4)
	s := 2 + int(fbm(seed ~ 2, x, y, 2, 2) > 0.55)
	if c.d2 - c.d1 < 0.6 {s = 1}
	if c.d1 < 0.8 && hash01(c.id, 5, 0) > 0.7 {s = 4} 	// a pale strand's knot
	return step(MYCELIUM, s)
}

// cap_of: a fungus's cap: its colour in broad soft patches, lit at the top, and round
// pale spots, each with a darker rim.
@(private = "file")
cap_of :: proc(ramp, spots: Ramp, seed: u32, x, y: int) -> Rgba {
	c := cells(seed ~ 7, x, y, 4)
	if hash01(c.id, 1, 0) < 0.45 {
		if c.d1 < 1.2 {return spots[4] if c.dx + c.dy < 0 else spots[3]}
		if c.d1 < 1.7 {return ramp[0]}
	}
	return step(ramp, 2 + int(fbm(seed, x, y, 2, 2) > 0.5))
}

// sprout: a few thin violet stalks from the bottom edge, each with a round pale head.
@(private = "file")
sprout :: proc(seed: u32, x, y: int) -> Rgba {
	STALKS :: [4]int{2, 6, 9, 13}
	for sx, i in STALKS {
		height := 6 + int(hash01(seed ~ 9, i, 0) * 8)
		head := SIZE - height
		dx, dy := f32(x - sx), f32(y - head)
		if dx * dx + dy * dy < 3 {
			return step(CAP, 4 if dx + dy < 0 else 2)
		}
		if x == sx && y > head {return step(MYCELIUM, 1 + int(y > SIZE - 4))}
	}
	return {}
}
