package script

import "core:strings"
import "core:testing"

@(private = "file")
lex_all :: proc(src: string) -> (toks: [dynamic]Token, err: Syntax_Error, ok: bool) {
	context.allocator = context.temp_allocator
	scratch := strings.builder_make(context.temp_allocator)
	lx: Lexer
	lexer_init(&lx, src, &scratch)
	toks = make([dynamic]Token, context.temp_allocator)
	for {
		t := lex_next(&lx)
		if lx.failed {return toks, lx.err, false}
		if t.kind == .String ||
		   t.kind == .Name {t.text = strings.clone(t.text, context.temp_allocator)}
		append(&toks, t)
		if t.kind == .EOF {break}
	}
	return toks, {}, true
}

@(test)
test_lexer_every_token :: proc(t: ^testing.T) {
	// Every token kind but EOF, written by its text, separated by spaces.
	b := strings.builder_make(context.temp_allocator)
	want := make([dynamic]Tok, context.temp_allocator)
	for kind in Tok {
		#partial switch kind {
		case .EOF:
			continue
		case .Name:
			strings.write_string(&b, "name_1")
		case .Int:
			strings.write_string(&b, "42")
		case .Float:
			strings.write_string(&b, "4.5")
		case .String:
			strings.write_string(&b, "'s'")
		case:
			strings.write_string(&b, TOKEN_TEXT[kind])
		}
		strings.write_byte(&b, ' ')
		append(&want, kind)
	}
	toks, err, ok := lex_all(strings.to_string(b))
	if !testing.expectf(t, ok, "lexing every token failed: %s", err.message) {return}
	testing.expect_value(t, len(toks), len(want) + 1)
	for kind, i in want {
		if i >= len(toks) {break}
		testing.expectf(t, toks[i].kind == kind, "token %d: %v, wanted %v", i, toks[i].kind, kind)
	}
	testing.expect_value(t, toks[len(toks) - 1].kind, Tok.EOF)
}

@(test)
test_lexer_positions :: proc(t: ^testing.T) {
	toks, _, ok := lex_all("local x = 1\n  x += [[a\nb]] .. \"c\"\r\n\tend")
	testing.expect(t, ok)
	Pos :: struct {
		kind:           Tok,
		line, col, len: u32,
	}
	want := []Pos {
		{.Local, 1, 1, 5},
		{.Name, 1, 7, 1},
		{.Assign, 1, 9, 1},
		{.Int, 1, 11, 1},
		{.Name, 2, 3, 1},
		{.Plus_Eq, 2, 5, 2},
		{.String, 2, 8, 3},
		{.Concat, 3, 5, 2},
		{.String, 3, 8, 3},
		{.End, 4, 2, 3},
		{.EOF, 4, 5, 0},
	}
	testing.expect_value(t, len(toks), len(want))
	for w, i in want {
		if i >= len(toks) {break}
		g := toks[i]
		testing.expectf(
			t,
			g.kind == w.kind &&
			g.line == w.line &&
			g.col == w.col &&
			(w.kind == .EOF || g.len == w.len),
			"token %d: %v at %d:%d (%d), wanted %v at %d:%d (%d)",
			i,
			g.kind,
			g.line,
			g.col,
			g.len,
			w.kind,
			w.line,
			w.col,
			w.len,
		)
	}
}

@(test)
test_lexer_numbers :: proc(t: ^testing.T) {
	Case :: struct {
		src:  string,
		kind: Tok,
		ival: i64,
		fval: f64,
	}
	cases := []Case {
		{"0", .Int, 0, 0},
		{"9223372036854775807", .Int, max(i64), 0},
		{"9223372036854775808", .Float, 0, 9223372036854775808.0},
		{"0xffffffffffffffff", .Int, -1, 0},
		{"0x10000000000000001", .Int, 1, 0},
		{"0x7FFFFFFFFFFFFFFF", .Int, max(i64), 0},
		{"1e2", .Float, 0, 100},
		{"1E-2", .Float, 0, 0.01},
		{".5", .Float, 0, 0.5},
		{"5.", .Float, 0, 5},
		{"3.25e+1", .Float, 0, 32.5},
		{"1e400", .Float, 0, transmute(f64)u64(0x7FF0_0000_0000_0000)},
	}
	for c in cases {
		toks, err, ok := lex_all(c.src)
		if !testing.expectf(t, ok, "%s: %s", c.src, err.message) {continue}
		g := toks[0]
		testing.expectf(t, g.kind == c.kind, "%s: %v, wanted %v", c.src, g.kind, c.kind)
		if c.kind ==
		   .Int {testing.expectf(t, g.ival == c.ival, "%s: %d, wanted %d", c.src, g.ival, c.ival)}
		if c.kind ==
		   .Float {testing.expectf(t, g.fval == c.fval, "%s: %v, wanted %v", c.src, g.fval, c.fval)}
	}
	bad := []string{"3..2", "0x1p4", "0x.8", "1e", "1_000", "0xg", "1.2.3", "08a"}
	for src in bad {
		_, _, ok := lex_all(src)
		testing.expectf(t, !ok, "%s lexed, wanted a malformed number", src)
	}
}

@(test)
test_lexer_strings :: proc(t: ^testing.T) {
	Case :: struct {
		src, want: string,
	}
	cases := []Case {
		{`"a\tb"`, "a\tb"},
		{`'\65\0661'`, "AB1"},
		{`"\x7e\x7F"`, "~\x7f"},
		{`"\u{20AC}"`, "€"},
		{`"\u{10FFFF}"`, "\U0010FFFF"},
		{"\"a\\z  \n  b\"", "ab"},
		{"[==[x]]y]==]", "x]]y"},
		{"[[\nfirst]]", "first"},
		{`"\\\"\'"`, "\\\"'"},
	}
	for c in cases {
		toks, err, ok := lex_all(c.src)
		if !testing.expectf(t, ok, "%s: %s", c.src, err.message) {continue}
		testing.expectf(
			t,
			toks[0].kind == .String && toks[0].text == c.want,
			"%s: %q, wanted %q",
			c.src,
			toks[0].text,
			c.want,
		)
	}
	bad := []string {
		`"abc`,
		"'a\nb'",
		`"\q"`,
		`"\x4"`,
		`"\u{110000}"`,
		`"\256"`,
		"[[abc",
		"[=[abc]]",
	}
	for src in bad {
		_, _, ok := lex_all(src)
		testing.expectf(t, !ok, "%q lexed, wanted an error", src)
	}
}
