package game

import "core:fmt"
import "core:slice"
import "core:strings"

// Shapes: lists of boxes in sixteenths of a block, interned in the registry's
// Shape_Table; every block state has a collision, a selection and a render
// shape. A shape is defined in a pack (data/shapes/) once, with the
// properties of the blocks that use it turning it per state.

Face_Axes :: struct {
	normal, u, v: [3]i32,
}

// FACE_AXES: per face the normal and two in-plane axes u, v with u x v =
// normal, so corners (0,0) (1,0) (1,1) (0,1) wind counter-clockwise seen
// from outside.
@(rodata)
FACE_AXES := [Face]Face_Axes {
	.Pos_X = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}},
	.Neg_X = {{-1, 0, 0}, {0, 0, 1}, {0, 1, 0}},
	.Pos_Y = {{0, 1, 0}, {0, 0, 1}, {1, 0, 0}},
	.Neg_Y = {{0, -1, 0}, {1, 0, 0}, {0, 0, 1}},
	.Pos_Z = {{0, 0, 1}, {1, 0, 0}, {0, 1, 0}},
	.Neg_Z = {{0, 0, -1}, {0, 1, 0}, {1, 0, 0}},
}

CUBE_BOX :: Box{{0, 0, 0}, {16, 16, 16}}

// shape_boxes: a shape's boxes.
shape_boxes :: #force_inline proc(t: ^Block_Table, id: u16) -> []Box {
	r := t.shapes.refs[id]
	return t.shapes.boxes[r.first:r.first + r.count]
}

// cover_full: the cover of a full face.
cover_full :: proc(c: ^Cover, f: Face) -> bool {
	for row in c[f] {if row != 0xFFFF {return false}}
	return true
}

// shape_cover: the cover of shape id (see Cover).
shape_cover :: #force_inline proc(t: ^Block_Table, id: u16) -> ^Cover {
	return &t.shapes.cover[id]
}

// boxes_cover: the cover of boxes: per face, the sixteenths of the cell's
// face that boxes touching it cover.
boxes_cover :: proc(boxes: []Box) -> (c: Cover) {
	for f in Face {
		axes := FACE_AXES[f]
		axis := 0
		for k in 0 ..< 3 {if axes.normal[k] != 0 {axis = k}}
		ua, va := 0, 0
		for k in 0 ..< 3 {
			if axes.u[k] != 0 {ua = k}
			if axes.v[k] != 0 {va = k}
		}
		positive := axes.normal[axis] > 0
		for box in boxes {
			if positive && box.hi[axis] != 16 {continue}
			if !positive && box.lo[axis] != 0 {continue}
			for v in box.lo[va] ..< min(box.hi[va], 16) {
				for u in box.lo[ua] ..< min(box.hi[ua], 16) {c[f][v] |= u16(1) << u}
			}
		}
	}
	return
}

// Shape_Builder: the shapes being interned while the registry resolves.
@(private)
Shape_Builder :: struct {
	refs:  [dynamic]Shape_Ref,
	boxes: [dynamic]Box,
	index: map[string]u16,
	names: [dynamic]string, // "" for a shape made for a block
}

@(private)
shape_builder_init :: proc(sb: ^Shape_Builder) {
	append(&sb.refs, Shape_Ref{0, 0})
	append(&sb.names, "empty")
	append(&sb.refs, Shape_Ref{0, 1})
	append(&sb.boxes, CUBE_BOX)
	append(&sb.names, "cube")
	sb.index = make(map[string]u16)
}

// shape_intern: the id of the shape with these boxes (made if new).
@(private)
shape_intern :: proc(sb: ^Shape_Builder, boxes: []Box) -> u16 {
	if len(boxes) == 0 {return SHAPE_EMPTY}
	if len(boxes) == 1 && boxes[0] == CUBE_BOX {return SHAPE_CUBE}
	key := string(slice.to_bytes(boxes))
	if id, found := sb.index[key]; found {return id}
	id := u16(len(sb.refs))
	append(&sb.refs, Shape_Ref{u16(len(sb.boxes)), u16(len(boxes))})
	append(&sb.boxes, ..boxes)
	append(&sb.names, "")
	sb.index[strings.clone(key)] = id
	return id
}

@(private)
shape_builder_finish :: proc(sb: ^Shape_Builder, t: ^Block_Table) {
	t.shapes.refs = sb.refs[:]
	t.shapes.boxes = sb.boxes[:]
	t.shapes.ids = sb.names[:]
	t.shapes.cover = make([]Cover, len(sb.refs))
	for r, i in sb.refs {
		t.shapes.cover[i] = boxes_cover(sb.boxes[r.first:r.first + r.count])
	}
}

