package game

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"

// The registry: everything a pack adds is content (blocks, items, textures,
// sounds, tags, recipes, structures), each with an id `namespace:name`.
// Built once from packs (registry_load.odin), then immutable; it owns its
// memory in an arena of its own and is never global.

// Limits (each an error with the number when passed).
MAX_PACKS :: 32
MAX_PACK_BYTES :: 16 << 20
MAX_PACK_FILES :: 1024
MAX_PACK_PATH :: 128
MAX_BLOCK_STATES :: 4096
MAX_TEXTURES :: 1024
MAX_SOUNDS :: 256
MAX_TAGS :: 512
MAX_TAG_VALUES :: 1024
MAX_RECIPES :: 4096
MAX_STRUCTURES :: 256
MAX_ERRORS :: 100

BASE_NAMESPACE :: "voxiverse"

// TEXTURE_GENERATOR_NAMES and SOUND_GENERATOR_NAMES: the generators the
// client has (mesh.Texture_Generator, sfx.Material, in their order; tests
// there compare). A texture or sound set of a pack names one.
@(rodata)
TEXTURE_GENERATOR_NAMES := [?]string {
	"stone",
	"dirt",
	"grass_top",
	"grass_side",
	"sand",
	"gravel",
	"bedrock",
	"lamp",
	"water",
	"snow",
	"ice",
	"clay",
	"sandstone_side",
	"sandstone_top",
	"log_side",
	"log_top",
	"leaves",
	"spruce_log_side",
	"spruce_leaves",
	"coal_ore",
	"iron_ore",
	"copper_ore",
	"tall_grass",
	"poppy",
	"dandelion",
	"cactus_side",
	"cactus_top",
	"cobblestone",
	"stone_bricks",
	"planks",
	"glass",
	"gate_ring",
	"gate_chevron",
	"gate_chevron_lit",
	"gate_horizon",
	"wool",
	"farmland_top",
	"farmland_moist_top",
	"wheat_0",
	"wheat_1",
	"wheat_2",
	"wheat_3",
	"wheat_4",
	"wheat_5",
	"wheat_6",
	"wheat_7",
	"wool_black",
	"chest_side",
	"chest_top",
}
@(rodata)
SOUND_GENERATOR_NAMES := [?]string {
	"stone",
	"dirt",
	"grass",
	"sand",
	"gravel",
	"glass",
	"wood",
	"snow",
}

// Id: `namespace:name`. namespace is [a-z0-9_]{1,32}, name [a-z0-9_]{1,48}.
Id :: struct {
	namespace: string,
	name:      string,
}

id_part_valid :: proc(s: string, max_len: int) -> bool {
	if len(s) < 1 || len(s) > max_len {return false}
	for c in transmute([]u8)s {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {return false}
	}
	return true
}

// id_parse: text as an id; a name without a colon is voxiverse:'s (what
// people and older saves write).
id_parse :: proc(text: string) -> (id: Id, ok: bool) {
	colon := strings.index_byte(text, ':')
	if colon < 0 {
		id = {BASE_NAMESPACE, text}
	} else {
		id = {text[:colon], text[colon + 1:]}
	}
	return id, id_part_valid(id.namespace, 32) && id_part_valid(id.name, 48)
}

id_text :: proc(id: Id, allocator := context.allocator) -> string {
	return strings.concatenate({id.namespace, ":", id.name}, allocator)
}

Content_Kind :: enum u8 {
	Texture,
	Sound,
	Block,
	Item,
	Block_Tag,
	Item_Tag,
	Recipe,
	Structure,
}

Block_Flag :: enum u8 {
	Collides,
	Opaque,
	Targetable,
	Breakable,
	Placeable,
	Replaceable,
	Shades,
	Cull_Same,
	Liquid,
}
Block_Flags :: bit_set[Block_Flag;u16]

Render_Kind :: enum u8 {
	Cube,
	Cross,
	None,
}

Layer_Kind :: enum u8 {
	Opaque,
	Cutout,
	Translucent,
}

NO_SOUND :: i32(-1)
NO_TAG :: i32(-1)

// Block_Def: what is not a flag or the light of one block.
Block_Def :: struct {
	id:      string,
	render:  Render_Kind,
	layer:   Layer_Kind,
	faces:   [3]u32, // texture layers: side, top, bottom
	sound:   i32, // a sound set index, or NO_SOUND
	drop:    Item,
	support: i32, // a block tag index (what a plant stands on), or NO_TAG
	tags:    []u16, // the block tags it is in, ascending
}

// Block_Table: the hot part, arrays indexed by the block's number.
Block_Table :: struct {
	count: int,
	flags: []Block_Flags,
	light: []u8,
	defs:  []Block_Def,
}

