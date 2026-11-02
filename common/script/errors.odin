package script

import "core:fmt"
import "core:slice"
import "core:strings"

// Errors: what a script did wrong, where, and a hint at the usual fix. Messages are
// Lua's where Lua has one, with the name description its getobjname gives.

Error_Kind :: enum u8 {
	None,
	Syntax,
	Runtime,
	Limit,
}

Limit_Kind :: enum u8 {
	None,
	Instructions,
	Memory,
	Call_Depth,
}

Trace_Frame :: struct {
	source: string,
	line:   u32,
	name:   string,
}

Script_Error :: struct {
	kind:      Error_Kind,
	limit:     Limit_Kind,
	message:   string,
	hint:      string,
	source:    string,
	line:      u32,
	column:    u32,
	span:      u32, // bytes the caret underlines
	text:      string, // the source line, for the caret
	traceback: []Trace_Frame,
	value:     Value,
}

// Pending_Error: an error being raised, before it is caught or ends the run.
Pending_Error :: struct {
	msg:       strings.Builder,
	hint:      strings.Builder,
	value:     Value,
	has_value: bool, // raised by error(): value is what pcall returns
	level:     int, // error(v, 2): the frame whose position it carries (1 the current)
	final:     Script_Error,
}

// error_format writes an error the way the tools print it.
error_format :: proc(e: Script_Error, b: ^strings.Builder) {
	kind := "runtime error"
	switch e.kind {
	case .Syntax:
		kind = "syntax error"
	case .Limit:
		kind = "limit exceeded"
	case .Runtime, .None:
	}
	if e.source != "" {
		fmt.sbprintf(b, "%s:%d:%d: ", e.source, e.line, e.column)
	}
	fmt.sbprintf(b, "%s: %s\n", kind, e.message)
	if e.text != "" && e.line > 0 {
		write_padded(b, int(e.line), 5)
		fmt.sbprintf(b, " | %s\n", e.text)
		strings.write_string(b, "      | ")
		for i in 0 ..< int(e.column) - 1 {
			strings.write_byte(b, '\t' if i < len(e.text) && e.text[i] == '\t' else ' ')
		}
		for _ in 0 ..< max(e.span, 1) {strings.write_byte(b, '^')}
		strings.write_byte(b, '\n')
	}
	if e.hint != "" {fmt.sbprintf(b, "  hint: %s\n", e.hint)}
	if len(e.traceback) > 0 {
		strings.write_string(b, "stack traceback:\n")
		for f in e.traceback {write_trace_frame(b, f)}
	}
}

error_string :: proc(e: Script_Error, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	error_format(e, &b)
	return strings.to_string(b)
}

// source_line: line n of text (1-based), without its end of line.
source_line :: proc(text: string, n: u32, allocator := context.allocator) -> string {
	line: u32 = 1
	start := 0
	for i := 0; i < len(text); i += 1 {
		if line == n {
			end := i
			for end < len(text) && text[end] != '\n' && text[end] != '\r' {end += 1}
			return strings.clone(text[start:end], allocator)
		}
		if text[i] == '\n' || text[i] == '\r' {
			if text[i] == '\r' && i + 1 < len(text) && text[i + 1] == '\n' {i += 1}
			line += 1
			start = i + 1
		}
	}
	if line == n {return strings.clone(text[start:], allocator)}
	return ""
}

// Raising.

// rt_error starts a runtime error with a message and an optional hint; returns false.
rt_error :: proc(vm: ^VM, message: string, hint := "") -> bool {
	strings.builder_reset(&vm.err.msg)
	strings.builder_reset(&vm.err.hint)
	strings.write_string(&vm.err.msg, message)
	strings.write_string(&vm.err.hint, hint)
	vm.err.has_value = false
	vm.err.level = 1
	return false
}

rt_errorf :: proc(vm: ^VM, hint: string, format: string, args: ..any) -> bool {
	strings.builder_reset(&vm.err.msg)
	strings.builder_reset(&vm.err.hint)
	fmt.sbprintf(&vm.err.msg, format, ..args)
	strings.write_string(&vm.err.hint, hint)
	vm.err.has_value = false
	vm.err.level = 1
	return false
}

// Name descriptions (Lua's getobjname).

@(private = "file")
sets_a :: proc(op: Op) -> bool {
	#partial switch op {
	case .SETUPVAL,
	     .SETGLOBAL,
	     .SETTABLE,
	     .SETI,
	     .SETFIELD,
	     .CLOSE,
	     .JMP,
	     .EQ,
	     .LT,
	     .LE,
	     .EQK,
	     .EQI,
	     .LTI,
	     .LEI,
	     .GTI,
	     .GEI,
	     .TEST,
	     .RETURN,
	     .RETURN0,
	     .RETURN1,
	     .TFORPREP,
	     .SETLIST,
	     .VARARGPREP,
	     .EXTRAARG:
		return false
	}
	return true
}

