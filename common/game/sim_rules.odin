package game

import "core:fmt"
import "core:reflect"
import "core:strings"

// Neighbour rules as data: a statement rule's `do` array (strings in the rule
// language, see sim_lexer.odin; the JSON gives the structure) is compiled here to a flat,
// index-linked Rule_Program that server/core/sim_interp.odin runs. The checks that bound a
// rule (cost, reach, nesting, picks, boxes) are all made at load; every refusal is one
// Pack_Error at the token at fault, "<what is wrong>: <the fix>".
//
// Nothing in the compiled form points into the JSON text; it lives in the registry's arena.

RULE_REACH :: 8
RULE_MAX_COST :: 4096
RULE_MAX_STATEMENTS :: 64
RULE_MAX_DEPTH :: 4
RULE_MAX_PICKS :: 4
RULE_MAX_BOX :: 9
RULE_MAX_BLOCKS :: 16
RULE_MAX_LIST :: 64
RULE_MAX_ERRORS :: 20
RULE_LIGHT_COST :: 377 // the cells within Manhattan distance 6 that light_above reads

Rule_Cell :: struct {
	slot: u8, // 0: self; 1..4: the pick bound that number
	off:  [3]i8,
}

Rule_Cmp :: enum u8 {
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
}

Rule_Op_Kind :: enum u8 {
	Lit, // push value
	Chan, // push cell's channel `value`
	Prop, // push cell's state property named names[ref]
	Index, // push the place of cell's block in list `ref` (-1 if absent)
	Add,
	Sub,
	Cmp, // pop two, push 0/1
	Is, // cell's block is in matcher `ref`
	Not, // ... is not
	Loaded,
	Any, // some cell of the box (lo..hi from self) is in matcher `ref`
	Count, // the number of cells in the box in matcher `ref`, compared (cmp) to `value`
	And_Jump, // top false: leave it, skip `value` ops; else pop it
	Or_Jump,
}

// Rule_Op: one step of an expression or condition, in postfix; Is and the others read a cell.
Rule_Op :: struct {
	kind:  Rule_Op_Kind,
	cmp:   Rule_Cmp,
	cell:  Rule_Cell,
	value: i32,
	ref:   i32,
	lo:    [3]i8,
	hi:    [3]i8,
}

Rule_Stmt_Kind :: enum u8 {
	Require, // code: the condition
	Chance, // value: n
	Pick, // slot, lo, hi
	Set_Block, // cell, value: the block
	Set_List, // cell, ref: the list, code: the index
	Set_Prop, // cell, ref: the property name, code: the value
	Set_Channel, // cell, value: the channel, code: the value
	Schedule, // cell, value: ticks
	Stop,
	If, // code: the condition, child: then, other: else (-1)
	Repeat, // value: n, child: the body
}

Rule_Stmt :: struct {
	kind:      Rule_Stmt_Kind,
	slot:      u8,
	next:      i32, // the next statement of the same list, -1 at the end
	child:     i32,
	other:     i32,
	code_from: i32,
	code_len:  i32,
	cell:      Rule_Cell,
	value:     i32,
	ref:       i32,
	lo:        [3]i8,
	hi:        [3]i8,
}

Rule_Matcher :: struct {
	bits: []u64, // one bit per block value
}

rule_matcher_has :: #force_inline proc(m: ^Rule_Matcher, b: Block) -> bool {
	i := int(b)
	return i >> 6 < len(m.bits) && m.bits[i >> 6] & (1 << u64(i & 63)) != 0
}

Rule_Program :: struct {
	stmts:    []Rule_Stmt, // stmts[first] starts the rule
	first:    i32,
	code:     []Rule_Op,
	matchers: []Rule_Matcher,
	names:    []string, // property names
	blocks:   Rule_Matcher, // the cells the rule runs on
	cost:     i32,
	picks:    u8,
}

// Why a rule was refused: one code per kind of refusal (the fuzz target's signature).
Rule_Refusal :: enum u8 {
	None,
	Lex,
	Syntax,
	Unknown_Statement,
	Unknown_Cell,
	Unknown_Block,
	Unknown_State,
	Unknown_Tag,
	Unknown_Flag,
	Unknown_List,
	Unknown_Channel,
	Unknown_Property,
	Computed_Channel_Set,
	Literal_Range,
	Reach,
	Box,
	Pick,
	Too_Many_Statements,
	Too_Deep,
	Too_Costly,
	List_Shape,
	Envelope,
	Conflict,
}

@(private)
Rule_Compiler :: struct {
	b:        ^Reg_Build,
	reg:      ^Registry,
	m:        ^Merged_Def,
	ns:       string,
	stmts:    [dynamic]Rule_Stmt,
	code:     [dynamic]Rule_Op,
	matchers: [dynamic]Rule_Matcher,
	names:    [dynamic]string,
	picks:    [RULE_MAX_PICKS]string,
	pick_lo:  [RULE_MAX_PICKS][3]i32,
	pick_hi:  [RULE_MAX_PICKS][3]i32,
	npicks:   int,
	depth:    int,
	errors:   int, // this rule's
	first:    Rule_Refusal, // the first refusal's code
}

@(private)
Rule_Parser :: struct {
	c:     ^Rule_Compiler,
	toks:  Rule_Tokens,
	pos:   int,
	end:   Rule_Token, // where the string ended (the position of "nothing more")
	value: Json_Value,
}

@(private)
rule_fail :: proc(c: ^Rule_Compiler, why: Rule_Refusal, line, column: i32, message: string) {
	if c.errors == 0 {c.first = why}
	c.errors += 1
	if c.errors > RULE_MAX_ERRORS {return}
	// (at most RULE_MAX_ERRORS a file: the file's earlier rules count)
	n := 0
	for e in c.b.errs {
		if e.e.file == c.m.file && e.order == c.m.pack {n += 1}
	}
	if n >= RULE_MAX_ERRORS {return}
	fail(c.b, c.m.pack, c.m.file, line, column, message)
}

@(private)
tok_fail :: proc(p: ^Rule_Parser, why: Rule_Refusal, t: Rule_Token, message: string) -> bool {
	rule_fail(p.c, why, t.line, t.column, message)
	return false
}

@(private)
peek :: proc(p: ^Rule_Parser) -> Rule_Token {
	if p.pos < p.toks.count {return p.toks.items[p.pos]}
	return p.end
}

