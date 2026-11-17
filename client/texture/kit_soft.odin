package texture

// Soft and domestic: thatch, plaster in three colours, roofs of clay tile and slate, wool
// in a palette, a patterned carpet and a shelf of books. Natural: mud, cracked dry earth,
// dry and snowy grass, red sand, moss, leaves of three more kinds and packed ice.

@(private, rodata)
THATCH := Ramp {
	{104, 78, 38, 255},
	{146, 112, 52, 255},
	{180, 144, 68, 255},
	{206, 174, 94, 255},
	{228, 202, 130, 255},
}
@(private, rodata)
WHITE_PLASTER := Ramp {
	{170, 170, 166, 255},
	{196, 195, 188, 255},
	{214, 212, 204, 255},
	{223, 221, 213, 255},
	{242, 240, 232, 255},
}
@(private, rodata)
CREAM_PLASTER := Ramp {
	{166, 148, 112, 255},
	{196, 178, 138, 255},
	{214, 198, 158, 255},
	{222, 207, 168, 255},
	{240, 230, 198, 255},
}
@(private, rodata)
OCHRE_PLASTER := Ramp {
	{136, 92, 46, 255},
	{170, 120, 60, 255},
	{192, 142, 74, 255},
	{201, 151, 83, 255},
	{226, 184, 120, 255},
}
@(private, rodata)
CLAY_TILE := Ramp {
	{96, 40, 30, 255},
	{136, 58, 38, 255},
	{166, 78, 48, 255},
	{190, 100, 62, 255},
	{212, 130, 88, 255},
}
@(private, rodata)
WOOL_RED := Ramp {
	{100, 28, 30, 255},
	{132, 38, 38, 255},
	{158, 50, 46, 255},
	{180, 66, 58, 255},
	{200, 88, 74, 255},
}
@(private, rodata)
WOOL_BLUE := Ramp {
	{30, 40, 84, 255},
	{40, 54, 110, 255},
	{52, 70, 136, 255},
	{68, 90, 158, 255},
	{92, 114, 178, 255},
}
@(private, rodata)
WOOL_GREEN := Ramp {
	{34, 66, 36, 255},
	{44, 88, 44, 255},
	{58, 110, 54, 255},
	{76, 130, 66, 255},
	{100, 150, 82, 255},
}
@(private, rodata)
WOOL_YELLOW := Ramp {
	{150, 110, 30, 255},
	{186, 140, 40, 255},
	{210, 166, 54, 255},
	{228, 190, 76, 255},
	{240, 212, 112, 255},
}
@(private, rodata)
MUD := Ramp {
	{44, 32, 26, 255},
	{60, 44, 34, 255},
	{76, 58, 44, 255},
	{96, 76, 58, 255},
	{150, 140, 128, 255},
}
@(private, rodata)
DRY_EARTH := Ramp {
	{96, 66, 42, 255},
	{136, 98, 62, 255},
	{162, 122, 80, 255},
	{184, 146, 100, 255},
	{204, 170, 124, 255},
}
@(private, rodata)
DRY_GRASS := Ramp {
	{100, 92, 44, 255},
	{130, 118, 56, 255},
	{158, 144, 70, 255},
	{184, 168, 90, 255},
	{208, 192, 116, 255},
}
@(private, rodata)
RED_SAND := Ramp {
	{150, 78, 44, 255},
	{176, 98, 56, 255},
	{196, 116, 68, 255},
	{212, 136, 84, 255},
	{228, 160, 106, 255},
}
@(private, rodata)
MOSS := Ramp {
	{38, 64, 30, 255},
	{54, 88, 36, 255},
	{72, 112, 44, 255},
	{94, 134, 52, 255},
	{124, 158, 68, 255},
}
@(private, rodata)
BIRCH_LEAVES := Ramp {
	{62, 96, 34, 255},
	{86, 124, 40, 255},
	{112, 150, 50, 255},
	{140, 172, 64, 255},
	{172, 194, 88, 255},
}
@(private, rodata)
AUTUMN_LEAVES := Ramp {
	{100, 42, 28, 255},
	{142, 64, 34, 255},
	{174, 92, 42, 255},
	{198, 124, 54, 255},
	{216, 156, 76, 255},
}
@(private, rodata)
PACKED_ICE := Ramp {
	{100, 140, 190, 255},
	{124, 162, 208, 255},
	{148, 182, 222, 255},
	{176, 204, 234, 255},
	{220, 236, 250, 255},
}
@(private, rodata)
BOOKS := [5]Rgba {
	{132, 40, 36, 255},
	{40, 62, 112, 255},
	{50, 92, 52, 255},
	{116, 84, 44, 255},
	{170, 132, 54, 255},
}

