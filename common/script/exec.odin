package script

import "core:strings"

// The dispatch loop: one procedure running the current thread's top frame until the run
// ends, suspends or errors. It never recurses: calls and metamethods push frames.
// Every instruction boundary is a safe point.

Exec_Result :: enum u8 {
	Done,
	Suspended,
	Error,
}

@(private = "file")
State :: struct {
	th:    ^Thread,
	base:  u32,
	pc:    u32,
	code:  []Instr,
	k:     []Value,
	cl:    Ref,
	p:     ^Proto,
	stack: []Value,
}

@(private = "file")
load :: proc(vm: ^VM, s: ^State) {
	th := s.th
	f := top_frame(vm, th)
	s.base = f.base
	s.pc = f.pc
	s.stack = thread_stack(vm, th)
	s.cl = as_ref(s.stack[f.func])
	cl := obj(vm, s.cl, Closure)
	s.p = obj(vm, cl.proto, Proto)
	s.code = bytes_of(vm, s.p.code, Instr, s.p.code_len)
	s.k = values_of(vm, s.p.consts, s.p.consts_len)
}

@(private = "file")
save :: #force_inline proc(vm: ^VM, s: ^State) {
	top_frame(vm, s.th).pc = s.pc
}

// fail saves the position and raises the pending error: true when it was caught.
@(private = "file")
fail :: proc(vm: ^VM, s: ^State) -> bool {
	save(vm, s)
	if throw(vm) {
		load(vm, s)
		return true
	}
	return false
}

@(private = "file")
is_strnum :: #force_inline proc(v: Value) -> bool {
	return v.tag == .String || v.tag == .Int || v.tag == .Float
}

// concat_run concatenates the n values from register a of the top frame into register a.
concat_run :: proc(vm: ^VM, th: ^Thread, a, n_in: u32) -> Call_Status {
	n := n_in
	for n > 1 {
		f := top_frame(vm, th)
		base := f.base
		stack := thread_stack(vm, th)
		x := stack[base + a + n - 2]
		y := stack[base + a + n - 1]
		if is_strnum(x) && is_strnum(y) {
			cnt: u32 = 2
			for cnt < n && is_strnum(stack[base + a + n - 1 - cnt]) {cnt += 1}
			total := 0
			for i in n - cnt ..< n {
				v := stack[base + a + i]
				total += int(obj(vm, as_ref(v), String).len) if v.tag == .String else 32
			}
			b := strings.builder_make(0, total, context.temp_allocator)
			for i in n - cnt ..< n {
				v := stack[base + a + i]
				if v.tag == .String {
					strings.write_string(&b, value_string(vm, v))
				} else {
					write_number(&b, v)
				}
			}
			if strings.builder_len(b) > int(vm.limits.string_max) {
				rt_error(
					vm,
					"string too large",
					"a string may hold at most the VM's string limit (1 MiB by default)",
				)
				return .Error
			}
			sv := new_string(vm, strings.to_string(b))
			if sv.tag == .Nil {return .Error}
			thread_stack(vm, th)[base + a + n - cnt] = sv
			n -= cnt - 1
			continue
		}
		h := get_mm(vm, x, .Concat)
		if h.tag == .Nil {h = get_mm(vm, y, .Concat)}
		if h.tag == .Nil {
			bad := n - 2 if !is_strnum(x) else n - 1
			v := stack[base + a + bad]
			p := frame_proto(vm, th, f)
			return Call_Status(
				int(
					!rt_errorf(
						vm,
						"",
						"attempt to concatenate a %s value%s",
						type_name(v),
						var_info(vm, p, int(f.pc) - 1, a + bad),
					),
				) *
					0 +
				int(Call_Status.Error),
			)
		}
		return call_mm(vm, th, h, x, y, .Concat, a << 16 | n)
	}
	return .Native_Done
}

@(private = "file")
index_error :: proc(vm: ^VM, s: ^State, v: Value, reg: i32) -> bool {
	info, hint: string
	if reg >= 0 {
		what, name := describe_reg(vm, s.p, int(s.pc) - 1, u32(reg))
		if v.tag == .Nil && what == "global" {
			if m := absent_message(indexed_name(vm, s.p, int(s.pc) - 1, name)); m != "" {
				return rt_error(vm, m)
			}
		}
		if what != "" {
			info = strings.concatenate({" (", what, " '", name, "')"}, context.temp_allocator)
			if v.tag == .Nil {
				save(vm, s)
				hint = nil_name_hint(vm, s.th, top_frame(vm, s.th), what, name)
			}
		}
	}
	return rt_errorf(vm, hint, "attempt to index a %s value%s", type_name(v), info)
}