@(private = "file")
find_set_reg :: proc(code: []Instr, lastpc: int, reg: u32) -> int {
	setreg := -1
	jmptarget := 0
	for pc in 0 ..< lastpc {
		i := code[pc]
		op := op_of(i)
		a := arg_a(i)
		change := false
		#partial switch op {
		case .LOADNIL:
			change = a <= reg && reg <= a + arg_b(i)
		case .TFORCALL:
			change = reg >= a + 3
		case .CALL, .TAILCALL:
			change = reg >= a
		case .JMP:
			dest := pc + 1 + int(arg_sj(i))
			if dest <= lastpc && dest > jmptarget {jmptarget = dest}
		case:
			change = sets_a(op) && reg == a
		}
		if change {setreg = -1 if pc < jmptarget else pc}
	}
	return setreg
}

local_name :: proc(vm: ^VM, p: ^Proto, pc: int, reg: u32) -> string {
	locals := bytes_of(vm, p.locals, Local_Info, p.locals_len)
	for l in locals {
		if int(l.start_pc) <= pc && pc < int(l.end_pc) && l.register == reg {
			name := string_bytes(vm, Ref(l.name_const))
			if len(name) > 0 && name[0] != '(' {return name}
		}
	}
	return ""
}

@(private = "file")
const_name :: proc(vm: ^VM, p: ^Proto, k: u32) -> string {
	if k >= p.consts_len {return "?"}
	v := values_of(vm, p.consts, p.consts_len)[k]
	if v.tag == .String {return value_string(vm, v)}
	return "?"
}

upvalue_name :: proc(vm: ^VM, p: ^Proto, i: u32) -> string {
	if i >= p.upvals_len {return "?"}
	return string_bytes(vm, Ref(bytes_of(vm, p.upvals, Upval_Desc, p.upvals_len)[i].name_const))
}

// describe_reg: "local 'x'", "global 'x'", ... for what register reg held at pc, or "".
describe_reg :: proc(
	vm: ^VM,
	p: ^Proto,
	pc: int,
	reg: u32,
	allocator := context.temp_allocator,
) -> (
	what, name: string,
) {
	if n := local_name(vm, p, pc, reg); n != "" {return "local", n}
	code := bytes_of(vm, p.code, Instr, p.code_len)
	at := find_set_reg(code, pc, reg)
	if at < 0 {return "", ""}
	i := code[at]
	#partial switch op_of(i) {
	case .MOVE:
		if arg_b(i) < arg_a(i) {return describe_reg(vm, p, at, arg_b(i), allocator)}
	case .GETGLOBAL:
		return "global", const_name(vm, p, arg_bx(i))
	case .GETFIELD:
		return "field", const_name(vm, p, arg_c(i))
	case .GETTABLE:
		kw, kn := describe_reg(vm, p, at, arg_c(i), allocator)
		if kw == "constant" {return "field", kn}
		return "field", "?"
	case .GETI:
		return "field", "integer index"
	case .GETUPVAL:
		return "upvalue", upvalue_name(vm, p, arg_b(i))
	case .LOADK:
		if v := values_of(vm, p.consts, p.consts_len)[arg_bx(i)]; v.tag == .String {
			return "constant", value_string(vm, v)
		}
	case .SELF:
		if arg_k(i) != 0 {return "method", const_name(vm, p, arg_c(i))}
		return "method", "?"
	}
	return "", ""
}

// var_info: " (global 'x')" for a register, or "".
var_info :: proc(
	vm: ^VM,
	p: ^Proto,
	pc: int,
	reg: u32,
	allocator := context.temp_allocator,
) -> string {
	what, name := describe_reg(vm, p, pc, reg, allocator)
	if what == "" {return ""}
	return fmt.aprintf(" (%s '%s')", what, name, allocator = allocator)
}

// Suggestions.

