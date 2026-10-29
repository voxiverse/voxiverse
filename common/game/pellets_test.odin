package game

import "core:math"
import "core:testing"

// The shotgun's pattern is a function of the seed and the aim: the server and
// the client (which draws the same rays) get the same eight for a shot.
@(test)
test_pellet_pattern_is_the_same_for_a_seed :: proc(t: ^testing.T) {
	info, _ := item_info(test_reg(), item_by_name(test_reg(), "shotgun") or_else NO_ITEM)
	w, ok := info.weapon.?
	if !testing.expect(t, ok, "the shotgun is a weapon") {return}
	testing.expect_value(t, w.pellets, 8)
	testing.expect_value(t, w.damage, 2)
	testing.expect_value(t, w.magazine, 6)
	seed := shot_seed(3, 1234, 1)
	a, n := pellet_dirs(seed, 0.7, -0.2, w)
	b, m := pellet_dirs(seed, 0.7, -0.2, w)
	testing.expect_value(t, n, 8)
	testing.expect_value(t, m, 8)
	testing.expect(t, a == b, "the same seed gave other rays")
	other, _ := pellet_dirs(shot_seed(3, 1235, 1), 0.7, -0.2, w)
	testing.expect(t, a != other, "another shot gave the same rays")
	aim := aim_forward(0.7, -0.2)
	limit := math.cos(f64(w.spread)) - 1e-9
	spread_out := 0
	for i in 0 ..< n {
		d := a[i]
		cosine := d.x * aim.x + d.y * aim.y + d.z * aim.z
		testing.expectf(t, cosine >= limit, "ray %d is %.4f radians off", i, math.acos(cosine))
		if i > 0 && d != a[i - 1] {spread_out += 1}
	}
	testing.expect(t, spread_out >= 6, "the pellets are not spread")
}

// One ray, no spread: the aim itself (a pistol).
@(test)
test_a_single_ray_is_the_aim :: proc(t: ^testing.T) {
	dirs, n := pellet_dirs(99, 1.1, 0.3, Weapon_Info{pellets = 0})
	testing.expect_value(t, n, 1)
	testing.expect_value(t, dirs[0], aim_forward(1.1, 0.3))
}
