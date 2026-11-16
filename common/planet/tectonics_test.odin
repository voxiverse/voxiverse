package planet

import "common:base"
import "common:starmap"
import "core:testing"

@(private = "file")
address_n :: proc(n: u64) -> starmap.Address {
	return starmap.address_derive(n * 7919 + 13)
}

@(private = "file")
land_share :: proc(r: Relief) -> f64 {
	land, total := 0.0, 0.0
	for j in 0 ..< r.height {
		wt := base_cos_lat(r, j)
		for i in 0 ..< r.width {
			total += wt
			if relief_at(r, i, j) > 0 {land += wt}
		}
	}
	return land / total
}

@(private = "file")
base_cos_lat :: proc(r: Relief, j: int) -> f64 {
	return base.cos(relief_cell_lat(r, j) * PI / 180)
}

@(test)
test_relief_generate_deterministic :: proc(t: ^testing.T) {
	a := address_n(1)
	r1 := relief_generate(a, 42)
	defer relief_destroy(&r1)
	r2 := relief_generate(a, 42)
	defer relief_destroy(&r2)
	r3 := relief_generate(a, 43)
	defer relief_destroy(&r3)
	testing.expect_value(t, relief_hash(r1), relief_hash(r2))
	testing.expect(t, relief_hash(r1) != relief_hash(r3))
	// The hash on every OS: a change here is a change of every generated world.
	testing.expect_value(t, relief_hash(r1), u64(0xed0b125a2ae0f1be))
}

@(test)
test_relief_generate_mountains_by_convergent_boundaries :: proc(t: ^testing.T) {
	for n in 0 ..< 3 {
		a := address_n(u64(100 + n))
		points: [dynamic][3]f64
		defer delete(points)
		r := relief_generate(a, 9, convergent = &points)
		defer relief_destroy(&r)
		high, near := 0, 0
		// Every 4th high cell, against every 2nd boundary point: 500 km is a chord of 0.0785.
		for e, k in r.elevation {
			if e <= 3000 || k % 4 != 0 {continue}
			high += 1
			i, j := k % r.width, k / r.width
			lat := relief_cell_lat(r, j) * PI / 180
			lon := relief_cell_lon(r, i) * PI / 180
			x := [3]f64 {
				base.cos(lat) * base.cos(lon),
				base.cos(lat) * base.sin(lon),
				base.sin(lat),
			}
			for q := 0; q < len(points); q += 2 {
				d := x - points[q]
				if d.x * d.x + d.y * d.y + d.z * d.z < 0.0785 * 0.0785 {
					near += 1
					break
				}
			}
		}
		testing.expectf(t, high > 0, "world %d has no high ground", n)
		testing.expectf(
			t,
			near * 10 >= high * 9,
			"world %d: %d of %d high cells near a boundary",
			n,
			near,
			high,
		)
		free_all(context.temp_allocator)
	}
}

// GENERATED_WORLDS: the worlds relief_world_check builds, one test each.
GENERATED_WORLDS :: 20
@(test)
test_relief_generate_world_00 :: proc(t: ^testing.T) {relief_world_check(t, 0)}
@(test)
test_relief_generate_world_01 :: proc(t: ^testing.T) {relief_world_check(t, 1)}
@(test)
test_relief_generate_world_02 :: proc(t: ^testing.T) {relief_world_check(t, 2)}
@(test)
test_relief_generate_world_03 :: proc(t: ^testing.T) {relief_world_check(t, 3)}
@(test)
test_relief_generate_world_04 :: proc(t: ^testing.T) {relief_world_check(t, 4)}
@(test)
test_relief_generate_world_05 :: proc(t: ^testing.T) {relief_world_check(t, 5)}
@(test)
test_relief_generate_world_06 :: proc(t: ^testing.T) {relief_world_check(t, 6)}
@(test)
test_relief_generate_world_07 :: proc(t: ^testing.T) {relief_world_check(t, 7)}
@(test)
test_relief_generate_world_08 :: proc(t: ^testing.T) {relief_world_check(t, 8)}
@(test)
test_relief_generate_world_09 :: proc(t: ^testing.T) {relief_world_check(t, 9)}
@(test)
test_relief_generate_world_10 :: proc(t: ^testing.T) {relief_world_check(t, 10)}
@(test)
test_relief_generate_world_11 :: proc(t: ^testing.T) {relief_world_check(t, 11)}
@(test)
test_relief_generate_world_12 :: proc(t: ^testing.T) {relief_world_check(t, 12)}
@(test)
test_relief_generate_world_13 :: proc(t: ^testing.T) {relief_world_check(t, 13)}
@(test)
test_relief_generate_world_14 :: proc(t: ^testing.T) {relief_world_check(t, 14)}
@(test)
test_relief_generate_world_15 :: proc(t: ^testing.T) {relief_world_check(t, 15)}
@(test)
test_relief_generate_world_16 :: proc(t: ^testing.T) {relief_world_check(t, 16)}
@(test)
test_relief_generate_world_17 :: proc(t: ^testing.T) {relief_world_check(t, 17)}
@(test)
test_relief_generate_world_18 :: proc(t: ^testing.T) {relief_world_check(t, 18)}
@(test)
test_relief_generate_world_19 :: proc(t: ^testing.T) {relief_world_check(t, 19)}
#assert(GENERATED_WORLDS == 20) // a test above for each

// relief_world_check: generated world n (of GENERATED_WORLDS), built once and held to
// what a generated world promises: its land is its character's share, its plates number
// 8 to 20, and its land has at least four Köppen groups. (One test a world, so the
// runner's threads build them side by side: one test of twenty outlasted macOS CI's
// limit, and four of five bounded the whole suite.)
@(private = "file")
relief_world_check :: proc(t: ^testing.T, n: int) {
	a := address_n(u64(200 + n))
	r := relief_generate(a, 5)
	defer relief_destroy(&r)

	ch := relief_character(a)
	share := land_share(r)
	testing.expectf(
		t,
		abs(share - ch.land_fraction) < 0.05,
		"world %d: land %.3f, target %.3f",
		n,
		share,
		ch.land_fraction,
	)
	testing.expect(t, ch.plates >= 8 && ch.plates <= 20)

	p := planet_build(r)
	defer planet_destroy(&p)
	groups: [256]bool
	count := 0
	for k, idx in p.koppen {
		if !p.land.is_land[idx] {continue}
		g := koppen_group(k)
		if !groups[g] {groups[g] = true; count += 1}
	}
	testing.expectf(t, count >= 4, "world %d has %d Köppen groups", n, count)
}

@(test)
test_relief_for_world_home :: proc(t: ^testing.T) {
	seed := u64(77)
	home := starmap.address_derive(seed)
	testing.expect(t, relief_is_home(home, seed))
	testing.expect(t, !relief_is_home(address_n(3), seed))
	// With no Earth file the home world is generated like any other.
	r := relief_for_world(home, seed, nil)
	defer relief_destroy(&r)
	testing.expect_value(t, r.width, RELIEF_WIDTH)
}
