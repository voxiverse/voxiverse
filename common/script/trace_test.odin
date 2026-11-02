package script

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

TRACE_FILES := #load_directory("testdata/trace")

// The trace of fixed programs, run in slices of 25 units, against testdata/trace/*.txt
// (what `build script run <file> --trace --slice 25` writes to stderr, run there, less
// the formatted error at the end).
@(test)
test_trace :: proc(t: ^testing.T) {
	files := slice.clone(TRACE_FILES[:])
	defer delete(files)
	slice.sort_by(files, proc(a, b: runtime.Load_Directory_File) -> bool {return a.name < b.name})
	programs := 0
	for f in files {
		if !strings.has_suffix(f.name, ".vxs") {continue}
		programs += 1
		want_name := fmt.tprintf("%s.txt", strings.trim_suffix(f.name, ".vxs"))
		want := ""
		for g in files {
			if g.name == want_name {
				want, _ = strings.replace_all(string(g.data), "\r\n", "\n", context.temp_allocator)
			}
		}
		src, _ := strings.replace_all(string(f.data), "\r\n", "\n", context.temp_allocator)
		vm, verr := vm_create(default_config())
		if !testing.expectf(t, verr.kind == .None, "vm_create: %s", verr.message) {return}
		fn, cerr := compile(vm, src, f.name, allocator = context.temp_allocator)
		if testing.expectf(t, cerr.kind == .None, "%s: %s", f.name, cerr.message) {
			b := strings.builder_make(context.temp_allocator)
			trace_set(vm, true)
			r := call(vm, fn, nil, 25, context.temp_allocator)
			for {
				strings.write_string(&b, trace_take(vm, context.temp_allocator))
				if r.status != .Suspended {break}
				r = resume(vm, nil, 25, context.temp_allocator)
			}
			testing.expectf(
				t,
				strings.to_string(b) == want,
				"%s: the trace differs from %s:\n%s",
				f.name,
				want_name,
				strings.to_string(b),
			)
		}
		vm_destroy(vm)
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, programs, 2)
}
