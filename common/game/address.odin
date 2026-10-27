package game

import "core:fmt"
import "core:strconv"
import "core:strings"

// Addresses: a world's name in its universe (docs/plan.md, "Addresses: how many
// worlds"): a galaxy (GALAXY_LENGTH different symbols, in order) and a
// world in it (WORLD_LENGTH different symbols, in order), symbols being
// SYMBOLS letters of Old Turkic. Written world first, then the galaxy. In
// file names, two hex digits a symbol ("0a1b...-..."), galaxy first: file
// systems need not know the script.

SYMBOLS :: 40
GALAXY_LENGTH :: 8
WORLD_LENGTH :: 7

Address :: struct {
	galaxy: [GALAXY_LENGTH]u8, // symbol indices, none twice
	world:  [WORLD_LENGTH]u8,
}

// SYMBOL_RUNES: what each symbol is in Unicode (Old Turkic, Orkhon).
@(rodata)
SYMBOL_RUNES := [SYMBOLS]rune {
	0x10C00,
	0x10C01,
	0x10C04,
	0x10C05,
	0x10C07,
	0x10C09,
	0x10C0A,
	0x10C0B,
	0x10C0C,
	0x10C0D,
	0x10C0E,
	0x10C0F,
	0x10C10,
	0x10C12,
	0x10C14,
	0x10C15,
	0x10C18,
	0x10C1C,
	0x10C22,
	0x10C24,
	0x10C26,
	0x10C27,
	0x10C28,
	0x10C2B,
	0x10C2C,
	0x10C2D,
	0x10C31,
	0x10C32,
	0x10C36,
	0x10C38,
	0x10C39,
	0x10C3A,
	0x10C3C,
	0x10C3D,
	0x10C41,
	0x10C42,
	0x10C43,
	0x10C44,
	0x10C45,
	0x10C47,
}

symbol_of_rune :: proc(r: rune) -> (int, bool) {
	for s, i in SYMBOL_RUNES {if s == r {return i, true}}
	return 0, false
}

@(private = "file")
part_valid :: proc(part: []u8) -> bool {
	seen: bit_set[0 ..< SYMBOLS]
	for s in part {
		if int(s) >= SYMBOLS || int(s) in seen {return false}
		seen += {int(s)}
	}
	return true
}

address_valid :: proc(a: Address) -> bool {
	g, w := a.galaxy, a.world
	return part_valid(g[:]) && part_valid(w[:])
}

// address_hash: 64 bits that stand for the address (seeds, kinds).
address_hash :: proc(a: Address) -> u64 {
	h := u64(0xcbf2_9ce4_8422_2325)
	g, w := a.galaxy, a.world
	for s in g {h = (h ~ u64(s)) * 0x100_0000_01b3}
	for s in w {h = (h ~ u64(s) ~ 0x80) * 0x100_0000_01b3}
	h ~= h >> 33
	h *= 0xff51_afd7_ed55_8ccd
	h ~= h >> 33
	return h
}

// address_derive: an address from a number (the universe seed: its home
// world): distinct symbols drawn in order by a small random sequence.
address_derive :: proc(n: u64) -> (a: Address) {
	state := n ~ 0x9e37_79b9_7f4a_7c15
	next :: proc(state: ^u64) -> u64 {
		state^ += 0x9e37_79b9_7f4a_7c15
		z := state^
		z = (z ~ (z >> 30)) * 0xbf58_476d_1ce4_e5b9
		z = (z ~ (z >> 27)) * 0x94d0_49bb_1331_11eb
		return z ~ (z >> 31)
	}
	draw :: proc(part: []u8, state: ^u64) {
		pool: [SYMBOLS]u8
		for &p, i in pool {p = u8(i)}
		for i in 0 ..< len(part) {
			j := i + int(next(state) % u64(SYMBOLS - i))
			pool[i], pool[j] = pool[j], pool[i]
			part[i] = pool[i]
		}
	}
	draw(a.galaxy[:], &state)
	draw(a.world[:], &state)
	return
}

// address_text: as players read and share it: the world's symbols, a
// space, the galaxy's.
address_text :: proc(a: Address, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	g, w := a.galaxy, a.world
	for s in w {strings.write_rune(&b, SYMBOL_RUNES[s])}
	strings.write_byte(&b, ' ')
	for s in g {strings.write_rune(&b, SYMBOL_RUNES[s])}
	return strings.to_string(b)
}

// address_dir: as a directory name: "<galaxy>-<world>", two hex digits a
// symbol.
address_dir :: proc(a: Address, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	g, w := a.galaxy, a.world
	for s in g {fmt.sbprintf(&b, "%02x", s)}
	strings.write_byte(&b, '-')
	for s in w {fmt.sbprintf(&b, "%02x", s)}
	return strings.to_string(b)
}

// address_parse reads an address written as players share it (world
// symbols, then the galaxy's; the galaxy may be left out: here's), or as a
// directory name.
address_parse :: proc(text: string, here_galaxy: [GALAXY_LENGTH]u8) -> (a: Address, ok: bool) {
	t := strings.trim_space(text)
	if g, _, w := strings.partition(t, "-");
	   len(g) == 2 * GALAXY_LENGTH && len(w) == 2 * WORLD_LENGTH {
		for i in 0 ..< GALAXY_LENGTH {a.galaxy[i] = u8(strconv.parse_uint(g[2 * i:2 * i + 2], 16) or_return)}
		for i in 0 ..< WORLD_LENGTH {a.world[i] = u8(strconv.parse_uint(w[2 * i:2 * i + 2], 16) or_return)}
		return a, address_valid(a)
	}
	symbols := make([dynamic]u8, context.temp_allocator)
	for r in t {
		if r == ' ' {continue}
		s := symbol_of_rune(r) or_return
		append(&symbols, u8(s))
	}
	switch len(symbols) {
	case WORLD_LENGTH:
		a.galaxy = here_galaxy
	case WORLD_LENGTH + GALAXY_LENGTH:
		copy(a.galaxy[:], symbols[WORLD_LENGTH:])
	case:
		return
	}
	copy(a.world[:], symbols[:WORLD_LENGTH])
	return a, address_valid(a)
}
