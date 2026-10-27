package game

import "core:strings"
import "core:testing"

Sch_Mode :: enum u8 {
	A = 0,
	B = 2,
	C = 5,
}

Sch_Flags :: bit_set[Sch_Mode;u8]

Sch_Inner :: struct {
	x: i32,
	y: f32,
}

Sch_All :: struct {
	flag:  bool,
	a:     u8,
	b:     u16,
	c:     u32,
	d:     u64,
	e:     i32,
	f:     int,
	g:     f32,
	h:     f64,
	mode:  Sch_Mode,
	flags: Sch_Flags,
	pos:   [3]f64,
	stack: [4]Stack,
	worn:  [Equip_Slot]Stack,
	inner: Sch_Inner,
	name:  string `net:"max=8"`,
	spot:  Maybe(Block_Pos),
}

@(private = "file")
one :: proc(value: typeid, lane := Lane.Reliable, key := Key_Type.None) -> (Schema, Schema_Error) {
	max_records := 1 if key == .None else 8
	states := []State_Kind_Info {
		{name = "thing", value = value, lane = lane, key = key, max_records = max_records},
	}
	return schema_make(states, nil, context.temp_allocator)
}

@(test)
test_schema_leaves_by_path :: proc(t: ^testing.T) {
	s, err := one(Sch_All)
	if !testing.expect(t, err.reason == "", schema_error_text(err)) {return}
	paths := [?]string {
		"flag",
		"a",
		"b",
		"c",
		"d",
		"e",
		"f",
		"g",
		"h",
		"mode",
		"flags",
		"pos",
		"stack",
		"worn",
		"inner.x",
		"inner.y",
		"name",
		"spot",
	}
	types := [?]Field_Type {
		.Bool,
		.Uint,
		.Uint,
		.Uint,
		.Uint,
		.Int,
		.Int,
		.F32,
		.F64,
		.Enum,
		.Bit_Set,
		.Array,
		.Array,
		.Array,
		.Int,
		.F32,
		.String,
		.Union,
	}
	fields := s.kinds[0].fields
	if !testing.expect_value(t, len(fields), len(paths)) {return}
	for f, i in fields {
		testing.expect_value(t, f.path, paths[i])
		testing.expectf(t, f.type == types[i], "%s is %v, wanted %v", f.path, f.type, types[i])
	}
	testing.expect(t, fields[11].scalar, "[3]f64 is an array of scalars")
	testing.expect(t, !fields[12].scalar, "[4]Stack is an array of structs")
	testing.expect(t, !fields[13].scalar, "[Equip_Slot]Stack is an array of structs")
	testing.expect_value(t, fields[16].max, 8)
	testing.expect_value(t, fields[10].valid_bits, u64(1 | 4 | 32))
}

@(test)
test_schema_refusals :: proc(t: ^testing.T) {
	Bad_Pointer :: struct {
		p: ^int,
	}
	Bad_Slice :: struct {
		x: struct {
			s: []u8,
		},
	}
	Bad_Dynamic :: struct {
		d: [dynamic]int,
	}
	Bad_Map :: struct {
		m: map[int]int,
	}
	Bad_Proc :: struct {
		p: proc(),
	}
	Bad_Any :: struct {
		a: any,
	}
	Bad_String :: struct {
		inventory: struct {
			note: string,
		},
	}
	Bad_Array_String :: struct {
		s: [2]struct {
			text: string `net:"max=3"`,
		},
	}
	Eight :: struct {
		a, b, c, d, e, f, g, h: u8,
	}
	Bad_Many :: struct {
		p, q, r, s, t, u, v, w: Eight,
	}
	Bad_Snapshot_String :: struct {
		text: string `net:"max=3"`,
	}
	Case :: struct {
		value:  typeid,
		path:   string,
		reason: string,
		lane:   Lane,
	}
	cases := [?]Case {
		{Bad_Pointer, "p", "pointer", .Reliable},
		{Bad_Slice, "x.s", "slice", .Reliable},
		{Bad_Dynamic, "d", "dynamic array", .Reliable},
		{Bad_Map, "m", "map", .Reliable},
		{Bad_Proc, "p", "procedure", .Reliable},
		{Bad_Any, "a", "any", .Reliable},
		{Bad_String, "inventory.note", `string has no net:"max=N"`, .Reliable},
		{Bad_Array_String, "s[].text", "string inside an array or union", .Reliable},
		{Bad_Snapshot_String, "text", "string on the snapshot lane", .Snapshot},
	}
	for c in cases {
		_, err := one(c.value, c.lane)
		testing.expectf(
			t,
			err.reason == c.reason,
			"%v: reason %q, wanted %q",
			c.value,
			err.reason,
			c.reason,
		)
		testing.expectf(t, err.path == c.path, "%v: path %q, wanted %q", c.value, err.path, c.path)
		testing.expect_value(t, err.kind, "thing")
	}
	_, err := one(Bad_Many)
	testing.expectf(
		t,
		strings.contains(err.reason, "64 fields, at most 62"),
		"reason %q",
		err.reason,
	)
}

