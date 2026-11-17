package update

import "core:os"
import "core:strings"
import "core:testing"

// The Linux package's listing (`tar -tzf`, `tar -tvzf`) as v0.5.1 has it.
LINUX_NAMES :: `voxiverse-0.5.1-linux-x64/
voxiverse-0.5.1-linux-x64/README.txt
voxiverse-0.5.1-linux-x64/licenses/
voxiverse-0.5.1-linux-x64/licenses/CREDITS.txt
voxiverse-0.5.1-linux-x64/voxiverse
voxiverse-0.5.1-linux-x64/voxiverse-server
voxiverse-0.5.1-linux-x64/voxiverse.png
voxiverse-0.5.1-linux-x64/LICENSE
`
LINUX_TYPES :: `drwxr-xr-x 0/0               0 2026-11-16 19:34 voxiverse-0.5.1-linux-x64/
-rw-r--r-- 0/0            1843 2026-11-16 19:34 voxiverse-0.5.1-linux-x64/README.txt
drwxr-xr-x 0/0               0 2026-11-16 19:34 voxiverse-0.5.1-linux-x64/licenses/
-rw-r--r-- 0/0            1396 2026-11-16 19:34 voxiverse-0.5.1-linux-x64/licenses/CREDITS.txt
-rwxr-xr-x 0/0        29592304 2026-11-16 19:34 voxiverse-0.5.1-linux-x64/voxiverse
-rwxr-xr-x 0/0        11563536 2026-11-16 19:34 voxiverse-0.5.1-linux-x64/voxiverse-server
-rw-r--r-- 0/0          262488 2026-11-16 19:34 voxiverse-0.5.1-linux-x64/voxiverse.png
-rw-r--r-- 0/0            1079 2026-11-16 19:34 voxiverse-0.5.1-linux-x64/LICENSE
`
LINUX_FOLDER :: "voxiverse-0.5.1-linux-x64"

@(test)
test_listing_of_a_package :: proc(t: ^testing.T) {
	testing.expect(t, listing_check(LINUX_NAMES, LINUX_TYPES, LINUX_FOLDER))
	// The macOS zip as bsdtar lists it (the app's insides are files and folders too).
	mac_names := "voxiverse-0.5.1-macos-arm64/\nvoxiverse-0.5.1-macos-arm64/Voxiverse.app/Contents/MacOS/voxiverse\r\n"
	mac_types := "drwxr-xr-x  0 0 0 0 Nov 16 19:34 voxiverse-0.5.1-macos-arm64/\n-rwxr-xr-x  0 0 0 27282640 Nov 16 19:34 voxiverse-0.5.1-macos-arm64/Voxiverse.app/Contents/MacOS/voxiverse\n"
	testing.expect(t, listing_check(mac_names, mac_types, "voxiverse-0.5.1-macos-arm64"))
	testing.expect(t, !listing_check("", "", LINUX_FOLDER), "an empty archive")
}

