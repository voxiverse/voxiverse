package script

// Lua 5.4's patterns (lstrlib.c's matcher, ported): classes %a %c %d %g %l %p %s %u %w
// %x and their negations (ASCII only), sets, %b, %f, anchors, up to 32 captures and
// position captures. Matching recursion is bounded at 200 and its steps are counted:
// past PATTERN_STEPS_MAX a call fails with "pattern too complex".

PATTERN_MAX_CAPTURES :: 32
PATTERN_MAX_DEPTH :: 200
PATTERN_STEPS_MAX :: 1_000_000
CAP_UNFINISHED :: -1
CAP_POSITION :: -2
L_ESC :: '%'

Match_State :: struct {
	src:     string,
	pat:     string,
	level:   int,
	depth:   int,
	steps:   int,
	err:     string, // set: the match failed with this error
	capture: [PATTERN_MAX_CAPTURES]struct {
		init: int,
		len:  int,
	},
}

match_state_init :: proc(ms: ^Match_State, src, pat: string) {
	ms.src = src
	ms.pat = pat
	ms.level = 0
	ms.depth = 0
	ms.err = ""
}

@(private = "file")
fail_ms :: proc(ms: ^Match_State, msg: string) -> int {
	if ms.err == "" {ms.err = msg}
	return -1
}

@(private = "file")
class_end :: proc(ms: ^Match_State, p_in: int) -> int {
	p := p_in
	pat := ms.pat
	c := pat[p]
	p += 1
	if c == L_ESC {
		if p >= len(pat) {return fail_ms(ms, "malformed pattern (ends with '%')")}
		return p + 1
	}
	if c == '[' {
		if p < len(pat) && pat[p] == '^' {p += 1}
		for {
			// Look for a ']'.
			if p >= len(pat) {return fail_ms(ms, "malformed pattern (missing ']')")}
			cc := pat[p]
			p += 1
			if cc == L_ESC && p < len(pat) {
				p += 1
			}
			if p < len(pat) && pat[p] == ']' {break}
			if p >= len(pat) {return fail_ms(ms, "malformed pattern (missing ']')")}
		}
		return p + 1
	}
	return p
}

@(private = "file")
is_alpha :: #force_inline proc(c: u8) -> bool {return (c | 0x20) >= 'a' && (c | 0x20) <= 'z'}
@(private = "file")
is_digit :: #force_inline proc(c: u8) -> bool {return c >= '0' && c <= '9'}
@(private = "file")
is_lower :: #force_inline proc(c: u8) -> bool {return c >= 'a' && c <= 'z'}
@(private = "file")
is_upper :: #force_inline proc(c: u8) -> bool {return c >= 'A' && c <= 'Z'}
@(private = "file")
is_cntrl :: #force_inline proc(c: u8) -> bool {return c < 32 || c == 127}
@(private = "file")
is_graph :: #force_inline proc(c: u8) -> bool {return c > 32 && c < 127}
@(private = "file")
is_punct :: #force_inline proc(c: u8) -> bool {return is_graph(c) && !is_alpha(c) && !is_digit(c)}
@(private = "file")
is_xdigit :: #force_inline proc(c: u8) -> bool {
	return is_digit(c) || ((c | 0x20) >= 'a' && (c | 0x20) <= 'f')
}
@(private = "file")
is_cspace :: #force_inline proc(c: u8) -> bool {return c == ' ' || (c >= '\t' && c <= '\r')}

@(private = "file")
single_class :: proc(c: u8, cl: u8) -> bool {
	res: bool
	switch cl | 0x20 {
	case 'a':
		res = is_alpha(c)
	case 'c':
		res = is_cntrl(c)
	case 'd':
		res = is_digit(c)
	case 'g':
		res = is_graph(c)
	case 'l':
		res = is_lower(c)
	case 'p':
		res = is_punct(c)
	case 's':
		res = is_cspace(c)
	case 'u':
		res = is_upper(c)
	case 'w':
		res = is_alpha(c) || is_digit(c)
	case 'x':
		res = is_xdigit(c)
	case:
		return cl == c
	}
	if is_upper(cl) {return !res}
	return res
}

