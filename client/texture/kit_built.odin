package texture

// Built and industrial: concrete (plain, stained, in slabs), asphalt, red brick, painted
// steel panels in a few strong colours, tinted glass, a screen, a vent and a conveyor. Made
// things: flat surfaces whose form is their joints, edges and fixings.

@(private, rodata)
CONCRETE := Ramp {
	{112, 113, 112, 255},
	{136, 137, 134, 255},
	{154, 154, 149, 255},
	{170, 169, 163, 255},
	{190, 188, 179, 255},
}
@(private, rodata)
ASPHALT := Ramp {
	{28, 29, 32, 255},
	{40, 41, 44, 255},
	{52, 53, 55, 255},
	{68, 68, 68, 255},
	{94, 92, 88, 255},
}
@(private, rodata)
RED_BRICK := Ramp {
	{100, 40, 34, 255},
	{130, 56, 42, 255},
	{154, 72, 52, 255},
	{176, 92, 64, 255},
	{198, 118, 86, 255},
}
@(private, rodata)
PAINT_RED := Ramp {
	{102, 32, 32, 255},
	{138, 44, 40, 255},
	{166, 58, 48, 255},
	{190, 80, 62, 255},
	{212, 110, 86, 255},
}
@(private, rodata)
PAINT_BLUE := Ramp {
	{28, 48, 88, 255},
	{38, 66, 118, 255},
	{52, 86, 146, 255},
	{74, 110, 170, 255},
	{104, 140, 194, 255},
}
@(private, rodata)
PAINT_YELLOW := Ramp {
	{156, 114, 26, 255},
	{194, 148, 36, 255},
	{220, 176, 52, 255},
	{236, 200, 82, 255},
	{246, 222, 128, 255},
}
@(private, rodata)
PAINT_WHITE := Ramp {
	{150, 154, 156, 255},
	{184, 187, 186, 255},
	{208, 210, 206, 255},
	{226, 226, 220, 255},
	{242, 240, 234, 255},
}
@(private, rodata)
SCREEN_GLOW := Ramp {
	{10, 24, 24, 255},
	{18, 44, 40, 255},
	{40, 112, 92, 255},
	{86, 196, 152, 255},
	{170, 246, 210, 255},
}
@(private, rodata)
TINT := Ramp {
	{40, 70, 80, 200},
	{60, 96, 104, 140},
	{78, 118, 124, 120},
	{120, 162, 166, 150},
	{190, 222, 222, 180},
}

// (Not rodata: made from the ramps, which are variables.)
@(private)
RED_BRICK_ROCK := Rock{RED_BRICK, {176, 170, 158, 255}, .Fired}

// concrete: poured concrete: broad faint clouds of two tones, the line where one pour met
// the next, and the holes of the formwork's ties in a grid, lit on their far wall.
@(private)
concrete :: proc(seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	if (u == 4 || u == 12) && (v == 4 || v == 12) {return CONCRETE[0]}
	if (u == 5 || u == 13) && (v == 5 || v == 13) {return CONCRETE[3]}
	s := 2 + int(fbm(seed, x, y, 2, 2) > 0.55)
	if v == 15 && noise(seed ~ 1, x, 0, 4, 1) > 0.35 {s -= 1} 	// the pour line
	h := hash01(seed ~ 2, x, y)
	if h > 0.96 {s -= 1}
	if h < 0.02 {s += 1}
	return step(CONCRETE, s)
}

// stained: concrete the rain has run down: dark streaks from the top, long and short.
@(private)
stained :: proc(seed: u32, x, y: int) -> Rgba {
	c := concrete(seed, x, y)
	column := wrap(x)
	length := int(hash01(seed ~ 3, column, 0) * 20) - 4 // pixels down it runs (none if < 1)
	if wrap(y) < length && c != CONCRETE[3] {
		s := 1
		if wrap(y) < length / 2 && hash01(seed ~ 4, column, 1) > 0.5 {s = 0}
		return step(CONCRETE, s)
	}
	return c
}

// slabs: concrete cast in square slabs, eight pixels across: a tone each, bevelled, in
// dark joints.
@(private)
slabs :: proc(seed: u32, x, y: int) -> Rgba {
	b := brick(x, y, 8, 8)
	if b.joint {return CONCRETE[0]}
	s := 2 + int(hash01(seed ~ 1, b.index, b.course) > 0.5)
	edge := bevel(b.u, b.v, 7, 7)
	if edge > 0 {s += 1}
	if edge < 0 {s -= 1}
	if hash01(seed ~ 2, x, y) > 0.96 {s -= 1}
	return step(CONCRETE, s)
}

