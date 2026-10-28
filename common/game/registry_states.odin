package game

import "core:fmt"
import "core:slice"
import "core:strings"

// Resolving block states, rules and shapes (registry_resolve.odin calls these).

@(private)
type_state_count :: proc(props: []Prop_Def) -> int {
	n := 1
	for p in props {n *= len(p.values)}
	return n
}

// read_states: a block's properties (`states`) and the index of its default
// state (`default`: each property's value; absent, each property's first).
@(private)
read_states :: proc(b: ^Reg_Build, m: ^Merged_Def, builtin: bool) -> (props: []Prop_Def, default_index: int) {
	f := field_of(m, "states")
	if f == nil {
		if g := field_of(m, "default"); g != nil {
			fail_field(b, g, g.value, "default needs \"states\"; a block without states has one state")
		}
		return nil, 0
	}
	if builtin {
		fail_field(
			b,
			f,
			f.value,
			fmt.aprintf("%s is named by the engine and keeps one state", m.id),
		)
		return nil, 0
	}
	if f.value.kind != .Object {
		fail_field(b, f, f.value, "states is an object: {\"name\": [\"value\", ...]} or {\"name\": \"bool\"}")
		return nil, 0
	}
	if len(f.value.members) > MAX_PROPS {
		fail_field(
			b,
			f,
			f.value,
			fmt.aprintf("%d properties; a block has at most %d", len(f.value.members), MAX_PROPS),
		)
		return nil, 0
	}
	list := make([dynamic]Prop_Def)
	count := 1
	for pm in f.value.members {
		if !id_part_valid(pm.key, 32) {
			fail_field(b, f, pm.value, fmt.aprintf("\"%s\" is not a property name; use 1 to 32 of a-z, 0-9 and _", pm.key))
			continue
		}
		p := Prop_Def {
			name = pm.key,
		}
		#partial switch pm.value.kind {
		case .String:
			if pm.value.s == "bool" {
				p.values = make([]string, 2)
				p.values[0], p.values[1] = "false", "true"
			} else {
				fail_field(b, f, pm.value, "a property's values are a list, or \"bool\"")
				continue
			}
		case .Array:
			vals := make([dynamic]string)
			for x in pm.value.items {
				if x.kind != .String || !id_part_valid(x.s, 32) {
					fail_field(b, f, x, "a value is a name of 1 to 32 of a-z, 0-9 and _")
					continue
				}
				if slice.contains(vals[:], x.s) {
					fail_field(b, f, x, fmt.aprintf("\"%s\" is listed twice in %s", x.s, pm.key))
					continue
				}
				append(&vals, x.s)
			}
			if len(vals) < 2 || len(vals) > MAX_PROP_VALUES {
				fail_field(
					b,
					f,
					pm.value,
					fmt.aprintf("%s has %d values; a property has 2 to %d", pm.key, len(vals), MAX_PROP_VALUES),
				)
				continue
			}
			p.values = vals[:]
		case:
			fail_field(b, f, pm.value, "a property's values are a list, or \"bool\"")
			continue
		}
		append(&list, p)
		count *= len(p.values)
	}
	if len(list) != len(f.value.members) {return nil, 0}
	if count > MAX_TYPE_STATES {
		fail_field(
			b,
			f,
			f.value,
			fmt.aprintf("%d states; a block has at most %d", count, MAX_TYPE_STATES),
		)
		return nil, 0
	}
	props = list[:]
	// The default.
	chosen := make([]int, len(props))
	if g := field_of(m, "default"); g != nil {
		if g.value.kind != .Object {
			fail_field(b, g, g.value, "default is an object: {\"property\": \"value\"}")
		} else {
			for dm in g.value.members {
				pi := -1
				for p, i in props {if p.name == dm.key {pi = i}}
				if pi < 0 {
					names := make([]string, len(props))
					for p, i in props {names[i] = p.name}
					fail_field(
						b,
						g,
						dm.value,
						fmt.aprintf("\"%s\" is not a property of this block%s", dm.key, suggestion(dm.key, names)),
					)
					continue
				}
				vi := -1
				if dm.value.kind == .String {
					found: bool
					vi, found = prop_value_index(props[pi], dm.value.s)
					if !found {vi = -1}
				}
				if vi < 0 {
					fail_field(
						b,
						g,
						dm.value,
						fmt.aprintf(
							"%s is not a value of %s; the values are %s",
							dm.value.s,
							dm.key,
							join_quoted(props[pi].values),
						),
					)
					continue
				}
				chosen[pi] = vi
			}
		}
	}
	for p, i in props {default_index = default_index * len(p.values) + chosen[i]}
	return
}

