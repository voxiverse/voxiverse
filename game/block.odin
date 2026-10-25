package game

// Blocks are a closed enum: the id on the wire and in saves is the enum's
// u16 value, so values are append-only (never reorder or reuse). Decoders
// check ids with block_valid before converting.

Block :: enum u16 {
	Air,
	Stone,
	Dirt,
	Grass,
	Sand,
	Gravel,
	Bedrock, // the world's floor; cannot be broken
	Lamp, // gives light
	Water, // a source: water stays here (liquids.odin)
	Snow,
	Ice,
	Clay,
	Sandstone,
	Log,
	Leaves,
	Spruce_Log,
	Spruce_Leaves,
	Coal_Ore,
	Iron_Ore,
	Copper_Ore,
	Tall_Grass, // plants: cross-shaped, no collision
	Poppy,
	Dandelion,
	Cactus,
	// Flowing water, 1 (next to a source) to 7 (as far as it goes), then
	// water falling (from water above).
	Water_1,
	Water_2,
	Water_3,
	Water_4,
	Water_5,
	Water_6,
	Water_7,
	Water_Falling,
	// Built: for structures and players.
	Cobblestone,
	Stone_Bricks,
	Planks,
	Glass,
	// Gates (M18): found, never made or broken.
	Gate_Ring,
	Gate_Chevron, // dark
	Gate_Chevron_Lit, // locked while dialing, and while open
	Gate_Horizon, // the open gate's surface: walking in travels
	Wool, // white; from a sheep
	// Farming (M24): tilled ground, and wheat in eight stages (block states,
	// as water has its levels).
	Farmland, // dry
	Farmland_Moist, // water is near
	Wheat_0, // just planted
	Wheat_1,
	Wheat_2,
	Wheat_3,
	Wheat_4,
	Wheat_5,
	Wheat_6,
	Wheat_7, // ripe
}

// Block_Info: everything about a block that client and server agree on
// (how it looks and sounds is the client's: client/mesh/textures.odin,
// client/mesh/mesh.odin's block_shape, client/sfx's material_of).
Block_Info :: struct {
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
BLOCK_INFO := [Block]Block_Info {
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

block_valid :: #force_inline proc(id: u16) -> bool {
	return id < len(Block)
}

block_targetable :: #force_inline proc(b: Block) -> bool {
	return BLOCK_INFO[b].targetable
}

block_collides :: #force_inline proc(b: Block) -> bool {
	return BLOCK_INFO[b].collides
}

block_opaque :: #force_inline proc(b: Block) -> bool {
	return BLOCK_INFO[b].opaque
}

// block_by_name: the block called name ("stone").
block_by_name :: proc(name: string) -> (Block, bool) {
	for b in Block {if BLOCK_INFO[b].name == name {return b, true}}
	return .Air, false
}

// block_shades: it stops sunlight from straight above (opaque blocks, and
// water and leaves, which let it seep in dimmed): a column's top.
block_shades :: #force_inline proc(b: Block) -> bool {
	return BLOCK_INFO[b].opaque || BLOCK_INFO[b].shades
}

// WATER_FALLING_LEVEL: falling water's level, for the rules (it spreads
// sideways as if fed from a source when it lands).
WATER_FALLING_LEVEL :: 8

// water_level: b's level if it is water: 0 a source, 1..7 flowing,
// WATER_FALLING_LEVEL falling.
water_level :: proc(b: Block) -> (level: i32, is_water: bool) {
	#partial switch b {
	case .Water:
		return 0, true
	case .Water_1 ..= .Water_7:
		return i32(b - .Water_1) + 1, true
	case .Water_Falling:
		return WATER_FALLING_LEVEL, true
	}
	return 0, false
}

// water_block: the block for a water level (as water_level gives).
water_block :: proc(level: i32) -> Block {
	switch level {
	case 0:
		return .Water
	case WATER_FALLING_LEVEL:
		return .Water_Falling
	}
	return Block(i32(Block.Water_1) + level - 1)
}

block_light :: #force_inline proc(b: Block) -> u8 {
	return BLOCK_INFO[b].light
}

// WHEAT_STAGES: wheat is Wheat_0 .. Wheat_7; the last is ripe.
WHEAT_STAGES :: 8

// wheat_stage: which stage b is, if it is wheat.
wheat_stage :: proc(b: Block) -> (stage: int, is_wheat: bool) {
	if b >= .Wheat_0 && b <= .Wheat_7 {return int(b - .Wheat_0), true}
	return 0, false
}

wheat_block :: proc(stage: int) -> Block {
	return Block(int(Block.Wheat_0) + clamp(stage, 0, WHEAT_STAGES - 1))
}

block_is_farmland :: proc(b: Block) -> bool {
	return b == .Farmland || b == .Farmland_Moist
}

// block_is_plant: a block that stands on the ground and goes when it does.
block_is_plant :: proc(b: Block) -> bool {
	if _, wheat := wheat_stage(b); wheat {return true}
	#partial switch b {
	case .Tall_Grass, .Poppy, .Dandelion:
		return true
	}
	return false
}

// plant_supported: whether plant may stand on below: wild plants on grass,
// dirt or sand, wheat on farmland.
plant_supported :: proc(plant: Block, below: Block) -> bool {
	if _, wheat := wheat_stage(plant); wheat {return block_is_farmland(below)}
	#partial switch below {
	case .Grass, .Dirt, .Sand:
		return true
	}
	return false
}

// can_till: a hoe makes farmland of current when only air is above it.
can_till :: proc(current, above: Block) -> bool {
	return (current == .Grass || current == .Dirt) && above == .Air
}
