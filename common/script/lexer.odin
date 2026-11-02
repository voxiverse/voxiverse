package script

import "core:strings"
import "core:unicode/utf8"

Tok :: enum u8 {
	EOF,
	Name,
	Int,
	Float,
	String,
	// Reserved words, in the order of KEYWORDS.
	And,
	Break,
	Continue,
	Do,
	Else,
	Elseif,
	End,
	False,
	For,
	Function,
	Goto,
	If,
	In,
	Local,
	Nil,
	Not,
	Or,
	Repeat,
	Return,
	Then,
	True,
	Until,
	While,
	// Symbols.
	Plus,
	Minus,
	Star,
	Slash,
	Dslash,
	Percent,
	Caret,
	Hash,
	Amp,
	Tilde,
	Pipe,
	Shl,
	Shr,
	Concat,
	Dots,
	Eq,
	Ne,
	Le,
	Ge,
	Lt,
	Gt,
	Assign,
	LParen,
	RParen,
	LBrace,
	RBrace,
	LBracket,
	RBracket,
	Semi,
	Colon,
	Dcolon,
	Comma,
	Dot,
	Arrow,
	Question,
	// Compound assignment.
	Plus_Eq,
	Minus_Eq,
	Star_Eq,
	Slash_Eq,
	Dslash_Eq,
	Percent_Eq,
	Caret_Eq,
	Concat_Eq,
	// Written by mistake (other languages); the parser refuses each with a hint.
	Bang_Eq,
	And_And,
	Or_Or,
	Bang,
}

KEYWORDS := [?]string {
	"and",
	"break",
	"continue",
	"do",
	"else",
	"elseif",
	"end",
	"false",
	"for",
	"function",
	"goto",
	"if",
	"in",
	"local",
	"nil",
	"not",
	"or",
	"repeat",
	"return",
	"then",
	"true",
	"until",
	"while",
}

TOKEN_TEXT := [Tok]string {
	.EOF        = "<eof>",
	.Name       = "<name>",
	.Int        = "<integer>",
	.Float      = "<number>",
	.String     = "<string>",
	.And        = "and",
	.Break      = "break",
	.Continue   = "continue",
	.Do         = "do",
	.Else       = "else",
	.Elseif     = "elseif",
	.End        = "end",
	.False      = "false",
	.For        = "for",
	.Function   = "function",
	.Goto       = "goto",
	.If         = "if",
	.In         = "in",
	.Local      = "local",
	.Nil        = "nil",
	.Not        = "not",
	.Or         = "or",
	.Repeat     = "repeat",
	.Return     = "return",
	.Then       = "then",
	.True       = "true",
	.Until      = "until",
	.While      = "while",
	.Plus       = "+",
	.Minus      = "-",
	.Star       = "*",
	.Slash      = "/",
	.Dslash     = "//",
	.Percent    = "%",
	.Caret      = "^",
	.Hash       = "#",
	.Amp        = "&",
	.Tilde      = "~",
	.Pipe       = "|",
	.Shl        = "<<",
	.Shr        = ">>",
	.Concat     = "..",
	.Dots       = "...",
	.Eq         = "==",
	.Ne         = "~=",
	.Le         = "<=",
	.Ge         = ">=",
	.Lt         = "<",
	.Gt         = ">",
	.Assign     = "=",
	.LParen     = "(",
	.RParen     = ")",
	.LBrace     = "{",
	.RBrace     = "}",
	.LBracket   = "[",
	.RBracket   = "]",
	.Semi       = ";",
	.Colon      = ":",
	.Dcolon     = "::",
	.Comma      = ",",
	.Dot        = ".",
	.Arrow      = "->",
	.Question   = "?",
	.Plus_Eq    = "+=",
	.Minus_Eq   = "-=",
	.Star_Eq    = "*=",
	.Slash_Eq   = "/=",
	.Dslash_Eq  = "//=",
	.Percent_Eq = "%=",
	.Caret_Eq   = "^=",
	.Concat_Eq  = "..=",
	.Bang_Eq    = "!=",
	.And_And    = "&&",
	.Or_Or      = "||",
	.Bang       = "!",
}

Token :: struct {
	kind: Tok,
	line: u32,
	col:  u32,
	len:  u32, // bytes of source the token spans on its first line
	text: string, // a name's or string's contents (decoded), or the source of a number
	ival: i64,
	fval: f64,
}

