package build

import "core:testing"

// The MoltenVK pin is complete: a SHA-256 in hex and a URL of the same version.
@(test)
test_moltenvk_pin :: proc(t: ^testing.T) {
	testing.expect(
		t,
		moltenvk_pin_valid(MOLTENVK_VERSION, MOLTENVK_SHA256, MOLTENVK_URL),
		"MOLTENVK_SHA256 must be 64 hex digits and MOLTENVK_URL must name MOLTENVK_VERSION",
	)
	testing.expect(t, !moltenvk_pin_valid("v1.4.2", "abc", MOLTENVK_URL), "a short hash passes")
	testing.expect(
		t,
		!moltenvk_pin_valid("v1.4.3", MOLTENVK_SHA256, MOLTENVK_URL),
		"a URL of another version passes",
	)
}
