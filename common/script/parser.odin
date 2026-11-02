package script

import "core:strings"

// The recursive-descent parser: source to the syntax tree. Only the first syntax error is
// reported; common mistakes from other languages get a message and a hint of their own.

MAX_NESTING :: 200

Parser :: struct {
	lx:        Lexer,
	tok:       Token,
	ahead:     Token,
	has_ahead: bool,
	depth:     int,
	varargs:   [dynamic]bool, // per open function: does it take '...'
}

@(private = "file")
failed :: #force_inline proc(p: ^Parser) -> bool {return p.lx.failed}

@(private = "file")
advance :: proc(p: ^Parser) {
	if p.lx.failed {
		p.tok = Token {
			kind = .EOF,
			line = p.tok.line,
			col  = p.tok.col,
		}
		return
	}
	if p.has_ahead {
		p.tok = p.ahead
		p.has_ahead = false
		return
	}
	p.tok = lex_next(&p.lx)
}

@(private = "file")
lookahead :: proc(p: ^Parser) -> Token {
	if !p.has_ahead {
		p.ahead = lex_next(&p.lx)
		p.has_ahead = true
	}
	return p.ahead
}

// got_text names a token in a message: 'then', 'x', '123', a string, the end of the file.
got_text :: proc(t: Token) -> string {
	#partial switch t.kind {
	case .EOF:
		return "the end of the file"
	case .Name, .Int, .Float:
		return strings.concatenate({"'", t.text, "'"})
	case .String:
		return "a string"
	}
	return strings.concatenate({"'", TOKEN_TEXT[t.kind], "'"})
}

@(private = "file")
fail_at :: proc(p: ^Parser, t: Token, message: string, hint := "") {
	lex_fail(&p.lx, t.line, t.col, t.len, message, hint)
}

// mistake_hint: the hint for a token other languages use where this one has another.
@(private = "file")
mistake :: proc(p: ^Parser) -> bool {
	msg, hint: string
	#partial switch p.tok.kind {
	case .Bang_Eq:
		msg, hint = "'!=' is not an operator", "write 'not equal' as '~='"
	case .And_And:
		msg, hint = "'&&' is not an operator", "write 'and'"
	case .Or_Or:
		msg, hint = "'||' is not an operator", "write 'or'"
	case .Bang:
		msg, hint = "'!' is not an operator", "write 'not'"
	case .Goto:
		msg, hint = "goto is not supported", "use 'continue' or 'break', or a flag variable"
	case .Dcolon:
		msg, hint = "labels are not supported", "use 'continue' or 'break', or a flag variable"
	case:
		return false
	}
	fail_at(p, p.tok, msg, hint)
	return true
}

@(private = "file")
expect :: proc(p: ^Parser, kind: Tok, after: string, hint := "") -> bool {
	if p.tok.kind == kind {
		advance(p)
		return true
	}
	if failed(p) || mistake(p) {return false}
	h := hint
	if p.tok.kind == .LBrace && (kind == .Then || kind == .Do) {
		h = "blocks are written 'then ... end' or 'do ... end', not with braces"
	}
	fail_at(
		p,
		p.tok,
		strings.concatenate(
			{"'", TOKEN_TEXT[kind], "' expected", after, ", got ", got_text(p.tok)},
		),
		h,
	)
	return false
}

@(private = "file")
expect_name :: proc(p: ^Parser, after: string) -> (Token, bool) {
	t := p.tok
	if t.kind == .Name {
		if t.text == "_ENV" {
			fail_at(
				p,
				t,
				"'_ENV' is not supported",
				"globals are the module's environment: use them by name",
			)
			return t, false
		}
		advance(p)
		return t, true
	}
	if failed(p) || mistake(p) {return t, false}
	fail_at(p, t, strings.concatenate({"a name expected", after, ", got ", got_text(t)}))
	return t, false
}

@(private = "file")
enter :: proc(p: ^Parser) -> bool {
	p.depth += 1
	if p.depth > MAX_NESTING {
		fail_at(
			p,
			p.tok,
			"too many nested levels (the limit is 200)",
			"split the code into smaller functions",
		)
		return false
	}
	return true
}