// A name that would land outside the staging folder, or a link of any kind, refuses the
// archive before it is unpacked.
@(test)
test_listing_with_a_path_escape :: proc(t: ^testing.T) {
	escapes := []string {
		"voxiverse-0.5.1-linux-x64/../../outside",
		"../outside",
		"/etc/passwd",
		"voxiverse-0.5.1-linux-x64//etc",
		"voxiverse-0.5.1-linux-x64/./x",
		"voxiverse-0.5.1-linux-x64/a/..",
		"voxiverse-0.5.1-linux-x64-other/x",
		"another-folder/x",
		"voxiverse-0.5.1-linux-x64/a\\..\\..\\x",
		"voxiverse-0.5.1-linux-x64/C:x",
		"voxiverse-0.5.1-linux-x64/a\x01",
	}
	for name in escapes {
		names := strings.concatenate({LINUX_NAMES, name, "\n"}, context.temp_allocator)
		types := strings.concatenate(
			{LINUX_TYPES, "-rw-r--r-- 0/0 1 x ", name, "\n"},
			context.temp_allocator,
		)
		testing.expectf(t, !listing_check(names, types, LINUX_FOLDER), "%q was let through", name)
	}
	link := strings.concatenate(
		{
			LINUX_TYPES[:len(LINUX_TYPES) - 1],
			"\nlrwxrwxrwx 0/0 0 x voxiverse-0.5.1-linux-x64/l -> /etc\n",
		},
		context.temp_allocator,
	)
	names := strings.concatenate(
		{LINUX_NAMES, "voxiverse-0.5.1-linux-x64/l\n"},
		context.temp_allocator,
	)
	testing.expect(t, !listing_check(names, link, LINUX_FOLDER), "a symbolic link")
	hard := strings.concatenate(
		{LINUX_TYPES, "hrw-r--r-- 0/0 0 x voxiverse-0.5.1-linux-x64/h link to voxiverse\n"},
		context.temp_allocator,
	)
	names = strings.concatenate(
		{LINUX_NAMES, "voxiverse-0.5.1-linux-x64/h\n"},
		context.temp_allocator,
	)
	testing.expect(t, !listing_check(names, hard, LINUX_FOLDER), "a hard link")
	testing.expect(
		t,
		!listing_check(LINUX_NAMES, LINUX_TYPES[:200], LINUX_FOLDER),
		"fewer types than names",
	)
}

// A package tree of layout under dir/folder, each file holding text.
package_tree :: proc(dir, folder: string, layout: Layout, text: string) {
	for file in layout.required {
		path := join(dir, folder, file)
		os.make_directory_all(path[:strings.last_index_any(path, "/\\")])
		_ = os.write_entire_file(path, transmute([]u8)text)
	}
	os.make_directory_all(join(dir, folder, "licenses"))
	_ = os.write_entire_file(join(dir, folder, "licenses", "CREDITS.txt"), transmute([]u8)text)
}

@(test)
test_tree_check :: proc(t: ^testing.T) {
	dir := "build/tmp/update_tree"
	os.remove_all(dir)
	defer os.remove_all(dir)
	for layout in ([]Layout{LAYOUT_LINUX, LAYOUT_WINDOWS, LAYOUT_MACOS}) {
		os.remove_all(dir)
		package_tree(dir, "pkg", layout, "new")
		testing.expectf(t, tree_check(dir, "pkg", layout), "a package of %s", layout.game)
		testing.expect(t, !tree_check(dir, "other", layout), "another folder's name")
	}
	// A file the layout requires is missing, or is a folder.
	os.remove_all(dir)
	package_tree(dir, "pkg", LAYOUT_LINUX, "new")
	os.remove(join(dir, "pkg", "voxiverse-server"))
	testing.expect(t, !tree_check(dir, "pkg", LAYOUT_LINUX), "no server")
	os.make_directory(join(dir, "pkg", "voxiverse-server"))
	testing.expect(t, !tree_check(dir, "pkg", LAYOUT_LINUX), "the server a folder")
	// Something beside the one folder.
	os.remove_all(dir)
	package_tree(dir, "pkg", LAYOUT_LINUX, "new")
	_ = os.write_entire_file(join(dir, "stray"), transmute([]u8)string("x"))
	testing.expect(t, !tree_check(dir, "pkg", LAYOUT_LINUX), "a second entry")
}

// A link in the unpacked tree (one the archive's listing hid) refuses it, wherever it
// points.
@(test)
test_tree_with_a_link :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir := "build/tmp/update_tree_link"
		os.remove_all(dir)
		defer os.remove_all(dir)
		package_tree(dir, "pkg", LAYOUT_LINUX, "new")
		testing.expect(t, tree_check(dir, "pkg", LAYOUT_LINUX))
		_ = os.symlink("/etc", join(dir, "pkg", "licenses", "outside"))
		testing.expect(t, !tree_check(dir, "pkg", LAYOUT_LINUX), "a link out of the tree")
		os.remove(join(dir, "pkg", "licenses", "outside"))
		_ = os.symlink("../README.txt", join(dir, "pkg", "licenses", "inside"))
		testing.expect(t, !tree_check(dir, "pkg", LAYOUT_LINUX), "a link inside the tree")
	}
}
