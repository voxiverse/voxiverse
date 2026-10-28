package game

import "base:runtime"
import "core:sync"

// Frozen copies of the tables the registry replaced (M47a): the equivalence
// tests compare the base pack against them, so they outlive the tables.

// Frozen_Block_Info: everything about a block that client and server agree on
// (how it looks and sounds is the client's: client/mesh/textures.odin,
// client/mesh/mesh.odin's block_shape, client/sfx's material_of).
Frozen_Block_Info :: struct {
	name:        string,
	collides:    bool, // stops players and entities
	opaque:      bool, // hides the faces of its neighbours, stops light (a column's top)
	targetable:  bool, // the aim hits it (else it aims through: air, water)
	breakable:   bool, // players (and explosions) may remove it
	placeable:   bool, // players may place it
	replaceable: bool, // placing a block there takes its place (air, water, tall grass)
	shades:      bool, // stops sunlight from straight above (light still seeps in, dimming: water, leaves)
	light:       u8, // light it gives, 0..15
}

@(rodata)
FROZEN_BLOCK_INFO := [Block]Frozen_Block_Info {
	.Air = {name = "air", replaceable = true},
	.Stone = {
		name = "stone",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Dirt = {
		name = "dirt",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Grass = {
		name = "grass",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Sand = {
		name = "sand",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Gravel = {
		name = "gravel",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Bedrock = {name = "bedrock", collides = true, opaque = true, targetable = true},
	.Lamp = {
		name = "lamp",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
		light = 15,
	},
	.Water = {name = "water", placeable = true, replaceable = true, shades = true},
	.Snow = {
		name = "snow",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Ice = {
		name = "ice",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Clay = {
		name = "clay",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Sandstone = {
		name = "sandstone",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Log = {
		name = "log",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Leaves = {
		name = "leaves",
		collides = true,
		targetable = true,
		breakable = true,
		placeable = true,
		shades = true,
	},
	.Spruce_Log = {
		name = "spruce_log",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Spruce_Leaves = {
		name = "spruce_leaves",
		collides = true,
		targetable = true,
		breakable = true,
		placeable = true,
		shades = true,
	},
	.Coal_Ore = {
		name = "coal_ore",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Iron_Ore = {
		name = "iron_ore",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Copper_Ore = {
		name = "copper_ore",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Tall_Grass = {
		name = "tall_grass",
		targetable = true,
		breakable = true,
		placeable = true,
		replaceable = true,
	},
	.Poppy = {name = "poppy", targetable = true, breakable = true, placeable = true},
	.Dandelion = {name = "dandelion", targetable = true, breakable = true, placeable = true},
	.Wool = {
		name = "wool",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Farmland = {
		name       = "farmland",
		collides   = true,
		shades     = true,
		targetable = true,
		breakable  = true,
		// (drawn a sixteenth low, so it does not hide its neighbours' faces:
		// not opaque; it breaks into dirt)
	},
	.Farmland_Moist = {
		name = "farmland_moist",
		collides = true,
		shades = true,
		targetable = true,
		breakable = true,
	},
	.Chest = {
		name = "chest",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Wool_Black = {
		name = "black_wool",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Wheat_0 = {name = "wheat_0", targetable = true, breakable = true},
	.Wheat_1 = {name = "wheat_1", targetable = true, breakable = true},
	.Wheat_2 = {name = "wheat_2", targetable = true, breakable = true},
	.Wheat_3 = {name = "wheat_3", targetable = true, breakable = true},
	.Wheat_4 = {name = "wheat_4", targetable = true, breakable = true},
	.Wheat_5 = {name = "wheat_5", targetable = true, breakable = true},
	.Wheat_6 = {name = "wheat_6", targetable = true, breakable = true},
	.Wheat_7 = {name = "wheat_7", targetable = true, breakable = true},
	.Cactus = {
		name = "cactus",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Water_1 = {name = "water_1", replaceable = true, shades = true},
	.Water_2 = {name = "water_2", replaceable = true, shades = true},
	.Water_3 = {name = "water_3", replaceable = true, shades = true},
	.Water_4 = {name = "water_4", replaceable = true, shades = true},
	.Water_5 = {name = "water_5", replaceable = true, shades = true},
	.Water_6 = {name = "water_6", replaceable = true, shades = true},
	.Water_7 = {name = "water_7", replaceable = true, shades = true},
	.Water_Falling = {name = "falling_water", replaceable = true, shades = true},
	.Cobblestone = {
		name = "cobblestone",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Stone_Bricks = {
		name = "stone_bricks",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Planks = {
		name = "planks",
		collides = true,
		opaque = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Glass = {
		name = "glass",
		collides = true,
		targetable = true,
		breakable = true,
		placeable = true,
	},
	.Gate_Ring = {name = "gate_ring", collides = true, opaque = true, targetable = true},
	.Gate_Chevron = {name = "gate_chevron", collides = true, opaque = true, targetable = true},
	.Gate_Chevron_Lit = {
		name = "gate_chevron_lit",
		collides = true,
		opaque = true,
		targetable = true,
		light = 12,
	},
	.Gate_Horizon = {name = "gate_horizon", light = 14},
}

@(rodata)
FROZEN_ARMOR_INFO := [Armor]Item_Info {
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

@(rodata)
FROZEN_TOOL_INFO := [Tool]Item_Info {
	.Launcher = {name = "rocket_launcher", stack = 1, tool = .Launcher},
	.Hoe = {name = "hoe", stack = 1, tool = .Hoe},
}

@(rodata)
FROZEN_MATERIAL_INFO := [Material]Item_Info {
	.Seeds = {name = "seeds", stack = 64, block = .Wheat_0}, // (placed with the right button, like a block)
	.Wheat = {name = "wheat", stack = 64},
	.Feather_Charm = {name = "feather_charm", stack = 1, modifiers = {{.Air_Jumps, 1}, {}}},
}


frozen_item_of_block :: proc(b: Block) -> Item {
	if !FROZEN_BLOCK_INFO[b].placeable {return NO_ITEM}
	return Item(u16(b) + 1)
}

frozen_item_info :: proc(i: Item) -> (Item_Info, bool) {
	switch {
	case i == NO_ITEM:
		return {}, false
	case i >= ARMOR_ITEMS:
		a := int(i - ARMOR_ITEMS)
		if a >= len(Armor) {return {}, false}
		return FROZEN_ARMOR_INFO[Armor(a)], true
	case i >= MATERIAL_ITEMS:
		m := int(i - MATERIAL_ITEMS)
		if m >= len(Material) {return {}, false}
		return FROZEN_MATERIAL_INFO[Material(m)], true
	case i >= TOOL_ITEMS:
		t := int(i - TOOL_ITEMS)
		if t >= len(Tool) {return {}, false}
		return FROZEN_TOOL_INFO[Tool(t)], true
	}
	id := u16(i) - 1
	if id >= len(Block) || !FROZEN_BLOCK_INFO[Block(id)].placeable {return {}, false}
	b := Block(id)
	return {name = FROZEN_BLOCK_INFO[b].name, stack = BLOCK_STACK, block = b}, true
}

frozen_every_item :: proc(allocator := context.temp_allocator) -> []Item {
	items := make([dynamic]Item, allocator)
	for b in Block {if i := frozen_item_of_block(b); i != NO_ITEM {append(&items, i)}}
	for t in Tool {append(&items, item_of_tool(t))}
	for m in Material {append(&items, item_of_material(m))}
	for a in Armor {append(&items, item_of_armor(a))}
	return items[:]
}

frozen_block_drop :: proc(b: Block) -> Item {
	switch {
	case b == .Tall_Grass:
		return NO_ITEM
	case b == .Farmland || b == .Farmland_Moist:
		return frozen_item_of_block(.Dirt)
	}
	if _, wheat := wheat_stage(b); wheat {return NO_ITEM}
	return frozen_item_of_block(b)
}

frozen_can_break :: proc(b: Block) -> bool {return FROZEN_BLOCK_INFO[b].breakable}
frozen_can_place :: proc(b: Block) -> bool {
	return FROZEN_BLOCK_INFO[b].placeable || b == .Wheat_0
}
frozen_can_change :: proc(b: Block) -> bool {
	return FROZEN_BLOCK_INFO[b].breakable || FROZEN_BLOCK_INFO[b].replaceable
}

frozen_block_is_plant :: proc(b: Block) -> bool {
	if _, wheat := wheat_stage(b); wheat {return true}
	#partial switch b {
	case .Tall_Grass, .Poppy, .Dandelion:
		return true
	}
	return false
}

frozen_plant_supported :: proc(plant: Block, below: Block) -> bool {
	if _, wheat := wheat_stage(plant);
	   wheat {return below == .Farmland || below == .Farmland_Moist}
	#partial switch below {
	case .Grass, .Dirt, .Sand:
		return true
	}
	return false
}

frozen_can_till :: proc(current, above: Block) -> bool {
	return (current == .Grass || current == .Dirt) && above == .Air
}

frozen_block_shades :: proc(b: Block) -> bool {
	return FROZEN_BLOCK_INFO[b].opaque || FROZEN_BLOCK_INFO[b].shades
}

@(private = "file")
shared_reg: ^Registry
@(private = "file")
shared_once: sync.Once

// test_reg: the base registry, built once for all the tests of the package
// (never freed: it is not the leak check's).
test_reg :: proc() -> ^Registry {
	sync.once_do(&shared_once, proc() {
		context.allocator = runtime.default_allocator()
		shared_reg = registry_base(runtime.default_allocator())
	})
	return shared_reg
}

test_blocks :: proc() -> ^Block_Table {
	return &test_reg().blocks
}

decode_client_t :: proc(data: []u8) -> (Client_Message, bool) {
	return decode_client(data, test_reg())
}

decode_server_t :: proc(data: []u8, blocks: ^Block_Array) -> (Server_Message, bool) {
	return decode_server(data, blocks, test_reg())
}
