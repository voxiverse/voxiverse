package server

import "base:runtime"
import "core:strings"

import "common:base"
import "common:base/fuzz"
import "common:game"

// text.parsers (Q2, docs/fuzzing.md): the parsers chat and commands hand players' text to.
// The first byte picks the parser; the rest is its text.

FUZZ_TEXT_PARSERS :: 9

fuzz_text_parsers :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	if len(data) == 0 {return 1}
	which := int(data[0]) % FUZZ_TEXT_PARSERS
	text := string(data[1:])
	reg := fuzz_registry()
	result: u64
	switch which {
	case 0:
		spans := make([dynamic]game.Span, allocator)
		defer delete(spans)
		game.format_parse(text, &spans)
		total := 0
		for sp in spans {
			if len(sp.text) == 0 {fuzz.fail("an empty span")}
			total += len(sp.text)
		}
		if total > len(text) {fuzz.fail("%d bytes of spans in %d bytes of text", total, len(text))}
		result = u64(len(spans))
	case 1:
		a, ok := game.address_parse(text, {})
		if ok && !game.address_valid(a) {fuzz.fail("an invalid address was accepted")}
		result = u64(ok)
	case 2:
		id, ok := game.id_parse(text)
		if ok &&
		   (!game.id_part_valid(id.namespace, 32) ||
				   !game.id_part_valid(id.name, 48)) {fuzz.fail("an invalid id was accepted")}
		result = u64(ok)
	case 3:
		b, ok := game.state_parse(reg, text)
		if ok && int(b) >= reg.blocks.count {fuzz.fail("block %d is not in the registry", int(b))}
		result = u64(ok)
	case 4:
		a, ok := game.account_parse(text)
		if ok && !strings.equal_fold(game.account_text(a), text) {
			fuzz.fail("an account did not read back as written")
		}
		result = u64(ok)
	case 5:
		_, ok := game.ability_parse(text)
		result = u64(ok)
	case 6:
		f, ok := game.parse_time_of_day(text)
		if ok && !(f >= 0 && f <= 1) {fuzz.fail("time of day %v", f)}
		result = u64(ok)
	case 7:
		_, ok := game.damage_source_parse(text)
		result = u64(ok)
	case:
		n, ok := parse_count(text)
		if ok && (n < 1 || n > 9999) {fuzz.fail("count %d", n)}
		result = u64(ok)
	}
	return fuzz.sig_mix(2, u64(which), result, fuzz.sig_bucket(len(text)))
}

fuzz_text_generate :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	which := base.rng_int_max(rng, FUZZ_TEXT_PARSERS)
	append(out, u8(which))
	pick :: proc(rng: ^base.Rng, options: []string) -> string {
		return options[base.rng_int_max(rng, len(options))]
	}
	text: string
	switch which {
	case 0:
		text = pick(
			rng,
			{
				"plain",
				"&cred &lbold&r plain",
				"&#ff8800orange&#zz",
				"&&escaped &",
				"&",
				"&#12",
				"&x&0&f",
			},
		)
	case 1:
		a := game.address_derive(base.rng_u64(rng))
		text = game.address_text(a) if base.rng_int_max(rng, 2) == 0 else game.address_dir(a)
	case 2:
		text = pick(
			rng,
			{"stone", "voxiverse:stone", "my_pack:thing_2", ":", "a:", ":b", "UP:x", "a:b:c"},
		)
	case 3:
		text = pick(
			rng,
			{
				"stone",
				"voxiverse:oak_door[facing=north,half=lower,open=true]",
				"voxiverse:stone[",
				"voxiverse:stone[]",
				"voxiverse:stone[a=b,]",
				"nope",
			},
		)
	case 4:
		a: game.Account
		for &x in a {x = u8(base.rng_u32(rng))}
		text = game.account_text(a)
	case 5:
		text = pick(rng, {"fly", "invulnerable", "instant_break", "health", "Fly", "", "fly "})
	case 6:
		text = pick(
			rng,
			{
				"noon",
				"midnight",
				"0",
				"1",
				"0.5",
				"1.0000001",
				"-0",
				"1e0",
				"nan",
				"inf",
				".5",
				"0x1p-1",
			},
		)
	case 7:
		text = pick(rng, {"fall", "void", "command", "player", "", "Fall"})
	case:
		text = pick(rng, {"1", "9999", "10000", "0", "00001", "-1", "+1", "12a", ""})
	}
	append(out, ..transmute([]u8)text)
}
