package build

import "core:os"
import "core:slice"
import "core:testing"

PLATFORMS_DOC :: #directory + "/../../docs/platforms.md"

// The tier table of docs/platforms.md and TIER1_TARGETS agree: a target
// added to one and not the other fails here.
@(test)
test_platforms_doc_matches :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(PLATFORMS_DOC, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot read %s: %v", PLATFORMS_DOC, err)
	if err != nil {return}
	got, ok := platforms_tier_targets(string(data), 1)
	testing.expect(t, ok, "docs/platforms.md has no Tier 1 row (| **1** | promise | targets |)")
	want := TIER1_TARGETS
	g := slice.clone(got, context.temp_allocator)
	w := slice.clone(want[:], context.temp_allocator)
	slice.sort(g)
	slice.sort(w)
	testing.expectf(
		t,
		slice.equal(g, w),
		"docs/platforms.md lists Tier 1 targets %v, tools/build's TIER1_TARGETS is %v; change one to match the other",
		got,
		want,
	)
	// Tiers 2 and 3 are listed too, and no target is in two tiers.
	seen := make(map[string]int, allocator = context.temp_allocator)
	for tier in 1 ..= 3 {
		row, row_ok := platforms_tier_targets(string(data), tier)
		testing.expectf(
			t,
			row_ok && len(row) > 0,
			"docs/platforms.md has no targets for Tier %d",
			tier,
		)
		for target in row {
			testing.expectf(t, target not_in seen, "%s is in two tiers", target)
			seen[target] = tier
		}
	}
}

// The parser itself, on a table written here.
@(test)
test_platforms_row_parser :: proc(t: ^testing.T) {
	doc := "| Tier | Promise | Targets |\n|---|---|---|\n| **1** | blocks a release | `a_b`, `c_d` (port in progress) |\n| **2** | tests | `e_f` |\n"
	row, ok := platforms_tier_targets(doc, 1)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(row, []string{"a_b", "c_d"}))
	row, ok = platforms_tier_targets(doc, 2)
	testing.expect(t, ok && slice.equal(row, []string{"e_f"}))
	_, ok = platforms_tier_targets(doc, 3)
	testing.expect(t, !ok)
}
