package server

import "core:mem"
import "core:testing"

// An async call runs at the start of the next step, once, with the data as it
// was when it was queued (a copy: the caller's own may change, or be gone),
// and in order with the waiting calls queued beside it.
@(test)
test_call_async_runs_a_copy_at_the_next_tick :: proc(t: ^testing.T) {
	h: Harness
	if !testing.expect(t, harness_start(&h, harness_world())) {return}
	defer harness_stop(&h)

	Seen :: struct {
		values: [dynamic]int,
		ticks:  [dynamic]u64,
	}
	seen: Seen
	defer {delete(seen.values); delete(seen.ticks)}

	Data :: struct {
		seen:  ^Seen,
		value: int,
		pad:   [CALL_DATA_MAX - size_of(^Seen) - size_of(int)]byte, // the most there may be
	}
	record :: proc(s: ^Server, data: rawptr) {
		d := (^Data)(data)
		append(&d.seen.values, d.value)
		append(&d.seen.ticks, s.tick)
	}
	queued_at := h.srv.tick
	d := Data {
		seen  = &seen,
		value = 1,
	}
	call_async(&h.srv, record, mem.ptr_to_bytes(&d))
	d.value = 2
	call_async(&h.srv, record, mem.ptr_to_bytes(&d))
	d.value = 3 // (after both are queued: neither sees it)
	testing.expect_value(t, len(seen.values), 0) // nothing runs before the step
	harness_step(&h)
	harness_step(&h)
	testing.expect_value(t, len(seen.values), 2)
	if len(seen.values) == 2 {
		testing.expect_value(t, seen.values[0], 1)
		testing.expect_value(t, seen.values[1], 2)
		testing.expect_value(t, seen.ticks[0], queued_at + 1)
		testing.expect_value(t, seen.ticks[1], queued_at + 1)
	}
}
