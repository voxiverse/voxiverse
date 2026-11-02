package script

import "core:mem"
import "core:mem/virtual"
import "core:strings"

// The compiler: the syntax tree to Proto objects, one walk per function, after Lua 5.4's
// lparser.c. Locals occupy consecutive registers; temporaries stack above them.

MAX_SOURCE :: 1 << 20

Const :: struct {
	tag:  Tag,
	bits: u64,
	s:    string,
}

Var_Desc :: struct {
	name:      string,
	reg:       i32,
	debug_idx: i32,
}

Upval_Build :: struct {
	name:    string,
	instack: bool,
	index:   u8,
}

Local_Debug :: struct {
	name:     string,
	start_pc: i32,
	end_pc:   i32,
	reg:      i32,
}

Block :: struct {
	previous:       ^Block,
	nactvar:        i32,
	upval:          bool, // a local of this block is captured
	any_upval:      bool, // a local of this block or one inside it is captured
	is_loop:        bool,
	break_list:     i32,
	continue_list:  i32,
	continue_nact:  i32, // active locals at the first 'continue' (repeat's check), or -1
	is_repeat_body: bool,
}

Func_State :: struct {
	parent:      ^Func_State,
	code:        [dynamic]Instr,
	lines:       [dynamic]Line_Info,
	consts:      [dynamic]Const,
	kindex:      []i32,
	protos:      [dynamic]^Func_State,
	upvals:      [dynamic]Upval_Build,
	locals:      [dynamic]Local_Debug,
	first_local: int,
	nactvar:     int,
	free_reg:    i32,
	max_stack:   i32,
	last_target: i32,
	block:       ^Block,
	num_params:  i32,
	is_vararg:   bool,
	name:        string,
	line:        u32,
	last_line:   u32,
}

Compiler :: struct {
	vm:          ^VM,
	source:      string,
	text:        Ref,
	fs:          ^Func_State,
	actvars:     [dynamic]Var_Desc,
	line, col:   u32,
	span:        u32,
	err:         Syntax_Error,
	failed:      bool,
	depth:       int,
	until_limit: i32, // while compiling an 'until': locals at or above this index are refused
	until_block: ^Block,
}

compile_error :: proc(c: ^Compiler, message: string, hint := "") {
	if c.failed {return}
	c.failed = true
	c.err = Syntax_Error {
		message = message,
		hint    = hint,
		line    = c.line,
		col     = c.col,
		len     = max(c.span, 1),
	}
}

@(private = "file")
at :: #force_inline proc(c: ^Compiler, n: ^Node) {
	c.line = n.line
	c.col = n.col
	c.span = n.len
}

// Scopes and variables.

@(private = "file")
enter_block :: proc(c: ^Compiler, bl: ^Block, is_loop: bool) {
	fs := c.fs
	bl^ = Block {
		previous      = fs.block,
		nactvar       = i32(fs.nactvar),
		is_loop       = is_loop,
		break_list    = NO_JUMP,
		continue_list = NO_JUMP,
		continue_nact = -1,
	}
	fs.block = bl
}

@(private = "file")
reg_level :: proc(c: ^Compiler, nvar: i32) -> i32 {
	if nvar == 0 {return 0}
	return c.actvars[c.fs.first_local + int(nvar) - 1].reg + 1
}

@(private = "file")
remove_vars :: proc(c: ^Compiler, to_level: i32) {
	fs := c.fs
	for i32(fs.nactvar) > to_level {
		fs.nactvar -= 1
		v := c.actvars[fs.first_local + fs.nactvar]
		fs.locals[v.debug_idx].end_pc = pc_of(c)
	}
	resize(&c.actvars, fs.first_local + fs.nactvar)
}

@(private = "file")
leave_block :: proc(c: ^Compiler, close: bool = true) {
	fs := c.fs
	bl := fs.block
	level := reg_level(c, bl.nactvar)
	remove_vars(c, bl.nactvar)
	if close && bl.upval && bl.previous != nil {emit_abc(c, .CLOSE, level, 0, 0)}
	fs.free_reg = level
	fs.block = bl.previous
}

