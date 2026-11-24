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

// Furrows: how a species' bark is cut up its length. A furrow is a groove a pixel or two
// wide that wanders across as it runs up the trunk and closes here and there, where the
// ridges either side of it meet; count of them across, how far each may wander, how much
// of its length is open and how often it is two pixels wide.
@(private = "file")
Furrows :: struct {
	count:  int,
	wander: f32, // pixels either way
	open:   f32, // 0..1: the share of its length that is open, about
	wide:   f32, // 0..1: the share of it two pixels wide, about
	ridge:  int, // the ridges' tone, the step of the ramp most of the bark is
}

@(private = "file", rodata)
FURROWS := [Bark_Style]Furrows {
	.Plated = {count = 4, wander = 1.2, open = 0.7, wide = 0.35, ridge = 2},
	.Papery = {ridge = 3}, // (birch_bark draws it)
	.Scaly = {count = 6, wander = 1.0, open = 0.6, wide = 0.25, ridge = 2},
	.Fibrous = {count = 6, wander = 0.6, open = 0.85, wide = 0.1, ridge = 2},
	.Split = {count = 3, wander = 0.8, open = 0.6, wide = 0.15, ridge = 3},
}

// bark_of: a log's side: ridges of bark running up the trunk between furrows of widths
// and lengths of their own, irregularly spaced, each wandering a little; a furrow's far
// wall catches the light. The ridges are two close tones in long soft patches; nothing is
// outlined and nothing repeats on a grid. The species says how many, how long, how straight.
@(private)
bark_of :: proc(w: Wood, seed: u32, x, y: int) -> Rgba {
	if w.style == .Papery {return birch_bark(w, seed, x, y)}
	f := FURROWS[w.style]
	u := wrap(x)
	// Long soft patches up the ridges: two tones.
	s := f.ridge + int(noise(seed ~ 5, x, y, 3, 2) > 0.62)
	spacing := f32(SIZE) / f32(f.count)
	for k in 0 ..< f.count {
		// Its place across: spaced about evenly, each pushed off its place.
		at := f32(k) * spacing + 0.3 * spacing + 0.4 * spacing * hash01(seed ~ 1, k, 0)
		at += f.wander * (2 * noise(seed ~ u32(16 + k), 0, y, 1, 3) - 1)
		col := wrap(int(math.floor(at)))
		open := noise(seed ~ u32(32 + k), 0, y, 1, 4) < f.open
		if !open {continue}
		width := 2 if noise(seed ~ u32(48 + k), 0, y, 1, 2) < f.wide else 1
		d := wrap(u - col)
		if d < width {return step(w.bark, f.ridge - 1)}
		if d == width {s = max(s, f.ridge + 1)} 	// the furrow's far wall, lit
	}
	return step(w.bark, s)
}

// birch_bark: pale and smooth in broad soft patches, with short grey dashes across it
// (lenticels) on rows of their own, and a dark scar here and there where a branch was.
@(private)
birch_bark :: proc(w: Wood, seed: u32, x, y: int) -> Rgba {
	// Dashes: on some rows (never two together), two to four pixels long.
	row := wrap(y)
	if hash01(seed ~ 1, row, 0) > 0.65 && hash01(seed ~ 1, wrap(row - 1), 0) <= 0.65 {
		shift := int(hash01(seed ~ 7, row, 0) * 16)
		dash := wrap(x + shift) / 5
		u := wrap(x + shift) % 5
		if hash01(seed ~ 2, dash, row) > 0.5 && u < 2 + int(hash01(seed ~ 8, dash, row) * 2.99) {
			return w.bark[1]
		}
	}
	// A scar: a dark eye, its lower lip pale grey.
	c := cells(seed ~ 3, x, y, 2)
	if hash01(c.id, 1, 0) < 0.3 {
		if abs(c.dx) < 1.6 && abs(c.dy) < 0.8 {return w.bark[0]}
		if abs(c.dx) < 2.1 && abs(c.dy) < 1.6 && c.dy > 0 {return w.bark[1]}
	}
	s := 3
	if noise(seed ~ 4, x, y, 2, 3) > 0.68 {s = 4}
	return step(w.bark, s)
}

// rings_of: a log's cut end: soft growth rings round the pith in two close tones,
// wavering, a darker ring now and then, the sapwood's edge a step darker, then the bark.
@(private)
rings_of :: proc(w: Wood, seed: u32, x, y: int) -> Rgba {
	dx, dy := f32(x) - 7.5, f32(y) - 7.5
	r := math.sqrt(dx * dx + dy * dy)
	if r >=
	   7.0 {return step(w.bark, FURROWS[w.style].ridge + int(noise(seed ~ 1, x, y, 4, 4) > 0.6))}
	if r >= 6.2 {return w.wood[1]} 	// the cambium: the wood's edge
	if r < 1 {return w.wood[2]} 	// the pith
	ring := int(r + 0.9 * noise(seed, x, y, 4, 4))
	if ring % 3 == 2 {return w.wood[2]} 	// the late wood of a year: a darker ring
	return w.wood[3]
}

// planks_of: boards four pixels wide with a dark gap below each, one end joint each at a
// place of its own; every board one of two tones, its top edge lit, a soft grain streak
// along it here and there.
@(private)
planks_of :: proc(w: Wood, seed: u32, x, y: int) -> Rgba {
	course := wrap(y) / 4
	joint := int(hash01(seed ~ 1, course, 0) * 16)
	u := wrap(x - joint)
	v := wrap(y) % 4
	if v == 3 {return w.wood[0]} 	// the gap under the board
	if u == SIZE - 1 {return w.wood[1]} 	// its end joint
	s := 2 + int(hash01(seed ~ 2, course, 0) > 0.6)
	if v == 0 {s += 1}
	// Grain: a streak along the board on one of its rows, broken in long pieces.
	if v == 1 + int(hash01(seed ~ 3, course, 0) * 1.99) &&
	   noise(seed ~ 4, x, course, 3, 4) > 0.55 {
		s -= 1
	}
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