@(private = "file")
leave :: #force_inline proc(p: ^Parser) {p.depth -= 1}

@(private = "file")
node :: proc(kind: Node_Kind, t: Token) -> ^Node {
	n := new(Node)
	n.kind = kind
	n.line = t.line
	n.col = t.col
	n.len = t.len
	return n
}

// node_at: a node placed where another starts (an index or call: the error marks the
// value indexed or called).
@(private = "file")
node_at :: proc(kind: Node_Kind, at: ^Node) -> ^Node {
	n := new(Node)
	n.kind = kind
	if at != nil {
		n.line = at.line
		n.col = at.col
		n.len = at.len
	}
	return n
}

// parse_module parses a whole source; the tree lives in context.allocator.
parse_module :: proc(
	p: ^Parser,
	src: string,
	scratch: ^strings.Builder,
) -> (
	body: []^Node,
	ok: bool,
) {
	lexer_init(&p.lx, src, scratch)
	p.varargs = make([dynamic]bool)
	append(&p.varargs, true)
	advance(p)
	body = block(p)
	if !failed(p) && p.tok.kind != .EOF {
		if !mistake(p) {
			hint := ""
			if p.tok.kind ==
			   .End {hint = "this 'end' closes nothing: remove it, or look for a block opened twice"}
			fail_at(
				p,
				p.tok,
				strings.concatenate({"unexpected ", got_text(p.tok), " at the top level"}),
				hint,
			)
		}
	}
	return body, !failed(p)
}

@(private = "file")
block_follow :: proc(k: Tok, with_until: bool) -> bool {
	#partial switch k {
	case .Else, .Elseif, .End, .EOF:
		return true
	case .Until:
		return with_until
	}
	return false
}

@(private = "file")
block :: proc(p: ^Parser) -> []^Node {
	stats := make([dynamic]^Node)
	for !failed(p) && !block_follow(p.tok.kind, true) {
		if p.tok.kind == .Return {
			append(&stats, return_stat(p))
			break
		}
		if s := statement(p); s != nil {append(&stats, s)}
	}
	return stats[:]
}

@(private = "file")
nested_block :: proc(p: ^Parser) -> []^Node {
	if !enter(p) {return nil}
	defer leave(p)
	return block(p)
}

@(private = "file")
return_stat :: proc(p: ^Parser) -> ^Node {
	n := node(.Return, p.tok)
	advance(p)
	if !block_follow(p.tok.kind, true) && p.tok.kind != .Semi {n.list = expr_list(p)}
	if p.tok.kind == .Semi {advance(p)}
	if !failed(p) && !block_follow(p.tok.kind, true) {
		fail_at(
			p,
			p.tok,
			strings.concatenate({"'end' expected after 'return', got ", got_text(p.tok)}),
			"'return' must be the last statement of its block: wrap it as 'do return end' to return early",
		)
	}
	return n
}

// end_of: expects the 'end' closing what opened at line.
@(private = "file")
end_of :: proc(p: ^Parser, what: string, line: u32, hint := "") -> bool {
	if p.tok.kind == .End {
		advance(p)
		return true
	}
	if failed(p) || mistake(p) {return false}
	fail_at(
		p,
		p.tok,
		strings.concatenate(
			{
				"'end' expected (to close '",
				what,
				"' at line ",
				line_text(line),
				"), got ",
				got_text(p.tok),
			},
		),
		hint,
	)
	return false
}

