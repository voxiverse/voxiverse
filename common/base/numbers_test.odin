package base

import "core:math"
import "core:testing"

@(private = "file")
INPUTS :: [64]f64 {
	0,
	-0.0,
	1e-310,
	-1e-310,
	1e-20,
	1e-9,
	0.1,
	-0.1,
	0.5,
	-0.5,
	0.7,
	1,
	-1,
	1.5,
	2,
	-2,
	3,
	3.14159265358979,
	-3.14159265358979,
	4,
	5,
	6.28318530717959,
	7,
	10,
	-10,
	12.5,
	20,
	25.7,
	50,
	-50,
	100,
	-100,
	300,
	700,
	709,
	-700,
	-740,
	1000,
	-1000,
	1234.5678,
	1e4,
	1e5,
	-1e5,
	1e6,
	1e7,
	1e9,
	1e12,
	1e15,
	123456789.123,
	0.3333333333333333,
	2.718281828459045,
	0.6931471805599453,
	0.34657359027997264,
	1.0397207708399179,
	-0.34657359027997264,
	1.5e-8,
	3e-9,
	8.5,
	9.99,
	16.2,
	33.3,
	64.64,
	-64.64,
	0.9999999,
}

@(private = "file")
ulps :: proc(a, b: f64) -> u64 {
	ia, ib := i64(transmute(u64)a), i64(transmute(u64)b)
	if ia < 0 {ia = min(i64) - ia}
	if ib < 0 {ib = min(i64) - ib}
	return u64(abs(ia - ib))
}

@(test)
test_numbers_close_to_libm :: proc(t: ^testing.T) {
	for x in INPUTS {
		if abs(x) <= 1e6 {
			testing.expectf(
				t,
				ulps(sin(x), math.sin(x)) <= 2,
				"sin(%v) = %v, libm %v",
				x,
				sin(x),
				math.sin(x),
			)
			testing.expectf(
				t,
				ulps(cos(x), math.cos(x)) <= 2,
				"cos(%v) = %v, libm %v",
				x,
				cos(x),
				math.cos(x),
			)
		}
		testing.expectf(
			t,
			ulps(exp(x), math.exp(x)) <= 1,
			"exp(%v) = %v, libm %v",
			x,
			exp(x),
			math.exp(x),
		)
	}
	// f32 forms agree with the f64 ones, rounded once
	for x in INPUTS {
		f := f32(x)
		testing.expect_value(t, sin(f), f32(sin(f64(f))))
		testing.expect_value(t, cos(f), f32(cos(f64(f))))
		testing.expect_value(t, exp(f), f32(exp(f64(f))))
	}
}

@(test)
test_numbers_special_values :: proc(t: ^testing.T) {
	inf := math.inf_f64(1)
	nan := math.nan_f64()
	testing.expect_value(t, transmute(u64)sin(-0.0), transmute(u64)f64(-0.0))
	testing.expect_value(t, cos(0.0), 1.0)
	testing.expect(t, math.is_nan(sin(inf)) && math.is_nan(cos(-inf)) && math.is_nan(sin(nan)))
	testing.expect_value(t, exp(0.0), 1.0)
	testing.expect_value(t, exp(inf), inf)
	testing.expect_value(t, exp(-inf), 0.0)
	testing.expect(t, math.is_nan(exp(nan)))
	testing.expect_value(t, exp(710.0), inf)
	testing.expect_value(t, exp(-746.0), 0.0)
	testing.expect(t, exp(-740.0) > 0, "subnormal result")
}

@(test)
test_numbers_golden :: proc(t: ^testing.T) {
	h := u64(0xcbf29ce484222325)
	for x in INPUTS {
		for v in ([3]f64{sin(x), cos(x), exp(x)}) {
			h = (h ~ transmute(u64)v) * 0x100000001b3
		}
	}
	testing.expectf(t, h == GOLDEN, "numbers changed: hash is now 0x%x", h)
}

@(private = "file")
GOLDEN :: u64(0x1cb9eaed0084ad6c) // FNV-1a over the bits of sin, cos, exp of every input, recorded on Linux

