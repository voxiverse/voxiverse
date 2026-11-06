package planet

import "common:base"
import "common:game"
import "core:math"

// Other worlds' relief by plate tectonics, on Earth's 2048 x 1024 grid so `planet_build`
// runs on it unchanged. The sphere is cut into plates (8 to 20 seeded points, each plate
// continental or oceanic, each turning about a pole); the boundaries get their features from
// the plates' relative motion (ranges, trenches, island arcs, ridges, rifts, faults); the
// elevation is the crust's (+400 m or -4 000 m) plus those features plus some roughness, then
// eroded a few passes, and the sea level is set so the land is the address's share of the
// planet. Deterministic: only `base` trigonometry, multiplications and a seeded stream.

EARTH_RADIUS_KM :: 6371.0
CONTINENT_BASE :: 400.0 // metres
OCEAN_BASE :: -4000.0
FEATURE_REACH_KM :: 420.0 // how far a boundary's features reach
PROFILE_STEP_KM :: 5.0
EROSION_PASSES :: 6

// Character is what an address decides about its world's relief.
Character :: struct {
	land_fraction: f64, // share of the planet's area above the sea
	plates:        int, // 8 to 20
	mountains:     f64, // scale of the ranges: 1 is Earth-like
}

// relief_character: the kind of relief an address has, from the address alone.
relief_character :: proc(a: game.Address) -> Character {
	r := base.rng_make(game.address_hash(a) ~ 0x7ec7_0a1c_5eed_0001)
	return Character {
		land_fraction = base.rng_f64_range(&r, 0.15, 0.55),
		plates = base.rng_int_range(&r, 8, 21),
		mountains = base.rng_f64_range(&r, 0.6, 1.5),
	}
}

// relief_is_home: whether the address is the universe's home world, Earth.
relief_is_home :: proc(a: game.Address, seed: u64) -> bool {
	return a == game.address_derive(seed)
}

// relief_for_world is the relief of the world at an address: Earth's own (decoded from the
// committed file `earth_file`) for the home world, a generated one for any other. A home
// world whose file does not load is generated like the others.
relief_for_world :: proc(
	a: game.Address,
	seed: u64,
	earth_file: []u8,
	allocator := context.allocator,
) -> Relief {
	if relief_is_home(a, seed) {
		if r, ok := relief_decode(earth_file, allocator); ok {return r}
	}
	return relief_generate(a, seed, allocator)
}

@(private = "file")
Plate :: struct {
	seed:        [3]f64, // a point on the sphere
	pole:        [3]f64, // the axis it turns about, times its rate
	continental: bool,
}

@(private = "file")
Boundary_Kind :: enum {
	Transform,
	Cont_Cont_Converge,
	Ocean_Cont_Converge, // the ocean on the negative side
	Ocean_Ocean_Converge, // the island arc on the positive side
	Cont_Cont_Diverge,
	Ocean_Diverge, // a ridge, whatever is on either side
}

@(private = "file")
PROFILE_N :: int(FEATURE_REACH_KM / PROFILE_STEP_KM) * 2 + 1

// A profile is a boundary kind's feature along the signed distance from it (the negative side
// first), in metres at the strength of 1: what rises, and what sinks.
@(private = "file")
Profile :: struct {
	up, down: [PROFILE_N]f32,
}

@(private = "file")
gauss :: proc(d, centre, width: f64) -> f64 {
	x := (d - centre) / width
	return base.exp(-x * x)
}

