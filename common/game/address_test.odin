package game

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_addresses :: proc(t: ^testing.T) {
	// The counts the symbol lengths are sized by.
	perm :: proc(n, k: int) -> (p: f64) {
		p = 1
		for i in 0 ..< k {p *= f64(n - i)}
		return
	}
	galaxies, worlds := perm(SYMBOLS, GALAXY_LENGTH), perm(SYMBOLS, WORLD_LENGTH)
	testing.expectf(
		t,
		galaxies > 3e12 && worlds > 9e10 && galaxies * worlds > 2.8e23,
		"%v galaxies, %v worlds",
		galaxies,
		worlds,
	)
	home := address_derive(12345)
	testing.expect(t, address_valid(home))
	testing.expect(t, address_derive(12345) == home && address_derive(12346) != home)
	dir := address_dir(home)
	back, ok := address_parse(dir, {})
	testing.expect(t, ok && back == home, dir)
	text := address_text(home)
	back, ok = address_parse(text, {})
	testing.expect(t, ok && back == home, text)
	// Seven symbols: a world in the galaxy given.
	world_only := text[:len(text) - 1 - 4 * GALAXY_LENGTH]
	back, ok = address_parse(world_only, home.galaxy)
	testing.expect(t, ok && back == home, world_only)
	// A symbol twice, too few, not a symbol: not addresses.
	bad := home
	bad.world[1] = bad.world[0]
	testing.expect(t, !address_valid(bad))
	_, ok = address_parse("abc", {})
	testing.expect(t, !ok)
	testing.expect(t, address_hash(home) != address_hash(address_derive(1)))
	for r in SYMBOL_RUNES {testing.expect(t, r >= 0x10C00 && r <= 0x10C48)}
}

// Earth's address is valid and never changes: saves and terrain are named by it.
@(test)
test_earth_address :: proc(t: ^testing.T) {
	earth := earth_address()
	testing.expect(t, address_valid(earth))
	testing.expect_value(t, address_dir(earth), "031116051f091a0c-0e022314071d0b")
	back, ok := address_parse("031116051f091a0c-0e022314071d0b", {})
	testing.expect(t, ok && back == earth)
	testing.expect(t, address_derive(0) != earth && address_derive(1) != earth)
}


@(test)
test_motif_of_earth :: proc(t: ^testing.T) {
	m := motif_of(earth_address())
	// 14 2 35 20 7 29 11 are the degrees 1 3 1 7 1 2 5: C E C B C D G.
	pitches := [MOTIF_NOTES]u8{60, 64, 60, 59, 60, 62, 67}
	for n, i in m {
		testing.expectf(
			t,
			n.pitch == pitches[i],
			"note %d: pitch %d, want %d",
			i,
			n.pitch,
			pitches[i],
		)
	}
	// Eighths by glyph div 7 (2 0 5 2 1 4, then the long last note).
	want_len := [MOTIF_NOTES]u8{1, 2, 2, 1, 1, 1, MOTIF_LAST_LENGTH}
	acc := u16(0)
	for n, i in m {
		testing.expectf(
			t,
			n.length == want_len[i],
			"note %d: length %d, want %d",
			i,
			n.length,
			want_len[i],
		)
		testing.expectf(t, n.start == acc, "note %d: start %d, want %d", i, n.start, acc)
		acc += u16(n.length)
	}
	// Singable: at most an octave and a half, no leap over a sixth, the last note long.
	lo, hi := m[0].pitch, m[0].pitch
	for n, i in m {
		lo, hi = min(lo, n.pitch), max(hi, n.pitch)
		if i > 0 {
			leap := abs(int(n.pitch) - int(m[i - 1].pitch))
			testing.expectf(t, leap <= 9, "leap of %d semitones before note %d", leap, i)
		}
	}
	testing.expect(t, int(hi) - int(lo) <= 18)
	testing.expect(t, m[MOTIF_NOTES - 1].length >= 4)
	testing.expect(t, motif_eighths(m) == 14)
}

@(test)
test_motif_of_minor :: proc(t: ^testing.T) {
	// The same degrees, a minor third and a minor seventh: C Eb C Bb C D G.
	m := motif_of(earth_address(), .Minor)
	pitches := [MOTIF_NOTES]u8{60, 63, 60, 58, 60, 62, 67}
	for n, i in m {
		testing.expectf(
			t,
			n.pitch == pitches[i],
			"note %d: pitch %d, want %d",
			i,
			n.pitch,
			pitches[i],
		)
	}
}

