package planet

import "common:base"
import "common:game"
import "core:testing"

@(private = "file")
address_n :: proc(n: u64) -> game.Address {
	return game.address_derive(n * 7919 + 13)
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
test_relief_generate_land_fraction :: proc(t: ^testing.T) {
	for n in 0 ..< 6 {
		a := address_n(u64(n))
		r := relief_generate(a, 7)
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
		free_all(context.temp_allocator)
	}
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

@(test)
test_relief_generate_climates :: proc(t: ^testing.T) {
	for n in 0 ..< 20 {
		a := address_n(u64(200 + n))
		r := relief_generate(a, 5)
		p := planet_build(r)
		groups: [256]bool
		count := 0
		for k, idx in p.koppen {
			if !p.land.is_land[idx] {continue}
			g := koppen_group(k)
			if !groups[g] {groups[g] = true; count += 1}
		}
		testing.expectf(t, count >= 4, "world %d has %d Köppen groups", n, count)
		planet_destroy(&p)
		relief_destroy(&r)
		free_all(context.temp_allocator)
	}
}

@(test)
test_relief_for_world_home :: proc(t: ^testing.T) {
	seed := u64(77)
	home := game.address_derive(seed)
	testing.expect(t, relief_is_home(home, seed))
	testing.expect(t, !relief_is_home(address_n(3), seed))
	// With no Earth file the home world is generated like any other.
	r := relief_for_world(home, seed, nil)
	defer relief_destroy(&r)
	testing.expect_value(t, r.width, RELIEF_WIDTH)
}
