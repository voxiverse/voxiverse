package build

import "core:strings"

// TIER1_TARGETS: the Odin targets that block a release (docs/platforms.md,
// Tier 1). The one list in code; test_platforms_doc_matches fails when the
// document's Tier 1 row says otherwise, so the two cannot drift. The
// cross-OS pass of `check` (#32) builds every one that is not the host.
TIER1_TARGETS :: [?]string{"windows_amd64", "linux_amd64", "darwin_arm64"}

// platforms_tier_targets: the Odin targets (the words in backticks) in the
// Targets cell of the row of the given tier in the document's tier table.
// A row is `| **<tier>** | <promise> | <targets> |`. ok is false when there
// is no such row.
platforms_tier_targets :: proc(
	doc: string,
	tier: int,
	allocator := context.temp_allocator,
) -> (
	targets: []string,
	ok: bool,
) {
	context.allocator = allocator
	prefix := strings.concatenate({"| **", itoa_small(tier), "** |"})
	for line in strings.split_lines(doc) {
		if !strings.has_prefix(line, prefix) {continue}
		cells := strings.split(strings.trim_right_space(line), "|")
		// "", " **1** ", promise, targets, "".
		if len(cells) < 5 {return nil, false}
		found := make([dynamic]string)
		parts := strings.split(cells[len(cells) - 2], "`")
		for p, i in parts {
			// Odd parts are inside backticks.
			if i % 2 == 1 {append(&found, p)}
		}
		return found[:], true
	}
	return nil, false
}

@(private = "file")
itoa_small :: proc(n: int) -> string {
	digits := "0123456789"
	return digits[n:n + 1]
}