Lexer :: struct {
	src:        string,
	pos:        int,
	line:       u32,
	line_start: int,
	scratch:    ^strings.Builder,
	err:        Syntax_Error,
	failed:     bool,
}

// Syntax_Error: the first one only.
Syntax_Error :: struct {
	message: string,
	hint:    string,
	line:    u32,
	col:     u32,
	len:     u32,
}

lexer_init :: proc(lx: ^Lexer, src: string, scratch: ^strings.Builder) {
	lx^ = Lexer {
		src     = src,
		line    = 1,
		scratch = scratch,
	}
	// A first line starting with '#' (a shebang) is skipped, as Lua does.
	if len(src) > 0 && src[0] == '#' {
		for lx.pos < len(src) && src[lx.pos] != '\n' {lx.pos += 1}
	}
}

@(private = "file")
peek :: #force_inline proc(lx: ^Lexer, off := 0) -> u8 {
	p := lx.pos + off
	return lx.src[p] if p < len(lx.src) else 0
}

@(private = "file")
newline :: proc(lx: ^Lexer) {
	c := lx.src[lx.pos]
	lx.pos += 1
	if lx.pos < len(lx.src) &&
	   (lx.src[lx.pos] == '\n' || lx.src[lx.pos] == '\r') &&
	   lx.src[lx.pos] != c {
		lx.pos += 1
	}
	lx.line += 1
	lx.line_start = lx.pos
}

lex_fail :: proc(lx: ^Lexer, line, col, n: u32, message: string, hint := "") {
	if lx.failed {return}
	lx.failed = true
	lx.err = Syntax_Error {
		message = message,
		hint    = hint,
		line    = line,
		col     = col,
		len     = max(n, 1),
	}
}

@(private = "file")
is_name_start :: #force_inline proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private = "file")
is_name_char :: #force_inline proc(c: u8) -> bool {
	return is_name_start(c) || (c >= '0' && c <= '9')
}

// long_bracket: the level of a long bracket at pos ('[' '='* '['), or -1.
@(private = "file")
long_bracket :: proc(lx: ^Lexer) -> int {
	if peek(lx) != '[' {return -1}
	n := 1
	for peek(lx, n) == '=' {n += 1}
	if peek(lx, n) == '[' {return n - 1}
	return -1
}

// read_long: a long string or comment's contents after its opening bracket.
@(private = "file")
read_long :: proc(lx: ^Lexer, level: int, is_comment: bool, line, col: u32) -> (string, bool) {
	lx.pos += level + 2
	if lx.pos < len(lx.src) && (lx.src[lx.pos] == '\n' || lx.src[lx.pos] == '\r') {newline(lx)}
	strings.builder_reset(lx.scratch)
	for {
		if lx.pos >= len(lx.src) {
			what := "comment" if is_comment else "long string"
			lex_fail(
				lx,
				line,
				col,
				2,
				strings.concatenate(
					{"unfinished ", what, " (begun on line ", line_text(line), ")"},
				),
				"close it with ']" + "]' (with as many '=' as it opened with)",
			)
			return "", false
		}
		c := lx.src[lx.pos]
		if c == ']' {
			n := 1
			for peek(lx, n) == '=' {n += 1}
			if n - 1 == level && peek(lx, n) == ']' {
				lx.pos += n + 1
				return strings.clone(strings.to_string(lx.scratch^)), true
			}
		}
		if c == '\n' || c == '\r' {
			newline(lx)
			strings.write_byte(lx.scratch, '\n')
			continue
		}
		strings.write_byte(lx.scratch, c)
		lx.pos += 1
	}
}

line_text :: proc(line: u32) -> string {
	b := strings.builder_make()
	strings.write_uint(&b, uint(line))
	return strings.to_string(b)
}

@(private = "file")
hex_digit :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a') + 10
	case 'A' ..= 'F':
		return int(c - 'A') + 10
	}
	return -1
}