@(private = "file")
statement :: proc(p: ^Parser) -> ^Node {
	t := p.tok
	#partial switch t.kind {
	case .Semi:
		advance(p)
		return nil
	case .If:
		return if_stat(p)
	case .While:
		advance(p)
		n := node(.While, t)
		n.a = expr(p)
		expect(
			p,
			.Do,
			" after the 'while' condition",
			"a while loop is written 'while <condition> do ... end'",
		)
		n.body = nested_block(p)
		n.end_line = p.tok.line
		end_of(p, "while", t.line)
		return n
	case .Do:
		advance(p)
		n := node(.Do, t)
		n.body = nested_block(p)
		end_of(p, "do", t.line)
		return n
	case .For:
		return for_stat(p)
	case .Repeat:
		advance(p)
		n := node(.Repeat, t)
		n.body = nested_block(p)
		if p.tok.kind != .Until {
			if !failed(p) && !mistake(p) {
				fail_at(
					p,
					p.tok,
					strings.concatenate(
						{
							"'until' expected (to close 'repeat' at line ",
							line_text(t.line),
							"), got ",
							got_text(p.tok),
						},
					),
				)
			}
			return nil
		}
		advance(p)
		n.a = expr(p)
		return n
	case .Function:
		return function_stat(p)
	case .Local:
		advance(p)
		if p.tok.kind == .Function {
			ft := p.tok
			advance(p)
			name, ok := expect_name(p, " after 'local function'")
			if !ok {return nil}
			if p.tok.kind == .Dot || p.tok.kind == .Colon {
				fail_at(
					p,
					name,
					"'local function' takes a plain name, not a field or a method",
					"drop 'local' to set a field: 'function a.b() ... end'",
				)
				return nil
			}
			n := node(.Local_Function, ft)
			n.name = name.text
			n.b = func_body(p, ft, false, name.text)
			return n
		}
		n := node(.Local, t)
		names := make([dynamic]^Node)
		for {
			append(&names, binding(p, " after 'local'"))
			if failed(p) {return nil}
			if p.tok.kind == .Lt {
				fail_at(
					p,
					p.tok,
					"attributes such as <const> and <close> are not supported",
					"drop the attribute: 'local x = ...'",
				)
				return nil
			}
			if p.tok.kind != .Comma {break}
			advance(p)
		}
		n.list = names[:]
		if p.tok.kind == .Assign {
			advance(p)
			n.list2 = expr_list(p)
		}
		return n
	case .Return:
		return return_stat(p)
	case .Break:
		advance(p)
		return node(.Break, t)
	case .Continue:
		advance(p)
		return node(.Continue, t)
	case .Name:
		if t.text == "type" {
			if a := lookahead(p); a.kind == .Name {
				advance(p)
				n := node(.Type_Alias, t)
				n.name = p.tok.text
				advance(p)
				expect(p, .Assign, " after the type's name")
				n.ty = type_expr(p)
				return n
			}
		}
	}
	if mistake(p) {return nil}
	return expr_stat(p)
}

@(private = "file")
if_stat :: proc(p: ^Parser) -> ^Node {
	t := p.tok
	n := node(.If, t)
	clauses := make([dynamic]^Node)
	else_if_line: u32 = 0
	for {
		c := node(.Clause, p.tok)
		advance(p) // 'if' or 'elseif'
		c.a = expr(p)
		if p.tok.kind == .Assign {
			fail_at(
				p,
				p.tok,
				strings.concatenate({"'then' expected after the 'if' condition, got '='"}),
				"to compare, write '=='",
			)
			return nil
		}
		expect(
			p,
			.Then,
			" after the 'if' condition",
			"an if is written 'if <condition> then ... end'",
		)
		c.body = nested_block(p)
		append(&clauses, c)
		if p.tok.kind != .Elseif || failed(p) {break}
	}
	n.list = clauses[:]
	if p.tok.kind == .Else {
		else_tok := p.tok
		advance(p)
		if p.tok.kind == .If && p.tok.line == else_tok.line {else_if_line = else_tok.line}
		n.flag = true
		n.list2 = nested_block(p)
	}
	hint := ""
	if else_if_line != 0 {
		hint = strings.concatenate(
			{
				"'else if' at line ",
				line_text(else_if_line),
				" opens a second 'if' that needs its own 'end': write 'elseif'",
			},
		)
	}
	end_of(p, "if", t.line, hint)
	return n
}

