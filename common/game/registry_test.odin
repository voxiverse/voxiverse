package game

import "core:fmt"
import "core:strings"
import "core:testing"

// The base pack's block types after the builtins: four stairs (8 states each),
// four slabs (3) and a ladder (4).
BASE_NEW_TYPES :: 9
BASE_NEW_STATES :: 4 * 8 + 4 * 3 + 4
BASE_TYPES :: len(Block) + BASE_NEW_TYPES
BASE_STATES :: len(Block) + BASE_NEW_STATES

@(test)
test_base_builds :: proc(t: ^testing.T) {
	src := base_pack_source(context.temp_allocator)
	reg, errs := registry_build({src})
	for e in errs {fmt.eprintln(pack_error_text(e))}
	testing.expect(t, reg != nil)
	if reg == nil {return}
	defer registry_destroy(reg)
	testing.expect_value(t, reg.blocks.count, BASE_STATES)
}

@(private = "file")
base_registry :: proc(t: ^testing.T) -> ^Registry {
	src := base_pack_source(context.temp_allocator)
	reg, errs := registry_build({src})
	for e in errs {fmt.eprintln(pack_error_text(e))}
	testing.expect(t, reg != nil)
	return reg
}

// The base pack is today's game: block by block and field by field against
// frozen copies of the Odin tables the registry replaced (registry_frozen_test.odin).
@(test)
test_base_matches_legacy :: proc(t: ^testing.T) {
	reg := base_registry(t)
	if reg == nil {return}
	defer registry_destroy(reg)
	tb := &reg.blocks
	for b in Block {
		want := FROZEN_BLOCK_INFO[b]
		n := int(b)
		testing.expect_value(t, tb.defs[n].id, BUILTIN_BLOCK_IDS[b])
		testing.expect_value(t, BUILTIN_BLOCK_IDS[b], fmt.tprintf("voxiverse:%s", want.name))
		testing.expectf(t, (.Collides in tb.flags[n]) == want.collides, "%v collides", b)
		testing.expectf(t, (.Opaque in tb.flags[n]) == want.opaque, "%v opaque", b)
		testing.expectf(t, (.Targetable in tb.flags[n]) == want.targetable, "%v targetable", b)
		testing.expectf(t, (.Breakable in tb.flags[n]) == want.breakable, "%v breakable", b)
		testing.expectf(t, (.Placeable in tb.flags[n]) == want.placeable, "%v placeable", b)
		testing.expectf(t, (.Replaceable in tb.flags[n]) == want.replaceable, "%v replaceable", b)
		testing.expectf(t, (.Shades in tb.flags[n]) == want.shades, "%v shades", b)
		testing.expectf(t, tb.light[n] == want.light, "%v light", b)
		testing.expectf(t, block_shades(tb, b) == frozen_block_shades(b), "%v shades (column)", b)
		testing.expectf(t, registry_block_drop(reg, b) == frozen_block_drop(b), "%v drop", b)
		testing.expectf(t, block_is_plant(tb, b) == frozen_block_is_plant(b), "%v plant", b)
		// by id
		got, ok := registry_block(reg, want.name)
		testing.expect(t, ok && got == b)
		got, ok = registry_block(reg, BUILTIN_BLOCK_IDS[b])
		testing.expect(t, ok && got == b)
		testing.expectf(
			t,
			(.Liquid in tb.flags[n]) ==
			(b == .Water || (b >= .Water_1 && b <= .Water_7) || b == .Water_Falling),
			"%v liquid",
			b,
		)
		testing.expectf(t, (.Cull_Same in tb.flags[n]) == (b == .Glass), "%v cull_same", b)
	}
	testing.expect_value(t, tb.count, BASE_STATES)
	// Plants stand where they did.
	for plant in Block {
		if !frozen_block_is_plant(plant) {continue}
		for below in Block {
			testing.expectf(
				t,
				block_supported(tb, plant, below) == frozen_plant_supported(plant, below),
				"%v on %v",
				plant,
				below,
			)
		}
	}
	// The hoe's rule: the tillable tag.
	tillable, found := registry_block_tag(reg, "tillable")
	testing.expect(t, found)
	for b in Block {
		testing.expectf(
			t,
			block_in_tag(tb, b, tillable) == frozen_can_till(b, .Air),
			"%v tillable",
			b,
		)
	}

	// Items: the same numbers, names and fields.
	for i in frozen_every_item(context.temp_allocator) {
		old, _ := frozen_item_info(i)
		got, ok := registry_item_info(reg, i)
		testing.expectf(t, ok, "item %d", i)
		short := old.name
		testing.expectf(
			t,
			got.name == fmt.tprintf("voxiverse:%s", short),
			"item %d is %s",
			i,
			got.name,
		)
		testing.expectf(
			t,
			got.stack == old.stack,
			"%s stack %d vs %d",
			short,
			got.stack,
			old.stack,
		)
		testing.expectf(t, got.block == old.block, "%s places", short)
		testing.expectf(t, got.tool == old.tool, "%s tool", short)
		testing.expectf(t, got.armor == old.armor, "%s armor", short)
		testing.expectf(t, got.equip == old.equip, "%s equip", short)
		testing.expectf(t, got.modifiers == old.modifiers, "%s modifiers", short)
		by_id, item_found := registry_item(reg, short)
		testing.expectf(t, item_found && by_id == i, "%s by id", short)
	}
	testing.expect_value(
		t,
		len(registry_every_item(reg)),
		len(frozen_every_item(context.temp_allocator)) + BASE_NEW_TYPES,
	)
	// Every old item is still there (the base pack's new block types add theirs among the blocks').
	old_all := frozen_every_item(context.temp_allocator)
	new_all := registry_every_item(reg)
	for i in old_all {
		present := false
		for j in new_all {if i == j {present = true}}
		testing.expectf(t, present, "item %d", i)
	}
	// Nothing beyond the old items exists.
	_, ok := registry_item_info(reg, PACK_ITEMS)
	testing.expect(t, !ok)
	// Textures and sounds: one per generator, in order.
	testing.expect_value(t, len(reg.textures), len(TEXTURE_GENERATOR_NAMES))
	for tex, i in reg.textures {
		testing.expect_value(t, tex.generator, TEXTURE_GENERATOR_NAMES[i])
		testing.expect_value(t, tex.id, fmt.tprintf("voxiverse:%s", TEXTURE_GENERATOR_NAMES[i]))
	}
	testing.expect_value(t, len(reg.sounds), len(SOUND_GENERATOR_NAMES))
	testing.expect(t, len(reg.structures) == 2)
}