@(private = "file")
profile_build :: proc(kind: Boundary_Kind) -> Profile {
	p: Profile
	half := PROFILE_N / 2
	for n in 0 ..< PROFILE_N {
		s := f64(n - half) * PROFILE_STEP_KM
		d := abs(s)
		neg := s < 0
		up, down := 0.0, 0.0
		switch kind {
		case .Transform:
			down = -300 * gauss(d, 0, 20)
		case .Cont_Cont_Converge:
			up = 5500 * gauss(d, 0, 180)
		case .Ocean_Cont_Converge:
			if neg {
				down = -3500 * gauss(d, 40, 70)
			} else {
				up = 4200 * gauss(d, 180, 110)
			}
		case .Ocean_Ocean_Converge:
			if neg {
				down = -3000 * gauss(d, 30, 60)
			} else {
				up = 4600 * gauss(d, 120, 45)
			}
		case .Cont_Cont_Diverge:
			down = -1000 * gauss(d, 0, 50)
			up = 700 * gauss(d, 150, 90)
		case .Ocean_Diverge:
			up = 1500 * gauss(d, 0, 260)
		}
		p.up[n] = f32(up)
		p.down[n] = f32(down)
	}
	return p
}

// noise3 is value noise on the integer lattice, in -1..1.
@(private = "file")
noise3 :: proc(x, y, z: f64, salt: u64) -> f64 {
	lattice :: proc(ix, iy, iz: int, salt: u64) -> f64 {
		h :=
			u64(ix) * 0x9e37_79b9_7f4a_7c15 ~
			u64(iy) * 0xbf58_476d_1ce4_e5b9 ~
			u64(iz) * 0x94d0_49bb_1331_11eb ~
			salt
		h ~= h >> 31
		h *= 0xd6e8_feb8_6659_fd93
		h ~= h >> 32
		h *= 0xd6e8_feb8_6659_fd93
		h ~= h >> 32
		return f64(h >> 11) / f64(1 << 52) - 1
	}
	fx, fy, fz := math.floor(x), math.floor(y), math.floor(z)
	ix, iy, iz := int(fx), int(fy), int(fz)
	tx, ty, tz := x - fx, y - fy, z - fz
	tx, ty, tz = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty), tz * tz * (3 - 2 * tz)
	mix :: proc(a, b, t: f64) -> f64 {return a + (b - a) * t}
	c00 := mix(lattice(ix, iy, iz, salt), lattice(ix + 1, iy, iz, salt), tx)
	c10 := mix(lattice(ix, iy + 1, iz, salt), lattice(ix + 1, iy + 1, iz, salt), tx)
	c01 := mix(lattice(ix, iy, iz + 1, salt), lattice(ix + 1, iy, iz + 1, salt), tx)
	c11 := mix(lattice(ix, iy + 1, iz + 1, salt), lattice(ix + 1, iy + 1, iz + 1, salt), tx)
	return mix(mix(c00, c10, ty), mix(c01, c11, ty), tz)
}

@(private = "file")
dot3 :: proc(a, b: [3]f64) -> f64 {return a.x * b.x + a.y * b.y + a.z * b.z}

@(private = "file")
cross3 :: proc(a, b: [3]f64) -> [3]f64 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

@(private = "file")
unit3 :: proc(a: [3]f64) -> [3]f64 {
	n := math.sqrt(dot3(a, a))
	if n == 0 {return {0, 0, 1}}
	return a / n
}