edit_distance :: proc(a, b: string) -> int {
	if abs(len(a) - len(b)) > 2 {return 3}
	prev := make([]int, len(b) + 1, context.temp_allocator)
	cur := make([]int, len(b) + 1, context.temp_allocator)
	for j in 0 ..= len(b) {prev[j] = j}
	for i in 1 ..= len(a) {
		cur[0] = i
		for j in 1 ..= len(b) {
			cost := 0 if a[i - 1] == b[j - 1] else 1
			cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

// did_you_mean: the string keys of a table within edit distance 2 of name, sorted, as
// "did you mean 'a' or 'b'?", or "".
did_you_mean :: proc(
	vm: ^VM,
	t: Ref,
	name: string,
	allocator := context.temp_allocator,
) -> string {
	if t == 0 {return ""}
	found := make([dynamic]string, context.temp_allocator)
	k := NIL
	for {
		nk, v, ok := table_next(vm, t, k)
		if !ok || nk.tag == .Nil {break}
		k = nk
		if nk.tag != .String || v.tag == .Nil {continue}
		s := value_string(vm, nk)
		if s != name && edit_distance(s, name) <= 2 {append(&found, s)}
	}
	if len(found) == 0 {return ""}
	slice.sort(found[:])
	if len(found) > 3 {resize(&found, 3)}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "did you mean ")
	for s, i in found {
		if i > 0 {strings.write_string(&b, " or " if i == len(found) - 1 else ", ")}
		fmt.sbprintf(&b, "'%s'", s)
	}
	strings.write_string(&b, "?")
	return strings.to_string(b)
}

limit_message :: proc(vm: ^VM, l: Limit_Kind) -> (message, hint: string) {
	switch l {
	case .Instructions:
		return fmt.tprintf(
				"script ran too long (the run's limit is %d instructions)",
				vm.limits.run_instructions,
			),
			"a loop may never end; long work can be split across calls"
	case .Memory:
		return fmt.tprintf("not enough memory (the script's limit is %d bytes)", vm.limits.memory),
			"a table may grow without end; drop references to what is no longer needed"
	case .Call_Depth:
		return fmt.tprintf("stack overflow (the call depth limit is %d)", vm.limits.call_depth),
			"use a loop or an explicit stack table instead of deep recursion"
	case .None:
	}
	return "", ""
}

// write_padded writes n right-aligned in width columns.
write_padded :: proc(b: ^strings.Builder, n: int, width: int) {
	digits := fmt.tprintf("%d", n)
	for _ in len(digits) ..< width {strings.write_byte(b, ' ')}
	strings.write_string(b, digits)
}

write_trace_frame :: proc(b: ^strings.Builder, f: Trace_Frame) {
	if f.line == 0 && f.source == "..." {
		fmt.sbprintf(b, "  ... %s\n", f.name)
		return
	}
	fmt.sbprintf(b, "  %s:%d: in %s\n", f.source, f.line, f.name)
}

// Names a script may reach for that do not exist here, and where to look instead.
@(rodata)
ABSENT := [?]struct {
	name, reason: string,
} {
	{"io", "there is no file or console I/O; print writes to the script's output"},
	{"os", "there is no clock or system access; time comes from the world API, in ticks"},
	{"package", "code is loaded by the host, not by scripts"},
	{"require", "code is loaded by the host, not by scripts"},
	{"load", "code is loaded by the host, not by scripts"},
	{"loadstring", "code is loaded by the host, not by scripts"},
	{"loadfile", "code is loaded by the host, not by scripts"},
	{"dofile", "code is loaded by the host, not by scripts"},
	{"string.dump", "bytecode is not available to scripts"},
	{"math.random", "randomness comes from the world API"},
	{"math.randomseed", "randomness comes from the world API"},
	{"debug", "only debug.traceback is available"},
	{"setfenv", "a module's globals are its environment, set by the host"},
	{"getfenv", "a module's globals are its environment, set by the host"},
}

// absent_message: "'name' is not available in scripts: ..." when name (or the table it
// is in) is one of ABSENT, else "".
absent_message :: proc(name: string) -> string {
	root := name
	if i := strings.index_byte(name, '.'); i >= 0 {root = name[:i]}
	for a in ABSENT {
		if a.name == name || (a.name == root && strings.index_byte(a.name, '.') < 0) {
			return fmt.tprintf("'%s' is not available in scripts: %s", name, a.reason)
		}
	}
	return ""
}

// qualified_name: "g" or "g.f" for a register loaded from a global or a global's
// field at pc, else "".
qualified_name :: proc(vm: ^VM, p: ^Proto, pc: int, reg: u32) -> string {
	code := bytes_of(vm, p.code, Instr, p.code_len)
	at := find_set_reg(code, pc, reg)
	if at < 0 {return ""}
	i := code[at]
	#partial switch op_of(i) {
	case .GETGLOBAL:
		return const_name(vm, p, arg_bx(i))
	case .GETFIELD, .SELF:
		if op_of(i) == .SELF && arg_k(i) == 0 {return ""}
		if what, tname := describe_reg(vm, p, at, arg_b(i)); what == "global" {
			return fmt.tprintf("%s.%s", tname, const_name(vm, p, arg_c(i)))
		}
	}
	return ""
}

// indexed_name: "g.k" for an instruction at pc indexing global g with a constant
// string key, else "g".
indexed_name :: proc(vm: ^VM, p: ^Proto, pc: int, global: string) -> string {
	if pc < 0 || pc >= int(p.code_len) {return global}
	i := bytes_of(vm, p.code, Instr, p.code_len)[pc]
	#partial switch op_of(i) {
	case .GETFIELD:
		return fmt.tprintf("%s.%s", global, const_name(vm, p, arg_c(i)))
	case .SELF:
		if arg_k(i) != 0 {return fmt.tprintf("%s.%s", global, const_name(vm, p, arg_c(i)))}
	case .SETFIELD:
		return fmt.tprintf("%s.%s", global, const_name(vm, p, arg_b(i)))
	}
	return global
}