// --- Packs in memory. ---

File :: struct {
	path: string,
	text: string,
}

pack_of :: proc(ns: string, files: []File, manifest := "") -> Pack_Source {
	list := make([dynamic]Pack_File, context.temp_allocator)
	m := manifest
	if m == "" {
		m = fmt.tprintf(
			`{{"format": 1, "namespace": "%s", "version": "1.0.0", "title": "T", "requires": ["voxiverse"]}}`,
			ns,
		)
	}
	append(&list, Pack_File{"pack.json", transmute([]u8)m})
	for f in files {append(&list, Pack_File{f.path, transmute([]u8)f.text})}
	return {ns, list[:]}
}

build_with :: proc(packs: ..Pack_Source) -> (^Registry, []Pack_Error) {
	sources := make([dynamic]Pack_Source, context.temp_allocator)
	append(&sources, base_pack_source(context.temp_allocator))
	append(&sources, ..packs)
	return registry_build(sources[:], .Server, context.temp_allocator)
}

errors_text :: proc(errs: []Pack_Error) -> string {
	lines := make([dynamic]string, context.temp_allocator)
	for e in errs {append(&lines, pack_error_text(e))}
	return strings.join(lines[:], "\n", context.temp_allocator)
}

TEST_PACK :: []File {
	{
		"data/blocks/marble.json",
		`{"marble": {"textures": {"all": "voxiverse:stone"}, "light": 7, "sound": "voxiverse:stone"}}`,
	},
	{"data/items/chisel.json", `{"chisel": {"stack": 1}}`},
	{
		"data/recipes/chisel.json",
		`{"chisel": {"type": "shaped", "pattern": ["#", "#"], "key": {"#": "testpack:marble"}, "output": {"item": "testpack:chisel"}}}`,
	},
}

