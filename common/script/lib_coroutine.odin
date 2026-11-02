package script

// Coroutines. Each is a Thread with its own stack; resume and yield switch the current
// thread inside the one dispatch loop (they are intrinsics: precall runs them), so a
// yield crosses pcall, metamethods and the prelude. A budget suspension or a host yield
// inside a coroutine suspends the whole run: every thread in the resume chain keeps its
// state. The values a stopped thread waits for go where its Thread.wait_* fields say.

COROUTINE_NATIVES := [?]Native_Spec {
	{name = "coroutine.create", fn = co_create},
	{name = "coroutine.resume", fn = base_intrinsic_stub},
	{name = "coroutine.yield", fn = base_intrinsic_stub},
	{name = "coroutine.wrap", fn = co_wrap},
	{name = "coroutine.wrapped", fn = base_intrinsic_stub},
	{name = "coroutine.status", fn = co_status},
	{name = "coroutine.isyieldable", fn = co_isyieldable},
	{name = "coroutine.running", fn = co_running},
	{name = "coroutine.close", fn = co_close},
}

open_coroutine :: proc(vm: ^VM) -> bool {
	t := lib_table(vm, "coroutine") or_return
	for name in ([?]string{"create", "wrap", "status", "isyieldable", "running", "close"}) {
		lib_bind(vm, t, name, native_value(vm, lib_name("coroutine", name))) or_return
	}
	lib_bind(
		vm,
		t,
		"resume",
		native_closure(vm, find_native(vm, "coroutine.resume"), .Resume),
	) or_return
	lib_bind(
		vm,
		t,
		"yield",
		native_closure(vm, find_native(vm, "coroutine.yield"), .Yield),
	) or_return
	return true
}

// base_intrinsic_stub: an intrinsic's native, never run (precall runs the intrinsic).
base_intrinsic_stub :: proc(c: ^Native_Call) -> Native_Status {
	return raise(c, "'%s' cannot be called from here", c.name)
}

thread_new :: proc(vm: ^VM, fn: Value) -> Ref {
	r := heap_alloc(vm, .Thread, size_of(Thread))
	if r == 0 {return 0}
	stack := alloc_values(vm, 32)
	if stack == 0 {return 0}
	frames := alloc_bytes(vm, 8 * size_of(Frame))
	if frames == 0 {return 0}
	th := obj(vm, r, Thread)
	th.stack = stack
	th.stack_cap = 32
	th.frames = frames
	th.frame_cap = 8
	th.status = .Suspended
	values_of(vm, stack, 32)[0] = fn
	th.top = 1
	return r
}

@(private = "file")
co_create :: proc(c: ^Native_Call) -> Native_Status {
	f := check_function(c, 1) or_return
	r := thread_new(c.vm, f)
	if r == 0 {return .Error}
	return push_value(c, ref_value(.Thread, r))
}

@(private = "file")
co_wrap :: proc(c: ^Native_Call) -> Native_Status {
	f := check_function(c, 1) or_return
	vm := c.vm
	r := thread_new(vm, f)
	if r == 0 {return .Error}
	push_value(c, ref_value(.Thread, r)) or_return
	w := heap_alloc(vm, .Native_Closure, NATIVE_UPVALS + size_of(Value))
	if w == 0 {return .Error}
	nc := obj(vm, w, Native_Closure)
	nc.native = u32(find_native(vm, "coroutine.wrapped"))
	nc.intrinsic = .Wrap
	nc.nup = 1
	native_upvals(vm, w)[0] = ref_value(.Thread, r)
	c.th.top -= 1
	return push_value(c, ref_value(.Function, w))
}

@(private = "file")
check_thread :: proc(c: ^Native_Call, i: int) -> (Ref, Native_Status) {
	v := arg(c, i)
	if v.tag == .Thread {return as_ref(v), .Ok}
	got := "no value" if i > int(c.nargs) else type_name(v)
	return 0, arg_error(c, i, fmt_expected("coroutine", got))
}

fmt_expected :: proc(want, got: string) -> string {
	return concat_temp(want, " expected, got ", got)
}

thread_status_name :: proc(vm: ^VM, r: Ref) -> string {
	if r == vm.current {return "running"}
	switch obj(vm, r, Thread).status {
	case .Suspended:
		return "suspended"
	case .Running:
		return "running"
	case .Normal:
		return "normal"
	case .Dead:
		return "dead"
	}
	return "dead"
}

@(private = "file")
co_status :: proc(c: ^Native_Call) -> Native_Status {
	r := check_thread(c, 1) or_return
	return push_string(c, thread_status_name(c.vm, r))
}

@(private = "file")
co_isyieldable :: proc(c: ^Native_Call) -> Native_Status {
	return push_bool(c, c.vm.current != c.vm.main_thread)
}

