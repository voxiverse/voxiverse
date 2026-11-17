package texture

// Metal: iron and steel plate (plain, riveted, rusted, dark), a grating, copper bright and
// green with age, brass, a hazard-striped panel and pipework. Metal is flat and hard: its
// form is in its seams, its rivets and its edges catching the light, its surface brushed
// in long faint streaks rather than grainy.

@(private, rodata)
STEEL := Ramp {
	{64, 68, 77, 255},
	{90, 95, 104, 255},
	{116, 121, 129, 255},
	{144, 148, 154, 255},
	{178, 180, 182, 255},
}
@(private, rodata)
DARK_STEEL := Ramp {
	{26, 29, 35, 255},
	{40, 44, 52, 255},
	{56, 61, 70, 255},
	{76, 82, 91, 255},
	{104, 109, 116, 255},
}
@(private, rodata)
RUST := Ramp {
	{86, 44, 28, 255},
	{118, 62, 34, 255},
	{148, 84, 46, 255},
	{174, 108, 62, 255},
	{198, 134, 86, 255},
}
@(private, rodata)
PATINA := Ramp {
	{50, 94, 84, 255},
	{68, 124, 106, 255},
	{90, 152, 126, 255},
	{118, 176, 148, 255},
	{154, 200, 174, 255},
}
@(private, rodata)
BRASS := Ramp {
	{102, 76, 32, 255},
	{142, 108, 44, 255},
	{180, 142, 62, 255},
	{208, 174, 88, 255},
	{234, 208, 134, 255},
}
@(private, rodata)
HAZARD := Ramp {
	{150, 110, 22, 255},
	{196, 148, 30, 255},
	{226, 180, 44, 255},
	{240, 202, 78, 255},
	{248, 224, 128, 255},
}

// Plating: how a metal is cut into plates.
Plating :: enum u8 {
	Quarters, // four plates a block, seamed
	Halves, // two long plates, bolted at their corners
	Riveted, // one plate a block, rivets along its edges
}

// plate: sheet metal: plates seamed (a dark line, the next plate's edge lit), each brushed
// in faint long streaks, their top and left edges catching the light.
@(private)
plate :: proc(ramp: Ramp, seed: u32, x, y: int, plating: Plating) -> Rgba {
	w, h := 8, 8
	switch plating {
	case .Quarters:
	case .Halves:
		w = 16
	case .Riveted:
		w, h = 16, 16
	}
	b := brick(x, y, w, h)
	if b.joint {return ramp[0]}
	s := 2
	if b.u == 0 || b.v == 0 {s = 3}
	if b.u == w - 2 || b.v == h - 2 {s = 1}
	// Rivets and bolts: a lit head, its shadow below and to the right.
	if rivet(plating, b.u, b.v, w, h) {return ramp[4]}
	if b.u > 0 && b.v > 0 && rivet(plating, b.u - 1, b.v - 1, w, h) {return ramp[0]}
	if s == 2 {
		// Brushed: streaks along the plate, a few pixels long.
		if noise(seed ~ 1, x, y, 2, 16) > 0.74 {s = 3}
	}
	return step(ramp, s)
}

// rivet: whether (u, v) of a w by h plate is a rivet's or a bolt's head.
@(private = "file")
rivet :: proc(plating: Plating, u, v, w, h: int) -> bool {
	switch plating {
	case .Quarters:
		return false
	case .Halves:
		return (u == 2 || u == w - 4) && v == 2
	case .Riveted:
		// Three a side, two pixels in from the seam.
		at :: proc(a: int) -> bool {return a == 2 || a == 7 || a == 12}
		return (u == 2 || u == 12) && at(v) || (v == 2 || v == 12) && at(u)
	}
	return false
}

