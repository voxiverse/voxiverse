package script

// Code generation for expressions: Lua 5.4's lcode.c, ported (no MMBIN, globals through
// GETGLOBAL and SETGLOBAL). An Exp describes a value not yet placed; jump lists (t, f)
// chain the JMPs of a condition through their sJ fields.

NO_JUMP :: -1
MAX_REGS :: 255
MAX_LOCALS :: 200
MAX_UPVALUES :: 255
MAX_CONSTS :: 1 << 25
LFIELDS_PER_FLUSH :: 50
MAXINDEXRK :: MAXARG_B

Exp_Kind :: enum u8 {
	Void,
	Nil,
	True,
	False,
	K, // info: constant index
	Int,
	Float,
	Str,
	Nonreloc, // info: register
	Local, // info: register
	Upval, // info: upvalue index
	Global, // info: constant index of the name
	Indexed, // t: table register, key: key register
	Indexed_Int, // key: integer
	Indexed_Str, // key: constant index of a string
	Call, // info: pc
	Vararg, // info: pc
	Jmp, // info: pc of the comparison's jump
	Reloc, // info: pc of an instruction whose A is to be set
}

Exp :: struct {
	kind: Exp_Kind,
	info: i32,
	t:    i32, // an indexed expression's table register
	key:  i32,
	ival: i64,
	fval: f64,
	str:  string,
	tj:   i32, // exit when true
	fj:   i32, // exit when false
	// Where a variable or index was written: its load or store carries this position.
	line: u32,
	col:  u32,
	span: u32,
}

Saved_Pos :: struct {
	line, col, span: u32,
}

// use_pos makes e's position the current one; restore_pos puts the old one back.
use_pos :: proc(c: ^Compiler, e: ^Exp) -> Saved_Pos {
	saved := Saved_Pos{c.line, c.col, c.span}
	if e.line != 0 {
		c.line = e.line
		c.col = e.col
		c.span = e.span
	}
	return saved
}

restore_pos :: proc(c: ^Compiler, s: Saved_Pos) {
	c.line = s.line
	c.col = s.col
	c.span = s.span
}

// mark_pos records the current position in e.
mark_pos :: proc(c: ^Compiler, e: ^Exp) {
	e.line = c.line
	e.col = c.col
	e.span = c.span
}

exp_init :: proc(kind: Exp_Kind, info: i32 = 0) -> Exp {
	return Exp{kind = kind, info = info, tj = NO_JUMP, fj = NO_JUMP}
}

@(private = "file")
has_jumps :: #force_inline proc(e: ^Exp) -> bool {return e.tj != e.fj}

has_multret :: #force_inline proc(k: Exp_Kind) -> bool {return k == .Call || k == .Vararg}

// Emitting.

emit :: proc(c: ^Compiler, i: Instr) -> i32 {
	fs := c.fs
	append(&fs.code, i)
	append(
		&fs.lines,
		Line_Info{line = c.line, col = u16(min(c.col, 0xffff)), span = u16(min(c.span, 0xffff))},
	)
	return i32(len(fs.code) - 1)
}

emit_abc :: proc(c: ^Compiler, op: Op, a, b, cc: i32, k: i32 = 0) -> i32 {
	return emit(c, make_abc(op, u32(a), u32(b), u32(cc), u32(k)))
}

emit_abx :: proc(c: ^Compiler, op: Op, a: i32, bx: u32) -> i32 {
	return emit(c, make_abx(op, u32(a), bx))
}

@(private = "file")
emit_k :: proc(c: ^Compiler, reg: i32, k: i32) -> i32 {
	if k <= MAXARG_BX {return emit_abx(c, .LOADK, reg, u32(k))}
	p := emit_abx(c, .LOADKX, reg, 0)
	emit(c, make_ax(.EXTRAARG, u32(k)))
	return p
}

pc_of :: #force_inline proc(c: ^Compiler) -> i32 {return i32(len(c.fs.code))}

get_label :: proc(c: ^Compiler) -> i32 {
	c.fs.last_target = pc_of(c)
	return pc_of(c)
}

jump :: proc(c: ^Compiler) -> i32 {
	return emit(c, make_sj(.JMP, NO_JUMP))
}

@(private = "file")
get_jump :: proc(c: ^Compiler, pc: i32) -> i32 {
	off := arg_sj(c.fs.code[pc])
	if off == NO_JUMP {return NO_JUMP}
	return pc + 1 + off
}

