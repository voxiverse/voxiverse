package game

import "core:testing"

@(test)
test_format :: proc(t: ^testing.T) {
	spans := make([dynamic]Span, context.temp_allocator)
	format_parse("&c&lAdmin&r Bea: hi &&c &q&#00ff80green&mx", &spans)
	want := []Span {
		{"Admin", {color = FORMAT_COLORS[12], colored = true, bold = true}},
		{" Bea: hi &", {}},
		{"c &q", {}},
		{"green", {color = {0, 0xff, 0x80}, colored = true}},
		{"x", {color = {0, 0xff, 0x80}, colored = true, strike = true}},
	}
	testing.expect_value(t, len(spans), len(want))
	for s, i in spans {
		if i < len(want) {testing.expectf(t, s == want[i], "span %d: %v, want %v", i, s, want[i])}
	}
	// A colour clears the styles before it.
	clear(&spans)
	format_parse("&l&cX", &spans)
	testing.expect(t, len(spans) == 1 && !spans[0].style.bold && spans[0].style.colored)
	// Not allowed: shown as written.
	clear(&spans)
	format_parse("&cred &lbold", &spans, {.Style})
	testing.expect(t, len(spans) == 2 && spans[0].text == "&cred " && spans[1].style.bold)
	testing.expect_value(t, format_strip("&c&lAdmin&r &#zzzzzz&&"), "Admin &#zzzzzz&")
	testing.expect_value(
		t,
		format_filter("&cred &lbold &#112233x &&", {.Style}),
		"&&cred &lbold &&#112233x &&",
	)
	testing.expect_value(t, format_strip(format_filter("&cred &#112233x", {})), "&cred &#112233x")
	// Parts do not leak into each other, even ending in a lone &.
	line := format_join({"&c&lAdmin", " Bea", ": &e1&", "2"})
	testing.expect_value(t, line, "&c&lAdmin&r Bea&r: &e1&&&r2")
	clear(&spans)
	format_parse(line, &spans)
	last := spans[len(spans) - 1]
	testing.expect(t, last.text == "2" && last.style == {}, "the message's colour leaked")
	testing.expect_value(t, format_strip(line), "Admin Bea: 1&2")
}
