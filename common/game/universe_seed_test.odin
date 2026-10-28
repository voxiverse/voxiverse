package game

import "core:slice"
import "core:testing"

@(test)
test_seed_glyphs_golden :: proc(t: ^testing.T) {
	Case :: struct {
		seed: u64,
		dir:  string,
	}
	cases := []Case {
		{0, "14020627220d101b-1e140e1213070f"},
		{1, "09141e0b170f0e0d-0c1a031d010f22"},
		{42, "0b2522090a231011-0e091c20171a12"},
		{0xdead_beef, "190b18140a101d1b-261d0021161325"},
		{0xffff_ffff_ffff_ffff, "1b12030d16061d23-2425060317051a"},
	}
	for c in cases {
		a := seed_glyphs(c.seed)
		testing.expect(t, address_valid(a))
		testing.expect_value(t, address_dir(a), c.dir)
	}
}

@(test)
test_seed_of_text :: proc(t: ^testing.T) {
	_, ok := seed_of_text("  ")
	testing.expect(t, !ok)
	n, _ := seed_of_text(" 42 ")
	testing.expect_value(t, n, 42)
	// Text is hashed (FNV-1a 64 of the UTF-8 bytes): "a" is a known value.
	a, ok_a := seed_of_text("a")
	testing.expect(t, ok_a)
	testing.expect_value(t, a, 0xaf63_dc4c_8601_ec8c)
	b, _ := seed_of_text("a")
	testing.expect_value(t, b, a)
	// A typed seed has the glyphs of the number it means.
	testing.expect_value(t, seed_glyphs(n), seed_glyphs(42))
}

@(test)
test_galaxy_stars :: proc(t: ^testing.T) {
	a := seed_glyphs(7)
	one, two: [400]Star
	galaxy_stars(a, one[:])
	galaxy_stars(a, two[:])
	testing.expect(t, one == two, "deterministic")
	testing.expect(t, one[0].home)
	for s in one[1:] {testing.expect(t, !s.home)}
	// Another world in the same galaxy: the same stars but the home one.
	b := a
	b.world = seed_glyphs(8).world
	other: [400]Star
	galaxy_stars(b, other[:])
	testing.expect(t, slice.equal(one[1:], other[1:]))
	testing.expect(t, one[0].position != other[0].position)
	// Another galaxy: other stars.
	c := seed_glyphs(9)
	different: [400]Star
	galaxy_stars(c, different[:])
	testing.expect(t, !slice.equal(one[1:], different[1:]))
	for s in one {
		testing.expect(t, s.position.x >= 0 && s.position.x <= 1)
		testing.expect(t, s.position.y >= 0 && s.position.y <= 1)
		testing.expect(t, s.color < STAR_COLORS)
	}
}
