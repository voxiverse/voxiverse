package wave

import "core:testing"

// Every wave is bigger than the last; the matriarch comes every BOSS_EVERY waves and only
// then; the skitters from the second, the hulks by the fourth.
@(test)
test_wave_plans :: proc(t: ^testing.T) {
	for n in 1 ..= 12 {
		p := plan(n)
		testing.expect_value(t, p.count[.Matriarch], 1 if n % BOSS_EVERY == 0 else 0)
		if n > 1 {testing.expect(t, size(n) > size(n - 1))}
	}
	testing.expect_value(t, plan(1).count[.Skitter], 0)
	testing.expect(t, plan(2).count[.Skitter] > 0)
	testing.expect(t, plan(4).count[.Hulk] > 0)
	testing.expect_value(t, size(1), 4)
}