@(private)
at_end :: #force_inline proc(p: ^Rule_Parser) -> bool {return p.pos >= p.toks.count}

@(private)
word_is :: proc(t: Rule_Token, word: string) -> bool {
	return t.kind == .Ident && t.text == word
}

@(private)
describe :: proc(t: Rule_Token) -> string {
	if t.kind == .Ident && t.text == "" {return "the end of the statement"}
	return fmt.aprintf("\"%s\"", t.text)
}

@(private)
expect :: proc(p: ^Rule_Parser, kind: Rule_Token_Kind, what: string) -> (Rule_Token, bool) {
	t := peek(p)
	if at_end(p) || t.kind != kind {
		got := "the end of the statement" if at_end(p) else fmt.aprintf("\"%s\"", t.text)
		tok_fail(
			p,
			.Syntax,
			t,
			fmt.aprintf("expected %s, found %s: write %s here", what, got, what),
		)
		return t, false
	}
	p.pos += 1
	return t, true
}

@(private)
expect_word :: proc(p: ^Rule_Parser, word: string) -> bool {
	t := peek(p)
	if at_end(p) || !word_is(t, word) {
		got := "the end of the statement" if at_end(p) else fmt.aprintf("\"%s\"", t.text)
		return tok_fail(
			p,
			.Syntax,
			t,
			fmt.aprintf("expected \"%s\", found %s: write \"%s\" here", word, got, word),
		)
	}
	p.pos += 1
	return true
}

// ---------------------------------------------------------------------------------------
// Names: ids, blocks, states, tags, flags, lists, channels.

@(private)
full_id :: proc(text: string) -> (string, bool) {
	id, ok := id_parse(text)
	if !ok {return "", false}
	return fmt.aprintf("%s:%s", id.namespace, id.name), true
}

// rule_list_of: the index of the list (or flow rule) named text in reg.sim.lists.
rule_list_of :: proc(reg: ^Registry, text: string) -> (int, bool) {
	full, ok := full_id(text)
	if !ok {return 0, false}
	for l, i in reg.sim.lists {
		if l.id == full {return i, true}
	}
	return 0, false
}

// Rule_Pattern: `ns:name` or `ns:name[prop=value,...]`, resolved to a type and the values given.
@(private)
Rule_Pattern :: struct {
	type:  Block_Type,
	props: [MAX_PROPS]int, // the value index per property, -1: any
	given: int,
}

@(private)
parse_pattern :: proc(p: ^Rule_Parser) -> (pat: Rule_Pattern, ok: bool) {
	t := peek(p)
	if at_end(p) || t.kind != .Ident {
		tok_fail(p, .Syntax, t, "expected a block id such as \"voxiverse:stone\": name a block")
		return
	}
	p.pos += 1
	reg := p.c.reg
	full, valid := full_id(t.text)
	n: u32
	found: bool
	if valid {n, found = reg.ids[.Block][full]}
	if !found {
		tok_fail(
			p,
			.Unknown_Block,
			t,
			fmt.aprintf("\"%s\" is not a block: name a block some pack defines", t.text),
		)
		return
	}
	tbl := &reg.blocks
	pat.type = tbl.type_of[n]
	for i in 0 ..< MAX_PROPS {pat.props[i] = -1}
	if peek(p).kind != .L_Brack || at_end(p) {return pat, true}
	p.pos += 1
	def := &tbl.types[pat.type]
	for {
		name, name_ok := expect(p, .Ident, "a property name")
		if !name_ok {return}
		pi, pfound := prop_index(tbl, pat.type, name.text)
		if !pfound {
			names := make([dynamic]string, context.temp_allocator)
			for q in def.props {append(&names, q.name)}
			tok_fail(
				p,
				.Unknown_State,
				name,
				fmt.aprintf(
					"\"%s\" has no property \"%s\": it has %s",
					def.id,
					name.text,
					strings.join(names[:], ", ", context.temp_allocator) if len(names) > 0 else "none",
				),
			)
			return
		}
		if _, eq_ok := expect(p, .Assign, "\"=\""); !eq_ok {return}
		val := peek(p)
		if at_end(p) || (val.kind != .Ident && val.kind != .Int) {
			tok_fail(p, .Syntax, val, "expected a property value: write one after \"=\"")
			return
		}
		p.pos += 1
		vi, vfound := prop_value_index(def.props[pi], val.text)
		if !vfound {
			tok_fail(
				p,
				.Unknown_State,
				val,
				fmt.aprintf(
					"property \"%s\" of \"%s\" has no value \"%s\": it has %s",
					name.text,
					def.id,
					val.text,
					strings.join(def.props[pi].values, ", ", context.temp_allocator),
				),
			)
			return
		}
		if pat.props[pi] == -1 {pat.given += 1}
		pat.props[pi] = vi
		if peek(p).kind == .Comma && !at_end(p) {
			p.pos += 1
			continue
		}
		if _, close_ok := expect(p, .R_Brack, "\"]\" or \",\""); !close_ok {return}
		break
	}
	return pat, true
}

// pattern_each: calls f with every state of the pattern's type that matches it.
@(private)
pattern_matches :: proc(p: ^Rule_Parser, pat: Rule_Pattern, b: Block) -> bool {
	tbl := &p.c.reg.blocks
	pat := pat
	for v, i in pat.props[:len(tbl.types[pat.type].props)] {
		if v >= 0 && state_value(tbl, b, i) != v {return false}
	}
	return true
}

@(private)
new_matcher :: proc(c: ^Rule_Compiler) -> Rule_Matcher {
	return {bits = make([]u64, (c.reg.blocks.count + 63) / 64)}
}

@(private)
set_bit :: #force_inline proc(m: ^Rule_Matcher, b: Block) {
	m.bits[int(b) >> 6] |= 1 << u64(int(b) & 63)
}