// A pack adds a block, an item and a recipe with no code of its own.
@(test)
test_pack_adds_block_item_recipe :: proc(t: ^testing.T) {
	reg, errs := build_with(pack_of("testpack", TEST_PACK))
	testing.expect_value(t, errors_text(errs), "")
	if reg == nil {return}
	marble, ok := registry_block(reg, "testpack:marble")
	testing.expect(t, ok)
	testing.expect_value(t, int(marble), BASE_STATES)
	testing.expect_value(t, reg.blocks.light[marble], 7)
	testing.expect(t, block_collides(&reg.blocks, marble) && block_opaque(&reg.blocks, marble))
	stone, _ := registry_block(reg, "stone")
	testing.expect_value(t, reg.blocks.defs[marble].faces, reg.blocks.defs[stone].faces)
	testing.expect_value(t, reg.blocks.defs[marble].sound, reg.blocks.defs[stone].sound)
	item, item_ok := registry_item(reg, "testpack:marble")
	testing.expect(t, item_ok)
	testing.expect_value(t, int(item), BASE_TYPES + 1)
	info, _ := registry_item_info(reg, item)
	testing.expect_value(t, info.block, marble)
	testing.expect_value(t, info.name, "testpack:marble")
	chisel, chisel_ok := registry_item(reg, "testpack:chisel")
	testing.expect(t, chisel_ok)
	testing.expect_value(t, chisel, PACK_ITEMS)
	info, _ = registry_item_info(reg, chisel)
	testing.expect_value(t, info.stack, 1)
	testing.expect_value(t, registry_block_drop(reg, marble), item)
	// The old things keep their numbers.
	testing.expect_value(
		t,
		len(registry_every_item(reg)),
		len(frozen_every_item(context.temp_allocator)) + BASE_NEW_TYPES + 2,
	)

	two := Stack{item, 1}
	grid: [9]Stack
	grid[0], grid[1] = two, two // 1 wide, 2 high
	id, found := recipe_match(reg, grid, 1, 2)
	testing.expect(t, found)
	testing.expect_value(t, reg.recipes[id].output.item, chisel)
	grid = {}
	grid[0], grid[1] = two, two // 2 wide, 1 high
	_, found = recipe_match(reg, grid, 2, 1)
	testing.expect(t, !found)
	// Anywhere in the grid.
	grid = {}
	grid[4], grid[7] = two, two
	_, found = recipe_match(reg, grid, 3, 3)
	testing.expect(t, found)
	// Three is too many.
	grid[1] = two
	_, found = recipe_match(reg, grid, 3, 3)
	testing.expect(t, !found)
}

@(private = "file")
Broken :: struct {
	name:  string,
	packs: []Pack_Source,
	want:  string,
}

// one: a single pack, testpack, of these files.
@(private = "file")
one :: proc(files: []File) -> []Pack_Source {
	list := make([]Pack_Source, 1, context.temp_allocator)
	list[0] = pack_of("testpack", files)
	return list
}

@(private = "file")
many_blocks :: proc(n: int, prefix: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "{")
	for i in 0 ..< n {
		if i > 0 {strings.write_string(&sb, ",")}
		fmt.sbprintf(&sb, `"%s%d":{{"textures":{{"all":"voxiverse:stone"}}}}`, prefix, i)
	}
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

@(private = "file")
too_many_packs :: proc() -> []Pack_Source {
	list := make([]Pack_Source, 32, context.temp_allocator) // with the base: 33
	for i in 0 ..< 32 {list[i] = pack_of(fmt.tprintf("p%d", i), nil)}
	return list
}

