package worldgen

import "core:testing"

import "common:game"

@(test)
test_world_life :: proc(t: ^testing.T) {
	a := game.address_derive(7)
	testing.expect(t, world_life(a) == world_life(a))
	earth := world_life(a, home = true)
	testing.expect(t, earth.life == .Animals && earth.peoples == 0 && earth.peoples_age == 0)

	N :: 10000
	kinds: [Life]int
	animals, with_peoples: int
	for i in 0 ..< N {
		w := world_life(game.address_derive(u64(i)))
		kinds[w.life] += 1
		if w.life == .Animals {animals += 1}
		if w.peoples > 0 {
			with_peoples += 1
			testing.expect(t, w.life == .Animals && w.peoples <= PEOPLES_MAX)
			testing.expect(t, w.peoples_age >= PEOPLES_AGE_MIN && w.peoples_age <= PEOPLES_AGE_MAX)
		} else {
			testing.expect(t, w.peoples_age == 0)
		}
	}
	for kind in Life {
		share := f64(kinds[kind]) / N
		want := f64(LIFE_SHARE[kind]) / 100
		testing.expectf(t, abs(share - want) <= 0.02, "%v: %v, want %v", kind, share, want)
	}
	share := f64(with_peoples) / f64(animals)
	testing.expectf(t, abs(share - 1.0 / PEOPLES_ONE_IN) <= 0.02, "peoples share %v", share)
}
