package script

import "core:fmt"
import "core:strings"
import "core:testing"

// The collector: flat memory under churn, cycles and dead strings freed, the barrier,
// the full collection before the memory fault, counted work, and a fuzz of allocation
// patterns under gc_stress with heap_check after every step.

@(private = "file")
gc_vm :: proc(t: ^testing.T, memory := 16 << 20, stress := false) -> ^VM {
	config := default_config()
	config.limits.memory = memory
	config.gc_stress = stress
	vm, e := vm_create(config)
	testing.expectf(t, e.kind == .None, "vm_create: %s", e.message)
	return vm
}

@(private = "file")
gc_run :: proc(t: ^testing.T, vm: ^VM, src: string, loc := #caller_location) -> Run_Result {
	fn, ce := compile(vm, src, "gc", allocator = context.temp_allocator)
	if !testing.expectf(t, ce.kind == .None, "compile: %s", ce.message, loc = loc) {return {}}
	r := call(vm, fn, nil, max(i64), context.temp_allocator)
	for r.status == .Suspended {r = resume(vm, nil, max(i64), context.temp_allocator)}
	return r
}

@(test)
test_gc_flat_memory :: proc(t: ^testing.T) {
	vm := gc_vm(t, 1 << 20)
	defer vm_destroy(vm)
	r := gc_run(t, vm, "for i = 1, 10^6 do local t = {i} end")
	testing.expectf(t, r.status == .Done, "the churn ended %v: %s", r.status, r.error.message)
	testing.expectf(t, vm.top < 512 << 10, "top %d after the churn; memory is not flat", vm.top)
	testing.expect(t, vm.gc.collections > 0, "no collection ran")
	ok, problem := heap_check(vm)
	testing.expectf(t, ok, "heap_check: %s", problem)
}

@(test)
test_gc_cycle_freed :: proc(t: ^testing.T) {
	vm := gc_vm(t)
	defer vm_destroy(vm)
	r := gc_run(t, vm, "local a, b = {}, {} a.b = b b.a = a cycle = a")
	testing.expect(t, r.status == .Done)
	cycle := get_global(vm, "cycle")
	a := as_ref(cycle)
	b := as_ref(table_get(vm, a, new_string(vm, "b")))
	set_global(vm, "cycle", NIL)
	collect(vm)
	collect(vm)
	testing.expect(t, a >= Ref(vm.top) || obj_kind(vm, a) != .Table, "table a survived")
	testing.expect(t, b >= Ref(vm.top) || obj_kind(vm, b) != .Table, "table b survived")
	ok, problem := heap_check(vm)
	testing.expectf(t, ok, "heap_check: %s", problem)
}

@(test)
test_gc_string_freed :: proc(t: ^testing.T) {
	vm := gc_vm(t)
	defer vm_destroy(vm)
	r := gc_run(t, vm, `local s = "a string only the index holds" .. 42`)
	testing.expect(t, r.status == .Done)
	text := "a string only the index holds42"
	find :: proc(vm: ^VM, text: string) -> Ref {
		slots := bytes_of(vm, vm.intern, u32, vm.intern_mask + 1)
		for e in slots {
			if e != 0 && string_bytes(vm, Ref(e)) == text {return Ref(e)}
		}
		return 0
	}
	testing.expect(t, find(vm, text) != 0, "the string was never made")
	count := vm.intern_count
	collect(vm)
	testing.expect(t, find(vm, text) == 0, "the dead string is still in the intern index")
	testing.expect(t, vm.intern_count < count, "the intern count did not drop")
	ok, problem := heap_check(vm)
	testing.expectf(t, ok, "heap_check: %s", problem)
}