@(private = "file")
read_string :: proc(lx: ^Lexer, line, col: u32) -> (string, bool) {
	quote := lx.src[lx.pos]
	lx.pos += 1
	strings.builder_reset(lx.scratch)
	unterminated :: proc(lx: ^Lexer, line, col: u32) -> (string, bool) {
		lex_fail(
			lx,
			line,
			col,
			1,
			strings.concatenate({"unfinished string (begun on line ", line_text(line), ")"}),
			"close the string with the quote it began with, or use [[...]] for text over several lines",
		)
		return "", false
	}
	for {
		if lx.pos >= len(lx.src) {return unterminated(lx, line, col)}
		c := lx.src[lx.pos]
		if c == quote {
			lx.pos += 1
			return strings.clone(strings.to_string(lx.scratch^)), true
		}
		if c == '\n' || c == '\r' {return unterminated(lx, line, col)}
		if c != '\\' {
			strings.write_byte(lx.scratch, c)
			lx.pos += 1
			continue
		}
		esc_col := u32(lx.pos - lx.line_start + 1)
		lx.pos += 1
		e := peek(lx)
		switch e {
		case 'a':
			strings.write_byte(lx.scratch, 7); lx.pos += 1
		case 'b':
			strings.write_byte(lx.scratch, 8); lx.pos += 1
		case 'f':
			strings.write_byte(lx.scratch, 12); lx.pos += 1
		case 'n':
			strings.write_byte(lx.scratch, '\n'); lx.pos += 1
		case 'r':
			strings.write_byte(lx.scratch, '\r'); lx.pos += 1
		case 't':
			strings.write_byte(lx.scratch, '\t'); lx.pos += 1
		case 'v':
			strings.write_byte(lx.scratch, 11); lx.pos += 1
		case '\\', '"', '\'':
			strings.write_byte(lx.scratch, e); lx.pos += 1
		case '\n', '\r':
			strings.write_byte(lx.scratch, '\n')
			newline(lx)
		case 'z':
			lx.pos += 1
			for lx.pos < len(lx.src) {
				d := lx.src[lx.pos]
				if d == '\n' || d == '\r' {
					newline(lx)
				} else if d == ' ' || d == '\t' || d == '\f' || d == '\v' {
					lx.pos += 1
				} else {
					break
				}
			}
		case 'x':
			h1, h2 := hex_digit(peek(lx, 1)), hex_digit(peek(lx, 2))
			if h1 < 0 || h2 < 0 {
				lex_fail(
					lx,
					lx.line,
					esc_col,
					2,
					"hexadecimal digit expected in '\\x' escape",
					"write two hex digits: '\\x41' is 'A'",
				)
				return "", false
			}
			strings.write_byte(lx.scratch, u8(h1 * 16 + h2))
			lx.pos += 3
		case 'u':
			if peek(lx, 1) != '{' {
				lex_fail(
					lx,
					lx.line,
					esc_col,
					2,
					"missing '{' in '\\u{xxxx}' escape",
					"write the code point in braces: '\\u{48}'",
				)
				return "", false
			}
			lx.pos += 2
			cp := 0
			digits := 0
			for hex_digit(peek(lx)) >= 0 {
				cp = cp * 16 + hex_digit(peek(lx))
				digits += 1
				lx.pos += 1
				if cp > 0x10FFFF {
					lex_fail(
						lx,
						lx.line,
						esc_col,
						2,
						"UTF-8 value too large in '\\u' escape",
						"code points go up to U+10FFFF",
					)
					return "", false
				}
			}
			if digits == 0 || peek(lx) != '}' {
				lex_fail(
					lx,
					lx.line,
					esc_col,
					2,
					"malformed '\\u{xxxx}' escape",
					"write hex digits in braces: '\\u{48}'",
				)
				return "", false
			}
			lx.pos += 1
			buf, n := utf8.encode_rune(rune(cp))
			strings.write_bytes(lx.scratch, buf[:n])
		case '0' ..= '9':
			v := 0
			for i := 0; i < 3 && peek(lx) >= '0' && peek(lx) <= '9'; i += 1 {
				v = v * 10 + int(peek(lx) - '0')
				lx.pos += 1
			}
			if v > 255 {
				lex_fail(
					lx,
					lx.line,
					esc_col,
					4,
					"decimal escape too large",
					"a '\\ddd' escape is a byte, 0 to 255",
				)
				return "", false
			}
			strings.write_byte(lx.scratch, u8(v))
		case:
			if lx.pos >= len(lx.src) {return unterminated(lx, line, col)}
			lex_fail(
				lx,
				lx.line,
				esc_col,
				2,
				strings.concatenate(
					{"invalid escape sequence '\\", lx.src[lx.pos:lx.pos + 1], "'"},
				),
				"to write a backslash, double it: '\\\\'",
			)
			return "", false
		}
	}
}