// match_class_set: c against the set pat[p..ec] ('[' at p, ']' at ec - 1).
@(private = "file")
match_set :: proc(ms: ^Match_State, c: u8, p_in, ec: int) -> bool {
	pat := ms.pat
	p := p_in + 1
	sig := true
	if pat[p] == '^' {
		sig = false
		p += 1
	}
	for p < ec - 1 {
		if pat[p] == L_ESC {
			p += 1
			if single_class(c, pat[p]) {return sig}
			p += 1
		} else if p + 2 < ec - 1 && pat[p + 1] == '-' {
			if pat[p] <= c && c <= pat[p + 2] {return sig}
			p += 3
		} else {
			if pat[p] == c {return sig}
			p += 1
		}
	}
	return !sig
}

@(private = "file")
single_match :: proc(ms: ^Match_State, s, p, ep: int) -> bool {
	if s >= len(ms.src) {return false}
	c := ms.src[s]
	switch ms.pat[p] {
	case '.':
		return true
	case L_ESC:
		return single_class(c, ms.pat[p + 1])
	case '[':
		return match_set(ms, c, p, ep)
	}
	return ms.pat[p] == c
}

@(private = "file")
match_balance :: proc(ms: ^Match_State, s_in, p: int) -> int {
	if p + 1 >= len(ms.pat) {return fail_ms(ms, "malformed pattern (missing arguments to '%b')")}
	s := s_in
	if s >= len(ms.src) || ms.src[s] != ms.pat[p] {return -1}
	b := ms.pat[p]
	e := ms.pat[p + 1]
	cont := 1
	s += 1
	for s < len(ms.src) {
		ms.steps += 1
		c := ms.src[s]
		if c == e {
			cont -= 1
			if cont == 0 {return s + 1}
		} else if c == b {
			cont += 1
		}
		s += 1
	}
	return -1
}

@(private = "file")
max_expand :: proc(ms: ^Match_State, s, p, ep: int) -> int {
	i := 0
	for single_match(ms, s + i, p, ep) {i += 1}
	ms.steps += i
	for i >= 0 {
		res := do_match(ms, s + i, ep + 1)
		if res != -1 || ms.err != "" {return res}
		i -= 1
	}
	return -1
}

@(private = "file")
min_expand :: proc(ms: ^Match_State, s_in, p, ep: int) -> int {
	s := s_in
	for {
		res := do_match(ms, s, ep + 1)
		if res != -1 || ms.err != "" {return res}
		if single_match(ms, s, p, ep) {
			s += 1
		} else {
			return -1
		}
	}
}

@(private = "file")
start_capture :: proc(ms: ^Match_State, s, p, what: int) -> int {
	if ms.level >= PATTERN_MAX_CAPTURES {return fail_ms(ms, "too many captures")}
	ms.capture[ms.level].init = s
	ms.capture[ms.level].len = what
	ms.level += 1
	res := do_match(ms, s, p)
	if res == -1 {ms.level -= 1}
	return res
}

@(private = "file")
end_capture :: proc(ms: ^Match_State, s, p: int) -> int {
	l := capture_to_close(ms)
	if l < 0 {return -1}
	ms.capture[l].len = s - ms.capture[l].init
	res := do_match(ms, s, p)
	if res == -1 {ms.capture[l].len = CAP_UNFINISHED}
	return res
}

@(private = "file")
capture_to_close :: proc(ms: ^Match_State) -> int {
	for l := ms.level - 1; l >= 0; l -= 1 {
		if ms.capture[l].len == CAP_UNFINISHED {return l}
	}
	return fail_ms(ms, "invalid pattern capture")
}

@(private = "file")
check_capture :: proc(ms: ^Match_State, l_in: u8) -> int {
	l := int(l_in) - '1'
	if l < 0 || l >= ms.level || ms.capture[l].len == CAP_UNFINISHED {
		return fail_ms(ms, "invalid capture index")
	}
	return l
}

@(private = "file")
match_capture :: proc(ms: ^Match_State, s: int, l_in: u8) -> int {
	l := check_capture(ms, l_in)
	if l < 0 {return -1}
	ln := ms.capture[l].len
	init := ms.capture[l].init
	if len(ms.src) - s >= ln && ms.src[init:init + ln] == ms.src[s:s + ln] {
		ms.steps += ln
		return s + ln
	}
	return -1
}