// A black table given a new white value keeps it: the collector is stepped by hand
// until the table is black, then a new table is stored into it.
@(test)
test_gc_barrier :: proc(t: ^testing.T) {
	vm := gc_vm(t)
	defer vm_destroy(vm)
	r := gc_run(t, vm, "holder = {}")
	testing.expect(t, r.status == .Done)
	holder := as_ref(get_global(vm, "holder"))
	gc_work(vm, max(i64))
	gc_start(vm)
	for obj(vm, holder, Table).mark != BLACK && vm.gc.phase == .Propagate {
		gc_work(vm, 64)
	}
	testing.expect(t, obj(vm, holder, Table).mark == BLACK, "the holder never turned black")
	testing.expect(t, vm.gc.phase == .Propagate, "the cycle ended before the store")
	fresh := table_new(vm)
	key := new_string(vm, "kept")
	testing.expect(t, obj(vm, fresh, Table).mark == vm.gc.white)
	table_set(vm, holder, key, ref_value(.Table, fresh))
	ok, problem := heap_check(vm)
	testing.expectf(t, ok, "heap_check mid-cycle: %s", problem)
	gc_work(vm, max(i64))
	testing.expect(t, vm.gc.phase == .Pause)
	v := table_get(vm, holder, key)
	testing.expect(t, v.tag == .Table && as_ref(v) == fresh, "the stored value was lost")
	testing.expect(t, obj_kind(vm, fresh) == .Table, "the stored table was freed")
	collect(vm)
	ok, problem = heap_check(vm)
	testing.expectf(t, ok, "heap_check: %s", problem)
}

// The memory fault comes only after a full collection: garbage alone past the cap is
// collected and the program finishes.
@(test)
test_gc_full_before_fault :: proc(t: ^testing.T) {
	vm := gc_vm(t, 1 << 20)
	defer vm_destroy(vm)
	// Each table is 2 KiB of garbage; 4 MiB of them in a 1 MiB heap.
	r := gc_run(
		t,
		vm,
		"for i = 1, 2000 do local t = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,128} end",
	)
	testing.expectf(t, r.status == .Done, "ended %v: %s", r.status, r.error.message)
	// With pacing that never starts a cycle, only the collection before the fault
	// frees the garbage.
	vm.gc.threshold = max(u64) / 2
	vm.gc.credit = max(i64) / 2
	before := vm.gc.collections
	r = gc_run(
		t,
		vm,
		"for i = 1, 2000 do local t = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,128} end",
	)
	testing.expectf(
		t,
		r.status == .Done,
		"with no pacing, ended %v: %s",
		r.status,
		r.error.message,
	)
	testing.expect(t, vm.gc.collections > before, "no full collection ran before the fault")
	// Live data past the cap still faults.
	r = gc_run(t, vm, "local keep = {} for i = 1, 100000 do keep[i] = {i} end")
	testing.expect(
		t,
		r.status == .Error && r.error.limit == .Memory,
		"live data past the cap did not fault",
	)
	ok, problem := heap_check(vm)
	testing.expectf(t, ok, "heap_check: %s", problem)
}

// The collector's work is counted in units, the same on every run.
@(test)
test_gc_units_deterministic :: proc(t: ^testing.T) {
	src := "local keep = {} for i = 1, 20000 do local s = tostring(i) keep[i % 100] = {s, s .. 'x'} end"
	units: [2]u64
	collections: [2]u64
	for k in 0 ..< 2 {
		vm := gc_vm(t, 4 << 20)
		r := gc_run(t, vm, src)
		testing.expect(t, r.status == .Done)
		units[k] = vm.gc.units
		collections[k] = vm.gc.collections
		vm_destroy(vm)
	}
	testing.expect(t, collections[0] > 0, "no cycle ran")
	testing.expectf(t, units[0] == units[1], "units %d and %d", units[0], units[1])
	testing.expect(t, collections[0] == collections[1])
	s := vm_stats_for_test(src)
	testing.expect(t, s.collections == collections[0] && s.units == units[0])
	testing.expect(t, s.heap_peak >= s.heap_used && s.heap_used > 0)
}