// relief_generate makes the relief of a world that is not Earth: the same address and seed,
// the same relief, on every OS.
//
// `convergent`, when given, gets a point (a unit vector) for each convergent boundary cell
// edge: the places the ranges stand on, for the tests.
relief_generate :: proc(
	a: game.Address,
	seed: u64,
	allocator := context.allocator,
	convergent: ^[dynamic][3]f64 = nil,
) -> Relief {
	w, h := RELIEF_WIDTH, RELIEF_HEIGHT
	n := w * h
	ch := relief_character(a)
	rng := base.rng_make(
		game.address_hash(a) ~ seed * 0x9e37_79b9_7f4a_7c15 ~ 0x7ec7_0a1c_0000_0002,
	)
	salt := base.rng_u64(&rng)

	// The unit vector of every cell, from a table of the columns' and rows' angles.
	col_cos, col_sin :=
		make([]f64, w, context.temp_allocator), make([]f64, w, context.temp_allocator)
	row_cos, row_sin :=
		make([]f64, h, context.temp_allocator), make([]f64, h, context.temp_allocator)
	row_weight := make([]f64, h, context.temp_allocator)
	for i in 0 ..< w {
		lon := (-180 + (f64(i) + 0.5) * 360 / f64(w)) * PI / 180
		col_cos[i], col_sin[i] = base.cos(lon), base.sin(lon)
	}
	for j in 0 ..< h {
		lat := (90 - (f64(j) + 0.5) * 180 / f64(h)) * PI / 180
		row_cos[j], row_sin[j] = base.cos(lat), base.sin(lat)
		row_weight[j] = row_cos[j]
	}
	cell_vec :: proc(i, j: int, cc, cs, rc, rs: []f64) -> [3]f64 {
		return {rc[j] * cc[i], rc[j] * cs[i], rs[j]}
	}

	// Plates: seeds uniform on the sphere (so the cylinder's cells count by cos latitude).
	plates := make([]Plate, ch.plates, context.temp_allocator)
	for &p in plates {
		p.seed = random_unit(&rng)
		p.pole = random_unit(&rng) * base.rng_f64_range(&rng, 0.2, 1.0)
	}

	// Every cell's plate: the nearest seed, from a position bent by smooth noise so the
	// boundaries wander.
	plate_of := make([]u8, n, context.temp_allocator)
	area := make([]f64, ch.plates, context.temp_allocator)
	for j in 0 ..< h {
		for i in 0 ..< w {
			x := cell_vec(i, j, col_cos, col_sin, row_cos, row_sin)
			q := x * 2.2
			bent := unit3(
				x +
				{
						0.22 * noise3(q.x, q.y, q.z, salt),
						0.22 * noise3(q.x + 17, q.y, q.z, salt),
						0.22 * noise3(q.x, q.y + 31, q.z, salt),
					},
			)
			best, best_dot := 0, -2.0
			for p, k in plates {
				if d := dot3(bent, p.seed); d > best_dot {best, best_dot = k, d}
			}
			plate_of[j * w + i] = u8(best)
			area[best] += row_weight[j]
		}
	}
	total_weight := 0.0
	for j in 0 ..< h {total_weight += row_weight[j] * f64(w)}

	// Which plates are continental: in a seeded order, until their area is the land's share.
	order := make([]int, ch.plates, context.temp_allocator)
	for k in 0 ..< ch.plates {order[k] = k}
	for k := ch.plates - 1; k > 0; k -= 1 {
		m := base.rng_int_max(&rng, k + 1)
		order[k], order[m] = order[m], order[k]
	}
	taken := 0.0
	for k, idx in order {
		share := area[k] / total_weight
		if idx == 0 || taken + share / 2 <= ch.land_fraction {
			plates[k].continental = true
			taken += share
		}
	}

	// The crust: a smoothed indicator of the continental plates, so the coasts have shelves.
	crust := make([]f32, n, context.temp_allocator)
	for k in 0 ..< n {crust[k] = 1 if plates[plate_of[k]].continental else 0}
	box_blur(crust, w, h, 7)
	box_blur(crust, w, h, 7)
	elevation := make([]f32, n, context.temp_allocator)
	for k in 0 ..< n {
		c := f64(crust[k])
		c = c * c * (3 - 2 * c)
		elevation[k] = f32(OCEAN_BASE + (CONTINENT_BASE - OCEAN_BASE) * c)
	}

	// Boundaries: every cell edge between two plates, classified by the plates' relative
	// motion there, lays its kind's profile over the cells around it.
	profiles: [Boundary_Kind]Profile
	for kind in Boundary_Kind {profiles[kind] = profile_build(kind)}
	up := make([]f32, n, context.temp_allocator)
	down := make([]f32, n, context.temp_allocator)
	reach_rows := int(FEATURE_REACH_KM / (EARTH_RADIUS_KM * PI / f64(h))) + 1
	half := PROFILE_N / 2
	for j in 0 ..< h {
		for i in 0 ..< w {
			k := j * w + i
			if (i + j) & 1 != 0 {continue}
			for step in 0 ..< 2 {
				i2, j2 := (i + 1) % w, j
				if step == 1 {
					if j + 1 >= h {continue}
					i2, j2 = i, j + 1
				}
				pa, pb := plate_of[k], plate_of[j2 * w + i2]
				if pa == pb {continue}
				va := cell_vec(i, j, col_cos, col_sin, row_cos, row_sin)
				vb := cell_vec(i2, j2, col_cos, col_sin, row_cos, row_sin)
				mid := unit3(va + vb)
				dir := unit3(vb - va - mid * dot3(vb - va, mid)) // from a's side to b's
				rel := cross3(plates[pa].pole, mid) - cross3(plates[pb].pole, mid)
				closing := dot3(rel, dir)
				ca, cb := plates[pa].continental, plates[pb].continental
				kind: Boundary_Kind
				strength := 1.0
				flip := false
				switch {
				case closing > 0.15:
					if convergent != nil {append(convergent, mid)}
					strength = clamp(closing / 0.8, 0.3, 1.5)
					switch {
					case ca && cb:
						kind = .Cont_Cont_Converge
					case !ca && !cb:
						kind = .Ocean_Ocean_Converge
						flip = (i / 64 + j / 64 + int(pa)) & 1 != 0
					case:
						kind = .Ocean_Cont_Converge
						flip = ca // the ocean must be on the negative side
					}
				case closing < -0.15:
					strength = clamp(-closing / 0.8, 0.4, 1.2)
					kind = .Cont_Cont_Diverge if ca && cb else .Ocean_Diverge
				case:
					kind = .Transform
				}
				sign := -1.0 if flip else 1.0
				prof := &profiles[kind]
				// An arc is stronger in blocks along it: islands, not a wall.
				block := 1.0
				if kind == .Ocean_Ocean_Converge {
					bh :=
						u64(i / 4) * 0x9e37_79b9_7f4a_7c15 ~
						u64(j / 4) * 0xbf58_476d_1ce4_e5b9 ~
						salt
					bh ~= bh >> 29
					bh *= 0x94d0_49bb_1331_11eb
					block = 0.55 + 0.45 * f64(bh >> 40) / f64(1 << 24)
				}
				amp_up := strength * ch.mountains * block
				if kind != .Cont_Cont_Converge &&
				   kind != .Ocean_Cont_Converge &&
				   kind != .Ocean_Ocean_Converge {
					amp_up = strength
				}
				cols := min(int(f64(reach_rows) / max(row_cos[j], 0.02)) + 1, w / 2)
				for dj := -reach_rows; dj <= reach_rows; dj += 1 {
					jj := j + dj
					if jj < 0 || jj >= h {continue}
					for di := -cols; di <= cols; di += 1 {
						ii := ((i + di) % w + w) % w
						x := cell_vec(ii, jj, col_cos, col_sin, row_cos, row_sin)
						off := x - mid
						dist := math.sqrt(dot3(off, off)) * EARTH_RADIUS_KM
						if dist > FEATURE_REACH_KM {continue}
						side := dot3(off, dir) * sign
						signed := dist if side >= 0 else -dist
						bin := int(math.floor(signed / PROFILE_STEP_KM + 0.5)) + half
						bin = clamp(bin, 0, PROFILE_N - 1)
						cell := jj * w + ii
						u := prof.up[bin] * f32(amp_up)
						if u > up[cell] {up[cell] = u}
						d := prof.down[bin] * f32(strength)
						if d < down[cell] {down[cell] = d}
					}
				}
			}
		}
	}

	// Rough ground, and the features on the crust.
	for j in 0 ..< h {
		for i in 0 ..< w {
			k := j * w + i
			x := cell_vec(i, j, col_cos, col_sin, row_cos, row_sin)
			rough := 0.0
			amp, freq := 1.0, 3.0
			for o in 0 ..< 4 {
				rough += amp * noise3(x.x * freq, x.y * freq, x.z * freq, salt + u64(o) * 0x51ed)
				amp *= 0.5
				freq *= 2
			}
			elevation[k] += up[k] + down[k] + f32(rough * 250)
		}
	}

	erode(elevation, w, h)

	// The sea level that leaves the land its share of the planet.
	sea := sea_level_for(elevation, w, h, row_weight, ch.land_fraction)
	r := relief_make(w, h, allocator)
	for k in 0 ..< n {
		e := f64(elevation[k]) - sea
		v := int(math.floor(e))
		if e > 0 {v = max(v, 1)} else {v = min(v, -1)}
		r.elevation[k] = i16(clamp(v, -32000, 32000))
	}
	return r
}

