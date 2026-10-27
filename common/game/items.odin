package game

// Items: what players carry. Every block players may place has its item;
// tools are items of their own. An item's id is on the wire; saves use its
// name. Ids are append-only like blocks': a block's item is its block id
// + 1 (0 is no item), a tool's TOOL_ITEMS + its tool id, a piece of armor's
// ARMOR_ITEMS + its id.

Item :: distinct u16

NO_ITEM :: Item(0)
TOOL_ITEMS :: Item(0x8000)
ARMOR_ITEMS :: Item(0xC000)

// Equip_Slot: where a character wears or holds things (common/game/inventory.odin).
Equip_Slot :: enum u8 {
	Head,
	Chest,
	Legs,
	Feet,
	Offhand, // holds anything
}
EQUIP_SLOTS :: len(Equip_Slot)
WORN_SLOTS :: 4 // the ones an avatar shows: Head to Feet

// Armor: what shows on the avatar (no stats yet).
Armor :: enum u8 {
	Cap,
	Tunic,
	Trousers,
	Boots,
}

Tool :: enum u8 {
	Launcher, // fires rockets (world.fire)
	Hoe, // tills grass and dirt into farmland (no durability yet)
}

// Material: items that are not blocks and not worn: what crops give.
Material :: enum u8 {
	Seeds, // plant wheat on farmland
	Wheat,
	Feather_Charm, // held in the offhand: one more jump in the air
}
MATERIAL_ITEMS :: Item(0xA000)

// PACK_ITEMS: the first number of the items packs add that are not blocks
// (0x2000 of them): a block's item is its block + 1, whoever added it.
PACK_ITEMS :: Item(0x6000)
MAX_PACK_ITEMS :: 0x2000

// The ids of the items engine code names: tools by id, materials and armor
// by their member's name ("voxiverse:seeds").
@(rodata)
BUILTIN_TOOL_IDS := [Tool]string {
	.Launcher = "voxiverse:rocket_launcher",
	.Hoe      = "voxiverse:hoe",
}
@(rodata)
BUILTIN_MATERIAL_IDS := [Material]string {
	.Seeds         = "voxiverse:seeds",
	.Wheat         = "voxiverse:wheat",
	.Feather_Charm = "voxiverse:feather_charm",
}
@(rodata)
BUILTIN_ARMOR_IDS := [Armor]string {
	.Cap      = "voxiverse:cap",
	.Tunic    = "voxiverse:tunic",
	.Trousers = "voxiverse:trousers",
	.Boots    = "voxiverse:boots",
}

Item_Info :: struct {
	name:      string,
	stack:     int, // how many one slot holds
	block:     Block, // what it places (Air: nothing)
	tool:      Maybe(Tool),
	armor:     Maybe(Armor),
	modifiers: [2]Modifier, // what wearing or holding it changes (mods.odin); amount 0: none
	equip:     Maybe(Equip_Slot), // where it can be worn (armor)
}

@(rodata)
ARMOR_INFO := [Armor]Item_Info {
	.Cap = {
		name = "cap",
		stack = 1,
		armor = .Cap,
		equip = .Head,
		modifiers = {{.Max_Health, 2}, {}},
	},
	.Tunic = {
		name = "tunic",
		stack = 1,
		armor = .Tunic,
		equip = .Chest,
		modifiers = {{.Max_Health, 4}, {}},
	},
	.Trousers = {
		name = "trousers",
		stack = 1,
		armor = .Trousers,
		equip = .Legs,
		modifiers = {{.Max_Health, 2}, {}},
	},
	.Boots = {
		name = "boots",
		stack = 1,
		armor = .Boots,
		equip = .Feet,
		modifiers = {{.Speed, 0.1}, {.Jump, 0.1}},
	},
}

item_of_armor :: proc(a: Armor) -> Item {
	return ARMOR_ITEMS + Item(a)
}

@(rodata)
TOOL_INFO := [Tool]Item_Info {
	.Launcher = {name = "rocket_launcher", stack = 1, tool = .Launcher},
	.Hoe = {name = "hoe", stack = 1, tool = .Hoe},
}

@(rodata)
MATERIAL_INFO := [Material]Item_Info {
	.Seeds = {name = "seeds", stack = 64, block = .Wheat_0}, // (placed with the right button, like a block)
	.Wheat = {name = "wheat", stack = 64},
	.Feather_Charm = {name = "feather_charm", stack = 1, modifiers = {{.Air_Jumps, 1}, {}}},
}

