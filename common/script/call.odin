package script

import "core:fmt"
import "core:strings"

// Frames, calls, returns, varargs, continuations, pcall unwinding and upvalues. Nothing
// here recurses into the dispatch loop: a call pushes a frame and the loop goes on.

EXTRA_STACK :: 8 // slots above a frame's registers: a metamethod call's function and arguments
MIN_NATIVE_STACK :: 20
MAX_VARARGS :: 65535

Call_Status :: enum u8 {
	Script, // a frame was pushed
	Native_Done, // a native ran; its results are in place
	Error,
}

thread_stack :: #force_inline proc "contextless" (vm: ^VM, th: ^Thread) -> []Value {
	return values_of(vm, th.stack, th.stack_cap)
}

thread_frames :: #force_inline proc "contextless" (vm: ^VM, th: ^Thread) -> []Frame {
	return bytes_of(vm, th.frames, Frame, th.frame_cap)
}

// frames_drop pops the frames above n and zeroes them: a dead frame's bytes (its last saved
// pc) would otherwise depend on where the run was sliced, and equal states hash equal.
frames_drop :: #force_inline proc "contextless" (vm: ^VM, th: ^Thread, n: u32) {
	frames := thread_frames(vm, th)
	for i in n ..< th.frame_count {frames[i] = {}}
	th.frame_count = n
}

top_frame :: #force_inline proc "contextless" (vm: ^VM, th: ^Thread) -> ^Frame {
	return &thread_frames(vm, th)[th.frame_count - 1]
}

// ensure_stack grows the thread's stack to hold need slots (the buffer may move).
ensure_stack :: proc(vm: ^VM, th: ^Thread, need: u32) -> bool {
	if need <= th.stack_cap {return true}
	cap := max(need, th.stack_cap * 2)
	fresh := alloc_values(vm, cap)
	if fresh == 0 {return false}
	copy(values_of(vm, fresh, cap), values_of(vm, th.stack, th.stack_cap))
	heap_free(vm, th.stack)
	th.stack = fresh
	th.stack_cap = cap
	return true
}

@(private = "file")
push_frame :: proc(vm: ^VM, th: ^Thread) -> ^Frame {
	if th.frame_count == th.frame_cap {
		cap := th.frame_cap * 2
		fresh := alloc_bytes(vm, int(cap) * size_of(Frame))
		if fresh == 0 {return nil}
		copy(bytes_of(vm, fresh, Frame, cap), bytes_of(vm, th.frames, Frame, th.frame_cap))
		heap_free(vm, th.frames)
		th.frames = fresh
		th.frame_cap = cap
	}
	th.frame_count += 1
	return top_frame(vm, th)
}

frame_proto :: #force_inline proc "contextless" (vm: ^VM, th: ^Thread, f: ^Frame) -> ^Proto {
	cl := (^Closure)(&vm.mem[as_ref(thread_stack(vm, th)[f.func])])
	return (^Proto)(&vm.mem[cl.proto])
}

// frame_result_slot: where a frame's results go (its function's slot before varargs moved it).
frame_result_slot :: proc(vm: ^VM, th: ^Thread, f: ^Frame) -> u32 {
	p := frame_proto(vm, th, f)
	if p.is_vararg == 0 {return f.func}
	return f.func - u32(f.nvarargs) - u32(p.num_params) - 1
}

// Metatables.

metatable_of :: proc(vm: ^VM, v: Value) -> Ref {
	#partial switch v.tag {
	case .Table:
		return obj(vm, as_ref(v), Table).meta
	case .String:
		return vm.string_meta
	case .Handle:
		mt := table_get_int(vm, vm.handle_metas, i64(v.kind))
		if mt.tag == .Table {return as_ref(mt)}
	}
	return 0
}

get_mm :: proc(vm: ^VM, v: Value, m: Metamethod) -> Value {
	mt := metatable_of(vm, v)
	if mt == 0 {return NIL}
	return mt_field(vm, mt, m)
}

mt_field :: proc(vm: ^VM, mt: Ref, m: Metamethod) -> Value {
	t := obj(vm, mt, Table)
	bit := u16(1) << u16(m) if int(m) < 16 else 0
	if t.mm_absent & bit != 0 {return NIL}
	h := table_get_str(vm, mt, ref_value(.String, vm.mm_names[m]))
	if h.tag == .Nil {obj(vm, mt, Table).mm_absent |= bit}
	return h
}

