package texture

import "core:math"

// Wood: five species of their own hue and grain (pale birch, honey oak, dark spruce, red
// redwood, weathered grey), each as a log (its bark and its cut end), planks and a panel.

// Bark_Style: how a species' bark is broken up.
Bark_Style :: enum u8 {
	Plated, // oak: thick plates between deep furrows
	Papery, // birch: smooth and pale, dark dashes across, a black scar here and there
	Scaly, // spruce: small scales
	Fibrous, // redwood: long straight fibres, deep narrow furrows
	Split, // weathered: bare grey wood, long splits along it
}

Wood :: struct {
	wood:  Ramp, // the cut wood, darkest first
	bark:  Ramp,
	style: Bark_Style,
}

@(private, rodata)
BIRCH_WOOD := Ramp {
	{152, 128, 92, 255},
	{184, 160, 118, 255},
	{206, 184, 142, 255},
	{224, 205, 166, 255},
	{240, 226, 192, 255},
}
@(private, rodata)
BIRCH_BARK := Ramp {
	{38, 36, 40, 255},
	{146, 142, 138, 255},
	{198, 196, 190, 255},
	{226, 224, 216, 255},
	{244, 242, 234, 255},
}
@(private, rodata)
SPRUCE_WOOD := Ramp {
	{56, 38, 28, 255},
	{76, 52, 36, 255},
	{96, 68, 46, 255},
	{116, 84, 58, 255},
	{138, 102, 72, 255},
}
@(private, rodata)
REDWOOD_WOOD := Ramp {
	{98, 44, 34, 255},
	{126, 60, 42, 255},
	{150, 76, 52, 255},
	{172, 94, 64, 255},
	{194, 116, 82, 255},
}
@(private, rodata)
REDWOOD_BARK := Ramp {
	{56, 28, 26, 255},
	{80, 42, 34, 255},
	{104, 56, 42, 255},
	{128, 72, 52, 255},
	{150, 90, 64, 255},
}
@(private, rodata)
WEATHERED_WOOD := Ramp {
	{82, 80, 80, 255},
	{106, 104, 100, 255},
	{130, 126, 118, 255},
	{152, 148, 138, 255},
	{176, 171, 158, 255},
}
@(private, rodata)
WEATHERED_BARK := Ramp {
	{50, 48, 50, 255},
	{72, 70, 68, 255},
	{94, 90, 84, 255},
	{116, 112, 104, 255},
	{140, 135, 124, 255},
}

// (Not rodata: made from the ramps, which are variables.)
@(private)
OAK := Wood{WOOD, BARK, .Plated}
@(private)
BIRCH := Wood{BIRCH_WOOD, BIRCH_BARK, .Papery}
@(private)
SPRUCE := Wood{SPRUCE_WOOD, SPRUCE_BARK, .Scaly}
@(private)
REDWOOD := Wood{REDWOOD_WOOD, REDWOOD_BARK, .Fibrous}
@(private)
WEATHERED := Wood{WEATHERED_WOOD, WEATHERED_BARK, .Split}

// bark_of: a log's side: strips of bark running up the trunk, of widths of their own,
// each broken into pieces down it; a strip's left edge lit, its right in shadow, a furrow
// between strips. The species says how wide, how broken and how deep.
@(private)
bark_of :: proc(w: Wood, seed: u32, x, y: int) -> Rgba {
	if w.style == .Papery {return birch_bark(w, seed, x, y)}
	// The strips across the texture: their widths sum to SIZE (a 0 ends the list).
	widths: [8]int
	switch w.style {
	case .Plated, .Papery:
		widths = {5, 3, 4, 4, 0, 0, 0, 0}
	case .Scaly:
		widths = {3, 3, 2, 3, 3, 2, 0, 0}
	case .Fibrous:
		widths = {2, 3, 2, 2, 3, 2, 2, 0}
	case .Split:
		widths = {6, 4, 6, 0, 0, 0, 0, 0}
	}
	strip, u, left := 0, wrap(x), 0
	for width, i in widths {
		if u < left + width {
			strip = i
			break
		}
		left += width
	}
	width := widths[strip]
	u -= left
	if u == width - 1 && w.style != .Split {return w.bark[0]} 	// the furrow
	// Breaks down the strip: its pieces, each its own tone.
	pieces := 4 if w.style == .Scaly else 2
	length := SIZE / pieces
	shift := int(hash01(seed ~ 1, strip, 0) * f32(length))
	row := wrap(y + shift)
	piece := row / length
	if row % length == 0 && w.style != .Fibrous {return w.bark[0 if w.style != .Split else 1]}
	s := 1 + int(hash01(seed ~ 2, strip, piece) * 2.99)
	if u == 0 {s += 1}
	if u == width - 2 {s -= 1}
	if row % length == 1 {s += 1} 	// the top of a piece, under the break
	if w.style == .Split &&
	   u ==
		   width -
			   1 {return w.bark[0] if hash01(seed ~ 3, strip, row / 3) > 0.4 else step(w.bark, s)}
	if w.style == .Fibrous && hash01(seed ~ 4, x, row / 4) > 0.75 {s -= 1}
	return step(w.bark, s)
}