@(private = "file")
fix_jump :: proc(c: ^Compiler, pc, dest: i32) {
	off := dest - (pc + 1)
	if off < -OFFSET_SJ || off > OFFSET_SJ {
		compile_error(
			c,
			"control structure too long (a jump beyond 2^24 instructions)",
			"split the function into smaller ones",
		)
		return
	}
	set_arg_sj(&c.fs.code[pc], off)
}

concat_jumps :: proc(c: ^Compiler, l1: ^i32, l2: i32) {
	if l2 == NO_JUMP {return}
	if l1^ == NO_JUMP {
		l1^ = l2
		return
	}
	list := l1^
	for {
		next := get_jump(c, list)
		if next == NO_JUMP {break}
		list = next
	}
	fix_jump(c, list, l2)
}

@(private = "file")
is_test_op :: proc(op: Op) -> bool {
	#partial switch op {
	case .EQ, .LT, .LE, .EQK, .EQI, .LTI, .LEI, .GTI, .GEI, .TEST, .TESTSET:
		return true
	}
	return false
}

@(private = "file")
jump_control :: proc(c: ^Compiler, pc: i32) -> ^Instr {
	if pc >= 1 && is_test_op(op_of(c.fs.code[pc - 1])) {return &c.fs.code[pc - 1]}
	return &c.fs.code[pc]
}

@(private = "file")
patch_test_reg :: proc(c: ^Compiler, node: i32, reg: i32) -> bool {
	i := jump_control(c, node)
	if op_of(i^) != .TESTSET {return false}
	if reg != NO_REG && reg != i32(arg_b(i^)) {
		set_arg_a(i, u32(reg))
	} else {
		i^ = make_abc(.TEST, arg_b(i^), 0, 0, arg_k(i^))
	}
	return true
}

@(private = "file")
remove_values :: proc(c: ^Compiler, list: i32) {
	for l := list; l != NO_JUMP; l = get_jump(c, l) {patch_test_reg(c, l, NO_REG)}
}

@(private = "file")
patch_list_aux :: proc(c: ^Compiler, list, vtarget, reg, dtarget: i32) {
	l := list
	for l != NO_JUMP {
		next := get_jump(c, l)
		if patch_test_reg(c, l, reg) {
			fix_jump(c, l, vtarget)
		} else {
			fix_jump(c, l, dtarget)
		}
		l = next
	}
}

patch_list :: proc(c: ^Compiler, list, target: i32) {
	patch_list_aux(c, list, target, NO_REG, target)
}

patch_to_here :: proc(c: ^Compiler, list: i32) {
	patch_list(c, list, get_label(c))
}

// Registers.

nvarstack :: proc(c: ^Compiler) -> i32 {
	fs := c.fs
	if fs.nactvar == 0 {return 0}
	return c.actvars[fs.first_local + fs.nactvar - 1].reg + 1
}

check_stack :: proc(c: ^Compiler, n: i32) {
	fs := c.fs
	need := fs.free_reg + n
	if need > fs.max_stack {
		if need > MAX_REGS {
			compile_error(
				c,
				"function or expression needs too many registers (the limit is 255)",
				"split the expression, or move locals into a table",
			)
			return
		}
		fs.max_stack = need
	}
}

reserve_regs :: proc(c: ^Compiler, n: i32) {
	check_stack(c, n)
	c.fs.free_reg += n
}

@(private = "file")
free_reg :: proc(c: ^Compiler, reg: i32) {
	if reg >= nvarstack(c) {
		c.fs.free_reg -= 1
	}
}

@(private = "file")
free_regs :: proc(c: ^Compiler, r1, r2: i32) {
	if r1 > r2 {
		free_reg(c, r1)
		free_reg(c, r2)
	} else {
		free_reg(c, r2)
		free_reg(c, r1)
	}
}

free_exp :: proc(c: ^Compiler, e: ^Exp) {
	if e.kind == .Nonreloc {free_reg(c, e.info)}
}

@(private = "file")
free_exps :: proc(c: ^Compiler, e1, e2: ^Exp) {
	r1 := e1.info if e1.kind == .Nonreloc else -1
	r2 := e2.info if e2.kind == .Nonreloc else -1
	if r1 >= 0 && r2 >= 0 {
		free_regs(c, r1, r2)
	} else if r1 >= 0 {
		free_reg(c, r1)
	} else if r2 >= 0 {
		free_reg(c, r2)
	}
}

// Constants.