@(test)
test_broken_packs :: proc(t: ^testing.T) {
	big := strings.repeat(" ", 1 << 20 + 1, context.temp_allocator)
	many_files := make([dynamic]File, context.temp_allocator)
	for i in 0 ..< 1025 {append(&many_files, File{fmt.tprintf("data/blocks/f%d.json", i), "{}"})}
	cases := []Broken {
		{
			"unquoted key",
			one({{"data/blocks/a.json", "{\n  rock: {}\n}"}}),
			`testpack/data/blocks/a.json:2:3: keys are quoted: write "rock"`,
		},
		{
			"single quotes",
			one({{"data/blocks/a.json", `{"rock": {"sound": 'x'}}`}}),
			`testpack/data/blocks/a.json:1:20: strings use double quotes`,
		},
		{
			"duplicate key",
			one({{"data/blocks/a.json", "{\"rock\": {\"light\": 1,\n\"light\": 2}}"}}),
			`testpack/data/blocks/a.json:2:1: "light" is given twice (first on line 1)`,
		},
		{
			"unknown field",
			one(
				{
					{
						"data/blocks/stone.json",
						`{"rock": {"textures": {"all": "stone"}, "ligth": 3}}`,
					},
				},
			),
			`testpack/data/blocks/stone.json:1:41: "ligth" is not a block field; did you mean "light"?`,
		},
		{
			"unknown field far",
			one(
				{
					{
						"data/blocks/a.json",
						`{"rock": {"textures": {"all": "stone"}, "zzzzzzzzzzzz": 3}}`,
					},
				},
			),
			`testpack/data/blocks/a.json:1:41: "zzzzzzzzzzzz" is not a block field; the valid ones are "collides", "opaque", "targetable", "breakable", "placeable", "replaceable", "shades", "cull_same", "liquid", "light", "render", "layer", "textures", "sound", "drop", "support", "states", "default", "shape", "collision", "selection", "render_shape", "place", "climbable", "override"`,
		},
		{
			"light out of range",
			one({{"data/blocks/a.json", `{"rock": {"textures": {"all": "stone"}, "light": 20}}`}}),
			`testpack/data/blocks/a.json:1:50: light is 0..15, got 20`,
		},
		{
			"light is a float",
			one(
				{{"data/blocks/a.json", `{"rock": {"textures": {"all": "stone"}, "light": 1.5}}`}},
			),
			`testpack/data/blocks/a.json:1:50: light is a whole number 0..15`,
		},
		{
			"bool is a string",
			one(
				{
					{
						"data/blocks/a.json",
						`{"rock": {"textures": {"all": "stone"}, "collides": "yes"}}`,
					},
				},
			),
			`testpack/data/blocks/a.json:1:53: collides is true or false`,
		},
		{
			"bad render",
			one(
				{
					{
						"data/blocks/a.json",
						`{"rock": {"textures": {"all": "stone"}, "render": "cub"}}`,
					},
				},
			),
			`testpack/data/blocks/a.json:1:51: render is one of "cube", "cross", "none"; got "cub"; did you mean "cube"?`,
		},
		{
			"opaque needs a cube",
			one(
				{
					{
						"data/blocks/a.json",
						`{"rock": {"textures": {"all": "stone"}, "render": "cross"}}`,
					},
				},
			),
			`testpack/data/blocks/a.json:1:2: a block is opaque unless it says otherwise, which needs render "cube" and layer "opaque"; set "opaque": false`,
		},
		{
			"all and side",
			one(
				{
					{
						"data/blocks/a.json",
						`{"rock": {"textures": {"all": "voxiverse:stone", "side": "voxiverse:dirt"}}}`,
					},
				},
			),
			`testpack/data/blocks/a.json:1:23: "all" cannot be combined with side, top or bottom; use one or the others`,
		},
		{
			"dangling texture",
			one({{"data/blocks/a.json", `{"rock": {"textures": {"all": "voxiverse:stoen"}}}`}}),
			`testpack/data/blocks/a.json:1:31: "voxiverse:stoen" is not a texture; did you mean "voxiverse:stone"?`,
		},
		{
			"no texture of its own",
			one({{"data/blocks/a.json", `{"rock": {}}`}}),
			`testpack/data/blocks/a.json:1:2: no texture "testpack:rock" for this block; add "textures", or a texture with that id`,
		},
		{
			"dangling sound",
			one(
				{
					{
						"data/blocks/a.json",
						`{"rock": {"textures": {"all": "stone"}, "sound": "rumble"}}`,
					},
				},
			),
			`testpack/data/blocks/a.json:1:50: "rumble" is not a sound set`,
		},
		{
			"dangling drop",
			one(
				{
					{
						"data/blocks/a.json",
						`{"rock": {"textures": {"all": "stone"}, "drop": "voxiverse:rubble"}}`,
					},
				},
			),
			`testpack/data/blocks/a.json:1:49: "voxiverse:rubble" is not an item`,
		},
		{
			"dangling support tag",
			one(
				{
					{
						"data/blocks/a.json",
						`{"rock": {"textures": {"all": "stone"}, "support": {"below": "nothing"}}}`,
					},
				},
			),
			`testpack/data/blocks/a.json:1:62: "nothing" is not a block tag`,
		},
		{
			"dangling recipe item",
			one(
				{
					{
						"data/recipes/a.json",
						`{"r": {"type": "shapeless", "inputs": [{"item": "voxiverse:stoen"}], "output": {"item": "voxiverse:stone"}}}`,
					},
				},
			),
			`testpack/data/recipes/a.json:1:49: "voxiverse:stoen" is not an item; did you mean "voxiverse:stone"?`,
		},
		{
			"dangling tag value",
			one({{"data/block_tags/a.json", `{"t": {"values": ["voxiverse:stoen"]}}`}}),
			`testpack/data/block_tags/a.json:1:19: "voxiverse:stoen" is not a block; did you mean "voxiverse:stone"?`,
		},
		{
			"duplicate id",
			one(
				{
					{"data/blocks/a.json", `{"rock": {"textures": {"all": "stone"}}}`},
					{"data/blocks/b.json", `{"rock": {"textures": {"all": "stone"}}}`},
				},
			),
			`testpack/data/blocks/b.json:1:2: "rock" is defined twice (first at data/blocks/a.json:1:2); rename one, or set "override": true`,
		},
		{
			"override without the flag",
			one({{"data/blocks/a.json", `{"voxiverse:stone": {"light": 3}}`}}),
			`testpack/data/blocks/a.json:1:2: "voxiverse:stone" is defined twice (first at voxiverse/data/blocks/terrain.json:2:2); rename one, or set "override": true`,
		},
		{
			"override of a missing id",
			one({{"data/blocks/a.json", `{"voxiverse:stoen": {"light": 3, "override": true}}`}}),
			`testpack/data/blocks/a.json:1:2: "voxiverse:stoen" does not exist, so it cannot be overridden; did you mean "voxiverse:stone"?`,
		},
		{
			"tag cycle",
			one(
				{
					{
						"data/block_tags/a.json",
						`{"a": {"values": ["#testpack:b"]}, "b": {"values": ["#testpack:a"]}}`,
					},
				},
			),
			`testpack/data/block_tags/a.json:1:53: tag "testpack:b" includes itself through "testpack:a"; remove the loop`,
		},
		{
			"tag names itself",
			one({{"data/block_tags/a.json", `{"a": {"values": ["#testpack:a"]}}`}}),
			`testpack/data/block_tags/a.json:1:19: tag "testpack:a" includes itself through "testpack:a"; remove the loop`,
		},
		{
			"stray file",
			one({{"data/blocks/notes.txt", "hello"}}),
			`testpack/data/blocks/notes.txt: not a pack file: data/blocks/ holds .json files`,
		},
		{
			"stray directory",
			one({{"data/blocks/sub/a.json", "{}"}}),
			`testpack/data/blocks/sub/a.json: not a pack file; a pack holds pack.json and the directories assets/textures/, assets/sounds/ (client only), data/blocks/, data/items/, data/block_tags/, data/item_tags/, data/recipes/, data/shapes/ (both sides) and server/structures/ (server only)`,
		},
		{
			"stray top-level file",
			one({{"readme.md", "hello"}}),
			`testpack/readme.md: not a pack file; a pack holds pack.json and the directories assets/textures/, assets/sounds/ (client only), data/blocks/, data/items/, data/block_tags/, data/item_tags/, data/recipes/, data/shapes/ (both sides) and server/structures/ (server only)`,
		},
		{
			"loot tables",
			one({{"server/loot_tables/a.json", "{}"}}),
			`testpack/server/loot_tables/: loot tables are read from M53 on; remove the directory`,
		},
		{
			"file over the limit",
			one({{"data/blocks/a.json", big}}),
			`testpack/data/blocks/a.json: file is 1048577 bytes; the limit is 1048576`,
		},
		{"too many files", one(many_files[:]), `testpack: 1026 files; the limit is 1024`},
		{
			"bad path",
			one({{"data/blocks/A.json", "{}"}}),
			`testpack/data/blocks/A.json: path is over 128 bytes or has a character outside a-z, 0-9 and _./-; rename it`,
		},
		{
			"too many blocks",
			one(
				{
					{"data/blocks/a.json", many_blocks(2500, "a")},
					{"data/blocks/b.json", many_blocks(2500, "b")},
				},
			),
			fmt.tprintf("%d blocks; the limit is 4096", 5000 + BASE_TYPES),
		},
		{
			"stack out of range",
			one({{"data/items/a.json", `{"x": {"stack": 1000}}`}}),
			`testpack/data/items/a.json:1:17: stack is 1..999, got 1000`,
		},
		{
			"too many modifiers",
			one(
				{
					{
						"data/items/a.json",
						`{"x": {"modifiers": [{"stat": "speed", "amount": 1}, {"stat": "jump", "amount": 1}, {"stat": "speed", "amount": 2}]}}`,
					},
				},
			),
			`testpack/data/items/a.json:1:21: an item has at most 2 modifiers, got 3`,
		},
		{
			"unknown modifier stat",
			one({{"data/items/a.json", `{"x": {"modifiers": [{"stat": "spede", "amount": 1}]}}`}}),
			`testpack/data/items/a.json:1:31: stat is one of "speed", "jump", "air_jumps", "max_health"; got "spede"; did you mean "speed"?`,
		},
		{
			"unknown generator",
			one({{"assets/textures/a.json", `{"x": {"generator": "marbel"}}`}}),
			"testpack/assets/textures/a.json:1:21: generator is one of \"stone\"~",
		},
		{
			"pattern key missing",
			one(
				{
					{
						"data/recipes/a.json",
						`{"r": {"type": "shaped", "pattern": ["#X"], "key": {"#": "voxiverse:stone"}, "output": {"item": "voxiverse:stone"}}}`,
					},
				},
			),
			`testpack/data/recipes/a.json:1:38: "X" is not in the key; add it`,
		},
		{
			"recipe without output",
			one(
				{
					{
						"data/recipes/a.json",
						`{"r": {"type": "shapeless", "inputs": [{"item": "voxiverse:stone"}]}}`,
					},
				},
			),
			`testpack/data/recipes/a.json:1:2: "output" is missing; say what the recipe makes`,
		},
		{
			"damaged structure",
			one({{"server/structures/a.vxs", "not a structure"}}),
			`testpack/server/structures/a.vxs: cannot be read: it is damaged, or names a block no pack defines`,
		},
		{
			"bad id in a key",
			one({{"data/blocks/a.json", `{"Rock": {}}`}}),
			`testpack/data/blocks/a.json:1:2: "Rock" is not a name; use 1 to 48 of a-z, 0-9 and _`,
		},
		{
			"definition is not an object",
			one({{"data/blocks/a.json", `{"rock": 3}`}}),
			`testpack/data/blocks/a.json:1:10: "rock" must be an object of fields`,
		},
		{
			"not a structure name",
			one({{"server/structures/A.vxs", "x"}}),
			`testpack/server/structures/A.vxs: path is over 128 bytes or has a character outside a-z, 0-9 and _./-; rename it`,
		},
		{
			"namespace differs from the directory",
			{pack_of("testpack", nil, `{"format": 1, "namespace": "farm_fix", "version": "1"}`)},
			`testpack/pack.json:1:28: namespace "farm_fix" does not match the directory "testpack"; rename one`,
		},
		{
			"base namespace taken",
			{pack_of("voxiverse", nil)},
			`voxiverse: the namespace voxiverse is the base game's; use your own`,
		},
		{
			"pack.json missing",
			{Pack_Source{"testpack", nil}},
			`testpack: the pack has no pack.json; add one`,
		},
		{
			"pack.json has an unknown field",
			{
				pack_of(
					"testpack",
					nil,
					`{"format": 1, "namespace": "testpack", "version": "1", "titel": "x"}`,
				),
			},
			`testpack/pack.json:1:56: "titel" is not a pack field; did you mean "title"?`,
		},
		{
			"pack.json lacks the version",
			{pack_of("testpack", nil, `{"format": 1, "namespace": "testpack"}`)},
			`testpack/pack.json:1:1: "version" is missing; add it`,
		},
		{
			"pack.json has another format",
			{pack_of("testpack", nil, `{"format": 2, "namespace": "testpack", "version": "1"}`)},
			`testpack/pack.json:1:12: format is 1; this game reads format 1 packs`,
		},
		{
			"requires a pack not loaded before",
			{
				pack_of(
					"testpack",
					nil,
					`{"format": 1, "namespace": "testpack", "version": "1", "requires": ["later"]}`,
				),
				pack_of("later", nil),
			},
			`testpack/pack.json:1:69: requires "later", which is not loaded before this pack; list it earlier in the universe's packs`,
		},
		{
			"two packs override one field",
			{
				pack_of(
					"farmfix",
					{
						{
							"data/blocks/a.json",
							`{"voxiverse:stone": {"light": 3, "override": true}}`,
						},
					},
				),
				pack_of(
					"moretrees",
					{
						{
							"data/blocks/b.json",
							`{"voxiverse:stone": {"light": 5, "override": true}}`,
						},
					},
				),
			},
			`moretrees/data/blocks/b.json:1:22: voxiverse:stone.light is also set by farmfix (data/blocks/a.json:1:31); add "farmfix" to moretrees's requires to override it knowingly`,
		},
		{"too many packs", too_many_packs(), `33 packs; the limit is 32`},
		{
			"nested too deep",
			one(
				{
					{
						"data/blocks/a.json",
						`{"rock": {"textures": {"all": [[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]}}}`,
					},
				},
			),
			`testpack/data/blocks/a.json:1:60: nested deeper than 32 levels; flatten it`,
		},
	}
	for c in cases {
		reg, errs := build_with(..c.packs)
		testing.expectf(t, reg == nil, "%s: should be refused", c.name)
		got := errors_text(errs)
		want := c.want
		matched := got == want
		if strings.has_suffix(want, "~") {matched = strings.has_prefix(got, want[:len(want) - 1])}
		testing.expectf(t, matched, "%s:\n--- got:\n%s\n--- want:\n%s", c.name, got, c.want)
	}
}

