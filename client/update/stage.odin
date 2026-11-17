package update

import "core:os"
import "core:path/filepath"
import "core:strings"

// What a package is, and checking an unpacked one before it goes anywhere near the
// installed game: the archive's listing before it is unpacked, the unpacked tree after.

// Layout: what a package holds on a platform (tools/build/package.odin makes them).
Layout :: struct {
	game:     string, // the game's executable, from the package's folder
	required: []string, // the files every package has (the game's among them)
	app:      string, // macOS: the app bundle, which may stand alone ("" elsewhere)
	app_only: []string, // ... and the files that make it one
}

LAYOUT_LINUX :: Layout {
	game     = "voxiverse",
	required = {"voxiverse", "voxiverse-server", "README.txt", "LICENSE"},
}
LAYOUT_WINDOWS :: Layout {
	game     = "voxiverse.exe",
	required = {"voxiverse.exe", "voxiverse-server.exe", "README.txt", "LICENSE"},
}
LAYOUT_MACOS :: Layout {
	game     = "Voxiverse.app/Contents/MacOS/voxiverse",
	required = {
		"Voxiverse.app/Contents/MacOS/voxiverse",
		"Voxiverse.app/Contents/Info.plist",
		"voxiverse-server",
		"README.txt",
		"LICENSE",
	},
	app      = "Voxiverse.app",
	app_only = {"Voxiverse.app/Contents/MacOS/voxiverse", "Voxiverse.app/Contents/Info.plist"},
}

when ODIN_OS == .Windows {
	LAYOUT :: LAYOUT_WINDOWS
} else when ODIN_OS == .Darwin {
	LAYOUT :: LAYOUT_MACOS
} else {
	LAYOUT :: LAYOUT_LINUX
}

TREE_ENTRIES_MAX :: 4096
TREE_DEPTH_MAX :: 16

// listing_check: an archive's listing, before it is unpacked: names (`tar -t`, a line
// each) all inside the one folder (folder/...), none absolute, none with a "." or ".."
// part, a backslash, a colon or a control character; and types (`tar -tv`, a line each,
// the first letter its kind) only files and folders, as many lines as there are names:
// no link of any kind, so nothing unpacked can point out of the staging folder.
listing_check :: proc(names, types: string, folder: string) -> bool {
	count := 0
	rest := names
	for line in strings.split_lines_iterator(&rest) {
		name := strings.trim_right(line, "\r")
		if name == "" {continue}
		count += 1
		if count > TREE_ENTRIES_MAX || !name_inside(name, folder) {return false}
	}
	kinds := 0
	rest = types
	for line in strings.split_lines_iterator(&rest) {
		if strings.trim_space(line) == "" {continue}
		kinds += 1
		if line[0] != '-' && line[0] != 'd' {return false}
	}
	return count > 0 && kinds == count
}

// name_inside: an archive member's name lies in folder.
@(private = "file")
name_inside :: proc(name, folder: string) -> bool {
	inside, cut := cut_prefix(name, folder)
	if !cut {return false}
	if inside == "" || inside == "/" {return true}
	if inside[0] != '/' {return false} 	// (folder-other/...)
	for c in transmute([]u8)name {
		if c < 0x20 || c == 0x7f || c == '\\' || c == ':' {return false}
	}
	parts := strings.trim_suffix(inside[1:], "/")
	for part in strings.split_iterator(&parts, "/") {
		if part == "" || part == "." || part == ".." {return false}
	}
	return true
}

// tree_check: the unpacked tree in dir is a package of layout: dir holds the one folder
// and nothing else, that folder only files and folders (no link, no device; within the
// caps on entries and depth), and every file layout requires is a file.
tree_check :: proc(dir, folder: string, layout: Layout) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil || len(entries) != 1 || entries[0].name != folder {return false}
	root := join(dir, folder)
	count := 0
	if !tree_walk(root, 0, &count) {return false}
	for file in layout.required {
		info, serr := os.lstat(join(root, file), context.temp_allocator)
		if serr != nil || info.type != .Regular {return false}
	}
	return true
}

@(private = "file")
tree_walk :: proc(dir: string, depth: int, count: ^int) -> bool {
	if depth > TREE_DEPTH_MAX {return false}
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return false}
	for e in entries {
		count^ += 1
		if count^ > TREE_ENTRIES_MAX {return false}
		info, serr := os.lstat(e.fullpath, context.temp_allocator) // (never through a link)
		if serr != nil {return false}
		switch info.type {
		case .Regular:
		case .Directory:
			if !tree_walk(e.fullpath, depth + 1, count) {return false}
		case .Undetermined, .Symlink, .Named_Pipe, .Socket, .Block_Device, .Character_Device:
			return false
		}
	}
	return true
}

@(private)
join :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}