@(private = "file")
random_unit :: proc(r: ^base.Rng) -> [3]f64 {
	z := base.rng_f64_range(r, -1, 1)
	lon := base.rng_f64_range(r, 0, 2 * PI)
	s := math.sqrt(1 - z * z)
	return {s * base.cos(lon), s * base.sin(lon), z}
}

// box_blur smooths a grid with a box of radius `radius` along the rows (longitude wraps),
// then along the columns (clamped).
@(private = "file")
box_blur :: proc(g: []f32, w, h, radius: int) {
	line := make([]f32, max(w, h), context.temp_allocator)
	scale := 1 / f32(2 * radius + 1)
	for j in 0 ..< h {
		sum := f32(0)
		for d in -radius ..= radius {sum += g[j * w + (d + w) % w]}
		for i in 0 ..< w {
			line[i] = sum * scale
			sum += g[j * w + (i + radius + 1) % w] - g[j * w + ((i - radius) % w + w) % w]
		}
		copy(g[j * w:j * w + w], line[:w])
	}
	for i in 0 ..< w {
		for j in 0 ..< h {
			sum := f32(0)
			for d in -radius ..= radius {sum += g[clamp(j + d, 0, h - 1) * w + i]}
			line[j] = sum * scale
		}
		for j in 0 ..< h {g[j * w + i] = line[j]}
	}
}

