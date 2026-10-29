#+feature dynamic-literals
package game

import "core:fmt"
import "core:strings"
import "core:testing"

// A pack of stairs, slabs, a ladder and a three-property block: the shapes
// of M48's spec, as data.
STATES_PACK :: []File {
	{
		"data/shapes/stairs.json",
		`{
  "stairs": {
    "boxes": [[0, 0, 0, 16, 8, 16], [0, 8, 0, 16, 16, 8]],
    "rotate": "facing",
    "flip": {"half": "top"}
  },
  "slab": {
    "boxes": [],
    "cases": [
      {"when": {"type": "bottom"}, "boxes": [[0, 0, 0, 16, 8, 16]]},
      {"when": {"type": "top"},    "boxes": [[0, 8, 0, 16, 16, 16]]},
      {"when": {"type": "double"}, "boxes": [[0, 0, 0, 16, 16, 16]]}
    ]
  },
  "ladder": {"boxes": [[0, 0, 13, 16, 16, 16]], "rotate": "facing"},
  "farmland": {"boxes": [[0, 0, 0, 16, 15, 16]]},
  "fence": {"boxes": [[6, 0, 6, 10, 24, 10]]}
}`,
	},
	{
		"data/blocks/stairs.json",
		`{
  "planks_stairs": {
    "states": {"facing": ["north", "east", "south", "west"], "half": ["bottom", "top"]},
    "default": {"facing": "north", "half": "bottom"},
    "shape": "testpack:stairs",
    "place": "stairs",
    "opaque": false, "shades": true,
    "textures": {"all": "voxiverse:planks"}, "sound": "voxiverse:wood"
  },
  "stone_stairs": {
    "states": {"facing": ["north", "east", "south", "west"], "half": ["bottom", "top"]},
    "shape": "testpack:stairs",
    "place": "stairs",
    "opaque": false, "shades": true,
    "textures": {"all": "voxiverse:stone"}
  },
  "planks_slab": {
    "states": {"type": ["bottom", "top", "double"]},
    "shape": "testpack:slab",
    "place": "slab",
    "opaque": false, "shades": true,
    "textures": {"all": "voxiverse:planks"}
  },
  "lad": {
    "states": {"facing": ["north", "east", "south", "west"]},
    "collision": "testpack:ladder", "selection": "testpack:ladder", "render_shape": "testpack:ladder",
    "climbable": true, "opaque": false, "layer": "cutout",
    "textures": {"all": "voxiverse:planks"}
  },
  "lever": {
    "states": {"powered": "bool", "face": ["floor", "wall", "ceiling"], "facing": ["north", "east", "south", "west"]},
    "default": {"face": "wall", "facing": "south"},
    "opaque": false, "collides": false, "layer": "cutout",
    "textures": {"all": "voxiverse:planks"}
  }
}`,
	},
}

states_registry :: proc(t: ^testing.T) -> ^Registry {
	reg, errs := build_with(pack_of("testpack", STATES_PACK))
	testing.expect_value(t, errors_text(errs), "")
	return reg
}

@(test)
test_state_ids_are_mixed_radix :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	tb := &reg.blocks
	// Builtins keep their numbers; the pack's types follow, each with its states.
	testing.expect_value(t, tb.count, BASE_STATES + 8 + 8 + 3 + 4 + 24)
	testing.expect_value(t, len(tb.types), BASE_TYPES + 5)
	lever, ok := registry_block(reg, "testpack:lever")
	testing.expect(t, ok)
	type := tb.type_of[lever]
	def := tb.types[type]
	testing.expect_value(t, int(def.state_count), 24)
	// Defaults: face=wall, facing=south, powered=false (the first).
	testing.expect_value(t, state_value(tb, lever, 0), 0)
	testing.expect_value(t, state_value(tb, lever, 1), 1)
	testing.expect_value(t, state_value(tb, lever, 2), 2)
	for k in 0 ..< 24 {
		b := Block(int(def.first_state) + k)
		testing.expect_value(
			t,
			state_value(tb, b, 0) * 12 + state_value(tb, b, 1) * 4 + state_value(tb, b, 2),
			k,
		)
		for p in 0 ..< 3 {
			for v in 0 ..< len(def.props[p].values) {
				c := state_with(tb, b, p, v)
				testing.expect_value(t, state_value(tb, c, p), v)
				for q in 0 ..< 3 {
					if q !=
					   p {testing.expect_value(t, state_value(tb, c, q), state_value(tb, b, q))}
				}
			}
		}
	}
	i, found := prop_index(tb, type, "face")
	testing.expect(t, found && i == 1)
	_, found = prop_index(tb, type, "nope")
	testing.expect(t, !found)
}

