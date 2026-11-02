package game

// The lexer of the rule language (M49b): one rule statement, condition or expression is a
// short string in a pack's JSON; this cuts it into at most MAX_RULE_TOKENS tokens, each with
// the line and column of its first byte in the pack file, and allocates nothing.
//
// A string may not hold a JSON escape or a control character, so a token's column is the
// string value's column (Json_Value.column, at its opening quote) plus 1 plus its byte
// offset, exactly.

MAX_RULE_TOKENS :: 64

Rule_Token_Kind :: enum u8 {
	Ident, // `self`, `voxiverse:stone`, `potency`: [a-z_][a-z0-9_]*(:[a-z0-9_/]+)?
	Int, // -12, 7
	Dot_Dot, // ..
	L_Paren,
	R_Paren,
	L_Brack,
	R_Brack,
	Comma,
	Dot,
	Plus,
	Minus,
	Assign, // =
	Hash,
	At,
	Dollar,
	Eq, // ==
	Ne, // !=
	Lt,
	Le,
	Gt,
	Ge,
}

Rule_Token :: struct {
	kind:   Rule_Token_Kind,
	text:   string, // a slice of the input
	value:  i32, // Int
	line:   i32,
	column: i32,
}

Rule_Tokens :: struct {
	items: [MAX_RULE_TOKENS]Rule_Token,
	count: int,
}

Lex_Error :: enum u8 {
	None,
	Escapes, // a backslash or a control character
	Too_Long, // over MAX_RULE_TOKENS tokens
	Bad_Character,
	Bad_Number,
}

// rule_lex: text (a JSON string value at line, column, the column of its opening quote) as
// tokens. On an error, `at` is the offending byte's line and column.
rule_lex :: proc(
	text: string,
	line, column: i32,
	out: ^Rule_Tokens,
) -> (
	err: Lex_Error,
	err_line, err_column: i32,
) {
	out.count = 0
	col_of :: #force_inline proc(column: i32, i: int) -> i32 {return column + 1 + i32(i)}
	for c, i in transmute([]u8)text {
		if c == '\\' || c < 0x20 || c == 0x7f {return .Escapes, line, col_of(column, i)}
	}
	n := len(text)
	i := 0
	push :: proc(
		out: ^Rule_Tokens,
		kind: Rule_Token_Kind,
		text: string,
		at: int,
		len_: int,
		line, column: i32,
	) -> bool {
		if out.count == MAX_RULE_TOKENS {return false}
		out.items[out.count] = {
			kind   = kind,
			text   = text[at:at + len_],
			line   = line,
			column = col_of(column, at),
		}
		out.count += 1
		return true
	}
	is_digit :: #force_inline proc(c: u8) -> bool {return c >= '0' && c <= '9'}
	is_start :: #force_inline proc(c: u8) -> bool {return (c >= 'a' && c <= 'z') || c == '_'}
	is_word :: #force_inline proc(c: u8) -> bool {return is_start(c) || is_digit(c)}
	for i < n {
		c := text[i]
		if c == ' ' {i += 1; continue}
		at := i
		kind: Rule_Token_Kind
		length := 1
		switch {
		case is_start(c):
			kind = .Ident
			for i + length < n && is_word(text[i + length]) {length += 1}
			// An optional `:name`, name [a-z0-9_/]+.
			if i + length < n && text[i + length] == ':' {
				j := i + length + 1
				k := j
				for k < n && (is_word(text[k]) || text[k] == '/') {k += 1}
				if k > j {length = k - i}
			}
		case is_digit(c) || (c == '-' && i + 1 < n && is_digit(text[i + 1])):
			kind = .Int
			j := i + 1
			for j < n && is_digit(text[j]) {j += 1}
			length = j - i
			if j - i > 10 {return .Bad_Number, line, col_of(column, i)}
		case c == '.':
			if i + 1 < n && text[i + 1] == '.' {kind, length = .Dot_Dot, 2} else {kind = .Dot}
		case c == '(':
			kind = .L_Paren
		case c == ')':
			kind = .R_Paren
		case c == '[':
			kind = .L_Brack
		case c == ']':
			kind = .R_Brack
		case c == ',':
			kind = .Comma
		case c == '+':
			kind = .Plus
		case c == '-':
			kind = .Minus
		case c == '#':
			kind = .Hash
		case c == '@':
			kind = .At
		case c == '$':
			kind = .Dollar
		case c == '=':
			if i + 1 < n && text[i + 1] == '=' {kind, length = .Eq, 2} else {kind = .Assign}
		case c == '!':
			if i + 1 < n && text[i + 1] == '=' {
				kind, length = .Ne, 2
			} else {
				return .Bad_Character, line, col_of(column, i)
			}
		case c == '<':
			if i + 1 < n && text[i + 1] == '=' {kind, length = .Le, 2} else {kind = .Lt}
		case c == '>':
			if i + 1 < n && text[i + 1] == '=' {kind, length = .Ge, 2} else {kind = .Gt}
		case:
			return .Bad_Character, line, col_of(column, i)
		}
		if !push(out, kind, text, at, length, line, column) {
			return .Too_Long, line, col_of(column, i)
		}
		if kind == .Int {
			v := 0
			neg := text[at] == '-'
			for d in transmute([]u8)text[at + (1 if neg else 0):at + length] {
				v = v * 10 + int(d - '0')
			}
			if v > 1 << 30 {return .Bad_Number, line, col_of(column, at)}
			out.items[out.count - 1].value = i32(-v if neg else v)
		}
		i += length
	}
	return .None, 0, 0
}
