package script

import "core:fmt"
import "core:mem"

// The collector: incremental tri-colour mark and sweep over the heap, non-moving and
// deterministic (its work is counted in bytes, never in time). Steps run at instruction
// boundaries inside a run, so an Odin local never needs to be a root; the full collection
// before the memory fault runs inside an allocation, and the objects made since the last
// boundary (vm.fresh) are its extra roots.

WHITE0 :: 0
WHITE1 :: 1
GRAY :: 2
BLACK :: 3

Gc_Phase :: enum u8 {
	Pause,
	Propagate,
	Atomic,
	Sweep,
}

// Gc_Params: the pacing (snapshotted with the VM).
Gc_Params :: struct {
	pause:         u32, // a cycle starts when in use reaches estimate * pause / 100
	stepmul:       u32, // a step does allocated * stepmul / 100 units of work
	step_bytes:    u32, // allocation between steps during a cycle
	min_threshold: u64, // a cycle never starts below this
}

DEFAULT_GC_PARAMS :: Gc_Params {
	pause         = 200,
	stepmul       = 200,
	step_bytes    = 8 << 10,
	min_threshold = 256 << 10,
}

// STRESS_STEP_MIN: the least work of a step under gc_stress (every allocation steps).
STRESS_STEP_MIN :: 512

Gc_State :: struct {
	phase:       Gc_Phase,
	white:       u8, // the current white
	emergency:   bool, // a full collection inside an allocation
	collecting:  bool,
	gray:        Ref,
	grayagain:   Ref,
	sweep:       u32, // the sweep's cursor
	sweep_run:   u32, // where the free run behind the cursor begins (0: none)
	credit:      i64, // bytes to allocate before the next step
	allocated:   i64, // bytes allocated since the last step
	estimate:    u64, // bytes in use after the last sweep
	threshold:   u64,
	collections: u64, // cycles finished
	units:       u64, // work done, all cycles
	peak:        u64, // the most bytes in use
}

// Memory statistics a host reads (M52's /script list, the profiler).
Vm_Stats :: struct {
	heap_used:   u64,
	heap_peak:   u64,
	collections: u64,
	units:       u64, // the collector's work, all cycles
	run_units:   u64, // instruction units the last run used (all its slices)
}

vm_stats :: proc(vm: ^VM) -> Vm_Stats {
	return Vm_Stats {
		heap_used = vm.in_use,
		heap_peak = vm.gc.peak,
		collections = vm.gc.collections,
		units = vm.gc.units,
		run_units = u64(max(vm.run_used, 0)),
	}
}

gc_init :: proc(vm: ^VM, stress: bool) {
	vm.gc_params = DEFAULT_GC_PARAMS
	vm.gc_stress = stress
	if stress {
		vm.gc_params.step_bytes = 0
		vm.gc_params.min_threshold = 0
	}
	vm.gc.threshold = vm.gc_params.min_threshold
	vm.gc.credit = i64(vm.gc.threshold)
}

// gc_safe_point: the collector's step, when allocation has earned one. Called at an
// instruction boundary (nothing but the roots holds a value there).
gc_safe_point :: proc(vm: ^VM) {
	if vm.gc.credit > 0 {return}
	if vm.gc.phase == .Pause {
		if vm.in_use < vm.gc.threshold {
			vm.gc.credit = i64(vm.gc.threshold - vm.in_use)
			vm.gc.allocated = 0
			return
		}
		gc_start(vm)
	}
	work := vm.gc.allocated * i64(vm.gc_params.stepmul) / 100
	if vm.gc_stress {work = max(work, STRESS_STEP_MIN)}
	work = max(work, 1)
	vm.gc.allocated = 0
	phase := vm.gc.phase
	gc_work(vm, work)
	if vm.trace.on {trace_event(vm, "G step %v work=%d inuse=%d", phase, work, vm.in_use)}
	if vm.gc.phase != .Pause {vm.gc.credit = i64(vm.gc_params.step_bytes)}
}

