package build

import "core:os"
import "core:testing"
import "core:time"

// An executable is fresh while what it was built from is the same; a source changed, a
// file added, another command or compiler, or the executable written by something else
// since, and it is built again. (The files' times are set, not waited for.)
@(test)
test_build_fresh :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	DIR :: "build/tmp/fresh_test"
	SRC :: DIR + "/src"
	EXE :: DIR + "/game"
	os.remove_all(DIR)
	defer os.remove_all(DIR)
	os.make_directory_all(SRC + "/sub")
	at :: proc(seconds: i64) -> time.Time {return {seconds * i64(time.Second)}}
	write :: proc(path, text: string, seconds: i64) {
		_ = os.write_entire_file(path, transmute([]u8)text)
		os.change_times(path, at(seconds), at(seconds))
	}
	write(SRC + "/sub/a.odin", "package a", 100)
	os.change_times(SRC + "/sub", at(100), at(100))
	os.change_times(SRC, at(100), at(100))
	text := build_stamp_text("odin version dev-2026-10\n", {"odin", "build", "client/main"})
	roots := []string{SRC}

	testing.expect(t, !build_fresh(EXE, text, roots), "fresh with no stamp")
	write(EXE, "built", 200) // (built from 150 on; its stamp is written now, after it)
	build_stamp_write(EXE, text, at(150))
	testing.expect(t, build_fresh(EXE, text, roots), "not fresh just built")
	other := build_stamp_text(
		"odin version dev-2026-10",
		{"odin", "build", "client/main", "-o:speed"},
	)
	testing.expect(t, !build_fresh(EXE, other, roots), "fresh for another command")

	write(SRC + "/sub/a.odin", "package a // changed", 160)
	testing.expect(t, !build_fresh(EXE, text, roots), "fresh with a source changed")
	build_stamp_write(EXE, text, at(170))
	testing.expect(t, build_fresh(EXE, text, roots), "not fresh built again")

	write(SRC + "/b.odin", "package a", 180)
	os.change_times(SRC, at(100), at(100)) // (only the file itself tells)
	testing.expect(t, !build_fresh(EXE, text, roots), "fresh with a file added")
	os.remove(SRC + "/b.odin")
	os.change_times(SRC, at(180), at(180)) // (a file removed: its folder tells)
	testing.expect(t, !build_fresh(EXE, text, roots), "fresh with a file removed")
	os.change_times(SRC, at(100), at(100))
	testing.expect(t, build_fresh(EXE, text, roots))

	os.change_times(EXE, at(0), at(0)) // the executable written after its stamp:
	os.change_times(EXE + ".stamp", at(0), at(0))
	os.change_times(EXE, at(1), at(1))
	testing.expect(t, !build_fresh(EXE, text, roots), "fresh with the executable written since")
}