@(private = "file")
new_local :: proc(c: ^Compiler, name: string) {
	fs := c.fs
	if len(c.actvars) - fs.first_local + 1 > MAX_LOCALS {
		compile_error(
			c,
			"too many local variables in one function (the limit is 200)",
			"group related values in a table, or split the function",
		)
		return
	}
	append(&c.actvars, Var_Desc{name = name, reg = -1})
}

// adjust_locals activates the last n declared locals, in registers from the current level.
@(private = "file")
adjust_locals :: proc(c: ^Compiler, n: int) {
	fs := c.fs
	reg := nvarstack(c)
	for _ in 0 ..< n {
		v := &c.actvars[fs.first_local + fs.nactvar]
		v.reg = reg
		reg += 1
		v.debug_idx = i32(len(fs.locals))
		append(&fs.locals, Local_Debug{name = v.name, start_pc = pc_of(c), reg = v.reg})
		fs.nactvar += 1
	}
}

@(private = "file")
mark_upval :: proc(c: ^Compiler, fs: ^Func_State, var_index: i32) {
	bl := fs.block
	for bl.nactvar > var_index {
		bl.any_upval = true
		bl = bl.previous
	}
	bl.upval = true
	for b := bl; b != nil; b = b.previous {b.any_upval = true}
}

@(private = "file")
search_upvalue :: proc(fs: ^Func_State, name: string) -> i32 {
	for u, i in fs.upvals {if u.name == name {return i32(i)}}
	return -1
}

@(private = "file")
single_var_aux :: proc(c: ^Compiler, fs: ^Func_State, name: string, e: ^Exp, base: bool) {
	if fs == nil {
		e^ = exp_init(.Void)
		return
	}
	for i := fs.nactvar - 1; i >= 0; i -= 1 {
		v := c.actvars[fs.first_local + i]
		if v.name == name {
			e^ = exp_init(.Local, v.reg)
			e.key = i32(i) // the variable's index, for the repeat check
			if !base {mark_upval(c, fs, i32(i))}
			return
		}
	}
	idx := search_upvalue(fs, name)
	if idx < 0 {
		single_var_aux(c, fs.parent, name, e, false)
		if e.kind != .Local && e.kind != .Upval {return}
		if len(fs.upvals) >= MAX_UPVALUES {
			compile_error(
				c,
				"too many upvalues in one function (the limit is 255)",
				"group the captured values in a table",
			)
			return
		}
		append(
			&fs.upvals,
			Upval_Build{name = name, instack = e.kind == .Local, index = u8(e.info)},
		)
		idx = i32(len(fs.upvals) - 1)
	}
	e^ = exp_init(.Upval, idx)
}

@(private = "file")
single_var :: proc(c: ^Compiler, name: string) -> Exp {
	e: Exp
	single_var_aux(c, c.fs, name, &e, true)
	if e.kind == .Local && c.until_block != nil && e.key >= c.until_limit {
		compile_error(
			c,
			strings.concatenate(
				{"'continue' here would skip local '", name, "', which 'until' uses"},
			),
			"declare the local before the first 'continue', or use a flag instead of 'continue'",
		)
	}
	if e.kind == .Void {
		e = exp_init(.Global, string_k(c, name))
	}
	mark_pos(c, &e)
	return e
}

// Functions.

@(private = "file")
open_func :: proc(c: ^Compiler, fs: ^Func_State, f: ^Node) -> ^Block {
	fs.parent = c.fs
	fs.first_local = len(c.actvars)
	fs.last_target = 0
	fs.line = f.line if f != nil else 0
	fs.last_line = f.end_line if f != nil else 0
	fs.name = f.name if f != nil else ""
	fs.max_stack = 2
	c.fs = fs
	bl := new(Block)
	enter_block(c, bl, false)
	return bl
}

@(private = "file")
close_func :: proc(c: ^Compiler) {
	code_ret(c, nvarstack(c), 0)
	leave_block(c)
	c.fs = c.fs.parent
}

@(private = "file")
function_body :: proc(c: ^Compiler, f: ^Node) -> ^Func_State {
	fs := new(Func_State)
	open_func(c, fs, f)
	at(c, f)
	for p in f.list {new_local(c, p.name)}
	adjust_locals(c, len(f.list))
	fs.num_params = i32(fs.nactvar)
	fs.is_vararg = f.flag
	if fs.is_vararg {emit_abc(c, .VARARGPREP, fs.num_params, 0, 0)}
	reserve_regs(c, fs.num_params)
	statements(c, f.body)
	c.line = f.end_line
	close_func(c)
	return fs
}

