package base

import "core:math/rand"
import "core:testing"

@(test)
test_range_alloc_and_merge :: proc(t: ^testing.T) {
	a: Range_Allocator
	range_init(&a, 100)
	defer range_destroy(&a)

	r1, ok1 := range_alloc(&a, 30)
	r2, ok2 := range_alloc(&a, 30)
	r3, ok3 := range_alloc(&a, 40)
	testing.expect(t, ok1 && ok2 && ok3)
	testing.expect(t, r1 == {0, 30} && r2 == {30, 30} && r3 == {60, 40})
	_, full := range_alloc(&a, 1)
	testing.expect(t, !full)

	// Freeing the outer two leaves two holes; the middle one joins them.
	range_free(&a, r1)
	range_free(&a, r3)
	testing.expect_value(t, len(a.free), 2)
	_, fits := range_alloc(&a, 50)
	testing.expect(t, !fits) // 70 free, but in pieces
	range_free(&a, r2)
	testing.expect_value(t, len(a.free), 1)
	testing.expect_value(t, a.used, 0)
	testing.expect_value(t, range_largest_free(&a), 100)
}

// Random allocations and frees: never overlapping, and once everything is
// freed the space is whole again.
@(test)
test_range_alloc_random :: proc(t: ^testing.T) {
	CAPACITY :: 10_000
	a: Range_Allocator
	range_init(&a, CAPACITY)
	defer range_destroy(&a)
	owner: [CAPACITY]int // which live range covers each unit (0 = free)
	live: [dynamic]Range
	defer delete(live)
	next_id := 1

	for _ in 0 ..< 20_000 {
		if len(live) > 0 && rand.int_max(2) == 0 {
			i := rand.int_max(len(live))
			r := live[i]
			unordered_remove(&live, i)
			for u in r.offset ..< r.offset + r.size {owner[u] = 0}
			range_free(&a, r)
		} else {
			r, ok := range_alloc(&a, u32(1 + rand.int_max(300)))
			if !ok {continue}
			for u in r.offset ..< r.offset + r.size {
				if owner[u] != 0 {testing.fail_now(t, "ranges overlap")}
				owner[u] = next_id
			}
			next_id += 1
			append(&live, r)
		}
		// The free list stays sorted with no adjacent entries.
		for i in 1 ..< len(a.free) {
			if a.free[i - 1].offset + a.free[i - 1].size >= a.free[i].offset {
				testing.fail_now(t, "free list unsorted or unmerged")
			}
		}
	}
	for r in live {range_free(&a, r)}
	testing.expect_value(t, a.used, 0)
	testing.expect_value(t, len(a.free), 1)
}
