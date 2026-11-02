package script

import "core:strings"

// The string library. format, gsub with a function and gmatch are in the prelude (they
// call script code); they use the private natives named "string.<fn>/..." here, whose
// errors name the public function.

STRING_NATIVES := [?]Native_Spec {
	{name = "string.byte", fn = str_byte},
	{name = "string.char", fn = str_char},
	{name = "string.find", fn = str_find},
	{name = "string.len", fn = str_len},
	{name = "string.lower", fn = str_lower},
	{name = "string.match", fn = str_match},
	{name = "string.rep", fn = str_rep},
	{name = "string.reverse", fn = str_reverse},
	{name = "string.sub", fn = str_sub},
	{name = "string.upper", fn = str_upper},
	{name = "string.split", fn = str_split},
	{name = "string.gsub/raw", fn = str_gsub_raw},
	{name = "string.gsub/find", fn = str_find_from},
	{name = "string.format/scan", fn = str_format_scan},
	{name = "string.format/raw", fn = str_format_raw},
}

open_string :: proc(vm: ^VM) -> bool {
	t := lib_open(vm, "string", STRING_NATIVES[:]) or_return
	meta := ref_value(.Table, vm.string_meta)
	lib_bind(vm, meta, "__index", t) or_return
	pt := ref_value(.Table, vm.prelude_table)
	lib_bind(vm, pt, "gsub_raw", native_value(vm, "string.gsub/raw")) or_return
	lib_bind(vm, pt, "find_from", native_value(vm, "string.gsub/find")) or_return
	lib_bind(vm, pt, "format_scan", native_value(vm, "string.format/scan")) or_return
	lib_bind(vm, pt, "format_raw", native_value(vm, "string.format/raw")) or_return
	return true
}

// pos_start: Lua 5.4's posrelatI, a start position in 1..len+1 (or beyond).
pos_start :: proc(pos: i64, n: int) -> i64 {
	if pos > 0 {return pos}
	if pos == 0 {return 1}
	if pos < -i64(n) {return 1}
	return i64(n) + pos + 1
}

// pos_end: Lua 5.4's getendpos, an end position in 0..len.
pos_end :: proc(pos: i64, n: int) -> i64 {
	if pos > i64(n) {return i64(n)}
	if pos >= 0 {return pos}
	if pos < -i64(n) {return 0}
	return i64(n) + pos + 1
}

charge_bytes :: #force_inline proc(c: ^Native_Call, n: int) {
	charge(c, i64(n + 63) / 64)
}

@(private = "file")
str_len :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	return push_int(c, i64(len(s)))
}

@(private = "file")
str_sub :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	i := opt_int(c, 2, 1) or_return
	j := opt_int(c, 3, -1) or_return
	start := pos_start(i, len(s))
	end := pos_end(j, len(s))
	if start > end {return push_string(c, "")}
	charge_bytes(c, int(end - start + 1))
	return push_string(c, s[start - 1:end])
}

@(private = "file")
str_byte :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	i := opt_int(c, 2, 1) or_return
	pi := pos_start(i, len(s))
	j := opt_int(c, 3, pi) or_return
	pe := pos_end(j, len(s))
	if pi > pe {return .Ok}
	if pe - pi >= 1 << 20 {return raise(c, "string slice too long")}
	for k in pi ..= pe {push_int(c, i64(s[k - 1])) or_return}
	return .Ok
}

@(private = "file")
str_char :: proc(c: ^Native_Call) -> Native_Status {
	b := strings.builder_make(0, arg_count(c), context.temp_allocator)
	for i in 1 ..= arg_count(c) {
		v := check_int(c, i) or_return
		if v < 0 || v > 255 {return arg_error(c, i, "value out of range")}
		strings.write_byte(&b, u8(v))
	}
	return push_string(c, strings.to_string(b))
}

@(private = "file")
str_lower :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	out := make([]u8, len(s), context.temp_allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		out[i] = ch + 32 if ch >= 'A' && ch <= 'Z' else ch
	}
	charge_bytes(c, len(s))
	return push_string(c, string(out))
}