@(private = "file")
code_closure :: proc(c: ^Compiler, f: ^Node, e: ^Exp) {
	child := function_body(c, f)
	append(&c.fs.protos, child)
	at(c, f)
	e^ = exp_init(.Reloc, emit_abx(c, .CLOSURE, 0, u32(len(c.fs.protos) - 1)))
	exp_to_next_reg(c, e)
}

// Expressions.

@(private = "file")
enter :: proc(c: ^Compiler) -> bool {
	c.depth += 1
	if c.depth > MAX_NESTING * 3 {
		compile_error(
			c,
			"too many nested levels (the limit is 200)",
			"split the code into smaller functions",
		)
		return false
	}
	return true
}

expression :: proc(c: ^Compiler, n: ^Node, e: ^Exp) {
	if n == nil || c.failed {
		e^ = exp_init(.Nil)
		return
	}
	if !enter(c) {
		e^ = exp_init(.Nil)
		return
	}
	defer c.depth -= 1
	#partial switch n.kind {
	case .Nil:
		e^ = exp_init(.Nil)
	case .True:
		e^ = exp_init(.True)
	case .False:
		e^ = exp_init(.False)
	case .Int:
		e^ = exp_init(.Int)
		e.ival = n.ival
	case .Float:
		e^ = exp_init(.Float)
		e.fval = n.fval
	case .String:
		e^ = exp_init(.Str)
		e.str = n.name
	case .Vararg:
		at(c, n)
		e^ = exp_init(.Vararg, emit_abc(c, .VARARG, 0, 0, 1))
	case .Function:
		code_closure(c, n, e)
	case .Table:
		table_constructor(c, n, e)
	case .Paren:
		expression(c, n.a, e)
		discharge_vars(c, e)
	case .Unop:
		expression(c, n.a, e)
		at(c, n)
		prefix(c, n.op, e)
	case .Binop:
		expression(c, n.a, e)
		at(c, n)
		infix(c, n.op, e)
		e2: Exp
		expression(c, n.b, &e2)
		at(c, n)
		posfix(c, n.op, e, &e2)
	case:
		suffixed(c, n, e)
	}
}

@(private = "file")
suffixed :: proc(c: ^Compiler, n: ^Node, e: ^Exp) {
	#partial switch n.kind {
	case .Name:
		at(c, n)
		e^ = single_var(c, n.name)
	case .Index:
		expression(c, n.a, e)
		exp_to_any_reg(c, e)
		key: Exp
		expression(c, n.b, &key)
		exp_to_val(c, &key)
		at(c, n)
		indexed(c, e, &key)
	case .Call, .Method_Call:
		call_expr(c, n, e)
	case:
		expression(c, n, e)
	}
}

@(private = "file")
call_expr :: proc(c: ^Compiler, n: ^Node, f: ^Exp) {
	expression(c, n.a, f)
	at(c, n)
	if n.kind == .Method_Call {
		key := exp_init(.Str)
		key.str = n.name
		code_self(c, f, &key)
	} else {
		exp_to_next_reg(c, f)
	}
	base := f.info
	args := exp_init(.Void)
	explist(c, n.list, &args)
	nparams: i32
	if has_multret(args.kind) {
		set_multret(c, &args)
		nparams = -1
	} else {
		if args.kind != .Void {exp_to_next_reg(c, &args)}
		nparams = c.fs.free_reg - (base + 1)
	}
	at(c, n)
	f^ = exp_init(.Call, emit_abc(c, .CALL, base, nparams + 1, 2))
	c.fs.free_reg = base + 1
}

// explist compiles a list; all but the last go to consecutive registers, the last is
// left in e. Returns the number of expressions.
@(private = "file")
explist :: proc(c: ^Compiler, list: []^Node, e: ^Exp) -> i32 {
	if len(list) == 0 {
		e^ = exp_init(.Void)
		return 0
	}
	for n, i in list {
		if i > 0 {exp_to_next_reg(c, e)}
		expression(c, n, e)
	}
	return i32(len(list))
}

