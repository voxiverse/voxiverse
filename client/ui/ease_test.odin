package ui

import "core:testing"

// Every curve starts at 0 and ends at 1, holds its ends outside 0 ..= 1, and rises on the
// way; the ones that overshoot go past 1 and come back.
@(test)
test_ease_ends :: proc(t: ^testing.T) {
	for e in Ease {
		testing.expectf(t, abs(ease(e, 0)) < 1e-5, "%v at 0: %v", e, ease(e, 0))
		testing.expectf(t, abs(ease(e, 1) - 1) < 1e-5, "%v at 1: %v", e, ease(e, 1))
		testing.expect_value(t, ease(e, -2), ease(e, 0))
		testing.expect_value(t, ease(e, 3), ease(e, 1))
		testing.expectf(t, ease(e, 0.5) > 0, "%v rises", e)
	}
	testing.expect(t, ease(.Out_Back, 0.7) > 1, "a pop goes past its end")
	testing.expect(t, ease(.Out_Elastic, 0.1) > 1, "a bounce goes past its end")
	testing.expect(t, ease(.Out_Cubic, 0.5) > ease(.Linear, 0.5), "out curves are ahead")
	testing.expect_value(t, ease(.In_Out, 0.5), 0.5)
}
