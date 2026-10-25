package build

import "core:math"
import "core:testing"

// The comparison's statistics against values worked out by hand: two sets
// wholly apart (one arrangement of C(n1 + n2, n1) on each side), two alike,
// and the floor that tells how few runs are too few.
@(test)
test_mann_whitney :: proc(t: ^testing.T) {
	near :: proc(a, b: f64) -> bool {return math.abs(a - b) < 1e-9}
	// 5 and 5 apart: 2 / C(10, 5) = 2 / 252.
	testing.expect(t, near(mann_whitney_p({1, 2, 3, 4, 5}, {6, 7, 8, 9, 10}), 2.0 / 252))
	testing.expect(t, near(mann_whitney_p({6, 7, 8, 9, 10}, {1, 2, 3, 4, 5}), 2.0 / 252))
	// 3 and 3 apart: 2 / C(6, 3) = 0.1, never below 0.05: three runs cannot call a change.
	testing.expect(t, near(mann_whitney_p({1, 2, 3}, {4, 5, 6}), 0.1))
	testing.expect(t, near(mann_whitney_p_floor(3, 3), 0.1))
	// Alike, interleaved: no evidence at all.
	testing.expect(t, near(mann_whitney_p({1, 2, 3, 4, 5}, {1, 2, 3, 4, 5}), 1))
	testing.expect(t, mann_whitney_p({1, 3, 5, 7, 9}, {2, 4, 6, 8, 10}) > 0.5)
	// One overlap of 5 and 5: U = 1, P(U <= 1) = 2 / 252, two sided 4 / 252.
	testing.expect(t, near(mann_whitney_p({1, 2, 3, 4, 6}, {5, 7, 8, 9, 10}), 4.0 / 252))
	// 7 above 5 and 6: U = 2, P(U <= 2) = (1 + 1 + 2) / 252, two sided 8 / 252.
	testing.expect(t, near(mann_whitney_p({1, 2, 3, 4, 7}, {5, 6, 8, 9, 10}), 8.0 / 252))
}