// get_slow: t[key] with __index, into register dest.
@(private = "file")
get_slow :: proc(vm: ^VM, s: ^State, t, key: Value, dest: u32, reg: i32) -> Call_Status {
	save(vm, s) // a slow path may load the frame again
	cur := t
	for loop in 0 ..< 100 {
		h: Value
		if cur.tag == .Table {
			v := table_get(vm, as_ref(cur), key)
			if v.tag != .Nil {
				s.stack[s.base + dest] = v
				return .Native_Done
			}
			mt := obj(vm, as_ref(cur), Table).meta
			if mt != 0 {h = mt_field(vm, mt, .Index)}
			if h.tag == .Nil {
				s.stack[s.base + dest] = NIL
				return .Native_Done
			}
		} else {
			h = get_mm(vm, cur, .Index)
			if h.tag == .Nil {
				index_error(vm, s, cur, reg if loop == 0 else -1)
				return .Error
			}
		}
		if h.tag == .Function {
			save(vm, s)
			return call_mm(vm, s.th, h, cur, key, .Store, dest)
		}
		cur = h
	}
	rt_error(
		vm,
		"'__index' chain too long; possible loop",
		"an __index table leads back to itself",
	)
	return .Error
}

@(private = "file")
set_result :: proc(vm: ^VM, r: Set_Result) -> bool {
	switch r {
	case .Ok:
		return true
	case .Memory:
		return false
	case .Nil_Key:
		return rt_error(vm, "index is nil", "a table key cannot be nil")
	case .Nan_Key:
		return rt_error(vm, "index is NaN", "a table key cannot be NaN")
	}
	return false
}

// set_slow: t[key] = val with __newindex.
@(private = "file")
set_slow :: proc(vm: ^VM, s: ^State, t, key, val: Value, reg: i32) -> Call_Status {
	save(vm, s) // a slow path may load the frame again
	cur := t
	for loop in 0 ..< 100 {
		h: Value
		if cur.tag == .Table {
			tr := as_ref(cur)
			mt := obj(vm, tr, Table).meta
			if mt != 0 && table_get(vm, tr, key).tag == .Nil {h = mt_field(vm, mt, .Newindex)}
			if h.tag == .Nil {
				if !set_result(vm, table_set(vm, tr, key, val)) {return .Error}
				return .Native_Done
			}
		} else {
			h = get_mm(vm, cur, .Newindex)
			if h.tag == .Nil {
				index_error(vm, s, cur, reg if loop == 0 else -1)
				return .Error
			}
		}
		if h.tag == .Function {
			save(vm, s)
			return call_mm(vm, s.th, h, cur, key, .Discard, 0, val, true)
		}
		cur = h
	}
	rt_error(
		vm,
		"'__newindex' chain too long; possible loop",
		"a __newindex table leads back to itself",
	)
	return .Error
}

@(private = "file")
ARITH_EVENTS := [Arith_Op]Metamethod {
	.Add  = .Add,
	.Sub  = .Sub,
	.Mul  = .Mul,
	.Mod  = .Mod,
	.Pow  = .Pow,
	.Div  = .Div,
	.Idiv = .Idiv,
	.Band = .Metatable,
	.Bor  = .Metatable,
	.Bxor = .Metatable,
	.Shl  = .Metatable,
	.Shr  = .Metatable,
	.Unm  = .Unm,
	.Bnot = .Metatable,
}

