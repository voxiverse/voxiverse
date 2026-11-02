package script

import "core:fmt"
import "core:strings"

// The listing: one block per function, nested functions after their parent.

disasm :: proc(vm: ^VM, fn: Value, b: ^strings.Builder) {
	if fn.tag != .Function || obj_kind(vm, as_ref(fn)) != .Closure {
		strings.write_string(b, "(not a script function)\n")
		return
	}
	disasm_proto(vm, obj(vm, as_ref(fn), Closure).proto, b)
}

@(private = "file")
plural :: proc(n: u32, word: string) -> string {
	return fmt.tprintf("%d %s%s", n, word, "" if n == 1 else "s")
}

@(private = "file")
write_const :: proc(vm: ^VM, b: ^strings.Builder, v: Value) {
	if v.tag == .String {
		strings.write_byte(b, '"')
		for c in transmute([]u8)value_string(vm, v) {
			switch c {
			case '"':
				strings.write_string(b, "\\\"")
			case '\\':
				strings.write_string(b, "\\\\")
			case '\n':
				strings.write_string(b, "\\n")
			case 0x20 ..= 0x7e:
				strings.write_byte(b, c)
			case:
				fmt.sbprintf(b, "\\x%02x", c)
			}
		}
		strings.write_byte(b, '"')
		return
	}
	value_text(vm, v, b)
}

@(private = "file")
has_test_k :: proc(op: Op) -> bool {
	#partial switch op {
	case .EQ, .LT, .LE, .EQK, .EQI, .LTI, .LEI, .GTI, .GEI, .TEST, .TESTSET:
		return true
	}
	return false
}

// jump_target: the 1-based instruction a jump at 0-based pc goes to, or 0.
@(private = "file")
jump_target :: proc(i: Instr, pc: int) -> int {
	#partial switch op_of(i) {
	case .JMP:
		return pc + 2 + int(arg_sj(i))
	case .FORLOOP, .TFORLOOP:
		return pc + 2 - int(arg_bx(i))
	case .FORPREP:
		return pc + 3 + int(arg_bx(i))
	case .TFORPREP:
		return pc + 2 + int(arg_bx(i))
	}
	return 0
}

