package script

import "core:testing"

// The host API of M51b: pins survive collections, handle kinds with metatables, and a
// native that yields to the host (at top level, inside a coroutine, inside pcall).

@(private = "file")
host_run :: proc(t: ^testing.T, vm: ^VM, src: string, loc := #caller_location) -> Run_Result {
	fn, ce := compile(vm, src, "host", allocator = context.temp_allocator)
	if !testing.expectf(t, ce.kind == .None, "compile: %s", ce.message, loc = loc) {return {}}
	return call(vm, fn, nil, allocator = context.temp_allocator)
}

@(test)
test_host_pin :: proc(t: ^testing.T) {
	vm, e := vm_create(default_config())
	if !testing.expect(t, e.kind == .None) {return}
	defer vm_destroy(vm)
	r := host_run(t, vm, `local n = 40
return function(x) n = n + x; return "sum " .. n end`)
	if !testing.expect_value(t, r.status, Run_Status.Done) {return}
	p := pin(vm, r.results[0])
	testing.expect(t, p != 0)
	// Nothing else holds the function: only the pin keeps it.
	for _ in 0 ..< 10 {collect(vm)}
	ok, problem := heap_check(vm)
	testing.expectf(t, ok, "heap_check: %s", problem)
	fn := pinned(vm, p)
	testing.expect_value(t, fn.tag, Tag.Function)
	r = call(vm, fn, {int_value(2)}, allocator = context.temp_allocator)
	if !testing.expect_value(t, r.status, Run_Status.Done) {return}
	testing.expect_value(t, value_string(vm, r.results[0]), "sum 42")
	// Slots are reused lowest first.
	p2 := pin(vm, int_value(7))
	unpin(vm, p)
	p3 := pin(vm, int_value(8))
	testing.expect_value(t, p3, p)
	testing.expect_value(t, pinned(vm, p2), int_value(7))
	testing.expect_value(t, pinned(vm, p), int_value(8))
}

@(private = "file")
host_pos :: proc(c: ^Native_Call) -> Native_Status {
	bits := check_handle(c, 1, 1) or_return
	return push_int(c, i64(bits) * 10)
}

@(test)
test_host_handle :: proc(t: ^testing.T) {
	cfg := default_config()
	natives := []Native_Spec{{name = "entity.pos", fn = host_pos, cost = 1}}
	cfg.natives = natives
	vm, e := vm_create(cfg)
	if !testing.expect(t, e.kind == .None) {return}
	defer vm_destroy(vm)
	kind := register_handle_kind(vm, "entity")
	testing.expect_value(t, kind, u16(1))
	other := register_handle_kind(vm, "player")
	methods := new_table(vm)
	testing.expect(
		t,
		table_set_raw(vm, methods, new_string(vm, "pos"), native_value(vm, "entity.pos")),
	)
	mt := new_table(vm)
	testing.expect(t, table_set_raw(vm, mt, new_string(vm, "__index"), methods))
	testing.expect(t, set_handle_metatable(vm, kind, mt))
	testing.expect(t, set_global(vm, "h", handle_value(kind, 0x2a)))
	testing.expect(t, set_global(vm, "h2", handle_value(kind, 0x2a)))
	testing.expect(t, set_global(vm, "p", handle_value(other, 0x2a)))
	collect(vm)
	r := host_run(
		t,
		vm,
		`local ok, err = pcall(h.pos, p)
return h:pos(), type(h), tostring(h), h == h2, h == p, err`,
	)
	if !testing.expectf(t, r.status == .Done, "%v: %s", r.status, r.error.message) {return}
	testing.expect_value(t, r.results[0], int_value(420))
	testing.expect_value(t, value_string(vm, r.results[1]), "handle")
	testing.expect_value(t, value_string(vm, r.results[2]), "entity: 0x000000000000002a")
	testing.expect_value(t, r.results[3], bool_value(true))
	testing.expect_value(t, r.results[4], bool_value(false))
	testing.expect_value(
		t,
		value_string(vm, r.results[5]),
		"bad argument #1 to 'entity.pos' (entity expected, got player)",
	)
}

@(private = "file")
host_ask :: proc(c: ^Native_Call) -> Native_Status {
	q := check_string(c, 1) or_return
	push_string(c, q) or_return
	return host_yield(c)
}

@(test)
test_host_yield :: proc(t: ^testing.T) {
	cfg := default_config()
	natives := []Native_Spec{{name = "host.ask", fn = host_ask, cost = 1}}
	cfg.natives = natives
	vm, e := vm_create(cfg)
	if !testing.expect(t, e.kind == .None) {return}
	defer vm_destroy(vm)
	testing.expect(t, set_global(vm, "ask", native_value(vm, "host.ask")))
	r := host_run(
		t,
		vm,
		`local out = {}
local a, b = ask("top")
out[#out + 1] = a + b
local co = coroutine.create(function(x)
	local v = ask("in coroutine")
	coroutine.yield(v + x)
	return "co done"
end)
local _, y = coroutine.resume(co, 100)
out[#out + 1] = y
local ok, w = pcall(function() return ask("in pcall") * 2 end)
out[#out + 1] = tostring(ok) .. " " .. w
local ok2, err = pcall(function() local z = ask("then error"); error("boom " .. z, 0) end)
out[#out + 1] = tostring(ok2) .. " " .. err
local _, last = coroutine.resume(co)
out[#out + 1] = last
return table.concat(out, ",")`,
	)
	answers := [][]Value {
		{int_value(1), int_value(2)},
		{int_value(5)},
		{int_value(21)},
		{int_value(9)},
	}
	questions := []string{"top", "in coroutine", "in pcall", "then error"}
	for q, i in questions {
		if !testing.expectf(
			t,
			r.status == .Yielded,
			"%s: %v: %s",
			q,
			r.status,
			r.error.message,
		) {return}
		testing.expect_value(t, len(r.results), 1)
		testing.expect_value(t, value_string(vm, r.results[0]), q)
		r = resume(vm, answers[i], allocator = context.temp_allocator)
	}
	if !testing.expectf(t, r.status == .Done, "%v: %s", r.status, r.error.message) {return}
	testing.expect_value(t, value_string(vm, r.results[0]), "3,105,true 42,false boom 9,co done")
	ok, problem := heap_check(vm)
	testing.expectf(t, ok, "heap_check: %s", problem)
}