@(private = "file")
read_number :: proc(lx: ^Lexer, tok: ^Token) -> bool {
	start := lx.pos
	hex := peek(lx) == '0' && (peek(lx, 1) == 'x' || peek(lx, 1) == 'X')
	if hex {lx.pos += 2}
	for lx.pos < len(lx.src) {
		c := lx.src[lx.pos]
		exp := (c == 'p' || c == 'P') if hex else (c == 'e' || c == 'E')
		if exp && (peek(lx, 1) == '+' || peek(lx, 1) == '-') {
			lx.pos += 2
		} else if is_name_char(c) || c == '.' {
			lx.pos += 1
		} else {
			break
		}
	}
	text := lx.src[start:lx.pos]
	tok.text = text
	tok.len = u32(len(text))
	if hex && strings.index_any(text, ".pP") >= 0 {
		lex_fail(
			lx,
			tok.line,
			tok.col,
			tok.len,
			strings.concatenate({"hex float literals are not supported: '", text, "'"}),
			"write the number in decimal",
		)
		return false
	}
	v, ok := parse_number(text, false)
	if !ok {
		hint := "a number is digits with an optional '.', exponent ('1e3') or '0x' prefix"
		if strings.contains(
			text,
			"_",
		) {hint = "numbers cannot contain '_': write the digits together"}
		if strings.contains(
			text,
			"..",
		) {hint = "to concatenate a number, put spaces around '..': 1 .. 2"}
		lex_fail(
			lx,
			tok.line,
			tok.col,
			tok.len,
			strings.concatenate({"malformed number near '", text, "'"}),
			hint,
		)
		return false
	}
	if v.tag == .Int {
		tok.kind = .Int
		tok.ival = as_int(v)
	} else {
		tok.kind = .Float
		tok.fval = as_float(v)
	}
	return true
}