Item_Table :: struct {
	blocks:    []Item_Info, // by block number (name "" where not placeable)
	tools:     [Tool]Item_Info,
	materials: [Material]Item_Info,
	armor:     [Armor]Item_Info,
	pack:      []Item_Info, // PACK_ITEMS + n
}

Texture_Def :: struct {
	id:        string,
	generator: string,
}

Sound_Def :: struct {
	id:        string,
	generator: string,
}

Tag_Def :: struct {
	id:      string,
	members: []u32, // block numbers or items as numbers (Item), flattened, ascending
}

Recipe_Input :: struct {
	item: Item, // NO_ITEM: an empty cell (shaped) or a tag
	tag:  i32, // an item tag index, or NO_TAG
}

Recipe_Id :: distinct u32

Recipe_Def :: struct {
	id:     string,
	shaped: bool,
	width:  int, // shaped: the pattern's size
	height: int,
	inputs: []Recipe_Input, // shaped: width*height cells, row by row; else one per cell used
	output: Stack,
}

Structure_Def :: struct {
	id:       string,
	template: Template,
	hash:     u64,
}

Pack_Info :: struct {
	namespace:   string,
	version:     string,
	title:       string,
	description: string,
	requires:    []string,
	files:       int,
}

Registry :: struct {
	arena:      virtual.Arena,
	blocks:     Block_Table,
	items:      Item_Table,
	textures:   []Texture_Def,
	sounds:     []Sound_Def,
	block_tags: []Tag_Def,
	item_tags:  []Tag_Def,
	recipes:    []Recipe_Def,
	structures: []Structure_Def,
	packs:      []Pack_Info,
	ids:        [Content_Kind]map[string]u32, // id text -> number (blocks, items) or index
	hash:       u64,
	allocator:  runtime.Allocator,
}

registry_destroy :: proc(reg: ^Registry) {
	if reg == nil {return}
	a := reg.allocator
	virtual.arena_destroy(&reg.arena)
	free(reg, a)
}

// --- Lookups by number. ---

block_valid_table :: #force_inline proc(t: ^Block_Table, id: u16) -> bool {
	return int(id) < t.count
}

block_targetable_table :: #force_inline proc(t: ^Block_Table, b: Block) -> bool {
	return .Targetable in t.flags[b]
}

block_collides_table :: #force_inline proc(t: ^Block_Table, b: Block) -> bool {
	return .Collides in t.flags[b]
}

block_opaque_table :: #force_inline proc(t: ^Block_Table, b: Block) -> bool {
	return .Opaque in t.flags[b]
}

// block_shades_table: it stops sunlight from straight above (opaque blocks,
// and water and leaves, which let it seep in dimmed): a column's top.
block_shades_table :: #force_inline proc(t: ^Block_Table, b: Block) -> bool {
	return t.flags[b] & {.Opaque, .Shades} != {}
}

block_light_table :: #force_inline proc(t: ^Block_Table, b: Block) -> u8 {
	return t.light[b]
}

block_has :: #force_inline proc(t: ^Block_Table, b: Block, f: Block_Flag) -> bool {
	return f in t.flags[b]
}

block_in_tag :: proc(t: ^Block_Table, b: Block, tag: i32) -> bool {
	if tag < 0 {return false}
	for x in t.defs[b].tags {if i32(x) == tag {return true}}
	return false
}

// block_is_plant_in: a block that stands on the ground and goes when it does.
block_is_plant_in :: #force_inline proc(t: ^Block_Table, b: Block) -> bool {
	return t.defs[b].support != NO_TAG
}

// block_supported: whether plant may stand on below.
block_supported :: proc(t: ^Block_Table, plant, below: Block) -> bool {
	return block_in_tag(t, below, t.defs[plant].support)
}

// --- Lookups by id. ---

// registry_block: the block with this id (a name without a colon is voxiverse:'s).
registry_block :: proc(reg: ^Registry, text: string) -> (Block, bool) {
	id, ok := id_parse(text)
	if !ok {return .Air, false}
	buf: [96]u8
	full := fmt.bprintf(buf[:], "%s:%s", id.namespace, id.name)
	n, found := reg.ids[.Block][full]
	return Block(n), found
}

block_id :: proc(reg: ^Registry, b: Block) -> string {
	if !block_valid_table(&reg.blocks, u16(b)) {return ""}
	return reg.blocks.defs[b].id
}

