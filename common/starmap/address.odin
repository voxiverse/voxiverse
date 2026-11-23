package starmap

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import "common:base"

// Addresses: a world's name in its universe: a galaxy (GALAXY_LENGTH different symbols, in order) and a
// world in it (WORLD_LENGTH different symbols, in order), from SYMBOLS
// symbols of our own (symbol_strokes draws them). Written world first, then
// the galaxy. In file names, two hex digits a symbol ("0a1b...-..."),
// galaxy first.

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

// SYMBOL_RUNE_FIRST: symbol i is this rune plus i in text, a run of
// Unicode's Private Use Area: no font has them, the UI draws them itself
// (symbol_strokes), and an address in chat is still text. Outside the game
// an address is shared in its Latin form (address_latin).
SYMBOL_RUNE_FIRST :: rune(0xE000)

// symbol_rune: what symbol is in text.
symbol_rune :: proc(symbol: u8) -> rune {
	return SYMBOL_RUNE_FIRST + rune(symbol)
}

symbol_of_rune :: proc(r: rune) -> (int, bool) {
	i := int(r - SYMBOL_RUNE_FIRST)
	return i, i >= 0 && i < SYMBOLS
}

// The symbols' shapes: one of SYMBOL_BODIES bodies with any of three marks,
// symbol = body * 8 + marks. The bodies are an arch, a cup, a diamond, a
// slab and two posts; the marks a dot inside (1), a bar beneath (2) and a
// dot above (4). Drawn as strokes of SYMBOL_WEIGHT, in em units with y up
// from the baseline, SYMBOL_ADVANCE apart.
SYMBOL_BODIES :: 5
SYMBOL_WEIGHT :: 0.08
SYMBOL_ADVANCE :: 0.9

#assert(SYMBOL_BODIES * 8 == SYMBOLS)

