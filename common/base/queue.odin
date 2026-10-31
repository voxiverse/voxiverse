package base

import "core:sync"
import "core:time"

// Queue passes values between threads: any number of producers and
// consumers, unbounded (a full queue would have to block or drop, and
// dropping fails silently). Consumers either take everything at once
// (queue_drain, once per frame or tick) or block for one value (queue_pop).
//
// Values still queued when the queue is destroyed are freed with it, so
// values that own memory must be drained first.
Queue :: struct($T: typeid) {
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	items:  [dynamic]T,
	head:   int, // items[head:] are queued
	closed: bool,
}

queue_init :: proc(q: ^Queue($T), allocator := context.allocator, loc := #caller_location) {
	q^ = {}
	q.items = make([dynamic]T, allocator, loc)
}

queue_destroy :: proc(q: ^Queue($T)) {
	delete(q.items)
	q^ = {}
}

// queue_push adds v; false (v not queued) once the queue is closed.
queue_push :: proc(q: ^Queue($T), v: T) -> bool {
	sync.guard(&q.mutex)
	if q.closed {return false}
	if q.head > 0 && q.head == len(q.items) {
		clear(&q.items) // empty: start over at the front instead of growing
		q.head = 0
	}
	append(&q.items, v)
	sync.cond_signal(&q.cond)
	return true
}

// queue_drain appends every queued value to out, in push order, and
// returns how many.
queue_drain :: proc(q: ^Queue($T), out: ^[dynamic]T) -> int {
	sync.guard(&q.mutex)
	n := len(q.items) - q.head
	append(out, ..q.items[q.head:])
	clear(&q.items)
	q.head = 0
	return n
}

// queue_pop blocks until a value is queued and takes it; ok is false once
// the queue is closed and empty.
queue_pop :: proc(q: ^Queue($T)) -> (v: T, ok: bool) {
	sync.guard(&q.mutex)
	for q.head == len(q.items) {
		if q.closed {return}
		sync.cond_wait(&q.cond, &q.mutex)
	}
	v = q.items[q.head]
	q.head += 1
	return v, true
}

// queue_wait blocks until something is queued, the queue is closed or the
// timeout passes; true if something is queued.
queue_wait :: proc(q: ^Queue($T), timeout: time.Duration) -> bool {
	sync.guard(&q.mutex)
	deadline := time.tick_add(time.tick_now(), timeout)
	for q.head == len(q.items) && !q.closed {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 {break}
		sync.cond_wait_with_timeout(&q.cond, &q.mutex, left)
	}
	return q.head < len(q.items)
}

// queue_close stops new pushes and wakes every waiting consumer; values
// already queued can still be taken.
queue_close :: proc(q: ^Queue($T)) {
	sync.guard(&q.mutex)
	q.closed = true
	sync.cond_broadcast(&q.cond)
}

queue_len :: proc(q: ^Queue($T)) -> int {
	sync.guard(&q.mutex)
	return len(q.items) - q.head
}
