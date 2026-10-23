package base

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:thread"

// Jobs runs procedures on worker threads. Workers inherit the creating
// thread's context (logger, assertion handler, allocator), so logging and
// asserts in jobs behave as on the main thread; each has its own temp
// allocator, freed after every job.
//
// A job owns its data until it finishes and reports back however its owner
// chooses (usually a Queue the owner drains). Every submitted job runs, even
// during shutdown, so whatever it owns is always handed back or freed; long
// jobs check jobs_stopping to skip their work.
//
//	jobs_init(&jobs, "mesh", 3)
//	jobs_submit(&jobs, mesh_job, task)
//	...
//	jobs_destroy(&jobs) // runs what is queued, then joins the workers

Job_Proc :: #type proc(data: rawptr)

Jobs :: struct {
	queue:     Queue(Job),
	threads:   []^thread.Thread,
	names:     []string,
	pending:   int, // submitted and not finished (atomic)
	stopping:  bool, // (atomic)
	allocator: mem.Allocator,
}

@(private)
Job :: struct {
	procedure: Job_Proc,
	data:      rawptr,
}

@(private = "file")
Worker :: struct {
	jobs: ^Jobs,
	name: string,
}

// jobs_init starts count workers named "<name> 1", "<name> 2", ...
jobs_init :: proc(
	j: ^Jobs,
	name: string,
	count: int,
	allocator := context.allocator,
	loc := #caller_location,
) {
	assert(count > 0, "a job pool needs a worker", loc)
	j^ = {
		allocator = allocator,
	}
	queue_init(&j.queue, allocator, loc)
	j.threads = make([]^thread.Thread, count, allocator, loc)
	j.names = make([]string, count, allocator, loc)
	ctx := context
	ctx.allocator = allocator
	for i in 0 ..< count {
		j.names[i] = fmt.aprintf("%s %d", name, i + 1, allocator = allocator)
		t := thread.create(worker_main)
		t.data = j
		t.user_index = i
		t.init_context = ctx
		j.threads[i] = t
		thread.start(t)
	}
}

// jobs_destroy runs every queued job (jobs_stopping is true for them), then
// joins and frees the workers.
jobs_destroy :: proc(j: ^Jobs) {
	sync.atomic_store(&j.stopping, true)
	queue_close(&j.queue)
	for t in j.threads {
		thread.join(t)
		thread.destroy(t)
	}
	assert(sync.atomic_load(&j.pending) == 0)
	for n in j.names {delete(n, j.allocator)}
	delete(j.names, j.allocator)
	delete(j.threads, j.allocator)
	queue_destroy(&j.queue)
	j^ = {}
}

jobs_submit :: proc(j: ^Jobs, procedure: Job_Proc, data: rawptr) {
	sync.atomic_add(&j.pending, 1)
	ok := queue_push(&j.queue, Job{procedure, data})
	assert(ok, "job submitted after jobs_destroy started")
}

// jobs_pending counts jobs submitted and not yet finished.
jobs_pending :: proc(j: ^Jobs) -> int {
	return sync.atomic_load(&j.pending)
}

jobs_stopping :: proc(j: ^Jobs) -> bool {
	return sync.atomic_load(&j.stopping)
}

jobs_worker_count :: proc(j: ^Jobs) -> int {
	return len(j.threads)
}

@(private = "file")
worker_main :: proc(t: ^thread.Thread) {
	j := (^Jobs)(t.data)
	profile_thread_start(j.names[t.user_index])
	for job in queue_pop(&j.queue) {
		job.procedure(job.data)
		free_all(context.temp_allocator)
		sync.atomic_sub(&j.pending, 1)
	}
	profile_thread_stop()
	// Given an init_context, the thread leaves its temp allocator to us.
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
}