@(private = "file")
str_upper :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	out := make([]u8, len(s), context.temp_allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		out[i] = ch - 32 if ch >= 'a' && ch <= 'z' else ch
	}
	charge_bytes(c, len(s))
	return push_string(c, string(out))
}

@(private = "file")
str_reverse :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	out := make([]u8, len(s), context.temp_allocator)
	for i in 0 ..< len(s) {out[i] = s[len(s) - 1 - i]}
	charge_bytes(c, len(s))
	return push_string(c, string(out))
}

@(private = "file")
too_large :: proc(c: ^Native_Call) -> Native_Status {
	return raise_hint(
		c,
		"a string may hold at most the VM's string limit (1 MiB by default)",
		"string too large",
	)
}

@(private = "file")
str_rep :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	n := check_int(c, 2) or_return
	sep := ""
	if arg(c, 3).tag != .Nil {sep = check_string(c, 3) or_return}
	if n <= 0 {return push_string(c, "")}
	unit := i64(len(s) + len(sep))
	if unit > 0 && n > i64(c.vm.limits.string_max) / unit + 1 {return too_large(c)}
	total := unit * n - i64(len(sep))
	if total > i64(c.vm.limits.string_max) {return too_large(c)}
	b := strings.builder_make(0, int(total), context.temp_allocator)
	for k in 0 ..< n {
		if k > 0 {strings.write_string(&b, sep)}
		strings.write_string(&b, s)
	}
	charge_bytes(c, int(total))
	return push_string(c, strings.to_string(b))
}

// split(s [, sep]): the pieces between plain separators (Luau's); an empty separator
// splits into bytes.
@(private = "file")
str_split :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	sep := ","
	if arg(c, 2).tag != .Nil {sep = check_string(c, 2) or_return}
	t, st := push_table(c)
	st or_return
	tr := as_ref(t)
	n: i64 = 0
	charge_bytes(c, len(s))
	add :: proc(c: ^Native_Call, tr: Ref, n: ^i64, piece: string) -> Native_Status {
		v := new_string(c.vm, piece)
		if v.tag == .Nil {return .Error}
		n^ += 1
		if table_set_int(c.vm, tr, n^, v) != .Ok {return .Error}
		return .Ok
	}
	if sep == "" {
		for i in 0 ..< len(s) {add(c, tr, &n, s[i:i + 1]) or_return}
		return .Ok
	}
	rest := s
	for {
		i := strings.index(rest, sep)
		if i < 0 {
			add(c, tr, &n, rest) or_return
			break
		}
		add(c, tr, &n, rest[:i]) or_return
		rest = rest[i + len(sep):]
	}
	return .Ok
}

@(private = "file")
SPECIALS :: "^$*+?.([%-"

@(private = "file")
str_find_aux :: proc(c: ^Native_Call, find: bool) -> Native_Status {
	s := check_string(c, 1) or_return
	p := check_string(c, 2) or_return
	init := pos_start(opt_int(c, 3, 1) or_return, len(s))
	if init > i64(len(s)) + 1 {return push_nil(c)}
	start := int(init - 1)
	if find && (!is_falsy(arg(c, 4)) || strings.index_any(p, SPECIALS) < 0) {
		charge_bytes(c, len(s) - start)
		i := strings.index(s[start:], p)
		if i < 0 {return push_nil(c)}
		push_int(c, i64(start + i + 1)) or_return
		return push_int(c, i64(start + i + len(p)))
	}
	ms: Match_State
	pat := p
	anchor := len(pat) > 0 && pat[0] == '^'
	if anchor {pat = pat[1:]}
	match_state_init(&ms, s, pat)
	s1 := start
	for {
		ms.level = 0
		ms.depth = 0
		e := do_match(&ms, s1, 0)
		if ms.err != "" {break}
		if e != -1 {
			pattern_finish(c, &ms) or_return
			if find {
				push_int(c, i64(s1 + 1)) or_return
				push_int(c, i64(e)) or_return
				push_captures(c, &ms, -1, -1, false) or_return
				return .Ok
			}
			push_captures(c, &ms, s1, e, true) or_return
			return .Ok
		}
		s1 += 1
		if s1 > len(s) || anchor {break}
	}
	pattern_finish(c, &ms) or_return
	return push_nil(c)
}