@(private = "file")
table_constructor :: proc(c: ^Compiler, n: ^Node, t: ^Exp) {
	at(c, n)
	pc := emit_abc(c, .NEWTABLE, 0, 0, 0)
	emit(c, make_ax(.EXTRAARG, 0))
	t^ = exp_init(.Nonreloc, c.fs.free_reg)
	reserve_regs(c, 1)
	na, nh, tostore: i32
	v := exp_init(.Void)
	for f in n.list {
		if c.failed {return}
		// Close the pending list item.
		if v.kind != .Void {
			exp_to_next_reg(c, &v)
			v = exp_init(.Void)
			if tostore == LFIELDS_PER_FLUSH {
				set_list(c, t.info, na, tostore)
				na += tostore
				tostore = 0
			}
		}
		#partial switch f.kind {
		case .Field_Pos:
			expression(c, f.a, &v)
			tostore += 1
		case .Field_Named, .Field_Keyed:
			reg := c.fs.free_reg
			key: Exp
			if f.kind == .Field_Named {
				key = exp_init(.Str)
				key.str = f.name
			} else {
				expression(c, f.a, &key)
				exp_to_val(c, &key)
			}
			nh += 1
			tab := t^
			at(c, f)
			indexed(c, &tab, &key)
			val: Exp
			expression(c, f.b if f.kind == .Field_Keyed else f.a, &val)
			at(c, f)
			store_var(c, &tab, &val)
			c.fs.free_reg = reg
		}
	}
	if tostore > 0 {
		if has_multret(v.kind) {
			set_multret(c, &v)
			set_list(c, t.info, na, -1)
			na -= 1
		} else {
			if v.kind != .Void {exp_to_next_reg(c, &v)}
			set_list(c, t.info, na, tostore)
		}
		na += tostore
	}
	set_table_size(c, pc, t.info, na, nh)
}

// Statements.

statements :: proc(c: ^Compiler, body: []^Node) {
	for s in body {
		if c.failed {return}
		statement(c, s)
		c.fs.free_reg = nvarstack(c)
	}
}

@(private = "file")
adjust_assign :: proc(c: ^Compiler, nvars, nexps: i32, e: ^Exp) {
	needed := nvars - nexps
	if has_multret(e.kind) {
		extra := max(needed + 1, 0)
		set_returns(c, e, extra)
	} else {
		if e.kind != .Void {exp_to_next_reg(c, e)}
		if needed > 0 {load_nil(c, c.fs.free_reg, needed)}
	}
	if needed > 0 {
		reserve_regs(c, needed)
	} else {
		c.fs.free_reg += needed
	}
}

@(private = "file")
block_body :: proc(c: ^Compiler, body: []^Node) {
	bl: Block
	enter_block(c, &bl, false)
	statements(c, body)
	leave_block(c)
}

// loop_body compiles a loop's body in its own block; 'continue' lands at its end, where
// the body's captured locals are closed.
@(private = "file")
loop_body :: proc(c: ^Compiler, body: []^Node, nvars: int) {
	bl: Block
	enter_block(c, &bl, false)
	if nvars > 0 {
		adjust_locals(c, nvars)
		reserve_regs(c, i32(nvars))
	}
	statements(c, body)
	loop_block_end(c, &bl)
}

@(private = "file")
loop_block_end :: proc(c: ^Compiler, bl: ^Block) {
	if bl.continue_list != NO_JUMP {patch_to_here(c, bl.continue_list)}
	if bl.any_upval {
		level := reg_level(c, bl.nactvar)
		remove_vars(c, bl.nactvar)
		emit_abc(c, .CLOSE, level, 0, 0)
		c.fs.free_reg = level
		c.fs.block = bl.previous
		return
	}
	leave_block(c, false)
}

// loop_end closes the loop block: 'break' lands after the loop.
@(private = "file")
loop_end :: proc(c: ^Compiler, loop: ^Block) {
	level := reg_level(c, loop.nactvar)
	remove_vars(c, loop.nactvar)
	c.fs.free_reg = level
	c.fs.block = loop.previous
	if loop.break_list != NO_JUMP {
		patch_to_here(c, loop.break_list)
		if loop.any_upval {emit_abc(c, .CLOSE, level, 0, 0)}
	}
}