// Calls.

// resolve_call makes stack[func] a function, inserting __call handlers before it.
resolve_call :: proc(vm: ^VM, th: ^Thread, func: u32, nargs: ^u32) -> bool {
	for _ in 0 ..< 100 {
		stack := thread_stack(vm, th)
		v := stack[func]
		if v.tag == .Function {return true}
		h := get_mm(vm, v, .Call)
		if h.tag == .Nil {return call_error(vm, th, func, v)}
		top := func + 1 + nargs^
		if !ensure_stack(vm, th, top + 1 + EXTRA_STACK) {return false}
		stack = thread_stack(vm, th)
		for i := top; i > func; i -= 1 {stack[i] = stack[i - 1]}
		stack[func] = h
		nargs^ += 1
		th.top = top + 1
	}
	return rt_error(vm, "'__call' chain too long; possible loop")
}

@(private = "file")
call_error :: proc(vm: ^VM, th: ^Thread, func: u32, v: Value) -> bool {
	info := ""
	hint := ""
	if th.frame_count > 0 {
		f := top_frame(vm, th)
		if func >= f.base {
			p := frame_proto(vm, th, f)
			what, name := describe_reg(vm, p, int(f.pc) - 1, func - f.base)
			if v.tag == .Nil {
				if m := absent_message(qualified_name(vm, p, int(f.pc) - 1, func - f.base));
				   m != "" {
					return rt_error(vm, m)
				}
			}
			if what != "" {
				info = fmt.tprintf(" (%s '%s')", what, name)
				if v.tag == .Nil {hint = nil_name_hint(vm, th, f, what, name)}
			}
		}
	}
	return rt_errorf(vm, hint, "attempt to call a %s value%s", type_name(v), info)
}

// nil_name_hint: "did you mean" for a nil global, field or method.
nil_name_hint :: proc(vm: ^VM, th: ^Thread, f: ^Frame, what, name: string) -> string {
	switch what {
	case "global":
		cl := obj(vm, as_ref(thread_stack(vm, th)[f.func]), Closure)
		if s := did_you_mean(vm, cl.env, name); s != "" {
			return fmt.tprintf("no global '%s' exists; %s", name, s)
		}
		return fmt.tprintf("no global '%s' exists", name)
	case "method", "field":
		// The object is usually still in a register: the instruction that loaded it says.
		p := frame_proto(vm, th, f)
		code := bytes_of(vm, p.code, Instr, p.code_len)
		pc := int(f.pc) - 1
		for i := pc - 1; i >= 0 && i >= pc - 8; i -= 1 {
			ins := code[i]
			if op_of(ins) != .SELF && op_of(ins) != .GETFIELD {continue}
			objv :=
				thread_stack(vm, th)[f.base + (arg_a(ins) + 1 if op_of(ins) == .SELF else arg_b(ins))]
			if objv.tag != .Table {continue}
			t := as_ref(objv)
			s := did_you_mean(vm, t, name)
			if s == "" {
				if idx := get_mm(vm, objv, .Index);
				   idx.tag == .Table {s = did_you_mean(vm, as_ref(idx), name)}
			}
			if s != "" {return s}
			break
		}
	}
	return ""
}