const_index :: proc(c: ^Compiler, k: Const) -> i32 {
	fs := c.fs
	h := const_hash(k)
	if len(fs.kindex) > 0 {
		mask := u32(len(fs.kindex) - 1)
		i := h & mask
		for {
			e := fs.kindex[i]
			if e == 0 {break}
			if const_same(fs.consts[e - 1], k) {return e - 1}
			i = (i + 1) & mask
		}
	}
	if len(fs.consts) >= MAX_CONSTS {
		compile_error(
			c,
			"too many constants in one function (the limit is 2^25)",
			"split the function, or load the data from a table",
		)
		return 0
	}
	append(&fs.consts, k)
	n := i32(len(fs.consts))
	if len(fs.kindex) < len(fs.consts) * 2 {
		size := max(64, len(fs.kindex) * 2)
		delete(fs.kindex)
		fs.kindex = make([]i32, size)
		for kc, j in fs.consts {const_put(fs.kindex, const_hash(kc), i32(j + 1))}
	} else {
		const_put(fs.kindex, h, n)
	}
	return n - 1
}

@(private = "file")
const_put :: proc(index: []i32, h: u32, e: i32) {
	mask := u32(len(index) - 1)
	i := h & mask
	for index[i] != 0 {i = (i + 1) & mask}
	index[i] = e
}

@(private = "file")
const_hash :: proc(k: Const) -> u32 {
	if k.tag == .String {return string_hash(0, k.s)}
	return u32(splitmix_finish(k.bits ~ u64(k.tag) << 56))
}

@(private = "file")
const_same :: proc(a, b: Const) -> bool {
	return a.tag == b.tag && a.bits == b.bits && a.s == b.s
}

string_k :: proc(c: ^Compiler, s: string) -> i32 {return const_index(
		c,
		Const{tag = .String, s = s},
	)}
@(private = "file")
int_k :: proc(c: ^Compiler, i: i64) -> i32 {return const_index(
		c,
		Const{tag = .Int, bits = cast(u64)i},
	)}
@(private = "file")
float_k :: proc(c: ^Compiler, f: f64) -> i32 {return const_index(
		c,
		Const{tag = .Float, bits = transmute(u64)f},
	)}

@(private = "file")
fits_bx :: #force_inline proc(i: i64) -> bool {return(
		-OFFSET_SBX <= i &&
		i <= MAXARG_BX - OFFSET_SBX \
	)}
@(private = "file")
fits_c :: #force_inline proc(i: i64) -> bool {return -OFFSET_SC <= i && i <= MAXARG_C - OFFSET_SC}

load_int :: proc(c: ^Compiler, reg: i32, i: i64) {
	if fits_bx(i) {
		emit(c, make_asbx(.LOADI, u32(reg), i32(i)))
	} else {
		emit_k(c, reg, int_k(c, i))
	}
}

@(private = "file")
load_float :: proc(c: ^Compiler, reg: i32, f: f64) {
	if i, ok := float_to_int_exact(f);
	   ok && fits_bx(i) && !(f == 0 && transmute(u64)f >> 63 != 0) {
		emit(c, make_asbx(.LOADF, u32(reg), i32(i)))
	} else {
		emit_k(c, reg, float_k(c, f))
	}
}

load_nil :: proc(c: ^Compiler, from_in, n: i32) {
	from := from_in
	l := from + n - 1
	fs := c.fs
	if pc_of(c) > fs.last_target && pc_of(c) > 0 {
		prev := &fs.code[pc_of(c) - 1]
		if op_of(prev^) == .LOADNIL {
			pfrom := i32(arg_a(prev^))
			pl := pfrom + i32(arg_b(prev^))
			if (pfrom <= from && from <= pl + 1) || (from <= pfrom && pfrom <= l + 1) {
				if pfrom < from {from = pfrom}
				if pl > l {l = pl}
				set_arg_a(prev, u32(from))
				set_arg_b(prev, u32(l - from))
				return
			}
		}
	}
	emit_abc(c, .LOADNIL, from, n - 1, 0)
}

// Results of calls and '...'.

set_returns :: proc(c: ^Compiler, e: ^Exp, nresults: i32) {
	i := &c.fs.code[e.info]
	set_arg_c(i, u32(nresults + 1))
	if e.kind == .Vararg {
		set_arg_a(i, u32(c.fs.free_reg))
		reserve_regs(c, 1)
	}
}

set_multret :: proc(c: ^Compiler, e: ^Exp) {set_returns(c, e, -1)}

set_one_ret :: proc(c: ^Compiler, e: ^Exp) {
	if e.kind == .Call {
		e.kind = .Nonreloc
		e.info = i32(arg_a(c.fs.code[e.info]))
	} else if e.kind == .Vararg {
		set_arg_c(&c.fs.code[e.info], 2)
		e.kind = .Reloc
	}
}

// Placing values.

