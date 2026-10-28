package game

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
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
	"ladder",
	"door_lower",
	"door_upper",
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
	Shape,
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

// Block_Type: one block definition (a number per definition, in M47's order);
// a Block is a state id, and a type owns a run of them (Type_Def).
Block_Type :: distinct u16

MAX_PROPS :: 6
MAX_PROP_VALUES :: 16
MAX_TYPE_STATES :: 256
MAX_SHAPE_BOXES :: 16

// Prop_Def: a state property: a name and its values, in declared order.
Prop_Def :: struct {
	name:   string,
	values: []string,
}

// Place_Rule: how an item places its type (common/game/placement.odin).
Place_Rule :: enum u8 {
	Default,
	Stairs,
	Slab,
	Attached,
	Connect, // the default state with its neighbours' connections (a fence)
	Door, // two cells, a lower and an upper half
}

PLACE_RULE_LIST := [?]string{"default", "stairs", "slab", "attached", "connect", "door"}
#assert(len(PLACE_RULE_LIST) == len(Place_Rule))

// Use_Rule: what the right button does to a block of the type (besides what
// the item in hand does): an edit of its state, predicted like any edit.
Use_Rule :: enum u8 {
	None,
	Toggle_Open, // flips the property `open`
}

USE_RULE_LIST := [?]string{"none", "toggle_open"}
#assert(len(USE_RULE_LIST) == len(Use_Rule))

// Block_Entity_Kind: the data a block of its own keeps beyond its state
// (block_entity.odin). The kinds are the engine's.
Block_Entity_Kind :: enum u8 {
	None,
	Container,
}


// Type_Def: one block type: its states are first_state ..< first_state +
// state_count, the index within the type mixed-radix over props (the last
// property fastest).
Type_Def :: struct {
	id:          string,
	first_state: u16,
	state_count: u16,
	props:       []Prop_Def,
	default:     Block,
	place:       Place_Rule,
	climbable:   bool,
	connect:     i32, // a block tag index: what a side connects to, or NO_TAG (north..west are bool properties)
	use:         Use_Rule,
	entity:      Block_Entity_Kind,
}

// Box: a box in sixteenths of a block, 0 <= lo < hi <= 16 (collision boxes
// may reach 24 on y).
Box :: struct {
	lo, hi: [3]u8,
}

// Shape_Ref: a shape's boxes: boxes[first:first+count] of Shape_Table.boxes.
Shape_Ref :: struct {
	first, count: u16,
}

SHAPE_EMPTY :: u16(0)
SHAPE_CUBE :: u16(1)

// Face: a cell's six faces, by the axis they face (the mesher's order).
Face :: enum u8 {
	Pos_X,
	Neg_X,
	Pos_Y,
	Neg_Y,
	Pos_Z,
	Neg_Z,
}

// Cover: which sixteenths of a cell's face a shape's boxes cover, per face
// 16 rows of 16 bits (row = the face's second axis, bit = the first).
Cover :: [Face][16]u16

Shape_Table :: struct {
	refs:  []Shape_Ref, // by shape id
	boxes: []Box,
	cover: []Cover, // by shape id (computed from the boxes)
	ids:   []string, // by shape id: "" for the interned ones a block made
}

NO_SOUND :: i32(-1)
NO_TAG :: i32(-1)

// Block_Def: what is not a flag or the light of one block.
Block_Def :: struct {
	id:        string,
	render:    Render_Kind,
	layer:     Layer_Kind,
	faces:     [3]u32, // texture layers: side, top, bottom
	sound:     i32, // a sound set index, or NO_SOUND
	drop:      Item,
	support:   i32, // a block tag index (what a plant stands on), or NO_TAG
	back:      i32, // a block tag index: what a facing block's back is against, or NO_TAG
	back_full: bool, // its back must be against a full face
	tags:      []u16, // the block tags it is in, ascending
}

// Block_Table: the hot part, arrays indexed by the block's number.
// A block here is a state id: count is the number of states, and the arrays
// are by state (a type's states share what is not a shape).
Block_Table :: struct {
	count:     int,
	flags:     []Block_Flags,
	light:     []u8,
	defs:      []Block_Def,
	type_of:   []Block_Type, // by state
	types:     []Type_Def,
	shapes:    Shape_Table,
	collision: []u16, // shape ids by state
	selection: []u16,
	render:    []u16,
}

Item_Table :: struct {
	blocks:    []Item_Info, // by block type (name "" where not placeable)
	tools:     [Tool]Item_Info,
	materials: [Material]Item_Info,
	armor:     [Armor]Item_Info,
	pack:      []Item_Info, // PACK_ITEMS + n
}

