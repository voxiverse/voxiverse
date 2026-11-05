package script

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"

// A VM is one script context: its own heap, globals and limits. VMs share nothing, so
// two can run on two threads; one VM is used by one thread at a time.

DEFAULT_SLICE :: 100_000
MEMORY_MIN :: 256 * 1024
MEMORY_MAX :: 1 << 30

Limits :: struct {
	slice:            i64, // the default instruction budget of one call or resume
	run_instructions: i64, // all slices of one run (0: none)
	memory:           int, // the heap region's bytes
	call_depth:       u32, // frames in a run
	string_max:       u32, // bytes in any one string
	output_max:       u32, // print output between drains
}

DEFAULT_LIMITS :: Limits {
	slice            = DEFAULT_SLICE,
	run_instructions = 10_000_000,
	memory           = 16 << 20,
	call_depth       = 1000,
	string_max       = 1 << 20,
	output_max       = 64 << 10,
}

Lib :: enum u8 {
	Base,
	String,
	Table,
	Math,
	Utf8,
	Coroutine,
}

Config :: struct {
	limits:       Limits,
	seed:         u64,
	libs:         bit_set[Lib],
	natives:      []Native_Spec,
	handle_kinds: []string, // registered in order at vm_create and restore (kinds 1, 2, ...)
	gc_stress:    bool,
	verify:       bool, // run verify_proto after every compile (always in tests)
}

default_config :: proc() -> Config {
	return Config{limits = DEFAULT_LIMITS, libs = ~bit_set[Lib]{}}
}

Run_Status :: enum u8 {
	Done,
	Suspended,
	Yielded,
	Error,
}

Run_Result :: struct {
	status:  Run_Status,
	results: []Value,
	error:   Script_Error,
}

VM_State :: enum u8 {
	Idle,
	Running,
	Suspended,
	Yielded,
}

Metamethod :: enum u8 {
	Index,
	Newindex,
	Call,
	Tostring,
	Len,
	Eq,
	Lt,
	Le,
	Unm,
	Add,
	Sub,
	Mul,
	Div,
	Mod,
	Idiv,
	Pow,
	Concat,
	Metatable,
}

METAMETHOD_NAMES := [Metamethod]string {
	.Index     = "__index",
	.Newindex  = "__newindex",
	.Call      = "__call",
	.Tostring  = "__tostring",
	.Len       = "__len",
	.Eq        = "__eq",
	.Lt        = "__lt",
	.Le        = "__le",
	.Unm       = "__unm",
	.Add       = "__add",
	.Sub       = "__sub",
	.Mul       = "__mul",
	.Div       = "__div",
	.Mod       = "__mod",
	.Idiv      = "__idiv",
	.Pow       = "__pow",
	.Concat    = "__concat",
	.Metatable = "__metatable",
}

VM :: struct {
	// The heap.
	mem:            []u8,
	committed:      u32,
	top:            u32,
	in_use:         u64,
	free_small:     [32]Ref,
	free_large:     [32]Ref,
	// Configuration.
	limits:         Limits,
	seed:           u64,
	// Strings.
	intern:         Ref,
	intern_mask:    u32,
	intern_count:   u32,
	next_id:        u32,
	// Roots.
	globals:        Ref,
	registry:       Ref,
	string_meta:    Ref,
	prelude_table:  Ref,
	main_thread:    Ref,
	current:        Ref,
	handle_metas:   Ref, // a table: handle kind -> its metatable
	call_through:   Value, // the prelude's function(f, ...) return f(...) end
	mm_names:       [Metamethod]Ref,
	natives:        [dynamic]Native_Spec,
	handle_kinds:   [dynamic]string,
	// The collector.
	gc:             Gc_State,
	gc_params:      Gc_Params,
	gc_stress:      bool,
	verify:         bool,
	pending:        bool, // the next instruction boundary has work: the collector, the trace
	fresh:          [dynamic]Ref, // objects made since the last instruction boundary
	trace:          Trace_State,
	// The run.
	state:          VM_State,
	meter:          i64, // units left in this slice
	budget:         i64, // this slice's units
	budget_is_last: bool, // the slice ends at run_instructions: running out faults
	run_used:       i64,
	depth:          u32,
	fault:          Limit_Kind,
	yielding:       bool, // a native yielded to the host: the run stops at the boundary
	yield_from:     u32, // where the yielded values begin on the current thread's stack
	err:            Pending_Error,
	run_allocator:  runtime.Allocator,
	// Output.
	output:         [dynamic]u8,
	output_dropped: int,
	allocator:      runtime.Allocator,
}

