package texture

// Stone and masonry: five rocks, each of its own hue and grain, and what is cut from it:
// its rough face, cobbles, bricks, tiles and a polished slab. A rock's grain is drawn in
// all of them, so its bricks are still that rock.

// Grain: what sets a rock apart besides its colour.
Grain :: enum u8 {
	Speckled, // grey stone: fine dark and pale crystals
	Vesicular, // basalt: small gas holes, lit on their far wall
	Bedded, // sandstone: layers of sand of their own tones
	Fossil, // limestone: soft, pale, a shell's arc here and there
	Laminated, // slate: thin sheets split along their planes
}

// Rock: a stone's ramp, the colour of its mortar (or the grout of its tiles) and its grain.
Rock :: struct {
	ramp:   Ramp,
	mortar: Rgba,
	grain:  Grain,
}

@(private, rodata)
BASALT := Ramp {
	{30, 31, 38, 255},
	{46, 47, 55, 255},
	{62, 63, 70, 255},
	{80, 80, 86, 255},
	{104, 101, 102, 255},
}
@(private, rodata)
LIMESTONE := Ramp {
	{142, 142, 136, 255},
	{170, 168, 156, 255},
	{194, 190, 174, 255},
	{214, 209, 191, 255},
	{233, 228, 209, 255},
}
@(private, rodata)
SLATE := Ramp {
	{44, 50, 61, 255},
	{60, 68, 81, 255},
	{78, 87, 99, 255},
	{98, 106, 117, 255},
	{124, 129, 136, 255},
}

// (Not rodata: a Rock is made from the ramps, which are variables.)
@(private)
STONE_ROCK := Rock{STONE, {62, 63, 70, 255}, .Speckled}
@(private)
BASALT_ROCK := Rock{BASALT, {22, 22, 27, 255}, .Vesicular}
@(private)
SANDSTONE_ROCK := Rock{SANDSTONE, {150, 118, 76, 255}, .Bedded}
@(private)
LIMESTONE_ROCK := Rock{LIMESTONE, {124, 122, 116, 255}, .Fossil}
@(private)
SLATE_ROCK := Rock{SLATE, {32, 36, 44, 255}, .Laminated}

// rough: a rock's natural face. Broken into facets, each a tone of its own, lit at its top
// left and shaded at its foot, so the rims between them read as grooves; the grain on top.
@(private)
rough :: proc(rock: Rock, seed: u32, x, y: int) -> Rgba {
	if rock.grain == .Laminated {return laminae(rock, seed, x, y)}
	if rock.grain == .Vesicular {return columns(rock, seed, x, y)}
	soft := rock.grain == .Fossil // limestone weathers round: its rims are gentler
	c := cells(seed, x, y, 3)
	lean := clamp(-(c.dx + c.dy) / 3, -1, 1) // 1 at a facet's top left, -1 at its foot
	tone := hash01(c.id, 0, 0)
	s := 2
	if tone < 0.3 {s = 1}
	if tone > 0.75 && !soft {s = 3}
	if lean < -0.55 {s -= 1}
	if lean > 0.6 {s += 1}
	if c.d2 - c.d1 < 1.0 {
		// The rim: lit where it faces the light, dark at the foot.
		s = 3 if lean > 0 else (1 if soft else 0)
	}
	return step(rock.ramp, clamp(s + grain_step(rock, seed, x, y), 0, 4))
}

// laminae: slate's face: sheets two to four pixels thick, each its own tone, its top edge
// catching the light and a dark parting under it, split across here and there.
@(private)
laminae :: proc(rock: Rock, seed: u32, x, y: int) -> Rgba {
	// The partings, at fixed rows wavering a pixel with x.
	PARTINGS :: [5]int{0, 3, 6, 10, 13}
	row := wrap(y - int(noise(seed ~ 1, x, 0, 4, 1) * 1.99))
	sheet := 0
	for p, i in PARTINGS {if row >= p {sheet = i}}
	partings := PARTINGS
	top := partings[sheet]
	bottom := partings[(sheet + 1) % 5] if sheet < 4 else SIZE
	if row == bottom - 1 {return rock.ramp[0]}
	s := 1 + int(hash01(seed ~ 2, sheet, 0) * 2.99)
	if row == top {s += 1}
	// A split across the sheet, where its pieces meet: dark, its right side lit.
	split := wrap(int(hash01(seed ~ 3, sheet, 0) * 16))
	if wrap(x) == split {return rock.ramp[0]}
	if wrap(x - 1) == split {s += 1}
	return step(rock.ramp, s + grain_step(rock, seed, x, y))
}

// columns: basalt's face: the columns it cooled into, four pixels across, each a tone of
// its own, its left side lit and its right in shadow, broken across at a fracture (a dark
// line, the edge below it lit), with its small gas holes.
@(private)
columns :: proc(rock: Rock, seed: u32, x, y: int) -> Rgba {
	column := wrap(x) / 4
	u := wrap(x) % 4
	if u == 3 {return rock.ramp[0]} 	// the joint between two columns
	// Two fractures down each column, one in each half, at rows of its own.
	row := wrap(y)
	first := int(hash01(seed ~ 1, column, 0) * 8)
	second := 8 + int(hash01(seed ~ 2, column, 0) * 8)
	for at in ([2]int{first, second}) {
		if row == at {return rock.ramp[0]}
		if row == wrap(at + 1) {return rock.ramp[3]}
	}
	piece := int(row > first && row <= second)
	s := 1 + int(hash01(seed ~ 3, column, piece) * 1.99)
	if u == 0 {s += 1}
	if u == 2 {s -= 1}
	return step(rock.ramp, s + grain_step(rock, seed, x, y))
}