item_of_material :: proc(m: Material) -> Item {
	return MATERIAL_ITEMS + Item(m)
}

// placing_item: the item a placed block uses up (a block's own, seeds for
// the first stage of wheat; none for the rest).
placing_item :: proc(b: Block) -> Item {
	if b == .Wheat_0 {return item_of_material(.Seeds)}
	return item_of_block(b)
}

BLOCK_STACK :: 64

item_of_block :: proc(b: Block) -> Item {
	if !BLOCK_INFO[b].placeable {return NO_ITEM}
	return Item(u16(b) + 1)
}

item_of_tool :: proc(t: Tool) -> Item {
	return TOOL_ITEMS + Item(t)
}

// item_info: what item i is; false if it is no item (or not one we know).
item_info :: proc(i: Item) -> (Item_Info, bool) {
	switch {
	case i == NO_ITEM:
		return {}, false
	case i >= ARMOR_ITEMS:
		a := int(i - ARMOR_ITEMS)
		if a >= len(Armor) {return {}, false}
		return ARMOR_INFO[Armor(a)], true
	case i >= MATERIAL_ITEMS:
		m := int(i - MATERIAL_ITEMS)
		if m >= len(Material) {return {}, false}
		return MATERIAL_INFO[Material(m)], true
	case i >= TOOL_ITEMS:
		t := int(i - TOOL_ITEMS)
		if t >= len(Tool) {return {}, false}
		return TOOL_INFO[Tool(t)], true
	}
	id := u16(i) - 1
	if !block_valid(id) || !BLOCK_INFO[Block(id)].placeable {return {}, false}
	b := Block(id)
	return {name = BLOCK_INFO[b].name, stack = BLOCK_STACK, block = b}, true
}

item_valid :: proc(i: Item) -> bool {
	_, ok := item_info(i)
	return ok
}

item_name :: proc(i: Item) -> string {
	info, _ := item_info(i)
	return info.name
}

item_stack_size :: proc(i: Item) -> int {
	info, _ := item_info(i)
	return info.stack
}

// item_by_name: the item called name ("stone", "rocket_launcher").
item_by_name :: proc(name: string) -> (Item, bool) {
	for t in Tool {if TOOL_INFO[t].name == name {return item_of_tool(t), true}}
	for m in Material {if MATERIAL_INFO[m].name == name {return item_of_material(m), true}}
	for a in Armor {if ARMOR_INFO[a].name == name {return item_of_armor(a), true}}
	if b, ok := block_by_name(name); ok && BLOCK_INFO[b].placeable {return item_of_block(b), true}
	return NO_ITEM, false
}

// every_item: all the items there are, in a stable order (blocks, tools, armor).
every_item :: proc(allocator := context.temp_allocator) -> []Item {
	items := make([dynamic]Item, allocator)
	for b in Block {if i := item_of_block(b); i != NO_ITEM {append(&items, i)}}
	for t in Tool {append(&items, item_of_tool(t))}
	for m in Material {append(&items, item_of_material(m))}
	for a in Armor {append(&items, item_of_armor(a))}
	return items[:]
}

// block_drop: the item breaking b leaves (none for what players may not
// place: ores, plants, ice are data to give drops of their own later).
block_drop :: proc(b: Block) -> Item {
	switch {
	case b == .Tall_Grass:
		return NO_ITEM // (seeds, by chance: the server's)
	case block_is_farmland(b):
		return item_of_block(.Dirt)
	}
	if _, wheat := wheat_stage(b); wheat {return NO_ITEM} 	// (by stage: the server's)
	return item_of_block(b)
}

// Stack: some of one item (count 0: empty, item NO_ITEM).
Stack :: struct {
	item:  Item,
	count: int,
}

stack_empty :: proc(s: Stack) -> bool {
	return s.count <= 0 || s.item == NO_ITEM
}

// item_fits: whether stack may go in equipment slot e (empty always may).
item_fits :: proc(stack: Stack, e: Equip_Slot) -> bool {
	if stack_empty(stack) {return true}
	if e == .Offhand {return true}
	info, _ := item_info(stack.item)
	slot, has := info.equip.?
	return has && slot == e
}