// box_rotate: a quarter turn clockwise seen from above, `steps` times: (x, z)
// becomes (16 - z, x), the corners re-sorted.
box_rotate :: proc(b: Box, steps: int) -> Box {
	r := b
	for _ in 0 ..< steps & 3 {
		lo := [2]u8{16 - r.hi[2], r.lo[0]} // (x, z) of the turned low corner
		hi := [2]u8{16 - r.lo[2], r.hi[0]}
		r.lo[0], r.lo[2] = lo[0], lo[1]
		r.hi[0], r.hi[2] = hi[0], hi[1]
	}
	return r
}

// box_flip: y becomes 16 - y (for a box up to 16 high).
box_flip :: proc(b: Box) -> Box {
	r := b
	if b.hi[1] > 16 {return b}
	r.lo[1], r.hi[1] = 16 - b.hi[1], 16 - b.lo[1]
	return r
}

ROTATE_VALUES := [4]string{"north", "east", "south", "west"}

// Shape_Source: a shape definition's data as read from its fields.
@(private)
Shape_Source :: struct {
	def:    ^Merged_Def,
	boxes:  [dynamic]Box,
	cases:  [dynamic]Shape_Case,
	rotate: string,
	flip:   Maybe([2]string), // property, value
}

@(private)
Shape_Case :: struct {
	cond:  [dynamic][2]string, // property name; one of the values, as "a|b"
	boxes: [dynamic]Box,
	value: Json_Value,
}

SHAPE_FIELDS := []string{"boxes", "cases", "rotate", "flip", "override"}

// read_boxes: a list of [x0, y0, z0, x1, y1, z1].
@(private)
read_boxes :: proc(b: ^Reg_Build, f: ^Def_Field, v: Json_Value, out: ^[dynamic]Box) {
	if v.kind != .Array {
		fail_field(b, f, v, "boxes is a list of [x0, y0, z0, x1, y1, z1] in sixteenths")
		return
	}
	if len(v.items) > MAX_SHAPE_BOXES {
		fail_field(
			b,
			f,
			v,
			fmt.aprintf("a shape has at most %d boxes, got %d", MAX_SHAPE_BOXES, len(v.items)),
		)
		return
	}
	for item in v.items {
		if item.kind != .Array || len(item.items) != 6 {
			fail_field(b, f, item, "a box is [x0, y0, z0, x1, y1, z1] in sixteenths")
			continue
		}
		n: [6]int
		good := true
		for c, i in item.items {
			if c.kind != .Int {
				fail_field(b, f, c, "a box's numbers are whole sixteenths")
				good = false
				break
			}
			n[i] = int(c.i)
		}
		if !good {continue}
		for k in 0 ..< 3 {
			limit := 24 if k == 1 else 16
			if n[k] < 0 || n[k + 3] > limit || n[k] >= n[k + 3] {
				fail_field(
					b,
					f,
					item,
					fmt.aprintf(
						"a box needs 0 <= lo < hi <= 16 on each axis (24 on y for collision), got %d..%d on %s",
						n[k],
						n[k + 3],
						axis_name(k),
					),
				)
				good = false
				break
			}
		}
		if !good {continue}
		append(
			out,
			Box {
				{u8(n[0]), u8(n[1]), u8(n[2])},
				{u8(n[3]), u8(n[4]), u8(n[5])},
			},
		)
	}
}

// read_shape_source: m's fields.
@(private)
read_shape_source :: proc(b: ^Reg_Build, m: ^Merged_Def) -> Shape_Source {
	s := Shape_Source {
		def = m,
	}
	if f := field_of(m, "boxes"); f != nil {
		read_boxes(b, f, f.value, &s.boxes)
	} else {
		fail(b, m.pack, m.file, m.line, m.column, "\"boxes\" is missing; give [] for none")
	}
	if f := field_of(m, "cases"); f != nil {
		if f.value.kind != .Array {
			fail_field(b, f, f.value, "cases is a list of {\"when\": {...}, \"boxes\": [...]}")
		} else {
			for c in f.value.items {
				sc: Shape_Case
				sc.value = c
				if c.kind != .Object {
					fail_field(b, f, c, "a case is {\"when\": {...}, \"boxes\": [...]}")
					continue
				}
				for cm in c.members {
					switch cm.key {
					case "when":
						if cm.value.kind != .Object {
							fail_field(b, f, cm.value, "when is {property: value} or {property: [values]}")
							continue
						}
						for wm in cm.value.members {
							vals := make([dynamic]string)
							#partial switch wm.value.kind {
							case .String:
								append(&vals, wm.value.s)
							case .Array:
								for x in wm.value.items {
									if x.kind == .String {append(&vals, x.s)} else {
										fail_field(b, f, x, "a value is a string")
									}
								}
							case:
								fail_field(b, f, wm.value, "a value is a string or a list of strings")
							}
							append(&sc.cond, [2]string{wm.key, strings.join(vals[:], "|")})
						}
					case "boxes":
						read_boxes(b, f, cm.value, &sc.boxes)
					case:
						fail_field(
							b,
							f,
							cm.value,
							fmt.aprintf(
								"\"%s\" is not a case field%s",
								cm.key,
								suggestion(cm.key, []string{"when", "boxes"}),
							),
						)
					}
				}
				append(&s.cases, sc)
			}
		}
	}
	if f := field_of(m, "rotate"); f != nil {
		if f.value.kind != .String {
			fail_field(b, f, f.value, "rotate is a property name")
		} else {
			s.rotate = f.value.s
		}
	}
	if f := field_of(m, "flip"); f != nil {
		if f.value.kind != .Object || len(f.value.members) != 1 || f.value.members[0].value.kind != .String {
			fail_field(b, f, f.value, "flip is {property: value}")
		} else {
			s.flip = [2]string{f.value.members[0].key, f.value.members[0].value.s}
		}
	}
	return s
}