// arith_slow: a op b outside the fast paths: errors and metamethods. ra and rb are the
// operands' registers (-1: a constant or immediate).
@(private = "file")
arith_slow :: proc(
	vm: ^VM,
	s: ^State,
	op: Arith_Op,
	a, b: Value,
	dest: u32,
	ra, rb: i32,
) -> Call_Status {
	save(vm, s) // a slow path may load the frame again
	r, st := arith(op, a, b)
	switch st {
	case .Ok:
		s.stack[s.base + dest] = r
		return .Native_Done
	case .Div_Zero:
		rt_error(
			vm,
			"attempt to perform 'n//0'",
			"check that the divisor is not zero before dividing",
		)
		return .Error
	case .Mod_Zero:
		rt_error(
			vm,
			"attempt to perform 'n%%0'",
			"check that the divisor is not zero before taking the remainder",
		)
		return .Error
	case .No_Int:
		bad := rb if is_number(b) && to_integer_ok(a) else ra
		if !to_integer_ok(b) && to_integer_ok(a) {bad = rb}
		rt_errorf(
			vm,
			"use math.floor or math.tointeger to make an integer",
			"number has no integer representation%s",
			reg_info(vm, s, bad),
		)
		return .Error
	case .Not_Number:
	}
	ev := ARITH_EVENTS[op]
	if ev != .Metatable {
		h := get_mm(vm, a, ev)
		if h.tag == .Nil {h = get_mm(vm, b, ev)}
		if h.tag != .Nil {
			save(vm, s)
			return call_mm(vm, s.th, h, a, b, .Store, dest)
		}
	}
	bad, reg := b, rb
	if !is_number(a) {bad, reg = a, ra}
	hint := ""
	if bad.tag == .String {hint = "convert it with tonumber() first"}
	what := "arithmetic"
	#partial switch op {
	case .Band, .Bor, .Bxor, .Shl, .Shr, .Bnot:
		what = "bitwise operation"
	}
	rt_errorf(
		vm,
		hint,
		"attempt to perform %s on a %s value%s",
		what,
		type_name(bad),
		reg_info(vm, s, reg),
	)
	return .Error
}

@(private = "file")
to_integer_ok :: proc(v: Value) -> bool {
	_, ok := to_integer_strict(v)
	return ok
}

@(private = "file")
reg_info :: proc(vm: ^VM, s: ^State, reg: i32) -> string {
	if reg < 0 {return ""}
	return var_info(vm, s.p, int(s.pc) - 1, u32(reg))
}

@(private = "file")
compare_error :: proc(vm: ^VM, a, b: Value) -> bool {
	ta, tb := type_name(a), type_name(b)
	hint := "compare values of one type: convert with tonumber() or tostring() first"
	if ta == tb {return rt_errorf(vm, hint, "attempt to compare two %s values", ta)}
	return rt_errorf(vm, hint, "attempt to compare %s with %s", ta, tb)
}

// less: a < b (or a <= b when le) for numbers and strings; ok false for other types.
@(private = "file")
less :: proc(vm: ^VM, a, b: Value, le: bool) -> (result: bool, ok: bool) {
	if is_number(a) && is_number(b) {
		return num_le(a, b) if le else num_lt(a, b), true
	}
	if a.tag == .String && b.tag == .String {
		x, y := value_string(vm, a), value_string(vm, b)
		return x <= y if le else x < y, true
	}
	return false, false
}

// order_slow: a comparison through __lt or __le, finishing as Compare with k.
@(private = "file")
order_slow :: proc(vm: ^VM, s: ^State, a, b: Value, le: bool, k: u32) -> Call_Status {
	save(vm, s) // a slow path may load the frame again
	ev: Metamethod = .Le if le else .Lt
	h := get_mm(vm, a, ev)
	if h.tag == .Nil {h = get_mm(vm, b, ev)}
	if h.tag == .Nil {
		compare_error(vm, a, b)
		return .Error
	}
	save(vm, s)
	return call_mm(vm, s.th, h, a, b, .Compare, k)
}

@(private = "file")
eq_slow :: proc(
	vm: ^VM,
	s: ^State,
	a, b: Value,
	k: u32,
) -> (
	done: bool,
	eq: bool,
	st: Call_Status,
) {
	save(vm, s) // a slow path may load the frame again
	if raw_equal(a, b) {return true, true, .Native_Done}
	if a.tag != b.tag || (a.tag != .Table && !(a.tag == .Handle && a.kind == b.kind)) {
		return true, false, .Native_Done
	}
	h := get_mm(vm, a, .Eq)
	if h.tag == .Nil {h = get_mm(vm, b, .Eq)}
	if h.tag == .Nil {return true, false, .Native_Done}
	save(vm, s)
	return false, false, call_mm(vm, s.th, h, a, b, .Compare, k)
}

@(private = "file")
imm_value :: #force_inline proc(i: Instr) -> Value {
	sb := arg_sb(i)
	if arg_c(i) != 0 {return float_value(f64(sb))}
	return int_value(i64(sb))
}

