package base

import "core:strings"
import "core:testing"

@(private = "file")
Test_Settings :: struct {
	fov:         f32,
	view:        i32,
	count:       int,
	show_things: bool,
	not_a_var:   f32,
}

@(private = "file")
TEST_DEFAULTS := Test_Settings {
	fov         = 70,
	view        = 12,
	count       = 3,
	show_things = true,
}

@(private = "file", rodata)
TEST_VARS := [?]Var {
	{field = "fov", help = "field of view", min = 50, max = 110},
	{field = "view", help = "view distance", min = 2, max = 32},
	{field = "count", help = "a count", min = 0, max = 10},
	{field = "show_things", help = "show things"},
}

@(private = "file")
test_table :: proc() -> Var_Table {
	return {"test.", Test_Settings, TEST_VARS[:], &TEST_DEFAULTS}
}

@(test)
test_vars_set_and_format :: proc(t: ^testing.T) {
	table := test_table()
	testing.expect(t, var_table_check(table))
	s := TEST_DEFAULTS

	testing.expect_value(t, var_set(table, &s, "test.fov", "90.5"), Var_Error.None)
	testing.expect_value(t, s.fov, 90.5)
	testing.expect_value(t, var_set(table, &s, "test.view", "7"), Var_Error.None)
	testing.expect_value(t, s.view, 7)
	testing.expect_value(t, var_set(table, &s, "test.count", "4.6"), Var_Error.None)
	testing.expect_value(t, s.count, 5) // rounded
	testing.expect_value(t, var_set(table, &s, "test.show_things", "off"), Var_Error.None)
	testing.expect_value(t, s.show_things, false)

	// Clamped, rejected, unknown.
	testing.expect_value(t, var_set(table, &s, "test.fov", "500"), Var_Error.Out_Of_Range)
	testing.expect_value(t, s.fov, 110)
	testing.expect_value(t, var_set(table, &s, "test.fov", "lots"), Var_Error.Bad_Value)
	testing.expect_value(t, var_set(table, &s, "test.fov", "nan"), Var_Error.Bad_Value)
	testing.expect_value(t, s.fov, 110)
	testing.expect_value(t, var_set(table, &s, "test.show_things", "maybe"), Var_Error.Bad_Value)
	testing.expect_value(t, var_set(table, &s, "test.not_a_var", "1"), Var_Error.Unknown_Name)
	testing.expect_value(t, var_set(table, &s, "fov", "80"), Var_Error.Unknown_Name) // prefix required

	v, _ := var_find(table, "test.fov")
	testing.expect_value(t, var_format(table, &s, v), "110")
	var_reset(table, &s, v)
	testing.expect_value(t, s.fov, 70)
}

@(test)
test_vars_file_round_trip :: proc(t: ^testing.T) {
	table := test_table()
	a := TEST_DEFAULTS
	a.fov, a.view, a.show_things = 85.25, 20, false
	b := strings.builder_make(context.temp_allocator)
	vars_write(table, &a, &b)

	c := TEST_DEFAULTS
	problems := vars_read(table, &c, strings.to_string(b))
	testing.expect_value(t, len(problems), 0)
	testing.expect(t, a == c)

	// Bad lines are reported; good lines around them still apply.
	text := "# comment\n\ntest.view = 9\ntest.fov = huge\nnonsense\ntest.gone = 1\ntest.count = 99\n"
	d := TEST_DEFAULTS
	problems = vars_read(table, &d, text)
	testing.expect_value(t, len(problems), 4)
	testing.expect_value(t, d.view, 9)
	testing.expect_value(t, d.count, 10) // clamped, reported
	testing.expect_value(t, d.fov, 70)
	if len(problems) == 4 {
		testing.expect_value(t, problems[0].line, 4)
		testing.expect_value(t, problems[0].error, Var_Error.Bad_Value)
		testing.expect_value(t, problems[2].error, Var_Error.Unknown_Name)
		testing.expect_value(t, problems[3].error, Var_Error.Out_Of_Range)
	}
}