// birch_bark: pale and smooth, with dark dashes across it (lenticels) and a black scar
// where a branch was.
@(private)
birch_bark :: proc(w: Wood, seed: u32, x, y: int) -> Rgba {
	// Dashes: rows of them, two to five pixels long, at places of their own.
	row := wrap(y)
	if row % 4 == 1 {
		dash := wrap(x + int(hash01(seed ~ 1, row / 4, 0) * 16)) / 4
		u := wrap(x + int(hash01(seed ~ 1, row / 4, 0) * 16)) % 4
		if hash01(seed ~ 2, dash, row / 4) > 0.35 && u < 3 {return w.bark[0]}
	}
	// A scar: a dark eye with a pale rim.
	c := cells(seed ~ 3, x, y, 2)
	if hash01(c.id, 1, 0) < 0.4 {
		if abs(c.dx) < 1.6 && abs(c.dy) < 0.8 {return w.bark[0]}
		if abs(c.dx) < 2.6 && abs(c.dy) < 1.6 && c.dy > 0 {return w.bark[1]}
	}
	s := 3
	if noise(seed ~ 4, x, y, 2, 4) > 0.65 {s = 2}
	return step(w.bark, s)
}

// rings_of: a log's cut end: growth rings round the pith, wavering, a check (a crack)
// out from the middle, a dark line of cambium, then the bark.
@(private)
rings_of :: proc(w: Wood, seed: u32, x, y: int) -> Rgba {
	dx, dy := f32(x) - 7.5, f32(y) - 7.5
	r := math.sqrt(dx * dx + dy * dy)
	if r >= 7.0 {return step(w.bark, 1 + int(hash01(seed ~ 1, x, y) * 2.99))}
	if r >= 6.2 {return w.bark[0]}
	if r < 1 {return w.wood[1]} 	// the pith
	// The check: along one direction from the middle.
	angle := math.atan2(dy, dx)
	check := f32(hash01(seed ~ 2, 0, 0)) * 2 * math.PI - math.PI
	if abs(angle - check) < 0.22 && r > 1.5 && r < 5.5 {return w.wood[0]}
	ring := r + 0.8 * noise(seed, x, y, 4, 4)
	s := 3 if int(ring) % 2 == 0 else 2
	if int(ring) % 4 == 3 {s = 1}
	return step(w.wood, s)
}

// planks_of: boards four pixels wide with a gap below each, one end joint each at a place
// of its own; every board a tone of its own, its top edge lit and its foot shaded, a grain
// line or two along it and a nail at each side of its joint.
@(private)
planks_of :: proc(w: Wood, seed: u32, x, y: int) -> Rgba {
	course := wrap(y) / 4
	joint := int(hash01(seed ~ 1, course, 0) * 16)
	u := wrap(x - joint)
	v := wrap(y) % 4
	if v == 3 || u == SIZE - 1 {return w.wood[0]} 	// the gap under the board, its end joint
	s := 1 + int(hash01(seed ~ 2, course, 0) * 2.99)
	if v == 0 {s += 1}
	if v == 2 {s -= 1}
	// Grain: a streak along the board on one of its rows, broken.
	if v == 1 + int(hash01(seed ~ 3, course, 0) * 1.99) &&
	   noise(seed ~ 4, x, course, 4, 4) > 0.45 {
		s -= 1
	}
	if v == 1 && (u == 1 || u == SIZE - 3) {return w.wood[0]} 	// nails
	return step(w.wood, s)
}

// panel_of: a framed panel a block across: rails along its top and bottom and stiles at
// its sides, their grain along them, round a sunken field (its top and left inside edge in
// the frame's shadow, its foot lit) with the grain up it.
@(private)
panel_of :: proc(w: Wood, seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x), wrap(y)
	if u == SIZE - 1 || v == SIZE - 1 {return w.wood[0]} 	// the joint to the next panel
	rail := v < 3 || v > 11
	stile := u < 3 || u > 11
	if rail || stile {
		s := 2
		if u == 0 || v == 0 {s += 1}
		if (rail && v == 14) || (stile && !rail && u == 14) {s -= 1}
		// Grain along the piece: across a rail, up a stile.
		along := hash01(seed ~ 1, v, 0) if rail else hash01(seed ~ 2, u, 1)
		if along > 0.7 {s -= 1}
		return step(w.wood, s)
	}
	// The field, sunk: shadowed under the frame's top and left, lit at its foot.
	if u == 3 || v == 3 {return w.wood[0]}
	s := 2
	if u == 11 || v == 11 {s += 1}
	if hash01(seed ~ 3, u, 0) > 0.75 && noise(seed ~ 4, u, v, 2, 4) > 0.4 {s -= 1}
	return step(w.wood, s)
}