@(private = "file")
str_find :: proc(c: ^Native_Call) -> Native_Status {return str_find_aux(c, true)}
@(private = "file")
str_match :: proc(c: ^Native_Call) -> Native_Status {return str_find_aux(c, false)}

// find_from(s, p, src, last, anchor): the first match at or after src whose end is not
// last: its start, its end + 1 and its captures (the whole match when there are none);
// nil when there is none. gsub with a function and gmatch loop on it.
@(private = "file")
str_find_from :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	p := check_string(c, 2) or_return
	src := int(check_int(c, 3) or_return) - 1
	last := int(check_int(c, 4) or_return) - 1
	anchor := !is_falsy(arg(c, 5))
	ms: Match_State
	match_state_init(&ms, s, p)
	for src >= 0 && src <= len(s) {
		ms.level = 0
		ms.depth = 0
		e := do_match(&ms, src, 0)
		if ms.err != "" {break}
		if e != -1 && e != last {
			pattern_finish(c, &ms) or_return
			push_int(c, i64(src + 1)) or_return
			push_int(c, i64(e + 1)) or_return
			push_captures(c, &ms, src, e, true) or_return
			return .Ok
		}
		if anchor {break}
		src += 1
	}
	pattern_finish(c, &ms) or_return
	return push_nil(c)
}

// gsub_raw(s, p, repl, n): gsub with a string or table replacement.
@(private = "file")
str_gsub_raw :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	p := check_string(c, 2) or_return
	repl := arg(c, 3)
	if repl.tag != .String && repl.tag != .Table && !is_number(repl) {
		got := "no value" if arg_count(c) < 3 else type_name(repl)
		return arg_error(c, 3, concat_temp("string/function/table expected, got ", got))
	}
	rs: string
	if repl.tag == .String {
		rs = value_string(c.vm, repl)
	} else if is_number(repl) {
		b := strings.builder_make(context.temp_allocator)
		write_number(&b, repl)
		rs = strings.to_string(b)
	}
	max_n := i64(len(s)) + 1
	if arg(c, 4).tag != .Nil {max_n = check_int(c, 4) or_return}
	pat := p
	anchor := len(pat) > 0 && pat[0] == '^'
	if anchor {pat = pat[1:]}
	ms: Match_State
	match_state_init(&ms, s, pat)
	out := strings.builder_make(context.temp_allocator)
	src := 0
	last := -1
	n: i64 = 0
	for n < max_n {
		ms.level = 0
		ms.depth = 0
		e := do_match(&ms, src, 0)
		if ms.err != "" {break}
		if e != -1 && e != last {
			n += 1
			// The replacement.
			if repl.tag == .Table {
				// The key: the first capture, or the whole match.
				key: Value
				if ms.level == 0 {
					key = new_string(c.vm, s[src:e])
				} else {
					ln := ms.capture[0].len
					init := ms.capture[0].init
					if ln == CAP_POSITION {
						key = int_value(i64(init) + 1)
					} else {
						key = new_string(c.vm, s[init:init + ln])
					}
				}
				if key.tag == .Nil {return .Error}
				v := table_get(c.vm, as_ref(repl), key)
				switch {
				case is_falsy(v):
					strings.write_string(&out, s[src:e])
				case v.tag == .String:
					strings.write_string(&out, value_string(c.vm, v))
				case is_number(v):
					write_number(&out, v)
				case:
					return raise(c, "invalid replacement value (a %s)", type_name(v))
				}
			} else {
				for i := 0; i < len(rs); i += 1 {
					ch := rs[i]
					if ch != L_ESC {
						strings.write_byte(&out, ch)
						continue
					}
					i += 1
					if i >= len(rs) {
						return raise(c, "invalid use of '%%' in replacement string")
					}
					d := rs[i]
					switch {
					case d == L_ESC:
						strings.write_byte(&out, L_ESC)
					case d == '0':
						strings.write_string(&out, s[src:e])
					case d >= '1' && d <= '9':
						k := int(d - '1')
						if k >= ms.level {
							if k == 0 {
								strings.write_string(&out, s[src:e])
								continue
							}
							return raise(
								c,
								"invalid capture index %%%d in replacement string",
								k + 1,
							)
						}
						ln := ms.capture[k].len
						init := ms.capture[k].init
						if ln == CAP_POSITION {
							strings.write_int(&out, init + 1)
						} else {
							strings.write_string(&out, s[init:init + ln])
						}
					case:
						return raise(c, "invalid use of '%%' in replacement string")
					}
				}
			}
			src = e
			last = e
		} else if src < len(s) {
			strings.write_byte(&out, s[src])
			src += 1
		} else {
			break
		}
		if strings.builder_len(out) > int(c.vm.limits.string_max) {return too_large(c)}
		if anchor {break}
	}
	pattern_finish(c, &ms) or_return
	if src < len(s) {strings.write_string(&out, s[src:])}
	charge_bytes(c, strings.builder_len(out))
	push_string(c, strings.to_string(out)) or_return
	return push_int(c, n)
}