discharge_vars :: proc(c: ^Compiler, e: ^Exp) {
	saved := use_pos(c, e)
	defer restore_pos(c, saved)
	#partial switch e.kind {
	case .Local:
		e.kind = .Nonreloc
	case .Upval:
		e.info = emit_abc(c, .GETUPVAL, 0, e.info, 0)
		e.kind = .Reloc
	case .Global:
		e.info = emit_abx(c, .GETGLOBAL, 0, u32(e.info))
		e.kind = .Reloc
	case .Indexed_Int:
		free_reg(c, e.t)
		e.info = emit_abc(c, .GETI, 0, e.t, e.key)
		e.kind = .Reloc
	case .Indexed_Str:
		free_reg(c, e.t)
		e.info = emit_abc(c, .GETFIELD, 0, e.t, e.key)
		e.kind = .Reloc
	case .Indexed:
		free_regs(c, e.t, e.key)
		e.info = emit_abc(c, .GETTABLE, 0, e.t, e.key)
		e.kind = .Reloc
	case .Call, .Vararg:
		set_one_ret(c, e)
	}
}

@(private = "file")
discharge_to_reg :: proc(c: ^Compiler, e: ^Exp, reg: i32) {
	discharge_vars(c, e)
	#partial switch e.kind {
	case .Nil:
		load_nil(c, reg, 1)
	case .False:
		emit_abc(c, .LOADFALSE, reg, 0, 0)
	case .True:
		emit_abc(c, .LOADTRUE, reg, 0, 0)
	case .Str:
		emit_k(c, reg, string_k(c, e.str))
	case .K:
		emit_k(c, reg, e.info)
	case .Float:
		load_float(c, reg, e.fval)
	case .Int:
		load_int(c, reg, e.ival)
	case .Reloc:
		set_arg_a(&c.fs.code[e.info], u32(reg))
	case .Nonreloc:
		if reg != e.info {emit_abc(c, .MOVE, reg, e.info, 0)}
	case:
		return // Jmp
	}
	e.info = reg
	e.kind = .Nonreloc
}

@(private = "file")
discharge_to_any_reg :: proc(c: ^Compiler, e: ^Exp) {
	if e.kind != .Nonreloc {
		reserve_regs(c, 1)
		discharge_to_reg(c, e, c.fs.free_reg - 1)
	}
}

@(private = "file")
code_loadbool :: proc(c: ^Compiler, a: i32, op: Op) -> i32 {
	get_label(c)
	return emit_abc(c, op, a, 0, 0)
}

@(private = "file")
need_value :: proc(c: ^Compiler, list: i32) -> bool {
	for l := list; l != NO_JUMP; l = get_jump(c, l) {
		if op_of(jump_control(c, l)^) != .TESTSET {return true}
	}
	return false
}

@(private = "file")
exp_to_reg :: proc(c: ^Compiler, e: ^Exp, reg: i32) {
	discharge_to_reg(c, e, reg)
	if e.kind == .Jmp {concat_jumps(c, &e.tj, e.info)}
	if has_jumps(e) {
		p_f, p_t: i32 = NO_JUMP, NO_JUMP
		if need_value(c, e.tj) || need_value(c, e.fj) {
			fj := NO_JUMP if e.kind == .Jmp else jump(c)
			p_f = code_loadbool(c, reg, .LFALSESKIP)
			p_t = code_loadbool(c, reg, .LOADTRUE)
			patch_to_here(c, i32(fj))
		}
		final := get_label(c)
		patch_list_aux(c, e.fj, final, reg, p_f)
		patch_list_aux(c, e.tj, final, reg, p_t)
	}
	e.fj = NO_JUMP
	e.tj = NO_JUMP
	e.info = reg
	e.kind = .Nonreloc
}

exp_to_next_reg :: proc(c: ^Compiler, e: ^Exp) {
	discharge_vars(c, e)
	free_exp(c, e)
	reserve_regs(c, 1)
	exp_to_reg(c, e, c.fs.free_reg - 1)
}

exp_to_any_reg :: proc(c: ^Compiler, e: ^Exp) -> i32 {
	discharge_vars(c, e)
	if e.kind == .Nonreloc {
		if !has_jumps(e) {return e.info}
		if e.info >= nvarstack(c) {
			exp_to_reg(c, e, e.info)
			return e.info
		}
	}
	exp_to_next_reg(c, e)
	return e.info
}

exp_to_val :: proc(c: ^Compiler, e: ^Exp) {
	if has_jumps(e) {
		exp_to_any_reg(c, e)
	} else {
		discharge_vars(c, e)
	}
}

