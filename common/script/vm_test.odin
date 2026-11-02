package script

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

@(private = "file")
SAMPLE :: `
local t = {}
for i = 1, 200 do t[#t + 1] = i * i end
local function sum(xs) local s = 0 for _, v in ipairs(xs) do s = s + v end return s end
local m = setmetatable({}, {__index = function(_, k) return k * 3 end})
print(sum(t), m[14], tostring(t) ~= nil)
local ok, e = pcall(function() error("inside", 0) end)
print(ok, e)
for k, v in pairs({a = 1, b = 2, 3}) do print(k, v) end
return sum(t)
`

// run_sliced runs src to its end, resuming after each slice; the output and the end.
@(private = "file")
run_sliced :: proc(
	src: string,
	slice: i64,
	config := Config{},
) -> (
	output: string,
	r: Run_Result,
	suspensions: int,
) {
	cfg := config
	if cfg.limits == {} {cfg = default_config()}
	vm, verr := vm_create(cfg, context.temp_allocator)
	if verr.kind != .None {return verr.message, Run_Result{status = .Error, error = verr}, 0}
	defer vm_destroy(vm)
	fn, cerr := compile(vm, src, "sample", allocator = context.temp_allocator)
	if cerr.kind != .None {return cerr.message, Run_Result{status = .Error, error = cerr}, 0}
	b := strings.builder_make(context.temp_allocator)
	r = call(vm, fn, nil, slice, context.temp_allocator)
	for {
		strings.write_string(&b, output_take(vm, context.temp_allocator))
		if r.status != .Suspended {break}
		suspensions += 1
		r = resume(vm, nil, slice, context.temp_allocator)
	}
	return strings.to_string(b), r, suspensions
}

@(test)
test_suspend_resume_same_output :: proc(t: ^testing.T) {
	straight, r, n := run_sliced(SAMPLE, DEFAULT_SLICE)
	testing.expect_value(t, r.status, Run_Status.Done)
	testing.expect_value(t, n, 0)
	testing.expect(t, len(r.results) == 1 && r.results[0] == int_value(2686700))
	for slice in ([]i64{1, 2, 7, 13, 97, 1000}) {
		out, rs, k := run_sliced(SAMPLE, slice)
		testing.expectf(t, rs.status == .Done, "slice %d: %v", slice, rs.status)
		testing.expectf(
			t,
			out == straight,
			"slice %d changed the output:\n%s\nwanted:\n%s",
			slice,
			out,
			straight,
		)
		testing.expectf(t, k > 0, "slice %d never suspended", slice)
	}
}

// The exit check's three: an infinite loop suspends at its slice, resumes, then faults
// at run_instructions; an allocation bomb faults .Memory at the cap; unbounded recursion
// faults .Call_Depth through pcall. None crashes or hangs.
@(test)
test_limits :: proc(t: ^testing.T) {
	cfg := default_config()
	cfg.limits.run_instructions = 1_000_000
	_, r, n := run_sliced("while true do end", 100_000, cfg)
	testing.expect_value(t, n, 9)
	testing.expect_value(t, r.status, Run_Status.Error)
	testing.expect_value(t, r.error.kind, Error_Kind.Limit)
	testing.expect_value(t, r.error.limit, Limit_Kind.Instructions)
	testing.expect_value(t, r.error.line, 1)

	cfg = default_config()
	cfg.limits.memory = MEMORY_MIN
	_, r, _ = run_sliced("local t = {} while true do t[#t + 1] = {} end", DEFAULT_SLICE, cfg)
	testing.expect_value(t, r.error.kind, Error_Kind.Limit)
	testing.expect_value(t, r.error.limit, Limit_Kind.Memory)

	out: string
	out, r, _ = run_sliced(
		"local function f(n) return 1 + f(n + 1) end print(pcall(f, 1)) print('after')",
		DEFAULT_SLICE,
	)
	testing.expect_value(t, r.error.kind, Error_Kind.Limit)
	testing.expect_value(t, r.error.limit, Limit_Kind.Call_Depth)
	testing.expect_value(t, out, "")
}

@(test)
test_abort_leaves_vm_usable :: proc(t: ^testing.T) {
	vm, verr := vm_create(default_config())
	if !testing.expect(t, verr.kind == .None) {return}
	defer vm_destroy(vm)
	loop, _ := compile(
		vm,
		"local function f() while true do end end f()",
		"loop",
		allocator = context.temp_allocator,
	)
	r := call(vm, loop, nil, 1000, context.temp_allocator)
	testing.expect_value(t, r.status, Run_Status.Suspended)
	r = call(vm, loop, nil, 1000, context.temp_allocator)
	testing.expect_value(t, r.status, Run_Status.Error)
	abort(vm)
	testing.expect_value(t, vm.state, VM_State.Idle)
	testing.expect_value(t, obj(vm, vm.main_thread, Thread).frame_count, 0)
	testing.expect(t, heap_check(vm))
	fn, _ := compile(vm, "return 1 + 2", "after", allocator = context.temp_allocator)
	r = call(vm, fn, nil, allocator = context.temp_allocator)
	testing.expect_value(t, r.status, Run_Status.Done)
	testing.expect(t, len(r.results) == 1 && r.results[0] == int_value(3))
}

