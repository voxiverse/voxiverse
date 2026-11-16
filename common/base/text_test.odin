package base

import "core:testing"

@(test)
test_text_format :: proc(t: ^testing.T) {
	testing.expect_value(t, text_format("ROUND {0}"), "ROUND {0}")
	testing.expect_value(t, text_format("{1} of {0} made it", 4, 3), "3 of 4 made it")
	testing.expect_value(t, text_format("{0}% {x} {2} {}", "a"), "a% {x} {2} {}")
	Key :: enum u8 {
		A,
		B,
	}
	full := [Key]string {
		.A = "a",
		.B = "b",
	}
	_, missing := text_missing(full)
	testing.expect(t, !missing)
	gap := #partial [Key]string {
		.A = "a",
	}
	key, gap_missing := text_missing(gap)
	testing.expect(t, gap_missing && key == .B)
}
