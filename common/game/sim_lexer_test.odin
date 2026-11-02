package game

import "core:strings"
import "core:testing"

@(test)
test_lexer_token_kinds :: proc(t: ^testing.T) {
	toks: Rule_Tokens
	err, _, _ := rule_lex(
		"set t.potency self[age] -1..1 + - ( ) , = # @ $ == != < <= > >= voxiverse:oak/log x_1",
		1,
		1,
		&toks,
	)
	testing.expect_value(t, err, Lex_Error.None)
	want := [?]Rule_Token_Kind {
		.Ident,
		.Ident,
		.Dot,
		.Ident,
		.Ident,
		.L_Brack,
		.Ident,
		.R_Brack, // set t . potency self [ age ]
		.Int,
		.Dot_Dot,
		.Int,
		.Plus,
		.Minus,
		.L_Paren,
		.R_Paren,
		.Comma, // -1 .. 1 + - ( ) ,
		.Assign,
		.Hash,
		.At,
		.Dollar,
		.Eq,
		.Ne,
		.Lt,
		.Le,
		.Gt,
		.Ge, // = # @ $ == != < <= > >=
		.Ident,
		.Ident,
	}
	testing.expect_value(t, toks.count, len(want))
	for k, i in want {
		if i <
		   toks.count {testing.expectf(t, toks.items[i].kind == k, "token %d: %v, want %v", i, toks.items[i].kind, k)}
	}
	testing.expect_value(t, toks.items[8].value, i32(-1))
	testing.expect_value(t, toks.items[10].value, i32(1))
	testing.expect_value(t, toks.items[26].text, "voxiverse:oak/log")
}

@(test)
test_lexer_positions :: proc(t: ^testing.T) {
	// A statement on line 7 whose string opens at column 9: its third token's exact place.
	toks: Rule_Tokens
	err, _, _ := rule_lex("require self.potency > 0", 7, 9, &toks)
	testing.expect_value(t, err, Lex_Error.None)
	third := toks.items[2] // "."
	testing.expect_value(t, third.kind, Rule_Token_Kind.Dot)
	testing.expect_value(t, third.line, i32(7))
	// opening quote at 9, text starts at 10: "require" 10..16, space, "self" 18..21, "." 22
	testing.expect_value(t, third.column, i32(22))
}

@(test)
test_lexer_refusals :: proc(t: ^testing.T) {
	toks: Rule_Tokens
	err, line, col := rule_lex("stop\n", 3, 5, &toks)
	testing.expect_value(t, err, Lex_Error.Escapes)
	testing.expect_value(t, line, i32(3))
	testing.expect_value(t, col, i32(10))
	err, _, _ = rule_lex("a\\n", 1, 1, &toks)
	testing.expect_value(t, err, Lex_Error.Escapes)
	long := strings.repeat("a ", 70, context.temp_allocator)
	err, _, _ = rule_lex(long[:127], 1, 1, &toks) // 64 tokens
	testing.expect_value(t, err, Lex_Error.None)
	testing.expect_value(t, toks.count, 64)
	err, _, col = rule_lex(long[:129], 1, 1, &toks) // 65
	testing.expect_value(t, err, Lex_Error.Too_Long)
	testing.expect_value(t, col, i32(1 + 1 + 128))
	err, _, _ = rule_lex("a ? b", 1, 1, &toks)
	testing.expect_value(t, err, Lex_Error.Bad_Character)
}
