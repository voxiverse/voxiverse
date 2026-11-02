package script

import "core:fmt"

// The bytecode verifier (M51c). verify_proto checks one proto's code against what the
// dispatch loop assumes, so a proto that passes runs without reading outside its frame,
// its constants, its upvalues or its code: registers below max_stack (with the ranges an
// instruction touches), constant and proto indices in range and of the right type,
// upvalue indices below the proto's count, jump targets inside the code, EXTRAARG after
// the instructions that read one, an open count (B = 0) only straight after the call or
// vararg that set it, a test followed by its jump, and a return at the end. Run after
// every compile in tests (and when Config.verify is set) and on every proto a snapshot
// restores.

// verify_tree verifies a module's proto and every proto nested in it.
verify_tree :: proc(vm: ^VM, pr: Ref, depth := 0) -> (ok: bool, problem: string) {
	if depth > 200 {return false, "protos nested too deep"}
	if good, why := verify_proto(vm, pr); !good {return false, why}
	p := obj(vm, pr, Proto)
	for v in values_of(vm, p.protos, p.protos_len) {
		if good, why := verify_tree(vm, as_ref(v), depth + 1); !good {return false, why}
	}
	return true, ""
}

// ref_is: r is inside the heap, aligned, and its header says kind. (The snapshot's
// validation also checks that r is an object start.)
@(private = "file")
ref_is :: proc(vm: ^VM, r: Ref, kind: Obj_Kind) -> bool {
	if u32(r) < HEAP_START || u32(r) % 16 != 0 || u64(r) + 16 > u64(vm.top) {return false}
	return (^Header)(&vm.mem[r]).kind == kind
}