// collect runs a full cycle (finishing the current one first) on an idle VM.
collect :: proc(vm: ^VM) {
	gc_full(vm)
}

// gc_emergency: no room for an allocation inside a run.
gc_emergency :: proc(vm: ^VM) {
	vm.gc.emergency = true
	gc_full(vm)
	vm.gc.emergency = false
}

@(private = "file")
gc_full :: proc(vm: ^VM) {
	if vm.gc.phase != .Pause {gc_work(vm, max(i64))}
	gc_start(vm)
	gc_work(vm, max(i64))
}

// gc_work does up to budget units of the cycle; a cycle ending stops it.
gc_work :: proc(vm: ^VM, budget_in: i64) {
	vm.gc.collecting = true
	defer vm.gc.collecting = false
	budget := budget_in
	for budget > 0 {
		switch vm.gc.phase {
		case .Pause:
			return
		case .Propagate:
			if vm.gc.gray != 0 {
				budget -= propagate_one(vm)
			} else {
				vm.gc.phase = .Atomic
			}
		case .Atomic:
			budget -= atomic(vm)
		case .Sweep:
			budget -= sweep_some(vm, budget)
		}
	}
}

gc_start :: proc(vm: ^VM) {
	vm.gc.gray = 0
	vm.gc.grayagain = 0
	vm.gc.phase = .Propagate
	mark_roots(vm)
}

@(private = "file")
mark_roots :: proc(vm: ^VM) {
	mark_ref(vm, vm.main_thread)
	for th := vm.current; th != 0; th = obj(vm, th, Thread).resumer {mark_ref(vm, th)}
	mark_ref(vm, vm.globals)
	mark_ref(vm, vm.registry)
	mark_ref(vm, vm.string_meta)
	mark_ref(vm, vm.prelude_table)
	mark_ref(vm, vm.handle_metas)
	mark_ref(vm, vm.intern)
	for r in vm.mm_names {mark_ref(vm, r)}
	if vm.err.has_value {mark_value(vm, vm.err.value)}
	if vm.gc.emergency {
		for r in vm.fresh {mark_ref(vm, r)}
	}
}

mark_value :: #force_inline proc(vm: ^VM, v: Value) {
	if v.tag >= .String {mark_ref(vm, as_ref(v))}
}

// mark_ref: a white object turns gray (on the gray list) or, holding no references of
// its own to follow later, black at once.
mark_ref :: proc(vm: ^VM, r: Ref) {
	if r == 0 {return}
	h := (^Header)(&vm.mem[r])
	if h.mark != vm.gc.white {return}
	#partial switch h.kind {
	case .String, .Bytes, .Values:
		h.mark = BLACK
	case .Upvalue:
		h.mark = BLACK
		uv := (^Upvalue)(h)
		if uv.open {
			mark_ref(vm, uv.thread)
		} else {
			mark_value(vm, uv.value)
		}
	case .Table, .Closure, .Native_Closure, .Proto, .Thread:
		h.mark = GRAY
		gclist_of(vm, r)^ = vm.gc.gray
		vm.gc.gray = r
	}
}

@(private = "file")
gclist_of :: proc(vm: ^VM, r: Ref) -> ^Ref {
	#partial switch obj_kind(vm, r) {
	case .Table:
		return &obj(vm, r, Table).gclist
	case .Closure:
		return &obj(vm, r, Closure).gclist
	case .Native_Closure:
		return &obj(vm, r, Native_Closure).gclist
	case .Proto:
		return &obj(vm, r, Proto).gclist
	case .Thread:
		return &obj(vm, r, Thread).gclist
	}
	panic("gclist_of: not a gray kind")
}

// barrier_back: a black table being stored into turns gray again, to be traversed in
// the atomic step.
barrier_back :: #force_inline proc(vm: ^VM, t: Ref) {
	if vm.gc.phase != .Propagate {return}
	tb := (^Table)(&vm.mem[t])
	if tb.mark != BLACK {return}
	tb.mark = GRAY
	tb.gclist = vm.gc.grayagain
	vm.gc.grayagain = t
}