@(private = "file")
exp_to_k :: proc(c: ^Compiler, e: ^Exp) -> bool {
	if has_jumps(e) {return false}
	info: i32
	#partial switch e.kind {
	case .True:
		info = const_index(c, Const{tag = .Bool, bits = 1})
	case .False:
		info = const_index(c, Const{tag = .Bool})
	case .Nil:
		info = const_index(c, Const{tag = .Nil})
	case .Int:
		info = int_k(c, e.ival)
	case .Float:
		info = float_k(c, e.fval)
	case .Str:
		info = string_k(c, e.str)
	case .K:
		info = e.info
	case:
		return false
	}
	if info <= MAXINDEXRK {
		e.kind = .K
		e.info = info
		return true
	}
	return false
}

@(private = "file")
exp_to_rk :: proc(c: ^Compiler, e: ^Exp) -> bool {
	if exp_to_k(c, e) {return true}
	exp_to_any_reg(c, e)
	return false
}

@(private = "file")
code_abrk :: proc(c: ^Compiler, op: Op, a, b: i32, ec: ^Exp) {
	k := exp_to_rk(c, ec)
	emit_abc(c, op, a, b, ec.info, i32(k))
}

store_var :: proc(c: ^Compiler, v: ^Exp, ex: ^Exp) {
	saved := use_pos(c, v)
	defer restore_pos(c, saved)
	#partial switch v.kind {
	case .Local:
		free_exp(c, ex)
		exp_to_reg(c, ex, v.info)
		return
	case .Upval:
		e := exp_to_any_reg(c, ex)
		emit_abc(c, .SETUPVAL, e, v.info, 0)
	case .Global:
		e := exp_to_any_reg(c, ex)
		emit_abx(c, .SETGLOBAL, e, u32(v.info))
	case .Indexed_Int:
		code_abrk(c, .SETI, v.t, v.key, ex)
	case .Indexed_Str:
		code_abrk(c, .SETFIELD, v.t, v.key, ex)
	case .Indexed:
		code_abrk(c, .SETTABLE, v.t, v.key, ex)
	}
	free_exp(c, ex)
}

code_self :: proc(c: ^Compiler, e: ^Exp, key: ^Exp) {
	exp_to_any_reg(c, e)
	ereg := e.info
	free_exp(c, e)
	e.info = c.fs.free_reg
	e.kind = .Nonreloc
	reserve_regs(c, 2)
	code_abrk(c, .SELF, e.info, ereg, key)
	free_exp(c, key)
}

@(private = "file")
is_kstr :: proc(e: ^Exp) -> bool {
	return e.kind == .Str
}

// indexed turns t (in a register) and key into an indexed expression.
indexed :: proc(c: ^Compiler, t: ^Exp, key: ^Exp) {
	treg := t.info
	mark_pos(c, t)
	if key.kind == .Str {
		k := string_k(c, key.str)
		if k <= MAXARG_C {
			t.t = treg
			t.key = k
			t.kind = .Indexed_Str
			return
		}
	}
	if key.kind == .Int && !has_jumps(key) && key.ival >= 0 && key.ival <= MAXARG_C {
		t.t = treg
		t.key = i32(key.ival)
		t.kind = .Indexed_Int
		return
	}
	t.t = treg
	t.key = exp_to_any_reg(c, key)
	t.kind = .Indexed
}

// Conditions.

@(private = "file")
negate_condition :: proc(c: ^Compiler, e: ^Exp) {
	i := jump_control(c, e.info)
	set_arg_k(i, arg_k(i^) ~ 1)
}

@(private = "file")
cond_jump :: proc(c: ^Compiler, op: Op, a, b, cc, k: i32) -> i32 {
	emit_abc(c, op, a, b, cc, k)
	return jump(c)
}

@(private = "file")
jump_on_cond :: proc(c: ^Compiler, e: ^Exp, cond: i32) -> i32 {
	if e.kind == .Reloc {
		ie := c.fs.code[e.info]
		if op_of(ie) == .NOT && e.info == pc_of(c) - 1 {
			pop(&c.fs.code)
			pop(&c.fs.lines)
			return cond_jump(c, .TEST, i32(arg_b(ie)), 0, 0, 1 - cond)
		}
	}
	discharge_to_any_reg(c, e)
	free_exp(c, e)
	return cond_jump(c, .TESTSET, NO_REG, e.info, 0, cond)
}

go_if_true :: proc(c: ^Compiler, e: ^Exp) {
	discharge_vars(c, e)
	pc: i32
	#partial switch e.kind {
	case .Jmp:
		negate_condition(c, e)
		pc = e.info
	case .K, .Float, .Int, .Str, .True:
		pc = NO_JUMP
	case:
		pc = jump_on_cond(c, e, 0)
	}
	concat_jumps(c, &e.fj, pc)
	patch_to_here(c, e.tj)
	e.tj = NO_JUMP
}

