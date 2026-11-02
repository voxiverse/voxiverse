package script

import "core:fmt"
import "core:strings"

// The syntax tree, built by the parser in the compile's scratch arena. Annotations are
// kept in it (ty, and the T_* kinds) and erased by the compiler.

Node_Kind :: enum u8 {
	// Expressions.
	Nil,
	True,
	False,
	Int,
	Float,
	String,
	Vararg,
	Function, // list: params (Binding), flag: vararg, a: vararg type, b: return type, body
	Name,
	Index, // a[b]
	Call, // a(list)
	Method_Call, // a:name(list)
	Paren,
	Table, // list: fields
	Binop, // a op b
	Unop, // op a
	// Table fields.
	Field_Pos, // a
	Field_Named, // name = a
	Field_Keyed, // [a] = b
	// Statements.
	Local, // list: bindings, list2: values
	Assign, // list: targets, list2: values
	Compound, // a op= b
	Call_Stat, // a
	Do, // body
	While, // while a do body
	Repeat, // repeat body until a
	If, // list: clauses (a then body), flag: has else, list2: else body
	Clause,
	Numeric_For, // for a = b, c [, d] do body
	Generic_For, // for list in list2 do body
	Function_Stat, // function a (a name path; flag: method) b (the function)
	Local_Function, // local function name b
	Return, // list
	Break,
	Continue,
	Type_Alias, // type name = ty
	Binding, // name [: ty]
	// Types (parsed, then erased).
	T_Name, // name (qualified: name.name2 in name)
	T_Nil,
	T_Optional, // a?
	T_Union, // list
	T_Array, // {a}
	T_Map, // {[a]: b}
	T_Record, // list: T_Field
	T_Field, // name: a
	T_Func, // (list) -> a
	T_Tuple, // (list)
}

Node :: struct {
	kind:       Node_Kind,
	op:         Tok,
	flag:       bool,
	line:       u32,
	col:        u32,
	len:        u32,
	end_line:   u32,
	name:       string,
	ival:       i64,
	fval:       f64,
	a, b, c, d: ^Node,
	ty:         ^Node,
	list:       []^Node,
	list2:      []^Node,
	body:       []^Node,
}

// ast_dump writes a node as an indented tree (the parser tests compare it with a file).
ast_dump :: proc(b: ^strings.Builder, n: ^Node, depth := 0) {
	for _ in 0 ..< depth {strings.write_string(b, "  ")}
	if n == nil {
		strings.write_string(b, "-\n")
		return
	}
	fmt.sbprintf(b, "%v %d:%d", n.kind, n.line, n.col)
	#partial switch n.kind {
	case .Int:
		fmt.sbprintf(b, " %d", n.ival)
	case .Float:
		fmt.sbprintf(b, " %v", n.fval)
	case .String:
		fmt.sbprintf(b, " %q", n.name)
	case .Binop, .Unop, .Compound:
		fmt.sbprintf(b, " %s", TOKEN_TEXT[n.op])
	}
	if n.name != "" && n.kind != .String {fmt.sbprintf(b, " %s", n.name)}
	if n.flag {strings.write_string(b, " +")}
	strings.write_byte(b, '\n')
	for child in ([4]^Node{n.a, n.b, n.c, n.d}) {
		if child != nil {ast_dump(b, child, depth + 1)}
	}
	if n.ty != nil {
		for _ in 0 ..< depth + 1 {strings.write_string(b, "  ")}
		strings.write_string(b, "type:\n")
		ast_dump(b, n.ty, depth + 2)
	}
	lists := [3][]^Node{n.list, n.list2, n.body}
	names := [3]string{"list", "list2", "body"}
	for l, i in lists {
		if len(l) == 0 {continue}
		for _ in 0 ..< depth + 1 {strings.write_string(b, "  ")}
		fmt.sbprintf(b, "%s:\n", names[i])
		for child in l {ast_dump(b, child, depth + 2)}
	}
}
