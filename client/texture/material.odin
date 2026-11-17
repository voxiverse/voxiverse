package texture

import "core:math"

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

// gravel: small pebbles packed together, each its own stone (grey, warm or
// pale), lit at its top left, dark gaps between.
@(private)
gravel :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 6)
	if c.d2 - c.d1 < 0.55 {return GRAVEL[0]}
	kind := hash01(c.id, 1, 0)
	ramp := GRAVEL_WARM if kind < 0.35 else GRAVEL
	v := 0.25 + 0.45 * hash01(c.id, 0, 0) - 0.16 * (c.dx + c.dy)
	if kind > 0.85 {v += 0.25}
	return pick(ramp, v + 0.1 * (hash01(seed ~ 1, x, y) - 0.5))
}

// bedrock: dark, coarse, blocky and deeply cracked: the end of the world.
@(private)
bedrock :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 4)
	if c.d2 - c.d1 < 0.9 {return BEDROCK[0]}
	v :=
		0.2 +
		0.5 * hash01(c.id, 0, 0) -
		0.12 * (c.dx + c.dy) +
		0.2 * (hash01(seed ~ 1, x, y) - 0.5)
	return pick(BEDROCK, v)
}

// ore: stone with nuggets of a mineral in it (of the n by n places, the share
// chance hold one, of about radius pixels), each lit at its top left, set in
// a rim of darker stone. The stone is stone's own, so ore and stone meet
// without a seam. inside: the pixel is the mineral's.
@(private)
ore :: proc(ramp: Ramp, seed: u32, x, y, n: int, radius, chance: f32) -> (c: Rgba, inside: bool) {
	cell := cells(seed ~ 9, x, y, n)
	r := radius * (0.75 + 0.5 * hash01(cell.id, 2, 0))
	d := cell.d1 + 0.9 * (noise(seed ~ 11, x, y, 8, 8) - 0.5) // ragged, not round
	present := hash01(cell.id, 3, 0) < chance
	if present && d < r {
		v := 0.5 + 0.4 * clamp(-(cell.dx + cell.dy) / (r + 0.5), -1, 1)
		return pick(ramp, v + 0.15 * (hash01(seed, x, y) - 0.5)), true
	}
	if present && d < r + 0.6 {return STONE[0], false}
	return rough(STONE_ROCK, seed_of(.Stone), x, y), false
}

// dirt: crumbly earth in clumps of a few tones, a small stone in it here
// and there.
@(private)
dirt :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed ~ 2, x, y, 4)
	if c.d1 < 1.0 && hash01(c.id, 0, 0) > 0.6 {
		return DIRT[4] if c.dx + c.dy < 0 else GRAVEL_WARM[2]
	}
	v := 0.15 + 0.6 * fbm(seed, x, y, 4, 3) + 0.3 * (hash01(seed ~ 1, x, y) - 0.5)
	return pick(DIRT, v)
}

// grass: a turf of short blades, each a stroke two pixels long, light at
// its tip, over patches of darker and lighter growth.
@(private)
grass :: proc(seed: u32, x, y: int) -> Rgba {
	shift := int(hash01(seed ~ 1, x, 0) * 16)
	blade := hash01(seed, x, wrap(y + shift) / 2)
	tip: f32 = 0.1 if wrap(y + shift) % 2 == 0 else -0.05
	v := 0.1 + 0.4 * fbm(seed ~ 2, x, y, 2, 3) + 0.4 * blade + tip
	return pick(GRASS, v)
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
	if hash01(seed ~ 2, x, y) > 0.95 {s -= 1}
	return step(SANDSTONE, s)
}

// (Bark is the kit's, bark_of: kit_wood.odin.)

// rings: a log's cut end: growth rings round the pith, wavering, a dark
// line of cambium, then the bark.
@(private)
rings :: proc(seed: u32, x, y: int) -> Rgba {
	dx, dy := f32(x) - 7.5, f32(y) - 7.5
	r := math.sqrt(dx * dx + dy * dy)
	if r >= 6.9 {return pick(BARK, 0.3 + 0.5 * hash01(seed ~ 1, x, y))}
	if r >= 6.2 {return BARK[0]}
	ring := r + 0.9 * noise(seed, x, y, 4, 4)
	if r < 1 {return WOOD[1]} 	// the pith
	v: f32 = 0.6 if int(ring * 0.9) % 2 == 0 else 0.35
	return pick(WOOD, v + 0.15 * (hash01(seed ~ 2, x, y) - 0.5))
}

// grain: wood's grain along x: long streaks a pixel high.
@(private)
grain :: proc(seed: u32, x, y: int) -> f32 {
	return noise(seed ~ 0x7f4a_7c15, x, y, 2, 16)
}

// plank: boards four pixels wide, one end joint each, staggered, every board
// its own tone with the grain along it, lit along its top edge.
@(private)
plank :: proc(seed: u32, x, y: int) -> Rgba {
	course := wrap(y) / 4
	joint := int(hash01(seed ~ 1, course, 0) * 16)
	b := brick(x - joint, y, SIZE, 4)
	if b.joint {return WOOD[0]} 	// (the end joint and the gap below the board)
	v := 0.35 + 0.25 * hash01(seed ~ 2, course, 0) + 0.45 * (grain(seed, x, y) - 0.5)
	v += 0.15 * bevel(b.u, b.v, SIZE - 1, 3)
	return pick(WOOD, v + 0.08 * (hash01(seed ~ 3, x, y) - 0.5))
}