go_if_false :: proc(c: ^Compiler, e: ^Exp) {
	discharge_vars(c, e)
	pc: i32
	#partial switch e.kind {
	case .Jmp:
		pc = e.info
	case .Nil, .False:
		pc = NO_JUMP
	case:
		pc = jump_on_cond(c, e, 1)
	}
	concat_jumps(c, &e.tj, pc)
	patch_to_here(c, e.fj)
	e.fj = NO_JUMP
}

@(private = "file")
code_not :: proc(c: ^Compiler, e: ^Exp) {
	#partial switch e.kind {
	case .Nil, .False:
		e.kind = .True
	case .K, .Float, .Int, .Str, .True:
		e.kind = .False
	case .Jmp:
		negate_condition(c, e)
	case .Reloc, .Nonreloc:
		discharge_to_any_reg(c, e)
		free_exp(c, e)
		e.info = emit_abc(c, .NOT, 0, e.info, 0)
		e.kind = .Reloc
	}
	e.tj, e.fj = e.fj, e.tj
	remove_values(c, e.fj)
	remove_values(c, e.tj)
}

// Operators.

@(private = "file")
numeral :: proc(e: ^Exp) -> (Value, bool) {
	if has_jumps(e) {return NIL, false}
	#partial switch e.kind {
	case .Int:
		return int_value(e.ival), true
	case .Float:
		return float_value(e.fval), true
	}
	return NIL, false
}

@(private = "file")
arith_op_of :: proc(op: Tok) -> Arith_Op {
	#partial switch op {
	case .Plus:
		return .Add
	case .Minus:
		return .Sub
	case .Star:
		return .Mul
	case .Percent:
		return .Mod
	case .Caret:
		return .Pow
	case .Slash:
		return .Div
	case .Dslash:
		return .Idiv
	case .Amp:
		return .Band
	case .Pipe:
		return .Bor
	case .Tilde:
		return .Bxor
	case .Shl:
		return .Shl
	case .Shr:
		return .Shr
	}
	return .Add
}

// fold: constant folding of arithmetic on numerals, never to NaN, -0 or a 0 divisor.
@(private = "file")
fold :: proc(op: Arith_Op, e1, e2: ^Exp) -> bool {
	v1, ok1 := numeral(e1)
	v2, ok2 := numeral(e2)
	if !ok1 || !ok2 {return false}
	#partial switch op {
	case .Div, .Idiv, .Mod:
		if to_float(v2) == 0 {return false}
	case .Band, .Bor, .Bxor, .Shl, .Shr, .Bnot:
		if _, ok := to_integer_strict(v1); !ok {return false}
		if _, ok := to_integer_strict(v2); !ok {return false}
	}
	r, st := arith(op, v1, v2)
	if st != .Ok {return false}
	if r.tag == .Int {
		e1.kind = .Int
		e1.ival = as_int(r)
	} else {
		f := as_float(r)
		if f != f || f == 0 {return false}
		e1.kind = .Float
		e1.fval = f
	}
	return true
}

prefix :: proc(c: ^Compiler, op: Tok, e: ^Exp) {
	discharge_vars(c, e)
	zero := exp_init(.Int)
	#partial switch op {
	case .Minus, .Tilde:
		aop: Arith_Op = .Unm if op == .Minus else .Bnot
		if fold(aop, e, &zero) {return}
		fallthrough
	case .Hash:
		opc: Op = .UNM if op == .Minus else .BNOT if op == .Tilde else .LEN
		r := exp_to_any_reg(c, e)
		free_exp(c, e)
		e.info = emit_abc(c, opc, 0, r, 0)
		e.kind = .Reloc
	case .Not:
		code_not(c, e)
	}
}

@(private = "file")
is_sc_number :: proc(e: ^Exp) -> (im: i32, is_float: i32, ok: bool) {
	i: i64
	if e.kind == .Int {
		i = e.ival
	} else if e.kind == .Float {
		j, exact := float_to_int_exact(e.fval)
		if !exact {return}
		i = j
		is_float = 1
	} else {
		return
	}
	if !has_jumps(e) && fits_c(i) {return i32(i + OFFSET_SC), is_float, true}
	return
}

@(private = "file")
is_sc_int :: proc(e: ^Exp) -> bool {
	return e.kind == .Int && !has_jumps(e) && fits_c(e.ival)
}