@(test)
test_missing_builtin_is_named :: proc(t: ^testing.T) {
	src := pack_of(
		"voxiverse",
		{{"data/blocks/air.json", `{"air": {"render": "none"}}`}},
		`{"format": 1, "namespace": "voxiverse", "version": "1"}`,
	)
	reg, errs := registry_build({src}, .Server, context.temp_allocator)
	testing.expect(t, reg == nil)
	testing.expect(t, len(errs) > 1)
	testing.expect_value(
		t,
		pack_error_text(errs[0]),
		"voxiverse:stone is not defined by any pack; the engine needs it (common/game/block.odin)",
	)
}

@(test)
test_requires_lets_a_pack_build_on_another :: proc(t: ^testing.T) {
	farmfix := pack_of(
		"farmfix",
		{{"data/blocks/a.json", `{"voxiverse:stone": {"light": 3, "override": true}}`}},
	)
	moretrees := pack_of(
		"moretrees",
		{{"data/blocks/b.json", `{"voxiverse:stone": {"light": 5, "override": true}}`}},
		`{"format": 1, "namespace": "moretrees", "version": "1", "requires": ["voxiverse", "farmfix"]}`,
	)
	reg, errs := build_with(farmfix, moretrees)
	testing.expect_value(t, errors_text(errs), "")
	if reg == nil {return}
	stone, _ := registry_block(reg, "stone")
	testing.expect_value(t, reg.blocks.light[stone], 5)
	// The base pack's fields stay where the override does not touch them.
	testing.expect(t, block_opaque(&reg.blocks, stone) && block_collides(&reg.blocks, stone))
}

