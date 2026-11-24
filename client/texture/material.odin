package texture

// The materials with form: rock and what is cut or gathered from it, soil,
// sand, wood. Each is a procedure of a pixel built from the toolkit, so it
// tiles as the toolkit does; a material's look is said in its comment, from
// what the real thing looks like.

// The rock, cobblestone and stone bricks are the kit's grey stone (kit_stone.odin).

// clay: smooth and fine, no grit to speak of, in soft bands where it settled.
@(private)
clay :: proc(seed: u32, x, y: int) -> Rgba {
	v := 0.15 + 0.45 * noise(seed, x, y, 2, 5) + 0.35 * noise(seed ~ 1, x, y, 4, 8)
	return pick(CLAY, v)
}

// gravel: pebbles packed together, each its own stone (grey, warm or pale) of one tone,
// lit along its top left, in shallow gaps a step darker.
@(private)
gravel :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 5)
	if c.d2 - c.d1 < 0.6 {return GRAVEL[1]}
	kind := hash01(c.id, 1, 0)
	ramp := GRAVEL_WARM if kind < 0.35 else GRAVEL
	s := 2 + int(kind > 0.8)
	if -(c.dx + c.dy) > 1.4 {s += 1} 	// the pebble's lit shoulder
	return step(ramp, s)
}

// bedrock: dark, coarse and blocky, deeply cracked between its blocks: the end of the
// world.
@(private)
bedrock :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 4)
	if c.d2 - c.d1 < 0.9 {return BEDROCK[0]}
	s := 1 + int(hash01(c.id, 0, 0) > 0.55)
	if -(c.dx + c.dy) > 1.6 {s += 1}
	return step(BEDROCK, s)
}

// ore: stone with nuggets of a mineral in it (of the n by n places, the share
// chance hold one, of about radius pixels), each lit at its top left, set in
// a rim of darker stone. The stone is stone's own, so ore and stone meet
// without a seam. inside: the pixel is the mineral's.
@(private)
ore :: proc(ramp: Ramp, seed: u32, x, y, n: int, radius, chance: f32) -> (c: Rgba, inside: bool) {
	return ore_in(STONE_ROCK, .Stone, ramp, seed, x, y, n, radius, chance)
}

// ore_in: ore as `ore` draws it, set in another rock (host, drawn by its own generator's
// seed so ore and rock meet without a seam). A nugget is two tones, its top left lit.
@(private)
ore_in :: proc(
	host: Rock,
	host_generator: Generator,
	ramp: Ramp,
	seed: u32,
	x, y, n: int,
	radius, chance: f32,
) -> (
	c: Rgba,
	inside: bool,
) {
	cell := cells(seed ~ 9, x, y, n)
	r := radius * (0.75 + 0.5 * hash01(cell.id, 2, 0))
	d := cell.d1 + 0.9 * (noise(seed ~ 11, x, y, 8, 8) - 0.5) // ragged, not round
	present := hash01(cell.id, 3, 0) < chance
	if present && d < r {
		lit := -(cell.dx + cell.dy) > 0.35 * r
		shade := cell.dx + cell.dy > 0.6 * r
		return step(ramp, 2 + int(lit) - int(shade)), true
	}
	if present && d < r + 0.6 {return host.ramp[1], false}
	return rough(host, seed_of(host_generator), x, y), false
}

// dirt: crumbly earth: soft patches of two browns with a few clods in them, each a
// round lump lit on top with a step of shadow at its foot.
@(private)
dirt :: proc(seed: u32, x, y: int) -> Rgba {
	s := 2 - int(fbm(seed, x, y, 4, 2) < 0.36)
	c := cells(seed ~ 2, x, y, 4)
	if hash01(c.id, 0, 0) > 0.5 {
		lean := c.dx + c.dy
		if c.d1 < 1.5 {return step(DIRT, 3 if lean < 0.6 else 2)} 	// the clod
		if c.d1 < 2.3 && lean > 1.2 {return step(DIRT, s - 1)} 	// its shadow
	}
	return step(DIRT, s)
}

// sandstone_side: sand turned to stone in beds: layers of their own tones,
// their boundaries wavering, a darker bedding plane under each.
@(private)
sandstone_side :: proc(seed: u32, x, y: int) -> Rgba {
	wobble := int(1.8 * noise(seed, x, 0, 3, 1))
	row := wrap(y + wobble)
	layer := row / 4
	s := 1 + int(hash01(seed ~ 1, layer, 0) * 2.99)
	switch row % 4 {
	case 3:
		s -= 1 // the bedding plane under the layer
	case 0:
		s += 1 // the layer's top, lit
	}
	if hash01(seed ~ 2, x, y) > 0.985 {s -= 1}
	return step(SANDSTONE, s)
}

// (Bark, a log's cut end and planks are the kit's: kit_wood.odin.)

// grain: wood's grain along x: long streaks a pixel high.
@(private)
grain :: proc(seed: u32, x, y: int) -> f32 {
	return noise(seed ~ 0x7f4a_7c15, x, y, 2, 16)
}
