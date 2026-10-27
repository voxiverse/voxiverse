package build

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_lint_names_line :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	found := lint_numbers("common/game/x.odin", "a := 1\nb := math.sin(a)\n")
	testing.expect_value(t, len(found), 1)
	testing.expect_value(
		t,
		found[0],
		"common/game/x.odin:2: math.sin in shared code: use base.sin (docs/determinism.md)",
	)
}

@(test)
test_lint_exception_and_comments :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(
		t,
		len(lint_numbers("f", "b := math.sin(a) // numbers: a visual offset\n")),
		0,
	)
	testing.expect_value(t, len(lint_numbers("f", "// math.sin( is banned\n")), 0)
	testing.expect_value(t, len(lint_numbers("f", "x := operand.y\n")), 0)
	testing.expect_value(t, len(lint_numbers("f", "x := rand.int_max(3)\n")), 1)
}

@(test)
test_pipeline_lint_names_the_write :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	found := lint_pipeline("server/x.odin", "a := 1\nchunks_set_block(&w.chunks, p, .Air)\n")
	testing.expect_value(t, len(found), 1)
	testing.expect_value(
		t,
		found[0],
		"server/x.odin:2: block write outside the edit pipeline: use set_block or bulk_edit with an Act (docs/journal.md)",
	)
	testing.expect_value(
		t,
		len(lint_pipeline("server/x.odin", "game.chunk_set(&c.blocks, a, l, b)\n")),
		1,
	)
	testing.expect_value(
		t,
		len(lint_pipeline("server/changes.odin", "chunks_set_block(&w.chunks, p, b)\n")),
		0,
	)
	testing.expect_value(
		t,
		len(lint_pipeline("server/x.odin", "// chunks_set_block( is only the pipeline's\n")),
		0,
	)
}

@(test)
test_compare_names_the_difference :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	head := "determinism 1 seed=38 ticks=3 os=%s opt=%s odin=x"
	a := strings.join(
		{
			fmt.tprintf(head, "Linux", "Minimal"),
			"1 aa clock=11 rules=22",
			"2 bb clock=11 rules=22",
			"dump 2",
			"rules.gravity = 0x1 (1)",
			"world 5",
			"end bb",
		},
		"\n",
	)
	same := strings.join(
		{
			fmt.tprintf(head, "Windows", "Speed"),
			"1 aa clock=11 rules=22",
			"2 bb clock=11 rules=22",
			"dump 2",
			"rules.gravity = 0x1 (1)",
			"world 5",
			"end bb",
		},
		"\n",
	)
	off := strings.join(
		{
			fmt.tprintf(head, "Darwin", "Speed"),
			"1 aa clock=11 rules=22",
			"2 cc clock=11 rules=23",
			"dump 2",
			"rules.gravity = 0x2 (2)",
			"world 5",
			"end cc",
		},
		"\n",
	)
	_, ok := compare_logs({"linux.minimal.txt", "windows.speed.txt"}, {a, same})
	testing.expect(t, ok, "logs that agree were called different")
	report, ok2 := compare_logs({"linux.minimal.txt", "darwin.speed.txt"}, {a, off})
	testing.expect(t, !ok2, "logs that differ were called alike")
	testing.expect(t, strings.contains(report, "differ at tick 2, in rules"), report)
	testing.expect(
		t,
		strings.contains(report, "rules.gravity = 0x1 (1) | rules.gravity = 0x2 (2)"),
		report,
	)
}