// read_block_rules: place and climbable.
@(private)
read_block_rules :: proc(b: ^Reg_Build, def: ^Type_Def, m: ^Merged_Def) {
	def.place = Place_Rule(rd_choice(b, m, "place", PLACE_RULE_LIST[:], 0))
	def.climbable = rd_bool(b, m, "climbable", false)
}

// shape_ref_of: what a shape field names.
@(private)
Shape_Choice :: struct {
	id:     u16, // SHAPE_EMPTY or SHAPE_CUBE, when source < 0
	source: int, // the shape definition's index, or -1
}

NO_SHAPE :: ~u16(0)

@(private)
read_shapes :: proc(b: ^Reg_Build, reg: ^Registry, blocks: []Merged_Def, order, first_state: []int) {
	t := &reg.blocks
	sb: Shape_Builder
	shape_builder_init(&sb)
	sources := make([]Shape_Source, len(b.defs[.Shape]))
	for &m, i in b.defs[.Shape] {sources[i] = read_shape_source(b, &m)}
	checked := make(map[[2]int]bool) // (shape, block type) pairs already checked

	choose :: proc(
		b: ^Reg_Build,
		m: ^Merged_Def,
		field: string,
	) -> (
		c: Shape_Choice,
		present: bool,
	) {
		f := field_of(m, field)
		if f == nil {return {}, false}
		if f.value.kind != .String {
			fail_field(b, f, f.value, fmt.aprintf("%s is \"cube\", \"empty\" or a shape id", field))
			return {NO_SHAPE, -1}, true
		}
		switch f.value.s {
		case "cube":
			return {SHAPE_CUBE, -1}, true
		case "empty":
			return {SHAPE_EMPTY, -1}, true
		}
		at, ok := ref_index(b, .Shape, f.value.s, f, f.value)
		if !ok {return {0, -1}, true}
		return {0, at}, true
	}

	for n in 0 ..< len(blocks) {
		m := &blocks[order[n]]
		fs := first_state[n]
		def := &t.types[n]
		render := t.defs[fs].render
		flags := t.flags[fs]
		// Defaults, as the render and the flags say.
		coll_default := SHAPE_CUBE if .Collides in flags else SHAPE_EMPTY
		sel_default := SHAPE_CUBE if render != .None else SHAPE_EMPTY
		render_default := SHAPE_CUBE if render == .Cube else SHAPE_EMPTY
		one, has_one := choose(b, m, "shape")
		coll, has_coll := choose(b, m, "collision")
		sel, has_sel := choose(b, m, "selection")
		rend, has_rend := choose(b, m, "render_shape")
		pick :: proc(own: Shape_Choice, has_own: bool, one: Shape_Choice, has_one: bool, fallback: u16) -> Shape_Choice {
			if has_own {return own}
			if has_one {return one}
			return {fallback, -1}
		}
		uses := [3]Shape_Choice {
			pick(coll, has_coll, one, has_one, coll_default),
			pick(sel, has_sel, one, has_one, sel_default),
			pick(rend, has_rend, one, has_one, render_default),
		}
		for use in uses {
			if use.id == NO_SHAPE && use.source < 0 {continue} // an error was reported
			if use.source >= 0 {
				if !checked[{use.source, n}] {
					checked[{use.source, n}] = true
					check_shape_against(b, &sources[use.source], m, def.props)
				}
			}
		}
		if len(b.errs) > 0 {continue}
		values := make([]int, len(def.props))
		tall_reported := false
		for k in 0 ..< int(def.state_count) {
			for _, pi in def.props {values[pi] = state_value(t, Block(fs + k), pi)}
			for use, ui in uses {
				id := use.id
				if use.source >= 0 {
					boxes := shape_for_state(&sources[use.source], def.props, values)
					if ui != 0 && k == 0 && !tall_reported {
						for bx in boxes {
							if bx.hi[1] > 16 {
								fail(
									b,
									m.pack,
									m.file,
									m.line,
									m.column,
									fmt.aprintf(
										"%s: a box of shape %s reaches above y = 16; only a collision shape may (up to 24)",
										m.id,
										sources[use.source].def.id,
									),
								)
								tall_reported = true
								break
							}
						}
					}
					id = shape_intern(&sb, boxes)
				}
				switch ui {
				case 0:
					t.collision[fs + k] = id
				case 1:
					t.selection[fs + k] = id
				case 2:
					t.render[fs + k] = id
				}
			}
		}
		if .Opaque in flags {
			for k in 0 ..< int(def.state_count) {
				if t.render[fs + k] != SHAPE_CUBE {
					fail(
						b,
						m.pack,
						m.file,
						m.line,
						m.column,
						fmt.aprintf("%s is opaque but its render shape is not a full cube; set \"opaque\": false", m.id),
					)
					break
				}
			}
		}
	}
	shape_builder_finish(&sb, t)
	_ = strings.concatenate
}
