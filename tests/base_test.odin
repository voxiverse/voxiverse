package tests

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "common:base"

// The queue and the job pool across real threads, and the thread CPU clock:
// base's own tests (queue_test.odin) run on one thread.

@(test)
test_a_queue_wait_times_out_when_empty :: proc(t: ^testing.T) {
	q: base.Queue(int)
	base.queue_init(&q)
	defer base.queue_destroy(&q)
	testing.expect(t, !base.queue_wait(&q, time.Millisecond))
}

@(test)
test_queue_many_producers :: proc(t: ^testing.T) {
	PRODUCERS :: 8
	PER :: 10_000
	q: base.Queue(int)
	base.queue_init(&q)
	defer base.queue_destroy(&q)

	threads: [PRODUCERS]^thread.Thread
	for &th, i in threads {
		th = thread.create_and_start_with_poly_data2(&q, i, proc(q: ^base.Queue(int), id: int) {
			for n in 0 ..< PER {base.queue_push(q, id * PER + n)}
		})
	}
	// Consume while producing; each producer's values arrive in order.
	last: [PRODUCERS]int = -1
	got := 0
	out: [dynamic]int
	defer delete(out)
	for got < PRODUCERS * PER {
		base.queue_wait(&q, 10 * time.Millisecond)
		clear(&out)
		base.queue_drain(&q, &out)
		for v in out {
			id := v / PER
			if v <= last[id] {testing.fail_now(t, "values reordered")}
			last[id] = v
		}
		got += len(out)
	}
	for th in threads {thread.join(th); thread.destroy(th)}
	testing.expect_value(t, got, PRODUCERS * PER)
	testing.expect_value(t, base.queue_len(&q), 0)
}

@(test)
test_jobs_run_everything :: proc(t: ^testing.T) {
	JOBS :: 2000
	Shared :: struct {
		sum:  int,
		temp: int,
	}
	shared: Shared
	jobs: base.Jobs
	base.jobs_init(&jobs, "test", 4)
	for _ in 0 ..< JOBS {
		base.jobs_submit(
			&jobs,
			proc(data: rawptr) {
				s := (^Shared)(data)
				_ = make([]u8, 4096, context.temp_allocator) // freed per job
				sync.atomic_add(&s.sum, 1)
			},
			&shared,
		)
	}
	base.jobs_destroy(&jobs) // waits for all of them, even unstarted ones
	testing.expect_value(t, shared.sum, JOBS)
}

@(test)
test_jobs_see_stopping :: proc(t: ^testing.T) {
	Shared :: struct {
		jobs:         ^base.Jobs,
		release:      sync.Sema,
		saw_stopping: int,
	}
	jobs: base.Jobs
	s := Shared {
		jobs = &jobs,
	}
	base.jobs_init(&jobs, "test", 1)
	// The first job holds the only worker until shutdown has begun.
	base.jobs_submit(&jobs, proc(data: rawptr) {sync.sema_wait(&(^Shared)(data).release)}, &s)
	for _ in 0 ..< 5 {
		base.jobs_submit(&jobs, proc(data: rawptr) {
				s := (^Shared)(data)
				if base.jobs_stopping(s.jobs) {sync.atomic_add(&s.saw_stopping, 1)}
			}, &s)
	}
	testing.expect_value(t, base.jobs_pending(&jobs), 6)
	releaser := thread.create_and_start_with_poly_data(&s, proc(s: ^Shared) {
		for !base.jobs_stopping(s.jobs) {thread.yield()}
		sync.sema_post(&s.release)
	})
	base.jobs_destroy(&jobs)
	thread.join(releaser)
	thread.destroy(releaser)
	testing.expect_value(t, s.saw_stopping, 5) // queued jobs still ran, seeing the flag
}


// The thread CPU clock must tick in steps well under 1 ms on every OS.
// Windows used to advance in 15625 us steps (GetThreadTimes ticks). The test
// reads the clock itself, not the wall clock: it spins until 5 ms of this
// thread's CPU time have passed and looks at the smallest step between two
// different readings. Preemption by other threads or processes takes no CPU
// time from this clock, so it cannot change the result; a coarse clock has no
// step below its tick.
@(test)
test_thread_cpu_us_resolves_under_a_millisecond :: proc(t: ^testing.T) {
	guard := time.tick_now()
	start := base.thread_cpu_us()
	last := start
	smallest := max(i64)
	for last - start < 5000 {
		now := base.thread_cpu_us()
		if now != last {
			smallest = min(smallest, now - last)
			last = now
		}
		if time.duration_seconds(time.tick_since(guard)) > 30 {break}
	}
	testing.expectf(
		t,
		smallest < 1000,
		"thread CPU time advanced in steps of at least %d us (%d us seen)",
		smallest,
		last - start,
	)
}