// registry_item_info: what item i is; false if it is no item here.
registry_item_info :: proc(reg: ^Registry, i: Item) -> (Item_Info, bool) {
	t := &reg.items
	switch {
	case i == NO_ITEM:
		return {}, false
	case i >= ARMOR_ITEMS:
		a := int(i - ARMOR_ITEMS)
		if a >= len(Armor) {return {}, false}
		return t.armor[Armor(a)], true
	case i >= MATERIAL_ITEMS:
		m := int(i - MATERIAL_ITEMS)
		if m >= len(Material) {return {}, false}
		return t.materials[Material(m)], true
	case i >= TOOL_ITEMS:
		k := int(i - TOOL_ITEMS)
		if k >= len(Tool) {return {}, false}
		return t.tools[Tool(k)], true
	case i >= PACK_ITEMS:
		n := int(i - PACK_ITEMS)
		if n >= len(t.pack) {return {}, false}
		return t.pack[n], true
	}
	b := int(i) - 1
	if b >= len(t.blocks) || t.blocks[b].name == "" {return {}, false}
	return t.blocks[b], true
}

registry_item :: proc(reg: ^Registry, text: string) -> (Item, bool) {
	id, ok := id_parse(text)
	if !ok {return NO_ITEM, false}
	buf: [96]u8
	full := fmt.bprintf(buf[:], "%s:%s", id.namespace, id.name)
	n, found := reg.ids[.Item][full]
	return Item(n), found
}

registry_item_id :: proc(reg: ^Registry, i: Item) -> string {
	info, _ := registry_item_info(reg, i)
	return info.name
}

// registry_every_item: all the items there are, in a stable order (blocks,
// tools, materials, armor, then the packs' items).
registry_every_item :: proc(reg: ^Registry, allocator := context.temp_allocator) -> []Item {
	items := make([dynamic]Item, allocator)
	for i in 0 ..< len(reg.items.blocks) {
		if reg.items.blocks[i].name != "" {append(&items, Item(i + 1))}
	}
	for t in Tool {append(&items, item_of_tool(t))}
	for m in Material {append(&items, item_of_material(m))}
	for a in Armor {append(&items, item_of_armor(a))}
	for i in 0 ..< len(reg.items.pack) {append(&items, PACK_ITEMS + Item(i))}
	return items[:]
}

// registry_block_drop: the item breaking b leaves.
registry_block_drop :: proc(reg: ^Registry, b: Block) -> Item {
	return reg.blocks.defs[b].drop
}

// registry_block_tag, registry_item_tag: a tag by id.
registry_block_tag :: proc(reg: ^Registry, text: string) -> (i32, bool) {
	id, ok := id_parse(strings.trim_prefix(text, "#"))
	if !ok {return NO_TAG, false}
	buf: [96]u8
	n, found := reg.ids[.Block_Tag][fmt.bprintf(buf[:], "%s:%s", id.namespace, id.name)]
	return i32(n), found
}

registry_item_tag :: proc(reg: ^Registry, text: string) -> (i32, bool) {
	id, ok := id_parse(strings.trim_prefix(text, "#"))
	if !ok {return NO_TAG, false}
	buf: [96]u8
	n, found := reg.ids[.Item_Tag][fmt.bprintf(buf[:], "%s:%s", id.namespace, id.name)]
	return i32(n), found
}

registry_item_in_tag :: proc(reg: ^Registry, i: Item, tag: i32) -> bool {
	if tag < 0 || int(tag) >= len(reg.item_tags) {return false}
	for m in reg.item_tags[tag].members {if Item(m) == i {return true}}
	return false
}

// --- Recipes. ---

@(private = "file")
input_matches :: proc(reg: ^Registry, in_: Recipe_Input, s: Stack) -> bool {
	if stack_empty(s) {return in_.item == NO_ITEM && in_.tag == NO_TAG}
	if in_.tag != NO_TAG {return registry_item_in_tag(reg, s.item, in_.tag)}
	return in_.item != NO_ITEM && in_.item == s.item
}

