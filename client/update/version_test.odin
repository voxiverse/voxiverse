package update

import "core:testing"

@(test)
test_version_parse :: proc(t: ^testing.T) {
	v, ok := version_parse("0.5.3")
	testing.expect(t, ok)
	testing.expect_value(t, v.numbers, [3]u32{0, 5, 3})
	testing.expect_value(t, v.pre, "")
	v, ok = version_parse("0.4.0-flood.5")
	testing.expect(t, ok)
	testing.expect_value(t, v.numbers, [3]u32{0, 4, 0})
	testing.expect_value(t, v.pre, "flood.5")
	refused := []string {
		"",
		"0.5",
		"0.5.3.1",
		"v0.5.3",
		"0.5.3+4", // a development build's
		"0.0.0-dev+4",
		"01.5.3",
		"0.5.-3",
		"0.5.3-",
		"0.5.3-a..b",
		"0.5.3-a b",
		"1000000.0.0",
		"0.5.3 ",
	}
	for text in refused {
		_, refused_ok := version_parse(text)
		testing.expectf(t, !refused_ok, "%q was read as a version", text)
	}
}

// Newer is by the numbers; the same numbers without a pre-release part come after it.
@(test)
test_version_order :: proc(t: ^testing.T) {
	order := []string {
		"0.4.0-flood.5",
		"0.4.0-flood.12",
		"0.4.0-rc",
		"0.4.0",
		"0.4.1",
		"0.5.0",
		"0.10.0",
		"1.0.0-alpha",
		"1.0.0-alpha.1",
		"1.0.0-alpha.beta",
		"1.0.0",
	}
	for a, i in order {
		va, _ := version_parse(a)
		for b, j in order {
			vb, _ := version_parse(b)
			testing.expectf(
				t,
				version_newer(va, vb) == (i > j),
				"%s newer than %s: %v",
				a,
				b,
				version_newer(va, vb),
			)
		}
	}
}