@(private = "file")
co_running :: proc(c: ^Native_Call) -> Native_Status {
	push_value(c, ref_value(.Thread, c.vm.current)) or_return
	return push_bool(c, c.vm.current == c.vm.main_thread)
}

@(private = "file")
co_close :: proc(c: ^Native_Call) -> Native_Status {
	r := check_thread(c, 1) or_return
	vm := c.vm
	th := obj(vm, r, Thread)
	if r == vm.current || th.status == .Running || th.status == .Normal {
		return raise(c, "cannot close a %s coroutine", thread_status_name(vm, r))
	}
	thread_kill(vm, th)
	return push_bool(c, true)
}

// thread_kill: a coroutine dead, its upvalues closed, its frames and stack gone.
thread_kill :: proc(vm: ^VM, th: ^Thread) {
	close_upvals(vm, th, 0)
	th.frame_count = 0
	th.top = 0
	th.status = .Dead
	th.resumer = 0
	th.wait_flags = {}
	th.wait_cont = .None
}

// The intrinsics.

// can_wait: a native called with this continuation can stop and be given its results
// later (the values finish the interrupted instruction then).
@(private = "file")
can_wait :: proc(cont: Cont) -> bool {
	#partial switch cont {
	case .None, .Store, .Compare, .Discard, .Concat:
		return true
	}
	return false
}

set_wait :: proc(
	th: ^Thread,
	slot: u32,
	nres: i16,
	cont: Cont,
	cont_arg: u32,
	flags: bit_set[Wait_Flag;u8],
) {
	th.wait_slot = slot
	th.wait_nres = nres
	th.wait_cont = cont
	th.wait_arg = cont_arg
	th.wait_flags = flags
}

// deliver gives a waiting thread n values from its own stack at src.
deliver :: proc(vm: ^VM, th: ^Thread, src, n: u32) -> bool {
	slot := th.wait_slot
	flags := th.wait_flags
	cont := th.wait_cont
	arg := th.wait_arg
	nres := th.wait_nres
	th.wait_flags = {}
	th.wait_cont = .None
	stack := thread_stack(vm, th)
	count := n
	if .True_Prefix in flags {
		for i in 0 ..< n {stack[slot + 1 + i] = stack[src + i]}
		stack[slot] = TRUE
		count += 1
		move_results(vm, th, slot, count, slot, nres)
	} else {
		move_results(vm, th, src, n, slot, nres)
	}
	if cont != .None {
		stack = thread_stack(vm, th)
		return finish_cont(vm, th, cont, arg, stack[slot] if count > 0 else NIL)
	}
	return true
}

// transfer copies n values from one thread's stack to where the other waits, and
// delivers them there.
@(private = "file")
transfer :: proc(vm: ^VM, from: ^Thread, src, n: u32, to: ^Thread) -> bool {
	at := to.wait_slot + 1
	if !ensure_stack(vm, to, at + n + 1 + EXTRA_STACK) {return false}
	dst := thread_stack(vm, to)
	sv := thread_stack(vm, from)
	for i in 0 ..< n {dst[at + i] = sv[src + i]}
	return deliver(vm, to, at, n)
}

// switch_to makes r the current thread.
@(private = "file")
switch_to :: proc(vm: ^VM, r: Ref) {
	vm.current = r
	obj(vm, r, Thread).status = .Running
}