@(test)
test_state_text_round_trips :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	tb := &reg.blocks
	for b in 0 ..< tb.count {
		text := state_text(reg, Block(b))
		got, ok := state_parse(reg, text)
		testing.expectf(t, ok && int(got) == b, "%s", text)
	}
	stairs, _ := registry_block(reg, "testpack:planks_stairs[facing=east,half=top]")
	testing.expect_value(
		t,
		state_text(reg, stairs),
		"testpack:planks_stairs[facing=east,half=top]",
	)
	// Missing properties take the default's; a type without properties is its id.
	d, ok := state_parse(reg, "testpack:planks_stairs")
	testing.expect(t, ok)
	testing.expect_value(t, state_text(reg, d), "testpack:planks_stairs[facing=north,half=bottom]")
	d, ok = state_parse(reg, "testpack:planks_stairs[half=top]")
	testing.expect(t, ok)
	testing.expect_value(t, state_text(reg, d), "testpack:planks_stairs[facing=north,half=top]")
	stone, _ := registry_block(reg, "stone")
	testing.expect_value(t, state_text(reg, stone), "voxiverse:stone")
	lever, _ := state_parse(reg, "testpack:lever")
	testing.expect_value(
		t,
		state_text(reg, lever),
		"testpack:lever[powered=false,face=wall,facing=south]",
	)
	for bad in ([]string{"testpack:planks_stairs[facing=up]", "testpack:planks_stairs[colour=red]", "testpack:planks_stairs[facing=east", "testpack:planks_stairs[facing=east,facing=west]", "testpack:nope[facing=east]", "testpack:planks_stairs[facing]"}) {
		_, good := state_parse(reg, bad)
		testing.expectf(t, !good, "%s", bad)
	}
	// An item is one per type.
	item := item_of_block(reg, stairs)
	other, _ := state_parse(reg, "testpack:planks_stairs")
	testing.expect_value(t, item, item_of_block(reg, other))
	info, _ := registry_item_info(reg, item)
	testing.expect_value(t, info.block, other)
	testing.expect_value(t, info.name, "testpack:planks_stairs")
}

@(private = "file")
box_text :: proc(boxes: []Box) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for b, i in boxes {
		if i > 0 {strings.write_byte(&sb, ' ')}
		fmt.sbprintf(&sb, "%d,%d,%d-%d,%d,%d", b.lo.x, b.lo.y, b.lo.z, b.hi.x, b.hi.y, b.hi.z)
	}
	return strings.to_string(sb)
}

@(test)
test_rotate_and_flip :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	tb := &reg.blocks
	want := map[string]string {
		"facing=north,half=bottom" = "0,0,0-16,8,16 0,8,0-16,16,8",
		"facing=east,half=bottom"  = "0,0,0-16,8,16 8,8,0-16,16,16",
		"facing=south,half=bottom" = "0,0,0-16,8,16 0,8,8-16,16,16",
		"facing=west,half=bottom"  = "0,0,0-16,8,16 0,8,0-8,16,16",
		"facing=north,half=top"    = "0,8,0-16,16,16 0,0,0-16,8,8",
		"facing=east,half=top"     = "0,8,0-16,16,16 8,0,0-16,8,16",
		"facing=south,half=top"    = "0,8,0-16,16,16 0,0,8-16,8,16",
		"facing=west,half=top"     = "0,8,0-16,16,16 0,0,0-8,8,16",
	}
	defer delete(want)
	for state, boxes in want {
		b, ok := state_parse(reg, fmt.tprintf("testpack:planks_stairs[%s]", state))
		testing.expect(t, ok)
		testing.expect_value(t, box_text(shape_boxes(tb, tb.collision[b])), boxes)
		testing.expect_value(t, tb.collision[b], tb.selection[b])
		testing.expect_value(t, tb.collision[b], tb.render[b])
	}
	// The ladder turns to its facing: the board is at the back (north: z 13..16 for facing=north).
	lad, _ := state_parse(reg, "testpack:lad[facing=east]")
	testing.expect_value(t, box_text(shape_boxes(tb, tb.collision[lad])), "0,0,0-3,16,16")
	// Interning: eight stairs share eight shapes, and the other pack's stairs share them too.
	seen: map[u16]bool
	seen.allocator = context.temp_allocator
	for name in ([]string{"planks_stairs", "stone_stairs"}) {
		first, _ := registry_block(reg, fmt.tprintf("testpack:%s", name))
		for k in 0 ..< 8 {seen[tb.collision[int(first) + k]] = true}
	}
	testing.expect_value(t, len(seen), 8)
	// Cubes are the cube; no shape is empty.
	stone, _ := registry_block(reg, "stone")
	testing.expect_value(t, tb.collision[stone], SHAPE_CUBE)
	testing.expect_value(t, tb.render[stone], SHAPE_CUBE)
	air: Block = .Air
	testing.expect_value(t, tb.collision[air], SHAPE_EMPTY)
	testing.expect_value(t, tb.selection[air], SHAPE_EMPTY)
	grass, _ := registry_block(reg, "tall_grass")
	testing.expect_value(t, tb.collision[grass], SHAPE_EMPTY)
	testing.expect_value(t, tb.selection[grass], SHAPE_CUBE)
	water, _ := registry_block(reg, "water")
	testing.expect_value(t, tb.collision[water], SHAPE_EMPTY)
}

