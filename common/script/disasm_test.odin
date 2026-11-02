package script

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

DISASM_FILES := #load_directory("testdata/disasm")

// The listings of three fixed programs, which also pin the register allocation.
@(test)
test_disasm_listings :: proc(t: ^testing.T) {
	files := slice.clone(DISASM_FILES[:])
	defer delete(files)
	slice.sort_by(files, proc(a, b: runtime.Load_Directory_File) -> bool {return a.name < b.name})
	programs := 0
	for f in files {
		if !strings.has_suffix(f.name, ".vxs") {continue}
		programs += 1
		want_name := fmt.tprintf("%s.txt", strings.trim_suffix(f.name, ".vxs"))
		want := ""
		for g in files {
			if g.name ==
			   want_name {want, _ = strings.replace_all(string(g.data), "\r\n", "\n", context.temp_allocator)}
		}
		vm, verr := vm_create(default_config())
		if !testing.expectf(t, verr.kind == .None, "vm_create: %s", verr.message) {return}
		fn, cerr := compile(vm, string(f.data), f.name, allocator = context.temp_allocator)
		if testing.expectf(t, cerr.kind == .None, "%s: %s", f.name, cerr.message) {
			b := strings.builder_make(context.temp_allocator)
			disasm(vm, fn, &b)
			testing.expectf(
				t,
				strings.to_string(b) == want,
				"%s: the listing differs from %s:\n%s",
				f.name,
				want_name,
				strings.to_string(b),
			)
		}
		vm_destroy(vm)
	}
	testing.expect_value(t, programs, 3)
}
