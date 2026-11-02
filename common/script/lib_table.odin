package script

import "core:strings"

// The table library: raw (no __index, __newindex or __len). sort is in the prelude (a
// stable merge sort: it calls the comparator).

TABLE_NATIVES := [?]Native_Spec {
	{name = "table.concat", fn = tab_concat},
	{name = "table.insert", fn = tab_insert},
	{name = "table.move", fn = tab_move},
	{name = "table.pack", fn = tab_pack},
	{name = "table.remove", fn = tab_remove},
	{name = "table.unpack", fn = tab_unpack},
}

open_table :: proc(vm: ^VM) -> bool {
	_, ok := lib_open(vm, "table", TABLE_NATIVES[:])
	return ok
}

@(private = "file")
set_or_fail :: proc(c: ^Native_Call, t: Ref, k: i64, v: Value) -> Native_Status {
	if table_set_int(c.vm, t, k, v) != .Ok {return .Error}
	return .Ok
}

@(private = "file")
tab_concat :: proc(c: ^Native_Call) -> Native_Status {
	t := check_table(c, 1) or_return
	sep := ""
	if arg(c, 2).tag != .Nil {sep = check_string(c, 2) or_return}
	i := opt_int(c, 3, 1) or_return
	j := opt_int(c, 4, table_len(c.vm, t)) or_return
	b := strings.builder_make(context.temp_allocator)
	for k := i; k <= j; k += 1 {
		v := table_get_int(c.vm, t, k)
		if v.tag == .String {
			strings.write_string(&b, value_string(c.vm, v))
		} else if is_number(v) {
			write_number(&b, v)
		} else {
			return raise(c, "invalid value (at index %d) in table for 'concat'", k)
		}
		if k < j {strings.write_string(&b, sep)}
		if strings.builder_len(b) > int(c.vm.limits.string_max) {
			return raise_hint(
				c,
				"a string may hold at most the VM's string limit (1 MiB by default)",
				"string too large",
			)
		}
		if k == max(i64) {break}
	}
	charge(c, i64(strings.builder_len(b) + 63) / 64 + (j - i + 1 if j >= i else 0) / 16)
	return push_string(c, strings.to_string(b))
}

@(private = "file")
tab_insert :: proc(c: ^Native_Call) -> Native_Status {
	t := check_table(c, 1) or_return
	e := table_len(c.vm, t) + 1
	switch arg_count(c) {
	case 2:
		return set_or_fail(c, t, e, arg(c, 2))
	case 3:
		pos := check_int(c, 2) or_return
		if u64(pos) - 1 >= u64(e) {return arg_error(c, 2, "position out of bounds")}
		charge(c, (e - pos) / 16)
		for k := e; k > pos; k -= 1 {
			set_or_fail(c, t, k, table_get_int(c.vm, t, k - 1)) or_return
		}
		return set_or_fail(c, t, pos, arg(c, 3))
	}
	return raise(c, "wrong number of arguments to 'insert'")
}

@(private = "file")
tab_remove :: proc(c: ^Native_Call) -> Native_Status {
	t := check_table(c, 1) or_return
	size := table_len(c.vm, t)
	pos := opt_int(c, 2, size) or_return
	if pos != size && u64(pos) - 1 > u64(size) {
		return arg_error(c, 2, "position out of bounds")
	}
	push_value(c, table_get_int(c.vm, t, pos)) or_return
	charge(c, (size - pos) / 16)
	for ; pos < size; pos += 1 {
		set_or_fail(c, t, pos, table_get_int(c.vm, t, pos + 1)) or_return
	}
	return set_or_fail(c, t, pos, NIL)
}

@(private = "file")
tab_move :: proc(c: ^Native_Call) -> Native_Status {
	a1 := check_table(c, 1) or_return
	f := check_int(c, 2) or_return
	e := check_int(c, 3) or_return
	tpos := check_int(c, 4) or_return
	a2 := a1
	if arg(c, 5).tag != .Nil {a2 = check_table(c, 5) or_return}
	if e >= f {
		if !(f > 0 || e < max(i64) + f) {return arg_error(c, 3, "too many elements to move")}
		n := e - f
		if tpos > max(i64) - n {return arg_error(c, 4, "destination wrap around")}
		charge(c, (n + 1) / 16)
		if tpos > e || tpos <= f || a1 != a2 {
			for k in 0 ..= n {
				set_or_fail(c, a2, tpos + k, table_get_int(c.vm, a1, f + k)) or_return
			}
		} else {
			for k := n; k >= 0; k -= 1 {
				set_or_fail(c, a2, tpos + k, table_get_int(c.vm, a1, f + k)) or_return
			}
		}
	}
	return push_value(c, ref_value(.Table, a2))
}

@(private = "file")
tab_pack :: proc(c: ^Native_Call) -> Native_Status {
	n := arg_count(c)
	t, st := push_table(c, u32(n), 1)
	st or_return
	tr := as_ref(t)
	for i in 1 ..= n {set_or_fail(c, tr, i64(i), arg(c, i)) or_return}
	k := new_string(c.vm, "n")
	if k.tag == .Nil {return .Error}
	if table_set(c.vm, tr, k, int_value(i64(n))) != .Ok {return .Error}
	return .Ok
}

@(private = "file")
tab_unpack :: proc(c: ^Native_Call) -> Native_Status {
	t := check_table(c, 1) or_return
	i := opt_int(c, 2, 1) or_return
	j: i64
	if arg(c, 3).tag == .Nil {
		j = table_len(c.vm, t)
	} else {
		j = check_int(c, 3) or_return
	}
	if i > j {return .Ok}
	n := u64(j) - u64(i)
	if n >= 1 << 16 {return raise(c, "too many results to unpack")}
	for k in 0 ..= n {push_value(c, table_get_int(c.vm, t, i + i64(k))) or_return}
	return .Ok
}
