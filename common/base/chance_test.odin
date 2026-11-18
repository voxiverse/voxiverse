package base

import "core:slice"
import "core:testing"

// The laws of chance.odin and rng_roll, each against a naive reference with fixed
// seeds, and the bits they give, pinned.

@(private = "file")
STEP :: u64(0x9e37_79b9_7f4a_7c15)

// unmix undoes mix step by step: a xorshift right by s is undone by repeating it
// until the shifted part is gone, a multiplication by an odd constant by its
// inverse mod 2^64 (Newton's iteration doubles the correct bits each time).
@(private = "file")
unmix :: proc(y: u64) -> u64 {
	unshift :: proc(y: u64, s: uint) -> u64 {
		x := y
		for _ in 0 ..< 64 / s {x = y ~ (x >> s)}
		return x
	}
	inverse :: proc(c: u64) -> u64 {
		v := c
		for _ in 0 ..< 6 {v *= 2 - c * v}
		return v
	}
	x := unshift(y, 31)
	x = unshift(x * inverse(0x94d0_49bb_1331_11eb), 27)
	return unshift(x * inverse(0xbf58_476d_1ce4_e5b9), 30)
}

@(test)
test_mix_is_a_bijection :: proc(t: ^testing.T) {
	r := rng_make(0xb1)
	testing.expect_value(t, mix(0), 0)
	for _ in 0 ..< 10_000 {
		x := rng_u64(&r)
		testing.expect_value(t, unmix(mix(x)), x)
	}
	for x in u64(0) ..< 1000 {testing.expect_value(t, unmix(mix(x)), x)}
}

@(test)
test_hash_folds_the_counter :: proc(t: ^testing.T) {
	r := rng_make(0xf01d)
	for _ in 0 ..< 1000 {
		k, i, j := rng_u64(&r), rng_u64(&r), u64(rng_int_max(&r, 64))
		testing.expect_value(t, hash(k), k)
		testing.expect_value(t, hash(k, i), mix(k + (i + 1) * STEP))
		testing.expect_value(t, hash(k, i, j), hash(hash(k, i), j))
	}
	// splitmix from s draws hash(s, 0), hash(s, 1), ...
	for s in ([?]u64{0, 1, 0xdead_beef, max(u64)}) {
		state := s
		for k in u64(0) ..< 100 {testing.expect_value(t, splitmix(&state), hash(s, k))}
	}
	// rng_make takes the first four.
	for s in u64(0) ..< 100 {
		testing.expect_value(
			t,
			rng_make(s).s,
			[4]u64{hash(s, 0), hash(s, 1), hash(s, 2), hash(s, 3)},
		)
	}
}

// Seeds derived from one seed by distinct salts are distinct, and from distinct
// seeds by the same salts too: 64 seeds by 1024 salts, all 65 536 apart.
@(test)
test_hash_derives_distinct_seeds :: proc(t: ^testing.T) {
	seeds := make([dynamic]u64, 0, 64 * 1024)
	defer delete(seeds)
	for seed in u64(0) ..< 64 {
		for salt in u64(0) ..< 1024 {append(&seeds, hash(seed, salt))}
	}
	slice.sort(seeds[:])
	for i in 1 ..< len(seeds) {
		if seeds[i] == seeds[i - 1] {
			testing.expectf(t, false, "two derivations give %x", seeds[i])
			return
		}
	}
}

@(test)
test_unit_is_below_one :: proc(t: ^testing.T) {
	testing.expect_value(t, unit_f32(u64(0)), 0)
	testing.expect_value(t, unit_f64(0), 0)
	testing.expect_value(t, unit_f32(max(u64)), 1 - 1.0 / 16777216.0)
	testing.expect_value(t, unit_f32(max(u32)), 1 - 1.0 / 16777216.0)
	testing.expect_value(t, unit_f64(max(u64)), 1 - 1.0 / 9007199254740992.0)
	r := rng_make(0x0417)
	for _ in 0 ..< 10_000 {
		x := rng_u64(&r)
		f, d := unit_f32(x), unit_f64(x)
		testing.expect(t, f >= 0 && f < 1 && d >= 0 && d < 1)
		// Exactly the top bits over a power of two, whatever the width.
		testing.expect_value(t, f64(f), f64(x >> 40) / 16777216.0)
		testing.expect_value(t, unit_f32(u32(x >> 32)), f)
		testing.expect_value(t, d, f64(x >> 11) / 9007199254740992.0)
	}
}

@(test)
test_rng_roll_is_inclusive :: proc(t: ^testing.T) {
	r := rng_make(0x7011)
	for _ in 0 ..< 200 {
		lo := rng_int_range(&r, -50, 50)
		hi := lo + rng_int_max(&r, 8)
		reference := r
		seen: [8]int
		for _ in 0 ..< 400 {
			v := rng_roll(&r, lo, hi)
			testing.expect_value(t, v, rng_int_range(&reference, lo, hi + 1))
			testing.expect(t, v >= lo && v <= hi)
			seen[v - lo] += 1
		}
		for n, k in seen[:hi - lo + 1] {testing.expectf(t, n > 0, "%d never rolled in [%d, %d]", lo + k, lo, hi)}
	}
	a := rng_make(5)
	b := a
	for _ in 0 ..< 100 {testing.expect_value(t, rng_roll(&a, i32(-3), i32(3)), i32(rng_roll(&b, -3, 3)))}
	testing.expect_value(t, rng_roll(&a, 7, 7), 7)
}

// Over a width that is a power of two, a roll is the draw's top bits, exactly:
// every value has the same number of draws behind it, with nothing rejected.
@(test)
test_rng_roll_is_unbiased :: proc(t: ^testing.T) {
	r := rng_make(0xd1ce)
	for bits in uint(1) ..= 6 {
		for _ in 0 ..< 1000 {
			raw := r
			testing.expect_value(
				t,
				rng_roll(&r, 10, 10 + (1 << bits) - 1),
				10 + int(rng_u64(&raw) >> (64 - bits)),
			)
		}
	}
}

// The bits these give for fixed inputs: a change to any of them fails here.
@(test)
test_chance_pinned_bits :: proc(t: ^testing.T) {
	// splitmix64's first draw from 0, as its authors give it.
	testing.expect_value(t, hash(0, 0), 0xe220_a839_7b1d_cdaf)
	h := u64(0)
	state := u64(0x5eed)
	for i in u64(0) ..< 256 {
		h = hash(h, i, transmute(u64)i64(-7), splitmix(&state))
		h ~= u64(transmute(u32)unit_f32(h)) ~ transmute(u64)unit_f64(h)
	}
	testing.expect_value(t, h, 0x13f1_9d90_88c0_adad)
}
