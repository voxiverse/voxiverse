package script

import "core:strings"
import "core:testing"

// Errors formatted exactly: 25 syntax and 20 runtime errors, columns and hints included.

@(private = "file")
Error_Case :: struct {
	name, source, want: string,
}

@(private = "file")
SYNTAX_CASES := [?]Error_Case {
	{
		"s00.vxs",
		`if a != b then end
`,
		`s00.vxs:1:6: syntax error: '!=' is not an operator
    1 | if a != b then end
      |      ^^
  hint: write 'not equal' as '~='
`,
	},
	{
		"s01.vxs",
		`if a && b then end
`,
		`s01.vxs:1:6: syntax error: '&&' is not an operator
    1 | if a && b then end
      |      ^^
  hint: write 'and'
`,
	},
	{
		"s02.vxs",
		`local x = a || b
`,
		`s02.vxs:1:13: syntax error: '||' is not an operator
    1 | local x = a || b
      |             ^^
  hint: write 'or'
`,
	},
	{
		"s03.vxs",
		`local x = !a
`,
		`s03.vxs:1:11: syntax error: '!' is not an operator
    1 | local x = !a
      |           ^
  hint: write 'not'
`,
	},
	{
		"s04.vxs",
		`if x = 1 then end
`,
		`s04.vxs:1:6: syntax error: 'then' expected after the 'if' condition, got '='
    1 | if x = 1 then end
      |      ^
  hint: to compare, write '=='
`,
	},
	{
		"s05.vxs",
		`while x < 10 then
end
`,
		`s05.vxs:1:14: syntax error: 'do' expected after the 'while' condition, got 'then'
    1 | while x < 10 then
      |              ^^^^
  hint: a while loop is written 'while <condition> do ... end'
`,
	},
	{
		"s06.vxs",
		`if x do end
`,
		`s06.vxs:1:6: syntax error: 'then' expected after the 'if' condition, got 'do'
    1 | if x do end
      |      ^^
  hint: an if is written 'if <condition> then ... end'
`,
	},
	{
		"s07.vxs",
		`for i = 1, 10 then end
`,
		`s07.vxs:1:15: syntax error: 'do' expected after the 'for' range, got 'then'
    1 | for i = 1, 10 then end
      |               ^^^^
  hint: a for loop is written 'for i = 1, 10 do ... end'
`,
	},
	{
		"s08.vxs",
		`if a then
else if b then
end
`,
		`s08.vxs:4:1: syntax error: 'end' expected (to close 'if' at line 1), got the end of the file
  hint: 'else if' at line 2 opens a second 'if' that needs its own 'end': write 'elseif'
`,
	},
	{
		"s09.vxs",
		`if a then {
  x = 1
}
`,
		`s09.vxs:1:11: syntax error: unexpected '{'
    1 | if a then {
      |           ^
  hint: blocks are written with 'do', 'then' and 'end', not braces
`,
	},
	{
		"s10.vxs",
		`goto done
`,
		`s10.vxs:1:1: syntax error: goto is not supported
    1 | goto done
      | ^^^^
  hint: use 'continue' or 'break', or a flag variable
`,
	},
	{
		"s11.vxs",
		`::done::
`,
		`s11.vxs:1:1: syntax error: labels are not supported
    1 | ::done::
      | ^^
  hint: use 'continue' or 'break', or a flag variable
`,
	},
	{
		"s12.vxs",
		`local x <const> = 1
`,
		`s12.vxs:1:9: syntax error: attributes such as <const> and <close> are not supported
    1 | local x <const> = 1
      |         ^
  hint: drop the attribute: 'local x = ...'
`,
	},
	{
		"s13.vxs",
		`local s = "abc
print(s)
`,
		`s13.vxs:1:11: syntax error: unfinished string (begun on line 1)
    1 | local s = "abc
      |           ^
  hint: close the string with the quote it began with, or use [[...]] for text over several lines
`,
	},
	{
		"s14.vxs",
		`local s = [[abc

x
`,
		`s14.vxs:1:11: syntax error: unfinished long string (begun on line 1)
    1 | local s = [[abc
      |           ^^
  hint: close it with ']]' (with as many '=' as it opened with)
`,
	},
	{
		"s15.vxs",
		`local x = 3..2
`,
		`s15.vxs:1:11: syntax error: malformed number near '3..2'
    1 | local x = 3..2
      |           ^^^^
  hint: to concatenate a number, put spaces around '..': 1 .. 2
`,
	},
	{
		"s16.vxs",
		`local x = 0x1p4
`,
		`s16.vxs:1:11: syntax error: hex float literals are not supported: '0x1p4'
    1 | local x = 0x1p4
      |           ^^^^^
  hint: write the number in decimal
`,
	},
	{
		"s17.vxs",
		`local function a.b() end
`,
		`s17.vxs:1:16: syntax error: 'local function' takes a plain name, not a field or a method
    1 | local function a.b() end
      |                ^
  hint: drop 'local' to set a field: 'function a.b() ... end'
`,
	},
	{
		"s19.vxs",
		`local x = = 1
`,
		`s19.vxs:1:11: syntax error: unexpected '='
    1 | local x = = 1
      |           ^
`,
	},
	{
		"s20.vxs",
		`local s = "\q"
`,
		`s20.vxs:1:12: syntax error: invalid escape sequence '\q'
    1 | local s = "\q"
      |            ^^
  hint: to write a backslash, double it: '\\'
`,
	},
	{
		"s22.vxs",
		`local 1x = 2
`,
		`s22.vxs:1:7: syntax error: malformed number near '1x'
    1 | local 1x = 2
      |       ^^
  hint: a number is digits with an optional '.', exponent ('1e3') or '0x' prefix
`,
	},
	{
		"s24.vxs",
		`local t = {1, 2
`,
		`s24.vxs:2:1: syntax error: '}' expected (to close '{' at line 1), got the end of the file
  hint: separate a table's fields with ',' or ';'
`,
	},
	{
		"s26.vxs",
		`local _ENV = {}
`,
		`s26.vxs:1:7: syntax error: '_ENV' is not supported
    1 | local _ENV = {}
      |       ^^^^
  hint: globals are the module's environment: use them by name
`,
	},
	{
		"s27.vxs",
		`for k, v in pairs(t) end
`,
		`s27.vxs:1:22: syntax error: 'do' expected after the 'for' iterator, got 'end'
    1 | for k, v in pairs(t) end
      |                      ^^^
  hint: a for loop is written 'for k, v in pairs(t) do ... end'
`,
	},
	{
		"s29.vxs",
		`local x = 1 end
`,
		`s29.vxs:1:13: syntax error: unexpected 'end' at the top level
    1 | local x = 1 end
      |             ^^^
  hint: this 'end' closes nothing: remove it, or look for a block opened twice
`,
	},
}