@(test)
test_shape_cover :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	tb := &reg.blocks
	slab, _ := state_parse(reg, "testpack:planks_slab[type=bottom]")
	c := shape_cover(tb, tb.render[slab])
	// A bottom slab covers the lower half of every side face, and the whole bottom.
	for face in Face {
		switch face {
		case .Neg_Y:
			testing.expect(t, cover_full(c, face))
		case .Pos_Y:
			for row in c[face] {testing.expect_value(t, row, 0)}
		case .Pos_X, .Neg_Z:
			// u = y (v = x): bits 0..7 of every row.
			for row in c[face] {testing.expect_value(t, row, 0x00FF)}
		case .Neg_X, .Pos_Z:
			// v = y: rows 0..7 full.
			for row, i in c[face] {testing.expect_value(t, row, 0xFFFF if i < 8 else 0)}
		}
	}
	dbl, _ := state_parse(reg, "testpack:planks_slab[type=double]")
	for face in Face {testing.expect(t, cover_full(shape_cover(tb, tb.render[dbl]), face))}
	// A stair facing north (the riser at the back, z 0..8 at the top): its +z face is
	// the lower half only; its -z face is full; its bottom is full, its top half.
	st, _ := state_parse(reg, "testpack:planks_stairs[facing=north,half=bottom]")
	c = shape_cover(tb, tb.render[st])
	for row, i in c[.Pos_Z] {testing.expect_value(t, row, 0xFFFF if i < 8 else 0)}
	testing.expect(t, cover_full(c, .Neg_Z))
	testing.expect(t, cover_full(c, .Neg_Y))
	for row in c[.Pos_Y] {testing.expect_value(t, row, 0x00FF)}
}

