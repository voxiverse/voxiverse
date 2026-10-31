package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The layout lints, run by `check`: docs/layout.md lists every folder and the file-name
// patterns it allows; scratch files live in build/. Neither has an exemption.

LAYOUT_MANIFEST :: "docs/layout.md"

Layout_Row :: struct {
	folder:   string,
	patterns: []string,
}

// parse_layout reads the manifest's table rows: `| `folder` | text | `pattern`, `pattern` |`.
// A row whose first cell is not a backticked path is not a folder row.
parse_layout :: proc(text: string) -> []Layout_Row {
	rows := make([dynamic]Layout_Row)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "| `") {continue}
		cells := strings.split(strings.trim_space(line), "|")
		// "", folder, text, patterns, ""
		if len(cells) < 5 {continue}
		folder := strings.trim(strings.trim_space(cells[1]), "`")
		patterns := make([dynamic]string)
		for p in strings.split(cells[len(cells) - 2], ",") {
			pattern := strings.trim(strings.trim_space(p), "`")
			if pattern != "" {append(&patterns, pattern)}
		}
		append(&rows, Layout_Row{folder = folder, patterns = patterns[:]})
	}
	return rows[:]
}

// lint_layout: every tracked file is in a listed folder and matches one of its patterns.
lint_layout :: proc(rows: []Layout_Row, tracked: []string) -> []string {
	found := make([dynamic]string)
	unlisted := make(map[string]bool)
	for path in tracked {
		folder := "."
		name := path
		if slash := strings.last_index_byte(path, '/'); slash >= 0 {
			folder = path[:slash]
			name = path[slash + 1:]
		}
		row: ^Layout_Row
		for &r in rows {
			if r.folder == folder {row = &r;break}
		}
		if row == nil {
			if !unlisted[folder] {
				unlisted[folder] = true
				append(
					&found,
					fmt.aprintf(
						"%s: folder %s is not in %s: add its row in the same commit",
						path,
						folder,
						LAYOUT_MANIFEST,
					),
				)
			}
			continue
		}
		matched := false
		for pattern in row.patterns {
			if ok, _ := filepath.match(pattern, name); ok {matched = true;break}
		}
		if !matched {
			append(
				&found,
				fmt.aprintf(
					"%s: %s does not match the patterns of %s in %s (%s)",
					path,
					name,
					folder,
					LAYOUT_MANIFEST,
					strings.join(row.patterns, ", "),
				),
			)
		}
	}
	// A listed folder with no tracked file is a stale row.
	for row in rows {
		used := false
		for path in tracked {
			if strings.has_prefix(path, row.folder + "/") &&
			   strings.index_byte(path[len(row.folder) + 1:], '/') < 0 {used = true;break}
			if row.folder == "." && strings.index_byte(path, '/') < 0 {used = true;break}
		}
		if !used {
			append(
				&found,
				fmt.aprintf("%s: folder %s has no tracked file: delete its row", LAYOUT_MANIFEST, row.folder),
			)
		}
	}
	return found[:]
}

// lint_scratch: no untracked, non-ignored file anywhere (scratch goes in build/, which is
// gitignored).
lint_scratch :: proc(untracked: []string) -> []string {
	found := make([dynamic]string)
	for path in untracked {
		if path == "" {continue}
		append(
			&found,
			fmt.aprintf(
				"%s: untracked file outside build/: scratch goes in build/tmp/ (or `git add` it with its row in %s)",
				path,
				LAYOUT_MANIFEST,
			),
		)
	}
	return found[:]
}

layout_lint :: proc() -> bool {
	data, err := os.read_entire_file_from_path(LAYOUT_MANIFEST, context.allocator)
	if err != nil {
		fmt.eprintfln("lint   %s: unreadable", LAYOUT_MANIFEST)
		return false
	}
	listing, ok := capture({"git", "ls-files", "-z", "--cached"})
	if !ok {
		fmt.eprintln("layout git ls-files failed")
		return false
	}
	tracked := strings.split(listing, "\x00", context.temp_allocator)
	kept := make([dynamic]string, context.temp_allocator)
	for p in tracked {
		if p != "" {append(&kept, p)}
	}
	ok = true
	for msg in lint_layout(parse_layout(string(data)), kept[:]) {
		fmt.eprintln(msg)
		ok = false
	}
	if ok {fmt.println("lint   every file is in a folder docs/layout.md lists, under a pattern it allows")}
	return ok
}

scratch_lint :: proc() -> bool {
	listing, ok := capture({"git", "ls-files", "-z", "--others", "--exclude-standard"})
	if !ok {
		fmt.eprintln("scratch git ls-files failed")
		return false
	}
	found := lint_scratch(strings.split(listing, "\x00", context.temp_allocator))
	for msg in found {fmt.eprintln(msg)}
	if len(found) == 0 {fmt.println("lint   no untracked file outside build/")}
	return len(found) == 0
}
