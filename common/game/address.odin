package game

import "core:fmt"
import "core:strconv"
import "core:strings"

// Addresses: a world's name in its universe: a galaxy (GALAXY_LENGTH different symbols, in order) and a
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

// Earth, the home world, has one fixed address, the same in every universe.
// Chosen once; never change them (saves and the Earth terrain are named by them).
// The galaxy is the Milky Way's.
EARTH_GALAXY :: [GALAXY_LENGTH]u8{3, 17, 22, 5, 31, 9, 26, 12}
EARTH_WORLD :: [WORLD_LENGTH]u8{14, 2, 35, 20, 7, 29, 11}

// earth_address: Earth's address.
earth_address :: proc() -> Address {
	return Address{galaxy = EARTH_GALAXY, world = EARTH_WORLD}
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

// Motifs: a world's address as a tune. The seven glyphs of its world part
// are seven notes (the hook of the world's theme). Pure and deterministic:
// the same address gives the same notes on every machine.
//
// The rule (also in docs/audio.md):
//   - pitch: the glyph mod 7 is a scale degree (0 is the home note) in the
//     world's mode. The first note is in the octave of middle C (MIDI 60 is
//     degree 1 of C); each later note is in the octave nearest the previous
//     note (a tie goes up), so no step is wider than a tritone.
//   - rhythm: the glyph div 7 (0..5) picks the length in eighths from
//     MOTIF_LENGTHS; the last note is always MOTIF_LAST_LENGTH eighths, long
//     enough to sing and let the phrase land.

MOTIF_NOTES :: WORLD_LENGTH
MOTIF_HOME :: 60 // MIDI note of degree 1 (C4); the tonic is C for every world.
MOTIF_LENGTHS :: [6]u8{2, 1, 1, 2, 1, 2} // eighths, by glyph div 7
MOTIF_LAST_LENGTH :: 6 // eighths: a dotted half

Mode :: enum u8 {
	Major,
	Minor,
}

@(rodata)
MODE_STEPS := [Mode][7]u8 {
	.Major = {0, 2, 4, 5, 7, 9, 11},
	.Minor = {0, 2, 3, 5, 7, 8, 10},
}

Motif_Note :: struct {
	pitch:  u8, // MIDI note number
	start:  u16, // in eighths from the start of the hook
	length: u8, // in eighths
}

Motif :: [MOTIF_NOTES]Motif_Note

// motif_of: the hook of a world's address, in the world's mode (Earth: major).
motif_of :: proc(a: Address, mode := Mode.Major) -> (m: Motif) {
	lengths := MOTIF_LENGTHS
	steps := MODE_STEPS[mode]
	start := u16(0)
	prev := 0
	for g, i in a.world {
		pc := int(steps[int(g) % 7])
		pitch: int
		if i == 0 {
			pitch = MOTIF_HOME + pc
		} else {
			// The note with pitch class pc nearest prev: round down to the octave at
			// or below prev, then take whichever of it and the one above is nearer.
			low := prev - ((prev - pc) %% 12)
			pitch = low
			if low + 12 - prev <= prev - low {pitch = low + 12}
		}
		length := u8(MOTIF_LAST_LENGTH)
		if i < MOTIF_NOTES - 1 {length = lengths[(int(g) / 7) % len(lengths)]}
		m[i] = Motif_Note{u8(pitch), start, length}
		start += u16(length)
		prev = pitch
	}
	return
}

// motif_eighths: the length of the whole hook in eighths.
motif_eighths :: proc(m: Motif) -> int {
	last := m[MOTIF_NOTES - 1]
	return int(last.start) + int(last.length)
}