// thatch: straw laid in courses eight pixels deep: strands down each, of their own tones
// and lengths, the top of a course in the shadow of the one above, the strands' ends
// ragged at its foot.
@(private)
thatch :: proc(seed: u32, x, y: int) -> Rgba {
	course := wrap(y) / 8
	v := wrap(y) % 8
	column := wrap(x + course * 5)
	length := 6 + int(hash01(seed ~ 1, column, course) * 2.99) // where this strand ends
	if v >= length {return THATCH[0]} 	// between strands' ends, the shadow under them
	s := 1 + int(hash01(seed ~ 2, column, course) * 2.99)
	if v <= 1 {s -= 1} 	// under the course above
	if v == length - 1 {s += 1} 	// a strand's lit end
	return step(THATCH, s)
}

// plaster: a smooth render: broad soft clouds of two close tones, a pit here and there.
@(private)
plaster :: proc(ramp: Ramp, seed: u32, x, y: int) -> Rgba {
	s := 2 + int(fbm(seed, x, y, 2, 2) > 0.56)
	if hash01(seed ~ 2, x, y) > 0.975 {s = 1}
	return step(ramp, s)
}

// roof: tiles in courses four pixels high and eight across, each course half a tile over
// from the one below, the course above casting its shadow. Clay tiles are round: lit
// along their left, shaded round to their right; slate is flat, a tone a slate.
@(private)
roof :: proc(ramp: Ramp, seed: u32, x, y: int, round: bool) -> Rgba {
	course := wrap(y) / 4
	b := brick(x + (course % 2) * 4, y, 8, 4)
	if b.v == 0 {return ramp[0]} 	// the shadow of the course above
	if b.u == 7 {return ramp[0] if round else ramp[1]}
	s := 2
	if round {
		ROUND :: [7]int{3, 3, 2, 2, 2, 1, 1}
		across := ROUND
		s = across[b.u]
	} else {
		s = 1 + int(hash01(seed ~ 1, b.index, course) * 2.99)
		if b.v == 1 {s += 1}
	}
	if hash01(seed ~ 2, x, y) > 0.95 {s -= 1}
	return step(ramp, s)
}

// woven: cloth woven in a basket weave: blocks of threads running across, then down, in
// turn, each thread a shade lighter along one side; soft, so it reads as cloth.
@(private)
woven :: proc(ramp: Ramp, seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	across := (u / 4 + v / 4) % 2 == 0
	along := v % 2 if across else u % 2
	s := 3 if along == 0 else 2
	if hash01(seed ~ 1, x, y) > 0.94 {s -= 1}
	return step(ramp, s)
}

// carpet: a woven rug's pattern, a block across: a dark border with a gold line, a red
// field with a gold diamond in it.
@(private)
carpet :: proc(seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	edge := min(min(u, v), min(SIZE - 1 - u, SIZE - 1 - v))
	if edge == 0 {return WOOL_RED[0]}
	if edge == 1 {return WOOL_YELLOW[2] if (u + v) % 2 == 0 else WOOL_YELLOW[1]}
	d := abs(f32(u) - 7.5) + abs(f32(v) - 7.5)
	if d < 1.5 {return WOOL_BLUE[2]}
	if d >= 4 && d < 5 {return WOOL_YELLOW[2]}
	if d >= 5 && d < 6 {return WOOL_RED[0]}
	return woven(WOOL_RED, seed, x, y)
}

// bookshelf: a shelf of books between boards: each book a colour and a height of its own,
// its spine lit along its left, the dark of the shelf above the shorter ones.
@(private)
bookshelf :: proc(seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	if v == 0 || v == 7 || v == 8 || v == SIZE - 1 {
		return WOOD[3] if v == 0 || v == 8 else WOOD[0] // the boards
	}
	if u == 0 || u == SIZE - 1 {return WOOD[1]}
	row := 0 if v < 8 else 1
	top := 1 if row == 0 else 9 // the first row a book can reach
	// Books two pixels wide (a few three), side by side.
	book := (u - 1) / 2
	height := 3 + int(hash01(seed ~ 1, book, row) * 3.99)
	if v < top + 6 - height {return WOOD[0]} 	// the dark above a short book
	colour := BOOKS[int(hash01(seed ~ 2, book, row) * 4.99)]
	if (u - 1) % 2 == 0 {return colour + {24, 24, 24, 0} * u8(v % 3 != 1)}
	if v == top + 6 - height + 1 {return {colour.r / 2, colour.g / 2, colour.b / 2, 255}}
	return colour
}

// mud: wet earth trodden into clods, each lit at its top left, with puddles between that
// shine where they catch the light.
@(private)
mud :: proc(seed: u32, x, y: int) -> Rgba {
	if fbm(seed ~ 1, x, y, 2, 2) > 0.6 {
		// A puddle: flat and dark, its far edge catching the sky.
		return MUD[4] if hash01(seed ~ 2, x, y) > 0.8 else MUD[3]
	}
	c := cells(seed, x, y, 4)
	if c.d2 - c.d1 < 0.7 {return MUD[0]}
	lean := -(c.dx + c.dy) / 2.5
	s := 1 + int(hash01(c.id, 0, 0) > 0.5)
	if lean > 0.45 {s += 1}
	return step(MUD, s)
}