// call_resume: coroutine.resume(co, ...) (wrap false) or a wrap function's call.
call_resume :: proc(
	vm: ^VM,
	th: ^Thread,
	func, nargs: u32,
	nresults: i16,
	cont: Cont,
	cont_arg: u32,
	wrap: bool,
) -> Call_Status {
	name := "coroutine.wrap" if wrap else "coroutine.resume"
	if !can_wait(cont) {
		rt_errorf(vm, "call it from script code", "'%s' cannot be called from here", name)
		return .Error
	}
	stack := thread_stack(vm, th)
	first := func + 1
	n := nargs
	co: Ref
	if wrap {
		co = as_ref(native_upvals(vm, as_ref(stack[func]))[0])
	} else {
		if nargs == 0 || stack[func + 1].tag != .Thread {
			got := type_name(stack[func + 1]) if nargs > 0 else "no value"
			rt_errorf(
				vm,
				"",
				"bad argument #1 to 'coroutine.resume' (coroutine expected, got %s)",
				got,
			)
			return .Error
		}
		co = as_ref(stack[func + 1])
		first += 1
		n -= 1
	}
	cth := obj(vm, co, Thread)
	if cth.status != .Suspended || co == vm.current {
		what := "dead" if cth.status == .Dead else "non-suspended"
		msg := concat_temp("cannot resume ", what, " coroutine")
		if wrap {
			rt_error(vm, msg)
			return .Error
		}
		sv := new_string(vm, msg)
		if sv.tag == .Nil {return .Error}
		stack = thread_stack(vm, th)
		stack[func] = FALSE
		stack[func + 1] = sv
		move_results(vm, th, func, 2, func, nresults)
		if cont != .None && !finish_cont(vm, th, cont, cont_arg, FALSE) {return .Error}
		return .Native_Done
	}
	flags: bit_set[Wait_Flag;u8] = {.Wrap} if wrap else {.True_Prefix}
	set_wait(th, func, nresults, cont, cont_arg, flags)
	th.status = .Normal
	cth.resumer = vm.current
	switch_to(vm, co)
	vm.depth += cth.frame_count
	if cth.frame_count == 0 {
		// A fresh coroutine: its function is in slot 0; the arguments go above it.
		if !ensure_stack(vm, cth, 1 + n + EXTRA_STACK) {return .Error}
		cs := thread_stack(vm, cth)
		stack = thread_stack(vm, th)
		for i in 0 ..< n {cs[1 + i] = stack[first + i]}
		cth.top = 1 + n
		switch precall(vm, cth, 0, n, -1, .Resume, 0) {
		case .Script:
			return .Script
		case .Native_Done:
			if !coroutine_return(vm, co, 0, cth.top) {return .Error}
			return .Script
		case .Error:
			return .Error
		}
	}
	// A coroutine stopped in a yield: the arguments are the yield's results.
	if !transfer(vm, th, first, n, cth) {return .Error}
	return .Script
}

// call_yield: coroutine.yield(...): back to the resumer with the arguments.
call_yield :: proc(
	vm: ^VM,
	th: ^Thread,
	func, nargs: u32,
	nresults: i16,
	cont: Cont,
	cont_arg: u32,
) -> Call_Status {
	if vm.current == vm.main_thread || th.resumer == 0 {
		rt_error(
			vm,
			"attempt to yield from outside a coroutine",
			"only code a coroutine runs can yield",
		)
		return .Error
	}
	if !can_wait(cont) {
		rt_error(vm, "'coroutine.yield' cannot be called from here", "call it from script code")
		return .Error
	}
	set_wait(th, func, nresults, cont, cont_arg, {})
	rr := th.resumer
	th.resumer = 0
	th.status = .Suspended
	vm.depth -= th.frame_count
	switch_to(vm, rr)
	if !transfer(vm, th, func + 1, nargs, obj(vm, rr, Thread)) {return .Error}
	return .Script
}

// coroutine_return: the coroutine's function returned n values from src; it is dead and
// its resumer goes on with them.
coroutine_return :: proc(vm: ^VM, co: Ref, src, n: u32) -> bool {
	cth := obj(vm, co, Thread)
	rr := cth.resumer
	cth.status = .Dead
	cth.resumer = 0
	switch_to(vm, rr)
	ok := transfer(vm, cth, src, n, obj(vm, rr, Thread))
	cth = obj(vm, co, Thread)
	cth.top = 0
	return ok
}

// coroutine_error: an error nothing in the coroutine caught. The coroutine dies; its
// resumer gets false and the value (resume), or the error again (wrap: true returned).
coroutine_error :: proc(vm: ^VM, value: Value) -> (raise_again: bool, ok: bool) {
	co := vm.current
	cth := obj(vm, co, Thread)
	rr := cth.resumer
	vm.depth -= cth.frame_count
	thread_kill(vm, cth)
	switch_to(vm, rr)
	rth := obj(vm, rr, Thread)
	if .Wrap in rth.wait_flags {
		rth.wait_flags = {}
		rth.wait_cont = .None
		return true, true
	}
	slot := rth.wait_slot
	if !ensure_stack(vm, rth, slot + 2 + EXTRA_STACK) {return false, false}
	stack := thread_stack(vm, rth)
	stack[slot + 1] = FALSE
	stack[slot + 2] = value
	rth.wait_flags = {}
	set_flags := rth.wait_cont
	_ = set_flags
	// Deliver false, value without the true prefix.
	return false, deliver(vm, rth, slot + 1, 2)
}

// unwind_threads: a run ended by an error or a fault: every coroutine in the resume
// chain dies, and the main thread is current again.
unwind_threads :: proc(vm: ^VM) {
	for r := vm.current; r != 0 && r != vm.main_thread; {
		th := obj(vm, r, Thread)
		next := th.resumer
		thread_kill(vm, th)
		r = next
	}
	vm.current = vm.main_thread
	m := obj(vm, vm.main_thread, Thread)
	m.status = .Running
	m.wait_flags = {}
	m.wait_cont = .None
}