@(test)
test_overrides_merge_by_field_and_tags_merge :: proc(t: ^testing.T) {
	files := []File {
		{
			"data/blocks/a.json",
			`{"voxiverse:lamp": {"light": 9, "override": true}, "voxiverse:glass": {"textures": {"all": "voxiverse:ice"}, "override": true}}`,
		},
		{
			"data/block_tags/a.json",
			`{"voxiverse:tillable": {"values": ["voxiverse:sand"]}, "voxiverse:farmland": {"values": ["voxiverse:gravel"], "replace": true}}`,
		},
		{"data/items/a.json", `{"voxiverse:hoe": {"stack": 5, "override": true}}`},
	}
	reg, errs := build_with(pack_of("testpack", files))
	testing.expect_value(t, errors_text(errs), "")
	if reg == nil {return}
	lamp, _ := registry_block(reg, "lamp")
	testing.expect_value(t, reg.blocks.light[lamp], 9)
	testing.expect(t, block_collides(&reg.blocks, lamp)) // not touched
	glass, _ := registry_block(reg, "glass")
	ice_tex := reg.ids[.Texture]["voxiverse:ice"]
	testing.expect_value(t, reg.blocks.defs[glass].faces, [3]u32{ice_tex, ice_tex, ice_tex})
	testing.expect(t, .Cull_Same in reg.blocks.flags[glass])
	tillable, _ := registry_block_tag(reg, "tillable")
	sand, _ := registry_block(reg, "sand")
	grass, _ := registry_block(reg, "grass")
	testing.expect(
		t,
		block_in_tag(&reg.blocks, sand, tillable) && block_in_tag(&reg.blocks, grass, tillable),
	)
	farmland_tag, _ := registry_block_tag(reg, "farmland")
	gravel, _ := registry_block(reg, "gravel")
	testing.expect(t, block_in_tag(&reg.blocks, gravel, farmland_tag))
	testing.expect(t, !block_in_tag(&reg.blocks, .Farmland, farmland_tag))
	hoe, _ := registry_item(reg, "hoe")
	info, _ := registry_item_info(reg, hoe)
	testing.expect_value(t, info.stack, 5)
	testing.expect_value(t, info.tool, Maybe(Tool)(Tool.Hoe))
}