// dry_earth: sun-baked earth cracked into plates, each a tone of its own and lit at its
// top left, the cracks dark between.
@(private)
dry_earth :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 4)
	gap := c.d2 - c.d1
	if gap < 0.8 {return DRY_EARTH[0]}
	lean := -(c.dx + c.dy)
	s := 2 + int(hash01(c.id, 0, 0) > 0.6)
	if gap < 1.7 {s += 1 if lean > 0 else -1}
	return step(DRY_EARTH, s)
}

// turf: short blades seen from above, a stroke two pixels long each, lit at its tip, over
// patches of darker and lighter growth.
@(private)
turf :: proc(ramp: Ramp, seed: u32, x, y: int) -> Rgba {
	shift := int(hash01(seed ~ 1, x, 0) * 16)
	row := wrap(y + shift)
	blade := hash01(seed, x, row / 2)
	s := 1 + int(fbm(seed ~ 2, x, y, 2, 2) > 0.5) + int(blade > 0.55)
	if row % 2 == 0 && blade > 0.55 {s += 1}
	return step(ramp, s)
}

// turf_side: a side under turf: the grass hanging two to four pixels over the earth, a
// blade further here and there, its shadow under it.
@(private)
turf_side :: proc(top: Ramp, seed: u32, x, y: int) -> Rgba {
	edge := 2 + int(hash01(seed ~ 3, x, 0) * 2.99)
	if hash01(seed ~ 4, x, 0) > 0.8 {edge += 2}
	v := wrap(y)
	switch {
	case v < edge:
		return turf(top, seed, x, y)
	case v == edge:
		return top[0]
	case v == edge + 1:
		return DIRT[0]
	}
	return dirt(seed_of(.Dirt), x, y)
}

// snow_side: a side under snow: the snow two to four pixels deep over the earth, hanging
// lower here and there, its blue shadow under it.
@(private)
snow_side :: proc(seed: u32, x, y: int) -> Rgba {
	edge := 2 + int(noise(seed ~ 3, x, 0, 8, 1) * 2.99) // a drift's depth, varying smoothly
	v := wrap(y)
	switch {
	case v < edge:
		return SNOW[4] if v == 0 else SNOW[3]
	case v == edge:
		return SNOW[0]
	case v == edge + 1:
		return DIRT[0]
	}
	return dirt(seed_of(.Dirt), x, y)
}

// dunes: sand in ripples the wind left: wavering bands of two tones, a dark or a pale
// grain here and there.
@(private)
dunes :: proc(ramp: Ramp, seed: u32, x, y: int) -> Rgba {
	band := noise(seed, x + 2 * int(noise(seed ~ 1, x, y, 2, 2) * 4), y, 1, 4)
	s := 2 + int(band > 0.55)
	if band < 0.25 {s = 1}
	h := hash01(seed ~ 2, x, y)
	if h > 0.9 {s -= 1}
	if h < 0.07 {s += 1}
	return step(ramp, s)
}

// moss: a cushion of moss in clumps, each round, lit at its top left, a bright tip here
// and there, the hollows between them dark.
@(private)
moss :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 4)
	if c.d2 - c.d1 < 0.7 {return MOSS[0]}
	lean := -(c.dx + c.dy) / 2.5
	s := 2
	if lean > 0.4 {s = 3}
	if lean < -0.5 {s = 1}
	if hash01(seed ~ 1, x, y) > 0.93 {s = 4}
	return step(MOSS, s)
}

// foliage: leaves in clusters, each lit at its top left and darker at its foot, with
// gaps to see through where clusters leave them.
@(private)
foliage :: proc(ramp: Ramp, seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 4)
	if c.d1 > 2.7 && hash01(seed ~ 1, x, y) > 0.35 {return {}} 	// a gap
	r := ramp
	if c.d2 - c.d1 < 0.6 {return r[0]}
	lean := -(c.dx + c.dy) / 2.5
	s := 2
	if lean > 0.35 {s = 3}
	if lean > 0.9 {s = 4}
	if lean < -0.5 {s = 1}
	if hash01(seed ~ 2, x, y) > 0.9 {s -= 1}
	return step(r, s)
}

// ice_of: ice in facets n across (broad for clear ice, smaller for packed), each a blue of
// its own lit at its top left, their edges fractured white, a bubble caught here and there.
@(private)
ice_of :: proc(ramp: Ramp, seed: u32, x, y, n: int) -> Rgba {
	c := cells(seed, x, y, n)
	gap := c.d2 - c.d1
	lean := -(c.dx + c.dy) / (9 / f32(n)) // (a facet's reach, about)
	if gap < 0.8 {return ramp[4] if lean > -0.2 else ramp[0]}
	s := 1 + int(hash01(c.id, 0, 0) * 1.99)
	if lean > 0.5 {s += 1}
	if hash01(seed ~ 1, x, y) > 0.97 {s = 4} 	// a bubble
	return step(ramp, s)
}