// Format.

Format_Spec :: struct {
	flags:     string,
	width:     int,
	precision: int, // -1: none
	conv:      u8,
	end:       int, // the index after the conversion letter
}

// format_spec parses the spec after a '%' at i; its error message, or "".
@(private = "file")
format_spec :: proc(f: string, i_in: int) -> (spec: Format_Spec, err: string) {
	i := i_in
	start := i
	for i < len(f) && strings.index_byte("-+ #0", f[i]) >= 0 {i += 1}
	spec.flags = f[start:i]
	if len(spec.flags) > 5 {return spec, "invalid format (repeated flags)"}
	digits := 0
	for i < len(f) && f[i] >= '0' && f[i] <= '9' {
		spec.width = spec.width * 10 + int(f[i] - '0')
		i += 1
		digits += 1
	}
	if digits > 2 {return spec, "invalid conversion (width too long)"}
	spec.precision = -1
	if i < len(f) && f[i] == '.' {
		i += 1
		spec.precision = 0
		digits = 0
		for i < len(f) && f[i] >= '0' && f[i] <= '9' {
			spec.precision = spec.precision * 10 + int(f[i] - '0')
			i += 1
			digits += 1
		}
		if digits > 2 {return spec, "invalid conversion (precision too long)"}
	}
	if i >= len(f) {return spec, "invalid conversion '%' to 'format'"}
	spec.conv = f[i]
	spec.end = i + 1
	switch spec.conv {
	case 'd', 'i', 'c', 'x', 'X', 'o', 'e', 'E', 'f', 'g', 'G', 'q', 's':
	case:
		return spec, concat_temp("invalid conversion '%", f[i_in:i + 1], "' to 'format'")
	}
	return spec, ""
}

// format_scan(fmt): the conversion letters of fmt's arguments, in order.
@(private = "file")
str_format_scan :: proc(c: ^Native_Call) -> Native_Status {
	f := check_string(c, 1) or_return
	kinds := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(f); i += 1 {
		if f[i] != '%' {continue}
		if i + 1 < len(f) && f[i + 1] == '%' {
			i += 1
			continue
		}
		spec, err := format_spec(f, i + 1)
		if err != "" {return raise(c, "%s", err)}
		strings.write_byte(&kinds, spec.conv)
		i = spec.end - 1
	}
	return push_string(c, strings.to_string(kinds))
}

@(private = "file")
has_flag :: #force_inline proc(spec: Format_Spec, f: u8) -> bool {
	return strings.index_byte(spec.flags, f) >= 0
}

