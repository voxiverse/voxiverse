package script

import "core:strings"
import "core:testing"

AST_PROGRAM :: #load("testdata/ast/program.vxs", string)
AST_WANT :: #load("testdata/ast/program.txt", string)

// parse_dump parses src and dumps its tree, or returns the syntax error's message.
parse_dump :: proc(src: string) -> (dump: string, err: Syntax_Error, ok: bool) {
	context.allocator = context.temp_allocator
	scratch := strings.builder_make()
	p: Parser
	body, parsed := parse_module(&p, src, &scratch)
	if !parsed {return "", p.lx.err, false}
	b := strings.builder_make()
	for n in body {ast_dump(&b, n)}
	return strings.to_string(b), {}, true
}

@(test)
test_parser_ast_dump :: proc(t: ^testing.T) {
	dump, err, ok := parse_dump(AST_PROGRAM)
	if !testing.expectf(t, ok, "the AST program did not parse: %s", err.message) {return}
	want, _ := strings.replace_all(AST_WANT, "\r\n", "\n", context.temp_allocator)
	testing.expectf(
		t,
		dump == want,
		"the AST dump differs from testdata/ast/program.txt:\n%s",
		dump,
	)
}

@(test)
test_parser_nesting :: proc(t: ^testing.T) {
	nested :: proc(n: int) -> string {
		return strings.concatenate(
			{
				strings.repeat("do ", n, context.temp_allocator),
				strings.repeat("end ", n, context.temp_allocator),
			},
			context.temp_allocator,
		)
	}
	_, err, ok := parse_dump(nested(200))
	testing.expectf(t, ok, "200 nested blocks were refused: %s", err.message)
	_, err, ok = parse_dump(nested(201))
	testing.expect(t, !ok, "201 nested blocks were accepted")
	testing.expect_value(t, err.message, "too many nested levels (the limit is 200)")
	testing.expect_value(t, err.hint, "split the code into smaller functions")
}