// barrier_forward: a value stored into a black object (a closed upvalue, a metatable
// field) is marked.
barrier_forward :: #force_inline proc(vm: ^VM, owner: Ref, v: Value) {
	if vm.gc.phase != .Propagate || v.tag < .String {return}
	if (^Header)(&vm.mem[owner]).mark != BLACK {return}
	mark_ref(vm, as_ref(v))
}

@(private = "file")
mark_buffer :: #force_inline proc(vm: ^VM, r: Ref) -> i64 {
	if r == 0 {return 0}
	h := (^Header)(&vm.mem[r])
	h.mark = BLACK
	return i64(h.size)
}

@(private = "file")
mark_values :: proc(vm: ^VM, r: Ref, n: u32) -> i64 {
	if r == 0 {return 0}
	for v in values_of(vm, r, n) {mark_value(vm, v)}
	return mark_buffer(vm, r)
}

// propagate_one traverses the first gray object; its work in units.
@(private = "file")
propagate_one :: proc(vm: ^VM) -> i64 {
	r := vm.gc.gray
	vm.gc.gray = gclist_of(vm, r)^
	return traverse(vm, r, false)
}

@(private = "file")
traverse :: proc(vm: ^VM, r: Ref, atomic: bool) -> i64 {
	h := (^Header)(&vm.mem[r])
	h.mark = BLACK
	work := i64(h.size)
	#partial switch h.kind {
	case .Table:
		t := (^Table)(h)
		mark_ref(vm, t.meta)
		work += mark_values(vm, t.arr, t.arr_cap)
		work += mark_values(vm, t.entries, t.entries_len * 2)
		if t.entries != 0 {mark_buffer(vm, t.entries)}
		work += mark_buffer(vm, t.index)
	case .Closure:
		c := (^Closure)(h)
		mark_ref(vm, c.proto)
		mark_ref(vm, c.env)
		for u in closure_upvals(vm, r) {mark_ref(vm, u)}
	case .Native_Closure:
		for v in native_upvals(vm, r) {mark_value(vm, v)}
	case .Proto:
		p := (^Proto)(h)
		work += mark_buffer(vm, p.code)
		work += mark_values(vm, p.consts, p.consts_len)
		work += mark_values(vm, p.protos, p.protos_len)
		work += mark_buffer(vm, p.upvals)
		work += mark_buffer(vm, p.lines)
		work += mark_buffer(vm, p.locals)
		mark_ref(vm, p.source)
		mark_ref(vm, p.name)
		mark_ref(vm, p.text)
		for u in bytes_of(vm, p.upvals, Upval_Desc, p.upvals_len) {mark_ref(vm, Ref(u.name_const))}
		for l in bytes_of(vm, p.locals, Local_Info, p.locals_len) {mark_ref(vm, Ref(l.name_const))}
	case .Thread:
		work += traverse_thread(vm, r, atomic)
	}
	return work
}

// thread_live_top: the slots of a thread's stack in use (its top, or its top frame's
// registers when they reach higher).
thread_live_top :: proc(vm: ^VM, th: ^Thread) -> u32 {
	n := th.top
	if th.frame_count > 0 {n = max(n, top_frame(vm, th).top)}
	return min(n, th.stack_cap)
}

@(private = "file")
traverse_thread :: proc(vm: ^VM, r: Ref, atomic: bool) -> i64 {
	th := obj(vm, r, Thread)
	work: i64
	if th.stack != 0 {
		stack := thread_stack(vm, th)
		live := thread_live_top(vm, th)
		// An emergency collection runs inside an instruction, where slots above the top
		// may hold what the instruction is making: it keeps them all.
		if vm.gc.emergency {live = th.stack_cap}
		for v in stack[:live] {mark_value(vm, v)}
		if atomic && !vm.gc.emergency {
			for &v in stack[live:] {v = NIL}
		}
		work += mark_buffer(vm, th.stack) / 4 + i64(live) * 16
	}
	work += mark_buffer(vm, th.frames)
	for u := th.open_upvals; u != 0; u = obj(vm, u, Upvalue).next_open {mark_ref(vm, u)}
	mark_ref(vm, th.resumer)
	if !atomic {
		// Threads have no barrier: they stay gray and are traversed again atomically.
		th.mark = GRAY
		th.gclist = vm.gc.grayagain
		vm.gc.grayagain = r
	}
	return work
}