Sch_A :: struct {
	a: i32,
	b: f32,
}

Sch_B :: struct {
	a: i32,
	b: f64,
}

Sch_C :: struct {
	b: f32,
	a: i32,
}

Sch_D :: struct {
	a: i32,
	c: f32,
}

Sch_E_Two :: enum u8 {
	X,
	Y,
}

Sch_E_Three :: enum u8 {
	X,
	Y,
	Z,
}

Sch_E1 :: struct {
	m: Sch_E_Two,
}

Sch_E2 :: struct {
	m: Sch_E_Three,
}

@(private = "file")
hash_of :: proc(infos: []State_Kind_Info) -> u64 {
	s, err := schema_make(infos, nil, context.temp_allocator)
	assert(err.reason == "")
	return schema_hash(&s)
}

@(test)
test_schema_hash_changes :: proc(t: ^testing.T) {
	kind :: proc(
		value: typeid,
		name := "k",
		version: u8 = 0,
		lane := Lane.Reliable,
		key := Key_Type.None,
	) -> State_Kind_Info {
		return {
			name = name,
			value = value,
			version = version,
			lane = lane,
			key = key,
			max_records = 1 if key == .None else 4,
		}
	}
	base := hash_of({kind(Sch_A)})
	testing.expect_value(t, hash_of({kind(Sch_A)}), base)
	others := [?]struct {
		what: string,
		hash: u64,
	} {
		{"a field's type", hash_of({kind(Sch_B)})},
		{"the fields' order", hash_of({kind(Sch_C)})},
		{"a field's name", hash_of({kind(Sch_D)})},
		{"the kind's name", hash_of({kind(Sch_A, "other")})},
		{"the kind's version", hash_of({kind(Sch_A, "k", 1)})},
		{"the kind's lane", hash_of({kind(Sch_A, "k", 0, .Snapshot)})},
		{"the kind's key", hash_of({kind(Sch_A, "k", 0, .Reliable, .Entity)})},
	}
	for o in others {
		testing.expectf(t, o.hash != base, "the hash did not change with %s", o.what)
	}
	testing.expect(
		t,
		hash_of({kind(Sch_E1)}) != hash_of({kind(Sch_E2)}),
		"the hash did not change with an enum's values",
	)
	ab := hash_of({kind(Sch_A, "x"), kind(Sch_B, "y")})
	ba := hash_of({kind(Sch_B, "y"), kind(Sch_A, "x")})
	testing.expect(t, ab != ba, "the hash did not change with the order of kinds")
}

@(test)
test_schema_text_golden :: proc(t: ^testing.T) {
	Golden :: struct {
		n:    u16,
		pos:  [3]f64,
		mode: Sch_Mode,
		name: string `net:"max=8"`,
		seq:  u32 `net:"acked"`,
	}
	states := []State_Kind_Info {
		{
			name = "thing",
			value = Golden,
			lane = .Reliable,
			key = .Entity,
			max_records = 4,
			version = 2,
		},
	}
	events := []Event_Kind_Info{{name = "flash", value = Sch_Inner}}
	s, err := schema_make(states, events, context.temp_allocator)
	if !testing.expect(t, err.reason == "", schema_error_text(err)) {return}
	want := `state thing 2 key=Entity lane=Reliable max=4 write_through=false priority=0
  field n u16
  field pos [3]f64
  field mode enum<8>{A=0,B=2,C=5}
  field name string(max=8)
  field seq u32 acked
event flash 0
  field x i32
  field y f32
`
	testing.expect_value(t, schema_text(&s), want)
	testing.expect_value(t, s.kinds[0].ack_field, 4)
}
