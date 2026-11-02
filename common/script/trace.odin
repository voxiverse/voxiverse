package script

import "core:fmt"
import "core:strings"

// The instruction trace: with tracing on, every executed instruction appends a line to a
// buffer the host drains (trace_take), plus lines for native calls, suspensions, errors
// and collector steps. Deterministic text (no addresses, no times), so a test can compare
// a trace with a file.
//
//	T 2 quests/intro.vxs:11 on_tick 2 GETFIELD 1 0 1 ; R1 = 20 (integer)
//	C 3 call native 'string.sub' args=3
//	G step Propagate work=16384 inuse=1254300
//	S suspend meter=-3 depth=2
//	E 2 error: attempt to index a nil value (local 'x')

TRACE_MAX :: 4 << 20

Trace_State :: struct {
	on:      bool,
	buf:     [dynamic]u8,
	dropped: int,
	// The line of the last instruction stays open until the next boundary writes the
	// register it set.
	open:    bool,
	start:   int, // where its line begins in buf
	reg:     i32, // the register it sets (-1: none)
	thread:  Ref,
	frames:  u32,
	base:    u32,
}

// trace_set turns the trace on or off.
trace_set :: proc(vm: ^VM, on: bool) {
	vm.trace.on = on
	if on {
		if vm.trace.buf == nil {vm.trace.buf = make([dynamic]u8, vm.allocator)}
		vm.pending = true
	}
}

trace_destroy :: proc(vm: ^VM) {
	delete(vm.trace.buf)
	vm.trace.buf = nil
}

// trace_take drains the trace.
trace_take :: proc(vm: ^VM, allocator := context.allocator) -> string {
	trace_close_line(vm, nil)
	b := strings.builder_make(allocator)
	strings.write_bytes(&b, vm.trace.buf[:])
	if vm.trace.dropped > 0 {fmt.sbprintf(&b, "[trace truncated: %d bytes]\n", vm.trace.dropped)}
	clear(&vm.trace.buf)
	vm.trace.dropped = 0
	return strings.to_string(b)
}

@(private = "file")
trace_write :: proc(vm: ^VM, s: string) {
	room := TRACE_MAX - len(vm.trace.buf)
	if room < len(s) {
		take := max(room, 0)
		append(&vm.trace.buf, s[:take])
		vm.trace.dropped += len(s) - take
		return
	}
	append(&vm.trace.buf, s)
}

// trace_value: a value without side effects (no object numbers are given out).
@(private = "file")
trace_value :: proc(vm: ^VM, b: ^strings.Builder, v: Value) {
	switch v.tag {
	case .Nil, .Bool:
		value_text(vm, v, b)
	case .Int:
		write_number(b, v)
		strings.write_string(b, " (integer)")
	case .Float:
		write_number(b, v)
		strings.write_string(b, " (float)")
	case .String:
		s := value_string(vm, v)
		if len(s) > 32 {s = s[:32]}
		fmt.sbprintf(b, "%q", s)
	case .Handle:
		fmt.sbprintf(b, "%s: 0x%016x", handle_kind_name(vm, v.kind), v.bits)
	case .Table, .Function, .Thread:
		strings.write_string(b, type_name(v))
	}
}

// trace_close_line ends the open instruction line, with the register it set when the
// same frame is still running.
@(private = "file")
trace_close_line :: proc(vm: ^VM, th: ^Thread) {
	t := &vm.trace
	if !t.open {return}
	t.open = false
	b := strings.builder_make(context.temp_allocator)
	if t.reg >= 0 && th != nil && vm.current == t.thread && th.frame_count == t.frames {
		if th.frame_count > 0 && top_frame(vm, th).base == t.base {
			fmt.sbprintf(&b, " ; R%d = ", t.reg)
			trace_value(vm, &b, thread_stack(vm, th)[t.base + u32(t.reg)])
		}
	}
	strings.write_byte(&b, '\n')
	trace_write(vm, strings.to_string(b))
}

// trace_instruction: the instruction at pc of th's top frame is about to run.
trace_instruction :: proc(vm: ^VM, th: ^Thread, pc: u32) {
	trace_close_line(vm, th)
	if th.frame_count == 0 {return}
	f := top_frame(vm, th)
	p := frame_proto(vm, th, f)
	if pc >= p.code_len {return}
	ins := bytes_of(vm, p.code, Instr, p.code_len)[pc]
	line := bytes_of(vm, p.lines, Line_Info, p.code_len)[pc].line
	name := string_bytes(vm, p.name)
	if p.line_defined == 0 {name = "main"} else if name == "" {name = "?"}
	op := op_of(ins)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		"T %d %s:%d %s %d %v",
		vm.depth,
		string_bytes(vm, p.source),
		line,
		name,
		pc + 1,
		op,
	)
	switch OP_INFO[op].format {
	case .ABC:
		fmt.sbprintf(&b, " %d %d %d", arg_a(ins), arg_b(ins), arg_c(ins))
		if arg_k(ins) != 0 {strings.write_string(&b, "k")}
	case .ABx:
		fmt.sbprintf(&b, " %d %d", arg_a(ins), arg_bx(ins))
	case .AsBx:
		fmt.sbprintf(&b, " %d %d", arg_a(ins), arg_sbx(ins))
	case .Ax:
		fmt.sbprintf(&b, " %d", arg_ax(ins))
	case .sJ:
		fmt.sbprintf(&b, " %d", arg_sj(ins))
	}
	t := &vm.trace
	t.start = len(t.buf)
	trace_write(vm, strings.to_string(b))
	t.open = true
	t.reg = i32(arg_a(ins)) if sets_a(op) else -1
	t.thread = vm.current
	t.frames = th.frame_count
	t.base = f.base
}

// trace_suspend: the run suspends before the instruction whose line is open (it runs
// on resume, and is traced then), so that line is replaced by the suspension's.
trace_suspend :: proc(vm: ^VM) {
	t := &vm.trace
	if t.open && t.dropped == 0 {
		resize(&t.buf, t.start)
		t.open = false
	}
	trace_event(vm, "S suspend meter=%d depth=%d", vm.meter, vm.depth)
}

// trace_error: an error being raised (caught or not) or a fault.
trace_error :: proc(vm: ^VM) {
	if vm.fault != .None {
		trace_event(vm, "E %d fault %v", vm.depth, vm.fault)
	} else if vm.err.has_value && strings.builder_len(vm.err.msg) == 0 {
		trace_event(vm, "E %d error: (a %s value)", vm.depth, type_name(vm.err.value))
	} else {
		trace_event(vm, "E %d error: %s", vm.depth, strings.to_string(vm.err.msg))
	}
}

// trace_event: a line for a native call, a suspension, an error or a collector step.
trace_event :: proc(vm: ^VM, format: string, args: ..any) {
	if !vm.trace.on {return}
	trace_close_line(vm, nil)
	trace_write(vm, fmt.tprintf(format, ..args))
	trace_write(vm, "\n")
}