// precall calls stack[func] with nargs arguments above it, wanting nresults (-1: all).
// A script function gets a frame; a native runs now.
precall :: proc(
	vm: ^VM,
	th: ^Thread,
	func: u32,
	nargs_in: u32,
	nresults: i16,
	cont: Cont,
	cont_arg: u32,
	flags: bit_set[Frame_Flag;u8] = {},
) -> Call_Status {
	nargs := nargs_in
	if !resolve_call(vm, th, func, &nargs) {return .Error}
	r := as_ref(thread_stack(vm, th)[func])
	if obj_kind(vm, r) == .Native_Closure {
		switch obj(vm, r, Native_Closure).intrinsic {
		case .None:
		case .Pcall:
			return call_pcall(vm, th, func, nargs, nresults, cont)
		case .Xpcall:
			return call_xpcall(vm, th, func, nargs, nresults, cont)
		case .Resume:
			return call_resume(vm, th, func, nargs, nresults, cont, cont_arg, false)
		case .Wrap:
			return call_resume(vm, th, func, nargs, nresults, cont, cont_arg, true)
		case .Yield:
			return call_yield(vm, th, func, nargs, nresults, cont, cont_arg)
		}
		return call_native(vm, th, func, nargs, nresults, cont, cont_arg)
	}
	p := obj(vm, obj(vm, r, Closure).proto, Proto)
	nfix := u32(p.num_params)
	vararg := p.is_vararg != 0
	actual := max(nargs, nfix)
	need := func + 1 + actual + (nfix + 1 if vararg else 0) + u32(p.max_stack) + EXTRA_STACK
	if !ensure_stack(vm, th, need) {return .Error}
	stack := thread_stack(vm, th)
	for i in nargs ..< nfix {stack[func + 1 + i] = NIL}
	f := func
	nextra: u32 = 0
	if vararg {
		nextra = actual - nfix
		if nextra > MAX_VARARGS {
			rt_error(
				vm,
				"too many arguments to a function taking '...' (the limit is 65535)",
				"pass a table instead",
			)
			return .Error
		}
		newf := func + 1 + actual
		stack[newf] = stack[func]
		for i in 0 ..< nfix {
			stack[newf + 1 + i] = stack[func + 1 + i]
			stack[func + 1 + i] = NIL
		}
		f = newf
	}
	if vm.depth >= vm.limits.call_depth {
		vm.fault = .Call_Depth
		vm.pending = true
		return .Error
	}
	fr := push_frame(vm, th)
	if fr == nil {return .Error}
	vm.depth += 1
	fr^ = Frame {
		func     = f,
		base     = f + 1,
		top      = f + 1 + u32(p.max_stack),
		pc       = 0,
		nresults = nresults,
		cont     = cont,
		flags    = flags,
		nvarargs = u16(nextra),
		cont_arg = cont_arg,
	}
	th.top = fr.top
	return .Script
}

// call_native runs a native. A native that yields to the host leaves its values on the
// stack for the host and returns .Script (the run stops at the next instruction
// boundary); the host's values become its results.
call_native :: proc(
	vm: ^VM,
	th: ^Thread,
	func, nargs: u32,
	nresults: i16,
	cont := Cont.None,
	cont_arg: u32 = 0,
) -> Call_Status {
	if !ensure_stack(vm, th, func + 1 + nargs + MIN_NATIVE_STACK) {return .Error}
	th.top = func + 1 + nargs
	r := as_ref(thread_stack(vm, th)[func])
	id := obj(vm, r, Native_Closure).native
	spec := vm.natives[id]
	c := Native_Call {
		vm      = vm,
		th      = th,
		func    = func,
		nargs   = nargs,
		ret     = func + 1 + nargs,
		closure = r,
		name    = spec.name,
	}
	// A private native of the prelude ("string.format/raw") speaks as its function.
	if k := strings.index_byte(spec.name, '/'); k >= 0 {c.name = spec.name[:k]}
	if vm.trace.on {trace_event(vm, "C %d call native '%s' args=%d", vm.depth, c.name, nargs)}
	vm.meter -= i64(spec.cost)
	st := spec.fn(&c)
	if vm.fault != .None || st == .Error {return .Error}
	if st == .Yield {
		if cont != .None &&
		   cont != .Host &&
		   cont != .Store &&
		   cont != .Compare &&
		   cont != .Discard &&
		   cont != .Concat {
			rt_errorf(vm, "call it from script code", "'%s' cannot yield from here", spec.name)
			return .Error
		}
		set_wait(th, func, nresults, cont, cont_arg, {})
		vm.yielding = true
		vm.yield_from = c.ret
		vm.pending = true
		return .Script
	}
	move_results(vm, th, c.ret, th.top - c.ret, func, nresults)
	return .Native_Done
}

