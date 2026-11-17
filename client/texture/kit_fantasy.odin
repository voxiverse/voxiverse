package texture

// Fantasy and dungeon: dark dungeon brick, stone brick overgrown with moss, a stone slab
// with a glowing rune, bone, crystal and magma that glow, and obsidian.

@(private, rodata)
DUNGEON := Ramp {
	{26, 24, 34, 255},
	{40, 37, 50, 255},
	{56, 52, 66, 255},
	{74, 70, 84, 255},
	{98, 92, 104, 255},
}
@(private, rodata)
RUNE_GLOW := Ramp {
	{20, 60, 76, 255},
	{40, 120, 140, 255},
	{70, 180, 196, 255},
	{130, 226, 232, 255},
	{210, 250, 250, 255},
}
@(private, rodata)
BONE := Ramp {
	{124, 112, 90, 255},
	{166, 154, 126, 255},
	{198, 188, 160, 255},
	{220, 212, 188, 255},
	{240, 234, 214, 255},
}
@(private, rodata)
CRYSTAL := Ramp {
	{56, 30, 88, 255},
	{92, 52, 138, 255},
	{134, 82, 188, 255},
	{178, 126, 226, 255},
	{228, 198, 250, 255},
}
@(private, rodata)
LAVA := Ramp {
	{122, 30, 12, 255},
	{188, 62, 16, 255},
	{228, 106, 24, 255},
	{246, 162, 48, 255},
	{255, 222, 124, 255},
}
@(private, rodata)
CRUST := Ramp {
	{20, 16, 18, 255},
	{36, 28, 28, 255},
	{52, 40, 38, 255},
	{70, 54, 48, 255},
	{92, 70, 60, 255},
}
@(private, rodata)
OBSIDIAN := Ramp {
	{12, 10, 18, 255},
	{22, 18, 32, 255},
	{34, 28, 48, 255},
	{54, 46, 74, 255},
	{100, 88, 128, 255},
}

// (Not rodata: made from the ramps, which are variables.)
@(private)
DUNGEON_ROCK := Rock{DUNGEON, {14, 13, 19, 255}, .Speckled}

// RUNE: the rune carved in a rune stone, 8 by 10 pixels: an angular sigil.
@(private, rodata)
RUNE := [10]string {
	"...##...",
	"..#..#..",
	".#.##.#.",
	"#..##..#",
	"...##...",
	"...##...",
	"#..##..#",
	".#.##.#.",
	"..#..#..",
	"...##...",
}

// mossy_bricks: stone bricks overgrown: moss along the tops of the bricks and in their
// joints, hanging down a pixel or two here and there.
@(private)
mossy_bricks :: proc(seed: u32, x, y: int) -> Rgba {
	course := wrap(y) / 4
	b := brick(x + (course % 2) * 4, y, 8, 4)
	growth := noise(seed ~ 1, x, y, 4, 4)
	if growth > 0.42 {
		if b.joint && b.v == 3 {return MOSS[1] if growth > 0.5 else MOSS[0]}
		if b.v == 0 {return MOSS[3] if growth > 0.55 else MOSS[2]}
		// Strands hanging from the moss above.
		if b.v == 1 && hash01(seed ~ 2, x, course) > 0.6 {return MOSS[1]}
	}
	return bricks(STONE_ROCK, seed, x, y, 8, 4)
}

// rune_stone: a dark polished slab with a rune carved in it that glows: the groove dark
// round the light.
@(private)
rune_stone :: proc(seed: u32, x, y: int) -> Rgba {
	u, v := wrap(x) - 4, wrap(y) - 3
	carved :: proc(u, v: int) -> bool {
		if u < 0 || u >= 8 || v < 0 || v >= 10 {return false}
		line := RUNE[v]
		return line[u] == '#'
	}
	if carved(u, v) {return RUNE_GLOW[3] if (u + v) % 3 != 0 else RUNE_GLOW[4]}
	// The groove's edge: the light spilling just round it.
	near := carved(u - 1, v) || carved(u + 1, v) || carved(u, v - 1) || carved(u, v + 1)
	if near {return RUNE_GLOW[0]}
	return polished(DUNGEON_ROCK, seed, x, y)
}

// bone: bones laid in rows, each a shaft with a knob at each end, lit along its top, in
// the dark between.
@(private)
bone :: proc(seed: u32, x, y: int) -> Rgba {
	course := wrap(y) / 4
	v := wrap(y) % 4
	u := wrap(x + int(hash01(seed ~ 1, course, 0) * 16))
	end := u % 8 // a bone eight pixels long
	knob := end == 0 || end == 1 || end == 6 || end == 7
	if end == 7 && v != 1 && v != 2 {return BONE[0]}
	if !knob && (v == 0 || v == 3) {return BONE[0]} 	// the gap round a shaft
	s := 2
	if v == 0 || (v == 1 && !knob) {s = 4}
	if v == 3 || (v == 2 && !knob) {s = 1}
	if knob && v == 1 {s = 3}
	if hash01(seed ~ 2, x, y) > 0.94 {s -= 1}
	return step(BONE, s)
}

// crystal: a mass of crystal faces: each facet flat, bright at its top left, dark at its
// foot, its edges lines of light, a glint here and there.
@(private)
crystal :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 3)
	if c.d2 - c.d1 < 0.7 {return CRYSTAL[4]}
	lean := -(c.dx + c.dy) / 3
	s := 1 + int(hash01(c.id, 0, 0) * 1.99)
	if lean > 0.3 {s += 1}
	if lean < -0.4 {s -= 1}
	if hash01(seed ~ 1, x, y) > 0.97 {s = 4}
	return step(CRYSTAL, s)
}

// magma: a dark crust broken into plates over molten rock that glows in the cracks, hotter
// in their middle.
@(private)
magma :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 3)
	gap := c.d2 - c.d1
	if gap < 0.5 {return LAVA[4]}
	if gap < 1.0 {return LAVA[2]}
	if gap < 1.4 {return LAVA[0]}
	lean := -(c.dx + c.dy) / 3
	s := 1 + int(hash01(c.id, 0, 0) > 0.5)
	if lean > 0.4 {s += 1}
	if hash01(seed ~ 1, x, y) > 0.95 {return LAVA[0]} 	// a glow through a pore
	return step(CRUST, s)
}

// obsidian: volcanic glass: broad dark facets broken in shells, their edges catching
// sharp light, a glint here and there.
@(private)
obsidian :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 2)
	lean := -(c.dx + c.dy) / 5
	if c.d2 - c.d1 < 0.8 {return OBSIDIAN[3] if lean > 0 else OBSIDIAN[0]}
	s := 1 + int(hash01(c.id, 0, 0) > 0.5)
	if lean > 0.6 {s += 1}
	if hash01(seed ~ 1, x, y) > 0.975 {s = 4}
	return step(OBSIDIAN, s)
}