// pad writes body to width: left-justified with '-', zeros after the sign and prefix
// with '0' (numbers only), else spaces before.
@(private = "file")
pad :: proc(
	out: ^strings.Builder,
	spec: Format_Spec,
	body: string,
	prefix_len: int,
	zero_ok: bool,
) {
	n := len(body)
	if n >= spec.width {
		strings.write_string(out, body)
		return
	}
	fill := spec.width - n
	if has_flag(spec, '-') {
		strings.write_string(out, body)
		for _ in 0 ..< fill {strings.write_byte(out, ' ')}
	} else if has_flag(spec, '0') && zero_ok {
		strings.write_string(out, body[:prefix_len])
		for _ in 0 ..< fill {strings.write_byte(out, '0')}
		strings.write_string(out, body[prefix_len:])
	} else {
		for _ in 0 ..< fill {strings.write_byte(out, ' ')}
		strings.write_string(out, body)
	}
}

@(private = "file")
write_quoted :: proc(c: ^Native_Call, out: ^strings.Builder, v: Value) -> Native_Status {
	#partial switch v.tag {
	case .String:
		s := value_string(c.vm, v)
		strings.write_byte(out, '"')
		for i in 0 ..< len(s) {
			ch := s[i]
			switch {
			case ch == '"' || ch == '\\' || ch == '\n':
				strings.write_byte(out, '\\')
				strings.write_byte(out, ch)
			case ch == '\r':
				strings.write_string(out, "\\r")
			case ch == 0 || ch < 32 || ch == 127:
				next_digit := i + 1 < len(s) && s[i + 1] >= '0' && s[i + 1] <= '9'
				strings.write_byte(out, '\\')
				if next_digit {
					strings.write_byte(out, '0' + ch / 100)
					strings.write_byte(out, '0' + ch / 10 % 10)
					strings.write_byte(out, '0' + ch % 10)
				} else {
					strings.write_int(out, int(ch))
				}
			case:
				strings.write_byte(out, ch)
			}
		}
		strings.write_byte(out, '"')
	case .Int:
		x := as_int(v)
		if x == min(i64) {
			strings.write_string(out, "0x8000000000000000")
		} else {
			strings.write_i64(out, x)
		}
	case .Float:
		f := as_float(v)
		switch {
		case f != f:
			strings.write_string(out, "(0/0)")
		case f > 1.7976931348623157e308:
			strings.write_string(out, "1e9999")
		case f < -1.7976931348623157e308:
			strings.write_string(out, "-1e9999")
		case:
			start := strings.builder_len(out^)
			write_float_g(out, f, 17)
			s := string(out.buf[start:])
			if strings.index_any(s, ".en") < 0 {strings.write_string(out, ".0")}
		}
	case .Nil, .Bool:
		value_text(c.vm, v, out)
	case:
		return raise(c, "bad argument to 'format' (value has no literal form)")
	}
	return .Ok
}

