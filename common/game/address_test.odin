package game

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