move_results :: proc(vm: ^VM, th: ^Thread, src, n, dest: u32, wanted: i16) {
	stack := thread_stack(vm, th)
	if wanted < 0 {
		for i in 0 ..< n {stack[dest + i] = stack[src + i]}
		th.top = dest + n
		return
	}
	w := u32(wanted)
	for i in 0 ..< w {stack[dest + i] = stack[src + i] if i < n else NIL}
	th.top = dest + w
}

@(private = "file")
call_pcall :: proc(
	vm: ^VM,
	th: ^Thread,
	func, nargs: u32,
	nresults: i16,
	cont: Cont,
) -> Call_Status {
	if cont != .None {
		rt_error(vm, "pcall cannot be called from here", "call pcall from script code")
		return .Error
	}
	if nargs == 0 {
		rt_error(vm, "bad argument #1 to 'pcall' (value expected)")
		return .Error
	}
	n := nargs - 1
	if !resolve_call(vm, th, func + 1, &n) {
		if vm.fault != .None {return .Error}
		return caught(vm, th, func, nresults, error_value_bare(vm))
	}
	r := as_ref(thread_stack(vm, th)[func + 1])
	if obj_kind(vm, r) == .Closure {
		return precall(vm, th, func + 1, n, nresults, .Pcall, 0, {.Protected})
	}
	if obj(vm, r, Native_Closure).intrinsic != .None {
		// A coroutine function runs inside a script frame (the prelude's call_through),
		// which pcall protects.
		if !call_through(vm, th, func + 1, &n) {return .Error}
		return precall(vm, th, func + 1, n, nresults, .Pcall, 0, {.Protected})
	}
	#partial switch call_native(vm, th, func + 1, n, -1) {
	case .Script:
		// A host yield: the host's values come back after a true.
		th.wait_slot = func
		th.wait_nres = nresults
		th.wait_flags = {.True_Prefix}
		return .Script
	case .Native_Done:
		stack := thread_stack(vm, th)
		stack[func] = TRUE
		move_results(vm, th, func, th.top - func, func, nresults)
		return .Native_Done
	}
	if vm.fault != .None {return .Error}
	return caught(vm, th, func, nresults, error_value_bare(vm))
}

@(private = "file")
call_xpcall :: proc(
	vm: ^VM,
	th: ^Thread,
	func, nargs: u32,
	nresults: i16,
	cont: Cont,
) -> Call_Status {
	if cont != .None {
		rt_error(vm, "xpcall cannot be called from here", "call xpcall from script code")
		return .Error
	}
	if nargs < 2 {
		rt_error(vm, "bad argument #2 to 'xpcall' (value expected)")
		return .Error
	}
	stack := thread_stack(vm, th)
	stack[func + 1], stack[func + 2] = stack[func + 2], stack[func + 1]
	n := nargs - 2
	if !resolve_call(vm, th, func + 2, &n) {
		if vm.fault != .None {return .Error}
		return call_handler(vm, th, func, nresults, error_value_bare(vm))
	}
	r := as_ref(thread_stack(vm, th)[func + 2])
	if obj_kind(vm, r) == .Closure {
		return precall(vm, th, func + 2, n, nresults, .Xpcall, 0, {.Protected})
	}
	if obj(vm, r, Native_Closure).intrinsic != .None {
		if !call_through(vm, th, func + 2, &n) {return .Error}
		return precall(vm, th, func + 2, n, nresults, .Xpcall, 0, {.Protected})
	}
	#partial switch call_native(vm, th, func + 2, n, -1) {
	case .Script:
		th.wait_slot = func
		th.wait_nres = nresults
		th.wait_flags = {.True_Prefix}
		return .Script
	case .Native_Done:
		stack = thread_stack(vm, th)
		count := th.top - (func + 2)
		stack[func] = TRUE
		for i in 0 ..< count {stack[func + 1 + i] = stack[func + 2 + i]}
		move_results(vm, th, func, count + 1, func, nresults)
		return .Native_Done
	}
	if vm.fault != .None {return .Error}
	return call_handler(vm, th, func, nresults, error_value_bare(vm))
}

// call_through puts the prelude's call_through(f, ...) in f's place at slot.
@(private = "file")
call_through :: proc(vm: ^VM, th: ^Thread, slot: u32, nargs: ^u32) -> bool {
	top := slot + 1 + nargs^
	if !ensure_stack(vm, th, top + 1 + EXTRA_STACK) {return false}
	stack := thread_stack(vm, th)
	for i := top; i > slot; i -= 1 {stack[i] = stack[i - 1]}
	stack[slot] = vm.call_through
	nargs^ += 1
	th.top = top + 1
	return true
}

