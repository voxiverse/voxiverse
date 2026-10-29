package build

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

// The cache's key changes with every input it covers, and comes back when the input
// does: a source's content, a file added beside it, a #load'ed file, the command; and
// a step whose input is not older than its start is not keyed (one test: the file
// digests are remembered package-wide).
@(test)
test_cache_key_follows_the_inputs :: proc(t: ^testing.T) {
	compiler_version = "test"
	dir := "build/tmp/cache_test"
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	defer digests_forget()
	source := fmt.tprintf("%s/a.odin", dir)
	loaded := fmt.tprintf("%s/data.bin", dir)
	added := fmt.tprintf("%s/a_linux.odin", dir)
	deps := fmt.tprintf("%s/deps.json", dir)
	write :: proc(path, text: string) {_ = os.write_entire_file(path, transmute([]u8)text)}
	write(source, "package a\n")
	write(loaded, "one")
	write(deps, fmt.tprintf(`{{"source_files": [%q], "load_files": [%q]}}`, source, loaded))
	cmd := []string{"odin", "build", dir}
	key :: proc(cmd: []string, deps: string) -> string {
		digests_forget()
		k, ok := odin_key(cmd, deps)
		return k if ok else "none"
	}
	first := key(cmd, deps)
	testing.expect(t, first != "none", "no key from a good list")
	testing.expect_value(t, key(cmd, deps), first)

	write(source, "package a // changed\n")
	testing.expect(t, key(cmd, deps) != first, "a changed source keeps the key")
	write(source, "package a\n")
	testing.expect_value(t, key(cmd, deps), first)

	write(added, "package a\n")
	testing.expect(t, key(cmd, deps) != first, "a file added beside a source keeps the key")
	os.remove(added)
	testing.expect_value(t, key(cmd, deps), first)

	write(loaded, "two")
	testing.expect(t, key(cmd, deps) != first, "a changed #load keeps the key")
	write(loaded, "one")
	testing.expect_value(t, key(cmd, deps), first)

	testing.expect(
		t,
		key({"odin", "build", dir, "-o:speed"}, deps) != first,
		"a new flag keeps the key",
	)

	os.remove(loaded)
	testing.expect_value(t, key(cmd, deps), "none")
	write(loaded, "one")

	// Inputs not older than the start: no key (the step is done again next time).
	info, err := os.stat(source, context.temp_allocator)
	testing.expect(t, err == nil)
	digests_forget()
	_, keyed := odin_key(cmd, deps, info.modification_time)
	testing.expect(t, !keyed, "an input changed at the start was keyed")
	later := time.time_add(info.modification_time, time.Hour)
	digests_forget()
	_, keyed = odin_key(cmd, deps, later)
	testing.expect(t, keyed, "inputs older than the start were not keyed")
}