// symbol_strokes appends symbol's strokes (from, to; a dot is both the
// same) to out.
symbol_strokes :: proc(symbol: int, out: ^[dynamic][2][2]f32) {
	LEFT, RIGHT, MID :: f32(0.2), f32(0.7), f32(0.45)
	LOW, HIGH, CENTRE :: f32(0.2), f32(0.66), f32(0.43)
	RADIUS :: (RIGHT - LEFT) / 2
	ARC_STEPS :: 8
	line :: proc(out: ^[dynamic][2][2]f32, a, b: [2]f32) {append(out, [2][2]f32{a, b})}
	// arc: half a circle round centre, over the top (up) or under it.
	arc :: proc(out: ^[dynamic][2][2]f32, centre: [2]f32, up: bool) {
		side: f32 = 1 if up else -1
		for k in 0 ..< ARC_STEPS {
			a0 := math.PI * f32(k) / ARC_STEPS
			a1 := math.PI * f32(k + 1) / ARC_STEPS
			line(
				out,
				centre + RADIUS * [2]f32{math.cos(a0), side * math.sin(a0)},
				centre + RADIUS * [2]f32{math.cos(a1), side * math.sin(a1)},
			)
		}
	}
	switch symbol / 8 {
	case 0:
		// An arch: two uprights under half a circle.
		top := HIGH - RADIUS
		line(out, {LEFT, LOW}, {LEFT, top})
		line(out, {RIGHT, LOW}, {RIGHT, top})
		arc(out, {MID, top}, up = true)
	case 1:
		// A cup: the arch upside down.
		bottom := LOW + RADIUS
		line(out, {LEFT, HIGH}, {LEFT, bottom})
		line(out, {RIGHT, HIGH}, {RIGHT, bottom})
		arc(out, {MID, bottom}, up = false)
	case 2:
		// A diamond.
		corners := [4][2]f32 {
			{MID, LOW},
			{RIGHT + 0.02, CENTRE},
			{MID, HIGH},
			{LEFT - 0.02, CENTRE},
		}
		for c, k in corners {line(out, c, corners[(k + 1) % 4])}
	case 3:
		// A slab, standing.
		corners := [4][2]f32{{LEFT, LOW}, {RIGHT, LOW}, {RIGHT, HIGH}, {LEFT, HIGH}}
		for c, k in corners {line(out, c, corners[(k + 1) % 4])}
	case:
		// Two posts.
		line(out, {LEFT, LOW}, {LEFT, HIGH})
		line(out, {RIGHT, LOW}, {RIGHT, HIGH})
	}
	marks := symbol % 8
	if marks & 1 != 0 {line(out, {MID, CENTRE}, {MID, CENTRE})}
	if marks & 2 != 0 {line(out, {LEFT - 0.06, 0.04}, {RIGHT + 0.06, 0.04})}
	if marks & 4 != 0 {line(out, {MID, 0.84}, {MID, 0.84})}
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
	draw :: proc(part: []u8, state: ^u64) {
		pool: [SYMBOLS]u8
		for &p, i in pool {p = u8(i)}
		for i in 0 ..< len(part) {
			j := i + int(base.splitmix(state) % u64(SYMBOLS - i))
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
	for s in w {strings.write_rune(&b, symbol_rune(s))}
	strings.write_byte(&b, ' ')
	for s in g {strings.write_rune(&b, symbol_rune(s))}
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

// Motifs: a world's address as a tune. The seven symbols of its world part
// are seven notes (the hook of the world's theme). Pure and deterministic:
// the same address gives the same notes on every machine.
//
// The rule (also in docs/audio.md):
//   - pitch: the symbol mod 7 is a scale degree (0 is the home note) in the
//     world's mode. The first note is in the octave of middle C (MIDI 60 is
//     degree 1 of C); each later note is in the octave nearest the previous
//     note (a tie goes up), so no step is wider than a tritone.
//   - rhythm: the symbol div 7 (0..5) picks the length in eighths from
//     MOTIF_LENGTHS; the last note is always MOTIF_LAST_LENGTH eighths, long
//     enough to sing and let the phrase land.

MOTIF_NOTES :: WORLD_LENGTH
MOTIF_HOME :: 60 // MIDI note of degree 1 (C4); the tonic is C for every world.
MOTIF_LENGTHS :: [6]u8{2, 1, 1, 2, 1, 2} // eighths, by symbol div 7
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

// ---- place codes ("share a place") ----
//
// A place can be a short text a player pastes to a friend. On a planet
// world it names the coordinates on the surface of Earth; on any other
// world it names the address and the position. Earth is the one fixed
// address every universe has, so it is the word @Earth.
//
//   @Earth 27.98N 86.92E
//   @abcdefg-hijklmno 123 64 -876
//
// The address is its symbols as Latin letters, case sensitive: 'a'..'z' for
// symbols 0-25, 'A'..'N' for 26-39, world first, a '-', then the galaxy.

LATIN_ALPHABET :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN"

address_latin :: proc(a: Address, allocator := context.temp_allocator) -> string {
	g, w := a.galaxy, a.world
	alphabet := LATIN_ALPHABET
	b := strings.builder_make(allocator)
	for s in w {strings.write_byte(&b, alphabet[s])}
	strings.write_byte(&b, '-')
	for s in g {strings.write_byte(&b, alphabet[s])}
	return strings.to_string(b)
}

@(private = "file")
symbol_of_latin :: proc(c: u8) -> (int, bool) {
	if c >= 'a' && c <= 'z' {return int(c - 'a'), true}
	if c >= 'A' && c <= 'N' {return int(c - 'A') + 26, true}
	return 0, false
}

// address_parse_latin reads the Latin-letter form (world, a '-', galaxy).
address_parse_latin :: proc(text: string) -> (a: Address, ok: bool) {
	t := strings.trim_space(text)
	if len(t) != WORLD_LENGTH + 1 + GALAXY_LENGTH || t[WORLD_LENGTH] != '-' {
		return {}, false
	}
	for i in 0 ..< WORLD_LENGTH {
		a.world[i] = u8(symbol_of_latin(t[i]) or_return)
	}
	for i in 0 ..< GALAXY_LENGTH {
		a.galaxy[i] = u8(symbol_of_latin(t[WORLD_LENGTH + 1 + i]) or_return)
	}
	return a, address_valid(a)
}

// Share: a place code parsed (@Earth with a surface position, or an
// address with absolute coordinates).
Share :: struct {
	earth:    bool,
	lat, lon: f64,
	address:  Address,
	x, y, z:  f64,
}

SHARE_FORM :: "@Earth 27.98N 86.92E or @<world>-<galaxy> <x> <y> <z>"

@(private = "file")
ascii_lower :: proc(c: u8) -> u8 {
	return c + 32 if c >= 'A' && c <= 'Z' else c
}

@(private = "file")
parse_hemisphere :: proc(s, allowed: string) -> (value: f64, ok: bool) {
	// <number><hemisphere letter>
	if len(s) < 2 {return 0, false}
	letter := ascii_lower(s[len(s) - 1])
	for i in 0 ..< len(allowed) {
		if letter == ascii_lower(allowed[i]) {
			n, parsed := strconv.parse_f64(s[:len(s) - 1])
			if !parsed {return 0, false}
			switch letter {
			case 's', 'w':
				return -n, true
			case:
				return n, true
			}
		}
	}
	return 0, false
}

// share_parse reads a place code. ok is false for anything that is not one
// (the caller says the expected form).
share_parse :: proc(text: string) -> (share: Share, ok: bool) {
	t := strings.trim_space(text)
	if !strings.has_prefix(t, "@") {return {}, false}
	fields := strings.fields(t[1:], context.temp_allocator)
	defer delete(fields, context.temp_allocator)
	if len(fields) == 3 && strings.equal_fold(fields[0], "earth") {
		lat := parse_hemisphere(fields[1], "NS") or_return
		lon := parse_hemisphere(fields[2], "EW") or_return
		if abs(lat) > 90 || abs(lon) > 180 {return {}, false}
		return Share{earth = true, lat = lat, lon = lon}, true
	}
	if len(fields) == 4 {
		a := address_parse_latin(fields[0]) or_return
		x := strconv.parse_f64(fields[1]) or_return
		y := strconv.parse_f64(fields[2]) or_return
		z := strconv.parse_f64(fields[3]) or_return
		return Share{address = a, x = x, y = y, z = z}, true
	}
	return {}, false
}

// share_earth_code: @Earth <lat><N|S> <lon><E|W>
share_earth_code :: proc(lat, lon: f64, allocator := context.temp_allocator) -> string {
	lat_c := "N" if lat >= 0 else "S"
	lon_c := "E" if lon >= 0 else "W"
	b := strings.builder_make(allocator)
	strings.write_string(&b, "@Earth ")
	fmt.sbprintf(&b, "%.2f%s %.2f%s", abs(lat), lat_c, abs(lon), lon_c)
	return strings.to_string(b)
}

// share_world_code: @<world>-<galaxy> <x> <y> <z>
share_world_code :: proc(a: Address, x, y, z: f64, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '@')
	strings.write_string(&b, address_latin(a, allocator))
	strings.write_byte(&b, ' ')
	fmt.sbprintf(&b, "%.2f %.2f %.2f", x, y, z)
	return strings.to_string(b)
}