// erode diffuses the ground a few passes, the high ground faster (steeper, so it wears more).
@(private = "file")
erode :: proc(e: []f32, w, h: int) {
	next := make([]f32, len(e), context.temp_allocator)
	for _ in 0 ..< EROSION_PASSES {
		for j in 0 ..< h {
			for i in 0 ..< w {
				k := j * w + i
				v := e[k]
				mean :=
					(e[j * w + (i + 1) % w] +
						e[j * w + (i + w - 1) % w] +
						e[max(j - 1, 0) * w + i] +
						e[min(j + 1, h - 1) * w + i]) *
					0.25
				rate := 0.1 + 0.25 * clamp(v / 3000, 0, 1)
				next[k] = v + (mean - v) * rate
			}
		}
		copy(e, next)
	}
}

// sea_level_for is the elevation above which `fraction` of the planet's area lies.
@(private = "file")
sea_level_for :: proc(e: []f32, w, h: int, row_weight: []f64, fraction: f64) -> f64 {
	LO :: -16000
	HI :: 16000
	bins := make([]f64, HI - LO, context.temp_allocator)
	total := 0.0
	for j in 0 ..< h {
		for i in 0 ..< w {
			b := clamp(int(math.floor(f64(e[j * w + i]))) - LO, 0, HI - LO - 1)
			bins[b] += row_weight[j]
			total += row_weight[j]
		}
	}
	above := 0.0
	for b := HI - LO - 1; b >= 0; b -= 1 {
		above += bins[b]
		if above >= fraction * total {return f64(b + LO)}
	}
	return 0
}