infix :: proc(c: ^Compiler, op: Tok, v: ^Exp) {
	discharge_vars(c, v)
	#partial switch op {
	case .And:
		go_if_true(c, v)
	case .Or:
		go_if_false(c, v)
	case .Concat:
		exp_to_next_reg(c, v)
	case .Plus, .Minus, .Star, .Slash, .Percent, .Dslash, .Caret, .Amp, .Pipe, .Tilde, .Shl, .Shr:
		if _, ok := numeral(v); !ok {exp_to_any_reg(c, v)}
	case .Eq, .Ne:
		if _, ok := numeral(v); !ok {exp_to_rk(c, v)}
	case .Lt, .Le, .Gt, .Ge:
		if _, _, ok := is_sc_number(v); !ok {exp_to_any_reg(c, v)}
	}
}

@(private = "file")
finish_bin :: proc(c: ^Compiler, e1, e2: ^Exp, op: Op, v2: i32, flip: i32) {
	v1 := exp_to_any_reg(c, e1)
	pc := emit_abc(c, op, 0, v1, v2, flip)
	free_exps(c, e1, e2)
	e1.info = pc
	e1.kind = .Reloc
}

@(private = "file")
REG_OPS := [Arith_Op]Op {
	.Add  = .ADD,
	.Sub  = .SUB,
	.Mul  = .MUL,
	.Mod  = .MOD,
	.Pow  = .POW,
	.Div  = .DIV,
	.Idiv = .IDIV,
	.Band = .BAND,
	.Bor  = .BOR,
	.Bxor = .BXOR,
	.Shl  = .SHL,
	.Shr  = .SHR,
	.Unm  = .UNM,
	.Bnot = .BNOT,
}

@(private = "file")
K_OPS := [Arith_Op]Op {
	.Add  = .ADDK,
	.Sub  = .SUBK,
	.Mul  = .MULK,
	.Mod  = .MODK,
	.Pow  = .POWK,
	.Div  = .DIVK,
	.Idiv = .IDIVK,
	.Band = .BANDK,
	.Bor  = .BORK,
	.Bxor = .BXORK,
	.Shl  = .SHL,
	.Shr  = .SHR,
	.Unm  = .UNM,
	.Bnot = .BNOT,
}

@(private = "file")
code_bin_reg :: proc(c: ^Compiler, op: Arith_Op, e1, e2: ^Exp, flip: i32) {
	if flip != 0 {e1^, e2^ = e2^, e1^}
	v2 := exp_to_any_reg(c, e2)
	finish_bin(c, e1, e2, REG_OPS[op], v2, 0)
}

// code_arith: with a numeral second operand the K form, else the register form. The k
// bit of a K or immediate form says the operands were swapped (for the metamethod).
@(private = "file")
code_arith :: proc(c: ^Compiler, op: Arith_Op, e1, e2: ^Exp, flip: i32) {
	if _, ok := numeral(e2); ok && exp_to_k(c, e2) {
		finish_bin(c, e1, e2, K_OPS[op], e2.info, flip)
		return
	}
	code_bin_reg(c, op, e1, e2, flip)
}

