package base

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

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
	testing.expect(t, !queue_wait(&q, time.Millisecond)) // empty: times out

	testing.expect(t, queue_push(&q, 4))
	queue_close(&q)
	testing.expect(t, !queue_push(&q, 5))
	v, ok = queue_pop(&q) // queued before closing: still delivered
	testing.expect(t, ok && v == 4)
	_, ok = queue_pop(&q) // closed and empty: does not block
	testing.expect(t, !ok)
}

@(test)
test_queue_many_producers :: proc(t: ^testing.T) {
	PRODUCERS :: 8
	PER :: 10_000
	q: Queue(int)
	queue_init(&q)
	defer queue_destroy(&q)

	threads: [PRODUCERS]^thread.Thread
	for &th, i in threads {
		th = thread.create_and_start_with_poly_data2(&q, i, proc(q: ^Queue(int), id: int) {
			for n in 0 ..< PER {queue_push(q, id * PER + n)}
		})
	}
	// Consume while producing; each producer's values arrive in order.
	last: [PRODUCERS]int = -1
	got := 0
	out: [dynamic]int
	defer delete(out)
	for got < PRODUCERS * PER {
		queue_wait(&q, 10 * time.Millisecond)
		clear(&out)
		queue_drain(&q, &out)
		for v in out {
			id := v / PER
			if v <= last[id] {testing.fail_now(t, "values reordered")}
			last[id] = v
		}
		got += len(out)
	}
	for th in threads {thread.join(th); thread.destroy(th)}
	testing.expect_value(t, got, PRODUCERS * PER)
	testing.expect_value(t, queue_len(&q), 0)
}

@(test)
test_jobs_run_everything :: proc(t: ^testing.T) {
	JOBS :: 2000
	Shared :: struct {
		sum:  int,
		temp: int,
	}
	shared: Shared
	jobs: Jobs
	jobs_init(&jobs, "test", 4)
	for _ in 0 ..< JOBS {
		jobs_submit(
			&jobs,
			proc(data: rawptr) {
				s := (^Shared)(data)
				_ = make([]u8, 4096, context.temp_allocator) // freed per job
				sync.atomic_add(&s.sum, 1)
			},
			&shared,
		)
	}
	jobs_destroy(&jobs) // waits for all of them, even unstarted ones
	testing.expect_value(t, shared.sum, JOBS)
}

@(test)
test_jobs_see_stopping :: proc(t: ^testing.T) {
	Shared :: struct {
		jobs:         ^Jobs,
		release:      sync.Sema,
		saw_stopping: int,
	}
	jobs: Jobs
	s := Shared {
		jobs = &jobs,
	}
	jobs_init(&jobs, "test", 1)
	// The first job holds the only worker until shutdown has begun.
	jobs_submit(&jobs, proc(data: rawptr) {sync.sema_wait(&(^Shared)(data).release)}, &s)
	for _ in 0 ..< 5 {
		jobs_submit(&jobs, proc(data: rawptr) {
				s := (^Shared)(data)
				if jobs_stopping(s.jobs) {sync.atomic_add(&s.saw_stopping, 1)}
			}, &s)
	}
	testing.expect_value(t, jobs_pending(&jobs), 6)
	releaser := thread.create_and_start_with_poly_data(&s, proc(s: ^Shared) {
		for !jobs_stopping(s.jobs) {thread.yield()}
		sync.sema_post(&s.release)
	})
	jobs_destroy(&jobs)
	thread.join(releaser)
	thread.destroy(releaser)
	testing.expect_value(t, s.saw_stopping, 5) // queued jobs still ran, seeing the flag
}