// vm_create makes a VM: its heap, its libraries and the prelude.
vm_create :: proc(config: Config, allocator := context.allocator) -> (^VM, Script_Error) {
	limits := config.limits
	if limits == {} {limits = DEFAULT_LIMITS}
	if limits.memory < MEMORY_MIN || limits.memory > MEMORY_MAX {
		return nil, Script_Error {
			kind = .Runtime,
			message = "memory limit out of range (256 KiB to 1 GiB)",
		}
	}
	if limits.slice <= 0 {limits.slice = DEFAULT_SLICE}
	vm := new(VM, allocator)
	vm.allocator = allocator
	vm.limits = limits
	vm.seed = config.seed
	vm.verify = config.verify
	vm.natives = make([dynamic]Native_Spec, allocator)
	vm.output = make([dynamic]u8, allocator)
	vm.fresh = make([dynamic]Ref, allocator)
	vm.handle_kinds = make([dynamic]string, allocator)
	gc_init(vm, config.gc_stress)
	vm.err.msg = strings.builder_make(allocator)
	vm.err.hint = strings.builder_make(allocator)
	if !heap_init(vm) {
		free(vm, allocator)
		return nil, Script_Error{kind = .Runtime, message = "could not reserve the script heap"}
	}
	ok := setup_vm(vm, config)
	if !ok {
		e := Script_Error {
			kind    = .Limit,
			limit   = .Memory,
			message = "not enough memory to create the VM",
		}
		vm_destroy(vm)
		return nil, e
	}
	if e, loaded := load_prelude(vm); !loaded {
		vm_destroy(vm)
		return nil, e
	}
	return vm, {}
}

@(private = "file")
setup_vm :: proc(vm: ^VM, config: Config) -> bool {
	if !intern_init(vm, 256) {return false}
	for name, m in METAMETHOD_NAMES {
		vm.mm_names[m] = intern(vm, name)
		if vm.mm_names[m] == 0 {return false}
	}
	vm.globals = table_new(vm)
	vm.registry = table_new(vm)
	vm.string_meta = table_new(vm)
	vm.prelude_table = table_new(vm)
	vm.handle_metas = table_new(vm)
	if vm.globals == 0 ||
	   vm.handle_metas == 0 ||
	   vm.registry == 0 ||
	   vm.string_meta == 0 ||
	   vm.prelude_table == 0 {return false}
	th := heap_alloc(vm, .Thread, size_of(Thread))
	if th == 0 {return false}
	vm.main_thread = th
	vm.current = th
	t := obj(vm, th, Thread)
	t.status = .Running
	stack := alloc_values(vm, 64)
	frames := alloc_bytes(vm, 16 * size_of(Frame))
	if stack == 0 || frames == 0 {return false}
	t = obj(vm, th, Thread)
	t.stack = stack
	t.stack_cap = 64
	t.frames = frames
	t.frame_cap = 16
	natives_init(vm, config)
	for k in config.handle_kinds {register_handle_kind(vm, k)}
	if !open_base(vm) {return false}
	// The string library is always there for the prelude (string.format); a VM without
	// it has no global 'string'.
	if !open_string(vm) {return false}
	if .Table in config.libs && !open_table(vm) {return false}
	if .Math in config.libs && !open_math(vm) {return false}
	if .Utf8 in config.libs && !open_utf8(vm) {return false}
	if .Coroutine in config.libs && !open_coroutine(vm) {return false}
	// What the prelude uses, whichever libraries the globals have.
	pt := ref_value(.Table, vm.prelude_table)
	for pair in ([?][2]string{{"sub", "string.sub"}, {"byte", "string.byte"}, {"find", "string.find"}, {"pack", "table.pack"}, {"unpack", "table.unpack"}, {"concat", "table.concat"}, {"rawlen", "rawlen"}}) {
		if !lib_bind(vm, pt, pair[0], native_value(vm, pair[1])) {return false}
	}
	return true
}

// natives_init: the natives, the libraries' first, then the host's, in order (snapshots
// record them by name).
natives_init :: proc(vm: ^VM, config: Config) {
	append(&vm.natives, ..BASE_NATIVES[:])
	append(&vm.natives, ..STRING_NATIVES[:])
	append(&vm.natives, ..TABLE_NATIVES[:])
	append(&vm.natives, ..MATH_NATIVES[:])
	append(&vm.natives, ..UTF8_NATIVES[:])
	append(&vm.natives, ..COROUTINE_NATIVES[:])
	append(&vm.natives, ..config.natives)
}

