package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
Repo :: struct {
	dir:   string,
	count: int,
}

@(private = "file")
run_git :: proc(r: ^Repo, args: ..string) -> bool {
	cmd := make([dynamic]string, 0, len(args) + 12)
	append(
		&cmd,
		"git",
		"-C",
		r.dir,
		"-c",
		"commit.gpgSign=false",
		"-c",
		"tag.gpgSign=false",
		"-c",
		"user.name=t",
		"-c",
		"user.email=t@example.com",
	)
	append(&cmd, ..args)
	_, ok := capture(cmd[:])
	return ok
}

@(private = "file")
new_repo :: proc(name: string) -> Repo {
	r := Repo {
		dir = fmt.aprintf("build/tmp/release_test_%s", name),
	}
	os.remove_all(r.dir)
	os.make_directory_all(r.dir)
	run_git(&r, "init", "-q", "-b", "main")
	return r
}

@(private = "file")
commit :: proc(r: ^Repo, subject: string, file := "") {
	r.count += 1
	name := file != "" ? file : fmt.tprintf("f%d.txt", r.count)
	path := fmt.tprintf("%s/%s", r.dir, name)
	if i := strings.last_index_byte(path, '/'); i > len(r.dir) {os.make_directory_all(path[:i])}
	body := fmt.tprintf("%d\n", r.count)
	_ = os.write_entire_file(path, transmute([]u8)body)
	run_git(r, "add", "-A")
	run_git(r, "commit", "-q", "-m", subject)
}

@(private = "file")
tag :: proc(r: ^Repo, name: string) {
	run_git(r, "tag", "-a", "-m", name, name)
}

@(private = "file")
finish :: proc(r: ^Repo) {
	os.remove_all(r.dir)
}

@(private = "file")
lines_of :: proc(notes, heading: string) -> []string {
	start := strings.index(notes, heading)
	if start < 0 {return nil}
	rest := notes[start + len(heading):]
	if end := strings.index(rest, "\n## "); end >= 0 {rest = rest[:end]}
	out := make([dynamic]string, context.temp_allocator)
	for l in strings.split_lines(rest, context.temp_allocator) {
		if strings.has_prefix(l, "- ") {append(&out, l)}
	}
	return out[:]
}

@(private = "file")
expect_list :: proc(t: ^testing.T, got: []string, want: []string) {
	testing.expect_value(t, len(got), len(want))
	if len(got) != len(want) {return}
	for w, i in want {testing.expect_value(t, got[i], w)}
}

@(test)
test_release_patch_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // short-lived, like the CLI
	r := new_repo("patch")
	defer finish(&r)
	commit(&r, "a")
	tag(&r, "v0.1.0")
	commit(&r, "b")
	tag(&r, "v0.1.1")
	commit(&r, "c")
	commit(&r, "d")
	tag(&r, "v0.1.2")
	notes, ok := release_notes(r.dir, "v0.1.2")
	testing.expect(t, ok)
	expect_list(t, lines_of(notes, "## What's in it"), {"- c", "- d"})
	expect_list(t, lines_of(notes, "## Script API"), {"- (no changes)"})
}

@(test)
test_release_minor_tag_runs_from_newest_patch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // short-lived, like the CLI
	r := new_repo("minor")
	defer finish(&r)
	commit(&r, "a")
	tag(&r, "v0.1.0")
	commit(&r, "b")
	tag(&r, "v0.1.1")
	commit(&r, "c")
	tag(&r, "v0.1.2")
	commit(&r, "d")
	tag(&r, "v0.2.0")
	notes, ok := release_notes(r.dir, "v0.2.0")
	testing.expect(t, ok)
	expect_list(t, lines_of(notes, "## What's in it"), {"- d"})
}