// The registry is a function of the files: any order of a pack's files builds
// the same registry, and any one field of any kind changes its hash.
@(test)
test_registry_hash :: proc(t: ^testing.T) {
	forward := pack_of("testpack", TEST_PACK)
	backward := forward
	files := make([]Pack_File, len(forward.files), context.temp_allocator)
	for f, i in forward.files {files[len(files) - 1 - i] = f}
	backward.files = files
	a, _ := build_with(forward)
	b, _ := build_with(backward)
	testing.expect(t, a != nil && b != nil)
	if a == nil || b == nil {return}
	testing.expect_value(t, a.hash, b.hash)
	base, _ := build_with()
	testing.expect(t, base.hash != a.hash)
	variants := []File {
		{
			"data/blocks/marble.json",
			`{"marble": {"textures": {"all": "voxiverse:stone"}, "light": 8, "sound": "voxiverse:stone"}}`,
		},
		{
			"data/blocks/marble.json",
			`{"marble": {"textures": {"all": "voxiverse:dirt"}, "light": 7, "sound": "voxiverse:stone"}}`,
		},
		{
			"data/blocks/marble.json",
			`{"marble": {"textures": {"all": "voxiverse:stone"}, "light": 7, "sound": "voxiverse:dirt"}}`,
		},
		{
			"data/blocks/marble.json",
			`{"marble": {"textures": {"all": "voxiverse:stone"}, "light": 7, "sound": "voxiverse:stone", "collides": false}}`,
		},
		{"data/items/chisel.json", `{"chisel": {"stack": 2}}`},
		{
			"data/recipes/chisel.json",
			`{"chisel": {"type": "shaped", "pattern": ["#", "#"], "key": {"#": "testpack:marble"}, "output": {"item": "testpack:chisel", "count": 2}}}`,
		},
		{"data/block_tags/x.json", `{"x": {"values": []}}`},
		{"assets/textures/x.json", `{"x": {"generator": "stone"}}`},
	}
	for v in variants {
		changed := make([dynamic]File, context.temp_allocator)
		replaced := false
		for f in TEST_PACK {
			if f.path == v.path {
				append(&changed, v)
				replaced = true
			} else {
				append(&changed, f)
			}
		}
		if !replaced {append(&changed, v)}
		c, errs := build_with(pack_of("testpack", changed[:]))
		testing.expect_value(t, errors_text(errs), "")
		if c == nil {continue}
		if v.path == "assets/textures/x.json" {
			// Client-side art: in the registry text, left out of the content hash.
			testing.expect(t, c.hash == a.hash, "a texture changed the content hash")
			testing.expect(
				t,
				registry_text(c) != registry_text(a),
				"a texture did not change the text",
			)
		} else {
			testing.expectf(t, c.hash != a.hash, "%s did not change the hash", v.path)
		}
	}
}