// shape_names_properties: every property a shape names (rotate, flip, cases),
// each with the values it names (for the check against a block).
@(private)
check_shape_against :: proc(
	b: ^Reg_Build,
	s: ^Shape_Source,
	block: ^Merged_Def,
	props: []Prop_Def,
) -> bool {
	ok := true
	where_ := fmt.aprintf("%s", block.id)
	find :: proc(props: []Prop_Def, name: string) -> (Prop_Def, bool) {
		for p in props {if p.name == name {return p, true}}
		return {}, false
	}
	need :: proc(
		b: ^Reg_Build,
		s: ^Shape_Source,
		block: ^Merged_Def,
		props: []Prop_Def,
		name: string,
		values: []string,
		ok: ^bool,
	) {
		p, found := find(props, name)
		if !found {
			fail(
				b,
				block.pack,
				block.file,
				block.line,
				block.column,
				fmt.aprintf(
					"%s uses shape %s (%s:%d:%d), which names the property \"%s\"; give the block that property",
					block.id,
					s.def.id,
					s.def.file,
					s.def.line,
					s.def.column,
					name,
				),
			)
			ok^ = false
			return
		}
		for v in values {
			if !slice.contains(p.values, v) {
				fail(
					b,
					block.pack,
					block.file,
					block.line,
					block.column,
					fmt.aprintf(
						"%s uses shape %s (%s:%d:%d), which names the value \"%s\" of \"%s\"; give the property that value",
						block.id,
						s.def.id,
						s.def.file,
						s.def.line,
						s.def.column,
						v,
						name,
					),
				)
				ok^ = false
			}
		}
	}
	if s.rotate != "" {
		need(b, s, block, props, s.rotate, ROTATE_VALUES[:], &ok)
	}
	if fl, has := s.flip.?; has {need(b, s, block, props, fl[0], []string{fl[1]}, &ok)}
	for c in s.cases {
		for w in c.cond {
			need(b, s, block, props, w[0], strings.split(w[1], "|"), &ok)
		}
	}
	_ = where_
	return ok
}

// shape_boxes_for: the boxes of s for the state whose properties have
// values (by Prop_Def order).
@(private)
shape_for_state :: proc(
	s: ^Shape_Source,
	props: []Prop_Def,
	values: []int,
	allocator := context.temp_allocator,
) -> []Box {
	value_of :: proc(props: []Prop_Def, values: []int, name: string) -> string {
		for p, i in props {if p.name == name {return p.values[values[i]]}}
		return ""
	}
	out := make([dynamic]Box, allocator)
	append(&out, ..s.boxes[:])
	for c in s.cases {
		matches := true
		for w in c.cond {
			have := value_of(props, values, w[0])
			if !slice.contains(strings.split(w[1], "|", context.temp_allocator), have) {
				matches = false
			}
		}
		if matches {append(&out, ..c.boxes[:])}
	}
	if fl, has := s.flip.?; has && value_of(props, values, fl[0]) == fl[1] {
		for &bx in out {bx = box_flip(bx)}
	}
	if s.rotate != "" {
		have := value_of(props, values, s.rotate)
		for v, i in ROTATE_VALUES {
			if v == have {
				for &bx in out {bx = box_rotate(bx, i)}
			}
		}
	}
	return out[:]
}

@(private)
axis_name :: proc(k: int) -> string {
	names := [3]string{"x", "y", "z"}
	return names[k]
}