// parse_matcher_into: one matcher (`ns:name[...]`, `#tag`, `@flag`, `$list`), its blocks
// added to m.
@(private)
parse_matcher_into :: proc(p: ^Rule_Parser, m: ^Rule_Matcher) -> bool {
	c := p.c
	reg := c.reg
	tbl := &reg.blocks
	t := peek(p)
	if at_end(p) {
		return tok_fail(
			p,
			.Syntax,
			t,
			"expected a block matcher (id, #tag, @flag or $list): write one here",
		)
	}
	#partial switch t.kind {
	case .Hash:
		p.pos += 1
		name, ok := expect(p, .Ident, "a block tag id")
		if !ok {return false}
		idx, found := registry_block_tag(reg, name.text)
		if !found {
			return tok_fail(
				p,
				.Unknown_Tag,
				name,
				fmt.aprintf("\"#%s\" is not a block tag: name a tag some pack defines", name.text),
			)
		}
		for member in reg.block_tags[idx].members {set_bit(m, Block(member))}
		return true
	case .At:
		p.pos += 1
		name, ok := expect(p, .Ident, "a block flag name")
		if !ok {return false}
		for f in Block_Flag {
			s, _ := reflect.enum_name_from_value(f)
			if strings.to_lower(s, context.temp_allocator) == name.text {
				for b in 0 ..< tbl.count {
					if f in tbl.flags[b] {set_bit(m, Block(b))}
				}
				return true
			}
		}
		flags := make([dynamic]string, context.temp_allocator)
		for f in Block_Flag {
			s, _ := reflect.enum_name_from_value(f)
			append(&flags, strings.to_lower(s, context.temp_allocator))
		}
		return tok_fail(
			p,
			.Unknown_Flag,
			name,
			fmt.aprintf(
				"\"@%s\" is not a block flag: use one of %s",
				name.text,
				strings.join(flags[:], ", ", context.temp_allocator),
			),
		)
	case .Dollar:
		p.pos += 1
		name, ok := expect(p, .Ident, "a list id")
		if !ok {return false}
		li, found := rule_list_of(reg, name.text)
		if !found {
			return tok_fail(
				p,
				.Unknown_List,
				name,
				fmt.aprintf(
					"\"$%s\" is not a list or a flow rule: name one a pack defines",
					name.text,
				),
			)
		}
		for b in reg.sim.lists[li].blocks {set_bit(m, b)}
		return true
	case .Ident:
		pat, ok := parse_pattern(p)
		if !ok {return false}
		def := &tbl.types[pat.type]
		for i in 0 ..< int(def.state_count) {
			b := Block(int(def.first_state) + i)
			if pattern_matches(p, pat, b) {set_bit(m, b)}
		}
		return true
	}
	return tok_fail(
		p,
		.Syntax,
		t,
		fmt.aprintf(
			"expected a block matcher, found %s: write an id, #tag, @flag or $list",
			describe(t),
		),
	)
}

@(private)
parse_matcher :: proc(p: ^Rule_Parser) -> (index: i32, ok: bool) {
	m := new_matcher(p.c)
	if !parse_matcher_into(p, &m) {return}
	append(&p.c.matchers, m)
	return i32(len(p.c.matchers) - 1), true
}

// parse_block_value: `ns:name` (its default state) or `ns:name[prop=v,...]`, one block.
@(private)
parse_block_value :: proc(p: ^Rule_Parser) -> (b: Block, ok: bool) {
	first := peek(p)
	pat0 := parse_pattern(p) or_return
	pat := pat0
	tbl := &p.c.reg.blocks
	def := &tbl.types[pat.type]
	b = def.default
	for v, i in pat.props[:len(def.props)] {
		if v >= 0 {b = state_with(tbl, b, i, v)}
	}
	_ = first
	return b, true
}

// channel_ref: a channel named by id or by a bare name (the rule's namespace first, then
// voxiverse; refused when both have it).
@(private)
parse_channel :: proc(p: ^Rule_Parser) -> (id: int, ok: bool) {
	t, name_ok := expect(p, .Ident, "a channel name")
	if !name_ok {return}
	reg := p.c.reg
	if strings.contains_rune(t.text, ':') {
		full, valid := full_id(t.text)
		n: u32
		found: bool
		if valid {n, found = reg.ids[.Channel][full]}
		if !found {
			tok_fail(
				p,
				.Unknown_Channel,
				t,
				fmt.aprintf("\"%s\" is not a channel: name one a pack defines", t.text),
			)
			return
		}
		return int(n), true
	}
	own, own_ok := reg.ids[.Channel][fmt.aprintf("%s:%s", p.c.ns, t.text)]
	base_n, base_ok := reg.ids[.Channel][fmt.aprintf("%s:%s", BASE_NAMESPACE, t.text)]
	if p.c.ns == BASE_NAMESPACE {base_ok = false}
	if own_ok && base_ok {
		tok_fail(
			p,
			.Unknown_Channel,
			t,
			fmt.aprintf(
				"channel \"%s\" is in both %s and %s: write it in full",
				t.text,
				p.c.ns,
				BASE_NAMESPACE,
			),
		)
		return
	}
	if own_ok {return int(own), true}
	if base_ok {return int(base_n), true}
	if p.c.ns == BASE_NAMESPACE {
		if n, found := reg.ids[.Channel][fmt.aprintf("%s:%s", BASE_NAMESPACE, t.text)]; found {
			return int(n), true
		}
	}
	tok_fail(
		p,
		.Unknown_Channel,
		t,
		fmt.aprintf(
			"\"%s\" is not a channel of %s or %s: name a channel a pack defines",
			t.text,
			p.c.ns,
			BASE_NAMESPACE,
		),
	)
	return
}

computed_cost :: proc(k: Computed) -> i32 {
	switch k {
	case .None:
		return 1
	case .Light:
		return RULE_LIGHT_COST
	}
	return 1
}

// ---------------------------------------------------------------------------------------
// Cells, boxes, expressions, conditions.

@(private)
CELL_WORDS := [?]string{"self", "above", "below", "north", "south", "east", "west"}
@(private)
CELL_OFFSETS := [?][3]i8 {
	{0, 0, 0},
	{0, 1, 0},
	{0, -1, 0},
	{0, 0, -1},
	{0, 0, 1},
	{1, 0, 0},
	{-1, 0, 0},
}
@(private)
RESERVED_WORDS := [?]string {
	"self",
	"above",
	"below",
	"north",
	"south",
	"east",
	"west",
	"index",
	"box",
	"is",
	"not",
	"and",
	"or",
	"any",
	"count",
	"loaded",
}

@(private)
is_cell_start :: proc(p: ^Rule_Parser) -> bool {
	t := peek(p)
	if at_end(p) || t.kind != .Ident {return false}
	for w in CELL_WORDS {if t.text == w {return true}}
	for i in 0 ..< p.c.npicks {if p.c.picks[i] == t.text {return true}}
	return false
}