@(test)
test_broken_states_and_shapes :: proc(t: ^testing.T) {
	Case :: struct {
		name:  string,
		files: []File,
		want:  string,
	}
	cases := []Case {
		{
			"shape names a property the block lacks",
			{
				{"data/shapes/s.json", `{"s": {"boxes": [[0,0,0,16,8,16]], "rotate": "facing"}}`},
				{
					"data/blocks/b.json",
					`{"b": {"shape": "testpack:s", "opaque": false, "textures": {"all": "voxiverse:stone"}}}`,
				},
			},
			`testpack/data/blocks/b.json:1:2: testpack:b uses shape testpack:s (data/shapes/s.json:1:2), which names the property "facing"; give the block that property`,
		},
		{
			"shape names a value the block lacks",
			{
				{
					"data/shapes/s.json",
					`{"s": {"boxes": [], "cases": [{"when": {"half": "top"}, "boxes": [[0,8,0,16,16,16]]}]}}`,
				},
				{
					"data/blocks/b.json",
					`{"b": {"states": {"half": ["bottom", "middle"]}, "shape": "testpack:s", "opaque": false, "textures": {"all": "voxiverse:stone"}}}`,
				},
			},
			`testpack/data/blocks/b.json:1:2: testpack:b uses shape testpack:s (data/shapes/s.json:1:2), which names the value "top" of "half"; give the property that value`,
		},
		{
			"box outside the cell",
			{{"data/shapes/s.json", `{"s": {"boxes": [[0,0,0,17,8,16]]}}`}},
			`testpack/data/shapes/s.json:1:18: a box needs 0 <= lo < hi <= 16 on each axis (24 on y for collision), got 0..17 on x`,
		},
		{
			"empty box",
			{{"data/shapes/s.json", `{"s": {"boxes": [[0,8,0,16,8,16]]}}`}},
			`testpack/data/shapes/s.json:1:18: a box needs 0 <= lo < hi <= 16 on each axis (24 on y for collision), got 8..8 on y`,
		},
		{
			"too tall",
			{{"data/shapes/s.json", `{"s": {"boxes": [[0,0,0,16,25,16]]}}`}},
			`testpack/data/shapes/s.json:1:18: a box needs 0 <= lo < hi <= 16 on each axis (24 on y for collision), got 0..25 on y`,
		},
		{
			"too many boxes",
			{
				{
					"data/shapes/s.json",
					fmt.tprintf(
						`{{"s": {{"boxes": [%s[0,0,0,1,1,1]]}}}}`,
						strings.repeat(`[0,0,0,1,1,1],`, 16, context.temp_allocator),
					),
				},
			},
			`testpack/data/shapes/s.json:1:17: a shape has at most 16 boxes, got 17`,
		},
		{
			"a tall box is only for collision",
			{
				{"data/shapes/s.json", `{"s": {"boxes": [[6,0,6,10,24,10]]}}`},
				{
					"data/blocks/b.json",
					`{"b": {"shape": "testpack:s", "opaque": false, "textures": {"all": "voxiverse:stone"}}}`,
				},
			},
			`testpack/data/blocks/b.json:1:2: testpack:b: a box of shape testpack:s reaches above y = 16; only a collision shape may (up to 24)`,
		},
		{
			"opaque with a shaped render",
			{
				{"data/shapes/s.json", `{"s": {"boxes": [[0,0,0,16,8,16]]}}`},
				{
					"data/blocks/b.json",
					`{"b": {"shape": "testpack:s", "textures": {"all": "voxiverse:stone"}}}`,
				},
			},
			`testpack/data/blocks/b.json:1:2: testpack:b is opaque but its render shape is not a full cube; set "opaque": false`,
		},
		{
			"states on a builtin",
			{
				{
					"data/blocks/s.json",
					`{"voxiverse:stone": {"override": true, "states": {"a": ["x", "y"]}}}`,
				},
			},
			`testpack/data/blocks/s.json:1:50: voxiverse:stone is named by the engine and keeps one state`,
		},
		{
			"more than 256 states",
			{
				{
					"data/blocks/b.json",
					`{"b": {"opaque": false, "states": {"a": ["a0","a1","a2","a3","a4","a5","a6","a7","a8","a9","a10","a11","a12","a13","a14","a15"], "b": ["a0","a1","a2","a3","a4","a5","a6","a7","a8","a9","a10","a11","a12","a13","a14","a15"], "c": "bool"}, "textures": {"all": "voxiverse:stone"}}}`,
				},
			},
			`testpack/data/blocks/b.json:1:35: 512 states; a block has at most 256`,
		},
		{
			"default not in the list",
			{
				{
					"data/blocks/b.json",
					`{"b": {"opaque": false, "states": {"a": ["x", "y"]}, "default": {"a": "z"}, ` +
					`"textures": {"all": "voxiverse:stone"}}}`,
				},
			},
			`testpack/data/blocks/b.json:1:71: z is not a value of a; the values are "x", "y"`,
		},
		{
			"one value",
			{
				{
					"data/blocks/b.json",
					`{"b": {"opaque": false, "states": {"a": ["x"]}, "textures": {"all": "voxiverse:stone"}}}`,
				},
			},
			`testpack/data/blocks/b.json:1:41: a has 1 values; a property has 2 to 16`,
		},
	}
	for c in cases {
		reg, errs := build_with(pack_of("testpack", c.files))
		testing.expectf(t, reg == nil, "%s: built", c.name)
		testing.expect_value(t, errors_text(errs), c.want)
	}
}
