package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
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

// GAME_SEGMENT, in a row's folder, stands for any game's folder name: `games/<game>` is the
// shape of every game's folder, one row for all of them, so a new game adds no row.
GAME_SEGMENT :: "<game>"

// is_game_name: a game's folder name is singular snake_case: a lower-case letter, then
// lower-case letters, digits and underscores.
is_game_name :: proc(name: string) -> bool {
	if name == "" || name[0] < 'a' || name[0] > 'z' {return false}
	for ch in transmute([]u8)name {
		switch ch {
		case 'a' ..= 'z', '0' ..= '9', '_':
		case:
			return false
		}
	}
	return true
}

// row_matches: folder is the row's folder, or has its shape: the same path with a game's
// name for each GAME_SEGMENT.
row_matches :: proc(row, folder: string) -> bool {
	if row == folder {return true}
	if !strings.contains(row, GAME_SEGMENT) {return false}
	row_rest, folder_rest := row, folder
	for {
		want, more := strings.split_iterator(&row_rest, "/")
		got, more_folder := strings.split_iterator(&folder_rest, "/")
		if !more || !more_folder {return !more && !more_folder}
		if want == GAME_SEGMENT {
			if !is_game_name(got) {return false}
		} else if want != got {return false}
	}
}

// GAME_PACK_AS: a game's pack (`games/<game>/pack`) is laid out as a pack is, so each of
// its folders follows the base pack's row of the same path (`games/<game>/pack/data/blocks`
// is `assets/packs/voxiverse/data/blocks`): a game's pack adds no row either.
GAME_PACK_AS :: "assets/packs/voxiverse"

// layout_folder: the folder whose row covers folder: a game's pack folder is the base
// pack's of the same path (GAME_PACK_AS), any other is itself.
layout_folder :: proc(folder: string) -> string {
	parts := strings.split_n(folder, "/", 4, context.temp_allocator)
	if len(parts) < 3 || parts[0] != "games" || !is_game_name(parts[1]) || parts[2] != "pack" {
		return folder
	}
	if len(parts) == 3 {return GAME_PACK_AS}
	return strings.concatenate({GAME_PACK_AS, "/", parts[3]}, context.temp_allocator)
}

// folder_of: the folder a tracked path is in ("." for the root).
folder_of :: proc(path: string) -> string {
	if slash := strings.last_index_byte(path, '/'); slash >= 0 {return path[:slash]}
	return "."
}

