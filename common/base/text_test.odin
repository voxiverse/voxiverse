package base

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

// text_cut keeps the longest prefix of whole letters within the limit, for every limit
// and every letter width.
@(test)
test_text_cut :: proc(t: ^testing.T) {
	s := "aé€😀b"
	for limit in -1 ..= len(s) + 1 {
		cut := text_cut(s, limit)
		testing.expect(t, utf8.valid_string(cut) && strings.has_prefix(s, cut))
		testing.expect(t, len(cut) <= max(limit, 0))
		// The next letter would not have fitted.
		if len(cut) < len(s) {
			_, width := utf8.decode_rune_in_string(s[len(cut):])
			testing.expect(t, len(cut) + width > limit)
		}
	}
}

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
