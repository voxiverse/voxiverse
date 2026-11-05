package script

import "core:hash/xxhash"
import "core:strings"
import "core:testing"

// Snapshots: the golden bytes, snapshot of a restore equal to the snapshot, the
// refusals with their messages, pins and handles across a restore, the size of a full heap.

@(private = "file")
GOLDEN_SOURCE :: `local t = {}
for i = 1, 50 do t[i] = i * i end
local names = {"alpha", "beta", "gamma"}
local s = table.concat(names, "-") .. 1.5
local co = coroutine.create(function(a) local b = coroutine.yield(a + 1) return b end)
coroutine.resume(co, 41)
local n = 0
while true do n = n + 1 end`

// GOLDEN_HASH: XXH64 of the snapshot GOLDEN_SOURCE gives suspended after 2 000 units. The
// same on every OS, or snapshots are not portable. A change to the heap's layout, the
// compiler's output or the prelude changes it: then this constant changes with it.
@(private = "file")
GOLDEN_HASH :: 0x1d217edb0bffd978

@(private = "file")
golden_vm :: proc(t: ^testing.T, cfg: Config) -> ^VM {
	vm, e := vm_create(cfg)
	if !testing.expectf(t, e.kind == .None, "vm_create: %s", e.message) {return nil}
	// The source's text is in the heap: a checkout with CRLF line endings must not change it.
	source, _ := strings.replace_all(GOLDEN_SOURCE, "\r\n", "\n", context.temp_allocator)
	fn, ce := compile(vm, source, "golden", allocator = context.temp_allocator)
	if !testing.expectf(t, ce.kind == .None, "compile: %s", ce.message) {
		vm_destroy(vm)
		return nil
	}
	r := call(vm, fn, nil, 2000, context.temp_allocator)
	if !testing.expect_value(t, r.status, Run_Status.Suspended) {
		vm_destroy(vm)
		return nil
	}
	return vm
}

@(private = "file")
golden_config :: proc() -> Config {
	cfg := default_config()
	cfg.seed = 51
	return cfg
}

@(test)
test_snapshot_golden :: proc(t: ^testing.T) {
	vm := golden_vm(t, golden_config())
	if vm == nil {return}
	defer vm_destroy(vm)
	bytes := snapshot(vm, context.temp_allocator)
	testing.expectf(
		t,
		xxhash.XXH64(bytes) == GOLDEN_HASH,
		"the golden snapshot's XXH64 is %#x, the test says %#x (%d bytes)",
		xxhash.XXH64(bytes),
		u64(GOLDEN_HASH),
		len(bytes),
	)
	// Restored and snapshotted again: the same bytes.
	vm2, e := restore(bytes, golden_config())
	if !testing.expectf(t, e.kind == .None, "restore: %s", e.message) {return}
	defer vm_destroy(vm2)
	again := snapshot(vm2, context.temp_allocator)
	testing.expect(t, string(again) == string(bytes), "a restored VM snapshots to other bytes")
	// Both go on the same way.
	r1 := resume(vm, nil, 5000, context.temp_allocator)
	r2 := resume(vm2, nil, 5000, context.temp_allocator)
	testing.expect_value(t, r1.status, Run_Status.Suspended)
	testing.expect_value(t, r2.status, Run_Status.Suspended)
	testing.expect_value(t, heap_hash(vm2), heap_hash(vm))
	testing.expect(
		t,
		string(snapshot(vm, context.temp_allocator)) ==
		string(snapshot(vm2, context.temp_allocator)),
		"after the same slice the VMs differ",
	)
}

@(private = "file")
host_ping :: proc(c: ^Native_Call) -> Native_Status {
	return push_string(c, "pong")
}

@(private = "file")
expect_refused :: proc(
	t: ^testing.T,
	bytes: []u8,
	cfg: Config,
	want: string,
	checked := true,
	loc := #caller_location,
) {
	vm: ^VM
	e: Script_Error
	if checked {
		vm, e = restore(bytes, cfg)
	} else {
		vm, e = restore_unchecked(bytes, cfg)
	}
	if vm != nil {
		vm_destroy(vm)
		testing.expectf(t, false, "restored; wanted %q", want, loc = loc)
		return
	}
	testing.expectf(t, e.message == want, "refused with %q; wanted %q", e.message, want, loc = loc)
}