@(private = "file")
for_prep :: proc(vm: ^VM, s: ^State, ra: u32) -> (skip: bool, ok: bool) {
	st := s.stack
	init, limit, step := st[ra], st[ra + 1], st[ra + 2]
	if init.tag == .Int && step.tag == .Int {
		i, stp := as_int(init), as_int(step)
		if stp ==
		   0 {return false, rt_error(vm, "'for' step is zero", "a numeric for needs a step other than 0")}
		ilimit: i64
		if limit.tag == .Int {
			ilimit = as_int(limit)
		} else if limit.tag == .Float {
			f := as_float(limit)
			conv: bool
			if stp > 0 {
				ilimit, conv = float_floor_int(f)
			} else {
				ilimit, conv = float_ceil_int(f)
			}
			if !conv || f != f {
				if f > 0 {
					if stp < 0 {return true, true}
					ilimit = max(i64)
				} else {
					if stp > 0 {return true, true}
					ilimit = min(i64)
				}
			}
		} else {
			return false, rt_errorf(vm, "", "'for' limit must be a number")
		}
		if stp > 0 ? i > ilimit : i < ilimit {return true, true}
		count: u64
		if stp > 0 {
			count = (cast(u64)ilimit - cast(u64)i) / cast(u64)stp
		} else {
			count = (cast(u64)i - cast(u64)ilimit) / (cast(u64)(-(stp + 1)) + 1)
		}
		st[ra + 1] = int_value(cast(i64)count)
		st[ra + 3] = init
		return false, true
	}
	if !is_number(init) {return false, rt_error(vm, "'for' initial value must be a number")}
	if !is_number(limit) {return false, rt_error(vm, "'for' limit must be a number")}
	if !is_number(step) {return false, rt_error(vm, "'for' step must be a number")}
	fi, fl, fs := to_float(init), to_float(limit), to_float(step)
	if fs ==
	   0 {return false, rt_error(vm, "'for' step is zero", "a numeric for needs a step other than 0")}
	if fs > 0 ? fl < fi : fi < fl {return true, true}
	st[ra] = float_value(fi)
	st[ra + 1] = float_value(fl)
	st[ra + 2] = float_value(fs)
	st[ra + 3] = float_value(fi)
	return false, true
}