// caught: a protected call at slot returns false and the error value.
@(private = "file")
caught :: proc(vm: ^VM, th: ^Thread, slot: u32, nresults: i16, value: Value) -> Call_Status {
	if vm.fault != .None {return .Error}
	if vm.trace.on {trace_event(vm, "E %d error caught by pcall", vm.depth)}
	stack := thread_stack(vm, th)
	stack[slot] = FALSE
	stack[slot + 1] = value
	move_results(vm, th, slot, 2, slot, nresults)
	return .Native_Done
}

// call_handler calls xpcall's handler with the error value. Called from call_xpcall
// (catcher -1: the protected function was a native, no frames to unwind; the handler is at
// slot+1) or from throw (catcher: the frame xpcall protected; the handler runs above the
// failing frames, so a traceback sees them, and they are unwound when it returns).
@(private = "file")
call_handler :: proc(
	vm: ^VM,
	th: ^Thread,
	slot: u32,
	nresults: i16,
	value: Value,
	catcher: i32 = -1,
) -> Call_Status {
	if vm.fault != .None {return .Error}
	at := slot + 1
	if catcher >= 0 {
		at = th.top
		if th.frame_count > 0 {at = max(at, top_frame(vm, th).top)}
		if !ensure_stack(vm, th, at + 2 + EXTRA_STACK) {return .Error}
		stack := thread_stack(vm, th)
		stack[at] = stack[slot + 1]
	}
	stack := thread_stack(vm, th)
	stack[at + 1] = value
	th.top = at + 2
	arg := u32(catcher + 1) | u32(u16(nresults)) << 16
	switch precall(vm, th, at, 1, 1, .Xpcall_Handler, arg) {
	case .Script:
		return .Script
	case .Native_Done:
		finish_handler(vm, th, at, arg, thread_stack(vm, th)[at])
		return .Native_Done
	case .Error:
	}
	if vm.fault != .None {return .Error}
	finish_handler(vm, th, at, arg, new_string(vm, "error in error handling"))
	if vm.fault != .None {return .Error}
	return .Native_Done
}

// finish_handler ends an xpcall whose handler (at handler_slot) gave v: the failing
// frames unwound, xpcall's results false and v.
finish_handler :: proc(vm: ^VM, th: ^Thread, handler_slot: u32, arg: u32, v: Value) {
	catcher := i32(arg & 0xffff) - 1
	nresults := i16(u16(arg >> 16))
	slot := handler_slot - 1
	if catcher >= 0 {
		frames := thread_frames(vm, th)
		slot = frame_result_slot(vm, th, &frames[catcher]) - 2
		close_upvals(vm, th, slot)
		vm.depth -= th.frame_count - u32(catcher)
		frames_drop(vm, th, u32(catcher))
	}
	stack := thread_stack(vm, th)
	stack[slot] = FALSE
	stack[slot + 1] = v
	move_results(vm, th, slot, 2, slot, nresults)
}

// error_value_at: the pending error as a value, a message with its position.
error_value_at :: proc(vm: ^VM, th: ^Thread) -> Value {
	if vm.err.has_value {return vm.err.value}
	return new_string(
		vm,
		fmt.tprintf("%s%s", position_prefix(vm, th, vm.err.level), strings.to_string(vm.err.msg)),
	)
}

// error_value_bare: the pending error as a value, without a position.
@(private = "file")
error_value_bare :: proc(vm: ^VM) -> Value {
	if vm.err.has_value {return vm.err.value}
	return new_string(vm, strings.to_string(vm.err.msg))
}

Pos_Result :: enum u8 {
	Continue,
	Host_Done,
	Error,
}