@(private = "file")
for_stat :: proc(p: ^Parser) -> ^Node {
	t := p.tok
	advance(p)
	first := binding(p, " after 'for'")
	if failed(p) {return nil}
	if p.tok.kind == .Assign {
		advance(p)
		n := node(.Numeric_For, t)
		n.a = first
		n.b = expr(p)
		expect(p, .Comma, " after the 'for' start value")
		n.c = expr(p)
		if p.tok.kind == .Comma {
			advance(p)
			n.d = expr(p)
		}
		expect(
			p,
			.Do,
			" after the 'for' range",
			"a for loop is written 'for i = 1, 10 do ... end'",
		)
		n.body = nested_block(p)
		end_of(p, "for", t.line)
		return n
	}
	n := node(.Generic_For, t)
	names := make([dynamic]^Node)
	append(&names, first)
	for p.tok.kind == .Comma {
		advance(p)
		append(&names, binding(p, " in the 'for' names"))
		if failed(p) {return nil}
	}
	n.list = names[:]
	expect(
		p,
		.In,
		" after the 'for' names",
		"a for loop is written 'for i = 1, 10 do' or 'for k, v in pairs(t) do'",
	)
	n.list2 = expr_list(p)
	expect(
		p,
		.Do,
		" after the 'for' iterator",
		"a for loop is written 'for k, v in pairs(t) do ... end'",
	)
	n.body = nested_block(p)
	end_of(p, "for", t.line)
	return n
}

@(private = "file")
function_stat :: proc(p: ^Parser) -> ^Node {
	t := p.tok
	advance(p)
	name, ok := expect_name(p, " after 'function'")
	if !ok {return nil}
	target := node(.Name, name)
	target.name = name.text
	full := name.text
	method := false
	for p.tok.kind == .Dot || p.tok.kind == .Colon {
		method = p.tok.kind == .Colon
		dot := p.tok
		advance(p)
		key, kok := expect_name(p, " in the function's name")
		if !kok {return nil}
		k := node(.String, key)
		k.name = key.text
		idx := node(.Index, dot)
		idx.a = target
		idx.b = k
		target = idx
		full = strings.concatenate({full, TOKEN_TEXT[dot.kind], key.text})
		if method {break}
	}
	n := node(.Function_Stat, t)
	n.a = target
	n.flag = method
	n.b = func_body(p, t, method, full)
	return n
}

@(private = "file")
binding :: proc(p: ^Parser, after: string) -> ^Node {
	name, ok := expect_name(p, after)
	if !ok {return nil}
	n := node(.Binding, name)
	n.name = name.text
	if p.tok.kind == .Colon {
		advance(p)
		n.ty = type_expr(p)
	}
	return n
}

@(private = "file")
func_body :: proc(p: ^Parser, t: Token, method: bool, name: string) -> ^Node {
	if !enter(p) {return nil}
	defer leave(p)
	f := node(.Function, t)
	f.name = name
	params := make([dynamic]^Node)
	if method {
		self := node(.Binding, t)
		self.name = "self"
		append(&params, self)
	}
	expect(
		p,
		.LParen,
		" to open the parameters",
		"a function is written 'function name(a, b) ... end'",
	)
	if p.tok.kind != .RParen {
		for !failed(p) {
			if p.tok.kind == .Dots {
				advance(p)
				f.flag = true
				if p.tok.kind == .Colon {
					advance(p)
					f.a = type_expr(p)
				}
				break
			}
			append(&params, binding(p, " in the parameters"))
			if p.tok.kind != .Comma {break}
			advance(p)
		}
	}
	f.list = params[:]
	expect(p, .RParen, " to close the parameters")
	if p.tok.kind == .Colon {
		advance(p)
		f.b = type_expr(p)
	}
	append(&p.varargs, f.flag)
	f.body = block(p)
	pop(&p.varargs)
	f.end_line = p.tok.line
	end_of(p, "function", t.line)
	return f
}

@(private = "file")
expr_list :: proc(p: ^Parser) -> []^Node {
	list := make([dynamic]^Node)
	append(&list, expr(p))
	for p.tok.kind == .Comma && !failed(p) {
		advance(p)
		append(&list, expr(p))
	}
	return list[:]
}