vm_destroy :: proc(vm: ^VM) {
	if vm == nil {return}
	allocator := vm.allocator
	heap_release(vm)
	delete(vm.natives)
	delete(vm.output)
	delete(vm.fresh)
	for k in vm.handle_kinds {delete(k, allocator)}
	delete(vm.handle_kinds)
	trace_destroy(vm)
	strings.builder_destroy(&vm.err.msg)
	strings.builder_destroy(&vm.err.hint)
	free(vm, allocator)
}

// compile compiles source into a module function whose globals are env (the VM's
// globals when env is nil).
compile :: proc(
	vm: ^VM,
	source, name: string,
	env := Value{},
	scratch := context.temp_allocator,
	allocator := context.allocator,
) -> (
	Value,
	Script_Error,
) {
	_ = scratch
	proto, serr, ok := compile_source(vm, source, name)
	vm.fault = .None
	if !ok {
		e := Script_Error {
			kind    = .Syntax,
			message = strings.clone(serr.message, allocator),
			hint    = strings.clone(serr.hint, allocator),
			source  = strings.clone(name, allocator),
			line    = serr.line,
			column  = serr.col,
			span    = serr.len,
			text    = source_line(source, serr.line, allocator),
		}
		return NIL, e
	}
	if ODIN_TEST || vm.verify {
		if good, problem := verify_tree(vm, proto); !good {
			return NIL, Script_Error {
				kind = .Runtime,
				message = fmt.aprintf(
					"the compiler made a function the verifier refuses: %s",
					problem,
					allocator = allocator,
				),
				source = strings.clone(name, allocator),
			}
		}
	}
	envr := as_ref(env) if env.tag == .Table else vm.globals
	cl := heap_alloc(vm, .Closure, size_of(Closure))
	if cl == 0 {
		vm.fault = .None
		return NIL, Script_Error {
			kind = .Limit,
			limit = .Memory,
			message = "not enough memory to compile",
		}
	}
	c := obj(vm, cl, Closure)
	c.proto = proto
	c.env = envr
	return ref_value(.Function, cl), {}
}

// call runs fn with args until it returns, errors, faults or suspends.
call :: proc(
	vm: ^VM,
	fn: Value,
	args: []Value,
	slice: i64 = DEFAULT_SLICE,
	allocator := context.allocator,
) -> Run_Result {
	if vm.state != .Idle {
		return Run_Result {
			status = .Error,
			error = Script_Error{kind = .Runtime, message = "the VM is already running a script"},
		}
	}
	th := obj(vm, vm.main_thread, Thread)
	th.top = 0
	frames_drop(vm, th, 0)
	vm.current = vm.main_thread
	vm.yielding = false
	clear(&vm.fresh)
	vm.run_used = 0
	vm.depth = 0
	vm.fault = .None
	vm.run_allocator = allocator
	vm.state = .Running
	start_slice(vm, slice)
	if !ensure_stack(vm, th, u32(len(args)) + 1 + EXTRA_STACK) {
		return finish_run(vm, .Error, allocator)
	}
	stack := thread_stack(vm, th)
	stack[0] = fn
	for a, i in args {stack[i + 1] = a}
	th.top = u32(len(args)) + 1
	switch precall(vm, th, 0, u32(len(args)), -1, .Host, 0) {
	case .Script:
		if th.frame_count == 0 && !vm.yielding {
			// Only a native that yields can stop without a frame.
			rt_error(vm, "this function cannot be called by the host")
			throw(vm)
			return finish_run(vm, .Error, allocator)
		}
	case .Native_Done:
		return finish_run(vm, .Done, allocator)
	case .Error:
		if !throw(vm) {return finish_run(vm, .Error, allocator)}
	}
	return run(vm, allocator)
}