// poscall returns n results from stack[ra] out of the top frame.
poscall :: proc(vm: ^VM, th: ^Thread, ra, n: u32) -> Pos_Result {
	fp := top_frame(vm, th)
	f := fp^
	res := frame_result_slot(vm, th, fp)
	frames_drop(vm, th, th.frame_count - 1)
	vm.depth -= 1
	stack := thread_stack(vm, th)
	switch f.cont {
	case .None:
		move_results(vm, th, ra, n, res, f.nresults)
	case .Host:
		move_results(vm, th, ra, n, res, f.nresults)
		return .Host_Done
	case .Pcall:
		move_results(vm, th, ra, n, res, -1)
		stack[res - 1] = TRUE
		move_results(vm, th, res - 1, n + 1, res - 1, f.nresults)
	case .Xpcall:
		slot := res - 2
		stack[slot] = TRUE
		move_results(vm, th, ra, n, slot + 1, -1)
		move_results(vm, th, slot, n + 1, slot, f.nresults)
	case .Xpcall_Handler:
		finish_handler(vm, th, res, f.cont_arg, stack[ra] if n > 0 else NIL)
	case .Resume:
		// The coroutine's function returned: its resumer goes on.
		if !coroutine_return(vm, vm.current, ra, n) {return .Error}
	case .Store, .Compare, .Discard, .Concat:
		v := stack[ra] if n > 0 else NIL
		if !finish_cont(vm, th, f.cont, f.cont_arg, v) {return .Error}
	}
	return .Continue
}

// finish_cont finishes the instruction a metamethod interrupted, with its result v.
finish_cont :: proc(vm: ^VM, th: ^Thread, cont: Cont, cont_arg: u32, v: Value) -> bool {
	f := top_frame(vm, th)
	stack := thread_stack(vm, th)
	#partial switch cont {
	case .Store:
		stack[f.base + cont_arg] = v
		th.top = f.top
	case .Compare:
		if !is_falsy(v) != (cont_arg != 0) {f.pc += 1}
		th.top = f.top
	case .Discard:
		th.top = f.top
	case .Concat:
		a := cont_arg >> 16
		n := cont_arg & 0xffff
		stack[f.base + a + n - 2] = v
		th.top = f.top
		return concat_run(vm, th, a, n - 1) != .Error
	}
	return true
}

// call_mm calls a metamethod h(a1, a2[, a3]) above the top frame's registers, the
// result finishing the instruction through cont.
call_mm :: proc(
	vm: ^VM,
	th: ^Thread,
	h, a1, a2: Value,
	cont: Cont,
	cont_arg: u32,
	a3: Value = NIL,
	three := false,
) -> Call_Status {
	f := top_frame(vm, th)
	t := f.top
	stack := thread_stack(vm, th)
	stack[t] = h
	stack[t + 1] = a1
	stack[t + 2] = a2
	nargs: u32 = 2
	if three {
		stack[t + 3] = a3
		nargs = 3
	}
	th.top = t + 1 + nargs
	st := precall(vm, th, t, nargs, 0 if cont == .Discard else 1, cont, cont_arg)
	if st == .Native_Done {
		v := thread_stack(vm, th)[t]
		if !finish_cont(vm, th, cont, cont_arg, v) {return .Error}
	}
	return st
}

// Upvalues.

find_upval :: proc(vm: ^VM, thr: Ref, slot: u32) -> Ref {
	th := obj(vm, thr, Thread)
	prev: ^Ref = &th.open_upvals
	for r := prev^; r != 0; {
		uv := obj(vm, r, Upvalue)
		if uv.slot == slot {return r}
		if uv.slot < slot {break}
		prev = &uv.next_open
		r = uv.next_open
	}
	fresh := heap_alloc(vm, .Upvalue, size_of(Upvalue))
	if fresh == 0 {return 0}
	uv := obj(vm, fresh, Upvalue)
	uv.thread = thr
	uv.slot = slot
	uv.open = true
	uv.next_open = prev^
	prev^ = fresh
	return fresh
}

close_upvals :: proc(vm: ^VM, th: ^Thread, level: u32) {
	stack := thread_stack(vm, th)
	for th.open_upvals != 0 {
		r := th.open_upvals
		uv := obj(vm, r, Upvalue)
		if uv.slot < level {break}
		uv.value = stack[uv.slot]
		uv.open = false
		th.open_upvals = uv.next_open
		uv.next_open = 0
		uv.thread = 0
		barrier_forward(vm, r, uv.value)
	}
}

