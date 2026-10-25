package base

import "core:fmt"
import "core:strings"

// What build this is (PLAN.md, M21), stamped in by the build driver with
// -define. VERSION is 0.<milestone>.<patch>: the version tag's on a tagged
// commit ("0.21.0"), else the last tag's with the commits since
// ("0.21.0-dev.5"; "0.0.0-dev" before any tag). RELEASE_NAME is a release's
// name for players, from its tag's message ("Pre-Alpha 1"), empty
// otherwise. COMMIT is the commit's short hash ("-dirty" with uncommitted
// changes). The network protocol's version is its own (game/protocol.odin).
VERSION :: #config(VX_VERSION, "0.0.0-dev")
RELEASE_NAME :: #config(VX_RELEASE_NAME, "")
COMMIT :: #config(VX_COMMIT, "unknown")

// version_text: the build as players see it: "Pre-Alpha 1 (0.21.0)" for a
// named release, "0.21.0" for another, "0.21.0-dev.5 (1a2b3c4d5e6f)" for a
// development build.
version_text :: proc(allocator := context.temp_allocator) -> string {
	if RELEASE_NAME !=
	   "" {return fmt.aprintf("%s (%s)", RELEASE_NAME, VERSION, allocator = allocator)}
	if COMMIT == "unknown" || !version_is_dev() {return VERSION}
	return fmt.aprintf("%s (%s)", VERSION, COMMIT, allocator = allocator)
}

// version_is_dev: built from a commit that is not a release.
version_is_dev :: proc() -> bool {
	return strings.contains(VERSION, "-")
}