// format_raw(fmt, ...): string.format once the prelude has made each %s argument a string.
@(private = "file")
str_format_raw :: proc(c: ^Native_Call) -> Native_Status {
	f := check_string(c, 1) or_return
	out := strings.builder_make(context.temp_allocator)
	argi := 1
	for i := 0; i < len(f); i += 1 {
		ch := f[i]
		if ch != '%' {
			strings.write_byte(&out, ch)
			continue
		}
		if i + 1 < len(f) && f[i + 1] == '%' {
			strings.write_byte(&out, '%')
			i += 1
			continue
		}
		spec, err := format_spec(f, i + 1)
		if err != "" {return raise(c, "%s", err)}
		i = spec.end - 1
		argi += 1
		if argi > arg_count(c) {return arg_error(c, argi, "no value")}
		v := arg(c, argi)
		body := strings.builder_make(context.temp_allocator)
		prefix := 0
		zero_ok := true
		switch spec.conv {
		case 'd', 'i':
			x := check_int(c, argi) or_return
			neg := x < 0
			digits := strings.builder_make(context.temp_allocator)
			ux := u64(x) if !neg else u64(0) - u64(x)
			write_u64(&digits, ux, 10, false)
			if neg {
				strings.write_byte(&body, '-')
			} else if has_flag(spec, '+') {
				strings.write_byte(&body, '+')
			} else if has_flag(spec, ' ') {
				strings.write_byte(&body, ' ')
			}
			prefix = strings.builder_len(body)
			ds := strings.to_string(digits)
			if spec.precision >= 0 {
				zero_ok = false
				for _ in len(ds) ..< spec.precision {strings.write_byte(&body, '0')}
				if !(spec.precision == 0 && ux == 0) {strings.write_string(&body, ds)}
			} else {
				strings.write_string(&body, ds)
			}
		case 'x', 'X', 'o':
			x := check_int(c, argi) or_return
			base := 8 if spec.conv == 'o' else 16
			digits := strings.builder_make(context.temp_allocator)
			write_u64(&digits, u64(x), base, spec.conv == 'X')
			ds := strings.to_string(digits)
			if has_flag(spec, '#') && x != 0 {
				if spec.conv == 'o' {
					strings.write_byte(&body, '0')
				} else {
					strings.write_string(&body, "0X" if spec.conv == 'X' else "0x")
					prefix = 2
				}
			}
			if spec.precision >= 0 {
				zero_ok = false
				for _ in len(ds) ..< spec.precision {strings.write_byte(&body, '0')}
				if !(spec.precision == 0 && x == 0) {strings.write_string(&body, ds)}
			} else {
				strings.write_string(&body, ds)
			}
		case 'c':
			x := check_int(c, argi) or_return
			strings.write_byte(&body, u8(x))
			zero_ok = false
		case 'e', 'E', 'f', 'g', 'G':
			nv := check_number(c, argi) or_return
			x := to_float(nv)
			if transmute(u64)x >> 63 == 0 {
				if has_flag(spec, '+') {
					strings.write_byte(&body, '+')
				} else if has_flag(spec, ' ') {
					strings.write_byte(&body, ' ')
				}
			}
			prec := spec.precision if spec.precision >= 0 else 6
			alt := has_flag(spec, '#')
			upper := spec.conv == 'E' || spec.conv == 'G'
			switch spec.conv {
			case 'e', 'E':
				write_float_e(&body, x, prec, upper, alt)
			case 'f':
				write_float_f(&body, x, prec, alt)
			case:
				write_float_g(&body, x, prec if spec.precision != 0 else 1, upper, alt)
			}
			bs := strings.to_string(body)
			if len(bs) > 0 && (bs[0] == '-' || bs[0] == '+' || bs[0] == ' ') {prefix = 1}
			if x != x ||
			   x > 1.7976931348623157e308 ||
			   x < -1.7976931348623157e308 {zero_ok = false}
		case 'q':
			write_quoted(c, &body, v) or_return
			zero_ok = false
		case 's':
			s: string
			if v.tag == .String {
				s = value_string(c.vm, v)
			} else {
				tb := strings.builder_make(context.temp_allocator)
				value_text(c.vm, v, &tb)
				s = strings.to_string(tb)
			}
			if spec.precision >= 0 && spec.precision < len(s) {s = s[:spec.precision]}
			strings.write_string(&body, s)
			zero_ok = false
		}
		pad(&out, spec, strings.to_string(body), prefix, zero_ok)
		if strings.builder_len(out) > int(c.vm.limits.string_max) {return too_large(c)}
	}
	charge_bytes(c, strings.builder_len(out))
	return push_string(c, strings.to_string(out))
}

@(private = "file")
write_u64 :: proc(b: ^strings.Builder, x: u64, base: int, upper: bool) {
	DIGITS_L := "0123456789abcdef"
	DIGITS_U := "0123456789ABCDEF"
	buf: [64]u8
	n := 0
	v := x
	for {
		d := v % u64(base)
		buf[n] = DIGITS_U[d] if upper else DIGITS_L[d]
		n += 1
		v /= u64(base)
		if v == 0 {break}
	}
	for k := n - 1; k >= 0; k -= 1 {strings.write_byte(b, buf[k])}
}