@(private = "file")
expr_stat :: proc(p: ^Parser) -> ^Node {
	t := p.tok
	e := suffixed_expr(p)
	if failed(p) {return nil}
	#partial switch p.tok.kind {
	case .Assign, .Comma:
		n := node(.Assign, t)
		targets := make([dynamic]^Node)
		append(&targets, e)
		for p.tok.kind == .Comma {
			advance(p)
			append(&targets, suffixed_expr(p))
			if failed(p) {return nil}
		}
		for target in targets {
			if target.kind != .Name && target.kind != .Index {
				fail_at(
					p,
					Token{line = target.line, col = target.col, len = target.len},
					"cannot assign to this expression",
					"only a name, a field 't.x' or an index 't[k]' can be assigned",
				)
				return nil
			}
		}
		n.list = targets[:]
		expect(p, .Assign, " after the assignment's targets")
		n.list2 = expr_list(p)
		return n
	case .Plus_Eq, .Minus_Eq, .Star_Eq, .Slash_Eq, .Dslash_Eq, .Percent_Eq, .Caret_Eq, .Concat_Eq:
		if e.kind != .Name && e.kind != .Index {
			fail_at(
				p,
				p.tok,
				"cannot assign to this expression",
				"only a name, a field 't.x' or an index 't[k]' can be assigned",
			)
			return nil
		}
		n := node(.Compound, p.tok)
		n.op = p.tok.kind
		advance(p)
		n.a = e
		n.b = expr(p)
		return n
	}
	if e.kind != .Call && e.kind != .Method_Call {
		if mistake(p) {return nil}
		if p.tok.kind == .Eq {
			fail_at(p, p.tok, "'==' compares, it does not assign", "to assign, write '='")
			return nil
		}
		fail_at(
			p,
			Token{line = e.line, col = e.col, len = e.len},
			"syntax error: this expression is not a statement",
			"a statement is an assignment, a call, or a keyword such as 'local' or 'if'",
		)
		return nil
	}
	n := node(.Call_Stat, t)
	n.a = e
	return n
}

@(private = "file")
primary_expr :: proc(p: ^Parser) -> ^Node {
	t := p.tok
	#partial switch t.kind {
	case .Name:
		if _, ok := expect_name(p, ""); !ok {return nil}
		n := node(.Name, t)
		n.name = t.text
		return n
	case .LParen:
		advance(p)
		n := node(.Paren, t)
		n.a = expr(p)
		expect(p, .RParen, " to close the parenthesis")
		return n
	}
	if failed(p) || mistake(p) {return nil}
	hint := ""
	if t.kind == .LBrace {hint = "blocks are written with 'do', 'then' and 'end', not braces"}
	fail_at(
		p,
		t,
		"unexpected end of the file" if t.kind == .EOF else strings.concatenate({"unexpected ", got_text(t)}),
		hint,
	)
	return nil
}

@(private = "file")
suffixed_expr :: proc(p: ^Parser) -> ^Node {
	e := primary_expr(p)
	for !failed(p) {
		t := p.tok
		#partial switch t.kind {
		case .Dot:
			advance(p)
			key, ok := expect_name(p, " after '.'")
			if !ok {return nil}
			k := node(.String, key)
			k.name = key.text
			n := node_at(.Index, e)
			n.a = e
			n.b = k
			e = n
		case .LBracket:
			advance(p)
			n := node_at(.Index, e)
			n.a = e
			n.b = expr(p)
			expect(p, .RBracket, " to close the index")
			e = n
		case .Colon:
			advance(p)
			key, ok := expect_name(p, " after ':' (a method call is written 'obj:name(...)')")
			if !ok {return nil}
			n := node(.Method_Call, key)
			n.name = key.text
			n.a = e
			n.list = call_args(p)
			e = n
		case .LParen, .String, .LBrace:
			n := node_at(.Call, e)
			n.a = e
			n.list = call_args(p)
			e = n
		case:
			return e
		}
	}
	return e
}

