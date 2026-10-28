package game

import "core:fmt"
import "core:strings"

// Block states: a Block is a state id. A type owns a run of consecutive ids,
// one per combination of its properties' values: the index within the type
// is mixed-radix, the last property fastest (registry.odin's Type_Def).

block_type_of :: #force_inline proc(t: ^Block_Table, b: Block) -> Block_Type {
	return t.type_of[b]
}

// type_stride: the weight of property prop in a state index.
type_stride :: proc(def: ^Type_Def, prop: int) -> int {
	stride := 1
	for i := len(def.props) - 1; i > prop; i -= 1 {stride *= len(def.props[i].values)}
	return stride
}

// state_value: the index of b's value of property prop (0 for no such property).
state_value :: proc(t: ^Block_Table, b: Block, prop: int) -> int {
	def := &t.types[t.type_of[b]]
	if prop < 0 || prop >= len(def.props) {return 0}
	index := int(b) - int(def.first_state)
	return index / type_stride(def, prop) % len(def.props[prop].values)
}

// state_with: b with property prop set to value (b itself when either is out of range).
state_with :: proc(t: ^Block_Table, b: Block, prop, value: int) -> Block {
	def := &t.types[t.type_of[b]]
	if prop < 0 || prop >= len(def.props) {return b}
	if value < 0 || value >= len(def.props[prop].values) {return b}
	stride := type_stride(def, prop)
	old := state_value(t, b, prop)
	return Block(int(b) + (value - old) * stride)
}

// prop_index: the number of the property of a type called name.
prop_index :: proc(t: ^Block_Table, type: Block_Type, name: string) -> (int, bool) {
	for p, i in t.types[type].props {if p.name == name {return i, true}}
	return 0, false
}

prop_value_index :: proc(p: Prop_Def, value: string) -> (int, bool) {
	for v, i in p.values {if v == value {return i, true}}
	return 0, false
}

// state_text: b as `voxiverse:planks_stairs[facing=east,half=top]`: every
// property in declared order; a type without properties is its id alone.
state_text :: proc(reg: ^Registry, b: Block, allocator := context.temp_allocator) -> string {
	t := &reg.blocks
	if !block_valid(t, u16(b)) {return ""}
	def := &t.types[t.type_of[b]]
	if len(def.props) == 0 {return def.id}
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, def.id)
	strings.write_byte(&sb, '[')
	for p, i in def.props {
		if i > 0 {strings.write_byte(&sb, ',')}
		fmt.sbprintf(&sb, "%s=%s", p.name, p.values[state_value(t, b, i)])
	}
	strings.write_byte(&sb, ']')
	return strings.to_string(sb)
}

// state_parse: the state text names; a property left out takes the default's
// value; an unknown type, property or value fails.
state_parse :: proc(reg: ^Registry, text: string) -> (Block, bool) {
	t := &reg.blocks
	open := strings.index_byte(text, '[')
	head := text if open < 0 else text[:open]
	id, ok := id_parse(head)
	if !ok {return .Air, false}
	buf: [96]u8
	full := fmt.bprintf(buf[:], "%s:%s", id.namespace, id.name)
	n, found := reg.ids[.Block][full]
	if !found {return .Air, false}
	b := Block(n)
	if open < 0 {return b, true}
	if !strings.has_suffix(text, "]") {return .Air, false}
	body := text[open + 1:len(text) - 1]
	if body == "" {return b, true}
	seen: [MAX_PROPS]bool
	type := t.type_of[b]
	for part in strings.split_iterator(&body, ",") {
		eq := strings.index_byte(part, '=')
		if eq < 0 {return .Air, false}
		pi, pok := prop_index(t, type, part[:eq])
		if !pok || seen[pi] {return .Air, false}
		seen[pi] = true
		vi, vok := prop_value_index(t.types[type].props[pi], part[eq + 1:])
		if !vok {return .Air, false}
		b = state_with(t, b, pi, vi)
	}
	return b, true
}
