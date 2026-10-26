package base

import "core:testing"

@(test)
test_rng_fixed_stream :: proc(t: ^testing.T) {
	want := [8]u64 {
		0xb3f2af6d0fc710c5,
		0x853b559647364cea,
		0x92f89756082a4514,
		0x642e1c7bc266a3a7,
		0xb27a48e29a233673,
		0x24c123126ffda722,
		0x123004ef8df510e6,
		0x61954dcc47b1e89d,
	}
	r := rng_make(1)
	for w in want {testing.expect_value(t, rng_u64(&r), w)}
}

@(test)
test_rng_int_max_uniform :: proc(t: ^testing.T) {
	r := rng_make(7)
	counts: [10]int
	N :: 100_000
	for _ in 0 ..< N {counts[rng_int_max(&r, 10)] += 1}
	// chi-square, 9 degrees of freedom: 27.88 is p = 0.001
	chi := 0.0
	for c in counts {
		d := f64(c) - N / 10.0
		chi += d * d / (N / 10.0)
	}
	testing.expectf(t, chi < 27.88, "chi-square %v", chi)
}

@(test)
test_rng_ranges :: proc(t: ^testing.T) {
	r := rng_make(3)
	seen: [4]bool
	for _ in 0 ..< 1000 {
		v := rng_int_range(&r, 2, 6)
		testing.expect(t, v >= 2 && v < 6)
		seen[v - 2] = true
		f := rng_f32_range(&r, -1, 1)
		testing.expect(t, f >= -1 && f < 1)
		d := rng_f64_range(&r, 5, 6)
		testing.expect(t, d >= 5 && d < 6)
	}
	testing.expect(t, seen == {true, true, true, true}, "every value of the range appears")
}

@(test)
test_rng_copy_continues :: proc(t: ^testing.T) {
	a := rng_make(9)
	for _ in 0 ..< 5 {rng_u64(&a)}
	b := a
	for _ in 0 ..< 20 {testing.expect_value(t, rng_u64(&a), rng_u64(&b))}
}