@(private = "file")
call_args :: proc(p: ^Parser) -> []^Node {
	t := p.tok
	#partial switch t.kind {
	case .String:
		n := node(.String, t)
		n.name = t.text
		advance(p)
		list := make([]^Node, 1)
		list[0] = n
		return list
	case .LBrace:
		list := make([]^Node, 1)
		list[0] = table_cons(p)
		return list
	case .LParen:
		advance(p)
		if p.tok.kind == .RParen {
			advance(p)
			return nil
		}
		args := expr_list(p)
		expect(p, .RParen, " to close the call's arguments")
		return args
	}
	expect(p, .LParen, " for the call's arguments")
	return nil
}

@(private = "file")
table_cons :: proc(p: ^Parser) -> ^Node {
	t := p.tok
	if !enter(p) {return nil}
	defer leave(p)
	advance(p)
	n := node(.Table, t)
	fields := make([dynamic]^Node)
	for p.tok.kind != .RBrace && !failed(p) {
		f: ^Node
		if p.tok.kind == .LBracket {
			f = node(.Field_Keyed, p.tok)
			advance(p)
			f.a = expr(p)
			expect(p, .RBracket, " to close the key")
			expect(p, .Assign, " after the key")
			f.b = expr(p)
		} else if p.tok.kind == .Name && lookahead(p).kind == .Assign {
			f = node(.Field_Named, p.tok)
			f.name = p.tok.text
			advance(p)
			advance(p)
			f.a = expr(p)
		} else {
			f = node(.Field_Pos, p.tok)
			f.a = expr(p)
		}
		append(&fields, f)
		if p.tok.kind == .Comma || p.tok.kind == .Semi {
			advance(p)
		} else {
			break
		}
	}
	n.list = fields[:]
	if !failed(p) && p.tok.kind != .RBrace {
		if mistake(p) {return nil}
		fail_at(
			p,
			p.tok,
			strings.concatenate(
				{
					"'}' expected (to close '{' at line ",
					line_text(t.line),
					"), got ",
					got_text(p.tok),
				},
			),
			"separate a table's fields with ',' or ';'",
		)
		return nil
	}
	advance(p)
	return n
}

@(private = "file")
simple_expr :: proc(p: ^Parser) -> ^Node {
	t := p.tok
	#partial switch t.kind {
	case .Int:
		n := node(.Int, t)
		n.ival = t.ival
		advance(p)
		return n
	case .Float:
		n := node(.Float, t)
		n.fval = t.fval
		advance(p)
		return n
	case .String:
		n := node(.String, t)
		n.name = t.text
		advance(p)
		return n
	case .Nil:
		advance(p)
		return node(.Nil, t)
	case .True:
		advance(p)
		return node(.True, t)
	case .False:
		advance(p)
		return node(.False, t)
	case .Dots:
		if !p.varargs[len(p.varargs) - 1] {
			fail_at(
				p,
				t,
				"cannot use '...' outside a function that takes '...'",
				"add '...' to the function's parameters",
			)
			return nil
		}
		advance(p)
		return node(.Vararg, t)
	case .LBrace:
		return table_cons(p)
	case .Function:
		advance(p)
		return func_body(p, t, false, "")
	}
	return suffixed_expr(p)
}

@(private = "file")
binary_priority :: proc(k: Tok) -> (left, right: int) {
	#partial switch k {
	case .Or:
		return 1, 1
	case .And:
		return 2, 2
	case .Lt, .Gt, .Le, .Ge, .Ne, .Eq:
		return 3, 3
	case .Pipe:
		return 4, 4
	case .Tilde:
		return 5, 5
	case .Amp:
		return 6, 6
	case .Shl, .Shr:
		return 7, 7
	case .Concat:
		return 9, 8
	case .Plus, .Minus:
		return 10, 10
	case .Star, .Slash, .Dslash, .Percent:
		return 11, 11
	case .Caret:
		return 14, 13
	}
	return 0, 0
}

UNARY_PRIORITY :: 12

expr :: proc(p: ^Parser) -> ^Node {
	return sub_expr(p, 0)
}