@(private = "file")
cond :: proc(c: ^Compiler, n: ^Node) -> i32 {
	e: Exp
	expression(c, n, &e)
	if e.kind == .Nil {e.kind = .False}
	go_if_true(c, &e)
	return e.fj
}

// enclosing_loop: the innermost loop's block and the block just inside it (its body).
@(private = "file")
enclosing_loop :: proc(c: ^Compiler) -> (loop: ^Block, body: ^Block) {
	child: ^Block
	for bl := c.fs.block; bl != nil; bl = bl.previous {
		if bl.is_loop {return bl, child}
		child = bl
	}
	return nil, nil
}

@(private = "file")
statement :: proc(c: ^Compiler, n: ^Node) {
	if !enter(c) {return}
	defer c.depth -= 1
	at(c, n)
	fs := c.fs
	#partial switch n.kind {
	case .Local:
		for b in n.list {new_local(c, b.name)}
		e: Exp
		nexps := explist(c, n.list2, &e)
		adjust_assign(c, i32(len(n.list)), nexps, &e)
		adjust_locals(c, len(n.list))
	case .Local_Function:
		new_local(c, n.name)
		adjust_locals(c, 1)
		e: Exp
		code_closure(c, n.b, &e)
		fs.locals[c.actvars[fs.first_local + fs.nactvar - 1].debug_idx].start_pc = pc_of(c)
	case .Function_Stat:
		v: Exp
		suffixed(c, n.a, &v)
		e: Exp
		code_closure(c, n.b, &e)
		at(c, n)
		store_var(c, &v, &e)
	case .Assign:
		assignment(c, n)
	case .Compound:
		compound(c, n)
	case .Call_Stat:
		e: Exp
		suffixed(c, n.a, &e)
		set_arg_c(&fs.code[e.info], 1)
	case .Do:
		block_body(c, n.body)
	case .While:
		loop: Block
		init := get_label(c)
		exit := cond(c, n.a)
		enter_block(c, &loop, true)
		loop_body(c, n.body, 0)
		c.line = n.end_line
		patch_list(c, jump(c), init)
		loop_end(c, &loop)
		patch_to_here(c, exit)
	case .Repeat:
		repeat_stat(c, n)
	case .If:
		escape := i32(NO_JUMP)
		for clause, i in n.list {
			at(c, clause)
			flist := cond(c, clause.a)
			block_body(c, clause.body)
			last := i == len(n.list) - 1 && !n.flag
			if !last {concat_jumps(c, &escape, jump(c))}
			patch_to_here(c, flist)
		}
		if n.flag {block_body(c, n.list2)}
		patch_to_here(c, escape)
	case .Numeric_For:
		numeric_for(c, n)
	case .Generic_For:
		generic_for(c, n)
	case .Return:
		return_stat(c, n)
	case .Break:
		loop, _ := enclosing_loop(c)
		if loop == nil {
			compile_error(
				c,
				"'break' outside a loop",
				"'break' leaves the innermost while, repeat or for loop",
			)
			return
		}
		concat_jumps(c, &loop.break_list, jump(c))
	case .Continue:
		_, body := enclosing_loop(c)
		if body == nil {
			compile_error(
				c,
				"'continue' outside a loop",
				"'continue' goes to the next iteration of the innermost loop",
			)
			return
		}
		if body.continue_nact < 0 {body.continue_nact = i32(fs.nactvar)}
		concat_jumps(c, &body.continue_list, jump(c))
	case .Type_Alias:
	// Erased.
	}
}

@(private = "file")
repeat_stat :: proc(c: ^Compiler, n: ^Node) {
	loop, scope: Block
	init := get_label(c)
	enter_block(c, &loop, true)
	enter_block(c, &scope, false)
	statements(c, n.body)
	if scope.continue_list != NO_JUMP {patch_to_here(c, scope.continue_list)}
	saved_limit, saved_block := c.until_limit, c.until_block
	if scope.continue_nact >= 0 {
		c.until_limit = scope.continue_nact
		c.until_block = &scope
	}
	exit := cond(c, n.a)
	c.until_limit, c.until_block = saved_limit, saved_block
	upval := scope.upval || scope.any_upval
	level := reg_level(c, scope.nactvar)
	leave_block(c, false)
	if upval {
		emit_abc(c, .CLOSE, level, 0, 0) // the normal exit
		normal := jump(c)
		patch_to_here(c, exit)
		emit_abc(c, .CLOSE, level, 0, 0)
		exit = jump(c)
		patch_to_here(c, normal)
	}
	patch_list(c, exit, init)
	loop_end(c, &loop)
}