@(test)
test_fault_keeps_globals :: proc(t: ^testing.T) {
	cfg := default_config()
	cfg.limits.memory = MEMORY_MIN
	vm, verr := vm_create(cfg)
	if !testing.expect(t, verr.kind == .None) {return}
	defer vm_destroy(vm)
	fn, _ := compile(
		vm,
		"kept = {n = 41} local t = {} while true do t[#t + 1] = {} end",
		"bomb",
		allocator = context.temp_allocator,
	)
	r := call(vm, fn, nil, allocator = context.temp_allocator)
	testing.expect_value(t, r.error.limit, Limit_Kind.Memory)
	testing.expect(t, heap_check(vm))
	check, _ := compile(
		vm,
		"kept.n = kept.n + 1 return kept.n",
		"check",
		allocator = context.temp_allocator,
	)
	// The bomb's table is still referenced from nothing, but no collector runs before M51b:
	// the check needs only a little memory, which the free lists or the cap may not have.
	r = call(vm, check, nil, allocator = context.temp_allocator)
	if r.status == .Done {
		testing.expect(t, len(r.results) == 1 && r.results[0] == int_value(42))
	}
	kept := get_global(vm, "kept")
	testing.expect_value(t, kept.tag, Tag.Table)
	n := table_get_raw(vm, kept, new_string(vm, "n"))
	testing.expect(t, n == int_value(41) || n == int_value(42))
}

@(private = "file")
Thread_Run :: struct {
	output:    string,
	done:      bool,
	allocator: runtime.Allocator,
}

@(test)
test_two_vms_two_threads :: proc(t: ^testing.T) {
	runs := [2]Thread_Run{{allocator = context.allocator}, {allocator = context.allocator}}
	worker :: proc(data: rawptr) {
		run := (^Thread_Run)(data)
		out, r, _ := run_sliced(SAMPLE, 37)
		run.output = strings.clone(out, run.allocator)
		run.done = r.status == .Done
	}
	threads: [2]^thread.Thread
	for i in 0 ..< 2 {threads[i] = thread.create_and_start_with_data(&runs[i], worker)}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	sync.atomic_thread_fence(.Seq_Cst)
	testing.expect(t, runs[0].done && runs[1].done)
	testing.expect(t, runs[0].output == runs[1].output && runs[0].output != "")
	straight, _, _ := run_sliced(SAMPLE, DEFAULT_SLICE)
	testing.expect_value(t, runs[0].output, straight)
	delete(runs[0].output)
	delete(runs[1].output)
}

@(private = "file")
host_add :: proc(c: ^Native_Call) -> Native_Status {
	a := check_int(c, 1) or_return
	b := check_int(c, 2) or_return
	return push_int(c, a + b)
}

@(test)
test_native_argument_errors :: proc(t: ^testing.T) {
	cfg := default_config()
	natives := []Native_Spec{{name = "host.add", fn = host_add, cost = 1}}
	cfg.natives = natives
	vm, verr := vm_create(cfg)
	if !testing.expect(t, verr.kind == .None) {return}
	defer vm_destroy(vm)
	testing.expect(t, set_global(vm, "add", native_value(vm, "host.add")))
	fn, _ := compile(
		vm,
		`
local a = add(2, 3)
local ok, e = pcall(add, 1, "x")
local ok2, e2 = pcall(add, 1.5, 1)
local ok3, e3 = pcall(add, 1)
return a, e, e2, e3`,
		"natives",
		allocator = context.temp_allocator,
	)
	r := call(vm, fn, nil, allocator = context.temp_allocator)
	if !testing.expect_value(t, r.status, Run_Status.Done) {return}
	testing.expect_value(t, len(r.results), 4)
	testing.expect_value(t, r.results[0], int_value(5))
	want := []string {
		"bad argument #2 to 'host.add' (number expected, got string)",
		"bad argument #1 to 'host.add' (number has no integer representation)",
		"bad argument #2 to 'host.add' (number expected, got no value)",
	}
	for w, i in want {
		v := r.results[i + 1]
		testing.expectf(
			t,
			v.tag == .String && value_string(vm, v) == w,
			"result %d: %s, wanted %s",
			i + 1,
			type_name(v),
			w,
		)
	}
}

@(test)
test_call_depth :: proc(t: ^testing.T) {
	cfg := default_config()
	cfg.limits.call_depth = 50
	// f(49) is 50 frames (the module's call of it is a tail call): it fits; f(50) does not.
	_, r, _ := run_sliced(
		"local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end return f(49)",
		DEFAULT_SLICE,
		cfg,
	)
	testing.expect_value(t, r.status, Run_Status.Done)
	_, r, _ = run_sliced(
		"local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end return f(50)",
		DEFAULT_SLICE,
		cfg,
	)
	testing.expect_value(t, r.error.limit, Limit_Kind.Call_Depth)
	// Tail calls do not count.
	_, r, _ = run_sliced(
		"local function f(n) if n == 0 then return 'done' end return f(n - 1) end return f(100000)",
		DEFAULT_SLICE,
		cfg,
	)
	testing.expect_value(t, r.status, Run_Status.Done)
	// Metamethods count like calls.
	_, r, _ = run_sliced(
		"local t = setmetatable({}, {__index = function(s, k) return s[k] end}) return t.x",
		DEFAULT_SLICE,
		cfg,
	)
	testing.expect_value(t, r.error.limit, Limit_Kind.Call_Depth)
}

@(test)
test_failed_compile_leaves_heap :: proc(t: ^testing.T) {
	vm, verr := vm_create(default_config())
	if !testing.expect(t, verr.kind == .None) {return}
	defer vm_destroy(vm)
	before := vm.in_use
	top := vm.top
	sources := []string {
		"local x = = 1",
		"repeat if a then continue end local b = 1 until b",
		"x = 1 +",
	}
	for src in sources {
		_, e := compile(vm, src, "bad", allocator = context.temp_allocator)
		testing.expectf(t, e.kind == .Syntax, "%q compiled", src)
	}
	testing.expect_value(t, vm.in_use, before)
	testing.expect_value(t, vm.top, top)
	testing.expect(t, heap_check(vm))
}
