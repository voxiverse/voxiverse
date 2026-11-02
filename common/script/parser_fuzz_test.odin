package script

import "core:fmt"
import "core:strings"
import "core:testing"

import "common:base"

// test_parser_random_bytes: 2 000 inputs from a fixed seed (random bytes, and conformance
// files with random bytes inserted, deleted or flipped). Each compiles or gives a syntax
// error with a line; a failed compile leaves the heap as it was; a module that compiles
// runs with a 64 KiB-instruction slice and is aborted if it suspends. The limits are
// counts, never times.

@(private = "file")
FUZZ_CASES :: 2000
@(private = "file")
FUZZ_SLICE :: 64 * 1024

@(private = "file")
fuzz_input :: proc(rng: ^base.Rng, n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	if n % 4 == 0 || len(CONFORMANCE_FILES) == 0 {
		for _ in 0 ..< base.rng_int_max(rng, 200) {strings.write_byte(&b, u8(base.rng_u32(rng)))}
		return strings.to_string(b)
	}
	src := transmute([]u8)strings.clone(
		string(CONFORMANCE_FILES[base.rng_int_max(rng, len(CONFORMANCE_FILES))].data),
		context.temp_allocator,
	)
	data := make([dynamic]u8, context.temp_allocator)
	append(&data, ..src)
	for _ in 0 ..< 1 + base.rng_int_max(rng, 4) {
		if len(data) == 0 {break}
		at := base.rng_int_max(rng, len(data))
		switch base.rng_int_max(rng, 3) {
		case 0:
			inject_at(&data, at, u8(base.rng_u32(rng)))
		case 1:
			ordered_remove(&data, at)
		case 2:
			data[at] ~= u8(1) << u8(base.rng_int_max(rng, 8))
		}
	}
	return string(data[:])
}

@(test)
test_parser_random_bytes :: proc(t: ^testing.T) {
	rng := base.rng_make(51)
	compiled, refused := 0, 0
	for n in 0 ..< FUZZ_CASES {
		src := fuzz_input(&rng, n)
		vm, verr := vm_create(default_config())
		if !testing.expectf(t, verr.kind == .None, "vm_create: %s", verr.message) {return}
		before, top := vm.in_use, vm.top
		fn, e := compile(vm, src, "fuzz", allocator = context.temp_allocator)
		if e.kind != .None {
			refused += 1
			testing.expectf(t, e.kind == .Syntax, "case %d: a %v error from compile", n, e.kind)
			testing.expectf(
				t,
				e.line >= 1 && e.message != "",
				"case %d: an error without a line or message: %v",
				n,
				e,
			)
			testing.expectf(
				t,
				vm.in_use == before && vm.top == top,
				"case %d: a failed compile changed the heap",
				n,
			)
		} else {
			compiled += 1
			r := call(vm, fn, nil, FUZZ_SLICE, context.temp_allocator)
			if r.status == .Suspended {abort(vm)}
			testing.expectf(
				t,
				vm.state == .Idle,
				"case %d: the VM is %v after the run",
				n,
				vm.state,
			)
		}
		if ok, problem := heap_check(vm); !ok {
			testing.expectf(t, false, "case %d: heap_check: %s\n%s", n, problem, src)
		}
		vm_destroy(vm)
		free_all(context.temp_allocator)
	}
	// Both kinds happen, or the generator is not doing its job.
	testing.expectf(
		t,
		compiled > 0 && refused > 0,
		"%s",
		fmt.tprintf("%d compiled, %d refused", compiled, refused),
	)
}