Texture_Def :: struct {
	id:        string,
	generator: string, // "" for a texture of the pack's own image
	image:     string, // the pack file (assets/textures/marble.png), or ""
	layer:     u32, // its layer in the client's texture array: the generator's number in TEXTURE_GENERATOR_NAMES, or for an image len(TEXTURE_GENERATOR_NAMES) + its place among the images (Registry.images)
}

// Sound_Def: a generated sound (generator) or a set of the pack's own files
// (clips, by action: break, place, step; an empty list takes break's).
Sound_Def :: struct {
	id:        string,
	generator: string, // "" for a set of files
	material:  u32, // the generator's number in SOUND_GENERATOR_NAMES
	files:     [Sound_Action][]string, // paths
	clips:     [Sound_Action][][]u8, // the files' bytes (checked: size and length)
}

SOUND_VARIANTS :: 3 // files in one action of a sound set (the client's sfx.VARIANTS; a test compares)

Sound_Action :: enum u8 {
	Break,
	Place,
	Step,
}

SOUND_ACTION_NAMES :: [Sound_Action]string {
	.Break = "break",
	.Place = "place",
	.Step  = "step",
}

sound_has_files :: proc(s: Sound_Def) -> bool {
	return s.generator == ""
}

// registry_texture_layers: the layers of the client's texture array: one for each
// generator, then one for each image of a pack.
registry_texture_layers :: proc(reg: ^Registry) -> int {
	return len(TEXTURE_GENERATOR_NAMES) + len(reg.images)
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
	arena:      ^virtual.Arena, // its own allocation, so a swap of two registries (registry_swap) moves it with the contents
	blocks:     Block_Table,
	items:      Item_Table,
	textures:   []Texture_Def,
	images:     []Texture_Image, // the pixels of the textures that are images, in layer order
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
	virtual.arena_destroy(reg.arena)
	free(reg.arena, a)
	free(reg, a)
}

// registry_swap makes the registry at dst what src is, and frees what dst
// was along with src's struct: the address everyone holds stays good. Only
// when nothing is reading dst (the server between its jobs, the client
// between its mesh jobs).
registry_swap :: proc(dst, src: ^Registry) {
	dst^, src^ = src^, dst^
	registry_destroy(src)
}

// registry_id_changes: how src's ids differ from dst's, "" when the numbers
// of every block, item, texture and sound set are the same. A reload may
// change what a thing is, never which number it has (the registry does not
// grow while the universe runs).
registry_id_changes :: proc(dst, src: ^Registry) -> string {
	lists :: proc(reg: ^Registry) -> [4][dynamic]string {
		out: [4][dynamic]string
		for i in 0 ..< reg.blocks.count {append(&out[0], reg.blocks.defs[i].id)}
		for info in reg.items.blocks {if info.name != "" {append(&out[1], info.name)}}
		for t in Tool {append(&out[1], reg.items.tools[t].name)}
		for m in Material {append(&out[1], reg.items.materials[m].name)}
		for a in Armor {append(&out[1], reg.items.armor[a].name)}
		for info in reg.items.pack {append(&out[1], info.name)}
		for t in reg.textures {append(&out[2], t.id)}
		for t in reg.sounds {append(&out[3], t.id)}
		return out
	}
	a, b := lists(dst), lists(src)
	for k in 0 ..< 4 {
		defer {delete(a[k]); delete(b[k])}
		for id, i in a[k] {
			if i < len(b[k]) && b[k][i] == id {continue}
			word := "moved"
			if !slice.contains(b[k][:], id) {word = "removed"}
			return fmt.aprintf(
				"this reload changes ids (%s %s); restart the universe to apply it",
				word,
				id,
			)
		}
		if len(b[k]) > len(a[k]) {
			return fmt.aprintf(
				"this reload changes ids (added %s); restart the universe to apply it",
				b[k][len(a[k])],
			)
		}
	}
	return ""
}

// --- Lookups by number. ---

block_valid :: #force_inline proc(t: ^Block_Table, id: u16) -> bool {
	return int(id) < t.count
}

block_targetable :: #force_inline proc(t: ^Block_Table, b: Block) -> bool {
	return .Targetable in t.flags[b]
}

block_collides :: #force_inline proc(t: ^Block_Table, b: Block) -> bool {
	return .Collides in t.flags[b]
}

block_opaque :: #force_inline proc(t: ^Block_Table, b: Block) -> bool {
	return .Opaque in t.flags[b]
}

// block_shades: it stops sunlight from straight above (opaque blocks,
// and water and leaves, which let it seep in dimmed): a column's top.
block_shades :: #force_inline proc(t: ^Block_Table, b: Block) -> bool {
	return t.flags[b] & {.Opaque, .Shades} != {}
}

block_light :: #force_inline proc(t: ^Block_Table, b: Block) -> u8 {
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