// looks_like_cell: a bare name that is not a cell but is used like one (followed by `is`,
// `not`, `.` or `[`): the user meant a pick that is not bound.
@(private)
looks_like_cell :: proc(p: ^Rule_Parser) -> bool {
	t := peek(p)
	if at_end(p) || t.kind != .Ident || strings.contains_rune(t.text, ':') || is_cell_start(p) {
		return false
	}
	for w in RESERVED_WORDS {if t.text == w {return false}}
	if p.pos + 1 >= p.toks.count {return false}
	n := p.toks.items[p.pos + 1]
	return n.kind == .Dot || n.kind == .L_Brack || word_is(n, "is") || word_is(n, "not")
}

// parse_cell: self, above, ..., a bound pick, optionally plus (dx, dy, dz). Changes
// nothing but the position.
@(private)
parse_cell :: proc(p: ^Rule_Parser) -> (cell: Rule_Cell, ok: bool) {
	t := peek(p)
	if at_end(p) || t.kind != .Ident {
		tok_fail(
			p,
			.Unknown_Cell,
			t,
			"expected a cell (self, above, below, north, south, east, west or a picked name): write one",
		)
		return
	}
	known := false
	for w, i in CELL_WORDS {
		if t.text == w {cell.off = CELL_OFFSETS[i]; known = true}
	}
	if !known {
		for i in 0 ..< p.c.npicks {
			if p.c.picks[i] == t.text {cell.slot = u8(i + 1); known = true}
		}
	}
	if !known {
		tok_fail(
			p,
			.Unknown_Cell,
			t,
			fmt.aprintf(
				"\"%s\" is not a cell: use self, above, below, north, south, east, west or a name bound by an earlier pick",
				t.text,
			),
		)
		return
	}
	p.pos += 1
	if peek(p).kind == .Plus && !at_end(p) {
		p.pos += 1
		if _, paren := expect(p, .L_Paren, "\"(\""); !paren {return}
		extra: [3]i32
		for i in 0 ..< 3 {
			n, n_ok := expect(p, .Int, "a whole number")
			if !n_ok {return}
			extra[i] = n.value
			if i < 2 {
				if _, comma := expect(p, .Comma, "\",\""); !comma {return}
			}
		}
		if _, close := expect(p, .R_Paren, "\")\""); !close {return}
		for i in 0 ..< 3 {
			if extra[i] < -RULE_REACH || extra[i] > RULE_REACH {
				tok_fail(
					p,
					.Reach,
					t,
					fmt.aprintf(
						"offset %d is over the reach of %d blocks from self: bring the cell closer",
						extra[i],
						RULE_REACH,
					),
				)
				return
			}
			cell.off[i] += i8(extra[i])
		}
	}
	// The reach: the cell's offset plus its pick's range.
	for i in 0 ..< 3 {
		lo, hi := i32(cell.off[i]), i32(cell.off[i])
		if cell.slot > 0 {
			lo += p.c.pick_lo[cell.slot - 1][i]
			hi += p.c.pick_hi[cell.slot - 1][i]
		}
		if lo < -RULE_REACH || hi > RULE_REACH {
			tok_fail(
				p,
				.Reach,
				t,
				fmt.aprintf(
					"cell \"%s\" is %d blocks from self, over the reach of %d: bring it closer",
					t.text,
					max(-lo, hi),
					RULE_REACH,
				),
			)
			return
		}
	}
	return cell, true
}

@(private)
emit :: proc(c: ^Rule_Compiler, op: Rule_Op) -> int {
	append(&c.code, op)
	return len(c.code) - 1
}

@(private)
name_index :: proc(c: ^Rule_Compiler, name: string) -> i32 {
	for n, i in c.names {if n == name {return i32(i)}}
	append(&c.names, strings.clone(name))
	return i32(len(c.names) - 1)
}

@(private)
prop_exists :: proc(reg: ^Registry, name: string) -> bool {
	for t in reg.blocks.types {
		for q in t.props {if q.name == name {return true}}
	}
	return false
}

// parse_expr: terms joined by + and -, in postfix.
@(private)
parse_expr :: proc(p: ^Rule_Parser) -> bool {
	parse_term(p) or_return
	for !at_end(p) && (peek(p).kind == .Plus || peek(p).kind == .Minus) {
		op := peek(p).kind
		p.pos += 1
		parse_term(p) or_return
		emit(p.c, {kind = .Add if op == .Plus else .Sub})
	}
	return true
}

@(private)
parse_term :: proc(p: ^Rule_Parser) -> bool {
	c := p.c
	t := peek(p)
	if at_end(p) {
		return tok_fail(
			p,
			.Syntax,
			t,
			"expected a number, a channel (cell.name), a property (cell[name]) or index(...): write one",
		)
	}
	if t.kind == .Int {
		p.pos += 1
		emit(c, {kind = .Lit, value = t.value})
		return true
	}
	if word_is(t, "index") {
		p.pos += 1
		expect(p, .L_Paren, "\"(\"") or_return
		expect(p, .Dollar, "\"$\" and a list id") or_return
		name := expect(p, .Ident, "a list id") or_return
		li, found := rule_list_of(c.reg, name.text)
		if !found {
			return tok_fail(
				p,
				.Unknown_List,
				name,
				fmt.aprintf(
					"\"$%s\" is not a list or a flow rule: name one a pack defines",
					name.text,
				),
			)
		}
		expect(p, .Comma, "\",\"") or_return
		cell := parse_cell(p) or_return
		expect(p, .R_Paren, "\")\"") or_return
		emit(c, {kind = .Index, cell = cell, ref = i32(li)})
		return true
	}
	if looks_like_cell(p) {
		parse_cell(p) or_return // (an unknown name: says so)
	}
	if is_cell_start(p) {
		cell := parse_cell(p) or_return
		nt := peek(p)
		if !at_end(p) && nt.kind == .Dot {
			p.pos += 1
			ch := parse_channel(p) or_return
			emit(c, {kind = .Chan, cell = cell, value = i32(ch)})
			return true
		}
		if !at_end(p) && nt.kind == .L_Brack {
			p.pos += 1
			name := expect(p, .Ident, "a property name") or_return
			expect(p, .R_Brack, "\"]\"") or_return
			if !prop_exists(c.reg, name.text) {
				return tok_fail(
					p,
					.Unknown_Property,
					name,
					fmt.aprintf(
						"no block has a property \"%s\": name a property some block type has",
						name.text,
					),
				)
			}
			emit(c, {kind = .Prop, cell = cell, ref = name_index(c, name.text)})
			return true
		}
		return tok_fail(
			p,
			.Syntax,
			nt,
			fmt.aprintf(
				"expected \".channel\" or \"[property]\" after the cell, found %s: a cell alone is not a number",
				describe(nt),
			),
		)
	}
	return tok_fail(
		p,
		.Syntax,
		t,
		fmt.aprintf(
			"expected a number, a channel (cell.name), a property (cell[name]) or index(...), found %s",
			describe(t),
		),
	)
}