@(private = "file")
RUNTIME_CASES := [?]Error_Case {
	{
		"r00.vxs",
		`local h = playr.health
`,
		`r00.vxs:1:11: runtime error: attempt to index a nil value (global 'playr')
    1 | local h = playr.health
      |           ^^^^^
  hint: no global 'playr' exists
stack traceback:
  r00.vxs:1: in main module
`,
	},
	{
		"r01.vxs",
		`local t = {}
t.missing()
`,
		`r01.vxs:2:1: runtime error: attempt to call a nil value (field 'missing')
    2 | t.missing()
      | ^
stack traceback:
  r01.vxs:2: in main module
`,
	},
	{
		"r02.vxs",
		`local x = 5
x()
`,
		`r02.vxs:2:1: runtime error: attempt to call a number value (local 'x')
    2 | x()
      | ^
stack traceback:
  r02.vxs:2: in main module
`,
	},
	{
		"r03.vxs",
		`local s = '10'
local n = s + 1
`,
		`r03.vxs:2:13: runtime error: attempt to perform arithmetic on a string value (local 's')
    2 | local n = s + 1
      |             ^
  hint: convert it with tonumber() first
stack traceback:
  r03.vxs:2: in main module
`,
	},
	{
		"r04.vxs",
		`local a = nil
local b = a.b.c
`,
		`r04.vxs:2:11: runtime error: attempt to index a nil value (local 'a')
    2 | local b = a.b.c
      |           ^
stack traceback:
  r04.vxs:2: in main module
`,
	},
	{
		"r06.vxs",
		`local x = {} < {}
`,
		`r06.vxs:1:14: runtime error: attempt to compare two table values
    1 | local x = {} < {}
      |              ^
  hint: compare values of one type: convert with tonumber() or tostring() first
stack traceback:
  r06.vxs:1: in main module
`,
	},
	{
		"r07.vxs",
		`local n = 1 < 'x'
`,
		`r07.vxs:1:13: runtime error: attempt to compare number with string
    1 | local n = 1 < 'x'
      |             ^
  hint: compare values of one type: convert with tonumber() or tostring() first
stack traceback:
  r07.vxs:1: in main module
`,
	},
	{
		"r08.vxs",
		`local z = 0
local r = 1 // z
`,
		`r08.vxs:2:13: runtime error: attempt to perform 'n//0'
    2 | local r = 1 // z
      |             ^^
  hint: check that the divisor is not zero before dividing
stack traceback:
  r08.vxs:2: in main module
`,
	},
	{
		"r09.vxs",
		`local z = 0
local r = 1 % z
`,
		`r09.vxs:2:13: runtime error: attempt to perform 'n%%0'
    2 | local r = 1 % z
      |             ^
  hint: check that the divisor is not zero before taking the remainder
stack traceback:
  r09.vxs:2: in main module
`,
	},
	{
		"r10.vxs",
		`local x = 1.5 | 2
`,
		`r10.vxs:1:15: runtime error: number has no integer representation
    1 | local x = 1.5 | 2
      |               ^
  hint: use math.floor or math.tointeger to make an integer
stack traceback:
  r10.vxs:1: in main module
`,
	},
	{
		"r11.vxs",
		`local obj = {update = function() end}
obj:updat()
`,
		`r11.vxs:2:5: runtime error: attempt to call a nil value (method 'updat')
    2 | obj:updat()
      |     ^^^^^
  hint: did you mean 'update'?
stack traceback:
  r11.vxs:2: in main module
`,
	},
	{
		"r12.vxs",
		`local cfg
local function f() return cfg.x end
f()
`,
		`r12.vxs:2:27: runtime error: attempt to index a nil value (upvalue 'cfg')
    2 | local function f() return cfg.x end
      |                           ^^^
stack traceback:
  r12.vxs:2: in function 'f'
  r12.vxs:3: in main module
`,
	},
	{
		"r13.vxs",
		`error('custom failure')
`,
		`r13.vxs:1:1: runtime error: custom failure
    1 | error('custom failure')
      | ^^^^^
stack traceback:
  r13.vxs:1: in main module
`,
	},
	{
		"r15.vxs",
		`local function lvl() error('from caller', 2) end
lvl()
`,
		`r15.vxs:2:1: runtime error: from caller
    2 | lvl()
      | ^^^
stack traceback:
  r15.vxs:1: in function 'lvl'
  r15.vxs:2: in main module
`,
	},
	{
		"r16.vxs",
		`local t = {}
t[nil] = 1
`,
		`r16.vxs:2:1: runtime error: index is nil
    2 | t[nil] = 1
      | ^
  hint: a table key cannot be nil
stack traceback:
  r16.vxs:2: in main module
`,
	},
	{
		"r17.vxs",
		`local t = setmetatable({}, {})
getmetatable(t).__index = t
local v = t.x
`,
		`r17.vxs:3:11: runtime error: '__index' chain too long; possible loop
    3 | local v = t.x
      |           ^
  hint: an __index table leads back to itself
stack traceback:
  r17.vxs:3: in main module
`,
	},
	{
		"r18.vxs",
		`rawlen(5)
`,
		`r18.vxs:1:1: runtime error: bad argument #1 to 'rawlen' (table or string expected)
    1 | rawlen(5)
      | ^^^^^^
stack traceback:
  r18.vxs:1: in main module
`,
	},
	{
		"r19.vxs",
		`for i = 1, 10, 0 do end
`,
		`r19.vxs:1:1: runtime error: 'for' step is zero
    1 | for i = 1, 10, 0 do end
      | ^^^
  hint: a numeric for needs a step other than 0
stack traceback:
  r19.vxs:1: in main module
`,
	},
	{
		"r21.vxs",
		`io.write('x')
`,
		`r21.vxs:1:1: runtime error: 'io.write' is not available in scripts: there is no file or console I/O; print writes to the script's output
    1 | io.write('x')
      | ^^
stack traceback:
  r21.vxs:1: in main module
`,
	},
	{
		"r22.vxs",
		`local s = 'x' .. {}
`,
		`r22.vxs:1:15: runtime error: attempt to concatenate a table value
    1 | local s = 'x' .. {}
      |               ^^
stack traceback:
  r22.vxs:1: in main module
`,
	},
}