// lint_layout: every tracked file is in a listed folder (or one of a listed shape, or a
// game's pack folder: layout_folder) and matches one of its patterns.
lint_layout :: proc(rows: []Layout_Row, tracked: []string) -> []string {
	found := make([dynamic]string)
	unlisted := make(map[string]bool)
	for path in tracked {
		folder := folder_of(path)
		name := path[len(folder) + 1:] if folder != "." else path
		row: ^Layout_Row
		for &r in rows {
			if row_matches(r.folder, layout_folder(folder)) {row = &r; break}
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
			if ok, _ := filepath.match(pattern, name); ok {matched = true; break}
		}
		if !matched {
			append(
				&found,
				fmt.aprintf(
					"%s: %s does not match the patterns of %s in %s (%s)",
					path,
					name,
					row.folder,
					LAYOUT_MANIFEST,
					strings.join(row.patterns, ", "),
				),
			)
		}
	}
	// A listed folder (or shape) with no tracked file is a stale row.
	for row in rows {
		used := false
		for path in tracked {
			if row_matches(row.folder, folder_of(path)) {used = true; break}
		}
		if !used {
			append(
				&found,
				fmt.aprintf(
					"%s: folder %s has no tracked file: delete its row",
					LAYOUT_MANIFEST,
					row.folder,
				),
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

// parse_cap reads the cap from the manifest: a line `Cap: `N` files per package`. Zero when absent.
parse_cap :: proc(text: string) -> int {
	rest_text := text
	for line in strings.split_lines_iterator(&rest_text) {
		at := strings.index(line, "Cap: `")
		if at < 0 {continue}
		rest := line[at + len("Cap: `"):]
		end := strings.index_byte(rest, '`')
		if end < 0 {continue}
		n, ok := strconv.parse_int(rest[:end])
		return n if ok else 0
	}
	return 0
}

// lint_cap: no package holds more than `cap` non-test `.odin` files directly in its folder
// (tests sit beside their code and are not counted). There is no per-folder allowance.
lint_cap :: proc(cap: int, tracked: []string) -> []string {
	found := make([dynamic]string)
	if cap <= 0 {
		append(&found, fmt.aprintf("%s: no `Cap: `N` files per package` line", LAYOUT_MANIFEST))
		return found[:]
	}
	counts := make(map[string]int, allocator = context.temp_allocator)
	for path in tracked {
		if !strings.has_suffix(path, ".odin") || strings.has_suffix(path, "_test.odin") {continue}
		counts[filepath.dir(path)] += 1
	}
	for dir, n in counts {
		if n > cap {
			append(
				&found,
				fmt.aprintf(
					"%s: %d files, over the cap of %d per package: split it into feature packages (see %s)",
					dir,
					n,
					cap,
					LAYOUT_MANIFEST,
				),
			)
		}
	}
	return found[:]
}

// lint_cap_counts: the counts the manifest's cap section states are the packages' own:
// each "`dir` (N files)" or "`dir` (N)" there, and "every other package has M or
// fewer" for every package it does not name. A count that has gone stale fails.
lint_cap_counts :: proc(text: string, tracked: []string) -> []string {
	found := make([dynamic]string)
	counts := make(map[string]int, allocator = context.temp_allocator)
	for path in tracked {
		if !strings.has_suffix(path, ".odin") || strings.has_suffix(path, "_test.odin") {continue}
		counts[filepath.dir(path)] += 1
	}
	_, _, section := strings.partition(text, "## The cap")
	section, _, _ = strings.partition(section, "\n## ")
	named := make([dynamic]string, context.temp_allocator)
	rest := section
	for {
		_, tick, after := strings.partition(rest, "`")
		if tick == "" {break}
		dir, closed, more := strings.partition(after, "`")
		if closed == "" {break}
		rest = more
		gap := strings.trim_left_space(more) // (a line may break before the count)
		if len(gap) == len(more) || !strings.has_prefix(gap, "(") {continue}
		digits := gap[1:]
		n := 0
		for n < len(digits) && digits[n] >= '0' && digits[n] <= '9' {n += 1}
		if n == 0 {continue}
		stated, _ := strconv.parse_int(digits[:n])
		append(&named, dir)
		if counts[dir] != stated {
			append(
				&found,
				fmt.aprintf(
					"%s: says %s has %d files; it has %d",
					LAYOUT_MANIFEST,
					dir,
					stated,
					counts[dir],
				),
			)
		}
	}
	if at := strings.index(section, "every other package has "); at >= 0 {
		digits := section[at + len("every other package has "):]
		n := 0
		for n < len(digits) && digits[n] >= '0' && digits[n] <= '9' {n += 1}
		bound, _ := strconv.parse_int(digits[:n])
		for dir, c in counts {
			if c > bound && !slice.contains(named[:], dir) {
				append(
					&found,
					fmt.aprintf(
						"%s: says every other package has %d files or fewer; %s has %d",
						LAYOUT_MANIFEST,
						bound,
						dir,
						c,
					),
				)
			}
		}
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
	for msg in lint_cap(parse_cap(string(data)), kept[:]) {
		fmt.eprintln(msg)
		ok = false
	}
	for msg in lint_cap_counts(string(data), kept[:]) {
		fmt.eprintln(msg)
		ok = false
	}
	if ok {fmt.println("lint   every file is in a folder docs/layout.md lists, under a pattern it allows, no package is over the cap and the counts it states are true")}
	return ok
}

// lint_package_lists: the driver's package lists stay complete. A folder holding a tracked
// `.odin` file must be in `packages` (all_packages: or `check` would never type-check it); a folder outside
// tests/ holding an `@(test)` procedure must be in `test_packages` (all_test_packages: or `test` would never run
// it; tests/ and its fixtures are `build system`'s, by location); a test package must be a
// package; and every such folder must lie under one of `source_dirs` (or the format check would
// skip it). `with_tests` are the tracked files that contain an `@(test)` procedure.
lint_package_lists :: proc(
	tracked, with_tests, packages, test_packages, source_dirs: []string,
) -> []string {
	found := make([dynamic]string)
	has :: proc(list: []string, s: string) -> bool {
		for x in list {if x == s {return true}}
		return false
	}
	seen := make(map[string]bool, context.temp_allocator)
	for path in tracked {
		if !strings.has_suffix(path, ".odin") {continue}
		folder := folder_of(path)
		if seen[folder] {continue}
		seen[folder] = true
		if !has(packages, folder) {
			append(
				&found,
				fmt.aprintf(
					"%s: folder %s holds Odin code but is not in PACKAGES (tools/build/main.odin): `check` would not type-check it",
					path,
					folder,
				),
			)
		}
		under := false
		for dir in source_dirs {
			if folder == dir || (strings.has_prefix(folder, dir) && folder[len(dir)] == '/') {
				under = true
				break
			}
		}
		if !under {
			append(
				&found,
				fmt.aprintf(
					"%s: folder %s is under none of SOURCE_DIRS: the format check would skip it",
					path,
					folder,
				),
			)
		}
	}
	tested := make(map[string]bool, context.temp_allocator)
	for path in with_tests {
		folder := folder_of(path)
		if folder == "tests" || strings.has_prefix(folder, "tests/") {continue}
		if tested[folder] {continue}
		tested[folder] = true
		if !has(test_packages, folder) {
			append(
				&found,
				fmt.aprintf(
					"%s: folder %s holds an @(test) procedure but is not in TEST_PACKAGES (tools/build/main.odin): `test` would not run it",
					path,
					folder,
				),
			)
		}
	}
	for pkg in test_packages {
		if !has(packages, pkg) {
			append(&found, fmt.aprintf("TEST_PACKAGES lists %s, which is not in PACKAGES", pkg))
		}
	}
	return found[:]
}

package_lists_lint :: proc() -> bool {
	listing, ok := capture({"git", "ls-files", "-z", "--cached"})
	if !ok {
		fmt.eprintln("package_lists git ls-files failed")
		return false
	}
	tracked := make([dynamic]string, context.temp_allocator)
	for p in strings.split(listing, "\x00", context.temp_allocator) {
		if p != "" {append(&tracked, p)}
	}
	hits, hit_ok := capture({"git", "grep", "-l", "-z", "^@(test)", "--", "*.odin"})
	with_tests := make([dynamic]string, context.temp_allocator)
	if hit_ok {
		for p in strings.split(hits, "\x00", context.temp_allocator) {
			if p != "" {append(&with_tests, p)}
		}
	}
	// A shelved game's tests are not run, but they are its, not a forgotten package's.
	_, game_tests := game_packages()
	found := lint_package_lists(
		tracked[:],
		with_tests[:],
		all_packages(),
		slice.concatenate([][]string{TEST_PACKAGES, game_tests}),
		SOURCE_DIRS,
	)
	for msg in found {fmt.eprintln(msg)}
	if len(found) ==
	   0 {fmt.println("lint   PACKAGES, TEST_PACKAGES and SOURCE_DIRS cover every Odin folder")}
	return len(found) == 0
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