execute :: proc(vm: ^VM) -> Exec_Result {
	s: State
	s.th = obj(vm, vm.current, Thread)
	load(vm, &s)
	for {
		vm.meter -= 1
		if vm.meter < 0 {
			save(vm, &s)
			if vm.budget_is_last {
				// The fault is at the instruction that would run next.
				vm.fault = .Instructions
				s.pc += 1
				if fail(vm, &s) {continue}
				return .Error
			}
			return .Suspended
		}
		if vm.fault != .None {
			if fail(vm, &s) {continue}
			return .Error
		}
		i := s.code[s.pc]
		s.pc += 1
		a := arg_a(i)
		ra := s.base + a
		switch op_of(i) {
		case .MOVE:
			s.stack[ra] = s.stack[s.base + arg_b(i)]
		case .LOADI:
			s.stack[ra] = int_value(i64(arg_sbx(i)))
		case .LOADF:
			s.stack[ra] = float_value(f64(arg_sbx(i)))
		case .LOADK:
			s.stack[ra] = s.k[arg_bx(i)]
		case .LOADKX:
			s.stack[ra] = s.k[arg_ax(s.code[s.pc])]
			s.pc += 1
		case .LOADFALSE:
			s.stack[ra] = FALSE
		case .LFALSESKIP:
			s.stack[ra] = FALSE
			s.pc += 1
		case .LOADTRUE:
			s.stack[ra] = TRUE
		case .LOADNIL:
			for j in 0 ..= arg_b(i) {s.stack[ra + j] = NIL}
		case .GETUPVAL:
			s.stack[ra] = upval_get(vm, closure_upvals(vm, s.cl)[arg_b(i)])
		case .SETUPVAL:
			upval_set(vm, closure_upvals(vm, s.cl)[arg_b(i)], s.stack[ra])
		case .GETGLOBAL:
			env := obj(vm, s.cl, Closure).env
			key := s.k[arg_bx(i)]
			v := table_get_str(vm, env, key)
			if v.tag != .Nil || obj(vm, env, Table).meta == 0 {
				s.stack[ra] = v
				continue
			}
			if get_slow(vm, &s, ref_value(.Table, env), key, a, -1) == .Error {
				if fail(vm, &s) {continue}
				return .Error
			}
			load(vm, &s)
		case .SETGLOBAL:
			env := obj(vm, s.cl, Closure).env
			key := s.k[arg_bx(i)]
			if obj(vm, env, Table).meta == 0 {
				if !set_result(vm, table_set(vm, env, key, s.stack[ra])) {
					if fail(vm, &s) {continue}
					return .Error
				}
				continue
			}
			if set_slow(vm, &s, ref_value(.Table, env), key, s.stack[ra], -1) == .Error {
				if fail(vm, &s) {continue}
				return .Error
			}
			load(vm, &s)
		case .GETTABLE, .GETI, .GETFIELD, .SELF:
			t := s.stack[s.base + arg_b(i)]
			key: Value
			#partial switch op_of(i) {
			case .GETTABLE:
				key = s.stack[s.base + arg_c(i)]
			case .GETI:
				key = int_value(i64(arg_c(i)))
			case .GETFIELD:
				key = s.k[arg_c(i)]
			case .SELF:
				key = s.k[arg_c(i)] if arg_k(i) != 0 else s.stack[s.base + arg_c(i)]
				s.stack[ra + 1] = t
			}
			if t.tag == .Table {
				tr := as_ref(t)
				v: Value
				if key.tag == .String {
					v = table_get_str(vm, tr, key)
				} else if key.tag == .Int {
					v = table_get_int(vm, tr, as_int(key))
				} else {
					v = table_get(vm, tr, key)
				}
				if v.tag != .Nil || obj(vm, tr, Table).meta == 0 {
					s.stack[ra] = v
					continue
				}
			}
			if get_slow(vm, &s, t, key, a, i32(arg_b(i))) == .Error {
				if fail(vm, &s) {continue}
				return .Error
			}
			load(vm, &s)
		case .SETTABLE, .SETI, .SETFIELD:
			t := s.stack[ra]
			key: Value
			#partial switch op_of(i) {
			case .SETTABLE:
				key = s.stack[s.base + arg_b(i)]
			case .SETI:
				key = int_value(i64(arg_b(i)))
			case .SETFIELD:
				key = s.k[arg_b(i)]
			}
			val := s.k[arg_c(i)] if arg_k(i) != 0 else s.stack[s.base + arg_c(i)]
			if t.tag == .Table && obj(vm, as_ref(t), Table).meta == 0 {
				if !set_result(vm, table_set(vm, as_ref(t), key, val)) {
					if fail(vm, &s) {continue}
					return .Error
				}
				continue
			}
			if set_slow(vm, &s, t, key, val, i32(a)) == .Error {
				if fail(vm, &s) {continue}
				return .Error
			}
			load(vm, &s)
		case .NEWTABLE:
			b := arg_b(i)
			c := arg_c(i)
			if arg_k(i) != 0 {c += arg_ax(s.code[s.pc]) * (MAXARG_C + 1)}
			s.pc += 1
			t := table_new(vm, c, (u32(1) << (b - 1)) if b > 0 else 0)
			if t == 0 {
				if fail(vm, &s) {continue}
				return .Error
			}
			s.stack[ra] = ref_value(.Table, t)
		case .ADDI:
			x := s.stack[s.base + arg_b(i)]
			imm := i64(arg_sc(i))
			if x.tag == .Int {
				s.stack[ra] = int_value(as_int(x) + imm)
			} else if x.tag == .Float {
				s.stack[ra] = float_value(as_float(x) + f64(imm))
			} else {
				av, bv := x, int_value(imm)
				rx, ry := i32(arg_b(i)), i32(-1)
				if arg_k(i) != 0 {av, bv, rx, ry = bv, av, ry, rx}
				if arith_slow(vm, &s, .Add, av, bv, a, rx, ry) == .Error {
					if fail(vm, &s) {continue}
					return .Error
				}
				load(vm, &s)
			}
		case .ADDK, .SUBK, .MULK, .MODK, .POWK, .DIVK, .IDIVK, .BANDK, .BORK, .BXORK:
			op := Arith_Op(int(op_of(i)) - int(Op.ADDK))
			x := s.stack[s.base + arg_b(i)]
			y := s.k[arg_c(i)]
			av, bv := x, y
			rx, ry := i32(arg_b(i)), i32(-1)
			if arg_k(i) != 0 {av, bv, rx, ry = bv, av, ry, rx}
			if op == .Add && x.tag == .Int && y.tag == .Int {
				s.stack[ra] = int_value(as_int(x) + as_int(y))
				continue
			}
			r, st := arith(op, av, bv)
			if st == .Ok {
				s.stack[ra] = r
				continue
			}
			if arith_slow(vm, &s, op, av, bv, a, rx, ry) == .Error {
				if fail(vm, &s) {continue}
				return .Error
			}
			load(vm, &s)
		case .SHRI, .SHLI:
			x := s.stack[s.base + arg_b(i)]
			imm := int_value(i64(arg_sc(i)))
			op: Arith_Op = .Shr
			av, bv := x, imm
			rx, ry := i32(arg_b(i)), i32(-1)
			if op_of(i) == .SHLI {
				op = .Shl
				av, bv, rx, ry = imm, x, -1, i32(arg_b(i))
			}
			r, st := arith(op, av, bv)
			if st == .Ok {
				s.stack[ra] = r
				continue
			}
			if arith_slow(vm, &s, op, av, bv, a, rx, ry) == .Error {
				if fail(vm, &s) {continue}
				return .Error
			}
			load(vm, &s)
		case .ADD, .SUB, .MUL, .MOD, .POW, .DIV, .IDIV, .BAND, .BOR, .BXOR, .SHL, .SHR:
			op := Arith_Op(int(op_of(i)) - int(Op.ADD))
			x := s.stack[s.base + arg_b(i)]
			y := s.stack[s.base + arg_c(i)]
			if x.tag == .Int && y.tag == .Int {
				#partial switch op {
				case .Add:
					s.stack[ra] = int_value(as_int(x) + as_int(y))
					continue
				case .Sub:
					s.stack[ra] = int_value(as_int(x) - as_int(y))
					continue
				case .Mul:
					s.stack[ra] = int_value(as_int(x) * as_int(y))
					continue
				}
			}
			r, st := arith(op, x, y)
			if st == .Ok {
				s.stack[ra] = r
				continue
			}
			if arith_slow(vm, &s, op, x, y, a, i32(arg_b(i)), i32(arg_c(i))) == .Error {
				if fail(vm, &s) {continue}
				return .Error
			}
			load(vm, &s)
		case .UNM, .BNOT:
			x := s.stack[s.base + arg_b(i)]
			op: Arith_Op = .Unm if op_of(i) == .UNM else .Bnot
			r, st := arith(op, x, x)
			if st == .Ok {
				s.stack[ra] = r
				continue
			}
			if arith_slow(vm, &s, op, x, x, a, i32(arg_b(i)), i32(arg_b(i))) == .Error {
				if fail(vm, &s) {continue}
				return .Error
			}
			load(vm, &s)
		case .NOT:
			s.stack[ra] = bool_value(is_falsy(s.stack[s.base + arg_b(i)]))
		case .LEN:
			x := s.stack[s.base + arg_b(i)]
			if x.tag == .String {
				s.stack[ra] = int_value(i64(obj(vm, as_ref(x), String).len))
				continue
			}
			h := get_mm(vm, x, .Len)
			if h.tag == .Nil {
				if x.tag == .Table {
					s.stack[ra] = int_value(table_len(vm, as_ref(x)))
					continue
				}
				rt_errorf(
					vm,
					"",
					"attempt to get length of a %s value%s",
					type_name(x),
					reg_info(vm, &s, i32(arg_b(i))),
				)
				if fail(vm, &s) {continue}
				return .Error
			}
			save(vm, &s)
			if call_mm(vm, s.th, h, x, x, .Store, a) == .Error {
				if fail(vm, &s) {continue}
				return .Error
			}
			load(vm, &s)
		case .CONCAT:
			save(vm, &s)
			if concat_run(vm, s.th, a, arg_b(i)) == .Error {
				if fail(vm, &s) {continue}
				return .Error
			}
			load(vm, &s)
		case .CLOSE:
			close_upvals(vm, s.th, ra)
		case .JMP:
			s.pc = u32(i32(s.pc) + arg_sj(i))
		case .EQ, .EQK, .EQI:
			x := s.stack[ra]
			y: Value
			#partial switch op_of(i) {
			case .EQ:
				y = s.stack[s.base + arg_b(i)]
			case .EQK:
				y = s.k[arg_b(i)]
			case .EQI:
				y = imm_value(i)
			}
			k := arg_k(i)
			eq: bool
			if x.tag == y.tag && x.tag != .Table {
				eq = raw_equal(x, y)
			} else {
				done, e, st := eq_slow(vm, &s, x, y, k)
				if !done {
					if st == .Error {
						if fail(vm, &s) {continue}
						return .Error
					}
					load(vm, &s)
					continue
				}
				eq = e
			}
			if eq != (k != 0) {
				s.pc += 1
			} else {
				s.pc = u32(i32(s.pc) + arg_sj(s.code[s.pc]) + 1)
			}
		case .LT, .LE, .LTI, .LEI, .GTI, .GEI:
			x, y: Value
			le := false
			#partial switch op_of(i) {
			case .LT:
				x, y = s.stack[ra], s.stack[s.base + arg_b(i)]
			case .LE:
				x, y, le = s.stack[ra], s.stack[s.base + arg_b(i)], true
			case .LTI:
				x, y = s.stack[ra], imm_value(i)
			case .LEI:
				x, y, le = s.stack[ra], imm_value(i), true
			case .GTI:
				x, y = imm_value(i), s.stack[ra]
			case .GEI:
				x, y, le = imm_value(i), s.stack[ra], true
			}
			k := arg_k(i)
			r: bool
			if x.tag == .Int && y.tag == .Int {
				r = as_int(x) <= as_int(y) if le else as_int(x) < as_int(y)
			} else {
				ok: bool
				r, ok = less(vm, x, y, le)
				if !ok {
					if order_slow(vm, &s, x, y, le, k) == .Error {
						if fail(vm, &s) {continue}
						return .Error
					}
					load(vm, &s)
					continue
				}
			}
			if r != (k != 0) {
				s.pc += 1
			} else {
				s.pc = u32(i32(s.pc) + arg_sj(s.code[s.pc]) + 1)
			}
		case .TEST:
			if is_falsy(s.stack[ra]) == (arg_k(i) != 0) {
				s.pc += 1
			} else {
				s.pc = u32(i32(s.pc) + arg_sj(s.code[s.pc]) + 1)
			}
		case .TESTSET:
			rb := s.stack[s.base + arg_b(i)]
			if is_falsy(rb) == (arg_k(i) != 0) {
				s.pc += 1
			} else {
				s.stack[ra] = rb
				s.pc = u32(i32(s.pc) + arg_sj(s.code[s.pc]) + 1)
			}
		case .CALL:
			b := arg_b(i)
			nargs := b - 1 if b != 0 else s.th.top - (ra + 1)
			if b != 0 {s.th.top = ra + b}
			save(vm, &s)
			switch precall(vm, s.th, ra, nargs, i16(arg_c(i)) - 1, .None, 0) {
			case .Script:
				load(vm, &s)
			case .Native_Done:
				s.stack = thread_stack(vm, s.th)
			case .Error:
				if fail(vm, &s) {continue}
				return .Error
			}
		case .TAILCALL:
			b := arg_b(i)
			nargs := b - 1 if b != 0 else s.th.top - (ra + 1)
			if b != 0 {s.th.top = ra + b}
			save(vm, &s)
			if !resolve_call(vm, s.th, ra, &nargs) {
				if fail(vm, &s) {continue}
				return .Error
			}
			s.stack = thread_stack(vm, s.th)
			callee := as_ref(s.stack[ra])
			if obj_kind(vm, callee) == .Closure {
				fp := top_frame(vm, s.th)
				f := fp^
				res := frame_result_slot(vm, s.th, fp)
				close_upvals(vm, s.th, f.base)
				for j in 0 ..= nargs {s.stack[res + j] = s.stack[ra + j]}
				s.th.frame_count -= 1
				vm.depth -= 1
				if precall(
					   vm,
					   s.th,
					   res,
					   nargs,
					   f.nresults,
					   f.cont,
					   f.cont_arg,
					   f.flags & {.Protected},
				   ) ==
				   .Error {
					if s.th.frame_count == 0 || fail(vm, &s) == false {
						if s.th.frame_count == 0 {
							throw(vm)
						}
						return .Error
					}
					continue
				}
				load(vm, &s)
				continue
			}
			switch precall(vm, s.th, ra, nargs, -1, .None, 0) {
			case .Script:
				load(vm, &s)
			case .Native_Done:
				s.stack = thread_stack(vm, s.th)
			case .Error:
				if fail(vm, &s) {continue}
				return .Error
			}
		case .RETURN, .RETURN0, .RETURN1:
			n: u32
			#partial switch op_of(i) {
			case .RETURN:
				b := arg_b(i)
				n = b - 1 if b != 0 else s.th.top - ra
			case .RETURN1:
				n = 1
			}
			if s.th.open_upvals != 0 {close_upvals(vm, s.th, s.base)}
			switch poscall(vm, s.th, ra, n) {
			case .Continue:
				load(vm, &s)
			case .Host_Done:
				return .Done
			case .Error:
				if fail(vm, &s) {continue}
				return .Error
			}
		case .FORLOOP:
			step := s.stack[ra + 2]
			if step.tag == .Int {
				count := cast(u64)as_int(s.stack[ra + 1])
				if count > 0 {
					s.stack[ra + 1] = int_value(cast(i64)(count - 1))
					idx := int_value(as_int(s.stack[ra]) + as_int(step))
					s.stack[ra] = idx
					s.stack[ra + 3] = idx
					s.pc -= arg_bx(i)
				}
			} else {
				st := as_float(step)
				idx := as_float(s.stack[ra]) + st
				lim := as_float(s.stack[ra + 1])
				if st > 0 ? idx <= lim : lim <= idx {
					s.stack[ra] = float_value(idx)
					s.stack[ra + 3] = float_value(idx)
					s.pc -= arg_bx(i)
				}
			}
		case .FORPREP:
			skip, ok := for_prep(vm, &s, ra)
			if !ok {
				if fail(vm, &s) {continue}
				return .Error
			}
			if skip {s.pc += arg_bx(i) + 1}
		case .TFORPREP:
			s.pc += arg_bx(i)
		case .TFORCALL:
			s.stack[ra + 3] = s.stack[ra]
			s.stack[ra + 4] = s.stack[ra + 1]
			s.stack[ra + 5] = s.stack[ra + 2]
			s.th.top = ra + 6
			save(vm, &s)
			switch precall(vm, s.th, ra + 3, 2, i16(arg_c(i)), .None, 0) {
			case .Script:
				load(vm, &s)
			case .Native_Done:
				s.stack = thread_stack(vm, s.th)
			case .Error:
				if fail(vm, &s) {continue}
				return .Error
			}
		case .TFORLOOP:
			if s.stack[ra + 3].tag != .Nil {
				s.stack[ra + 2] = s.stack[ra + 3]
				s.pc -= arg_bx(i)
			}
		case .SETLIST:
			n := arg_b(i)
			last := arg_c(i)
			if n == 0 {n = s.th.top - ra - 1}
			if arg_k(i) != 0 {
				last += arg_ax(s.code[s.pc]) * (MAXARG_C + 1)
				s.pc += 1
			}
			tr := as_ref(s.stack[ra])
			failed := false
			for j in 1 ..= n {
				if table_set_int(vm, tr, i64(last + j), s.stack[ra + j]) == .Memory {
					failed = true
					break
				}
				s.stack = thread_stack(vm, s.th)
			}
			if failed {
				if fail(vm, &s) {continue}
				return .Error
			}
		case .CLOSURE:
			pr := as_ref(values_of(vm, s.p.protos, s.p.protos_len)[arg_bx(i)])
			np := obj(vm, pr, Proto)
			nup := np.upvals_len
			cr := heap_alloc(vm, .Closure, CLOSURE_UPVALS + int(nup) * 4)
			if cr == 0 {
				if fail(vm, &s) {continue}
				return .Error
			}
			c := obj(vm, cr, Closure)
			c.proto = pr
			c.env = obj(vm, s.cl, Closure).env
			c.nup = u16(nup)
			descs := bytes_of(vm, np.upvals, Upval_Desc, nup)
			mine := closure_upvals(vm, s.cl)
			failed := false
			for d, j in descs {
				u: Ref
				if d.instack != 0 {
					u = find_upval(vm, vm.current, s.base + u32(d.index))
					if u == 0 {
						failed = true
						break
					}
				} else {
					u = mine[d.index]
				}
				closure_upvals(vm, cr)[j] = u
			}
			if failed {
				if fail(vm, &s) {continue}
				return .Error
			}
			s.stack[ra] = ref_value(.Function, cr)
		case .VARARG:
			f := top_frame(vm, s.th)
			nextra := u32(f.nvarargs)
			src := f.func - nextra
			c := arg_c(i)
			if c == 0 {
				if !ensure_stack(vm, s.th, ra + nextra + EXTRA_STACK) {
					if fail(vm, &s) {continue}
					return .Error
				}
				s.stack = thread_stack(vm, s.th)
				for j in 0 ..< nextra {s.stack[ra + j] = s.stack[src + j]}
				s.th.top = ra + nextra
			} else {
				for j in 0 ..< c - 1 {s.stack[ra + j] = s.stack[src + j] if j < nextra else NIL}
			}
		case .VARARGPREP, .EXTRAARG:
		// The arguments were placed by the call.
		}
	}
}