disasm_proto :: proc(vm: ^VM, pr: Ref, b: ^strings.Builder) {
	p := obj(vm, pr, Proto)
	source := string_bytes(vm, p.source)
	name := string_bytes(vm, p.name)
	if p.line_defined == 0 {
		fmt.sbprintf(b, "module <%s>", source)
	} else {
		fmt.sbprintf(
			b,
			"function <%s:%d-%d> %s",
			source,
			p.line_defined,
			p.last_line,
			name if name != "" else "(anonymous)",
		)
	}
	fmt.sbprintf(
		b,
		" (%s; %s%s, %s, %s, %s)\n",
		plural(p.code_len, "instruction"),
		plural(u32(p.num_params), "param"),
		" + vararg" if p.is_vararg != 0 else "",
		plural(u32(p.max_stack), "register"),
		plural(p.upvals_len, "upvalue"),
		plural(p.consts_len, "constant"),
	)
	code := bytes_of(vm, p.code, Instr, p.code_len)
	lines := bytes_of(vm, p.lines, Line_Info, p.code_len)
	consts := values_of(vm, p.consts, p.consts_len)
	protos := values_of(vm, p.protos, p.protos_len)
	for ins, pc in code {
		op := op_of(ins)
		info := OP_INFO[op]
		fields := strings.builder_make(context.temp_allocator)
		comment := strings.builder_make(context.temp_allocator)
		nums := make([dynamic]i64, context.temp_allocator)
		switch info.format {
		case .ABC:
			if info.a != .None {append(&nums, i64(arg_a(ins)))}
			if info.b != .None {
				if info.b == .Imm &&
				   op !=
					   .SETI {append(&nums, i64(arg_sb(ins)))} else {append(&nums, i64(arg_b(ins)))}
			}
			if info.c != .None && !(op >= .EQI && op <= .GEI && arg_c(ins) == 0) {
				if info.c == .Imm &&
				   op !=
					   .GETI {append(&nums, i64(arg_sc(ins)))} else {append(&nums, i64(arg_c(ins)))}
			}
			if has_test_k(op) ||
			   info.c == .Reg_Or_Const && arg_k(ins) != 0 {append(&nums, i64(arg_k(ins)))}
		case .ABx:
			append(&nums, i64(arg_a(ins)))
			if info.b != .None {append(&nums, i64(arg_bx(ins)))}
		case .AsBx:
			append(&nums, i64(arg_a(ins)), i64(arg_sbx(ins)))
		case .Ax:
			append(&nums, i64(arg_ax(ins)))
		case .sJ:
			append(&nums, i64(arg_sj(ins)))
		}
		for n, i in nums {
			if i > 0 {strings.write_byte(&fields, ' ')}
			fmt.sbprintf(&fields, "%d", n)
		}
		// What the operands name.
		k_at := -1
		#partial switch op {
		case .LOADK, .GETGLOBAL, .SETGLOBAL:
			k_at = int(arg_bx(ins))
		case .LOADKX:
			if pc + 1 < len(code) {k_at = int(arg_ax(code[pc + 1]))}
		case .GETFIELD, .ADDK, .SUBK, .MULK, .MODK, .POWK, .DIVK, .IDIVK, .BANDK, .BORK, .BXORK:
			k_at = int(arg_c(ins))
		case .SETFIELD:
			k_at = int(arg_b(ins))
		case .EQK:
			k_at = int(arg_b(ins))
		case .SELF:
			if arg_k(ins) != 0 {k_at = int(arg_c(ins))}
		}
		if k_at >= 0 && k_at < len(consts) {write_const(vm, &comment, consts[k_at])}
		if (op == .SETFIELD || op == .SETTABLE || op == .SETI) &&
		   arg_k(ins) != 0 &&
		   int(arg_c(ins)) < len(consts) {
			if strings.builder_len(comment) > 0 {strings.write_byte(&comment, ' ')}
			write_const(vm, &comment, consts[arg_c(ins)])
		}
		if op == .GETUPVAL ||
		   op == .SETUPVAL {strings.write_string(&comment, upvalue_name(vm, p, arg_b(ins)))}
		if op == .CLOSURE && int(arg_bx(ins)) < len(protos) {
			np := obj(vm, as_ref(protos[arg_bx(ins)]), Proto)
			fmt.sbprintf(&comment, "function <%s:%d>", source, np.line_defined)
		}
		if t := jump_target(ins, pc); t != 0 {fmt.sbprintf(&comment, "to %d", t)}
		write_padded(b, pc + 1, 6)
		fmt.sbprintf(
			b,
			"  %-9s %-12s %-10s",
			fmt.tprintf("[%d:%d]", lines[pc].line, lines[pc].col),
			op_name(op),
			strings.to_string(fields),
		)
		if strings.builder_len(comment) > 0 {fmt.sbprintf(b, " ; %s", strings.to_string(comment))}
		trim_trailing_spaces(b)
		strings.write_byte(b, '\n')
	}
	fmt.sbprintf(b, "constants (%d):", p.consts_len)
	for v, i in consts {
		fmt.sbprintf(b, " %d ", i)
		write_const(vm, b, v)
	}
	strings.write_byte(b, '\n')
	locals := bytes_of(vm, p.locals, Local_Info, p.locals_len)
	fmt.sbprintf(b, "locals (%d):", p.locals_len)
	for l, i in locals {
		fmt.sbprintf(
			b,
			" %d %s %d-%d",
			i,
			string_bytes(vm, Ref(l.name_const)),
			l.start_pc + 1,
			l.end_pc,
		)
	}
	strings.write_byte(b, '\n')
	ups := bytes_of(vm, p.upvals, Upval_Desc, p.upvals_len)
	fmt.sbprintf(b, "upvalues (%d):", p.upvals_len)
	for u, i in ups {
		place := "in stack, register" if u.instack != 0 else "upvalue"
		fmt.sbprintf(b, " %d %s (%s %d)", i, string_bytes(vm, Ref(u.name_const)), place, u.index)
	}
	strings.write_byte(b, '\n')
	for v in protos {
		strings.write_byte(b, '\n')
		disasm_proto(vm, as_ref(v), b)
	}
}

@(private = "file")
trim_trailing_spaces :: proc(b: ^strings.Builder) {
	for len(b.buf) > 0 && b.buf[len(b.buf) - 1] == ' ' {pop(&b.buf)}
}

op_name :: proc(op: Op) -> string {
	return fmt.tprintf("%v", op)
}
