package script

import "core:strings"
import "core:testing"

// verify_proto: every proto the conformance suite compiles passes; hand-broken ones
// are refused, each with its reason.

@(test)
test_verify_conformance :: proc(t: ^testing.T) {
	count := 0
	for f in CONFORMANCE_FILES {
		vm, e := vm_create(default_config(), context.temp_allocator)
		if !testing.expect(t, e.kind == .None) {return}
		fn, ce := compile(vm, string(f.data), f.name, allocator = context.temp_allocator)
		if ce.kind == .None {
			ok, problem := verify_tree(vm, obj(vm, as_ref(fn), Closure).proto)
			testing.expectf(t, ok, "%s: %s", f.name, problem)
			count += 1
		}
		vm_destroy(vm)
		free_all(context.temp_allocator)
	}
	testing.expectf(t, count >= 150, "only %d conformance files compile", count)
}

@(private = "file")
VERIFY_SOURCE :: `local up = 1
local function f(a, b)
  local t = {x = 1}
  local s = "str"
  if a < b then up = up + a end
  print(s, a * 1.5)
  return t.x + a
end
return f`

@(private = "file")
find_op :: proc(code: []Instr, op: Op) -> int {
	for i, pc in code {
		if op_of(i) == op {return pc}
	}
	return -1
}

@(test)
test_verify_refuses :: proc(t: ^testing.T) {
	Break :: struct {
		what:  string,
		main:  bool, // in the module's proto, not f's
		apply: proc(code: []Instr) -> bool,
		want:  string,
	}
	breaks := [?]Break {
		{"register out of range", false, proc(code: []Instr) -> bool {
				pc := find_op(code, .MOVE)
				if pc < 0 {pc = find_op(code, .GETFIELD)}
				if pc < 0 {return false}
				set_arg_a(&code[pc], 250)
				return true
			}, "a register out of range"},
		{"jump outside", false, proc(code: []Instr) -> bool {
				pc := find_op(code, .JMP)
				if pc < 0 {return false}
				set_arg_sj(&code[pc], 5000)
				return true
			}, "a jump outside the code"},
		{
			"field name of a wrong type",
			false,
			proc(code: []Instr) -> bool {
				pc := find_op(code, .GETFIELD)
				mk := find_op(code, .MULK)
				if pc < 0 || mk < 0 {return false}
				set_arg_c(&code[pc], arg_c(code[mk])) // the number 1.5
				return true
			},
			"a field name is not a string constant",
		},
		{
			"arithmetic constant of a wrong type",
			false,
			proc(code: []Instr) -> bool {
				mk := find_op(code, .MULK)
				gf := find_op(code, .GETFIELD)
				if gf < 0 || mk < 0 {return false}
				set_arg_c(&code[mk], arg_c(code[gf])) // the string "x"
				return true
			},
			"an arithmetic constant is not a number",
		},
		{"missing EXTRAARG", false, proc(code: []Instr) -> bool {
				pc := find_op(code, .NEWTABLE)
				if pc < 0 {return false}
				code[pc + 1] = make_abc(.MOVE, 0, 0, 0)
				return true
			}, "NEWTABLE without EXTRAARG"},
		{"no final return", false, proc(code: []Instr) -> bool {
				code[len(code) - 1] = make_abc(.MOVE, 0, 0, 0)
				return true
			}, "does not end with a return"},
		{"upvalue out of range", false, proc(code: []Instr) -> bool {
				pc := find_op(code, .GETUPVAL)
				if pc < 0 {return false}
				set_arg_b(&code[pc], 9)
				return true
			}, "an upvalue out of range"},
		{"constant out of range", false, proc(code: []Instr) -> bool {
				pc := find_op(code, .LOADK)
				if pc < 0 {return false}
				set_arg_bx(&code[pc], 1000)
				return true
			}, "a constant out of range"},
		{"not an instruction", false, proc(code: []Instr) -> bool {
				code[0] = (code[0] &~ 0x7f) | 0x7f
				return true
			}, "is not an instruction"},
		{"test without its jump", false, proc(code: []Instr) -> bool {
				pc := find_op(code, .LT)
				if pc < 0 {return false}
				code[pc + 1] = make_abc(.MOVE, 0, 0, 0)
				return true
			}, "a test not followed by a jump"},
		{"nested function out of range", true, proc(code: []Instr) -> bool {
				pc := find_op(code, .CLOSURE)
				if pc < 0 {return false}
				set_arg_bx(&code[pc], 50)
				return true
			}, "a nested function out of range"},
		{"open count not set", false, proc(code: []Instr) -> bool {
				pc := find_op(code, .CALL)
				if pc < 0 {return false}
				set_arg_b(&code[pc], 0)
				return true
			}, "an open argument count not set by the instruction before"},
	}
	for br in breaks {
		vm, e := vm_create(default_config(), context.temp_allocator)
		if !testing.expect(t, e.kind == .None) {return}
		defer vm_destroy(vm)
		fn, ce := compile(vm, VERIFY_SOURCE, "verify", allocator = context.temp_allocator)
		if !testing.expectf(t, ce.kind == .None, "compile: %s", ce.message) {return}
		main := obj(vm, as_ref(fn), Closure).proto
		pr := main
		if !br.main {pr = as_ref(values_of(vm, obj(vm, main, Proto).protos, 1)[0])}
		p := obj(vm, pr, Proto)
		if ok, problem := verify_proto(vm, pr);
		   !testing.expectf(t, ok, "before %s: %s", br.what, problem) {
			continue
		}
		code := bytes_of(vm, p.code, Instr, p.code_len)
		if !testing.expectf(t, br.apply(code), "%s: no instruction to break", br.what) {continue}
		ok, problem := verify_proto(vm, pr)
		testing.expectf(t, !ok, "%s: verify_proto accepted it", br.what)
		testing.expectf(
			t,
			strings.contains(problem, br.want),
			"%s: refused with %q, wanted %q",
			br.what,
			problem,
			br.want,
		)
	}
}