upval_get :: #force_inline proc(vm: ^VM, r: Ref) -> Value {
	uv := obj(vm, r, Upvalue)
	if uv.open {return thread_stack(vm, obj(vm, uv.thread, Thread))[uv.slot]}
	return uv.value
}

upval_set :: #force_inline proc(vm: ^VM, r: Ref, v: Value) {
	uv := obj(vm, r, Upvalue)
	if uv.open {
		thread_stack(vm, obj(vm, uv.thread, Thread))[uv.slot] = v
	} else {
		uv.value = v
		barrier_forward(vm, r, v)
	}
}

// Raising errors.

// frame_pos: a frame's source, line, column and span at its current instruction.
frame_pos :: proc(
	vm: ^VM,
	th: ^Thread,
	fi: u32,
) -> (
	source: string,
	line, col, span: u32,
	p: ^Proto,
) {
	f := &thread_frames(vm, th)[fi]
	p = frame_proto(vm, th, f)
	pc := int(f.pc) - 1
	if pc >= 0 && pc < int(p.code_len) {
		li := bytes_of(vm, p.lines, Line_Info, p.code_len)[pc]
		line, col, span = li.line, u32(li.col), u32(li.span)
	}
	return string_bytes(vm, p.source), line, col, span, p
}

// level_frame: the frame of error level n (1: the running script function).
// A prelude frame there stands for the script function that called into the prelude, so
// errors of the prelude's functions and natives point at the script.
level_frame :: proc(vm: ^VM, th: ^Thread, level: int) -> (u32, bool) {
	if level < 1 || u32(level) > th.frame_count {return 0, false}
	fi := th.frame_count - u32(level)
	frames := thread_frames(vm, th)
	for {
		// The level's function called by pcall, xpcall, resume or the host has no script
		// caller: as Lua's natives there, no position. (A metamethod's caller is the
		// script instruction that ran it.)
		if fi + 1 < th.frame_count {
			#partial switch frames[fi + 1].cont {
			case .Host, .Pcall, .Xpcall, .Xpcall_Handler, .Resume:
				return 0, false
			}
		}
		if string_bytes(vm, frame_proto(vm, th, &frames[fi]).source) != "prelude" {return fi, true}
		if fi == 0 {return 0, false}
		fi -= 1
	}
}

// position_prefix: "source:line: " of a level, or "".
position_prefix :: proc(
	vm: ^VM,
	th: ^Thread,
	level: int,
	allocator := context.temp_allocator,
) -> string {
	fi, ok := level_frame(vm, th, level)
	if !ok {return ""}
	src, line, _, _, _ := frame_pos(vm, th, fi)
	return fmt.aprintf("%s:%d: ", src, line, allocator = allocator)
}

// traceback: the frames of the run, innermost first.
traceback :: proc(vm: ^VM, th: ^Thread, allocator := context.allocator) -> []Trace_Frame {
	out := make([dynamic]Trace_Frame, allocator)
	n := th.frame_count
	frames := thread_frames(vm, th)
	for k in 0 ..< n {
		fi := n - 1 - k
		if n > 22 && k == 10 {
			append(
				&out,
				Trace_Frame {
					source = "...",
					name = fmt.aprintf("(%d levels skipped)", n - 21, allocator = allocator),
				},
			)
		}
		if n > 22 && k >= 10 && k < n - 11 {continue}
		src, line, _, _, p := frame_pos(vm, th, fi)
		name := ""
		if p.line_defined == 0 {
			name = "main module"
		} else if fi > 0 && frames[fi].cont == .None {
			caller := &frames[fi - 1]
			cp := frame_proto(vm, th, caller)
			code := bytes_of(vm, cp.code, Instr, cp.code_len)
			pc := int(caller.pc) - 1
			if pc >= 0 && (op_of(code[pc]) == .CALL || op_of(code[pc]) == .TAILCALL) {
				what, fname := describe_reg(vm, cp, pc, arg_a(code[pc]))
				if what != "" && what != "constant" {
					name = fmt.aprintf(
						"%s '%s'",
						"method" if what == "method" else "function",
						fname,
						allocator = allocator,
					)
				}
			}
		}
		if name == "" {
			pname := string_bytes(vm, p.name)
			if pname != "" {
				name = fmt.aprintf("function '%s'", pname, allocator = allocator)
			} else {
				name = fmt.aprintf("function <%s:%d>", src, p.line_defined, allocator = allocator)
			}
		}
		append(&out, Trace_Frame{source = strings.clone(src, allocator), line = line, name = name})
	}
	return out[:]
}