@(private = "file")
error_text :: proc(name, source_text: string) -> (text: string, kind: Error_Kind) {
	// A Windows checkout has CRLF line ends; the cases are written with LF.
	source, _ := strings.replace_all(source_text, "\r\n", "\n", context.temp_allocator)
	vm, verr := vm_create(default_config(), context.temp_allocator)
	if verr.kind != .None {return verr.message, verr.kind}
	defer vm_destroy(vm)
	fn, cerr := compile(vm, source, name, allocator = context.temp_allocator)
	if cerr.kind != .None {return error_string(cerr, context.temp_allocator), cerr.kind}
	r := call(vm, fn, nil, allocator = context.temp_allocator)
	if r.status != .Error {return "", .None}
	return error_string(r.error, context.temp_allocator), r.error.kind
}

@(test)
test_syntax_errors :: proc(t: ^testing.T) {
	for c in SYNTAX_CASES {
		text, kind := error_text(c.name, c.source)
		testing.expectf(t, kind == .Syntax, "%s: %v, wanted a syntax error", c.name, kind)
		want, _ := strings.replace_all(c.want, "\r\n", "\n", context.temp_allocator)
		testing.expectf(t, text == want, "%s:\n%s\nwanted:\n%s", c.name, text, want)
	}
}

@(test)
test_runtime_errors :: proc(t: ^testing.T) {
	for c in RUNTIME_CASES {
		text, kind := error_text(c.name, c.source)
		testing.expectf(t, kind == .Runtime, "%s: %v, wanted a runtime error", c.name, kind)
		want, _ := strings.replace_all(c.want, "\r\n", "\n", context.temp_allocator)
		testing.expectf(t, text == want, "%s:\n%s\nwanted:\n%s", c.name, text, want)
	}
}