@(private = "file")
vm_stats_for_test :: proc(src: string) -> Vm_Stats {
	config := default_config()
	config.limits.memory = 4 << 20
	vm, _ := vm_create(config)
	defer vm_destroy(vm)
	fn, _ := compile(vm, src, "gc", allocator = context.temp_allocator)
	call(vm, fn, nil, max(i64), context.temp_allocator)
	return vm_stats(vm)
}

// test_gc_fuzz: 500 generated allocation patterns (tables, strings, closures, cycles,
// coroutines) under gc_stress with heap_check after every slice.
@(test)
test_gc_fuzz :: proc(t: ^testing.T) {
	rng := u64(51)
	next :: proc(s: ^u64) -> u64 {
		s^ += 0x9e37_79b9_7f4a_7c15
		return splitmix_finish(s^)
	}
	pick :: proc(s: ^u64, n: int) -> int {return int(next(s) % u64(n))}
	SNIPPETS := [?]string {
		"t[$1] = {}",
		"t[$1] = {x = t[$2], y = 'k' .. $3}",
		"local a, b = {}, {} a.b = b b.a = a t[$1] = a",
		"t[$1] = tostring($2) .. string.rep('z', $3)",
		"local n = $1 t[$2] = function() n = n + 1 return n end",
		"t[$1] = nil",
		"t[$1] = setmetatable({}, {__index = t})",
		"local co = coroutine.wrap(function(a) local x = {a} coroutine.yield(x) return {x} end) t[$1] = co($2)",
		"t[$1] = {table.unpack({1, 2, 3, $2})}",
		"for k = 1, $3 do t[k % 7] = {k} end",
		"t.s = (t.s or '') .. $1 if #t.s > 200 then t.s = nil end",
		"t[$1] = string.format('%d-%s', $2, 'x')",
		"t[$1] = select('#', table.unpack(t, 1, $2))",
		"t[$1] = {} for k = 1, $3 do t[$1][tostring(k)] = k end",
	}
	failures := 0
	for case_i in 0 ..< 500 {
		b := make([dynamic]u8, context.temp_allocator)
		append(&b, "local t = {}\n")
		for _ in 0 ..< 4 + pick(&rng, 12) {
			snip := SNIPPETS[pick(&rng, len(SNIPPETS))]
			line, _ := strings.replace_all(
				snip,
				"$1",
				fmt.tprint(1 + pick(&rng, 16)),
				context.temp_allocator,
			)
			line, _ = strings.replace_all(
				line,
				"$2",
				fmt.tprint(pick(&rng, 16)),
				context.temp_allocator,
			)
			line, _ = strings.replace_all(
				line,
				"$3",
				fmt.tprint(pick(&rng, 40)),
				context.temp_allocator,
			)
			append(&b, line)
			append(&b, '\n')
		}
		append(&b, "local n = 0 for k, v in pairs(t) do n = n + 1 end print(n)\n")
		src := string(b[:])
		config := default_config()
		config.limits.memory = 1 << 20
		config.gc_stress = true
		vm, e := vm_create(config, context.temp_allocator)
		if e.kind != .None {
			testing.expectf(t, false, "vm_create: %s", e.message)
			return
		}
		fn, ce := compile(vm, src, "fuzz", allocator = context.temp_allocator)
		if ce.kind != .None {
			testing.expectf(t, false, "case %d does not compile: %s\n%s", case_i, ce.message, src)
			vm_destroy(vm)
			failures += 1
			continue
		}
		r := call(vm, fn, nil, 97, context.temp_allocator)
		for {
			if ok, problem := heap_check(vm); !ok {
				testing.expectf(t, false, "case %d: heap_check: %s\n%s", case_i, problem, src)
				failures += 1
				break
			}
			if r.status != .Suspended {break}
			r = resume(vm, nil, 97, context.temp_allocator)
		}
		if r.status == .Error && r.error.limit != .Memory {
			testing.expectf(t, false, "case %d: %s\n%s", case_i, r.error.message, src)
			failures += 1
		}
		vm_destroy(vm)
		free_all(context.temp_allocator)
		if failures > 3 {return}
	}
}