@(test)
test_motif_of_every_address :: proc(t: ^testing.T) {
	for seed in 0 ..< u64(2000) {
		a := address_derive(seed)
		m := motif_of(a)
		testing.expect(t, m == motif_of(a), "not deterministic")
		for mode in Mode {
			m = motif_of(a, mode)
			acc := u16(0)
			for n, i in m {
				testing.expectf(
					t,
					n.pitch >= 24 && n.pitch <= 96,
					"seed %d: pitch %d",
					seed,
					n.pitch,
				)
				testing.expectf(
					t,
					n.length >= 1 && n.length <= MOTIF_LAST_LENGTH,
					"seed %d: length %d",
					seed,
					n.length,
				)
				testing.expectf(t, n.start == acc, "seed %d: start", seed)
				acc += u16(n.length)
				if i > 0 {
					leap := abs(int(n.pitch) - int(m[i - 1].pitch))
					testing.expectf(t, leap <= 6, "seed %d: leap %d before note %d", seed, leap, i)
				}
			}
		}
	}
}

// ---- place codes ----

@(test)
test_share_earth_code_round_trips :: proc(t: ^testing.T) {
	// Earth's surface columns for known places land back within one block.
	places := [][2]f64 {
		{27.98, 86.92},
		{-33.87, 151.21},
		{-8.37, -115.19},
		{0.0, 0.0},
		{85.0, 179.0},
	}
	for pl in places {
		code := share_earth_code(pl[0], pl[1])
		parsed, ok := share_parse(code)
		testing.expectf(t, ok, "%q", code)
		testing.expect(t, parsed.earth)
		testing.expectf(
			t,
			abs(parsed.lat - pl[0]) < 0.01 && abs(parsed.lon - pl[1]) < 0.01,
			"%q: %v, %v",
			code,
			parsed.lat,
			parsed.lon,
		)
		text := strings.builder_make(context.temp_allocator)
		strings.write_string(&text, "@Earth ")
		fmt.sbprintf(
			&text,
			"%.2f%s %.2f%s",
			abs(parsed.lat),
			"N" if parsed.lat >= 0 else "S",
			abs(parsed.lon),
			"E" if parsed.lon >= 0 else "W",
		)
		testing.expect_value(t, strings.to_string(text), code)
	}
}

@(test)
test_share_world_code_round_trips :: proc(t: ^testing.T) {
	for seed in 0 ..< u64(20) {
		a := address_derive(seed)
		code := share_world_code(a, 123.5, 64, -876.25)
		parsed, ok := share_parse(code)
		testing.expectf(t, ok, "%q", code)
		testing.expect(t, !parsed.earth)
		testing.expect(t, parsed.address == a)
		testing.expect_value(t, parsed.x, 123.5)
		testing.expect_value(t, parsed.y, 64.0)
		testing.expect_value(t, parsed.z, -876.25)
	}
}

@(test)
test_share_code_earth_knows_its_address :: proc(t: ^testing.T) {
	// The Latin-letter form round-trips, Earth included (everywhere, so a
	// friend can paste it from any machine).
	earth := earth_address()
	latin := address_latin(earth)
	testing.expect(t, len(latin) == WORLD_LENGTH + 1 + GALAXY_LENGTH)
	back, ok := address_parse_latin(latin)
	testing.expect(t, ok && back == earth)
	code := share_world_code(earth, 1, 2, 3)
	parsed, ok2 := share_parse(code)
	testing.expect(t, ok2 && parsed.address == earth)
}

@(test)
test_share_parse_refuses :: proc(t: ^testing.T) {
	cases := []string {
		"",
		"Earth",
		"@",
		"@Earth",
		"@Earth 27.98N",
		"@Earth 27.98N 86.92E 10",
		"@Earth 91N 10E",
		"@Earth 10S 181E",
		"@Earth 27.98Q 86.92E",
		"@Earth north 86.92E",
		"@abcdefg-hijklmno",
		"@abcdefg-hijklmno 1 2",
		"@abcdefg-hijklmno 1 2 3 4",
		"@ABCDEFG-HIJKLMNO 1 2 3",
		"@abcdefg-hijklmn0 1 2 3", // 0 is not a symbol
		"@abcdefghijklmno 1 2 3", // no dash
		"@world 1 2 3",
		"@earth 27.98N", // case insensitive but too few fields
	}
	for c in cases {
		_, ok := share_parse(c)
		testing.expectf(t, !ok, "%q was accepted", c)
	}
	// These parse (case insensitive hemisphere letters, lowercase earth).
	_, ok := share_parse("@earth 27.98n 86.92e")
	testing.expect(t, ok)
	_, ok = share_parse("@Earth 0N 0E")
	testing.expect(t, ok)
}
