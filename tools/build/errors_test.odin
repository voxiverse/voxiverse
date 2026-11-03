package build

import "core:strings"
import "core:testing"

@(test)
test_group_errors_prints_each_error_once_with_its_targets :: proc(t: ^testing.T) {
	err := "a.odin(3:4) Error: Undeclared name: x\n\tfoo(x)\n\t    ^\n"
	other := "b.odin(1:1) Error: Other\n\tbar\n"
	text := group_errors(
		{
			{"linux_amd64", strings.concatenate({err, other}, context.temp_allocator)},
			{"windows_amd64", err},
			{"darwin_arm64", err},
			{"linux_amd64", err},
		},
	)
	testing.expect_value(t, strings.count(text, "Undeclared name: x"), 1)
	testing.expect_value(t, strings.count(text, "foo(x)"), 1)
	testing.expect(
		t,
		strings.contains(text, "failed on: linux_amd64, windows_amd64, darwin_arm64\n"),
		text,
	)
	testing.expect(t, strings.contains(text, "Other\n\tbar\n  failed on: linux_amd64\n"), text)
}

@(test)
test_group_errors_keeps_lines_outside_messages :: proc(t: ^testing.T) {
	text := group_errors({{"linux_amd64", "link failed\n"}, {"darwin_arm64", "link failed\n"}})
	testing.expect_value(t, text, "link failed\n  failed on: linux_amd64, darwin_arm64\n")
}
