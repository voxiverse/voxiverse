package build

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// An executable is built again only when something it is built from changed (a shot or a
// run after another, with nothing edited between, starts at once). What it was built
// from is written beside it, `<exe>.stamp`: the time its build began, then the
// compiler's version and the command line (the profile, the defines: the version's
// commit), a line each. It is fresh when the stamp says the same compiler and command,
// nothing wrote the executable after the stamp, and no file or folder under FRESH_ROOTS
// (every collection, every #load'ed file, the games' lists, the shaders) changed after
// its build began (a folder changes when a file is added to it or removed).

FRESH_ROOTS :: []string {
	"client",
	"common",
	"server",
	"games",
	"assets",
	GENERATED_DIR,
	SHADER_OUT_DIR,
}

// build_stamp_text: what a build of cmd with this compiler is built from (the stamp's
// lines after the first).
build_stamp_text :: proc(compiler: string, cmd: []string) -> string {
	return strings.join({strings.trim_space(compiler), strings.join(cmd, "\n")}, "\n")
}

// build_fresh: exe is built from text (build_stamp_text) and nothing under roots changed
// since its build began.
build_fresh :: proc(exe, text: string, roots: []string) -> bool {
	stamp_path := strings.concatenate({exe, ".stamp"}, context.temp_allocator)
	stamp, err := os.read_entire_file_from_path(stamp_path, context.temp_allocator)
	if err != nil {return false}
	first, _, rest := strings.partition(string(stamp), "\n")
	if rest != text {return false}
	began_ns, began_ok := strconv.parse_i64(first, 10)
	exe_info, exe_err := os.stat(exe, context.temp_allocator)
	stamp_info, stamp_err := os.stat(stamp_path, context.temp_allocator)
	if !began_ok || exe_err != nil || stamp_err != nil {return false}
	if exe_info.modification_time._nsec > stamp_info.modification_time._nsec {return false}
	for root in roots {
		if newer_than(root, began_ns) {return false}
	}
	return true
}

// build_stamp_write: exe was built from text, its build begun at began.
build_stamp_write :: proc(exe, text: string, began: time.Time) {
	stamp := fmt.tprintf("%d\n%s", began._nsec, text)
	path := strings.concatenate({exe, ".stamp"}, context.temp_allocator)
	if err := os.write_entire_file(path, transmute([]u8)stamp); err != nil {
		os.remove(path) // (a stamp half written is no stamp: built again next time)
	}
}

// newer_than: something under root (root itself among them) was modified at or after
// the time ns. A root that is not there is nothing.
@(private = "file")
newer_than :: proc(root: string, ns: i64) -> bool {
	if info, err := os.stat(root, context.temp_allocator); err != nil {
		return false
	} else if info.modification_time._nsec >= ns {
		return true
	}
	w := os.walker_create(root)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if info.modification_time._nsec >= ns {return true}
	}
	return false
}
