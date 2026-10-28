package game

import "core:hash"
import "core:strconv"
import "core:strings"

// A universe's seed as the player sees it (docs/milestones/M48e.md, history.md): its
// home world's gate address, shown as glyphs, and the galaxy around it as a
// set of stars. Both are pure functions of the seed (state, not free: the
// seed to address mapping is the one the server saves a universe under).

// seed_glyphs: the gate address of a universe's home world. It is
// address_derive, the mapping the server has always used for the home
// world (a golden test pins five seeds), so a typed seed shows exactly the
// address the universe will have.
seed_glyphs :: proc(seed: u64) -> Address {
	return address_derive(seed)
}

// seed_of_text: what a typed seed means: a number is the seed itself,
// other text is hashed (FNV-1a 64 of its UTF-8 bytes); empty text is no
// seed (ok false: Roll).
seed_of_text :: proc(text: string) -> (seed: u64, ok: bool) {
	t := strings.trim_space(text)
	if t == "" {return 0, false}
	if n, is_number := strconv.parse_i64(t); is_number {return u64(n), true}
	return hash.fnv64a(transmute([]u8)t), true
}

// A galaxy's star: its place on a unit square, its size (0 ..< 1) and its
// colour (an index into STAR_COLORS).
Star :: struct {
	position: [2]f32,
	size:     f32,
	color:    u8,
	home:     bool, // the home world's star (the first one, only)
}

STAR_COLORS :: 5

// galaxy_stars fills out with a galaxy as a point set, a pure function of the
// galaxy's symbols (the first star is the home world's, placed by the
// world's symbols, and marked; the rest do not depend on the world).
galaxy_stars :: proc(a: Address, out: []Star) {
	if len(out) == 0 {return}
	g, w := a.galaxy, a.world
	state := u64(0xcbf2_9ce4_8422_2325)
	for s in g {state = (state ~ u64(s)) * 0x100_0000_01b3}
	next :: proc(state: ^u64) -> f32 {
		state^ += 0x9e37_79b9_7f4a_7c15
		z := state^
		z = (z ~ (z >> 30)) * 0xbf58_476d_1ce4_e5b9
		z = (z ~ (z >> 27)) * 0x94d0_49bb_1331_11eb
		z ~= z >> 31
		return f32(z >> 40) / f32(1 << 24)
	}
	for &star in out[1:] {
		// A disc denser in the middle, like a galaxy seen from above.
		angle := next(&state) * 6.2831853
		radius := next(&state)
		radius = radius * radius * 0.48 + 0.02
		spin := radius * 3.0 // the arms
		x := 0.5 + radius * cos_approx(angle + spin)
		y := 0.5 + radius * sin_approx(angle + spin)
		star = {
			position = {x, y},
			size     = next(&state),
			color    = u8(next(&state) * STAR_COLORS) % STAR_COLORS,
		}
	}
	home := u64(0x9e37_79b9_7f4a_7c15)
	for s in w {home = (home ~ u64(s)) * 0x100_0000_01b3}
	angle := next(&home) * 6.2831853
	radius := 0.1 + next(&home) * 0.3
	out[0] = {
		position = {0.5 + radius * cos_approx(angle), 0.5 + radius * sin_approx(angle)},
		size     = 1,
		color    = 0,
		home     = true,
	}
}

// sin_approx and cos_approx: a parabola-based sine (error under 0.002),
// the same on every machine (no libm's last bits in a golden test).
@(private = "file")
sin_approx :: proc(x: f32) -> f32 {
	TAU :: f32(6.2831853)
	t := x - TAU * f32(int(x / TAU)) // 0 ..< TAU for x >= 0
	if t < 0 {t += TAU}
	if t > TAU / 2 {t -= TAU} 	// -PI ..< PI
	y := 1.27323954 * t - 0.405284735 * t * abs(t)
	return 0.225 * (y * abs(y) - y) + y
}

@(private = "file")
cos_approx :: proc(x: f32) -> f32 {
	return sin_approx(x + 1.5707963)
}