// do_match: the end of a match of pat[p..] at src[s..], or -1.
do_match :: proc(ms: ^Match_State, s_in, p_in: int) -> int {
	ms.depth += 1
	defer ms.depth -= 1
	if ms.depth > PATTERN_MAX_DEPTH {return fail_ms(ms, "pattern too complex")}
	s := s_in
	p := p_in
	for {
		ms.steps += 1
		if ms.steps > PATTERN_STEPS_MAX {return fail_ms(ms, "pattern too complex")}
		if ms.err != "" {return -1}
		if p >= len(ms.pat) {return s}
		switch ms.pat[p] {
		case '(':
			if p + 1 < len(ms.pat) && ms.pat[p + 1] == ')' {
				return start_capture(ms, s, p + 2, CAP_POSITION)
			}
			return start_capture(ms, s, p + 1, CAP_UNFINISHED)
		case ')':
			return end_capture(ms, s, p + 1)
		case '$':
			if p + 1 == len(ms.pat) {
				return s if s == len(ms.src) else -1
			}
		case L_ESC:
			if p + 1 < len(ms.pat) {
				switch ms.pat[p + 1] {
				case 'b':
					s = match_balance(ms, s, p + 2)
					if s != -1 {
						p += 4
						continue
					}
					return -1
				case 'f':
					p += 2
					if p >= len(ms.pat) || ms.pat[p] != '[' {
						return fail_ms(ms, "missing '[' after '%f' in pattern")
					}
					ep := class_end(ms, p)
					if ep < 0 {return -1}
					prev: u8 = 0 if s == 0 else ms.src[s - 1]
					cur: u8 = ms.src[s] if s < len(ms.src) else 0
					if !match_set(ms, prev, p, ep) && match_set(ms, cur, p, ep) {
						p = ep
						continue
					}
					return -1
				case '0' ..= '9':
					s = match_capture(ms, s, ms.pat[p + 1])
					if s == -1 {return -1}
					p += 2
					continue
				}
			}
		}
		// The default: a single char class, maybe with a repetition.
		ep := class_end(ms, p)
		if ep < 0 {return -1}
		epc: u8 = ms.pat[ep] if ep < len(ms.pat) else 0
		if !single_match(ms, s, p, ep) {
			if epc == '*' || epc == '?' || epc == '-' {
				p = ep + 1
				continue
			}
			return -1
		}
		switch epc {
		case '?':
			res := do_match(ms, s + 1, ep + 1)
			if res != -1 || ms.err != "" {return res}
			p = ep + 1
			continue
		case '+':
			return max_expand(ms, s + 1, p, ep)
		case '*':
			return max_expand(ms, s, p, ep)
		case '-':
			return min_expand(ms, s, p, ep)
		}
		s += 1
		p = ep
	}
}

// capture_value: capture i of a match from s to e (the whole match when there are none).
capture_value :: proc(c: ^Native_Call, ms: ^Match_State, i, s, e: int) -> Native_Status {
	if i >= ms.level {
		if i == 0 {return push_string(c, ms.src[s:e])}
		return raise(c, "invalid capture index %%%d", i + 1)
	}
	ln := ms.capture[i].len
	init := ms.capture[i].init
	if ln == CAP_UNFINISHED {return raise(c, "unfinished capture")}
	if ln == CAP_POSITION {return push_int(c, i64(init) + 1)}
	return push_string(c, ms.src[init:init + ln])
}

// push_captures pushes the captures (or the whole match); their count.
push_captures :: proc(
	c: ^Native_Call,
	ms: ^Match_State,
	s, e: int,
	whole: bool,
) -> (
	count: int,
	st: Native_Status,
) {
	n := ms.level
	if n == 0 && whole {n = 1}
	for i in 0 ..< n {capture_value(c, ms, i, s, e) or_return}
	return n, .Ok
}

// pattern_charge: the matcher's steps, one unit per 16, and its error.
pattern_finish :: proc(c: ^Native_Call, ms: ^Match_State) -> Native_Status {
	charge(c, i64(ms.steps / 16))
	if ms.err != "" {return raise(c, "%s", ms.err)}
	return .Ok
}