// lex_next reads the next token; on an error lx.failed is set and EOF returned.
lex_next :: proc(lx: ^Lexer) -> (tok: Token) {
	for {
		// Space and comments.
		for lx.pos < len(lx.src) {
			c := lx.src[lx.pos]
			if c == '\n' || c == '\r' {
				newline(lx)
			} else if c == ' ' || c == '\t' || c == '\f' || c == '\v' {
				lx.pos += 1
			} else {
				break
			}
		}
		if peek(lx) == '-' && peek(lx, 1) == '-' {
			line, col := lx.line, u32(lx.pos - lx.line_start + 1)
			lx.pos += 2
			if level := long_bracket(lx); level >= 0 {
				if _, ok := read_long(lx, level, true, line, col);
				   !ok {return Token{kind = .EOF, line = lx.line}}
			} else {
				for lx.pos < len(lx.src) &&
				    lx.src[lx.pos] != '\n' &&
				    lx.src[lx.pos] != '\r' {lx.pos += 1}
			}
			continue
		}
		break
	}
	tok.line = lx.line
	tok.col = u32(lx.pos - lx.line_start + 1)
	tok.len = 1
	if lx.pos >= len(lx.src) {
		tok.kind = .EOF
		return
	}
	c := lx.src[lx.pos]
	two :: proc(lx: ^Lexer, tok: ^Token, kind: Tok, n: int) {
		tok.kind = kind
		tok.len = u32(n)
		lx.pos += n
	}
	switch {
	case is_name_start(c):
		start := lx.pos
		for lx.pos < len(lx.src) && is_name_char(lx.src[lx.pos]) {lx.pos += 1}
		tok.text = lx.src[start:lx.pos]
		tok.len = u32(lx.pos - start)
		tok.kind = .Name
		for kw, i in KEYWORDS {
			if kw == tok.text {
				tok.kind = Tok(int(Tok.And) + i)
				break
			}
		}
		return
	case c >= '0' && c <= '9', c == '.' && peek(lx, 1) >= '0' && peek(lx, 1) <= '9':
		if !read_number(lx, &tok) {tok.kind = .EOF}
		return
	case c == '"' || c == '\'':
		start := lx.pos
		s, ok := read_string(lx, tok.line, tok.col)
		if !ok {
			tok.kind = .EOF
			return
		}
		tok.kind = .String
		tok.text = s
		tok.len = first_line_len(lx.src[start:lx.pos])
		return
	case c == '[':
		start := lx.pos
		if level := long_bracket(lx); level >= 0 {
			s, ok := read_long(lx, level, false, tok.line, tok.col)
			if !ok {
				tok.kind = .EOF
				return
			}
			tok.kind = .String
			tok.text = s
			tok.len = first_line_len(lx.src[start:lx.pos])
			return
		}
		two(lx, &tok, .LBracket, 1)
		return
	}
	n1, n2 := peek(lx, 1), peek(lx, 2)
	switch c {
	case '+':
		if n1 == '=' {two(lx, &tok, .Plus_Eq, 2)} else {two(lx, &tok, .Plus, 1)}
	case '-':
		if n1 == '=' {
			two(lx, &tok, .Minus_Eq, 2)
		} else if n1 == '>' {
			two(lx, &tok, .Arrow, 2)
		} else {
			two(lx, &tok, .Minus, 1)
		}
	case '*':
		if n1 == '=' {two(lx, &tok, .Star_Eq, 2)} else {two(lx, &tok, .Star, 1)}
	case '/':
		if n1 == '/' {
			if n2 == '=' {two(lx, &tok, .Dslash_Eq, 3)} else {two(lx, &tok, .Dslash, 2)}
		} else if n1 == '=' {
			two(lx, &tok, .Slash_Eq, 2)
		} else {
			two(lx, &tok, .Slash, 1)
		}
	case '%':
		if n1 == '=' {two(lx, &tok, .Percent_Eq, 2)} else {two(lx, &tok, .Percent, 1)}
	case '^':
		if n1 == '=' {two(lx, &tok, .Caret_Eq, 2)} else {two(lx, &tok, .Caret, 1)}
	case '#':
		two(lx, &tok, .Hash, 1)
	case '&':
		if n1 == '&' {two(lx, &tok, .And_And, 2)} else {two(lx, &tok, .Amp, 1)}
	case '~':
		if n1 == '=' {two(lx, &tok, .Ne, 2)} else {two(lx, &tok, .Tilde, 1)}
	case '|':
		if n1 == '|' {two(lx, &tok, .Or_Or, 2)} else {two(lx, &tok, .Pipe, 1)}
	case '<':
		if n1 == '<' {
			two(lx, &tok, .Shl, 2)
		} else if n1 == '=' {
			two(lx, &tok, .Le, 2)
		} else {
			two(lx, &tok, .Lt, 1)
		}
	case '>':
		if n1 == '>' {
			two(lx, &tok, .Shr, 2)
		} else if n1 == '=' {
			two(lx, &tok, .Ge, 2)
		} else {
			two(lx, &tok, .Gt, 1)
		}
	case '=':
		if n1 == '=' {two(lx, &tok, .Eq, 2)} else {two(lx, &tok, .Assign, 1)}
	case '!':
		if n1 == '=' {two(lx, &tok, .Bang_Eq, 2)} else {two(lx, &tok, .Bang, 1)}
	case '.':
		if n1 == '.' {
			if n2 == '.' {
				two(lx, &tok, .Dots, 3)
			} else if n2 == '=' {
				two(lx, &tok, .Concat_Eq, 3)
			} else {
				two(lx, &tok, .Concat, 2)
			}
		} else {
			two(lx, &tok, .Dot, 1)
		}
	case '(':
		two(lx, &tok, .LParen, 1)
	case ')':
		two(lx, &tok, .RParen, 1)
	case '{':
		two(lx, &tok, .LBrace, 1)
	case '}':
		two(lx, &tok, .RBrace, 1)
	case ']':
		two(lx, &tok, .RBracket, 1)
	case ';':
		two(lx, &tok, .Semi, 1)
	case ':':
		if n1 == ':' {two(lx, &tok, .Dcolon, 2)} else {two(lx, &tok, .Colon, 1)}
	case ',':
		two(lx, &tok, .Comma, 1)
	case '?':
		two(lx, &tok, .Question, 1)
	case:
		shown := lx.src[lx.pos:lx.pos + 1]
		if c >= 0x80 {
			_, n := utf8.decode_rune_in_string(lx.src[lx.pos:])
			shown = lx.src[lx.pos:lx.pos + max(n, 1)]
		}
		lex_fail(
			lx,
			tok.line,
			tok.col,
			1,
			strings.concatenate({"unexpected character '", shown, "'"}),
			"names are ASCII letters, digits and '_'; text goes in quotes",
		)
		tok.kind = .EOF
	}
	return
}

// first_line_len: the bytes of text before its first line break.
@(private = "file")
first_line_len :: proc(text: string) -> u32 {
	n := strings.index_any(text, "\r\n")
	return u32(n if n >= 0 else len(text))
}