// grain_step: the rock's grain at a pixel, as steps up or down its ramp; sparse, so a
// rock reads by its large shapes first.
@(private)
grain_step :: proc(rock: Rock, seed: u32, x, y: int) -> int {
	h := hash01(seed ~ 0x2c1b_3c6d, x, y)
	switch rock.grain {
	case .Speckled:
		if h > 0.95 {return -1}
		if h < 0.04 {return 1}
	case .Vesicular:
		c := cells(seed ~ 0x51ed_270b, x, y, 5)
		if hash01(c.id, 1, 0) < 0.25 {
			if c.d1 < 0.7 {return -2}
			if c.d1 < 1.5 && c.dx + c.dy > 0.3 {return 1}
		}
	case .Bedded:
		band := wrap(y + int(noise(seed ~ 5, x, 0, 2, 1) * 2.99)) / 2
		if hash01(seed ~ 6, band, 0) > 0.7 {return -1}
		if h > 0.97 {return 1}
	case .Fossil:
		c := cells(seed ~ 0x6a09_e667, x, y, 4)
		if hash01(c.id, 1, 0) < 0.3 && c.d1 > 1.0 && c.d1 < 1.9 && c.dy < 0 {return -1}
		if h > 0.97 {return -1}
	case .Laminated:
		if wrap(y) % 4 == 2 && h > 0.5 {return -1}
	}
	return 0
}

// cobble_of: rounded stones of a rock set in mortar, each a tone of its own, lit at its
// top left, shaded towards its foot, its rim a step lighter or darker by the side.
@(private)
cobble_of :: proc(rock: Rock, seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 3)
	gap := c.d2 - c.d1
	if gap < 1.0 {return rock.mortar}
	lean := clamp(-(c.dx + c.dy) / 3.5, -1, 1)
	tone := hash01(c.id, 0, 0)
	s := 2
	if tone < 0.3 {s = 1}
	if tone > 0.75 {s = 3}
	if lean > 0.55 {s += 1}
	if lean < -0.45 {s -= 1}
	if gap < 1.9 {s += 1 if lean > 0 else -1}
	return step(rock.ramp, clamp(s, 0, 4) + grain_step(rock, seed, x, y) / 2)
}

// bricks: dressed blocks of a rock, w by h pixels with the joint, in a running bond: each
// a tone of its own, its top and left edges lit, its bottom and right shaded, the rock's
// grain on its face and a chip out of an edge here and there.
@(private)
bricks :: proc(rock: Rock, seed: u32, x, y, w, h: int) -> Rgba {
	course := wrap(y) / h
	b := brick(x + (course % 2) * (w / 2), y, w, h)
	if b.joint {return rock.mortar}
	tone := hash01(seed ~ 1, b.index, course)
	s := 2
	if tone < 0.25 {s = 1}
	if tone > 0.75 {s = 3}
	edge := bevel(b.u, b.v, w - 1, h - 1)
	if edge > 0 {s += 1}
	if edge < 0 {s -= 1}
	if edge != 0 && hash01(seed ~ 3, x, y) > 0.9 {return rock.mortar} 	// a chip
	return step(rock.ramp, s + max(grain_step(rock, seed, x, y), -1))
}

// tiles: square slabs of a rock, eight pixels across, in grout: each a flat tone of its
// own, bevelled, the grain faint on it.
@(private)
tiles :: proc(rock: Rock, seed: u32, x, y: int) -> Rgba {
	b := brick(x, y, 8, 8)
	if b.joint {return rock.mortar}
	s := 2 + int(hash01(seed ~ 1, b.index, b.course) > 0.5)
	edge := bevel(b.u, b.v, 7, 7)
	if edge > 0 {s += 1}
	if edge < 0 {s -= 1}
	return step(rock.ramp, s + clamp(grain_step(rock, seed, x, y), -1, 0))
}

// polished: the rock cut and polished into one slab a block across: a bevel round its
// edge, its face smooth in two broad tones, the grain showing through as specks or, in
// pale stone, veins.
@(private)
polished :: proc(rock: Rock, seed: u32, x, y: int) -> Rgba {
	edge := bevel(wrap(x), wrap(y), SIZE, SIZE)
	if edge > 0 {return rock.ramp[4]}
	if edge < 0 {return rock.ramp[1]}
	s := 2 + int(fbm(seed, x, y, 2, 2) > 0.5)
	// A fine vein where a slow noise crosses its middle.
	vein := abs(noise(seed ~ 9, x, y, 3, 3) - 0.5) < 0.035
	switch rock.grain {
	case .Fossil, .Bedded:
		if vein {s -= 1}
	case .Speckled, .Vesicular, .Laminated:
		h := hash01(seed ~ 4, x, y)
		if h > 0.94 {s -= 1}
		if h < 0.03 {s += 1}
	}
	return step(rock.ramp, s)
}