// parse_range: `lo..hi` (or one number), as bytes inside -RULE_REACH..RULE_REACH.
@(private)
parse_range :: proc(p: ^Rule_Parser) -> (lo, hi: i32, ok: bool) {
	a := expect(p, .Int, "a whole number") or_return
	lo, hi = a.value, a.value
	if peek(p).kind == .Dot_Dot && !at_end(p) {
		p.pos += 1
		b := expect(p, .Int, "a whole number") or_return
		hi = b.value
	}
	if hi < lo {
		tok_fail(
			p,
			.Literal_Range,
			a,
			fmt.aprintf("the range %d..%d runs backwards: write the smaller number first", lo, hi),
		)
		return
	}
	if lo < -RULE_REACH || hi > RULE_REACH {
		tok_fail(
			p,
			.Reach,
			a,
			fmt.aprintf(
				"the range %d..%d is over the reach of %d blocks: bring it closer",
				lo,
				hi,
				RULE_REACH,
			),
		)
		return
	}
	return lo, hi, true
}

@(private)
parse_box :: proc(p: ^Rule_Parser) -> (lo, hi: [3]i8, ok: bool) {
	t := peek(p)
	expect_word(p, "box") or_return
	expect(p, .L_Paren, "\"(\"") or_return
	volume := i32(1)
	for i in 0 ..< 3 {
		at := peek(p)
		l, h := parse_range(p) or_return
		if h - l + 1 > RULE_MAX_BOX {
			tok_fail(
				p,
				.Box,
				at,
				fmt.aprintf(
					"a box %d blocks wide is over %d: make it narrower",
					h - l + 1,
					RULE_MAX_BOX,
				),
			)
			return
		}
		lo[i], hi[i] = i8(l), i8(h)
		volume *= h - l + 1
		if i < 2 {expect(p, .Comma, "\",\"") or_return}
	}
	expect(p, .R_Paren, "\")\"") or_return
	_ = t
	return lo, hi, true
}

@(private)
box_volume :: proc(lo, hi: [3]i8) -> i32 {
	return i32(hi.x - lo.x + 1) * i32(hi.y - lo.y + 1) * i32(hi.z - lo.z + 1)
}

@(private)
parse_cmp :: proc(p: ^Rule_Parser) -> (op: Rule_Cmp, ok: bool) {
	t := peek(p)
	if !at_end(p) {
		#partial switch t.kind {
		case .Eq:
			op, ok = .Eq, true
		case .Ne:
			op, ok = .Ne, true
		case .Lt:
			op, ok = .Lt, true
		case .Le:
			op, ok = .Le, true
		case .Gt:
			op, ok = .Gt, true
		case .Ge:
			op, ok = .Ge, true
		}
	}
	if !ok {
		tok_fail(
			p,
			.Syntax,
			t,
			fmt.aprintf(
				"expected a comparison (== != < <= > >=), found %s: write one",
				describe(t),
			),
		)
		return
	}
	p.pos += 1
	return
}

@(private)
parse_primary :: proc(p: ^Rule_Parser) -> bool {
	c := p.c
	t := peek(p)
	if !at_end(p) && t.kind == .L_Paren {
		p.pos += 1
		parse_cond(p) or_return
		expect(p, .R_Paren, "\")\"") or_return
		return true
	}
	if word_is(t, "loaded") {
		p.pos += 1
		cell := parse_cell(p) or_return
		emit(c, {kind = .Loaded, cell = cell})
		return true
	}
	if word_is(t, "any") {
		p.pos += 1
		lo, hi := parse_box(p) or_return
		expect_word(p, "is") or_return
		m := parse_matcher(p) or_return
		emit(c, {kind = .Any, ref = m, lo = lo, hi = hi})
		return true
	}
	if word_is(t, "count") {
		p.pos += 1
		lo, hi := parse_box(p) or_return
		expect_word(p, "is") or_return
		m := parse_matcher(p) or_return
		op := parse_cmp(p) or_return
		n := expect(p, .Int, "a whole number") or_return
		if n.value < 0 || n.value > 729 {
			return tok_fail(
				p,
				.Literal_Range,
				n,
				fmt.aprintf("a count is 0..729, not %d: use a number in range", n.value),
			)
		}
		emit(c, {kind = .Count, ref = m, lo = lo, hi = hi, cmp = op, value = n.value})
		return true
	}
	if looks_like_cell(p) {
		parse_cell(p) or_return // (an unknown name: says so)
	}
	if is_cell_start(p) {
		save := p.pos
		cell := parse_cell(p) or_return
		nt := peek(p)
		if !at_end(p) && (word_is(nt, "is") || word_is(nt, "not")) {
			p.pos += 1
			m := parse_matcher(p) or_return
			emit(c, {kind = .Is if word_is(nt, "is") else .Not, cell = cell, ref = m})
			return true
		}
		p.pos = save
	}
	parse_expr(p) or_return
	op := parse_cmp(p) or_return
	parse_expr(p) or_return
	emit(c, {kind = .Cmp, cmp = op})
	return true
}

@(private)
parse_and :: proc(p: ^Rule_Parser) -> bool {
	parse_primary(p) or_return
	for !at_end(p) && word_is(peek(p), "and") {
		p.pos += 1
		j := emit(p.c, {kind = .And_Jump})
		parse_primary(p) or_return
		p.c.code[j].value = i32(len(p.c.code) - j - 1)
	}
	return true
}

@(private)
parse_cond :: proc(p: ^Rule_Parser) -> bool {
	parse_and(p) or_return
	for !at_end(p) && word_is(peek(p), "or") {
		p.pos += 1
		j := emit(p.c, {kind = .Or_Jump})
		parse_and(p) or_return
		p.c.code[j].value = i32(len(p.c.code) - j - 1)
	}
	return true
}

// ---------------------------------------------------------------------------------------
// Statements.

