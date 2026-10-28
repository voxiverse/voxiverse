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
	Wool_Black, // from a sheep with the recessive wool gene (M25)
	Chest, // holds 25 stacks (M30): a block with a record of its own (server/containers.odin)
}

// BUILTIN_BLOCK_IDS: the ids of the blocks engine code names (the members
// of Block); the registry gives them these numbers, whatever the packs say
// (common/game/registry.odin). Every pack set must define them.
@(rodata)
BUILTIN_BLOCK_IDS := [Block]string {
	.Air              = "voxiverse:air",
	.Stone            = "voxiverse:stone",
	.Dirt             = "voxiverse:dirt",
	.Grass            = "voxiverse:grass",
	.Sand             = "voxiverse:sand",
	.Gravel           = "voxiverse:gravel",
	.Bedrock          = "voxiverse:bedrock",
	.Lamp             = "voxiverse:lamp",
	.Water            = "voxiverse:water",
	.Snow             = "voxiverse:snow",
	.Ice              = "voxiverse:ice",
	.Clay             = "voxiverse:clay",
	.Sandstone        = "voxiverse:sandstone",
	.Log              = "voxiverse:log",
	.Leaves           = "voxiverse:leaves",
	.Spruce_Log       = "voxiverse:spruce_log",
	.Spruce_Leaves    = "voxiverse:spruce_leaves",
	.Coal_Ore         = "voxiverse:coal_ore",
	.Iron_Ore         = "voxiverse:iron_ore",
	.Copper_Ore       = "voxiverse:copper_ore",
	.Tall_Grass       = "voxiverse:tall_grass",
	.Poppy            = "voxiverse:poppy",
	.Dandelion        = "voxiverse:dandelion",
	.Cactus           = "voxiverse:cactus",
	.Water_1          = "voxiverse:water_1",
	.Water_2          = "voxiverse:water_2",
	.Water_3          = "voxiverse:water_3",
	.Water_4          = "voxiverse:water_4",
	.Water_5          = "voxiverse:water_5",
	.Water_6          = "voxiverse:water_6",
	.Water_7          = "voxiverse:water_7",
	.Water_Falling    = "voxiverse:falling_water",
	.Cobblestone      = "voxiverse:cobblestone",
	.Stone_Bricks     = "voxiverse:stone_bricks",
	.Planks           = "voxiverse:planks",
	.Glass            = "voxiverse:glass",
	.Gate_Ring        = "voxiverse:gate_ring",
	.Gate_Chevron     = "voxiverse:gate_chevron",
	.Gate_Chevron_Lit = "voxiverse:gate_chevron_lit",
	.Gate_Horizon     = "voxiverse:gate_horizon",
	.Wool             = "voxiverse:wool",
	.Farmland         = "voxiverse:farmland",
	.Farmland_Moist   = "voxiverse:farmland_moist",
	.Wheat_0          = "voxiverse:wheat_0",
	.Wheat_1          = "voxiverse:wheat_1",
	.Wheat_2          = "voxiverse:wheat_2",
	.Wheat_3          = "voxiverse:wheat_3",
	.Wheat_4          = "voxiverse:wheat_4",
	.Wheat_5          = "voxiverse:wheat_5",
	.Wheat_6          = "voxiverse:wheat_6",
	.Wheat_7          = "voxiverse:wheat_7",
	.Wool_Black       = "voxiverse:black_wool",
	.Chest            = "voxiverse:chest",
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

// can_till: a hoe makes farmland of current when only air is above it: the
// block is in the tag voxiverse:tillable.
can_till :: proc(reg: ^Registry, current, above: Block) -> bool {
	tag, found := registry_block_tag(reg, "voxiverse:tillable")
	return found && above == .Air && block_in_tag(&reg.blocks, current, tag)
}