// resume continues a suspended run where it stopped.
resume :: proc(
	vm: ^VM,
	values: []Value = nil,
	slice: i64 = DEFAULT_SLICE,
	allocator := context.allocator,
) -> Run_Result {
	if vm.state == .Yielded {
		// The values become the yielding native's results.
		vm.state = .Running
		vm.run_allocator = allocator
		clear(&vm.fresh)
		start_slice(vm, slice)
		th := obj(vm, vm.current, Thread)
		at := vm.yield_from
		n := u32(len(values))
		if !ensure_stack(vm, th, at + n + 1 + EXTRA_STACK) {
			if !throw(vm) {return finish_run(vm, .Error, allocator)}
		} else {
			stack := thread_stack(vm, th)
			for v, i in values {stack[at + u32(i)] = v}
			th.top = at + n
			if th.frame_count == 0 {
				// The host called the yielding native itself: its results end the run.
				move_results(vm, th, at, n, 0, -1)
				return finish_run(vm, .Done, allocator)
			}
			if !deliver(vm, th, at, n) {
				if !throw(vm) {return finish_run(vm, .Error, allocator)}
			}
		}
		return run(vm, allocator)
	}
	if vm.state != .Suspended {
		return Run_Result {
			status = .Error,
			error = Script_Error {
				kind = .Runtime,
				message = "the VM has no suspended run to resume",
			},
		}
	}
	vm.state = .Running
	vm.run_allocator = allocator
	clear(&vm.fresh)
	start_slice(vm, slice)
	return run(vm, allocator)
}

// abort ends a suspended run: its frames gone, upvalues closed, the VM idle.
abort :: proc(vm: ^VM) {
	if vm.state != .Suspended && vm.state != .Yielded {return}
	unwind_threads(vm)
	vm.yielding = false
	th := obj(vm, vm.main_thread, Thread)
	close_upvals(vm, th, 0)
	frames_drop(vm, th, 0)
	th.top = 0
	vm.depth = 0
	vm.state = .Idle
}

// output_take drains what print wrote since the last drain.
output_take :: proc(vm: ^VM, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_bytes(&b, vm.output[:])
	if vm.output_dropped > 0 {
		strings.write_string(&b, "[output truncated: ")
		strings.write_int(&b, vm.output_dropped)
		strings.write_string(&b, " bytes]\n")
	}
	clear(&vm.output)
	vm.output_dropped = 0
	return strings.to_string(b)
}

@(private = "file")
start_slice :: proc(vm: ^VM, slice: i64) {
	budget := slice if slice > 0 else vm.limits.slice
	vm.budget_is_last = false
	if vm.limits.run_instructions > 0 {
		left := vm.limits.run_instructions - vm.run_used
		if left <= budget {
			budget = max(left, 0)
			vm.budget_is_last = true
		}
	}
	vm.budget = budget
	vm.meter = budget
}

@(private = "file")
run :: proc(vm: ^VM, allocator: mem.Allocator) -> Run_Result {
	r := Exec_Result.Yielded if vm.yielding else execute(vm)
	switch r {
	case .Yielded:
		vm.yielding = false
		vm.run_used += vm.budget - vm.meter
		vm.state = .Yielded
		th := obj(vm, vm.current, Thread)
		n := th.top - vm.yield_from
		results := make([]Value, n, allocator)
		copy(results, thread_stack(vm, th)[vm.yield_from:th.top])
		return Run_Result{status = .Yielded, results = results}
	case .Done:
		return finish_run(vm, .Done, allocator)
	case .Suspended:
		// (the boundary that suspended charged a unit for an instruction it did not run)
		vm.run_used += vm.budget - vm.meter - 1
		vm.state = .Suspended
		return Run_Result{status = .Suspended}
	case .Error:
		return finish_run(vm, .Error, allocator)
	}
	return {}
}

@(private = "file")
finish_run :: proc(vm: ^VM, status: Run_Status, allocator: mem.Allocator) -> Run_Result {
	result := Run_Result {
		status = status,
	}
	th := obj(vm, vm.main_thread, Thread)
	if status == .Done {
		stack := thread_stack(vm, th)
		result.results = make([]Value, th.top, allocator)
		copy(result.results, stack[:th.top])
	} else {
		result.error = vm.err.final
		vm.err.final = {}
	}
	unwind_threads(vm)
	vm.yielding = false
	vm.err.has_value = false
	close_upvals(vm, th, 0)
	th.top = 0
	frames_drop(vm, th, 0)
	vm.depth = 0
	vm.fault = .None
	vm.state = .Idle
	vm.run_used += vm.budget - vm.meter
	return result
}

@(private = "file")
load_prelude :: proc(vm: ^VM) -> (Script_Error, bool) {
	fn, e := compile(vm, PRELUDE, "prelude", allocator = context.temp_allocator)
	if e.kind != .None {return e, false}
	r := call(vm, fn, {ref_value(.Table, vm.prelude_table)}, max(i64), context.temp_allocator)
	if r.status != .Done {return r.error, false}
	vm.call_through = table_get(vm, vm.prelude_table, new_string(vm, "call_through"))
	return {}, true
}

PRELUDE :: #load("prelude.vxs", string)