// rusted: iron plate eaten by rust in patches, the rust running down from them in streaks.
@(private)
rusted :: proc(seed: u32, x, y: int) -> Rgba {
	base := plate(STEEL, seed, x, y, .Riveted)
	patch := fbm(seed ~ 2, x, y, 2, 3)
	run := noise(seed ~ 3, x, y, 8, 2) // streaks: fine across, long down
	if patch > 0.58 || (patch > 0.45 && run > 0.6) {
		s := 2
		if patch > 0.7 {s = 1}
		if hash01(seed ~ 4, x, y) > 0.9 {s += 1}
		if base == STEEL[0] || base == STEEL[4] {s -= 1}
		return step(RUST, s)
	}
	return base
}

// verdigris: copper plate gone green: patina in patches and in runs down from its seams.
@(private)
verdigris :: proc(seed: u32, x, y: int) -> Rgba {
	base := plate(COPPER, seed, x, y, .Quarters)
	patch := fbm(seed ~ 2, x, y, 2, 3)
	run := noise(seed ~ 3, x, y, 8, 2)
	if patch > 0.56 || (patch > 0.44 && run > 0.62) {
		s := 2 if patch < 0.62 else 3
		if base == COPPER[0] {s = 0}
		return step(PATINA, s)
	}
	return base
}

// grating: square bars every four pixels with the holes between them clear: the crossings
// lit, a bar's lower edge shaded.
@(private)
grating :: proc(ramp: Ramp, x, y: int) -> Rgba {
	u, v := wrap(x) % 4, wrap(y) % 4
	if u != 0 && v != 0 {return {}}
	if u == 0 && v == 0 {return ramp[3]}
	if u == 0 {return ramp[2] if v < 3 else ramp[1]}
	return ramp[2] if u < 3 else ramp[1]
}

// hazard: a panel striped in yellow and black, diagonally, scuffed here and there, its
// top and left edges lit.
@(private)
hazard :: proc(seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	if u == SIZE - 1 || v == SIZE - 1 {return DARK_STEEL[0]}
	yellow := (u + v) % 8 < 4
	s := 2
	if u == 0 || v == 0 {s = 3}
	if u == SIZE - 2 || v == SIZE - 2 {s = 1}
	if hash01(seed ~ 1, x, y) > 0.94 {return step(DARK_STEEL, 3)} 	// a scuff to the steel
	return step(HAZARD if yellow else DARK_STEEL, s if yellow else s - 1)
}

// pipes: two pipes up the face, round (lit a third of the way across, dark at their far
// side), joined by flanges, on a dark wall.
@(private)
pipes :: proc(seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	pipe := u >= 1 && u <= 6 || u >= 9 && u <= 14
	across := (u - 1) % 8 // 0..5 across a pipe
	flange := v % 8 == 6 || v % 8 == 7
	if flange && (u <= 7 || u >= 8) {
		// A flange: wider than the pipe, lit along its top.
		if u == 0 || u == 8 {return STEEL[1]}
		return STEEL[3] if v % 8 == 6 else STEEL[1]
	}
	if !pipe {
		if u == 0 || u == 8 {return DARK_STEEL[0]}
		return DARK_STEEL[1] if (u + v) % 4 != 0 else DARK_STEEL[2]
	}
	SHADE :: [6]int{1, 3, 4, 3, 2, 1}
	shade := SHADE
	return step(STEEL, shade[across])
}

// brass: one polished plate a block, an engraved line round it and a sheen across.
@(private)
brass :: proc(seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	edge := bevel(u, v, SIZE, SIZE)
	if edge > 0 {return BRASS[4]}
	if edge < 0 {return BRASS[0]}
	if (u == 2 || u == 13) && v >= 2 && v <= 13 || (v == 2 || v == 13) && u >= 2 && u <= 13 {
		return BRASS[1] // the engraved line
	}
	s := 2
	if abs(u - v) <= 1 && u > 3 && u < 12 {s = 3} 	// the sheen
	if hash01(seed ~ 1, x, y) > 0.95 {s -= 1}
	return step(BRASS, s)
}