@(private = "file")
numeric_for :: proc(c: ^Compiler, n: ^Node) {
	loop: Block
	enter_block(c, &loop, true)
	base := c.fs.free_reg
	new_local(c, "(for state)")
	new_local(c, "(for state)")
	new_local(c, "(for state)")
	new_local(c, n.a.name)
	e: Exp
	expression(c, n.b, &e)
	exp_to_next_reg(c, &e)
	expression(c, n.c, &e)
	exp_to_next_reg(c, &e)
	if n.d != nil {
		expression(c, n.d, &e)
		exp_to_next_reg(c, &e)
	} else {
		load_int(c, c.fs.free_reg, 1)
		reserve_regs(c, 1)
	}
	adjust_locals(c, 3)
	at(c, n)
	prep := emit_abx(c, .FORPREP, base, 0)
	loop_body(c, n.body, 1)
	at(c, n)
	fix_for_jump(c, prep, get_label(c), false)
	endfor := emit_abx(c, .FORLOOP, base, 0)
	fix_for_jump(c, endfor, prep + 1, true)
	loop_end(c, &loop)
}

@(private = "file")
generic_for :: proc(c: ^Compiler, n: ^Node) {
	loop: Block
	enter_block(c, &loop, true)
	base := c.fs.free_reg
	new_local(c, "(for state)")
	new_local(c, "(for state)")
	new_local(c, "(for state)")
	for b in n.list {new_local(c, b.name)}
	e: Exp
	nexps := explist(c, n.list2, &e)
	at(c, n)
	adjust_assign(c, 3, nexps, &e)
	adjust_locals(c, 3)
	check_stack(c, 3)
	prep := emit_abx(c, .TFORPREP, base, 0)
	loop_body(c, n.body, len(n.list))
	at(c, n)
	fix_for_jump(c, prep, get_label(c), false)
	emit_abc(c, .TFORCALL, base, 0, i32(len(n.list)))
	endfor := emit_abx(c, .TFORLOOP, base, 0)
	fix_for_jump(c, endfor, prep + 1, true)
	loop_end(c, &loop)
}

@(private = "file")
fix_for_jump :: proc(c: ^Compiler, pc, dest: i32, back: bool) {
	off := dest - (pc + 1)
	if back {off = -off}
	if off > MAXARG_BX {
		compile_error(c, "control structure too long", "split the loop's body into functions")
		return
	}
	set_arg_bx(&c.fs.code[pc], u32(off))
}

@(private = "file")
return_stat :: proc(c: ^Compiler, n: ^Node) {
	first := nvarstack(c)
	nret: i32
	e: Exp
	nret = explist(c, n.list, &e)
	if nret == 0 {
		code_ret(c, first, 0)
		return
	}
	if has_multret(e.kind) {
		set_multret(c, &e)
		if e.kind == .Call && nret == 1 {set_op_tailcall(c, e.info)} 	// return f(...)
		nret = -1
	} else if nret == 1 {
		first = exp_to_any_reg(c, &e)
	} else {
		exp_to_next_reg(c, &e)
	}
	at(c, n)
	code_ret(c, first, nret)
}

@(private = "file")
set_op_tailcall :: proc(c: ^Compiler, pc: i32) {
	i := c.fs.code[pc]
	c.fs.code[pc] = make_abc(.TAILCALL, arg_a(i), arg_b(i), arg_c(i), arg_k(i))
}