// asphalt: dark binder full of small stones, pale and dark, and a crack wandering across.
@(private)
asphalt :: proc(seed: u32, x, y: int) -> Rgba {
	if abs(noise(seed ~ 1, x, y, 3, 3) - 0.5) < 0.025 {return ASPHALT[0]} 	// the crack
	s := 1 + int(fbm(seed, x, y, 2, 2) > 0.5)
	h := hash01(seed ~ 2, x, y)
	if h > 0.86 {s = 3}
	if h > 0.97 {s = 4}
	if h < 0.06 {s = 0}
	return step(ASPHALT, s)
}

// painted: a steel panel a block across, painted: split into two by a seam, each half lit
// at its top and left, flat in between, chipped to the steel here and there.
@(private)
painted :: proc(paint: Ramp, seed: u32, x, y: int) -> Rgba {
	b := brick(x, y, 16, 8)
	if b.joint {return paint[0]}
	if hash01(seed ~ 1, x, y) > 0.975 {return DARK_STEEL[2]} 	// a chip
	s := 2
	if b.u == 0 || b.v == 0 {s = 3}
	if b.u == 14 || b.v == 6 {s = 1}
	return step(paint, s)
}

// tinted: coloured glass in a frame: see-through and tinted, two streaks of light on it.
@(private)
tinted :: proc(x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	if u == 0 || v == 0 || u == SIZE - 1 || v == SIZE - 1 {return TINT[0]}
	if (u + v == 9 || u + v == 10) && u > 2 && u < 9 {return TINT[4]}
	if (u + v == 14) && u > 5 && u < 12 {return TINT[3]}
	return TINT[1] if (u + v) % 2 == 0 || u < 8 else TINT[2]
}

// screen: a display in a steel bezel: dark glass, lines of glowing text, a cursor, the
// scanlines faint across it.
@(private)
screen :: proc(seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	if u == 0 || v == 0 {return DARK_STEEL[3]}
	if u == SIZE - 1 || v == SIZE - 1 {return DARK_STEEL[0]}
	if u == 1 || v == 1 || u == SIZE - 2 || v == SIZE - 2 {return DARK_STEEL[1]}
	// The text: a line every other row from the third, of a length of its own.
	if v >= 3 && v <= 12 && v % 2 == 1 {
		line := v / 2
		length := 3 + int(hash01(seed ~ 1, line, 0) * 9)
		if u >= 3 && u < 3 + length {
			if hash01(seed ~ 2, u, line) > 0.8 {return SCREEN_GLOW[1]} 	// between words
			return SCREEN_GLOW[3]
		}
		if u == 3 + length && line == 5 {return SCREEN_GLOW[4]} 	// the cursor
	}
	return SCREEN_GLOW[0] if v % 2 == 0 else SCREEN_GLOW[1]
}

// vent: louvres in a steel frame: slats lit along their top, a dark gap under each.
@(private)
vent :: proc(x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	if u == 0 || v == 0 {return STEEL[3]}
	if u == SIZE - 1 || v == SIZE - 1 {return STEEL[0]}
	if u == 1 || u == SIZE - 2 {return STEEL[1]}
	switch (v - 1) % 3 {
	case 0:
		return STEEL[3]
	case 1:
		return STEEL[2]
	}
	return DARK_STEEL[0]
}

// conveyor_top: a rubber belt with ribs across it between two steel rails.
@(private)
conveyor_top :: proc(seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	if u <= 1 || u >= SIZE - 2 {
		return STEEL[3] if u == 0 || u == SIZE - 2 else STEEL[1] // the rails
	}
	switch v % 4 {
	case 0:
		return ASPHALT[3] // a rib, lit
	case 1:
		return ASPHALT[0] // its shadow
	}
	return ASPHALT[1] if hash01(seed ~ 1, x, y) > 0.15 else ASPHALT[2]
}

// conveyor_side: the conveyor's side: the belt's edge along its top, a steel frame below
// with two rollers' ends, round and lit at their top left.
@(private)
conveyor_side :: proc(seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	if v <= 1 {return ASPHALT[2] if v == 0 else ASPHALT[0]}
	for cx in ([2]f32{4.5, 11.5}) {
		dx, dy := f32(u) - cx, f32(v) - 7.5
		r := dx * dx + dy * dy
		if r < 2.5 {return STEEL[0]} 	// the axle
		if r < 9 {return STEEL[4] if dx + dy < -1 else STEEL[2]}
		if r < 12 {return DARK_STEEL[0]}
	}
	return plate(DARK_STEEL, seed, x, y, .Halves)
}