// block_is_plant: a block that stands on the ground and goes when it does.
block_is_plant :: #force_inline proc(t: ^Block_Table, b: Block) -> bool {
	return t.defs[b].support != NO_TAG
}

// block_supported: whether plant may stand on below.
block_supported :: proc(t: ^Block_Table, plant, below: Block) -> bool {
	return block_in_tag(t, below, t.defs[plant].support)
}

// --- Lookups by id. ---

// registry_block: the block with this id (a name without a colon is
// voxiverse:'s): the type's default state. `id[prop=value,...]` names a state
// (state_parse).
registry_block :: proc(reg: ^Registry, text: string) -> (Block, bool) {
	if strings.index_byte(text, '[') >= 0 {return state_parse(reg, text)}
	id, ok := id_parse(text)
	if !ok {return .Air, false}
	buf: [96]u8
	full := fmt.bprintf(buf[:], "%s:%s", id.namespace, id.name)
	n, found := reg.ids[.Block][full]
	return Block(n), found
}

block_id :: proc(reg: ^Registry, b: Block) -> string {
	if !block_valid(&reg.blocks, u16(b)) {return ""}
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
	return registry_text_of(reg, true, allocator)
}

// registry_text_of: with `all` false, only what both sides build from data/
// (the lines the content hash covers); the texture, sound and structure lines
// are left out.
registry_text_of :: proc(
	reg: ^Registry,
	all: bool,
	allocator := context.temp_allocator,
) -> string {
	b := strings.builder_make(allocator)
	for p in reg.packs {
		fmt.sbprintf(&b, "pack %s %s\n", p.namespace, p.version)
	}
	if all {
		for t, i in reg.textures {
			if t.image != "" {
				fmt.sbprintf(&b, "texture %s %d image=%s\n", t.id, i, t.image)
			} else {
				fmt.sbprintf(&b, "texture %s %d generator=%s\n", t.id, i, t.generator)
			}
		}
		for s, i in reg.sounds {
			if sound_has_files(s) {
				fmt.sbprintf(&b, "sound %s %d files=", s.id, i)
				for a in Sound_Action {
					for f in s.files[a] {fmt.sbprintf(&b, "%v:%s,", a, f)}
				}
				fmt.sbprintf(&b, "\n")
			} else {
				fmt.sbprintf(&b, "sound %s %d generator=%s\n", s.id, i, s.generator)
			}
		}
	}
	for i in 0 ..< reg.blocks.count {
		d := reg.blocks.defs[i]
		fmt.sbprintf(&b, "block %s %d flags=", d.id, i)
		for f in Block_Flag {
			if f in reg.blocks.flags[i] {fmt.sbprintf(&b, "%v,", f)}
		}
		fmt.sbprintf(
			&b,
			" light=%d render=%v layer=%v textures=%d,%d,%d sound=%d drop=%d support=%d back=%d,%v tags=",
			reg.blocks.light[i],
			d.render,
			d.layer,
			d.faces[0],
			d.faces[1],
			d.faces[2],
			d.sound,
			d.drop,
			d.support,
			d.back,
			d.back_full,
		)
		for x in d.tags {fmt.sbprintf(&b, "%d,", x)}
		fmt.sbprintf(&b, " type=%d", reg.blocks.type_of[i])
		for use, k in ([3][]u16{reg.blocks.collision, reg.blocks.selection, reg.blocks.render}) {
			fmt.sbprintf(&b, " shape%d=", k)
			for bx in shape_boxes(&reg.blocks, use[i]) {fmt.sbprintf(&b, "%v-%v,", bx.lo, bx.hi)}
		}
		strings.write_byte(&b, '\n')
	}
	for d in reg.blocks.types {
		fmt.sbprintf(
			&b,
			"type %s first=%d count=%d default=%d place=%v climbable=%v connect=%d use=%v entity=%v props=",
			d.id,
			d.first_state,
			d.state_count,
			d.default,
			d.place,
			d.climbable,
			d.connect,
			d.use,
			d.entity,
		)
		for p in d.props {fmt.sbprintf(&b, "%s%v;", p.name, p.values)}
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
	if all {
		for s in reg.structures {
			fmt.sbprintf(&b, "structure %s %v %x\n", s.id, s.template.size, s.hash)
		}
	}
	return strings.to_string(b)
}

registry_hash_of :: proc(reg: ^Registry) -> u64 {
	text := registry_text_of(reg, false)
	h := hasher_make()
	hasher_bytes(&h, transmute([]u8)text)
	return hasher_finish(h)
}

// block_name: b's name for people and logs: its id, without the base pack's
// namespace ("stone", "testpack:marble").
block_name :: proc(reg: ^Registry, b: Block) -> string {
	return strings.trim_prefix(block_id(reg, b), BASE_NAMESPACE + ":")
}
