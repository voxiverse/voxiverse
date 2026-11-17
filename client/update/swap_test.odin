package update

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	return string(data) if err == nil else "<missing>"
}

// An install is found only in a folder laid out as an unpacked package; on macOS the app
// may stand alone (dragged to Applications).
@(test)
test_install_find :: proc(t: ^testing.T) {
	dir := "build/tmp/update_install"
	os.remove_all(dir)
	defer os.remove_all(dir)
	package_tree(dir, "pkg", LAYOUT_LINUX, "old")
	install, ok := install_find(join(dir, "pkg"), LAYOUT_LINUX)
	testing.expect(t, ok)
	testing.expect_value(t, install.dir, join(dir, "pkg"))
	testing.expect_value(t, install.alone, false)
	os.remove(join(dir, "pkg", "README.txt"))
	_, ok = install_find(join(dir, "pkg"), LAYOUT_LINUX)
	testing.expect(t, !ok, "a folder without the package's files (a developer's build/)")

	package_tree(dir, "mac", LAYOUT_MACOS, "old")
	macos := join(dir, "mac", "Voxiverse.app", "Contents", "MacOS")
	install, ok = install_find(macos, LAYOUT_MACOS)
	testing.expect(t, ok)
	testing.expect_value(t, install.dir, join(dir, "mac"))
	testing.expect_value(t, install.alone, false)
	os.remove(join(dir, "mac", "voxiverse-server"))
	install, ok = install_find(macos, LAYOUT_MACOS)
	testing.expect(t, ok)
	testing.expect_value(t, install.alone, true)
	_, ok = install_find(join(dir, "mac"), LAYOUT_MACOS)
	testing.expect(t, !ok, "not run from inside an app")
}

// A swap puts every entry of the package in place, the old ones aside, and cleanup
// removes those; files that are not the package's stay.
@(test)
test_swap :: proc(t: ^testing.T) {
	dir := "build/tmp/update_swap"
	os.remove_all(dir)
	defer os.remove_all(dir)
	package_tree(dir, "install", LAYOUT_LINUX, "old")
	_ = os.write_entire_file(join(dir, "install", "notes.txt"), transmute([]u8)string("mine"))
	staging := join(dir, "install", STAGING_NAME)
	package_tree(staging, "pkg", LAYOUT_LINUX, "new")
	_ = os.write_entire_file(join(staging, "pkg", "voxiverse.png"), transmute([]u8)string("new"))
	install := Install {
		dir = join(dir, "install"),
	}
	steps, planned := swap_plan(install, join(staging, "pkg"), LAYOUT_LINUX)
	testing.expect(t, planned)
	ok, restored := swap_run(steps)
	testing.expect(t, ok && restored)
	for file in ([]string{"voxiverse", "voxiverse-server", "README.txt", "LICENSE", "voxiverse.png"}) {
		testing.expect_value(t, read_text(join(dir, "install", file)), "new")
	}
	testing.expect_value(t, read_text(join(dir, "install", "licenses", "CREDITS.txt")), "new")
	testing.expect_value(t, read_text(join(dir, "install", "voxiverse" + OLD_SUFFIX)), "old")
	testing.expect_value(t, read_text(join(dir, "install", "notes.txt")), "mine")
	cleanup(join(dir, "install"))
	testing.expect(t, !os.exists(join(dir, "install", "voxiverse" + OLD_SUFFIX)))
	testing.expect(t, !os.exists(join(dir, "install", "licenses" + OLD_SUFFIX)))
	testing.expect(t, !os.exists(staging))
	testing.expect_value(t, read_text(join(dir, "install", "voxiverse")), "new")
	testing.expect_value(t, read_text(join(dir, "install", "notes.txt")), "mine")
}

// A swap that fails part way is undone: every installed file is as it was, and what was
// staged is back in the staging folder.
@(test)
test_swap_failing_midway_is_rolled_back :: proc(t: ^testing.T) {
	dir := "build/tmp/update_swap_fail"
	os.remove_all(dir)
	defer os.remove_all(dir)
	package_tree(dir, "install", LAYOUT_LINUX, "old")
	staging := join(dir, "install", STAGING_NAME)
	package_tree(staging, "pkg", LAYOUT_LINUX, "new")
	install := Install {
		dir = join(dir, "install"),
	}
	steps, _ := swap_plan(install, join(staging, "pkg"), LAYOUT_LINUX)
	testing.expect(t, len(steps) >= 6)
	for fail_at in 0 ..< len(steps) {
		@(static) calls, fails: int
		calls, fails = 0, fail_at
		failing :: proc(from, to: string) -> bool {
			calls += 1
			if calls - 1 == fails {return false}
			return rename_file(from, to)
		}
		ok, restored := swap_run(steps, failing)
		testing.expectf(
			t,
			!ok && restored,
			"failing at step %d: ok %v restored %v",
			fail_at,
			ok,
			restored,
		)
		for file in LAYOUT_LINUX.required {
			testing.expectf(
				t,
				read_text(join(dir, "install", file)) == "old",
				"failing at step %d: %s is %q",
				fail_at,
				file,
				read_text(join(dir, "install", file)),
			)
			testing.expect_value(t, read_text(join(staging, "pkg", file)), "new")
			aside := strings.concatenate({file, OLD_SUFFIX}, context.temp_allocator)
			testing.expect(t, !os.exists(join(dir, "install", aside)))
		}
		testing.expect_value(t, read_text(join(dir, "install", "licenses", "CREDITS.txt")), "old")
	}
}