// atomic: the roots and everything stored into since, marked to the end; then the
// whites flip and the sweep begins.
@(private = "file")
atomic :: proc(vm: ^VM) -> i64 {
	work: i64
	mark_roots(vm)
	for vm.gc.gray != 0 || vm.gc.grayagain != 0 {
		for vm.gc.gray != 0 {
			r := vm.gc.gray
			vm.gc.gray = gclist_of(vm, r)^
			work += traverse(vm, r, true)
		}
		for vm.gc.grayagain != 0 {
			r := vm.gc.grayagain
			vm.gc.grayagain = gclist_of(vm, r)^
			work += traverse(vm, r, true)
		}
	}
	vm.gc.white ~= 1
	vm.gc.phase = .Sweep
	vm.gc.sweep = HEAP_START
	vm.gc.sweep_run = 0
	vm.free_small = {}
	vm.free_large = {}
	vm.gc.units += u64(work)
	return work
}

// sweep_some walks blocks from the cursor: a block of the other white is freed (its
// string out of the intern index), free neighbours merge, live blocks turn the current
// white. Returns its work (bytes passed / 8).
@(private = "file")
sweep_some :: proc(vm: ^VM, budget: i64) -> i64 {
	work: i64
	dead_white := vm.gc.white ~ 1
	for work < budget && vm.gc.sweep < vm.top {
		at := vm.gc.sweep
		h := (^Header)(&vm.mem[at])
		size := h.size
		if h.kind == .Free || h.mark == dead_white {
			if h.kind != .Free {
				if h.kind == .String {intern_remove(vm, Ref(at))}
				vm.in_use -= u64(size)
			}
			mem.zero(h, int(size))
			if vm.gc.sweep_run == 0 {vm.gc.sweep_run = at}
		} else {
			close_run(vm, at)
			h.mark = vm.gc.white
		}
		vm.gc.sweep = at + size
		work += max(i64(size) / 8, 1)
	}
	if vm.gc.sweep >= vm.top {
		if vm.gc.sweep_run != 0 {
			// A free run at the end of the heap lowers top.
			vm.top = vm.gc.sweep_run
			vm.gc.sweep_run = 0
		}
		vm.gc.sweep = 0
		vm.gc.phase = .Pause
		vm.gc.collections += 1
		vm.gc.estimate = vm.in_use
		vm.gc.threshold = max(
			vm.gc_params.min_threshold,
			vm.gc.estimate * u64(vm.gc_params.pause) / 100,
		)
		vm.gc.credit = i64(vm.gc.threshold) - i64(vm.in_use)
	}
	vm.gc.units += u64(work)
	return max(work, 1)
}

// close_run ends the free run behind the cursor at end: one free block, on its list.
@(private = "file")
close_run :: proc(vm: ^VM, end: u32) {
	start := vm.gc.sweep_run
	if start == 0 {return}
	vm.gc.sweep_run = 0
	fb := (^Free_Block)(&vm.mem[start])
	fb.size = end - start
	fb.kind = .Free
	free_push(vm, Ref(start))
}

