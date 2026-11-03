package build

import "core:fmt"
import "core:os"
import "core:strings"

// SCRIPT_API_PATHSPEC selects the commits listed under "Script API": those that change
// the script language and libraries' reference (docs/script.md, or a generated
// docs/script_api*).
SCRIPT_API_PATHSPEC :: "docs/script*"

// FIRST_TAG_CAP is how many changes a section lists when there is no previous tag.
FIRST_TAG_CAP :: 40

RELEASE_DOWNLOADS :: `## Downloads

- Windows (64-bit): the .zip. Windows may warn about an unknown publisher (not code-signed yet): More info, Run anyway.
- Linux (64-bit): the .tar.gz. Needs a Vulkan 1.3 driver.
- macOS (Apple Silicon): the .zip. macOS asks you to confirm opening an app that is not from the App Store: see README.txt.

Will it run on your computer, and what to include in a report: https://github.com/voxiverse/voxiverse/blob/main/docs/platforms.md

README.txt inside says where settings and saves are kept. SHA256SUMS lists each file's checksum.
`

// release_notes writes the notes of a version tag's draft release: every commit subject
// since the previous version tag that is its ancestor, the subjects of the commits
// that change the script API's documentation, and the download text. ok is false when
// tag is not a tag of the repository at repo.
release_notes :: proc(repo: string, tag: string) -> (notes: string, ok: bool) {
	git :: proc(repo: string, args: ..string) -> (string, bool) {
		cmd := make([dynamic]string, 0, len(args) + 3)
		append(&cmd, "git", "-C", repo)
		append(&cmd, ..args)
		return capture(cmd[:])
	}
	ref := fmt.tprintf("refs/tags/%s", tag)
	if _, found := git(repo, "rev-parse", "-q", "--verify", ref); !found {return "", false}

	prev: string
	if listing, listed := git(repo, "tag", "--list", "v*.*.*", "--sort=-v:refname"); listed {
		for line in strings.split_lines(listing) {
			name := strings.trim_space(line)
			if name == "" || name == tag {continue}
			if _, ancestor := git(
				repo,
				"merge-base",
				"--is-ancestor",
				fmt.tprintf("refs/tags/%s", name),
				ref,
			); ancestor {
				prev = name
				break
			}
		}
	}
	range_ := prev == "" ? ref : fmt.tprintf("refs/tags/%s..%s", prev, ref)

	section :: proc(repo, range_, heading: string, capped: bool, pathspec: string) -> string {
		args := make([dynamic]string, 0, 12)
		append(&args, "log", "--reverse", "--topo-order", "--no-merges", "--format=%s", range_)
		if pathspec != "" {append(&args, "--", pathspec)}
		out, _ := git(repo, ..args[:])
		subjects := make([dynamic]string)
		seen := make(map[string]bool)
		for line in strings.split_lines(out) {
			if line == "" || line in seen {continue}
			seen[line] = true
			append(&subjects, line)
		}
		b := strings.builder_make()
		fmt.sbprintf(&b, "## %s\n\n", heading)
		first, extra := 0, 0
		if capped && len(subjects) > FIRST_TAG_CAP {
			first = len(subjects) - FIRST_TAG_CAP
			extra = first
		}
		if len(subjects) == 0 {
			strings.write_string(&b, "- (no changes)\n")
		}
		for s in subjects[first:] {
			fmt.sbprintf(&b, "- %s\n", s)
		}
		if extra > 0 {fmt.sbprintf(&b, "- …and %d earlier changes\n", extra)}
		strings.write_string(&b, "\n")
		return strings.to_string(b)
	}

	capped := prev == ""
	b := strings.builder_make()
	strings.write_string(&b, section(repo, range_, "What's in it", capped, ""))
	strings.write_string(&b, section(repo, range_, "Script API", capped, SCRIPT_API_PATHSPEC))
	strings.write_string(&b, RELEASE_DOWNLOADS)
	return strings.to_string(b), true
}

// release_notes_command: `release-notes <tag> <file>`.
release_notes_command :: proc(args: []string) -> bool {
	if len(args) != 2 {
		fmt.eprintln("usage: build release-notes <tag> <file>")
		return false
	}
	notes, ok := release_notes(".", args[0])
	if !ok {
		fmt.eprintfln("build: '%s' is not a tag", args[0])
		return false
	}
	if err := os.write_entire_file(args[1], transmute([]u8)notes); err != nil {
		fmt.eprintfln("build: cannot write %s", args[1])
		return false
	}
	return true
}