@(test)
test_pow_exact :: proc(t: ^testing.T) {
	// 2^k is exact over the whole range, subnormals included.
	for k in -1074 ..= 1023 {
		want :=
			transmute(f64)(u64(k + 1023) << 52) if k >= -1022 else transmute(f64)(u64(1) << u64(k + 1074))
		testing.expectf(
			t,
			pow(2.0, f64(k)) == want,
			"2^%d = %v, wanted %v",
			k,
			pow(2.0, f64(k)),
			want,
		)
	}
	// 10^k is exact while it is representable (k <= 22).
	ten := 1.0
	for k in 0 ..= 22 {
		testing.expectf(
			t,
			pow(10.0, f64(k)) == ten,
			"10^%d = %v, wanted %v",
			k,
			pow(10.0, f64(k)),
			ten,
		)
		ten *= 10
	}
	for x in INPUTS {
		if x >= 0 {
			testing.expectf(
				t,
				pow(x, 0.5) == math.sqrt(x),
				"%v^0.5 = %v, sqrt %v",
				x,
				pow(x, 0.5),
				math.sqrt(x),
			)
		}
	}
	testing.expect_value(t, pow(3.0, 4.0), 81.0)
	testing.expect_value(t, pow(-2.0, 3.0), -8.0)
	testing.expect_value(t, pow(0.5, -2.0), 4.0)
}

@(test)
test_pow_close_to_libm :: proc(t: ^testing.T) {
	for x in INPUTS {
		for y in ([?]f64{-3, -0.5, 0.25, 1.5, 2, 7.25, 30}) {
			testing.expectf(
				t,
				ulps(pow(abs(x), y), math.pow(abs(x), y)) <= 1,
				"%v^%v = %v, libm %v",
				abs(x),
				y,
				pow(abs(x), y),
				math.pow(abs(x), y),
			)
		}
	}
}

// The special cases of C99 Annex F (F.9.4.4).
@(test)
test_pow_special :: proc(t: ^testing.T) {
	inf := math.inf_f64(1)
	nan := math.nan_f64()
	neg0 := -0.0
	is_neg0 :: proc(x: f64) -> bool {return x == 0 && math.sign_bit(x)}
	testing.expect_value(t, pow(nan, 0.0), 1.0)
	testing.expect_value(t, pow(nan, neg0), 1.0)
	testing.expect_value(t, pow(1.0, nan), 1.0)
	testing.expect_value(t, pow(1.0, inf), 1.0)
	testing.expect(t, math.is_nan(pow(nan, 1.0)) && math.is_nan(pow(2.0, nan)))
	testing.expect_value(t, pow(0.0, -3.0), inf)
	testing.expect_value(t, pow(neg0, -3.0), -inf)
	testing.expect_value(t, pow(0.0, -2.0), inf)
	testing.expect_value(t, pow(neg0, -2.0), inf)
	testing.expect_value(t, pow(0.0, -inf), inf)
	testing.expect(t, is_neg0(pow(neg0, 3.0)))
	testing.expect_value(t, pow(0.0, 3.0), 0.0)
	testing.expect(t, pow(neg0, 2.0) == 0 && !math.sign_bit(pow(neg0, 2.0)))
	testing.expect_value(t, pow(-1.0, inf), 1.0)
	testing.expect_value(t, pow(-1.0, -inf), 1.0)
	testing.expect(t, math.is_nan(pow(-2.0, 0.5)))
	testing.expect_value(t, pow(0.5, -inf), inf)
	testing.expect_value(t, pow(2.0, -inf), 0.0)
	testing.expect_value(t, pow(0.5, inf), 0.0)
	testing.expect_value(t, pow(2.0, inf), inf)
	testing.expect(t, is_neg0(pow(-inf, -3.0)))
	testing.expect_value(t, pow(-inf, -2.0), 0.0)
	testing.expect_value(t, pow(-inf, 3.0), -inf)
	testing.expect_value(t, pow(-inf, 2.0), inf)
	testing.expect_value(t, pow(inf, -1.0), 0.0)
	testing.expect_value(t, pow(inf, 1.0), inf)
	testing.expect_value(t, pow(2.0, 1024.0), inf)
	testing.expect_value(t, pow(2.0, -1075.0), 0.0)
}

@(test)
test_pow_golden :: proc(t: ^testing.T) {
	h := u64(0xcbf29ce484222325)
	for x in INPUTS {
		for y in INPUTS {
			h = (h ~ transmute(u64)pow(x, y)) * 0x100000001b3
		}
	}
	testing.expectf(t, h == POW_GOLDEN, "pow changed: hash is now 0x%x", h)
}

@(private = "file")
POW_GOLDEN :: u64(0x6751935c7a485e3) // FNV-1a over the bits of pow(x, y) for every pair of inputs, recorded on Linux