posfix :: proc(c: ^Compiler, op: Tok, e1, e2: ^Exp) {
	discharge_vars(c, e2)
	#partial switch op {
	case .Plus, .Minus, .Star, .Slash, .Percent, .Dslash, .Caret, .Amp, .Pipe, .Tilde, .Shl, .Shr:
		if fold(arith_op_of(op), e1, e2) {return}
	}
	#partial switch op {
	case .And:
		concat_jumps(c, &e2.fj, e1.fj)
		e1^ = e2^
	case .Or:
		concat_jumps(c, &e2.tj, e1.tj)
		e1^ = e2^
	case .Concat:
		exp_to_next_reg(c, e2)
		fs := c.fs
		if pc_of(c) > fs.last_target && pc_of(c) > 0 && op_of(fs.code[pc_of(c) - 1]) == .CONCAT {
			ie2 := &fs.code[pc_of(c) - 1]
			n := arg_b(ie2^)
			free_exp(c, e2)
			set_arg_a(ie2, u32(e1.info))
			set_arg_b(ie2, n + 1)
		} else {
			emit_abc(c, .CONCAT, e1.info, 2, 0)
			free_exp(c, e2)
		}
	case .Plus, .Star:
		flip: i32 = 0
		if _, ok := numeral(e1); ok {
			e1^, e2^ = e2^, e1^
			flip = 1
		}
		if op == .Plus && is_sc_int(e2) {
			finish_bin(c, e1, e2, .ADDI, i32(e2.ival + OFFSET_SC), flip)
		} else {
			code_arith(c, arith_op_of(op), e1, e2, flip)
		}
	case .Minus:
		if is_sc_int(e2) && fits_c(-e2.ival) {
			finish_bin(c, e1, e2, .ADDI, i32(-e2.ival + OFFSET_SC), 0)
		} else {
			code_arith(c, .Sub, e1, e2, 0)
		}
	case .Slash, .Dslash, .Percent, .Caret:
		code_arith(c, arith_op_of(op), e1, e2, 0)
	case .Amp, .Pipe, .Tilde:
		flip: i32 = 0
		if e1.kind == .Int {
			e1^, e2^ = e2^, e1^
			flip = 1
		}
		if e2.kind == .Int && exp_to_k(c, e2) {
			finish_bin(c, e1, e2, K_OPS[arith_op_of(op)], e2.info, flip)
		} else {
			code_bin_reg(c, arith_op_of(op), e1, e2, flip)
		}
	case .Shl:
		if is_sc_int(e1) {
			e1^, e2^ = e2^, e1^
			finish_bin(c, e1, e2, .SHLI, i32(e2.ival + OFFSET_SC), 1)
		} else if is_sc_int(e2) && fits_c(-e2.ival) {
			finish_bin(c, e1, e2, .SHRI, i32(-e2.ival + OFFSET_SC), 0)
		} else {
			code_bin_reg(c, .Shl, e1, e2, 0)
		}
	case .Shr:
		if is_sc_int(e2) {
			finish_bin(c, e1, e2, .SHRI, i32(e2.ival + OFFSET_SC), 0)
		} else {
			code_bin_reg(c, .Shr, e1, e2, 0)
		}
	case .Eq, .Ne:
		if e1.kind != .Nonreloc {e1^, e2^ = e2^, e1^}
		r1 := exp_to_any_reg(c, e1)
		r2: i32
		opc: Op
		isf: i32 = 0
		if im, f, ok := is_sc_number(e2); ok {
			opc, r2, isf = .EQI, im, f
		} else if exp_to_rk(c, e2) {
			opc, r2 = .EQK, e2.info
		} else {
			opc, r2 = .EQ, exp_to_any_reg(c, e2)
		}
		free_exps(c, e1, e2)
		e1.info = cond_jump(c, opc, r1, r2, isf, 1 if op == .Eq else 0)
		e1.kind = .Jmp
	case .Gt, .Ge, .Lt, .Le:
		lt := op == .Lt || op == .Gt
		if op == .Gt || op == .Ge {e1^, e2^ = e2^, e1^}
		r1, r2: i32
		opc: Op
		isf: i32 = 0
		if im, f, ok := is_sc_number(e2); ok {
			r1 = exp_to_any_reg(c, e1)
			r2, isf = im, f
			opc = .LTI if lt else .LEI
		} else if im2, f2, ok2 := is_sc_number(e1); ok2 {
			r1 = exp_to_any_reg(c, e2)
			r2, isf = im2, f2
			opc = .GTI if lt else .GEI
		} else {
			r1 = exp_to_any_reg(c, e1)
			r2 = exp_to_any_reg(c, e2)
			opc = .LT if lt else .LE
		}
		free_exps(c, e1, e2)
		e1.info = cond_jump(c, opc, r1, r2, isf, 1)
		e1.kind = .Jmp
	}
}

set_list :: proc(c: ^Compiler, base, nelems_in, tostore_in: i32) {
	tostore := 0 if tostore_in == -1 else tostore_in
	nelems := nelems_in
	if nelems <= MAXARG_C {
		emit_abc(c, .SETLIST, base, tostore, nelems)
	} else {
		extra := nelems / (MAXARG_C + 1)
		nelems %= MAXARG_C + 1
		emit_abc(c, .SETLIST, base, tostore, nelems, 1)
		emit(c, make_ax(.EXTRAARG, u32(extra)))
	}
	c.fs.free_reg = base + 1
}

set_table_size :: proc(c: ^Compiler, pc, ra, asize, hsize: i32) {
	rb: i32 = 0
	if hsize != 0 {
		l: i32 = 0
		for (i32(1) << u32(l)) < hsize {l += 1}
		rb = l + 1
	}
	extra := asize / (MAXARG_C + 1)
	rc := asize % (MAXARG_C + 1)
	c.fs.code[pc] = make_abc(.NEWTABLE, u32(ra), u32(rb), u32(rc), 1 if extra > 0 else 0)
	c.fs.code[pc + 1] = make_ax(.EXTRAARG, u32(extra))
}

code_ret :: proc(c: ^Compiler, first, nret: i32) {
	switch nret {
	case 0:
		emit_abc(c, .RETURN0, 0, 0, 0)
	case 1:
		emit_abc(c, .RETURN1, first, 0, 0)
	case:
		emit_abc(c, .RETURN, first, nret + 1, 0)
	}
}