@(private = "file")
assignment :: proc(c: ^Compiler, n: ^Node) {
	targets := make([]Exp, len(n.list))
	for t, i in n.list {
		suffixed(c, t, &targets[i])
		if c.failed {return}
		if targets[i].kind == .Local {
			// A local assigned here may be the table or key of an earlier target.
			conflict := false
			extra := c.fs.free_reg
			for j in 0 ..< i {
				p := &targets[j]
				#partial switch p.kind {
				case .Indexed, .Indexed_Int, .Indexed_Str:
					if p.t == targets[i].info {
						conflict = true
						p.t = extra
					}
					if p.kind == .Indexed && p.key == targets[i].info {
						conflict = true
						p.key = extra
					}
				}
			}
			if conflict {
				emit_abc(c, .MOVE, extra, targets[i].info, 0)
				reserve_regs(c, 1)
			}
		}
	}
	e: Exp
	nexps := explist(c, n.list2, &e)
	nvars := i32(len(targets))
	if nexps == nvars && nvars == 1 {
		set_one_ret(c, &e)
		at(c, n)
		store_var(c, &targets[0], &e)
		return
	}
	adjust_assign(c, nvars, nexps, &e)
	at(c, n)
	for i := len(targets) - 1; i >= 0; i -= 1 {
		v := exp_init(.Nonreloc, c.fs.free_reg - 1)
		store_var(c, &targets[i], &v)
	}
}

@(private = "file")
compound :: proc(c: ^Compiler, n: ^Node) {
	op: Tok
	#partial switch n.op {
	case .Plus_Eq:
		op = .Plus
	case .Minus_Eq:
		op = .Minus
	case .Star_Eq:
		op = .Star
	case .Slash_Eq:
		op = .Slash
	case .Dslash_Eq:
		op = .Dslash
	case .Percent_Eq:
		op = .Percent
	case .Caret_Eq:
		op = .Caret
	case .Concat_Eq:
		op = .Concat
	}
	target: Exp
	suffixed(c, n.a, &target)
	// The target's table and key are evaluated once: read it through a copy.
	cur := target
	#partial switch cur.kind {
	case .Indexed, .Indexed_Int, .Indexed_Str:
		// discharge_vars would free the registers the store still needs.
		at(c, n.a)
		pc: i32
		#partial switch cur.kind {
		case .Indexed:
			pc = emit_abc(c, .GETTABLE, 0, cur.t, cur.key)
		case .Indexed_Int:
			pc = emit_abc(c, .GETI, 0, cur.t, cur.key)
		case .Indexed_Str:
			pc = emit_abc(c, .GETFIELD, 0, cur.t, cur.key)
		}
		cur = exp_init(.Reloc, pc)
	}
	at(c, n)
	infix(c, op, &cur)
	rhs: Exp
	expression(c, n.b, &rhs)
	at(c, n)
	posfix(c, op, &cur, &rhs)
	store_var(c, &target, &cur)
}

// Building the Protos.