@(private)
lex_value :: proc(c: ^Rule_Compiler, v: Json_Value, p: ^Rule_Parser) -> bool {
	p.c = c
	p.value = v
	err, el, ec := rule_lex(v.s, v.line, v.column, &p.toks)
	end_col := v.column + 1 + i32(len(v.s))
	p.end = {
		kind   = .Ident,
		text   = "",
		line   = v.line,
		column = end_col,
	}
	switch err {
	case .None:
		return true
	case .Escapes:
		rule_fail(
			c,
			.Lex,
			el,
			ec,
			"a rule statement may not contain escapes or control characters: write it plainly",
		)
	case .Too_Long:
		rule_fail(
			c,
			.Lex,
			el,
			ec,
			fmt.aprintf("statement too long (over %d tokens): split it", MAX_RULE_TOKENS),
		)
	case .Bad_Character:
		rule_fail(c, .Lex, el, ec, "this character is not part of the rule language: remove it")
	case .Bad_Number:
		rule_fail(c, .Lex, el, ec, "this number is too large: use a smaller one")
	}
	return false
}

@(private)
finish :: proc(p: ^Rule_Parser) -> bool {
	if !at_end(p) {
		t := peek(p)
		return tok_fail(
			p,
			.Syntax,
			t,
			fmt.aprintf("unexpected %s after the statement: remove it", describe(t)),
		)
	}
	return true
}

@(private)
parse_statement :: proc(c: ^Rule_Compiler, v: Json_Value) -> (s: Rule_Stmt, ok: bool) {
	s = {
		next  = -1,
		child = -1,
		other = -1,
	}
	if v.kind != .String {
		rule_fail(
			c,
			.Syntax,
			v.line,
			v.column,
			"a statement is a string or an {\"if\"...} or {\"repeat\"...} object: write one",
		)
		return
	}
	p: Rule_Parser
	lex_value(c, v, &p) or_return
	word := peek(&p)
	if at_end(&p) {
		tok_fail(&p, .Unknown_Statement, word, "an empty statement: write one or remove it")
		return
	}
	p.pos += 1
	s.code_from = i32(len(c.code))
	switch word.text {
	case "require":
		s.kind = .Require
		parse_cond(&p) or_return
	case "chance":
		s.kind = .Chance
		n := expect(&p, .Int, "a whole number 2..65536") or_return
		if n.value < 2 || n.value > 65536 {
			tok_fail(
				&p,
				.Literal_Range,
				n,
				fmt.aprintf("chance %d is out of range: use 2..65536", n.value),
			)
			return
		}
		s.value = n.value
	case "pick":
		s.kind = .Pick
		name := expect(&p, .Ident, "a name for the cell") or_return
		for w in RESERVED_WORDS {
			if name.text == w || strings.contains_rune(name.text, ':') {
				tok_fail(
					&p,
					.Pick,
					name,
					fmt.aprintf("\"%s\" cannot name a pick: use another name", name.text),
				)
				return
			}
		}
		for i in 0 ..< c.npicks {
			if c.picks[i] == name.text {
				tok_fail(
					&p,
					.Pick,
					name,
					fmt.aprintf(
						"pick \"%s\" is bound twice: give the second another name",
						name.text,
					),
				)
				return
			}
		}
		if c.npicks == RULE_MAX_PICKS {
			tok_fail(
				&p,
				.Pick,
				name,
				fmt.aprintf(
					"more than %d picks in a rule: reuse a name's cell or drop one",
					RULE_MAX_PICKS,
				),
			)
			return
		}
		slot := c.npicks
		for i in 0 ..< 3 {
			l, h := parse_range(&p) or_return
			s.lo[i], s.hi[i] = i8(l), i8(h)
			c.pick_lo[slot][i], c.pick_hi[slot][i] = l, h
		}
		c.picks[slot] = strings.clone(name.text)
		c.npicks += 1
		s.slot = u8(c.npicks)
	case "set":
		s.kind = .Set_Block
		cell := parse_cell(&p) or_return
		s.cell = cell
		nt := peek(&p)
		switch {
		case at_end(&p):
			tok_fail(
				&p,
				.Syntax,
				nt,
				"expected a block, $list[...], .channel or [property] after the cell",
			)
			return
		case nt.kind == .Dollar:
			p.pos += 1
			name := expect(&p, .Ident, "a list id") or_return
			li, found := rule_list_of(c.reg, name.text)
			if !found {
				tok_fail(
					&p,
					.Unknown_List,
					name,
					fmt.aprintf(
						"\"$%s\" is not a list or a flow rule: name one a pack defines",
						name.text,
					),
				)
				return
			}
			expect(&p, .L_Brack, "\"[\"") or_return
			s.kind, s.ref = .Set_List, i32(li)
			s.code_from = i32(len(c.code))
			parse_expr(&p) or_return
			expect(&p, .R_Brack, "\"]\"") or_return
		case nt.kind == .Dot:
			p.pos += 1
			cn := peek(&p)
			ch := parse_channel(&p) or_return
			if c.reg.channels[ch].computed != .None {
				tok_fail(
					&p,
					.Computed_Channel_Set,
					cn,
					fmt.aprintf(
						"channel \"%s\" is computed and cannot be set: set a stored channel",
						cn.text,
					),
				)
				return
			}
			s.kind, s.value = .Set_Channel, i32(ch)
			s.code_from = i32(len(c.code))
			parse_expr(&p) or_return
		case nt.kind == .L_Brack:
			p.pos += 1
			name := expect(&p, .Ident, "a property name") or_return
			expect(&p, .R_Brack, "\"]\"") or_return
			if !prop_exists(c.reg, name.text) {
				tok_fail(
					&p,
					.Unknown_Property,
					name,
					fmt.aprintf(
						"no block has a property \"%s\": name a property some block type has",
						name.text,
					),
				)
				return
			}
			s.kind, s.ref = .Set_Prop, name_index(c, name.text)
			s.code_from = i32(len(c.code))
			parse_expr(&p) or_return
		case:
			blk := parse_block_value(&p) or_return
			s.value = i32(blk)
		}
	case "schedule":
		s.kind = .Schedule
		s.cell = parse_cell(&p) or_return
		n := expect(&p, .Int, "a number of ticks 1..1200") or_return
		if n.value < 1 || n.value > 1200 {
			tok_fail(
				&p,
				.Literal_Range,
				n,
				fmt.aprintf("schedule %d ticks is out of range: use 1..1200", n.value),
			)
			return
		}
		s.value = n.value
	case "stop":
		s.kind = .Stop
	case:
		tok_fail(
			&p,
			.Unknown_Statement,
			word,
			fmt.aprintf(
				"unknown statement word \"%s\": use require, chance, pick, set, schedule or stop",
				word.text,
			),
		)
		return
	}
	finish(&p) or_return
	s.code_len = i32(len(c.code)) - s.code_from
	return s, true
}

