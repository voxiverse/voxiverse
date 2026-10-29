package game

import "core:strings"

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
	name:        string,
	stack:       int, // how many one slot holds
	block:       Block, // what it places (Air: nothing)
	tool:        Maybe(Tool),
	armor:       Maybe(Armor),
	description: string, // a short line for the tooltip (the pack's; "": none)
	modifiers:   [2]Modifier, // what wearing or holding it changes (mods.odin); amount 0: none
	equip:       Maybe(Equip_Slot), // where it can be worn (armor)
	weapon:      Maybe(Weapon_Info), // a hitscan weapon (data: items/weapons.json)
	grapple:     Maybe(Grapple_Info), // a grappling hook (data: items/tools.json)
	model:       Maybe(u16), // the voxel model it is held as (an index into Registry.models)
}

// Weapon_Info: what a hitscan weapon does, all of it data (the item's
// `weapon` object; server/weapons.odin is the only reader that matters).
Weapon_Info :: struct {
	damage:      f32, // health points a body hit does
	magazine:    int, // shots before a reload (at most MAX_MAGAZINE)
	fire_rate:   f32, // shots a second
	automatic:   bool, // holding the button keeps firing
	range:       f32, // blocks
	headshot:    f32, // the head's damage factor
	zoom:        f32, // the field of view's factor while the use button is held (0: none)
	reload_time: f32, // seconds
	spread:      f32, // radians of random cone
	sound:       string, // the shot's cue (client/sfx: "pistol", "rifle", "sniper"; "": the pistol's)
	pellets:     int, // rays a shot casts, each doing `damage` (0 or 1: one; MAX_PELLETS at most)
}

MAX_PELLETS :: 16

// Grapple_Info: what a grappling hook does, all of it data (the item's `grapple`
// object; the shared movement code, physics.odin, is its only reader).
Grapple_Info :: struct {
	range:    f32, // blocks: how far the line reaches (0: not a hook)
	speed:    f32, // blocks a second: the pull toward the anchor
	cooldown: f32, // seconds after a release before the next attach
}

MAX_MAGAZINE :: 255 // (Stack.ammo is a byte)

item_of_armor :: proc(a: Armor) -> Item {
	return ARMOR_ITEMS + Item(a)
}

item_of_material :: proc(m: Material) -> Item {
	return MATERIAL_ITEMS + Item(m)
}

// placing_item: the item a placed block uses up (a block's own, seeds for
// the first stage of wheat; none for the rest).
placing_item :: proc(reg: ^Registry, b: Block) -> Item {
	if b == .Wheat_0 {return item_of_material(.Seeds)}
	return item_of_block(reg, b)
}

BLOCK_STACK :: 64

// item_of_block: the item of a block players may place (a block's own
// type's number + 1), else none.
item_of_block :: proc(reg: ^Registry, b: Block) -> Item {
	if !block_valid(&reg.blocks, u16(b)) || !block_has(&reg.blocks, b, .Placeable) {return NO_ITEM}
	return Item(u16(reg.blocks.type_of[b]) + 1)
}

item_of_tool :: proc(t: Tool) -> Item {
	return TOOL_ITEMS + Item(t)
}

// item_info: what item i is; false if it is no item here.
item_info :: registry_item_info

item_valid :: proc(reg: ^Registry, i: Item) -> bool {
	_, ok := registry_item_info(reg, i)
	return ok
}

// item_id: the item's id ("voxiverse:stone"): what files and packs say.
item_id :: proc(reg: ^Registry, i: Item) -> string {
	info, _ := registry_item_info(reg, i)
	return info.name
}

// item_name: the item's name for people, logs and counters: its id without
// the base pack's namespace ("stone"; "testpack:marble").
item_name :: proc(reg: ^Registry, i: Item) -> string {
	return strings.trim_prefix(item_id(reg, i), BASE_NAMESPACE + ":")
}

item_stack_size :: proc(reg: ^Registry, i: Item) -> int {
	info, _ := registry_item_info(reg, i)
	return info.stack
}

// item_by_name: the item with this id ("stone" is voxiverse:stone).
item_by_name :: registry_item

// every_item: all the items there are, in a stable order (blocks, tools,
// materials, armor, then the packs').
every_item :: registry_every_item

// block_drop: the item breaking b leaves.
block_drop :: registry_block_drop

// Stack: some of one item (count 0: empty, item NO_ITEM).
Stack :: struct {
	item:  Item,
	count: int,
	ammo:  u8, // a weapon's magazine (instance data; 0 for everything else)
}

stack_empty :: proc(s: Stack) -> bool {
	return s.count <= 0 || s.item == NO_ITEM
}

// item_fits: whether stack may go in equipment slot e (empty always may).
item_fits :: proc(reg: ^Registry, stack: Stack, e: Equip_Slot) -> bool {
	if stack_empty(stack) {return true}
	if e == .Offhand {return true}
	info, _ := registry_item_info(reg, stack.item)
	slot, has := info.equip.?
	return has && slot == e
}
