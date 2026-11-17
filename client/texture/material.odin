package texture

import "core:math"

// The materials with form: rock and what is cut or gathered from it, soil,
// sand, wood. Each is a procedure of a pixel built from the toolkit, so it
// tiles as the toolkit does; a material's look is said in its comment, from
// what the real thing looks like.

// rock: broad patches of tone (fbm, dithered between the ramp's steps), a
// hairline crack along some of the borders between cells, and here and
// there a grain of quartz or a dark one.
@(private)
rock :: proc(ramp: Ramp, seed: u32, x, y: int) -> Rgba {
	grit := hash01(seed ~ 4, x, y)
	if grit > 0.975 {return ramp[4]}
	if grit < 0.02 {return ramp[0]}
	v := 0.18 + 0.64 * fbm(seed, x, y, 2, 4) + 0.12 * (hash01(seed ~ 1, x, y) - 0.5)
	c := cells(seed ~ 2, x, y, 3)
	if c.d2 - c.d1 < 0.8 && noise(seed ~ 3, x, y, 4, 4) > 0.55 {v -= 0.3}
	return dither(ramp, v, x, y)
}

// clay: smooth and fine, no grit to speak of, in soft bands where it settled.
@(private)
clay :: proc(seed: u32, x, y: int) -> Rgba {
	v := 0.15 + 0.45 * noise(seed, x, y, 2, 5) + 0.35 * noise(seed ~ 1, x, y, 4, 8)
	v += 0.08 * (hash01(seed ~ 2, x, y) - 0.5)
	return dither(CLAY, v, x, y)
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

// cobble: rounded stones of their own tones set in dark mortar, each lit at
// its top left and shaded towards its rim.
@(private)
cobble :: proc(seed: u32, x, y: int) -> Rgba {
	c := cells(seed, x, y, 3)
	gap := c.d2 - c.d1
	if gap < 1.0 {return STONE[0]}
	v := 0.3 + 0.4 * hash01(c.id, 0, 0) + 0.2 * clamp(-(c.dx + c.dy) / 5, -1, 1)
	if gap < 1.9 {v -= 0.18}
	return dither(STONE, v + 0.1 * (hash01(seed ~ 1, x, y) - 0.5), x, y)
}

// stone_brick: dressed blocks of stone in a running bond, each a tone of its
// own with its top and left edges lit, its bottom and right shaded, a chip
// out of an edge here and there.
@(private)
stone_brick :: proc(seed: u32, x, y: int) -> Rgba {
	course := wrap(y) / 4
	b := brick(x + course * 4, y, 8, 4)
	if b.joint {return STONE[0]}
	edge := bevel(b.u, b.v, 7, 3)
	v := 0.35 + 0.3 * hash01(seed ~ 1, b.index, course) + 0.22 * edge
	v += 0.3 * (fbm(seed ~ 2, x, y, 4, 2) - 0.5)
	if edge != 0 && hash01(seed ~ 3, x, y) > 0.88 {v -= 0.35}
	return dither(STONE, v, x, y)
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
	return rock(STONE, seed_of(.Stone), x, y), false
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

// sand: fine grains of a few tones, a dark or a pale one here and there,
// over faint ripples the wind left.
@(private)
sand :: proc(seed: u32, x, y: int) -> Rgba {
	grit := hash01(seed ~ 1, x, y)
	if grit > 0.96 {return SAND[0]}
	if grit < 0.03 {return SAND[4]}
	v := 0.3 + 0.3 * noise(seed, x + y / 2, y, 2, 5) + 0.4 * (hash01(seed ~ 2, x, y) - 0.5)
	return dither(SAND, v + 0.15, x, y)
}

// sandstone_side: sand turned to stone in beds: layers of their own tones,
// their boundaries wavering, a darker bedding plane under each.
@(private)
sandstone_side :: proc(seed: u32, x, y: int) -> Rgba {
	wobble := int(1.8 * noise(seed, x, 0, 3, 1))
	row := wrap(y + wobble)
	layer := row / 4
	v := 0.3 + 0.35 * hash01(seed ~ 1, layer, 0) + 0.2 * (hash01(seed ~ 2, x, y) - 0.5)
	v += 0.15 * (noise(seed ~ 3, x, y, 8, 4) - 0.5)
	switch row % 4 {
	case 3:
		v -= 0.3
	case 0:
		v += 0.12
	}
	return dither(SANDSTONE, v, x, y)
}

// bark: ridges running up the trunk, n across, broken every so often (breaks
// down it), deep furrows between them, each ridge's left side catching the
// light.
@(private)
bark :: proc(ramp: Ramp, seed: u32, x, y, n, breaks: int) -> Rgba {
	ridge_at :: proc(seed: u32, x, y, n, breaks: int) -> f32 {
		return 0.65 * noise(seed, x, y, n, 1) + 0.35 * noise(seed ~ 5, x, y, n, breaks)
	}
	ridge := ridge_at(seed, x, y, n, breaks)
	if ridge < 0.3 {return ramp[0]} 	// a furrow
	v := 0.1 + 0.8 * ridge + 0.2 * (hash01(seed ~ 1, x, y) - 0.5)
	if ridge_at(seed, x - 1, y, n, breaks) < ridge - 0.06 {v += 0.2}
	return pick(ramp, v)
}

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