// throw handles the pending error or fault: true when a pcall or xpcall caught it (the
// run goes on), false when it ends the run (vm.err.final is set).
throw :: proc(vm: ^VM) -> bool {
	th := obj(vm, vm.current, Thread)
	if vm.trace.on {trace_error(vm)}
	if vm.fault != .None {
		final_error(vm, th, .Limit)
		return false
	}
	frames := thread_frames(vm, th)
	catcher := -1
	for i := int(th.frame_count) - 1; i >= 0; i -= 1 {
		f := frames[i]
		if .Protected in f.flags || f.cont == .Xpcall_Handler {
			catcher = i
			break
		}
		if f.cont == .Host {break}
	}
	if catcher < 0 && vm.current != vm.main_thread && th.resumer != 0 {
		// Nothing in the coroutine catches it: the coroutine dies, its resumer goes on.
		value := error_value_at(vm, th)
		if vm.fault != .None {
			final_error(vm, th, .Limit)
			return false
		}
		again, ok := coroutine_error(vm, value)
		if !ok {return throw(vm)}
		if again {
			vm.err.value = value
			vm.err.has_value = true
			vm.err.level = 1
		} else {
			return true
		}
		return throw(vm)
	}
	if catcher < 0 {
		final_error(vm, th, .Runtime)
		return false
	}
	value := vm.err.value
	if !vm.err.has_value {
		value = new_string(
			vm,
			fmt.tprintf(
				"%s%s",
				position_prefix(vm, th, vm.err.level),
				strings.to_string(vm.err.msg),
			),
		)
		if vm.fault != .None {
			final_error(vm, th, .Limit)
			return false
		}
	}
	f := frames[catcher]
	res := frame_result_slot(vm, th, &frames[catcher])
	#partial switch f.cont {
	case .Pcall:
		close_upvals(vm, th, res)
		vm.depth -= th.frame_count - u32(catcher)
		frames_drop(vm, th, u32(catcher))
		stack := thread_stack(vm, th)
		stack[res - 1] = FALSE
		stack[res] = value
		move_results(vm, th, res - 1, 2, res - 1, f.nresults)
	case .Xpcall:
		// The handler runs above the failing frames.
		if call_handler(vm, th, res - 2, f.nresults, value, i32(catcher)) ==
		   .Error {return throw(vm)}
	case .Xpcall_Handler:
		// An error inside the handler ends the xpcall.
		msg := new_string(vm, "error in error handling")
		if vm.fault != .None {return throw(vm)}
		close_upvals(vm, th, res)
		vm.depth -= th.frame_count - u32(catcher)
		frames_drop(vm, th, u32(catcher))
		finish_handler(vm, th, res, f.cont_arg, msg)
	}
	return true
}

@(private = "file")
final_error :: proc(vm: ^VM, th: ^Thread, kind: Error_Kind) {
	a := vm.run_allocator
	e := Script_Error {
		kind = kind,
	}
	level := 1
	if kind == .Limit {
		e.limit = vm.fault
		msg, hint := limit_message(vm, vm.fault)
		e.message = strings.clone(msg, a)
		e.hint = strings.clone(hint, a)
	} else {
		level = max(vm.err.level, 1)
		e.message = strings.clone(strings.to_string(vm.err.msg), a)
		e.hint = strings.clone(strings.to_string(vm.err.hint), a)
		e.value = vm.err.value if vm.err.has_value else NIL
	}
	if fi, ok := level_frame(vm, th, level); ok {
		src, line, col, span, p := frame_pos(vm, th, fi)
		e.source = strings.clone(src, a)
		e.line = line
		e.column = col
		e.span = span
		if p.text != 0 {e.text = source_line(string_bytes(vm, p.text), line, a)}
	}
	e.traceback = traceback(vm, th, a)
	vm.err.final = e
}