@(private)
add_stmt :: proc(c: ^Rule_Compiler, s: Rule_Stmt, at: Json_Value) -> (int, bool) {
	if len(c.stmts) >= RULE_MAX_STATEMENTS {
		rule_fail(
			c,
			.Too_Many_Statements,
			at.line,
			at.column,
			fmt.aprintf("more than %d statements in a rule: split the rule", RULE_MAX_STATEMENTS),
		)
		return 0, false
	}
	append(&c.stmts, s)
	return len(c.stmts) - 1, true
}

// parse_items: a `do` array; the statements are linked through `next`. Returns the first
// (-1 if every item failed). Parsing goes on past a bad item.
@(private)
parse_items :: proc(c: ^Rule_Compiler, items: Json_Value, nested: bool) -> (first: i32, ok: bool) {
	first = -1
	ok = true
	if items.kind != .Array || len(items.items) < 1 || len(items.items) > RULE_MAX_STATEMENTS {
		rule_fail(
			c,
			.Envelope,
			items.line,
			items.column,
			fmt.aprintf(
				"\"do\" is an array of 1 to %d statements: write the statements",
				RULE_MAX_STATEMENTS,
			),
		)
		return -1, false
	}
	last := -1
	for item in items.items {
		at := -1
		item_ok := false
		if item.kind == .Object {
			at, item_ok = parse_object(c, item)
		} else {
			saved := len(c.code)
			s, parsed := parse_statement(c, item)
			if parsed {
				at, item_ok = add_stmt(c, s, item)
			}
			if !item_ok {resize(&c.code, saved)}
		}
		if !item_ok {ok = false; continue}
		if last >= 0 {c.stmts[last].next = i32(at)} else {first = i32(at)}
		last = at
	}
	return
}

@(private)
object_member :: proc(v: Json_Value, key: string) -> (Json_Member, bool) {
	for m in v.members {if m.key == key {return m, true}}
	return {}, false
}

@(private)
parse_object :: proc(c: ^Rule_Compiler, v: Json_Value) -> (at: int, ok: bool) {
	_, is_if := object_member(v, "if")
	_, is_repeat := object_member(v, "repeat")
	if is_if == is_repeat {
		rule_fail(
			c,
			.Syntax,
			v.line,
			v.column,
			"an object statement has \"if\" (with \"then\", \"else\") or \"repeat\" (with \"do\"): write one of them",
		)
		return
	}
	allowed := []string{"if", "then", "else"} if is_if else []string{"repeat", "do"}
	for m in v.members {
		known := false
		for a in allowed {if m.key == a {known = true}}
		if !known {
			rule_fail(
				c,
				.Syntax,
				m.key_line,
				m.key_column,
				fmt.aprintf(
					"\"%s\" is not part of this statement: it has %s",
					m.key,
					strings.join(allowed, ", ", context.temp_allocator),
				),
			)
			return
		}
	}
	return parse_branch(c, v, is_if, false)
}

@(private)
parse_branch :: proc(
	c: ^Rule_Compiler,
	v: Json_Value,
	is_if: bool,
	is_else_if: bool,
) -> (
	at: int,
	ok: bool,
) {
	if !is_else_if {
		if c.depth == RULE_MAX_DEPTH {
			rule_fail(
				c,
				.Too_Deep,
				v.line,
				v.column,
				fmt.aprintf("nested deeper than %d: flatten the rule", RULE_MAX_DEPTH),
			)
			return
		}
		c.depth += 1
	}
	defer if !is_else_if {c.depth -= 1}
	s := Rule_Stmt {
		next  = -1,
		child = -1,
		other = -1,
	}
	if is_if {
		s.kind = .If
		cond, _ := object_member(v, "if")
		then, has_then := object_member(v, "then")
		if cond.value.kind != .String {
			rule_fail(
				c,
				.Syntax,
				cond.value.line,
				cond.value.column,
				"\"if\" is a condition string: write one",
			)
			return
		}
		p: Rule_Parser
		lex_value(c, cond.value, &p) or_return
		s.code_from = i32(len(c.code))
		saved := len(c.code)
		if !parse_cond(&p) || !finish(&p) {
			resize(&c.code, saved)
			return
		}
		s.code_len = i32(len(c.code)) - s.code_from
		if !has_then {
			rule_fail(
				c,
				.Syntax,
				v.line,
				v.column,
				"an \"if\" needs \"then\": write the statements to run",
			)
			return
		}
		at = len(c.stmts)
		slot, added := add_stmt(c, s, v)
		if !added {return}
		at = slot
		first, then_ok := parse_items(c, then.value, true)
		c.stmts[at].child = first
		ok = then_ok
		if els, has_else := object_member(v, "else"); has_else {
			// An else holding exactly one `if` is "else if": no extra nesting.
			single_if := false
			if els.value.kind == .Array &&
			   len(els.value.items) == 1 &&
			   els.value.items[0].kind == .Object {
				_, single_if = object_member(els.value.items[0], "if")
			}
			if single_if {
				child := els.value.items[0]
				for m in child.members {
					if m.key != "if" && m.key != "then" && m.key != "else" {
						rule_fail(
							c,
							.Syntax,
							m.key_line,
							m.key_column,
							fmt.aprintf(
								"\"%s\" is not part of this statement: it has if, then, else",
								m.key,
							),
						)
						return at, false
					}
				}
				e_at, e_ok := parse_branch(c, child, true, true)
				if e_ok {c.stmts[at].other = i32(e_at)}
				ok = ok && e_ok
			} else {
				e_first, e_ok := parse_items(c, els.value, true)
				c.stmts[at].other = e_first
				ok = ok && e_ok
			}
		}
		return at, ok
	}
	s.kind = .Repeat
	n, _ := object_member(v, "repeat")
	body, has_body := object_member(v, "do")
	if n.value.kind != .Int || n.value.i < 1 || n.value.i > 16 {
		rule_fail(
			c,
			.Literal_Range,
			n.value.line,
			n.value.column,
			"\"repeat\" is a whole number 1..16: use a number in range",
		)
		return
	}
	if !has_body {
		rule_fail(
			c,
			.Syntax,
			v.line,
			v.column,
			"a \"repeat\" needs \"do\": write the statements to repeat",
		)
		return
	}
	s.value = i32(n.value.i)
	slot, added := add_stmt(c, s, v)
	if !added {return}
	first, body_ok := parse_items(c, body.value, true)
	c.stmts[slot].child = first
	return slot, body_ok
}

