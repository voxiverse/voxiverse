package base

import "core:testing"

@(test)
test_queue_order_and_close :: proc(t: ^testing.T) {
	q: Queue(int)
	queue_init(&q)
	defer queue_destroy(&q)

	for i in 1 ..= 3 {testing.expect(t, queue_push(&q, i))}
	v, ok := queue_pop(&q)
	testing.expect(t, ok && v == 1)
	out: [dynamic]int
	defer delete(out)
	testing.expect_value(t, queue_drain(&q, &out), 2)
	testing.expect(t, len(out) == 2 && out[0] == 2 && out[1] == 3)

	testing.expect(t, queue_push(&q, 4))
	queue_close(&q)
	testing.expect(t, !queue_push(&q, 5))
	v, ok = queue_pop(&q) // queued before closing: still delivered
	testing.expect(t, ok && v == 4)
	_, ok = queue_pop(&q) // closed and empty: does not block
	testing.expect(t, !ok)
}