// recipe_match: the first recipe (in registry order) the grid satisfies. grid
// holds width*height stacks row by row (at most 3x3). A shaped recipe matches
// when the grid's filled cells, as a box, are exactly its pattern (placed
// anywhere in the grid, not mirrored); a shapeless one when its inputs and
// the filled cells pair off one to one.
recipe_match :: proc(
	reg: ^Registry,
	grid: [9]Stack,
	width, height: int,
) -> (
	id: Recipe_Id,
	ok: bool,
) {
	if width < 1 || height < 1 || width > 3 || height > 3 {return}
	lo_x, lo_y, hi_x, hi_y := 99, 99, -1, -1
	filled := 0
	for y in 0 ..< height {
		for x in 0 ..< width {
			if stack_empty(grid[y * width + x]) {continue}
			filled += 1
			lo_x, hi_x = min(lo_x, x), max(hi_x, x)
			lo_y, hi_y = min(lo_y, y), max(hi_y, y)
		}
	}
	if filled == 0 {return}
	bw, bh := hi_x - lo_x + 1, hi_y - lo_y + 1
	for r, ri in reg.recipes {
		if r.shaped {
			if r.width != bw || r.height != bh {continue}
			matched := true
			for y in 0 ..< bh {
				for x in 0 ..< bw {
					if !input_matches(
						reg,
						r.inputs[y * bw + x],
						grid[(lo_y + y) * width + lo_x + x],
					) {
						matched = false
					}
				}
			}
			if matched {return Recipe_Id(ri), true}
		} else if len(r.inputs) == filled {
			cells: [9]Stack
			n := 0
			for y in 0 ..< height {
				for x in 0 ..< width {
					if !stack_empty(grid[y * width + x]) {
						cells[n] = grid[y * width + x]
						n += 1
					}
				}
			}
			used: [9]bool
			if pair_off(reg, r.inputs, cells[:n], &used, 0) {return Recipe_Id(ri), true}
		}
	}
	return
}

@(private = "file")
pair_off :: proc(
	reg: ^Registry,
	inputs: []Recipe_Input,
	cells: []Stack,
	used: ^[9]bool,
	at: int,
) -> bool {
	if at == len(inputs) {return true}
	for i in 0 ..< len(cells) {
		if used[i] || !input_matches(reg, inputs[at], cells[i]) {continue}
		used[i] = true
		if pair_off(reg, inputs, cells, used, at + 1) {return true}
		used[i] = false
	}
	return false
}

// --- The text and the hash. ---

// registry_text: every resolved definition, one per line, in registry order.
registry_text :: proc(reg: ^Registry, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for p in reg.packs {
		fmt.sbprintf(&b, "pack %s %s\n", p.namespace, p.version)
	}
	for t, i in reg.textures {fmt.sbprintf(&b, "texture %s %d generator=%s\n", t.id, i, t.generator)}
	for s, i in reg.sounds {fmt.sbprintf(&b, "sound %s %d generator=%s\n", s.id, i, s.generator)}
	for i in 0 ..< reg.blocks.count {
		d := reg.blocks.defs[i]
		fmt.sbprintf(&b, "block %s %d flags=", d.id, i)
		for f in Block_Flag {
			if f in reg.blocks.flags[i] {fmt.sbprintf(&b, "%v,", f)}
		}
		fmt.sbprintf(
			&b,
			" light=%d render=%v layer=%v textures=%d,%d,%d sound=%d drop=%d support=%d tags=",
			reg.blocks.light[i],
			d.render,
			d.layer,
			d.faces[0],
			d.faces[1],
			d.faces[2],
			d.sound,
			d.drop,
			d.support,
		)
		for x in d.tags {fmt.sbprintf(&b, "%d,", x)}
		strings.write_byte(&b, '\n')
	}
	item_line :: proc(b: ^strings.Builder, n: u32, info: Item_Info) {
		fmt.sbprintf(
			b,
			"item %s %d stack=%d places=%d tool=%v armor=%v equip=%v mods=%v\n",
			info.name,
			n,
			info.stack,
			info.block,
			info.tool,
			info.armor,
			info.equip,
			info.modifiers,
		)
	}
	for info, i in reg.items.blocks {if info.name != "" {item_line(&b, u32(i + 1), info)}}
	for t in Tool {item_line(&b, u32(item_of_tool(t)), reg.items.tools[t])}
	for m in Material {item_line(&b, u32(item_of_material(m)), reg.items.materials[m])}
	for a in Armor {item_line(&b, u32(item_of_armor(a)), reg.items.armor[a])}
	for info, i in reg.items.pack {item_line(&b, u32(PACK_ITEMS) + u32(i), info)}
	for t in reg.block_tags {fmt.sbprintf(&b, "block_tag %s %v\n", t.id, t.members)}
	for t in reg.item_tags {fmt.sbprintf(&b, "item_tag %s %v\n", t.id, t.members)}
	for r in reg.recipes {
		fmt.sbprintf(
			&b,
			"recipe %s shaped=%v %dx%d inputs=%v output=%v\n",
			r.id,
			r.shaped,
			r.width,
			r.height,
			r.inputs,
			r.output,
		)
	}
	for s in reg.structures {fmt.sbprintf(&b, "structure %s %v %x\n", s.id, s.template.size, s.hash)}
	return strings.to_string(b)
}

registry_hash_of :: proc(reg: ^Registry) -> u64 {
	text := registry_text(reg)
	h := hasher_make()
	hasher_bytes(&h, transmute([]u8)text)
	return hasher_finish(h)
}