@(test)
test_snapshot_refused :: proc(t: ^testing.T) {
	natives := []Native_Spec{{name = "test.ping", fn = host_ping, cost = 1}}
	cfg := golden_config()
	cfg.natives = natives
	cfg.handle_kinds = {"entity"}
	vm := golden_vm(t, cfg)
	if vm == nil {return}
	defer vm_destroy(vm)
	bytes := snapshot(vm, context.temp_allocator)
	{
		ok, e := restore(bytes, cfg)
		testing.expectf(t, e.kind == .None, "restore: %s", e.message)
		vm_destroy(ok)
	}
	expect_refused(t, bytes[:len(bytes) - 1], cfg, "the snapshot is truncated")
	expect_refused(t, bytes[:100], cfg, "the snapshot is truncated")
	expect_refused(t, bytes[:3], cfg, "not a script snapshot (no 'VXSS' at the start)")
	flipped := make([]u8, len(bytes), context.temp_allocator)
	copy(flipped, bytes)
	flipped[len(flipped) - 200] ~= 0x10
	expect_refused(t, flipped, cfg, "the snapshot's checksum is wrong (the file is damaged)")
	v2 := make([]u8, len(bytes), context.temp_allocator)
	copy(v2, bytes)
	v2[4] = 2
	expect_refused(t, v2, cfg, "snapshot version 2; this build reads 1")
	no_native := golden_config()
	no_native.handle_kinds = {"entity"}
	expect_refused(
		t,
		bytes,
		no_native,
		"snapshot needs native 'test.ping', which this VM does not have",
	)
	no_kind := golden_config()
	no_kind.natives = natives
	expect_refused(
		t,
		bytes,
		no_kind,
		"snapshot needs handle kind 'entity', which this VM does not have",
	)
	small := cfg
	small.limits.memory = MEMORY_MIN
	big_vm, _ := vm_create(cfg)
	defer vm_destroy(big_vm)
	fill, _ := compile(
		big_vm,
		`big = {} for i = 1, 3000 do big[i] = {i} end`,
		"fill",
		allocator = context.temp_allocator,
	)
	call(big_vm, fill, nil, allocator = context.temp_allocator)
	big := snapshot(big_vm, context.temp_allocator)
	expect_refused(
		t,
		big,
		small,
		strings.concatenate(
			{
				"the snapshot's heap is ",
				itoa(int(big_vm.top)),
				" bytes; this VM's memory limit is 262144",
			},
			context.temp_allocator,
		),
	)
	// A heap whose structure is wrong, behind a good checksum's back: refused, not run.
	broken := make([]u8, len(bytes), context.temp_allocator)
	copy(broken, bytes)
	heap_at := len(bytes) - int(vm.top)
	(^Header)(&broken[heap_at + HEAP_START]).size = 7
	expect_refused(
		t,
		broken,
		cfg,
		"the snapshot is damaged: the block at 16 has a bad size",
		false,
	)
}

@(private = "file")
itoa :: proc(n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, n)
	return strings.to_string(b)
}

@(private = "file")
entity_x :: proc(c: ^Native_Call) -> Native_Status {
	bits := check_handle(c, 1, 1) or_return
	return push_int(c, i64(bits) * 10)
}

@(test)
test_snapshot_pins_handles :: proc(t: ^testing.T) {
	cfg := default_config()
	natives := []Native_Spec{{name = "entity.x", fn = entity_x, cost = 1}}
	cfg.natives = natives
	cfg.handle_kinds = {"entity"}
	vm, e := vm_create(cfg)
	if !testing.expect(t, e.kind == .None) {return}
	defer vm_destroy(vm)
	methods := new_table(vm)
	table_set_raw(vm, methods, new_string(vm, "x"), native_value(vm, "entity.x"))
	mt := new_table(vm)
	table_set_raw(vm, mt, new_string(vm, "__index"), methods)
	set_handle_metatable(vm, 1, mt)
	set_global(vm, "hero", handle_value(1, 7))
	fn, ce := compile(
		vm,
		`local n = 1
return function() n = n + 1; return hero:x() + n end`,
		"pins",
		allocator = context.temp_allocator,
	)
	if !testing.expectf(t, ce.kind == .None, "compile: %s", ce.message) {return}
	r := call(vm, fn, nil, allocator = context.temp_allocator)
	if !testing.expect_value(t, r.status, Run_Status.Done) {return}
	p := pin(vm, r.results[0])
	bytes := snapshot(vm, context.temp_allocator)
	vm2, re := restore(bytes, cfg)
	if !testing.expectf(t, re.kind == .None, "restore: %s", re.message) {return}
	defer vm_destroy(vm2)
	for _ in 0 ..< 3 {collect(vm2)}
	f := pinned(vm2, p)
	testing.expect_value(t, f.tag, Tag.Function)
	r = call(vm2, f, nil, allocator = context.temp_allocator)
	if !testing.expect_value(t, r.status, Run_Status.Done) {return}
	testing.expect_value(t, r.results[0], int_value(72))
	h := get_global(vm2, "hero")
	testing.expect_value(t, h, handle_value(1, 7))
	ok, problem := heap_check(vm2)
	testing.expectf(t, ok, "heap_check: %s", problem)
}

// A snapshot of a full 16 MiB heap is the heap's live bytes and little more.
@(test)
test_snapshot_size :: proc(t: ^testing.T) {
	vm, e := vm_create(default_config())
	if !testing.expect(t, e.kind == .None) {return}
	defer vm_destroy(vm)
	fill_heap(t, vm)
	collect(vm)
	bytes := snapshot(vm, context.temp_allocator)
	testing.expectf(t, vm.in_use > 15 << 20, "the heap holds %d bytes, not full", vm.in_use)
	testing.expectf(
		t,
		u64(len(bytes)) <= vm.in_use + vm.in_use / 20,
		"a snapshot of %d live bytes is %d bytes",
		vm.in_use,
		len(bytes),
	)
}

// fill_heap: strings in a global table until 16 MiB is nearly full.
fill_heap :: proc(t: ^testing.T, vm: ^VM) {
	fn, ce := compile(vm, SNAPSHOT_FILL, "fill", allocator = context.temp_allocator)
	if t != nil && !testing.expectf(t, ce.kind == .None, "compile: %s", ce.message) {return}
	r := call(vm, fn, nil, max(i64), context.temp_allocator)
	if t != nil {testing.expectf(t, r.status == .Done, "fill: %v %s", r.status, r.error.message)}
}