@(private = "file")
sub_expr :: proc(p: ^Parser, limit: int) -> ^Node {
	if !enter(p) {return nil}
	defer leave(p)
	e: ^Node
	t := p.tok
	#partial switch t.kind {
	case .Not, .Minus, .Hash, .Tilde:
		advance(p)
		n := node(.Unop, t)
		n.op = t.kind
		n.a = sub_expr(p, UNARY_PRIORITY)
		e = n
	case:
		if mistake(p) {return nil}
		e = simple_expr(p)
	}
	for !failed(p) {
		op := p.tok
		left, right := binary_priority(op.kind)
		if left == 0 {
			#partial switch op.kind {
			case .Bang_Eq, .And_And, .Or_Or:
				mistake(p)
			}
			break
		}
		if left <= limit {break}
		advance(p)
		n := node(.Binop, op)
		n.op = op.kind
		n.a = e
		n.b = sub_expr(p, right)
		e = n
	}
	return e
}

// Types: parsed into the tree and erased; nothing checks them.

@(private = "file")
type_expr :: proc(p: ^Parser) -> ^Node {
	if !enter(p) {return nil}
	defer leave(p)
	first := optional_type(p)
	if p.tok.kind != .Pipe {return first}
	n := node(.T_Union, p.tok)
	list := make([dynamic]^Node)
	append(&list, first)
	for p.tok.kind == .Pipe && !failed(p) {
		advance(p)
		append(&list, optional_type(p))
	}
	n.list = list[:]
	return n
}

@(private = "file")
optional_type :: proc(p: ^Parser) -> ^Node {
	t := simple_type(p)
	if p.tok.kind == .Question {
		n := node(.T_Optional, p.tok)
		advance(p)
		n.a = t
		return n
	}
	return t
}

@(private = "file")
simple_type :: proc(p: ^Parser) -> ^Node {
	t := p.tok
	#partial switch t.kind {
	case .Nil:
		advance(p)
		return node(.T_Nil, t)
	case .Function:
		// 'function' as a type name.
		advance(p)
		n := node(.T_Name, t)
		n.name = "function"
		return n
	case .Name:
		advance(p)
		n := node(.T_Name, t)
		n.name = t.text
		if p.tok.kind == .Dot {
			advance(p)
			second, ok := expect_name(p, " in the type's name")
			if !ok {return nil}
			n.name = strings.concatenate({t.text, ".", second.text})
		}
		return n
	case .LBrace:
		if !enter(p) {return nil}
		defer leave(p)
		advance(p)
		n: ^Node
		if p.tok.kind == .LBracket {
			advance(p)
			n = node(.T_Map, t)
			n.a = type_expr(p)
			expect(p, .RBracket, " to close the map type's key")
			expect(p, .Colon, " after the map type's key")
			n.b = type_expr(p)
		} else if p.tok.kind == .Name && lookahead(p).kind == .Colon {
			n = node(.T_Record, t)
			fields := make([dynamic]^Node)
			for p.tok.kind == .Name && !failed(p) {
				f := node(.T_Field, p.tok)
				f.name = p.tok.text
				advance(p)
				expect(p, .Colon, " after the field's name")
				f.a = type_expr(p)
				append(&fields, f)
				if p.tok.kind != .Comma {break}
				advance(p)
			}
			n.list = fields[:]
		} else {
			n = node(.T_Array, t)
			n.a = type_expr(p)
		}
		expect(p, .RBrace, " to close the table type")
		return n
	case .LParen:
		if !enter(p) {return nil}
		defer leave(p)
		advance(p)
		list := make([dynamic]^Node)
		if p.tok.kind != .RParen {
			append(&list, type_expr(p))
			for p.tok.kind == .Comma && !failed(p) {
				advance(p)
				append(&list, type_expr(p))
			}
		}
		expect(p, .RParen, " to close the type list")
		if p.tok.kind == .Arrow {
			advance(p)
			n := node(.T_Func, t)
			n.list = list[:]
			n.a = type_expr(p)
			return n
		}
		if len(list) == 1 {return list[0]}
		n := node(.T_Tuple, t)
		n.list = list[:]
		return n
	}
	if failed(p) {return nil}
	fail_at(
		p,
		t,
		strings.concatenate({"a type expected, got ", got_text(t)}),
		"a type is a name ('number', 'string'), '{T}', '{[K]: V}', '{x: T}' or '(A) -> R'",
	)
	return nil
}
