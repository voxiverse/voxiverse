package voxel

import "core:testing"

import "common:base"

// Hash: FNV-1a over 64-bit values.
Hash :: struct {
	h: u64,
}

hash_u64 :: proc(h: ^Hash, v: u64) {
	if h.h == 0 {h.h = 0xcbf2_9ce4_8422_2325}
	for i in 0 ..< 8 {
		h.h ~= (v >> uint(i * 8)) & 0xff
		h.h *= 0x100_0000_01b3
	}
}

hash_mask :: proc(h: ^Hash, m: Mask) {
	for v in ([6]i32{m.bounds.lo.x, m.bounds.lo.y, m.bounds.lo.z, m.bounds.hi.x, m.bounds.hi.y, m.bounds.hi.z}) {
		hash_u64(h, u64(u32(v)))
	}
	for w in m.words {hash_u64(h, w)}
}

hash_field :: proc(h: ^Hash, f: Field) {
	for v in f.values {hash_u64(h, u64(u32(v)))}
}

// The bits every operation gives for fixed inputs: a change to any result fails here, on
// every machine alike.
@(test)
test_results_are_the_same_bits_everywhere :: proc(t: ^testing.T) {
	h: Hash
	rng := base.rng_make(0xde7e)
	b := Bounds{{-40, -6, -9}, {90, 10, 12}}
	n26, n6 := neighbours(3), neighbours(1)
	defer mask_destroy(&n26)
	defer mask_destroy(&n6)
	for _ in 0 ..< 4 {
		defer free_all(context.temp_allocator)
		m := random_mask(&rng, b, base.rng_int_range(&rng, 20, 70))
		defer mask_destroy(&m)
		d := mask_make(bounds_sum(b, n26.bounds))
		defer mask_destroy(&d)
		dilate(&d, m, n26)
		hash_mask(&h, d)
		erode(&d, m, n6)
		hash_mask(&h, d)
		seed := random_mask(&rng, b, 1)
		defer mask_destroy(&seed)
		fill(&seed, m, n6, max(int))
		hash_mask(&h, seed)
		f := field_make(b)
		defer field_destroy(&f)
		count, _ := components(&f, m, n26, max(int))
		hash_u64(&h, u64(count))
		hash_field(&h, f)
		distance(&f, seed, m, n26, 50, max(int))
		hash_field(&h, f)
		shapes := mask_make(b)
		defer mask_destroy(&shapes)
		ellipsoid(&shapes, {700, 300, -100}, {9000, 1500, 2300})
		ellipsoid(&shapes, {-3000, 0, 0}, {2000, 800, 2000}, {0, 2}, false)
		diamond(&shapes, {50, 0, 0}, 7)
		line(&shapes, {-9000, -1000, -2000}, {300, 0, 512}, {30000, 3000, 4000})
		hash_mask(&h, shapes)
		turned := mask_make(turn_bounds(TURN_X * TURN_Y, b))
		defer mask_destroy(&turned)
		turn(&turned, m, TURN_X * TURN_Y)
		hash_mask(&h, turned)
		hit, found, _ := sweep(m, {-10000, 500, 700}, {128, 0, 64}, {30000, -900, 1300}, max(int))
		hash_u64(&h, u64(found))
		for v in ([5]i64{i64(hit.cell.x), i64(hit.cell.y), i64(hit.cell.z), i64(hit.normal.x), hit.t}) {
			hash_u64(&h, u64(v))
		}
	}
	testing.expect_value(t, h.h, 2964763567486446444)
}

// The bits a least-cost spread gives for fixed inputs, weighted, seeded and stopped.
@(test)
test_least_cost_is_the_same_bits_everywhere :: proc(t: ^testing.T) {
	h: Hash
	rng := base.rng_make(0x1ea5)
	b := Bounds{{-40, -6, -9}, {90, 10, 12}}
	n26 := neighbours(3)
	defer mask_destroy(&n26)
	octile := moves_of(n26, 10)
	defer delete(octile)
	costs := [4]i32{0, 10, 14, 17} // (by the number of axes a move crosses)
	for &m in octile {
		axes := 0
		for k in 0 ..< 3 {if m.offset[k] != 0 {axes += 1}}
		m.cost = costs[axes]
	}
	for round in 0 ..< 4 {
		defer free_all(context.temp_allocator)
		m := random_mask(&rng, b, base.rng_int_range(&rng, 40, 90))
		defer mask_destroy(&m)
		climb := random_mask(&rng, b, 50)
		defer mask_destroy(&climb)
		octile[round].from = &climb
		f := field_make(b)
		defer field_destroy(&f)
		for _ in 0 ..< 5 {
			c := ref_cells(b)[base.rng_int_max(&rng, bounds_volume(b))]
			f.values[field_index(f, c)] = i32(base.rng_int_max(&rng, 40))
		}
		seeds := field_make(b)
		defer field_destroy(&seeds)
		copy(seeds.values, f.values)
		least_cost(&f, m, octile, 900, max(int))
		hash_field(&h, f)
		goal := Cell{80, 8, 10}
		stop := mask_make({goal, goal + 1})
		defer mask_destroy(&stop)
		mask_set(&stop, goal)
		least_cost(&seeds, m, octile, max(int), max(int), stop)
		hash_field(&h, seeds)
		at := goal
		for next in descend(seeds, at, octile) {at = next}
		hash_u64(&h, u64(u32(at.x)) | u64(u32(at.y)) << 16 | u64(u32(at.z)) << 32)
		octile[round].from = nil
	}
	testing.expect_value(t, h.h, 7472160107628367187)
}