@(test)
test_release_no_merges_no_duplicates :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // short-lived, like the CLI
	r := new_repo("merges")
	defer finish(&r)
	commit(&r, "a")
	tag(&r, "v0.1.0")
	run_git(&r, "checkout", "-q", "-b", "side")
	commit(&r, "side work")
	run_git(&r, "checkout", "-q", "main")
	commit(&r, "same")
	commit(&r, "same")
	run_git(&r, "merge", "-q", "--no-ff", "-m", "Merge side", "side")
	tag(&r, "v0.1.1")
	notes, ok := release_notes(r.dir, "v0.1.1")
	testing.expect(t, ok)
	expect_list(t, lines_of(notes, "## What's in it"), {"- same", "- side work"})
}

@(test)
test_release_unrelated_tag_is_skipped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // short-lived, like the CLI
	r := new_repo("unrelated")
	defer finish(&r)
	commit(&r, "a")
	tag(&r, "v0.1.0")
	run_git(&r, "checkout", "-q", "-b", "other")
	commit(&r, "elsewhere")
	tag(&r, "v0.9.0")
	run_git(&r, "checkout", "-q", "main")
	commit(&r, "b")
	tag(&r, "v0.1.1")
	notes, ok := release_notes(r.dir, "v0.1.1")
	testing.expect(t, ok)
	expect_list(t, lines_of(notes, "## What's in it"), {"- b"})
}

@(test)
test_release_script_api_section :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // short-lived, like the CLI
	r := new_repo("script")
	defer finish(&r)
	commit(&r, "a")
	tag(&r, "v0.1.0")
	commit(&r, "unrelated")
	commit(&r, "language", "docs/script.md")
	commit(&r, "reference", "docs/script_api.md")
	tag(&r, "v0.1.1")
	commit(&r, "again")
	tag(&r, "v0.1.2")
	notes, _ := release_notes(r.dir, "v0.1.1")
	expect_list(t, lines_of(notes, "## Script API"), {"- language", "- reference"})
	expect_list(
		t,
		lines_of(notes, "## What's in it"),
		{"- unrelated", "- language", "- reference"},
	)
	notes2, _ := release_notes(r.dir, "v0.1.2")
	expect_list(t, lines_of(notes2, "## Script API"), {"- (no changes)"})
}

@(test)
test_release_first_tag_is_capped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // short-lived, like the CLI
	r := new_repo("first")
	defer finish(&r)
	for i in 1 ..= 45 {commit(&r, fmt.tprintf("c%d", i))}
	tag(&r, "v0.1.0")
	notes, ok := release_notes(r.dir, "v0.1.0")
	testing.expect(t, ok)
	got := lines_of(notes, "## What's in it")
	testing.expect_value(t, len(got), 41)
	if len(got) == 41 {
		testing.expect_value(t, got[0], "- c6")
		testing.expect_value(t, got[39], "- c45")
		testing.expect_value(t, got[40], "- …and 5 earlier changes")
	}
}

@(test)
test_release_order_and_downloads :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // short-lived, like the CLI
	r := new_repo("order")
	defer finish(&r)
	commit(&r, "a")
	tag(&r, "v0.1.0")
	notes, ok := release_notes(r.dir, "v0.1.0")
	testing.expect(t, ok)
	a := strings.index(notes, "## What's in it\n\n- a\n\n## Script API\n\n")
	b := strings.index(notes, "## Downloads\n\n- Windows (64-bit)")
	testing.expect(t, a == 0)
	testing.expect(t, b > a)
	testing.expect(t, strings.has_suffix(notes, "SHA256SUMS lists each file's checksum.\n"))
	testing.expect(
		t,
		strings.contains(notes, "- Linux (64-bit): the .tar.gz. Needs a Vulkan 1.3 driver.\n"),
	)
	testing.expect(t, !strings.contains(notes, "\r"))
}

@(test)
test_release_missing_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // short-lived, like the CLI
	r := new_repo("missing")
	defer finish(&r)
	commit(&r, "a")
	_, ok := release_notes(r.dir, "v9.9.9")
	testing.expect(t, !ok)
}
