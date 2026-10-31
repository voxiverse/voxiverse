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