@(private = "file")
build_proto :: proc(c: ^Compiler, fs: ^Func_State) -> Ref {
	vm := c.vm
	nested := make([]Ref, len(fs.protos))
	for child, i in fs.protos {
		nested[i] = build_proto(c, child)
		if nested[i] == 0 {return 0}
	}
	consts := make([]Value, len(fs.consts))
	for k, i in fs.consts {
		switch k.tag {
		case .String:
			consts[i] = new_string(vm, k.s)
			if consts[i].tag == .Nil {return 0}
		case .Nil, .Bool, .Int, .Float, .Handle, .Table, .Function, .Thread:
			consts[i] = Value {
				tag  = k.tag,
				bits = k.bits,
			}
		}
	}
	r := heap_alloc(vm, .Proto, size_of(Proto))
	if r == 0 {return 0}
	code := alloc_bytes(vm, len(fs.code) * 4)
	lines := alloc_bytes(vm, len(fs.lines) * size_of(Line_Info))
	kbuf := alloc_values(vm, u32(len(consts)))
	pbuf := alloc_values(vm, u32(len(nested)))
	ubuf := alloc_bytes(vm, len(fs.upvals) * size_of(Upval_Desc))
	lbuf := alloc_bytes(vm, len(fs.locals) * size_of(Local_Info))
	name := new_string(vm, fs.name)
	source := new_string(vm, c.source)
	if code == 0 ||
	   lines == 0 ||
	   kbuf == 0 ||
	   pbuf == 0 ||
	   ubuf == 0 ||
	   lbuf == 0 ||
	   name.tag == .Nil ||
	   source.tag == .Nil {
		return 0
	}
	if len(fs.code) >
	   0 {mem.copy(&vm.mem[u32(code) + BUF_DATA], raw_data(fs.code), len(fs.code) * 4)}
	if len(fs.lines) >
	   0 {mem.copy(&vm.mem[u32(lines) + BUF_DATA], raw_data(fs.lines), len(fs.lines) * size_of(Line_Info))}
	copy(values_of(vm, kbuf, u32(len(consts))), consts)
	pv := values_of(vm, pbuf, u32(len(nested)))
	for p, i in nested {pv[i] = ref_value(.Function, p)}
	uv := bytes_of(vm, ubuf, Upval_Desc, u32(len(fs.upvals)))
	for u, i in fs.upvals {
		uv[i] = Upval_Desc {
			instack    = u8(u.instack),
			index      = u.index,
			name_const = u32(string_k_value(c, fs, u.name)),
		}
	}
	lv := bytes_of(vm, lbuf, Local_Info, u32(len(fs.locals)))
	for l, i in fs.locals {
		lv[i] = Local_Info {
			name_const = u32(string_k_value(c, fs, l.name)),
			start_pc   = u32(l.start_pc),
			end_pc     = u32(l.end_pc),
			register   = u32(l.reg),
		}
	}
	p := obj(vm, r, Proto)
	p.code = code
	p.consts = kbuf
	p.protos = pbuf
	p.upvals = ubuf
	p.lines = lines
	p.locals = lbuf
	p.source = as_ref(source)
	p.name = as_ref(name)
	p.text = c.text
	p.code_len = u32(len(fs.code))
	p.consts_len = u32(len(consts))
	p.protos_len = u32(len(nested))
	p.upvals_len = u32(len(fs.upvals))
	p.locals_len = u32(len(fs.locals))
	p.line_defined = fs.line
	p.last_line = fs.last_line
	p.num_params = u8(fs.num_params)
	p.is_vararg = u8(fs.is_vararg)
	p.max_stack = u8(fs.max_stack)
	return r
}

// string_k_value: debug names are interned strings; their Ref is kept as a "constant"
// number in the debug tables (the Ref of the string itself).
@(private = "file")
string_k_value :: proc(c: ^Compiler, fs: ^Func_State, s: string) -> Ref {
	return intern(c.vm, s)
}

// compile_source: source to a module Proto in the VM's heap, or a syntax error. The
// tree and the compiler's tables live in a scratch arena freed at the end.
compile_source :: proc(
	vm: ^VM,
	source, name: string,
) -> (
	proto: Ref,
	err: Syntax_Error,
	ok: bool,
) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return 0,
			Syntax_Error{message = "out of memory compiling", line = 1, col = 1, len = 1},
			false
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	if len(source) > MAX_SOURCE {
		return 0,
			Syntax_Error {
				message = "source too large (the limit is 1 MiB)",
				hint = "split it into several scripts",
				line = 1,
				col = 1,
				len = 1,
			},
			false
	}
	scratch := strings.builder_make()
	p: Parser
	body, parsed := parse_module(&p, source, &scratch)
	if !parsed {return 0, clone_syntax_error(p.lx.err), false}
	c := Compiler {
		vm     = vm,
		source = name,
	}
	fs := new(Func_State)
	main := Node {
		kind = .Function,
		flag = true,
		line = 0,
		name = "main module",
	}
	c.fs = nil
	open_func(&c, fs, &main)
	fs.is_vararg = true
	emit_abc(&c, .VARARGPREP, 0, 0, 0)
	statements(&c, body)
	close_func(&c)
	if c.failed {return 0, clone_syntax_error(c.err), false}
	// The heap is touched only now, so a failed compile leaves it as it was.
	c.text = intern(vm, source)
	if c.text == 0 {
		return 0,
			Syntax_Error{message = "not enough memory to compile", line = 1, col = 1, len = 1},
			false
	}
	proto = build_proto(&c, fs)
	if proto == 0 {
		return 0,
			Syntax_Error{message = "not enough memory to compile", line = 1, col = 1, len = 1},
			false
	}
	return proto, {}, true
}

@(private = "file")
clone_syntax_error :: proc(e: Syntax_Error) -> Syntax_Error {
	out := e
	out.message = strings.clone(e.message, context.temp_allocator)
	out.hint = strings.clone(e.hint, context.temp_allocator)
	return out
}
