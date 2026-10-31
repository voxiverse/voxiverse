package base

import "core:mem/virtual"
import "core:testing"

@(private = "file")
Test_Handle :: distinct u32

@(private = "file")
Test_Item :: struct {
	value: int,
}

@(test)
test_pool_add_get_remove :: proc(t: ^testing.T) {
	p: Pool(Test_Item, Test_Handle)
	testing.expect(t, pool_init(&p, 4) == nil)
	defer pool_destroy(&p)

	a, item, ok := pool_add(&p, Test_Item{1})
	testing.expect(t, ok && item.value == 1)
	b, _, _ := pool_add(&p, Test_Item{2})
	testing.expect(t, a != b && a != 0 && b != 0)
	testing.expect_value(t, p.count, 2)

	testing.expect_value(t, pool_get(&p, b).value, 2)
	pool_get(&p, a).value = 10 // writes through to storage, no copy
	testing.expect_value(t, pool_get(&p, a).value, 10)

	testing.expect(t, pool_remove(&p, a))
	testing.expect(t, pool_get(&p, a) == nil)
	testing.expect(t, !pool_remove(&p, a)) // already removed
	testing.expect_value(t, p.count, 1)
}

@(test)
test_pool_zero_handle_is_invalid :: proc(t: ^testing.T) {
	p: Pool(Test_Item, Test_Handle)
	testing.expect(t, pool_init(&p, 2) == nil)
	defer pool_destroy(&p)
	pool_add(&p, Test_Item{1})
	testing.expect(t, pool_get(&p, Test_Handle(0)) == nil)
	testing.expect(t, !pool_remove(&p, Test_Handle(0)))
}

@(test)
test_pool_stale_handle_after_reuse :: proc(t: ^testing.T) {
	p: Pool(Test_Item, Test_Handle)
	testing.expect(t, pool_init(&p, 1) == nil)
	defer pool_destroy(&p)

	old, _, _ := pool_add(&p, Test_Item{1})
	pool_remove(&p, old)
	fresh, _, ok := pool_add(&p, Test_Item{2}) // reuses the only slot
	testing.expect(t, ok)
	testing.expect(t, fresh != old)
	testing.expect(t, pool_get(&p, old) == nil)
	testing.expect_value(t, pool_get(&p, fresh).value, 2)
}

@(test)
test_pool_full :: proc(t: ^testing.T) {
	p: Pool(Test_Item, Test_Handle)
	testing.expect(t, pool_init(&p, 2) == nil)
	defer pool_destroy(&p)
	_, _, ok1 := pool_add(&p, Test_Item{})
	_, _, ok2 := pool_add(&p, Test_Item{})
	_, _, ok3 := pool_add(&p, Test_Item{})
	testing.expect(t, ok1 && ok2 && !ok3)
}

@(test)
test_pool_pointers_stay_valid :: proc(t: ^testing.T) {
	p: Pool(Test_Item, Test_Handle)
	testing.expect(t, pool_init(&p, 64) == nil)
	defer pool_destroy(&p)
	h, first, _ := pool_add(&p, Test_Item{7})
	for i in 0 ..< 63 {pool_add(&p, Test_Item{i})}
	testing.expect(t, first == pool_get(&p, h)) // storage never moved
}

@(test)
test_pool_iteration_skips_removed :: proc(t: ^testing.T) {
	p: Pool(Test_Item, Test_Handle)
	testing.expect(t, pool_init(&p, 8) == nil)
	defer pool_destroy(&p)
	handles: [5]Test_Handle
	for &h, i in handles {h, _, _ = pool_add(&p, Test_Item{i})}
	pool_remove(&p, handles[1])
	pool_remove(&p, handles[3])

	sum, n := 0, 0
	it: Pool_Iterator
	for item, h in pool_next(&p, &it) {
		testing.expect(t, pool_get(&p, h) == item)
		sum += item.value
		n += 1
	}
	testing.expect_value(t, n, 3)
	testing.expect_value(t, sum, 0 + 2 + 4)
}

@(test)
test_pool_remove_during_iteration :: proc(t: ^testing.T) {
	p: Pool(Test_Item, Test_Handle)
	testing.expect(t, pool_init(&p, 8) == nil)
	defer pool_destroy(&p)
	for i in 0 ..< 6 {pool_add(&p, Test_Item{i})}
	it: Pool_Iterator
	for item, h in pool_next(&p, &it) {
		if item.value % 2 == 0 {pool_remove(&p, h)}
	}
	testing.expect_value(t, p.count, 3)
}

@(test)
test_pool_in_arena :: proc(t: ^testing.T) {
	// The intended lifetime pattern: a session arena owns the pool and is
	// freed in one go, no pool_destroy.
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	p: Pool(Test_Item, Test_Handle)
	testing.expect(t, pool_init(&p, 1000, virtual.arena_allocator(&arena)) == nil)
	h, _, ok := pool_add(&p, Test_Item{42})
	testing.expect(t, ok && pool_get(&p, h).value == 42)
}

@(test)
test_pool_generation_wraps :: proc(t: ^testing.T) {
	p: Pool(Test_Item, Test_Handle)
	testing.expect(t, pool_init(&p, 1) == nil)
	defer pool_destroy(&p)
	h: Test_Handle
	for _ in 0 ..< POOL_GEN_MASK + 2 {
		h, _, _ = pool_add(&p, Test_Item{})
		testing.expect(t, h != 0) // index bits keep a wrapped handle non-zero
		pool_remove(&p, h)
	}
}

@(test)
test_fixed_map_never_grows :: proc(t: ^testing.T) {
	for n in ([]int{6, 100, 6144, 6220, 10_000}) {
		m, err := map_make_fixed(map[int]int, n)
		testing.expect(t, err == nil)
		capacity := cap(m)
		for i in 0 ..< n {m[i] = i}
		testing.expectf(
			t,
			cap(m) == capacity,
			"map for %d entries grew from %d to %d",
			n,
			capacity,
			cap(m),
		)
		// Churn (delete and insert other keys) at full size: still no growth.
		for i in 0 ..< n {
			delete_key(&m, i)
			m[i + n] = i
		}
		testing.expectf(t, cap(m) == capacity, "map for %d entries grew under churn", n)
		delete(m)
	}
}