// ---------------------------------------------------------------------------------------
// Costs.

@(private)
op_cost :: proc(c: ^Rule_Compiler, op: Rule_Op) -> i32 {
	switch op.kind {
	case .Lit, .Add, .Sub, .Cmp, .And_Jump, .Or_Jump:
		return 0
	case .Chan:
		return computed_cost(c.reg.channels[op.value].computed)
	case .Prop, .Index, .Is, .Not, .Loaded:
		return 1
	case .Any, .Count:
		return box_volume(op.lo, op.hi)
	}
	return 0
}

@(private)
code_cost :: proc(c: ^Rule_Compiler, from, len_: i32) -> i32 {
	total := i32(0)
	for op in c.code[from:from + len_] {total += op_cost(c, op)}
	return total
}

@(private)
chain_cost :: proc(c: ^Rule_Compiler, first: i32) -> i32 {
	total := i32(0)
	i := first
	for i >= 0 {
		s := c.stmts[i]
		total += 1 + code_cost(c, s.code_from, s.code_len)
		#partial switch s.kind {
		case .If:
			total += chain_cost(c, s.child) + chain_cost(c, s.other)
		case .Repeat:
			total += s.value * chain_cost(c, s.child)
		}
		total = min(total, 1 << 28)
		i = s.next
	}
	return total
}

// ---------------------------------------------------------------------------------------
// The entry points.

// rule_compile: the `blocks` and `do` of a statement rule, compiled. On refusals, the
// errors are in b (nothing is returned for the rule). refusal is the first one's code.
@(private)
rule_compile :: proc(
	b: ^Reg_Build,
	reg: ^Registry,
	m: ^Merged_Def,
	blocks_field, do_field: ^Def_Field,
) -> (
	prog: Rule_Program,
	refusal: Rule_Refusal,
) {
	c := Rule_Compiler {
		b   = b,
		reg = reg,
		m   = m,
		ns  = b.sources[m.pack].namespace,
	}
	// The cells the rule runs on.
	prog.blocks = new_matcher(&c)
	bv := blocks_field.value
	if bv.kind != .Array || len(bv.items) < 1 || len(bv.items) > RULE_MAX_BLOCKS {
		rule_fail(
			&c,
			.Envelope,
			bv.line,
			bv.column,
			fmt.aprintf(
				"\"blocks\" is an array of 1 to %d block matchers: write the blocks the rule runs on",
				RULE_MAX_BLOCKS,
			),
		)
	} else {
		for item in bv.items {
			if item.kind != .String {
				rule_fail(
					&c,
					.Envelope,
					item.line,
					item.column,
					"a block matcher is a string: write one",
				)
				continue
			}
			p: Rule_Parser
			if !lex_value(&c, item, &p) {continue}
			if parse_matcher_into(&p, &prog.blocks) {finish(&p)}
		}
	}
	first, _ := parse_items(&c, do_field.value, false)
	if c.errors == 0 {
		cost := chain_cost(&c, first)
		if cost > RULE_MAX_COST {
			rule_fail(
				&c,
				.Too_Costly,
				do_field.value.line,
				do_field.value.column,
				fmt.aprintf(
					"rule %s costs up to %d cell reads a run, over %d: shrink the box or the repeat",
					m.id,
					cost,
					RULE_MAX_COST,
				),
			)
		}
		prog.cost = cost
	}
	if c.errors > 0 {return {}, c.first}
	prog.stmts = c.stmts[:]
	prog.first = first
	prog.code = c.code[:]
	prog.matchers = c.matchers[:]
	prog.names = c.names[:]
	prog.picks = u8(c.npicks)
	return prog, .None
}

// read_rule_list: a list entry: 1..64 block values, in order.
@(private)
read_rule_list :: proc(
	b: ^Reg_Build,
	reg: ^Registry,
	m: ^Merged_Def,
	f: ^Def_Field,
) -> (
	l: Rule_List,
	ok: bool,
) {
	c := Rule_Compiler {
		b   = b,
		reg = reg,
		m   = m,
		ns  = b.sources[m.pack].namespace,
	}
	l.id = m.id
	v := f.value
	if v.kind != .Array || len(v.items) < 1 || len(v.items) > RULE_MAX_LIST {
		rule_fail(
			&c,
			.List_Shape,
			v.line,
			v.column,
			fmt.aprintf(
				"\"list\" is an array of 1 to %d block values: write the blocks in order",
				RULE_MAX_LIST,
			),
		)
		return
	}
	blocks := make([dynamic]Block)
	for item in v.items {
		if item.kind != .String {
			rule_fail(
				&c,
				.List_Shape,
				item.line,
				item.column,
				"a list member is a block id or state string: write one",
			)
			continue
		}
		p: Rule_Parser
		if !lex_value(&c, item, &p) {continue}
		pat0, pat_ok := parse_pattern(&p)
		if !pat_ok {continue}
		pat := pat0
		def := &reg.blocks.types[pat.type]
		if pat.given < len(def.props) {
			// More than one state matches unless the type has a single one.
			count := 0
			for i in 0 ..< int(def.state_count) {
				if pattern_matches(&p, pat, Block(int(def.first_state) + i)) {count += 1}
			}
			if count != 1 {
				rule_fail(
					&c,
					.List_Shape,
					item.line,
					item.column + 1,
					fmt.aprintf(
						"\"%s\" names %d states, a list member is one block value: write a state such as \"%s[...]\"",
						item.s,
						count,
						def.id,
					),
				)
				continue
			}
		}
		blk := def.default
		for v, i in pat.props[:len(def.props)] {
			if v >= 0 {blk = state_with(&reg.blocks, blk, i, v)}
		}
		if finish(&p) {append(&blocks, blk)}
	}
	if c.errors > 0 {return}
	l.blocks = blocks[:]
	return l, true
}
