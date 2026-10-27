package game

import "core:testing"

@(private = "file")
refused :: proc(
	t: ^testing.T,
	text: string,
	line, col: i32,
	message: string,
	loc := #caller_location,
) {
	_, err, ok := json_parse(text, context.temp_allocator)
	testing.expect(t, !ok, loc = loc)
	testing.expect_value(t, err.message, message, loc)
	testing.expect_value(t, err.line, line, loc)
	testing.expect_value(t, err.column, col, loc)
}

@(test)
test_pack_json_values :: proc(t: ^testing.T) {
	text := `// a comment
{
	"a": 1, /* inline */
	"b": [true, false, null, -2.5e1,],
	"c": "x\né",
	"z": 0,
}`
	v, err, ok := json_parse(text, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, v.kind, Json_Kind.Object)
	testing.expect_value(t, len(v.members), 4)
	// source order
	testing.expect_value(t, v.members[0].key, "a")
	testing.expect_value(t, v.members[3].key, "z")
	testing.expect_value(t, v.members[0].key_line, 3)
	testing.expect_value(t, v.members[0].key_column, 2)
	testing.expect_value(t, v.members[0].value.kind, Json_Kind.Int)
	testing.expect_value(t, v.members[0].value.i, 1)
	testing.expect_value(t, v.members[0].value.column, 7)
	arr := v.members[1].value
	testing.expect_value(t, arr.kind, Json_Kind.Array)
	testing.expect_value(t, len(arr.items), 4)
	testing.expect_value(t, arr.items[0].b, true)
	testing.expect_value(t, arr.items[2].kind, Json_Kind.Null)
	testing.expect_value(t, arr.items[3].kind, Json_Kind.Float)
	testing.expect_value(t, arr.items[3].f, -25.0)
	testing.expect_value(t, arr.items[3].line, 4)
	testing.expect_value(t, v.members[2].value.s, "x\né")
}

@(test)
test_pack_json_refusals :: proc(t: ^testing.T) {
	refused(t, "{\n  light: 3}", 2, 3, `keys are quoted: write "light"`)
	refused(t, "{\"a\": 'x'}", 1, 7, "strings use double quotes")
	refused(t, "[Infinity]", 1, 2, "numbers are plain decimals")
	refused(t, "[NaN]", 1, 2, "numbers are plain decimals")
	refused(t, "[0x10]", 1, 2, "numbers are plain decimals")
	refused(t, "[+1]", 1, 2, "numbers are plain decimals")
	refused(t, "[.5]", 1, 2, "numbers are plain decimals")
	refused(t, "[5.]", 1, 2, "numbers are plain decimals")
	refused(
		t,
		"{\"light\": 1,\n\n\n\"light\": 2}",
		4,
		1,
		`"light" is given twice (first on line 1)`,
	)
	refused(
		t,
		"[99999999999999999999]",
		1,
		2,
		"integer does not fit in 64 bits; use a smaller number",
	)
	refused(t, "{\"a\": 1} 2", 1, 10, "text after the value; a file holds one value")
	refused(t, "{\"a\": 1", 1, 1, "the object is never closed; end it with }")
	refused(t, "/* x", 1, 1, "comment is never closed; end it with */")
}

@(test)
test_pack_json_limits :: proc(t: ^testing.T) {
	deep := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< 33 {append(&deep, '[')}
	for _ in 0 ..< 33 {append(&deep, ']')}
	_, err, ok := json_parse(string(deep[:]), context.temp_allocator)
	testing.expect(t, !ok)
	testing.expect_value(t, err.message, "nested deeper than 32 levels; flatten it")

	long := make([dynamic]u8, context.temp_allocator)
	append(&long, '"')
	for _ in 0 ..< 4097 {append(&long, 'a')}
	append(&long, '"')
	_, err, ok = json_parse(string(long[:]), context.temp_allocator)
	testing.expect(t, !ok)
	testing.expect_value(t, err.message, "string is over 4096 bytes; shorten it")

	many := make([dynamic]u8, context.temp_allocator)
	append(&many, '[')
	for _ in 0 ..< 4097 {append(&many, '1', ',')}
	append(&many, ']')
	_, err, ok = json_parse(string(many[:]), context.temp_allocator)
	testing.expect(t, !ok)
	testing.expect_value(t, err.message, "array has over 4096 entries; split it")

	// 4096 is fine
	ok4 := make([dynamic]u8, context.temp_allocator)
	append(&ok4, '[')
	for _ in 0 ..< 4096 {append(&ok4, '1', ',')}
	append(&ok4, ']')
	_, _, ok = json_parse(string(ok4[:]), context.temp_allocator)
	testing.expect(t, ok)
}