// heap_check walks the heap: headers sane, every block inside top, bytes in use as the
// blocks say, free lists made of free blocks, every reference of a live object on an
// object of an allowed kind, the intern index made of live strings, and the colours the
// phase allows. Tests and fuzzers run it.
heap_check :: proc(vm: ^VM) -> (ok: bool, problem: string) {
	starts := make([]u8, (vm.top >> 4) / 8 + 1, context.temp_allocator)
	at := u32(HEAP_START)
	in_use: u64
	for at < vm.top {
		h := (^Header)(&vm.mem[at])
		if h.size < 16 || h.size % 16 != 0 || at + h.size > vm.top {
			return false, fmt.tprintf("the block at %d has a bad size", at)
		}
		if h.kind > .Bytes {return false, fmt.tprintf("the block at %d has a bad kind", at)}
		if h.kind != .Free {in_use += u64(h.size)}
		if h.kind != .Free && h.mark > BLACK {
			return false, fmt.tprintf("the block at %d has a bad colour", at)
		}
		idx := at >> 4
		starts[idx / 8] |= 1 << (idx % 8)
		at += h.size
	}
	if at != vm.top {return false, "the blocks do not end at top"}
	if in_use != vm.in_use {return false, "bytes in use disagree with the blocks"}
	for head, i in vm.free_small {
		for b := head; b != 0; b = (^Free_Block)(&vm.mem[b]).next {
			fb := (^Free_Block)(&vm.mem[b])
			if u32(b) >= vm.top || fb.kind != .Free || fb.size != u32(i + 1) * 16 {
				return false, "a small free list holds a wrong block"
			}
		}
	}
	for head in vm.free_large {
		for b := head; b != 0; b = (^Free_Block)(&vm.mem[b]).next {
			fb := (^Free_Block)(&vm.mem[b])
			if u32(b) >= vm.top || fb.kind != .Free || fb.size <= SMALL_MAX {
				return false, "a large free list holds a wrong block"
			}
		}
	}
	Check :: struct {
		vm:     ^VM,
		starts: []u8,
		dead:   u8, // the colour of objects the sweep will free (none: 255)
	}
	ck := Check{vm, starts, 255}
	if vm.gc.phase == .Sweep {ck.dead = vm.gc.white ~ 1}
	is_start :: proc(ck: ^Check, r: Ref) -> bool {
		if r == 0 || u32(r) % 16 != 0 || u32(r) >= ck.vm.top {return false}
		idx := u32(r) >> 4
		return ck.starts[idx / 8] & (1 << (idx % 8)) != 0
	}
	ref_ok :: proc(ck: ^Check, r: Ref, kinds: bit_set[Obj_Kind], may_be_zero := true) -> bool {
		if r == 0 {return may_be_zero}
		if !is_start(ck, r) {return false}
		h := (^Header)(&ck.vm.mem[r])
		if h.kind not_in kinds {return false}
		// A live object never refers to one the sweep will free.
		return ck.dead == 255 || h.mark != ck.dead
	}
	value_ok :: proc(ck: ^Check, v: Value) -> bool {
		switch v.tag {
		case .Nil, .Bool, .Int, .Float, .Handle:
			return true
		case .String:
			return ref_ok(ck, as_ref(v), {.String}, false)
		case .Table:
			return ref_ok(ck, as_ref(v), {.Table}, false)
		case .Function:
			return ref_ok(ck, as_ref(v), {.Closure, .Native_Closure}, false)
		case .Thread:
			return ref_ok(ck, as_ref(v), {.Thread}, false)
		}
		return false
	}
	values_ok :: proc(ck: ^Check, r: Ref, n: u32) -> bool {
		if r == 0 {return true}
		if !ref_ok(ck, r, {.Values}) {return false}
		h := (^Header)(&ck.vm.mem[r])
		if BUF_DATA + int(n) * size_of(Value) > int(h.size) {return false}
		for v in values_of(ck.vm, r, n) {
			if !value_ok(ck, v) {return false}
		}
		return true
	}
	bytes_ok :: proc(ck: ^Check, r: Ref, n: int) -> bool {
		if r == 0 {return n == 0}
		if !ref_ok(ck, r, {.Bytes}) {return false}
		return BUF_DATA + n <= int((^Header)(&ck.vm.mem[r]).size)
	}
	at = HEAP_START
	for at < vm.top {
		h := (^Header)(&vm.mem[at])
		r := Ref(at)
		at += h.size
		if h.kind == .Free || h.mark == ck.dead {continue}
		if vm.gc.phase == .Pause && h.mark != vm.gc.white {
			return false, fmt.tprintf(
				"a %v at %d is not white while the collector rests",
				h.kind,
				r,
			)
		}
		if vm.gc.phase != .Propagate && h.mark == GRAY {
			return false, fmt.tprintf("a %v at %d is gray outside marking", h.kind, r)
		}
		bad := false
		#partial switch h.kind {
		case .String:
			s := (^String)(h)
			bad = STRING_DATA + int(s.len) + 1 > int(h.size)
		case .Table:
			t := (^Table)(h)
			bad =
				!ref_ok(&ck, t.meta, {.Table}) ||
				!values_ok(&ck, t.arr, t.arr_cap) ||
				t.arr_len > t.arr_cap ||
				!values_ok(&ck, t.entries, t.entries_cap * 2) ||
				t.entries_len > t.entries_cap ||
				(t.index != 0 && !bytes_ok(&ck, t.index, int(t.index_mask + 1) * 4))
		case .Closure:
			c := (^Closure)(h)
			bad = !ref_ok(&ck, c.proto, {.Proto}, false) || !ref_ok(&ck, c.env, {.Table}, false)
			if !bad && CLOSURE_UPVALS + int(c.nup) * 4 > int(h.size) {bad = true}
			if !bad {
				for u in closure_upvals(vm, r) {
					// 0 only while CLOSURE fills it in.
					if !ref_ok(&ck, u, {.Upvalue}) {bad = true}
				}
			}
		case .Native_Closure:
			c := (^Native_Closure)(h)
			bad = int(c.native) >= len(vm.natives) || NATIVE_UPVALS + int(c.nup) * 16 > int(h.size)
			if !bad {
				for v in native_upvals(vm, r) {
					if !value_ok(&ck, v) {bad = true}
				}
			}
		case .Upvalue:
			uv := (^Upvalue)(h)
			if uv.open {
				bad =
					!ref_ok(&ck, uv.thread, {.Thread}, false) ||
					!ref_ok(&ck, uv.next_open, {.Upvalue})
			} else {
				bad = !value_ok(&ck, uv.value)
			}
		case .Proto:
			p := (^Proto)(h)
			bad =
				!bytes_ok(&ck, p.code, int(p.code_len) * 4) ||
				!values_ok(&ck, p.consts, p.consts_len) ||
				(p.protos != 0 && !ref_ok(&ck, p.protos, {.Values})) ||
				!bytes_ok(&ck, p.upvals, int(p.upvals_len) * size_of(Upval_Desc)) ||
				!bytes_ok(&ck, p.lines, int(p.code_len) * size_of(Line_Info)) ||
				!bytes_ok(&ck, p.locals, int(p.locals_len) * size_of(Local_Info)) ||
				!ref_ok(&ck, p.source, {.String}) ||
				!ref_ok(&ck, p.name, {.String}) ||
				!ref_ok(&ck, p.text, {.String})
			if !bad {
				for v in values_of(vm, p.protos, p.protos_len) {
					if v.tag != .Function || !ref_ok(&ck, as_ref(v), {.Proto}, false) {bad = true}
				}
			}
		case .Thread:
			th := (^Thread)(h)
			bad =
				!values_ok(&ck, th.stack, th.stack_cap) ||
				th.top > th.stack_cap ||
				!bytes_ok(&ck, th.frames, int(th.frame_cap) * size_of(Frame)) ||
				th.frame_count > th.frame_cap ||
				!ref_ok(&ck, th.open_upvals, {.Upvalue}) ||
				!ref_ok(&ck, th.resumer, {.Thread})
		}
		if bad {return false, fmt.tprintf("a %v at %d has a bad reference", h.kind, r)}
	}
	slots := bytes_of(vm, vm.intern, u32, vm.intern_mask + 1)
	count: u32
	for e in slots {
		if e == 0 {continue}
		count += 1
		if !ref_ok(&ck, Ref(e), {.String}, false) {
			return false, "the intern index holds a dead or wrong block"
		}
	}
	if count != vm.intern_count {return false, "the intern count disagrees with the index"}
	return true, ""
}