verify_proto :: proc(vm: ^VM, pr: Ref) -> (ok: bool, problem: string) {
	if !ref_is(vm, pr, .Proto) {return false, "not a proto"}
	p := obj(vm, pr, Proto)
	bad :: proc(p: ^Proto, pc: int, format: string, args: ..any) -> (bool, string) {
		return false, fmt.tprintf(
			"instruction %d of the function at line %d: %s",
			pc + 1,
			p.line_defined,
			fmt.tprintf(format, ..args),
		)
	}
	n := int(p.code_len)
	if n == 0 {return false, "a function with no code"}
	if p.code == 0 || !ref_is(vm, p.code, .Bytes) {return false, "the code is not a buffer"}
	if BUF_DATA + n * 4 > int((^Header)(&vm.mem[p.code]).size) {
		return false, "the code is longer than its buffer"
	}
	if p.consts_len > 0 && !ref_is(vm, p.consts, .Values) {
		return false, "the constants are not a buffer"
	}
	if p.protos_len > 0 && !ref_is(vm, p.protos, .Values) {
		return false, "the nested functions are not a buffer"
	}
	if p.upvals_len > 0 && !ref_is(vm, p.upvals, .Bytes) {
		return false, "the upvalues are not a buffer"
	}
	if p.locals_len > 0 && !ref_is(vm, p.locals, .Bytes) {
		return false, "the locals are not a buffer"
	}
	if p.consts_len > 0 &&
	   BUF_DATA + int(p.consts_len) * size_of(Value) > int((^Header)(&vm.mem[p.consts]).size) {
		return false, "more constants than their buffer holds"
	}
	if p.protos_len > 0 &&
	   BUF_DATA + int(p.protos_len) * size_of(Value) > int((^Header)(&vm.mem[p.protos]).size) {
		return false, "more nested functions than their buffer holds"
	}
	if p.upvals_len > 0 &&
	   BUF_DATA + int(p.upvals_len) * size_of(Upval_Desc) >
		   int((^Header)(&vm.mem[p.upvals]).size) {
		return false, "more upvalues than their buffer holds"
	}
	if p.locals_len > 0 &&
	   BUF_DATA + int(p.locals_len) * size_of(Local_Info) >
		   int((^Header)(&vm.mem[p.locals]).size) {
		return false, "more locals than their buffer holds"
	}
	if p.lines == 0 ||
	   !ref_is(vm, p.lines, .Bytes) ||
	   BUF_DATA + n * size_of(Line_Info) > int((^Header)(&vm.mem[p.lines]).size) {
		return false, "the line table does not cover the code"
	}
	if p.upvals_len > 255 {return false, "more than 255 upvalues"}
	if u32(p.num_params) > u32(p.max_stack) {return false, "more parameters than registers"}
	if p.is_vararg > 1 {return false, "a bad vararg flag"}
	code := bytes_of(vm, p.code, Instr, p.code_len)
	k := values_of(vm, p.consts, p.consts_len)
	ms := u32(p.max_stack)
	nk := p.consts_len
	nup := p.upvals_len
	for c in k {
		switch c.tag {
		case .Nil, .Bool, .Int, .Float:
			if c.kind != 0 ||
			   c._pad0 != 0 ||
			   c._pad1 != 0 {return false, "a constant with padding"}
		case .String:
			if !ref_is(vm, as_ref(c), .String) {return false, "a string constant is not a string"}
		case .Handle, .Table, .Function, .Thread:
			return false, "a constant of a type constants never have"
		case:
			return false, "a constant with a bad tag"
		}
	}
	for v in values_of(vm, p.protos, p.protos_len) {
		if v.tag != .Function || !ref_is(vm, as_ref(v), .Proto) {
			return false, "a nested function that is not a proto"
		}
	}
	for u in bytes_of(vm, p.upvals, Upval_Desc, p.upvals_len) {
		if u.name_const != 0 && !ref_is(vm, Ref(u.name_const), .String) {
			return false, "an upvalue's name is not a string"
		}
	}
	for l in bytes_of(vm, p.locals, Local_Info, p.locals_len) {
		if !ref_is(vm, Ref(l.name_const), .String) {return false, "a local's name is not a string"}
	}
	for r in ([?]Ref{p.source, p.name, p.text}) {
		if r != 0 && !ref_is(vm, r, .String) {return false, "a name that is not a string"}
	}

	// The jump targets first: an open count may not be one.
	target := make([]bool, n + 1, context.temp_allocator)
	jump :: proc(target: []bool, n, to: int) -> bool {
		if to < 0 || to >= n {return false}
		target[to] = true
		return true
	}
	for i, pc in code {
		op := u32(i & 0x7f)
		if op > u32(Op.EXTRAARG) {return bad(p, pc, "opcode %d is not an instruction", op)}
		#partial switch Op(op) {
		case .JMP:
			if !jump(
				target,
				n,
				pc + 1 + int(arg_sj(i)),
			) {return bad(p, pc, "a jump outside the code")}
		case .FORLOOP, .TFORLOOP:
			if !jump(
				target,
				n,
				pc + 1 - int(arg_bx(i)),
			) {return bad(p, pc, "a loop jump outside the code")}
		case .FORPREP:
			if !jump(
				target,
				n,
				pc + 2 + int(arg_bx(i)),
			) {return bad(p, pc, "a loop exit outside the code")}
		case .TFORPREP:
			if !jump(
				target,
				n,
				pc + 1 + int(arg_bx(i)),
			) {return bad(p, pc, "a loop jump outside the code")}
		case .LFALSESKIP:
			if !jump(target, n, pc + 2) {return bad(p, pc, "a skip past the end")}
		case .EQ, .LT, .LE, .EQK, .EQI, .LTI, .LEI, .GTI, .GEI, .TEST, .TESTSET:
			if !jump(target, n, pc + 2) {return bad(p, pc, "a test at the end")}
		}
	}
	reg :: proc(r, ms: u32) -> bool {return r < ms}
	span :: proc(first, count, ms: u32) -> bool {return first + count <= ms}
	is_string :: proc(k: []Value, i: u32) -> bool {return int(i) < len(k) && k[i].tag == .String}
	is_number :: proc(k: []Value, i: u32) -> bool {
		return int(i) < len(k) && (k[i].tag == .Int || k[i].tag == .Float)
	}
	rk :: proc(i: Instr, k: []Value, ms: u32) -> bool {
		if arg_k(i) != 0 {return int(arg_c(i)) < len(k)}
		return arg_c(i) < ms
	}
	// open: the instruction before pc set the stack's top for a count of 0 at register
	// a + above, and pc is not a jump target.
	open :: proc(code: []Instr, target: []bool, pc: int, a, above: u32) -> bool {
		if pc == 0 || target[pc] {return false}
		prev := code[pc - 1]
		#partial switch op_of(prev) {
		case .CALL, .VARARG:
			return arg_c(prev) == 0 && arg_a(prev) >= a + above
		case .TAILCALL:
			return arg_a(prev) >= a + above
		}
		return false
	}
	extra :: proc(code: []Instr, pc: int) -> bool {
		return pc + 1 < len(code) && op_of(code[pc + 1]) == .EXTRAARG
	}
	for i, pc in code {
		op := op_of(i)
		a, b, c := arg_a(i), arg_b(i), arg_c(i)
		good := true
		why := "a register out of range"
		switch op {
		case .MOVE, .UNM, .BNOT, .NOT, .LEN, .ADDI, .SHRI, .SHLI, .GETI, .EQ, .LT, .LE, .TESTSET:
			good = reg(a, ms) && reg(b, ms)
		case .LOADI,
		     .LOADF,
		     .LOADFALSE,
		     .LFALSESKIP,
		     .LOADTRUE,
		     .CLOSE,
		     .RETURN1,
		     .EQI,
		     .LTI,
		     .LEI,
		     .GTI,
		     .GEI,
		     .TEST:
			good = reg(a, ms)
		case .LOADK:
			good = reg(a, ms)
			if good && arg_bx(i) >= nk {good, why = false, "a constant out of range"}
		case .LOADKX:
			good = reg(a, ms)
			if good {
				if !extra(code, pc) {
					good, why = false, "LOADKX without EXTRAARG"
				} else if arg_ax(code[pc + 1]) >= nk {
					good, why = false, "a constant out of range"
				}
			}
		case .LOADNIL:
			good = span(a, b + 1, ms)
		case .GETUPVAL, .SETUPVAL:
			good = reg(a, ms)
			if good && b >= nup {good, why = false, "an upvalue out of range"}
		case .GETGLOBAL, .SETGLOBAL:
			good = reg(a, ms)
			if good &&
			   !is_string(
					   k,
					   arg_bx(i),
				   ) {good, why = false, "a global's name is not a string constant"}
		case .GETTABLE, .ADD, .SUB, .MUL, .MOD, .POW, .DIV, .IDIV, .BAND, .BOR, .BXOR, .SHL, .SHR:
			good = reg(a, ms) && reg(b, ms) && reg(c, ms)
		case .GETFIELD:
			good = reg(a, ms) && reg(b, ms)
			if good &&
			   !is_string(k, c) {good, why = false, "a field name is not a string constant"}
		case .SETTABLE:
			good = reg(a, ms) && reg(b, ms) && rk(i, k, ms)
		case .SETI:
			good = reg(a, ms) && rk(i, k, ms)
		case .SETFIELD:
			good = reg(a, ms) && rk(i, k, ms)
			if good &&
			   !is_string(k, b) {good, why = false, "a field name is not a string constant"}
		case .NEWTABLE:
			good = reg(a, ms)
			if good && !extra(code, pc) {good, why = false, "NEWTABLE without EXTRAARG"}
			if good && b > 27 {good, why = false, "a hash size out of range"}
		case .SELF:
			good = span(a, 2, ms) && reg(b, ms) && rk(i, k, ms)
			if good && arg_k(i) != 0 && !is_string(k, c) {
				good, why = false, "a method name is not a string constant"
			}
		case .ADDK, .SUBK, .MULK, .MODK, .POWK, .DIVK, .IDIVK, .BANDK, .BORK, .BXORK:
			good = reg(a, ms) && reg(b, ms)
			if good &&
			   !is_number(k, c) {good, why = false, "an arithmetic constant is not a number"}
		case .CONCAT:
			good = b >= 1 && span(a, b, ms)
		case .JMP:
		case .EQK:
			good = reg(a, ms)
			if good && b >= nk {good, why = false, "a constant out of range"}
		case .CALL:
			good = reg(a, ms)
			if good && b > 0 && !span(a, b, ms) {good = false}
			if good && c > 1 && !span(a, c - 1, ms) {good = false}
			if good && b == 0 && !open(code, target, pc, a, 1) {
				good, why = false, "an open argument count not set by the instruction before"
			}
		case .TAILCALL:
			good = reg(a, ms)
			if good && b > 0 && !span(a, b, ms) {good = false}
			if good && b == 0 && !open(code, target, pc, a, 1) {
				good, why = false, "an open argument count not set by the instruction before"
			}
		case .RETURN:
			good = b == 0 || span(a, b - 1, ms)
			if good && b == 0 && !open(code, target, pc, a, 0) {
				good, why = false, "an open result count not set by the instruction before"
			}
		case .RETURN0:
		case .FORLOOP, .FORPREP:
			good = span(a, 4, ms)
		case .TFORPREP:
			good = span(a, 4, ms)
		case .TFORCALL:
			good = span(a, 6, ms) && span(a + 3, c, ms)
			if good && (pc + 1 >= n || op_of(code[pc + 1]) != .TFORLOOP) {
				good, why = false, "TFORCALL not followed by TFORLOOP"
			}
		case .TFORLOOP:
			good = span(a, 4, ms)
		case .SETLIST:
			good = reg(a, ms) && (b == 0 || span(a, b + 1, ms))
			if good && b == 0 && !open(code, target, pc, a, 1) {
				good, why = false, "an open count not set by the instruction before"
			}
			if good &&
			   arg_k(i) != 0 &&
			   !extra(code, pc) {good, why = false, "SETLIST without EXTRAARG"}
		case .CLOSURE:
			good = reg(a, ms)
			if good && arg_bx(i) >= p.protos_len {
				good, why = false, "a nested function out of range"
			} else if good {
				child := obj(vm, as_ref(values_of(vm, p.protos, p.protos_len)[arg_bx(i)]), Proto)
				if child.upvals_len > 255 ||
				   (child.upvals_len > 0 && !ref_is(vm, child.upvals, .Bytes)) ||
				   BUF_DATA + int(child.upvals_len) * size_of(Upval_Desc) >
					   int(
						   (^Header)(&vm.mem[child.upvals if child.upvals_len > 0 else p.code]).size,
					   ) {
					good, why = false, "a nested function's upvalues are not a buffer"
				} else {
					for d in bytes_of(vm, child.upvals, Upval_Desc, child.upvals_len) {
						if d.instack > 1 ||
						   (d.instack != 0 && u32(d.index) >= ms) ||
						   (d.instack == 0 && u32(d.index) >= nup) {
							good, why = false, "a nested function captures out of range"
							break
						}
					}
				}
			}
		case .VARARG:
			good = reg(a, ms) && (c <= 1 || span(a, c - 1, ms))
		case .VARARGPREP:
		case .EXTRAARG:
			if pc == 0 {
				good, why = false, "EXTRAARG with nothing before it"
			} else {
				prev := code[pc - 1]
				#partial switch op_of(prev) {
				case .LOADKX, .NEWTABLE:
				case .SETLIST:
					if arg_k(prev) == 0 {good = false}
				case:
					good = false
				}
				if !good {why = "EXTRAARG after an instruction that takes none"}
				if target[pc] {good, why = false, "a jump to an EXTRAARG"}
			}
		}
		if !good {return bad(p, pc, "%v: %s", op, why)}
		#partial switch op {
		case .EQ, .LT, .LE, .EQK, .EQI, .LTI, .LEI, .GTI, .GEI, .TEST, .TESTSET:
			if op_of(code[pc + 1]) !=
			   .JMP {return bad(p, pc, "%v: a test not followed by a jump", op)}
		}
	}
	#partial switch op_of(code[n - 1]) {
	case .RETURN, .RETURN0, .RETURN1:
	case:
		return false, fmt.tprintf(
			"the function at line %d does not end with a return",
			p.line_defined,
		)
	}
	return true, ""
}
